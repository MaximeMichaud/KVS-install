package dockerx

import (
	"context"
	"encoding/json"
	"strings"
	"testing"
	"time"

	"github.com/moby/moby/api/types/container"
	"github.com/moby/moby/api/types/image"
	"github.com/moby/moby/api/types/system"
	"github.com/moby/moby/api/types/volume"
)

// fakeContainer is a container of project kvs as the engine describes it.
func fakeContainer(id, name, service string, health *container.HealthConfig) container.InspectResponse {
	return container.InspectResponse{
		ID:           id,
		Name:         "/" + name,
		Image:        "sha256:" + strings.Repeat("d", 64),
		RestartCount: 2,
		State: &container.State{
			Status:    "running",
			StartedAt: "2026-10-06T10:00:00.5Z",
			Health:    &container.Health{Status: "starting"},
		},
		Config: &container.Config{
			Image:       "mariadb:11.8.9",
			Labels:      map[string]string{"com.docker.compose.project": "kvs", "com.docker.compose.service": service},
			Healthcheck: health,
		},
		Mounts: []container.MountPoint{{Type: "volume", Name: "kvs_mariadb-data", Source: "/var/lib/docker/volumes/kvs_mariadb-data/_data", Destination: "/var/lib/mysql"}},
	}
}

func TestContainersCarryTheIDAndTheHealthTiming(t *testing.T) {
	f, c := newFakeEngine(t)
	f.set(func(f *fakeEngine) {
		f.containers = []container.InspectResponse{
			fakeContainer("id-manticore", "kvs-manticore", "manticore", &container.HealthConfig{Test: []string{"CMD-SHELL", "true"}, StartPeriod: 300 * time.Second, Interval: 30 * time.Second, Timeout: 10 * time.Second, Retries: 5}),
			fakeContainer("id-php", "kvs-php", "php-fpm", &container.HealthConfig{Test: []string{"NONE"}, Interval: time.Hour}),
			fakeContainer("id-cron", "kvs-cron", "cron", nil),
		}
		other := fakeContainer("id-other", "other-site", "php-fpm", nil)
		other.Config.Labels["com.docker.compose.project"] = "another"
		f.containers = append(f.containers, other)
	})
	states, err := c.Containers(context.Background(), "kvs")
	if err != nil {
		t.Fatal(err)
	}
	if len(states) != 3 || states[0].Name != "kvs-cron" || states[1].Name != "kvs-manticore" || states[2].Name != "kvs-php" {
		t.Fatalf("states %+v", states)
	}
	manticore := states[1]
	if manticore.ID != "id-manticore" || manticore.Service != "manticore" || manticore.State != "running" || manticore.Health != "starting" || manticore.Restarts != 2 {
		t.Errorf("manticore %+v", manticore)
	}
	if want := time.Date(2026, 10, 6, 10, 0, 0, 500e6, time.UTC); !manticore.Started.Equal(want) {
		t.Errorf("started %s, want %s", manticore.Started, want)
	}
	if manticore.HealthStartPeriod != 300*time.Second || manticore.HealthInterval != 30*time.Second || manticore.HealthTimeout != 10*time.Second || manticore.HealthRetries != 5 {
		t.Errorf("health timing %+v", manticore)
	}
	// A check turned off and no check at all leave the timing at zero.
	for _, s := range []ContainerState{states[0], states[2]} {
		if s.HealthStartPeriod != 0 || s.HealthInterval != 0 || s.HealthTimeout != 0 || s.HealthRetries != 0 {
			t.Errorf("%s has a timing: %+v", s.Name, s)
		}
	}
	one, err := c.Container(context.Background(), "kvs-manticore")
	if err != nil {
		t.Fatal(err)
	}
	if one.ID != "id-manticore" || one.Service != "manticore" || !one.Started.Equal(manticore.Started) || one.HealthRetries != 5 {
		t.Errorf("Container = %+v", one)
	}
	if _, err := c.Container(context.Background(), "kvs-gone"); err == nil {
		t.Error("a container the engine does not know is an error")
	}
}

// The window of a health check: start period + interval x (retries + 1) +
// timeout + 30 s, Docker's defaults standing in for what the check leaves
// unset.
func TestHealthWindow(t *testing.T) {
	cases := []struct {
		state ContainerState
		want  time.Duration
	}{
		{ContainerState{}, 30*time.Second*4 + 30*time.Second + 30*time.Second},
		{ContainerState{HealthStartPeriod: 300 * time.Second, HealthInterval: 30 * time.Second, HealthTimeout: 10 * time.Second, HealthRetries: 5}, 300*time.Second + 180*time.Second + 10*time.Second + 30*time.Second},
		{ContainerState{HealthInterval: 10 * time.Second, HealthTimeout: 5 * time.Second}, 40*time.Second + 5*time.Second + 30*time.Second},
	}
	for _, tc := range cases {
		if got := tc.state.HealthWindow(); got != tc.want {
			t.Errorf("%+v: window %s, want %s", tc.state, got, tc.want)
		}
	}
}

func TestEngineFacts(t *testing.T) {
	f, c := newFakeEngine(t)
	f.set(func(f *fakeEngine) {
		f.info = system.Info{Architecture: "x86_64", OSType: "linux", DockerRootDir: "/srv/docker", ServerVersion: "29.8.2"}
		f.volumes["kvs_mariadb-data"] = volume.Volume{Name: "kvs_mariadb-data", Mountpoint: "/srv/docker/volumes/kvs_mariadb-data/_data"}
		f.volumes["kvs_empty"] = volume.Volume{Name: "kvs_empty"}
		f.containers = []container.InspectResponse{fakeContainer("id-db", "kvs-mariadb", "mariadb", nil)}
	})
	info, err := c.Info(context.Background())
	if err != nil {
		t.Fatal(err)
	}
	if info.Architecture != "x86_64" || info.OSType != "linux" || info.RootDir != "/srv/docker" || info.Version != "29.8.2" || !info.AMD64() {
		t.Errorf("info %+v", info)
	}
	if (EngineInfo{Architecture: "aarch64"}).AMD64() {
		t.Error("aarch64 is not amd64")
	}
	if (EngineInfo{Architecture: "amd64"}).AMD64() == false {
		t.Error("amd64 is amd64")
	}
	if dir, err := c.VolumeMountpoint(context.Background(), "kvs_mariadb-data"); err != nil || dir != "/srv/docker/volumes/kvs_mariadb-data/_data" {
		t.Errorf("mountpoint %q, %v", dir, err)
	}
	if _, err := c.VolumeMountpoint(context.Background(), "kvs_missing"); err == nil {
		t.Error("a missing volume is an error")
	}
	if _, err := c.VolumeMountpoint(context.Background(), "kvs_empty"); err == nil {
		t.Error("a volume without a mountpoint is an error")
	}
	if dir, err := c.MountSource(context.Background(), "kvs-mariadb", "/var/lib/mysql"); err != nil || dir != "/var/lib/docker/volumes/kvs_mariadb-data/_data" {
		t.Errorf("mount source %q, %v", dir, err)
	}
	if _, err := c.MountSource(context.Background(), "kvs-mariadb", "/srv"); err == nil {
		t.Error("nothing is mounted at /srv")
	}
}

// The requests name the API version the engine answered the ping with, not
// the newest one the client knows, which an older engine refuses.
func TestNegotiatesTheEngineAPIVersion(t *testing.T) {
	f, c := newFakeEngine(t)
	if _, err := c.Info(context.Background()); err != nil {
		t.Fatal(err)
	}
	if _, err := c.Containers(context.Background(), "kvs"); err != nil {
		t.Fatal(err)
	}
	if got := f.apiVersions(); len(got) != 2 || got[0] != fakeAPIVersion || got[1] != fakeAPIVersion {
		t.Errorf("the requests named API versions %v, want %s", got, fakeAPIVersion)
	}
}

// The version comes from the image the container runs, not from the
// environment of the container, which may carry the stack's own
// MARIADB_VERSION=11.8.
func TestMariaDBVersion(t *testing.T) {
	f, c := newFakeEngine(t)
	f.set(func(f *fakeEngine) {
		db := fakeContainer("id-db", "kvs-mariadb", "mariadb", nil)
		db.Config.Env = []string{"MARIADB_VERSION=11.8"}
		bare := fakeContainer("id-bare", "kvs-bare", "mariadb", nil)
		bare.Image = "sha256:" + strings.Repeat("e", 64)
		f.containers = []container.InspectResponse{db, bare}
		f.images[db.Image] = imageWithEnv(t, db.Image, "PATH=/usr/bin", "MARIADB_VERSION=1:11.8.10+maria~ubu2404")
		f.images[bare.Image] = imageWithEnv(t, bare.Image, "PATH=/usr/bin")
	})
	if v, err := c.MariaDBVersion(context.Background(), "kvs-mariadb"); err != nil || v != "11.8.10" {
		t.Errorf("version %q, %v", v, err)
	}
	if v, err := c.MariaDBVersion(context.Background(), "kvs-bare"); err != nil || v != "" {
		t.Errorf("an image that says nothing gives no version: %q, %v", v, err)
	}
	if _, err := c.MariaDBVersion(context.Background(), "kvs-gone"); err == nil {
		t.Error("a missing container is an error")
	}
}

// imageWithEnv is an image whose configuration sets env, built from the
// JSON the engine sends.
func imageWithEnv(t *testing.T, id string, env ...string) image.InspectResponse {
	t.Helper()
	data, err := json.Marshal(map[string]any{"Id": id, "Config": map[string]any{"Env": env}})
	if err != nil {
		t.Fatal(err)
	}
	var img image.InspectResponse
	if err := json.Unmarshal(data, &img); err != nil {
		t.Fatal(err)
	}
	return img
}

func TestMariaDBVersionParse(t *testing.T) {
	cases := map[string]string{
		"1:11.8.9+maria~ubu2404":  "11.8.9",
		"1:12.3.3+maria~ubu2404":  "12.3.3",
		"11.4.13":                 "11.4.13",
		"1:10.11.14+maria~deb12":  "10.11.14",
		"1:11.8.9-1+maria~ubu24":  "11.8.9",
		"latest":                  "",
		"1:":                      "",
		"11":                      "",
		"1:11..9+maria~ubu2404":   "",
		"1:11.8.9rc+maria~ubu244": "",
	}
	for in, want := range cases {
		if got := mariadbVersion(in); got != want {
			t.Errorf("mariadbVersion(%q) = %q, want %q", in, got, want)
		}
	}
}

func TestImageSizeOfAMissingImage(t *testing.T) {
	f, c := newFakeEngine(t)
	f.set(func(f *fakeEngine) { f.images["ghcr.io/x/php:0.1.0"] = image.InspectResponse{Size: 42} })
	if n, err := c.ImageSize(context.Background(), "ghcr.io/x/php:0.1.0"); err != nil || n != 42 {
		t.Errorf("size %d, %v", n, err)
	}
	if n, err := c.ImageSize(context.Background(), "ghcr.io/x/php:0.0.1"); err != nil || n != 0 {
		t.Errorf("a missing image weighs nothing: %d, %v", n, err)
	}
}

func TestRefs(t *testing.T) {
	names := map[string]string{
		"mariadb:11.8.9":                       "mariadb",
		"mariadb":                              "mariadb",
		"ghcr.io/x/php:8.3@" + digestA:         "ghcr.io/x/php",
		"localhost:5000/x/php:0.2.0":           "localhost:5000/x/php",
		"localhost:5000/x/php":                 "localhost:5000/x/php",
		"docker.dragonflydb.io/df/df:v1.35.1":  "docker.dragonflydb.io/df/df",
		"mariadb@" + digestA:                   "mariadb",
		"registry.example.com:443/a/b/c:1.2.3": "registry.example.com:443/a/b/c",
	}
	for ref, want := range names {
		if got := RefName(ref); got != want {
			t.Errorf("RefName(%q) = %q, want %q", ref, got, want)
		}
	}
	if got, err := PinnedRef("ghcr.io/x/php:8.3", digestA); err != nil || got != "ghcr.io/x/php@"+digestA {
		t.Errorf("PinnedRef = %q, %v", got, err)
	}
	if _, err := PinnedRef("", digestA); err == nil {
		t.Error("an empty reference cannot be pinned")
	}
	keys := map[string]string{
		"mariadb:11.8.9":                      dockerHub,
		"neilpang/acme.sh:3.1.6":              dockerHub,
		"docker.io/library/mariadb:11.8.9":    dockerHub,
		"index.docker.io/library/mariadb":     dockerHub,
		"ghcr.io/x/php:8.3":                   "ghcr.io",
		"localhost:5000/x/php:0.2.0":          "localhost:5000",
		"localhost/x/php":                     "localhost",
		"docker.dragonflydb.io/df/df:v1.35.1": "docker.dragonflydb.io",
	}
	for ref, want := range keys {
		if got := registryKey(ref); got != want {
			t.Errorf("registryKey(%q) = %q, want %q", ref, got, want)
		}
	}
}
