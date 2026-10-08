package dockerx

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"slices"
	"strings"
	"testing"

	"github.com/moby/moby/api/types/container"
	"github.com/moby/moby/api/types/image"
)

func TestRefsOf(t *testing.T) {
	list := []image.Summary{
		{RepoTags: []string{"ghcr.io/x/php:0.2.0", "ghcr.io/x/php:latest"}},
		{RepoTags: []string{"<none>:<none>"}},
		{RepoTags: nil},
		{RepoTags: []string{"ghcr.io/x/nginx:0.1.0", "ghcr.io/x/php:0.2.0"}},
	}
	got := strings.Join(refsOf(list), " ")
	want := "ghcr.io/x/nginx:0.1.0 ghcr.io/x/php:0.2.0 ghcr.io/x/php:latest"
	if got != want {
		t.Fatalf("refs are %q, wanted %q", got, want)
	}
}

func TestInUse(t *testing.T) {
	used := []string{
		`Error response from daemon: conflict: unable to remove repository reference "ghcr.io/x/php:0.1.0" (must force) - container 4b2 is using its referenced image 9ad`,
		"Error response from daemon: conflict: unable to delete 9ad (must be forced) - image is being used by stopped container 4b2",
	}
	for _, msg := range used {
		if !inUse(errors.New(msg)) {
			t.Fatalf("not recognised as in use: %s", msg)
		}
	}
	if inUse(errors.New("Error response from daemon: No such image: ghcr.io/x/php:0.1.0")) {
		t.Fatal("a missing image was read as in use")
	}
}

// Unpinned names each container of the project that runs another image
// than the one pinned for its service, compared by image ID: a container
// named by another reference to the pinned image runs it, and one named by
// the pin itself does not when the engine holds another image at it.
func TestUnpinned(t *testing.T) {
	f, c := newFakeEngine(t)
	pinnedID, otherID := "sha256:"+strings.Repeat("1", 64), "sha256:"+strings.Repeat("2", 64)
	nginxID := "sha256:" + strings.Repeat("3", 64)
	ctr := func(name, service, img, id string, oneOff bool) container.InspectResponse {
		labels := map[string]string{"com.docker.compose.project": "kvs-example", "com.docker.compose.service": service}
		if oneOff {
			labels["com.docker.compose.oneoff"] = "True"
		}
		return container.InspectResponse{ID: name + "-id", Name: "/" + name, Image: id, Config: &container.Config{Image: img, Labels: labels}}
	}
	f.set(func(f *fakeEngine) {
		f.images["registry.example/php@"+digestA] = image.InspectResponse{ID: pinnedID}
		f.images["registry.example/cron@"+digestA] = image.InspectResponse{ID: pinnedID}
		f.images["registry.example/nginx@"+digestA] = image.InspectResponse{ID: nginxID}
		f.containers = []container.InspectResponse{
			ctr("kvs-example-php-fpm-1", "php-fpm", "registry.example/php:1.1.0@"+digestA, pinnedID, false),
			ctr("kvs-example-cron-1", "cron", "registry.example/cron:1.0.0@"+digestB, otherID, false),
			ctr("kvs-example-cron-run-1", "cron", "registry.example/cron:1.0.0@"+digestB, otherID, true),
			ctr("kvs-example-mariadb-1", "mariadb", "mariadb:11.4", otherID, false),
			// The pinned image under another name: the same image.
			ctr("kvs-example-nginx-1", "nginx", "registry.example/nginx:stable", nginxID, false),
			// The very pin, and another image: the engine no longer
			// holds the pinned one.
			ctr("kvs-example-manticore-1", "manticore", "registry.example/manticore:1.1.0@"+digestA, otherID, false),
		}
	})
	pins := map[string]string{
		"php-fpm":   "registry.example/php:1.1.0@" + digestA,
		"cron":      "registry.example/cron:1.1.0@" + digestA,
		"mariadb":   "mariadb:11.8@" + digestA,
		"memcached": "memcached:1@" + digestA,
		"nginx":     "registry.example/nginx:1.1.0@" + digestA,
		"manticore": "registry.example/manticore:1.1.0@" + digestA,
	}
	got, err := c.Unpinned(context.Background(), "kvs-example", pins)
	if err != nil {
		t.Fatal(err)
	}
	want := []string{
		"kvs-example-cron-1 runs registry.example/cron:1.0.0@" + digestB + " (222222222222), not the pinned registry.example/cron:1.1.0@" + digestA,
		"kvs-example-manticore-1 runs registry.example/manticore:1.1.0@" + digestA + " (222222222222), not the pinned registry.example/manticore:1.1.0@" + digestA,
		"kvs-example-mariadb-1 runs mariadb:11.4 (222222222222), not the pinned mariadb:11.8@" + digestA,
	}
	if !slices.Equal(got, want) {
		t.Errorf("Unpinned =\n%q\nwant\n%q", got, want)
	}
}

// ComposeImages names a service compose only builds the way the engine
// holds it, and lists each image once. It asks for the services of every
// profile: the setup profile, which is off once the stack is installed,
// builds kvs-init.
func TestComposeImages(t *testing.T) {
	log := installFakeDocker(t, "images")
	got, err := ComposeImages(context.Background(), t.TempDir())
	if err != nil {
		t.Fatal(err)
	}
	want := []string{"ghcr.io/x/php:1.1.0@sha256:" + strings.Repeat("0", 64), "kvs-example-nginx:latest", "localhost:5000/kvs/cron:latest", "mariadb:11.8"}
	if !slices.Equal(got, want) {
		t.Errorf("ComposeImages =\n%q\nwant\n%q", got, want)
	}
	if args := logged(readLog(t, log), "args"); args != "compose --profile * config --images" {
		t.Errorf("args %q, want every profile on", args)
	}
}

// inspected is an image as the engine describes it, with its labels:
// image.InspectResponse carries them in a type of another module.
func inspected(t *testing.T, id string, repoDigests []string, labels map[string]string) image.InspectResponse {
	t.Helper()
	doc, err := json.Marshal(map[string]any{"Id": id, "RepoDigests": repoDigests, "Config": map[string]any{"Labels": labels}})
	if err != nil {
		t.Fatal(err)
	}
	var out image.InspectResponse
	if err := json.Unmarshal(doc, &out); err != nil {
		t.Fatal(err)
	}
	return out
}

// BuiltLocally keeps the images compose built for the project: the
// containerd image store gives them a repository digest like a pulled
// image, the label of the project tells them apart. Without a label, an
// image with no repository digest was built on the classic store.
func TestBuiltLocally(t *testing.T) {
	f, c := newFakeEngine(t)
	id := func(n string) string { return "sha256:" + strings.Repeat(n, 64) }
	built := map[string]string{"com.docker.compose.project": "kvs-example", "com.docker.compose.service": "nginx"}
	f.set(func(f *fakeEngine) {
		f.images["kvs-example-nginx:latest"] = inspected(t, id("1"), []string{"kvs-example-nginx@" + digestA}, built)
		f.images["kvs-example-cron:latest"] = inspected(t, id("2"), nil, nil)
		f.images["mariadb:11.8"] = inspected(t, id("3"), []string{"mariadb@" + digestB}, nil)
		f.images["kvs-other-php:latest"] = inspected(t, id("4"), nil, map[string]string{"com.docker.compose.project": "kvs-other"})
	})
	refs := []string{"kvs-example-cron:latest", "kvs-example-nginx:latest", "kvs-example-php:latest", "kvs-other-php:latest", "mariadb:11.8"}
	got, err := c.BuiltLocally(context.Background(), "kvs-example", refs)
	if err != nil {
		t.Fatal(err)
	}
	if want := []string{"kvs-example-cron:latest", "kvs-example-nginx:latest"}; !slices.Equal(got, want) {
		t.Errorf("BuiltLocally = %q, want %q", got, want)
	}
}

// ComposeProject reads the name compose gives the project.
func TestComposeProject(t *testing.T) {
	log := installFakeDocker(t, "project")
	got, err := ComposeProject(context.Background(), t.TempDir())
	if err != nil || got != "kvs-example" {
		t.Errorf("ComposeProject = %q, %v", got, err)
	}
	if args := logged(readLog(t, log), "args"); args != "compose config --format=json" {
		t.Errorf("args %q", args)
	}
}

// What BuiltLocally relies on, on the engine of the machine: compose
// labels the image it builds with the project, whatever the image store.
// It builds an image FROM scratch, which pulls nothing, and removes it; it
// runs only with KVSCTL_DOCKER_BUILD=1.
func TestBuiltLocallyOnTheEngine(t *testing.T) {
	if os.Getenv("KVSCTL_DOCKER_BUILD") != "1" {
		t.Skip("set KVSCTL_DOCKER_BUILD=1 to build an image on the engine of this machine")
	}
	dir := t.TempDir()
	project := fmt.Sprintf("kvsctltest-files-%d-build", os.Getpid())
	for name, content := range map[string]string{
		"docker-compose.yml": "name: " + project + "\nservices:\n  app:\n    build: .\n  db:\n    image: mariadb:11.8\n",
		"Dockerfile":         "FROM scratch\nCOPY payload /payload\n",
		"payload":            "built here\n",
	} {
		if err := os.WriteFile(filepath.Join(dir, name), []byte(content), 0o644); err != nil {
			t.Fatal(err)
		}
	}
	ctx := context.Background()
	if err := Compose(ctx, dir, nil, "build", "app"); err != nil {
		t.Fatal(err)
	}
	c, err := New()
	if err != nil {
		t.Fatal(err)
	}
	defer c.Close()
	t.Cleanup(func() { _ = c.RemoveImage(ctx, project+"-app:latest") })
	name, err := ComposeProject(ctx, dir)
	if err != nil || name != project {
		t.Fatalf("ComposeProject = %q, %v", name, err)
	}
	refs, err := ComposeImages(ctx, dir)
	if err != nil {
		t.Fatal(err)
	}
	got, err := c.BuiltLocally(ctx, name, refs)
	if err != nil || !slices.Equal(got, []string{project + "-app:latest"}) {
		t.Errorf("BuiltLocally(%q) = %q, %v; want the image compose built", refs, got, err)
	}
}
