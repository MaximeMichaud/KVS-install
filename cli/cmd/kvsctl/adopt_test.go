package main

import (
	"context"
	"errors"
	"os"
	"os/exec"
	"path/filepath"
	"slices"
	"strings"
	"testing"
	"time"

	"github.com/MaximeMichaud/KVS-install/cli/internal/instance"
	"github.com/MaximeMichaud/KVS-install/cli/internal/release"
	"github.com/MaximeMichaud/KVS-install/cli/internal/runlog"
)

// git runs git in root with git's own configuration only: the global one
// of the machine running the tests may sign commits or run hooks.
func git(t *testing.T, root string, args ...string) string {
	t.Helper()
	cmd := exec.Command("git", append([]string{"-C", root}, args...)...)
	cmd.Env = append(os.Environ(),
		"GIT_CONFIG_GLOBAL=/dev/null", "GIT_CONFIG_NOSYSTEM=1",
		"GIT_AUTHOR_NAME=kvs", "GIT_AUTHOR_EMAIL=kvs@example.com",
		"GIT_COMMITTER_NAME=kvs", "GIT_COMMITTER_EMAIL=kvs@example.com",
		"GIT_AUTHOR_DATE=2026-10-01T12:00:00Z", "GIT_COMMITTER_DATE=2026-10-01T12:00:00Z")
	out, err := cmd.CombinedOutput()
	if err != nil {
		t.Fatalf("git %s: %v\n%s", strings.Join(args, " "), err, out)
	}
	return strings.TrimSpace(string(out))
}

const committedPHPIni = "memory_limit = 512M\nopcache.enable = 1\n"

// checkoutRoot is an installation cloned by kvs-install.sh: a git checkout
// of the release files, with the .env of the site beside them, untracked.
func checkoutRoot(t *testing.T) string {
	t.Helper()
	if _, err := exec.LookPath("git"); err != nil {
		t.Skip("git is not installed")
	}
	root := newRoot(t,
		"docker/php/php.ini", committedPHPIni,
		"conf/nginx.conf", "server {}\n",
		"README.md", "# KVS\n",
	)
	git(t, root, "init", "-q")
	git(t, root, "add", "docker/docker-compose.yml", "docker/php/php.ini", "conf/nginx.conf", "README.md")
	git(t, root, "commit", "-q", "-m", "stack")
	// No engine is reached: the checkout built nothing.
	stubCheckoutImages(t, nil, nil)
	return root
}

// stubCheckoutImages has adopt find images, or fail to list them, without
// an engine.
func stubCheckoutImages(t *testing.T, images []string, err error) {
	t.Helper()
	old := checkoutImages
	t.Cleanup(func() { checkoutImages = old })
	checkoutImages = func(_ context.Context, dir string) ([]string, error) {
		if !strings.HasSuffix(dir, "docker") {
			t.Errorf("the images are listed in %s, not in the compose project", dir)
		}
		return images, err
	}
}

func loadState(t *testing.T, root string) *instance.State {
	t.Helper()
	inst, err := instance.Detect(root)
	if err != nil {
		t.Fatal(err)
	}
	state, err := inst.LoadState()
	if err != nil || state == nil {
		t.Fatalf("state %v, %v", state, err)
	}
	return state
}

// Adopt records the version of the tag at HEAD, the commit and its date,
// keeps the working tree for a rollback, and takes the checksums of the
// commit, so that what was edited since is what the first check reports.
// The JIT block the setup appended to php.ini is no local change.
func TestAdoptRecordsTheCheckout(t *testing.T) {
	root := checkoutRoot(t)
	git(t, root, "tag", "26.10.0")
	head := git(t, root, "rev-parse", "HEAD")
	if err := os.WriteFile(filepath.Join(root, "docker/php/php.ini"), []byte(committedPHPIni+jitBlock), 0o644); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(root, "conf/nginx.conf"), []byte("server { listen 8080; }\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	if err := os.Remove(filepath.Join(root, "README.md")); err != nil {
		t.Fatal(err)
	}
	s := testSession(t, root)
	out := stdout.(*lockedBuffer).b
	if err := adopt(s, "", false); err != nil {
		t.Fatal(err)
	}
	state := loadState(t, root)
	if state.Current != "26.10.0" || state.AdoptedCommit != head || !state.AdoptedCommitDate.Equal(time.Date(2026, 10, 1, 12, 0, 0, 0, time.UTC)) {
		t.Fatalf("recorded %s at %s on %v", state.Current, state.AdoptedCommit, state.AdoptedCommitDate)
	}
	if want := []string{"conf/nginx.conf", "docker/docker-compose.yml", "docker/php/php.ini"}; !slices.Equal(state.Files, want) {
		t.Fatalf("files %v, want %v (a deleted file has nothing to keep)", state.Files, want)
	}
	changed, err := release.Verify(root, state.Checksums)
	if err != nil {
		t.Fatal(err)
	}
	if want := []string{"README.md", "conf/nginx.conf"}; !slices.Equal(changed, want) {
		t.Fatalf("the first check would report %v, want %v", changed, want)
	}
	kept, err := os.ReadFile(filepath.Join(root, "kvsctl/releases/26.10.0/conf/nginx.conf"))
	if err != nil || string(kept) != "server { listen 8080; }\n" {
		t.Fatalf("the snapshot is not the working tree: %q, %v", kept, err)
	}
	env, _ := instance.ReadEnv(filepath.Join(root, "docker/.env"))
	if env["KVS_STACK_VERSION"] != "26.10.0" {
		t.Fatalf("KVS_STACK_VERSION=%q", env["KVS_STACK_VERSION"])
	}
	text := out.String()
	for _, want := range []string{"recorded as stack 26.10.0", "conf/nginx.conf", "README.md (deleted)", "JIT block"} {
		if !strings.Contains(text, want) {
			t.Errorf("the output lacks %q:\n%s", want, text)
		}
	}
	if strings.Contains(text, "  docker/php/php.ini") {
		t.Errorf("php.ini is listed as changed:\n%s", text)
	}
}

// A checkout no release names is 0.0.0, shown as its commit.
func TestAdoptAnUnreleasedCheckout(t *testing.T) {
	root := checkoutRoot(t)
	head := git(t, root, "rev-parse", "HEAD")
	s := testSession(t, root)
	if err := adopt(s, "", false); err != nil {
		t.Fatal(err)
	}
	state := loadState(t, root)
	if state.Current != instance.Unreleased {
		t.Fatalf("recorded %s", state.Current)
	}
	text := stdout.(*lockedBuffer).b.String()
	if !strings.Contains(text, "unreleased checkout "+head[:12]) || !strings.Contains(text, "no release names commit "+head[:12]) {
		t.Fatalf("output:\n%s", text)
	}
}

// --force records the stack again until kvsctl upgrades it; from then on
// it refuses and points at recover.
func TestAdoptForce(t *testing.T) {
	root := checkoutRoot(t)
	s := testSession(t, root)
	if err := adopt(s, "26.9.0", false); err != nil {
		t.Fatal(err)
	}
	if err := adopt(s, "26.10.0", false); err == nil || !strings.Contains(err.Error(), "already recorded as 26.9.0") {
		t.Fatalf("a second adopt: %v", err)
	}
	if err := adopt(s, "26.10.0", true); err != nil {
		t.Fatal(err)
	}
	state := loadState(t, root)
	if state.Current != "26.10.0" || len(state.History) != 2 {
		t.Fatalf("after --force: %s, %d history entries", state.Current, len(state.History))
	}
	state.History = append(state.History, instance.Entry{Version: "26.11.0", Action: instance.ActionUpgrade, Date: time.Now()})
	state.Current = "26.11.0"
	inst, _ := instance.Detect(root)
	if err := inst.SaveState(state); err != nil {
		t.Fatal(err)
	}
	err := adopt(s, "26.10.0", true)
	if err == nil || !strings.Contains(err.Error(), "kvsctl recover") {
		t.Fatalf("--force on an upgraded stack: %v", err)
	}
	if loadState(t, root).Current != "26.11.0" {
		t.Fatal("the refusal changed the record")
	}
}

// adopt checks --version as a version, before it takes the lock.
func TestAdoptRefusesABadVersion(t *testing.T) {
	root := checkoutRoot(t)
	useRoot(t, root)
	keepFlags(t)
	cmd := rootCmd()
	cmd.SetArgs([]string{"adopt", "--root", root, "--version", "26.01.0"})
	if err := cmd.Execute(); exitCode(err) != exitUsage {
		t.Fatalf("a bad version gives %v", err)
	}
}

func TestAdoptedVersionOf(t *testing.T) {
	co := &instance.Checkout{Commit: "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa", Tag: "26.10.0"}
	root := t.TempDir()
	if err := os.MkdirAll(filepath.Join(root, "docker"), 0o755); err != nil {
		t.Fatal(err)
	}
	if v, source, err := adoptedVersionOf(root, co); err != nil || v != "26.10.0" || !strings.Contains(source, "tag") {
		t.Fatalf("the tag: %s, %s, %v", v, source, err)
	}
	if v, _, err := adoptedVersionOf(root, &instance.Checkout{Commit: co.Commit}); err != nil || v != instance.Unreleased {
		t.Fatalf("no tag: %s, %v", v, err)
	}
	release := filepath.Join(root, "docker", "RELEASE")
	if err := os.WriteFile(release, []byte("26.11.0\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	if v, source, err := adoptedVersionOf(root, co); err != nil || v != "26.11.0" || source != "docker/RELEASE" {
		t.Fatalf("docker/RELEASE: %s, %s, %v", v, source, err)
	}
	if err := os.WriteFile(release, []byte("latest\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	if _, _, err := adoptedVersionOf(root, co); err == nil || !strings.Contains(err.Error(), "--version") {
		t.Fatalf("a RELEASE that is no version: %v", err)
	}
}

// Only the committed php.ini plus exactly the JIT block counts as
// unchanged; anything else in the file stays a local change.
func TestAllowJITBlock(t *testing.T) {
	cases := []struct {
		working string
		allowed bool
	}{
		{committedPHPIni + jitBlock, true},
		{committedPHPIni, false},
		{committedPHPIni + jitBlock + "memory_limit = 1G\n", false},
		{"memory_limit = 1G\n" + jitBlock, false},
		{committedPHPIni + strings.TrimPrefix(jitBlock, "\n"), false},
	}
	for _, c := range cases {
		root := t.TempDir()
		path := filepath.Join(root, phpIni)
		if err := os.MkdirAll(filepath.Dir(path), 0o755); err != nil {
			t.Fatal(err)
		}
		if err := os.WriteFile(path, []byte(c.working), 0o644); err != nil {
			t.Fatal(err)
		}
		head := sha256Hex([]byte(committedPHPIni))
		sums := map[string]string{phpIni: head}
		allowed, err := allowJITBlock(root, sums)
		if err != nil {
			t.Fatal(err)
		}
		if allowed != c.allowed {
			t.Errorf("%q: allowed %v", c.working, allowed)
		}
		if want := head; allowed {
			want = sha256Hex([]byte(c.working))
			if sums[phpIni] != want {
				t.Errorf("%q: the checksum was not moved to the working file", c.working)
			}
		} else if sums[phpIni] != want {
			t.Errorf("%q: the checksum of the commit changed", c.working)
		}
	}
	if allowed, err := allowJITBlock(t.TempDir(), map[string]string{}); allowed || err != nil {
		t.Fatalf("no php.ini in the release: %v, %v", allowed, err)
	}
}

func TestPresent(t *testing.T) {
	root := t.TempDir()
	if err := os.WriteFile(filepath.Join(root, "a"), nil, 0o644); err != nil {
		t.Fatal(err)
	}
	kept, missing := present(root, []string{"a", "b"})
	if !slices.Equal(kept, []string{"a"}) || !missing["b"] || missing["a"] {
		t.Fatalf("kept %v, missing %v", kept, missing)
	}
}

// The images the checkout built are recorded as the images of its version,
// so 'kvsctl clean' lists them once two upgrades left that version behind,
// and not before. An engine adopt cannot reach only costs that record.
func TestAdoptRecordsTheImagesTheCheckoutBuilt(t *testing.T) {
	root := checkoutRoot(t)
	git(t, root, "tag", "26.8.0")
	built := []string{"kvs-example-nginx:latest", "kvs-example-php-fpm:latest"}
	stubCheckoutImages(t, built, nil)
	s := testSession(t, root)
	out := stdout.(*lockedBuffer).b
	if err := adopt(s, "", false); err != nil {
		t.Fatal(err)
	}
	state := loadState(t, root)
	if got := state.ReleaseImages["26.8.0"]; !slices.Equal(got, built) {
		t.Fatalf("recorded images %v, want %v", got, built)
	}
	if !strings.Contains(out.String(), "2 images the checkout built recorded: 'kvsctl clean' removes them once 26.8.0") {
		t.Errorf("the output lacks the images:\n%s", out.String())
	}

	// One upgrade later 26.8.0 is the way back; two upgrades later it is
	// dropped, and its images with it.
	state.Previous, state.Current = "26.8.0", "26.9.0"
	state.ReleaseImages["26.9.0"] = []string{"ghcr.io/kvs/nginx:26.9.0@sha256:" + strings.Repeat("a", 64)}
	plan, err := cleanTargets(filepath.Join(root, "kvsctl"), state)
	if err != nil {
		t.Fatal(err)
	}
	for _, ref := range built {
		if slices.Contains(plan.Images, ref) {
			t.Errorf("%s of the rollback target is listed: %v", ref, plan.Images)
		}
	}
	state.Previous, state.Current = "26.9.0", "26.10.0"
	plan, err = cleanTargets(filepath.Join(root, "kvsctl"), state)
	if err != nil {
		t.Fatal(err)
	}
	for _, ref := range built {
		if !slices.Contains(plan.Images, ref) {
			t.Errorf("%s the checkout built is not listed once 26.8.0 is dropped: %v", ref, plan.Images)
		}
	}
	if !slices.Contains(plan.Dropped, "26.8.0") {
		t.Errorf("26.8.0 is not dropped: %v", plan.Dropped)
	}

	// Adopted again as another version, the record keeps the images of the
	// first one.
	stubCheckoutImages(t, []string{"kvs-example-nginx:latest"}, nil)
	if err := adopt(s, "26.8.1", true); err != nil {
		t.Fatal(err)
	}
	again := loadState(t, root)
	if !slices.Equal(again.ReleaseImages["26.8.0"], built) || !slices.Equal(again.ReleaseImages["26.8.1"], []string{"kvs-example-nginx:latest"}) {
		t.Errorf("adopted again: %v", again.ReleaseImages)
	}
	if !strings.Contains(out.String(), "1 image the checkout built recorded: 'kvsctl clean' removes it once 26.8.1") {
		t.Errorf("the output lacks the image:\n%s", out.String())
	}

	// Without an engine the adopt goes on and says what it could not do.
	root = checkoutRoot(t)
	stubCheckoutImages(t, nil, errors.New("cannot connect to the Docker daemon\nsecond line"))
	s = testSession(t, root)
	out = stdout.(*lockedBuffer).b
	if err := adopt(s, "26.8.0", false); err != nil {
		t.Fatal(err)
	}
	if state := loadState(t, root); len(state.ReleaseImages) != 0 {
		t.Errorf("recorded %v without an engine", state.ReleaseImages)
	}
	if !strings.Contains(out.String(), "could not be listed (cannot connect to the Docker daemon)") {
		t.Errorf("the output lacks the failure:\n%s", out.String())
	}
}

// With --quiet an adopt that worked prints nothing: what it recorded is
// what status shows from then on, and the log of the run has it, the
// images the checkout built, the JIT block of php.ini and the files that
// differ from the commit included. An adopt that could not list the images
// prints nothing either.
func TestQuietAdoptPrintsNothing(t *testing.T) {
	root := checkoutRoot(t)
	git(t, root, "tag", "26.10.0")
	if err := os.WriteFile(filepath.Join(root, "docker/php/php.ini"), []byte(committedPHPIni+jitBlock), 0o644); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(root, "conf/nginx.conf"), []byte("server { listen 8080; }\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	if err := os.Remove(filepath.Join(root, "README.md")); err != nil {
		t.Fatal(err)
	}
	stubCheckoutImages(t, []string{"kvs-example-nginx:latest"}, nil)
	useRoot(t, root)
	useStderr(t)
	out, err := runKvsctl(t, "adopt", "--root", root, "--quiet")
	if err != nil || out != "" {
		t.Fatalf("a quiet adopt: %v, printed %q", err, out)
	}
	if state := loadState(t, root); state.Current != "26.10.0" {
		t.Fatalf("recorded %s", state.Current)
	}
	newestLog := func() string {
		t.Helper()
		logs, err := runlog.List(filepath.Join(root, "kvsctl"))
		if err != nil || len(logs) == 0 {
			t.Fatalf("no log: %v", err)
		}
		data, err := os.ReadFile(logs[0])
		if err != nil {
			t.Fatal(err)
		}
		return string(data)
	}
	data := newestLog()
	for _, want := range []string{"recorded as stack 26.10.0", "release files kept in", "1 image the checkout built recorded", "JIT block", "2 files differ from commit", "conf/nginx.conf", "README.md (deleted)", "kvs-install.sh does not update a stack kvsctl manages"} {
		if !strings.Contains(data, want) {
			t.Errorf("the log lacks %q:\n%s", want, data)
		}
	}

	stubCheckoutImages(t, nil, errors.New("cannot connect to the Docker daemon"))
	out, err = runKvsctl(t, "adopt", "--root", root, "--quiet", "--force")
	if err != nil || out != "" {
		t.Fatalf("a quiet adopt that could not list the images: %v, printed %q", err, out)
	}
	if data := newestLog(); !strings.Contains(data, "could not be listed (cannot connect to the Docker daemon)") {
		t.Errorf("the log lacks the images that could not be listed:\n%s", data)
	}
}

// An adopt that kept the release files and could not record the stack says
// where the files are: it changed the disk, which --quiet printed nothing
// of, and the stack is still not one kvsctl manages.
func TestAdoptSaysWhereTheFilesAreWhenTheRecordFails(t *testing.T) {
	root := checkoutRoot(t)
	git(t, root, "tag", "26.10.0")
	useRoot(t, root)
	useStderr(t)
	// The state file turns into a directory once adopt read it, before it
	// keeps the release files: the record cannot be written over it.
	state := filepath.Join(root, "kvsctl", "state.json")
	checkoutImages = func(context.Context, string) ([]string, error) {
		return nil, os.MkdirAll(filepath.Join(state, "held"), 0o755)
	}
	out, err := runKvsctl(t, "adopt", "--root", root, "--quiet")
	kept := filepath.Join(root, "kvsctl", "releases", "26.10.0")
	if err == nil || !strings.HasPrefix(err.Error(), "the release files are kept in "+kept+", but the stack could not be recorded: ") || out != "" {
		t.Fatalf("an adopt whose record failed: %v, printed %q", err, out)
	}
	if _, err := os.Stat(filepath.Join(kept, "conf", "nginx.conf")); err != nil {
		t.Fatalf("the release files are not where the message says: %v", err)
	}
}
