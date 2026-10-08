//go:build linux

package upgrade

import (
	"bytes"
	"crypto/ed25519"
	"crypto/sha256"
	"encoding/base64"
	"encoding/hex"
	"errors"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"regexp"
	"runtime"
	"slices"
	"strings"
	"testing"
	"time"

	"github.com/MaximeMichaud/KVS-install/cli/internal/manifest"
)

// The tests of this file run kvsctl as a process on what it reads of the
// manifest and of the engine before it plans: the signature, the format,
// the channel, a server that does not answer, an engine that does not
// answer. update-cli runs on a copy of the build, which it may replace.

// kvsctlCopy is a copy of the kvsctl the tests build, for update-cli to
// replace without touching the build the other tests run.
func kvsctlCopy(t *testing.T) string {
	t.Helper()
	data, err := os.ReadFile(kvsctlBinary(t))
	if err != nil {
		t.Fatal(err)
	}
	path := filepath.Join(t.TempDir(), "kvsctl")
	if err := os.WriteFile(path, data, 0o755); err != nil {
		t.Fatal(err)
	}
	return path
}

// kvsctlFrom starts the kvsctl at bin on the stack, its output on pipes,
// with the root, the manifest and the key of the stack the way s.kvsctl
// adds them.
func (s *stack) kvsctlFrom(bin string, args ...string) *kvsctlRun {
	t := s.t
	t.Helper()
	args = append(args, "--root", s.root)
	if !slices.Contains(args, "--manifest") {
		args = append(args, "--manifest", "file://"+filepath.Join(s.dir, "manifest.json"))
	}
	cmd := exec.Command(bin, args...)
	cmd.Env = append(os.Environ(), "KVSCTL_RELEASE_KEY="+base64.StdEncoding.EncodeToString(s.pub))
	r := &kvsctlRun{t: t, cmd: cmd, drained: make(chan struct{}), exited: make(chan struct{})}
	cmd.Stdout, cmd.Stderr = &r.out, &r.out
	if err := cmd.Start(); err != nil {
		t.Fatal(err)
	}
	close(r.drained)
	go func() {
		err := cmd.Wait()
		var exit *exec.ExitError
		switch {
		case err == nil:
			r.status = "exit 0"
		case errors.As(err, &exit):
			r.code, r.status = exit.ExitCode(), exit.String()
		default:
			r.code, r.status = -1, err.Error()
		}
		close(r.exited)
	}()
	t.Cleanup(func() {
		select {
		case <-r.exited:
		default:
			_ = cmd.Process.Kill()
			<-r.exited
		}
	})
	return r
}

// releaseKvsctl builds kvsctl the way a release does, with its version,
// for what a release build decides on it: a dev build is never held back.
func releaseKvsctl(t *testing.T, version string) string {
	t.Helper()
	if testing.Short() {
		t.Skip("builds kvsctl and runs it as a process")
	}
	path := filepath.Join(t.TempDir(), "kvsctl")
	args := []string{"build", "-ldflags", "-X main.Version=" + version, "-o", path}
	if raceBuild {
		args = append(args, "-race")
	}
	args = append(args, "github.com/MaximeMichaud/KVS-install/cli/cmd/kvsctl")
	if out, err := exec.Command("go", args...).CombinedOutput(); err != nil {
		t.Fatalf("go build: %v\n%s", err, out)
	}
	return path
}

// cliBuild is a kvsctl build of a release for this platform: a script that
// prints the version line of that release, and its entry in a manifest.
func cliBuild(t *testing.T, version string) string {
	t.Helper()
	data := []byte("#!/bin/sh\necho 'kvsctl " + version + " (linux/amd64)'\n")
	path := filepath.Join(t.TempDir(), "kvsctl-"+version)
	if err := os.WriteFile(path, data, 0o644); err != nil {
		t.Fatal(err)
	}
	sum := sha256.Sum256(data)
	return fmt.Sprintf(`{"%s-%s":{"url":"file://%s","sha256":"%s","size":%d}}`, runtime.GOOS, runtime.GOARCH, path, hex.EncodeToString(sum[:]), len(data))
}

// unchanged fails the test when the binary at path no longer holds want,
// or update-cli kept a previous binary beside it.
func unchanged(t *testing.T, path string, want []byte) {
	t.Helper()
	if got, err := os.ReadFile(path); err != nil || !bytes.Equal(got, want) {
		t.Errorf("%s changed (%v)", path, err)
	}
	if _, err := os.Stat(path + ".previous"); !os.IsNotExist(err) {
		t.Errorf("%s.previous was written: %v", path, err)
	}
}

// A manifest signed by a key kvsctl does not trust is refused by the
// commands that read the release list for kvsctl itself, and update-cli
// leaves the binary as it was.
func TestKvsctlRefusesAForeignSignature(t *testing.T) {
	s := e2eStack(t)
	_, stranger, err := ed25519.GenerateKey(nil)
	if err != nil {
		t.Fatal(err)
	}
	raw, err := os.ReadFile(filepath.Join(s.dir, "manifest.json"))
	if err != nil {
		t.Fatal(err)
	}
	s.sign(raw, stranger)
	const refused = "manifest signature does not match any release key this kvsctl knows"
	check := s.kvsctl(pipes, "version", "--check")
	if code := check.wait(); code != 1 {
		t.Errorf("version --check: %s, want exit 1; it printed:\n%s", check.status, check.output())
	}
	contains(t, "version --check", check.output(), refused)
	bin := kvsctlCopy(t)
	before, err := os.ReadFile(bin)
	if err != nil {
		t.Fatal(err)
	}
	update := s.kvsctlFrom(bin, "update-cli")
	if code := update.wait(); code != 1 {
		t.Errorf("update-cli: %s, want exit 1; it printed:\n%s", update.status, update.output())
	}
	contains(t, "update-cli", update.output(), refused)
	unchanged(t, bin, before)
}

// update-cli reads the part of the manifest every kvsctl reads, so the
// format of a later release, which check and upgrade refuse and send to
// update-cli, still gives it the build that reads it.
func TestKvsctlUpdateCLIReadsALaterFormat(t *testing.T) {
	s := e2eStack(t)
	later := fmt.Sprintf(`{"schema":3,"channel":"stable","updated":"%s","signing":{"scheme":"something new"},"releases":[{"version":"9.9.9","cli":%s,"bundle":"elsewhere","images":"another shape"}]}`,
		time.Now().UTC().Format(time.RFC3339), cliBuild(t, "9.9.9"))
	s.sign([]byte(later), s.priv)
	check := s.kvsctl(pipes, "check")
	if code := check.wait(); code != 1 {
		t.Errorf("check: %s, want exit 1; it printed:\n%s", check.status, check.output())
	}
	contains(t, "check", check.output(), "this manifest needs a newer kvsctl (schema 3, this build reads 2): run 'kvsctl update-cli'")
	bin := kvsctlCopy(t)
	before, err := os.ReadFile(bin)
	if err != nil {
		t.Fatal(err)
	}
	update := s.kvsctlFrom(bin, "update-cli")
	if code := update.wait(); code != 0 {
		t.Fatalf("update-cli: %s, want exit 0; it printed:\n%s", update.status, update.output())
	}
	contains(t, "update-cli", update.output(), bin+": dev replaced by the build of release 9.9.9")
	if out, err := exec.Command(bin, "version").Output(); err != nil || string(out) != "kvsctl 9.9.9 (linux/amd64)\n" {
		t.Errorf("the new binary says %q (%v)", out, err)
	}
	if previous, err := os.ReadFile(bin + ".previous"); err != nil || !bytes.Equal(previous, before) {
		t.Errorf("the previous binary was not kept (%v)", err)
	}
}

// update-cli installs the build of the latest stable release, a release
// candidate only when --version names it, and takes the manifest of a
// candidate from the URL it is given.
func TestKvsctlUpdateCLITakesACandidateOnlyByName(t *testing.T) {
	s := e2eStack(t)
	candidate := fmt.Sprintf(`{"schema":2,"channel":"candidate","updated":"%s","releases":[{"version":"9.9.9-rc1","cli":%s},{"version":"9.9.8","cli":%s}]}`,
		time.Now().UTC().Format(time.RFC3339), cliBuild(t, "9.9.9-rc1"), cliBuild(t, "9.9.8"))
	s.sign([]byte(candidate), s.priv)
	for _, c := range []struct {
		args []string
		want string
	}{
		{nil, "9.9.8"},
		{[]string{"--version", "9.9.9-rc1"}, "9.9.9-rc1"},
	} {
		bin := kvsctlCopy(t)
		update := s.kvsctlFrom(bin, append([]string{"update-cli"}, c.args...)...)
		if code := update.wait(); code != 0 {
			t.Fatalf("update-cli %v: %s, want exit 0; it printed:\n%s", c.args, update.status, update.output())
		}
		contains(t, fmt.Sprintf("update-cli %v", c.args), update.output(), "replaced by the build of release "+c.want+";")
	}
}

// update-cli stops the download of a build at the size the signed manifest
// gives it: a file larger than that is refused before it is read whole, and
// the binary stays as it was.
func TestKvsctlUpdateCLIStopsAtTheSignedSize(t *testing.T) {
	s := e2eStack(t)
	build := regexp.MustCompile(`"size":\d+`).ReplaceAllString(cliBuild(t, "9.9.9"), `"size":10`)
	s.sign([]byte(fmt.Sprintf(`{"schema":2,"channel":"stable","updated":"%s","releases":[{"version":"9.9.9","cli":%s}]}`, time.Now().UTC().Format(time.RFC3339), build)), s.priv)
	bin := kvsctlCopy(t)
	before, err := os.ReadFile(bin)
	if err != nil {
		t.Fatal(err)
	}
	update := s.kvsctlFrom(bin, "update-cli")
	if code := update.wait(); code != 1 {
		t.Errorf("update-cli: %s, want exit 1; it printed:\n%s", update.status, update.output())
	}
	contains(t, "update-cli", update.output(), "goes past the 10 bytes the signed manifest gives: refused", " is unchanged")
	unchanged(t, bin, before)
}

// update-cli --quiet prints nothing when it has nothing to do or replaced
// the binary, the way a cron job wants it, and its failure all the same.
func TestKvsctlUpdateCLIQuiet(t *testing.T) {
	s := e2eStack(t)
	publish := func(version, build string) {
		s.sign([]byte(fmt.Sprintf(`{"schema":2,"channel":"stable","updated":"%s","releases":[{"version":"%s","cli":%s}]}`, time.Now().UTC().Format(time.RFC3339), version, build)), s.priv)
	}
	// What a run printed but the notice of the keys the tests sign with,
	// which every command gives.
	said := func(run *kvsctlRun) string {
		var lines []string
		for _, line := range strings.Split(strings.TrimSpace(run.output()), "\n") {
			if line != "" && !strings.Contains(line, "release keys from KVSCTL_RELEASE_KEY") {
				lines = append(lines, line)
			}
		}
		return strings.Join(lines, "\n")
	}
	bin := releaseKvsctl(t, "9.9.8")
	for _, c := range []struct {
		what, version, build string
		code                 int
		want                 string
	}{
		{"nothing to do", "9.9.8", cliBuild(t, "9.9.8"), 0, ""},
		{"a build past its signed size", "9.9.9", regexp.MustCompile(`"size":\d+`).ReplaceAllString(cliBuild(t, "9.9.9"), `"size":10`), 1, "goes past the 10 bytes the signed manifest gives: refused"},
		{"a new build", "9.9.9", cliBuild(t, "9.9.9"), 0, ""},
	} {
		publish(c.version, c.build)
		update := s.kvsctlFrom(bin, "update-cli", "--quiet")
		if code := update.wait(); code != c.code {
			t.Errorf("%s: %s, want exit %d; it printed:\n%s", c.what, update.status, c.code, update.output())
		}
		if got := said(update); (c.want == "" && got != "") || !strings.Contains(got, c.want) {
			t.Errorf("%s: it printed %q, want %q", c.what, got, c.want)
		}
	}
	if out, err := exec.Command(bin, "version").Output(); err != nil || string(out) != "kvsctl 9.9.9 (linux/amd64)\n" {
		t.Errorf("the binary says %q (%v), want the build of 9.9.9", out, err)
	}
}

// A Ctrl-C ends the read of a manifest that never comes at once, in every
// command that plans: nothing has changed yet, and there is nothing to wait
// for.
func TestKvsctlCtrlCStopsTheReadOfTheManifest(t *testing.T) {
	s := e2eStack(t)
	for _, c := range []struct {
		args []string
		bin  string
		want string
	}{
		{[]string{"check"}, "", "kvsctl: interrupted"},
		{[]string{"upgrade", "--yes", "--plain"}, "", "upgrade interrupted while it was being planned, nothing was changed"},
		{[]string{"update-cli"}, kvsctlCopy(t), "kvsctl: interrupted, this binary is unchanged"},
	} {
		addr, asked := silentServer(t)
		args := append(slices.Clone(c.args), "--manifest", "http://"+addr+"/manifest.json")
		var run *kvsctlRun
		if c.bin == "" {
			run = s.kvsctl(pipes, args...)
		} else {
			run = s.kvsctlFrom(c.bin, args...)
		}
		select {
		case <-asked:
		case <-run.exited:
			t.Fatalf("%s ended (%s) before it read the manifest; it printed:\n%s", c.args[0], run.status, run.output())
		case <-time.After(time.Minute):
			t.Fatalf("%s did not read the manifest after a minute; it printed:\n%s", c.args[0], run.output())
		}
		if err := run.cmd.Process.Signal(os.Interrupt); err != nil {
			t.Fatal(err)
		}
		select {
		case <-run.exited:
		case <-time.After(10 * time.Second):
			t.Fatalf("%s still waits for the manifest 10 seconds after the Ctrl-C; it printed:\n%s", c.args[0], run.output())
		}
		if code := run.wait(); code != 1 {
			t.Errorf("%s: %s, want exit 1; it printed:\n%s", c.args[0], run.status, run.output())
		}
		contains(t, c.args[0], run.output(), c.want)
	}
}

// status catches Ctrl-C to finish cleanly, and the read of the manifest
// for its Updates line ends at it all the same; the update reminder after
// it then reads nothing.
func TestKvsctlStatusEndsAtCtrlC(t *testing.T) {
	s := e2eStack(t)
	addr, asked := silentServer(t)
	run := s.kvsctl(pipes, "status", "--manifest", "http://"+addr+"/manifest.json")
	select {
	case <-asked:
	case <-run.exited:
		t.Fatalf("status ended (%s) before it read the manifest; it printed:\n%s", run.status, run.output())
	case <-time.After(time.Minute):
		t.Fatalf("status did not read the manifest after a minute; it printed:\n%s", run.output())
	}
	if err := run.cmd.Process.Signal(os.Interrupt); err != nil {
		t.Fatal(err)
	}
	select {
	case <-run.exited:
	case <-time.After(10 * time.Second):
		t.Fatalf("status still waits for the manifest 10 seconds after the Ctrl-C; it printed:\n%s", run.output())
	}
	contains(t, "status", run.output(), "interrupted")
}

// A release build of kvsctl holds back a release that needs a newer one:
// check names the update-cli to run first, and upgrade stops there with
// nothing changed.
func TestKvsctlHoldsBackAReleaseThatNeedsANewerKvsctl(t *testing.T) {
	s := e2eStack(t)
	s.release("1.1.0").Requires.KvsctlMin = "9.0.0"
	s.writeManifest()
	bin := releaseKvsctl(t, "1.0.0")
	want := "1.1.0 needs kvsctl 9.0.0 or newer, and this is kvsctl 1.0.0: run 'kvsctl update-cli --manifest file://" + filepath.Join(s.dir, "manifest.json") + "' first"
	check := s.kvsctlFrom(bin, "check")
	if code := check.wait(); code != 0 {
		t.Errorf("check: %s, want exit 0; it printed:\n%s", check.status, check.output())
	}
	contains(t, "check", check.output(), want)
	up := s.kvsctlFrom(bin, "upgrade", "--yes", "--plain")
	if code := up.wait(); code != 3 {
		t.Errorf("upgrade: %s, want exit 3; it printed:\n%s", up.status, up.output())
	}
	contains(t, "upgrade", up.output(), want)
	if state := s.state(); state.Current != "1.0.0" || state.Previous != "" {
		t.Errorf("the state moved: current %s, previous %s", state.Current, state.Previous)
	}
}

// A stack that runs a release candidate newer than every stable release
// stays on it: the upgrade a cron job runs without a version has nothing to
// do, and says so with exit 0.
func TestKvsctlUpgradeLeavesAStackOnItsCandidate(t *testing.T) {
	s := newStack(t, "", rel{version: "1.2.0-rc1"}, rel{version: "1.0.0"}, rel{version: "1.1.0"})
	for _, images := range s.images {
		for _, img := range images {
			s.f.behave(img.Ref, behavior{})
		}
	}
	s.republish(func(m *manifest.Manifest) { m.Channel = manifest.ChannelCandidate })
	up := s.kvsctl(pipes, "upgrade", "--yes", "--plain")
	if code := up.wait(); code != 0 {
		t.Errorf("upgrade: %s, want exit 0; it printed:\n%s", up.status, up.output())
	}
	contains(t, "upgrade", up.output(), "Already on 1.2.0-rc1")
	if state := s.state(); state.Current != "1.2.0-rc1" {
		t.Errorf("the state moved to %s", state.Current)
	}
}

// A mirror the operator names may serve the list of a release candidate
// for a while, signed after the stable list: the stable list it serves
// again afterwards is no stale manifest.
func TestKvsctlCheckTakesTheStableListBackAfterACandidateList(t *testing.T) {
	s := e2eStack(t)
	signed := time.Now().UTC().Add(-time.Hour).Format(time.RFC3339)
	s.republish(func(m *manifest.Manifest) { m.Updated = signed })
	s.addRelease(rel{version: "1.2.0-rc1"})
	stable := s.releases[:len(s.releases)-1]
	for _, step := range []struct {
		what   string
		change func(m *manifest.Manifest)
	}{
		{"the stable list", func(m *manifest.Manifest) { m.Releases, m.Updated = stable, signed }},
		{"the list of a candidate, signed after it", func(m *manifest.Manifest) { m.Channel = manifest.ChannelCandidate }},
		{"the stable list again", func(m *manifest.Manifest) { m.Releases, m.Updated = stable, signed }},
	} {
		s.republish(step.change)
		check := s.kvsctl(pipes, "check")
		if code := check.wait(); code != 0 {
			t.Errorf("%s: %s, want exit 0; it printed:\n%s", step.what, check.status, check.output())
		}
	}
}

// check with an engine that does not answer says so once, and nothing of
// what it could not read: no service, no download, no disk, no health.
func TestKvsctlCheckSaysOnlyThatTheEngineDoesNotAnswer(t *testing.T) {
	s := e2eStack(t)
	s.f.with(func(f *fakeDocker) {
		f.refusal = "Cannot connect to the Docker daemon at unix:///var/run/docker.sock. Is the docker daemon running?"
	})
	check := s.kvsctl(pipes, "check")
	if code := check.wait(); code != 0 {
		t.Errorf("check: %s, want exit 0; it printed:\n%s", check.status, check.output())
	}
	out := check.output()
	contains(t, "check", out, "Target       1.1.0 (2026-10-01)\nBlocked\n  - kvsctl cannot talk to the Docker engine (")
	if n := strings.Count(out, "\n  - "); n != 1 {
		t.Errorf("%d blockers, want one:\n%s", n, out)
	}
	for _, guess := range []string{"Download", "Disk", "Health", "Running", "MariaDB", "Ready"} {
		if strings.Contains(out, "\n"+guess) {
			t.Errorf("check prints %s of an engine it could not read:\n%s", guess, out)
		}
	}
}

// check prints, after what it measured on disk, what it could not measure
// and why, the room the rollback of a one-way upgrade needs included, and
// holds nothing against the machine for it.
func TestKvsctlCheckSaysWhatItCouldNotMeasure(t *testing.T) {
	s := e2eStack(t)
	s.f.with(func(f *fakeDocker) {
		f.hook = func(_ *fakeDocker, req cliRequest) (cliResponse, bool) {
			if req.Args[0] == "exec" && strings.Contains(req.Args[len(req.Args)-1], "SUM(data_length + index_length)") {
				return cliResponse{Stderr: "ERROR 1045 (28000): Access denied\n", Code: 1}, true
			}
			return cliResponse{}, false
		}
	})
	check := s.kvsctl(pipes, "check", "--mariadb-series", "12.3")
	if code := check.wait(); code != 0 {
		t.Errorf("check: %s, want exit 0; it printed:\n%s", check.status, check.output())
	}
	out := check.output()
	unknown := regexp.MustCompile(`(?m)^Disk +\S.*\n(?: +.*\n)* +not measured: a second copy of the database, which a rollback of this one-way upgrade replays while the files of the new server stay in the volume: the size of the database could not be read \(.*Access denied.*\)\n`)
	if !unknown.MatchString(out) {
		t.Errorf("check does not say, after its Disk lines, that the room of the rollback was not measured:\n%s", out)
	}
	if strings.Contains(out, "\nBlocked") || !strings.Contains(out, "\nReady") {
		t.Errorf("a room that could not be measured blocks the upgrade:\n%s", out)
	}
}

// status warns of a signing key the manifest announces and this kvsctl
// does not carry, with the day it signs from.
func TestKvsctlStatusWarnsOfAnAnnouncedKey(t *testing.T) {
	s := e2eStack(t)
	next, _, err := ed25519.GenerateKey(nil)
	if err != nil {
		t.Fatal(err)
	}
	s.republish(func(m *manifest.Manifest) {
		m.Keys = []manifest.Key{{ID: "r9", Pub: base64.StdEncoding.EncodeToString(next), ValidFrom: "2026-12-01"}}
	})
	status := s.kvsctl(pipes, "status")
	if code := status.wait(); code != 0 {
		t.Fatalf("status: %s; it printed:\n%s", status.status, status.output())
	}
	contains(t, "status", status.output(), "Signing key  the manifest announces signing key r9 from 2026-12-01, unknown to this kvsctl: run 'kvsctl update-cli' before then")
}
