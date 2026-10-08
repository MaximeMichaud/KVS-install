package main

import (
	"bytes"
	"context"
	"crypto/ed25519"
	"encoding/base64"
	"encoding/json"
	"errors"
	"fmt"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"syscall"
	"testing"
	"time"

	"github.com/spf13/cobra"

	"github.com/MaximeMichaud/KVS-install/cli/internal/backup"
	"github.com/MaximeMichaud/KVS-install/cli/internal/diskspace"
	"github.com/MaximeMichaud/KVS-install/cli/internal/instance"
	"github.com/MaximeMichaud/KVS-install/cli/internal/manifest"
	"github.com/MaximeMichaud/KVS-install/cli/internal/upgrade"
)

// useStderr catches what kvsctl says on stderr, and says the notice of
// the release keys again, for the length of the test.
func useStderr(t *testing.T) *bytes.Buffer {
	t.Helper()
	old, oldOnce := stderr, keyNoticeOnce
	out := &bytes.Buffer{}
	stderr, keyNoticeOnce = out, new(sync.Once)
	t.Cleanup(func() { stderr, keyNoticeOnce = old, oldOnce })
	return out
}

// KVSCTL_RELEASE_KEY replaces the keys this build embeds, which kvsctl
// says once per run on stderr and in the log of the run; without it,
// nothing is said.
func TestReleaseKeyNotice(t *testing.T) {
	errOut := useStderr(t)
	t.Setenv(releaseKeyEnv, "")
	if keys, err := publicKeys(); err != nil || len(keys) == 0 || errOut.Len() != 0 {
		t.Fatalf("the embedded keys: %d keys, %v, said %q", len(keys), err, errOut.String())
	}
	pub, _, err := ed25519.GenerateKey(nil)
	if err != nil {
		t.Fatal(err)
	}
	t.Setenv(releaseKeyEnv, base64.StdEncoding.EncodeToString(pub))
	for i := 0; i < 2; i++ {
		keys, err := publicKeys()
		if err != nil || len(keys) != 1 || manifest.KeyID(keys[0]) != manifest.KeyID(pub) {
			t.Fatalf("the keys of %s: %d keys, %v", releaseKeyEnv, len(keys), err)
		}
	}
	want := "kvsctl: release keys from KVSCTL_RELEASE_KEY, not the ones this build embeds\n"
	if errOut.String() != want {
		t.Fatalf("stderr %q, want %q once", errOut.String(), want)
	}
	s := testSession(t, newRoot(t))
	path := s.log.Path()
	if err := s.finish(nil); err != nil {
		t.Fatal(err)
	}
	data, err := os.ReadFile(path)
	if err != nil {
		t.Fatal(err)
	}
	if !strings.Contains(string(data), "release keys from KVSCTL_RELEASE_KEY, not the ones this build embeds") {
		t.Fatalf("the log lacks the notice:\n%s", data)
	}
}

// --quiet leaves out the reminder and the progress of a run, never the
// notice that KVSCTL_RELEASE_KEY replaced the keys this build embeds, and
// its help says so.
func TestQuietKeepsTheReleaseKeyNotice(t *testing.T) {
	root := newRoot(t)
	url := signedManifest(t, testRelease("1.0.0", "2026-09-01", ""))
	errOut := useStderr(t)
	out, err := runKvsctl(t, "releases", "--root", root, "--manifest", url, "--quiet")
	if err != nil || !strings.Contains(out, "1.0.0") {
		t.Fatalf("releases --quiet: %v, printed %q", err, out)
	}
	if want := "kvsctl: release keys from KVSCTL_RELEASE_KEY, not the ones this build embeds\n"; errOut.String() != want {
		t.Errorf("releases --quiet said %q on stderr, want %q", errOut.String(), want)
	}
	if usage := rootCmd().PersistentFlags().Lookup("quiet").Usage; !strings.Contains(usage, "the notice that KVSCTL_RELEASE_KEY replaces the release keys is printed all the same") {
		t.Errorf("the help of --quiet does not say that the notice stays: %s", usage)
	}
}

// testRelease is a release the manifests of the tests list: one image and
// a bundle, as the manifest requires.
func testRelease(version, date, commit string) manifest.Release {
	return manifest.Release{
		Version: version,
		Date:    date,
		Commit:  commit,
		Bundle:  manifest.Asset{URL: "https://example.com/" + version + ".tar.gz", SHA256: strings.Repeat("0", 64)},
		Images:  []manifest.Image{{Service: "nginx", Ref: "example/nginx:" + version, Digest: "sha256:" + strings.Repeat("1", 64)}},
	}
}

// signedManifest signs a manifest of releases with a key of its own, which
// KVSCTL_RELEASE_KEY trusts for the test, writes it beside its signature,
// and points --manifest at it.
func signedManifest(t *testing.T, releases ...manifest.Release) string {
	t.Helper()
	return signedManifestOf(t, manifest.Schema, releases...)
}

// signedManifestOf is signedManifest with the schema the manifest says it
// follows.
func signedManifestOf(t *testing.T, schema int, releases ...manifest.Release) string {
	t.Helper()
	pub, priv, err := ed25519.GenerateKey(nil)
	if err != nil {
		t.Fatal(err)
	}
	t.Setenv(releaseKeyEnv, base64.StdEncoding.EncodeToString(pub))
	raw, err := json.Marshal(manifest.Manifest{Schema: schema, Channel: "stable", Updated: time.Now().UTC().Format(time.RFC3339), Releases: releases})
	if err != nil {
		t.Fatal(err)
	}
	sig, err := json.Marshal(manifest.Signature{KeyID: manifest.KeyID(pub), Alg: manifest.AlgEd25519, Sig: base64.StdEncoding.EncodeToString(ed25519.Sign(priv, raw))})
	if err != nil {
		t.Fatal(err)
	}
	path := filepath.Join(t.TempDir(), "manifest.json")
	if err := os.WriteFile(path, raw, 0o644); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(path+".sig", sig, 0o644); err != nil {
		t.Fatal(err)
	}
	useManifest(t, "file://"+path)
	return "file://" + path
}

// useManifest points --manifest at url for the length of the test.
func useManifest(t *testing.T, url string) {
	t.Helper()
	old := flagManifest
	flagManifest = url
	t.Cleanup(func() { flagManifest = old })
}

// saveState records state for the installation at root.
func saveState(t *testing.T, root string, state *instance.State) *instance.Instance {
	t.Helper()
	inst, err := instance.Detect(root)
	if err != nil {
		t.Fatal(err)
	}
	if err := inst.SaveState(state); err != nil {
		t.Fatal(err)
	}
	return inst
}

// reminded is what remind says on stderr after command, without the
// notice of the release keys the tests sign with.
func reminded(t *testing.T, command string) string {
	t.Helper()
	errOut := useStderr(t)
	remind(&cobra.Command{Use: command})
	var lines []string
	for _, line := range strings.Split(strings.TrimSpace(errOut.String()), "\n") {
		if line != "" && !strings.Contains(line, "release keys from "+releaseKeyEnv) {
			lines = append(lines, line)
		}
	}
	return strings.Join(lines, "\n")
}

// The reminder never says to run 'kvsctl upgrade', which only a plan made
// now knows would run: it points at 'kvsctl check', which makes that plan
// and ends with the upgrade to run, unless what kvsctl sees from here comes
// first: recover after an interrupted run, the end of the kvsctl that holds
// the lock, the cause of the upgrade that just failed. A cancelled run left
// nothing to fix. A release older than the git checkout the stack runs is
// no news at all, since no upgrade installs it. The commands named carry
// the installation and the manifest the command was given.
func TestRemindNamesWhatComesFirst(t *testing.T) {
	root := newRoot(t)
	useRoot(t, root)
	url := signedManifest(t, testRelease("1.1.0", "2026-10-01T12:00:00Z", strings.Repeat("a", 40)), testRelease("1.0.0", "2026-09-01", ""))
	inst := saveState(t, root, &instance.State{Current: "1.0.0", Files: []string{"docker/docker-compose.yml"}})
	check := "kvsctl check --root " + root + " --manifest " + url
	if got, want := reminded(t, "history"), "1.1.0 is available, run '"+check+"'"; got != want {
		t.Fatalf("a stack one release behind: %q, want %q", got, want)
	}

	j := interruptedJournal(t, root)
	if got, want := reminded(t, "history"), "1.1.0 is available, run 'kvsctl recover --root "+root+"' first: a run was interrupted"; got != want {
		t.Fatalf("with the journal of %s: %q, want %q", j.Action, got, want)
	}
	if err := inst.RemoveJournal(); err != nil {
		t.Fatal(err)
	}

	unlock, err := inst.Lock("upgrade")
	if err != nil {
		t.Fatal(err)
	}
	got := reminded(t, "history")
	unlock()
	if want := fmt.Sprintf("1.1.0 is available, run '%s' once the kvsctl running now ends: another kvsctl is running (pid %d, upgrade, started just now)", check, os.Getpid()); got != want {
		t.Fatalf("with the lock held: %q, want %q", got, want)
	}

	saveState(t, root, &instance.State{Current: "1.0.0", History: []instance.Entry{
		{Version: "1.0.0", Action: "adopt", Date: failedAt.Add(-time.Hour)},
		{Version: "1.0.0", Action: instance.ActionRollback, Date: failedAt, Note: "1.1.0 failed: not healthy after 1s: kvs-nginx is unhealthy"},
	}})
	if got, want := reminded(t, "history"), "1.1.0 is available, run '"+check+"' once the cause is fixed: the last upgrade to 1.1.0 failed on 2026-10-07 00:57 UTC and was rolled back (not healthy after 1s: kvs-nginx is unhealthy)"; got != want {
		t.Fatalf("after a failed upgrade: %q, want %q", got, want)
	}
	saveState(t, root, undoneState("1.1.0 failed: docker compose up -d: context canceled (signal: terminated)"))
	if got, want := reminded(t, "history"), "1.1.0 is available, run '"+check+"'"; got != want {
		t.Fatalf("after a cancelled upgrade: %q, want %q", got, want)
	}

	saveState(t, root, &instance.State{
		Current:           instance.Unreleased,
		AdoptedCommit:     strings.Repeat("b", 40),
		AdoptedCommitDate: time.Date(2026, 10, 1, 12, 0, 1, 0, time.UTC),
		History:           []instance.Entry{{Version: instance.Unreleased, Action: "adopt", Date: failedAt}},
	})
	if got := reminded(t, "history"); got != "" {
		t.Fatalf("a checkout newer than the latest release is told %q", got)
	}

	saveState(t, root, &instance.State{Current: "1.1.0"})
	if got := reminded(t, "history"); got != "" {
		t.Fatalf("a stack on the latest release is told %q", got)
	}
}

// A manifest this kvsctl can no longer read is the one failure the
// reminder tells: no upgrade runs before update-cli. The failure kept for
// the hour tells it again.
func TestRemindAsksForUpdateCLI(t *testing.T) {
	root := newRoot(t)
	useRoot(t, root)
	signedManifestOf(t, manifest.Schema+1, testRelease("1.1.0", "2026-10-01", ""))
	saveState(t, root, &instance.State{Current: "1.0.0"})
	for _, read := range []string{"read now", "kept for the hour"} {
		if got := reminded(t, "history"); !strings.HasPrefix(got, "kvsctl: this manifest needs a newer kvsctl") || !strings.HasSuffix(got, ": run 'kvsctl update-cli'") {
			t.Fatalf("a manifest of a newer schema, %s: %q", read, got)
		}
	}
}

// status says what a newer release means on its Updates line, and check
// in its verdict: after either, the reminder would repeat it, or worse,
// point at the upgrade check has just shown blocked. An upgrade made its
// own plan of the manifest, complete or not.
func TestRemindLeavesStatusAndCheckAlone(t *testing.T) {
	root := newRoot(t)
	useRoot(t, root)
	signedManifest(t, testRelease("1.1.0", "2026-10-01", ""), testRelease("1.0.0", "2026-09-01", ""))
	saveState(t, root, &instance.State{Current: "1.0.0"})
	for _, command := range []string{"status", "check", "upgrade"} {
		if got := reminded(t, command); got != "" {
			t.Errorf("after %s the reminder says %q", command, got)
		}
	}
	if got := reminded(t, "releases"); got == "" {
		t.Fatal("the reminder is silent after releases")
	}
}

// A manifest server that does not answer holds a command for one short
// wait, not for the 30 s of each file, and the failure is remembered for
// an hour: the next commands answer from it without asking the server.
// A read that works is kept for the day.
func TestLatestReleaseRemembersAServerThatDoesNotAnswer(t *testing.T) {
	root := newRoot(t)
	useRoot(t, root)
	useStderr(t)
	inst := saveState(t, root, &instance.State{Current: "1.0.0"})
	var mu sync.Mutex
	requests := 0
	release := make(chan struct{})
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		mu.Lock()
		requests++
		mu.Unlock()
		<-release
	}))
	t.Cleanup(server.Close)
	t.Cleanup(func() { close(release) })
	useManifest(t, server.URL+"/manifest.json")
	old := reminderWait
	reminderWait = 300 * time.Millisecond
	t.Cleanup(func() { reminderWait = old })
	start := time.Now()
	if _, err := latestRelease(inst, reminderWait, manifest.Fetch); err == nil || time.Since(start) > 5*time.Second {
		t.Fatalf("a server that does not answer: %v after %s", err, time.Since(start))
	}
	start = time.Now()
	_, err := latestRelease(inst, reminderWait, manifest.Fetch)
	var earlier *earlierFailure
	if !errors.As(err, &earlier) || time.Since(start) > time.Second {
		t.Fatalf("the second read: %v after %s, want the failure remembered", err, time.Since(start))
	}
	mu.Lock()
	asked := requests
	mu.Unlock()
	if asked != 1 {
		t.Fatalf("the server was asked %d times, want once", asked)
	}
	if got := updatesLine(inst, &instance.State{Current: "1.0.0"}, latestKnown{}, err, ""); !strings.HasPrefix(got, "could not check at ") || !strings.Contains(got, "did not answer within 300ms") {
		t.Fatalf("status says %q", got)
	}

	// An hour later the server is asked again, and what it answers is
	// kept for the day.
	known := loadLatestKnown(inst)
	known[server.URL+"/manifest.json"].Failed = time.Now().Add(-failureFor - time.Minute)
	saveLatestKnown(inst, known)
	url := signedManifest(t, testRelease("1.1.0", "2026-10-01", ""), testRelease("1.0.0", "2026-09-01", ""))
	known = loadLatestKnown(inst)
	known[url] = known[server.URL+"/manifest.json"]
	saveLatestKnown(inst, known)
	latest, err := latestRelease(inst, reminderWait, manifest.Fetch)
	if err != nil || latest.Version != "1.1.0" {
		t.Fatalf("after the hour: %+v, %v", latest, err)
	}
	if err := os.Remove(strings.TrimPrefix(url, "file://")); err != nil {
		t.Fatal(err)
	}
	if latest, err := latestRelease(inst, reminderWait, manifest.Fetch); err != nil || latest.Version != "1.1.0" {
		t.Fatalf("the read of the day was not kept: %+v, %v", latest, err)
	}
}

// The reminder holds a command for its own short wait at most, whatever
// wait the manifest server would take: the command was not run for it.
func TestRemindWaitsBriefly(t *testing.T) {
	root := newRoot(t)
	useRoot(t, root)
	saveState(t, root, &instance.State{Current: "1.0.0"})
	release := make(chan struct{})
	server := httptest.NewServer(http.HandlerFunc(func(http.ResponseWriter, *http.Request) { <-release }))
	t.Cleanup(server.Close)
	t.Cleanup(func() { close(release) })
	useManifest(t, server.URL+"/manifest.json")
	old := reminderWait
	reminderWait = 200 * time.Millisecond
	t.Cleanup(func() { reminderWait = old })
	start := time.Now()
	if got := reminded(t, "history"); got != "" {
		t.Fatalf("a manifest server that does not answer is told %q", got)
	}
	if took := time.Since(start); took > 3*time.Second {
		t.Fatalf("the reminder held the command %s", took)
	}
}

// A read dated after now, which a clock set back leaves behind, answers
// for nothing: the manifest is read again, and so it is after a failure
// dated after now, which would otherwise keep the reminder silent until
// the clock passed it.
func TestLatestReleaseDistrustsAReadDatedLater(t *testing.T) {
	root := newRoot(t)
	useRoot(t, root)
	useStderr(t)
	inst := saveState(t, root, &instance.State{Current: "1.0.0"})
	url := signedManifest(t, testRelease("1.1.0", "2026-10-01", ""), testRelease("1.0.0", "2026-09-01", ""))
	later := time.Now().Add(48 * time.Hour)
	for name, known := range map[string]*latestKnown{
		"a read":    {Read: later, Version: "1.0.0"},
		"a failure": {Failed: later, Error: "EOF", Build: thisBuild()},
	} {
		saveLatestKnown(inst, map[string]*latestKnown{url: known})
		if latest, err := latestRelease(inst, reminderWait, manifest.Fetch); err != nil || latest.Version != "1.1.0" {
			t.Errorf("%s dated later: %+v, %v", name, latest, err)
		}
	}
}

// status and the reminder read the URL of the latest release as check
// does: the list of a release candidate there, a candidate published as
// the latest release by mistake, announces no release.
func TestLatestReleaseRefusesACandidateListAtTheDefaultURL(t *testing.T) {
	root := newRoot(t)
	useRoot(t, root)
	useStderr(t)
	inst := saveState(t, root, &instance.State{Current: "1.0.0"})
	file := signedManifest(t, testRelease("1.1.0-rc1", "2026-10-01", ""), testRelease("1.0.0", "2026-09-01", ""))
	useManifest(t, "")
	t.Setenv("KVSCTL_MANIFEST_URL", "")
	var asked []string
	read := func(url string) (*manifest.Document, error) {
		asked = append(asked, url)
		return manifest.Fetch(file)
	}
	latest, err := latestRelease(inst, reminderWait, read)
	if err == nil || !strings.Contains(err.Error(), "names the release candidate 1.1.0-rc1 as its newest release, and that URL serves stable releases only") || latest.Version != "" {
		t.Fatalf("a candidate list at the default URL: %+v, %v", latest, err)
	}
	if len(asked) != 1 || asked[0] != DefaultManifestURL {
		t.Fatalf("read %v, want the default URL", asked)
	}
	if got := updatesLine(inst, &instance.State{Current: "1.0.0"}, latest, err, ""); !strings.HasPrefix(got, "could not check (the manifest at "+DefaultManifestURL+" names the release candidate 1.1.0-rc1") {
		t.Fatalf("status says %q", got)
	}
}

// The last line of a failed command drops the separator a docker command
// leaves when it wrote nothing on stderr, before the log a quiet run names
// too, and so does the error that names the log.
func TestFailDropsAnEmptyDetail(t *testing.T) {
	const raw = "docker exec kvs-mariadb: exit status 1: "
	var out bytes.Buffer
	if code := fail(&out, fmt.Errorf("backup: %w", errors.New(raw))); code != exitError || out.String() != "kvsctl: backup: docker exec kvs-mariadb: exit status 1\n" {
		t.Fatalf("exit %d, printed %q", code, out.String())
	}
	if got, want := namedLog(errors.New(raw), "/x.log").Error(), "docker exec kvs-mariadb: exit status 1; log: /x.log"; got != want {
		t.Fatalf("the error that names the log reads %q, want %q", got, want)
	}
	out.Reset()
	if code := fail(&out, namedLog(errors.New(raw), "/opt/kvs/kvsctl/logs/x.log")); code != exitError || out.String() != "kvsctl: docker exec kvs-mariadb: exit status 1; log: /opt/kvs/kvsctl/logs/x.log\n" {
		t.Fatalf("a quiet run: exit %d, printed %q", code, out.String())
	}
	out.Reset()
	if code := fail(&out, upgrade.ErrBlocked); code != exitBlocked || out.String() != "kvsctl: "+upgrade.ErrBlocked.Error()+"\n" {
		t.Fatalf("a blocked upgrade: exit %d, printed %q", code, out.String())
	}
}

// A list older than one already read, which --allow-stale-manifest lets a
// check or an upgrade through, does not take the newest release back; a
// read clears the failure it follows.
func TestRecordKeepsTheNewestRelease(t *testing.T) {
	now := time.Now()
	k := &latestKnown{Version: "1.2.0", Date: "2026-10-05", Commit: "c12", MinFrom: map[string]string{"1.2.0": "1.1.0"}, Failed: now.Add(-time.Minute), Error: "EOF"}
	k.record(&manifest.Manifest{Releases: []manifest.Release{{Version: "1.1.0", Date: "2026-10-01", Commit: "c11"}}}, now)
	if k.Version != "1.2.0" || k.Date != "2026-10-05" || k.Commit != "c12" || k.MinFrom["1.2.0"] != "1.1.0" || !k.Read.Equal(now) || !k.Failed.IsZero() || k.Error != "" {
		t.Fatalf("an older list recorded %+v", k)
	}
	k.record(&manifest.Manifest{Releases: []manifest.Release{
		{Version: "1.3.0", Date: "2026-10-09", Commit: "c13", Requires: manifest.Requires{MinFrom: "1.2.0"}},
		{Version: "1.2.0", Date: "2026-10-05", Commit: "c12"},
	}}, now)
	if k.Version != "1.3.0" || k.Date != "2026-10-09" || k.Commit != "c13" || len(k.MinFrom) != 1 || k.MinFrom["1.3.0"] != "1.2.0" {
		t.Fatalf("a newer list recorded %+v", k)
	}
}

// The first stop is the one the plan of the upgrade names: the oldest
// version the first release on the way upgrades from, when the stack is
// older than that.
func TestFirstStop(t *testing.T) {
	latest := latestKnown{Version: "1.4.0", MinFrom: map[string]string{"0.9.0": "0.8.0", "1.2.0": "1.1.0", "1.4.0": "1.3.0", "1.5.0": "1.4.0"}}
	for current, want := range map[string]string{"0.5.0": "0.8.0", "1.0.0": "1.1.0", "1.1.0": "1.3.0", "1.2.0": "1.3.0", "1.3.0": "", "1.4.0": ""} {
		if got := firstStop(current, latest); got != want {
			t.Errorf("from %s the first stop is %q, want %q", current, got, want)
		}
	}
}

// A release the stack cannot upgrade to directly is reached through the
// stop the plan names: the reminder has that release checked first, as
// the upgrade would.
func TestRemindNamesTheStop(t *testing.T) {
	root := newRoot(t)
	useRoot(t, root)
	target := testRelease("1.2.0", "2026-10-05", "")
	target.Requires.MinFrom = "1.1.0"
	url := signedManifest(t, target, testRelease("1.1.0", "2026-10-01", ""), testRelease("1.0.0", "2026-09-01", ""))
	saveState(t, root, &instance.State{Current: "1.0.0"})
	check := "kvsctl check --root " + root + " --manifest " + url
	if got, want := reminded(t, "history"), "1.2.0 is available, run '"+check+" --version 1.1.0' first: 1.2.0 cannot be installed directly from 1.0.0"; got != want {
		t.Fatalf("a stack two releases behind: %q, want %q", got, want)
	}
	saveState(t, root, &instance.State{Current: "1.0.0", History: []instance.Entry{
		{Version: "1.0.0", Action: instance.ActionRollback, Date: failedAt, Note: "1.1.0 failed: not healthy after 1s"},
	}})
	if got, want := reminded(t, "history"), "1.2.0 is available, run '"+check+" --version 1.1.0' once the cause is fixed: the last upgrade to 1.1.0 failed on 2026-10-07 00:57 UTC and was rolled back (not healthy after 1s)"; got != want {
		t.Fatalf("after the upgrade to the stop failed: %q, want %q", got, want)
	}
	saveState(t, root, &instance.State{Current: "1.1.0"})
	if got, want := reminded(t, "history"), "1.2.0 is available, run '"+check+"'"; got != want {
		t.Fatalf("a stack on the stop: %q, want %q", got, want)
	}
}

// useCreateBackup stands create in for the archive maker of backup, for
// the length of the test.
func useCreateBackup(t *testing.T, create func(ctx context.Context, dir string, report func(string)) (*backup.Result, error)) {
	t.Helper()
	old := createBackup
	createBackup = func(ctx context.Context, dir, _, _, _, _ string, report func(string), _ ...backup.Option) (*backup.Result, error) {
		return create(ctx, dir, report)
	}
	t.Cleanup(func() { createBackup = old })
}

// A backup an interrupt stopped says so, and that it kept nothing, rather
// than ending with the error of the docker exec it cut short, which wraps
// the cause of the context as dockerx.Exec does.
func TestBackupInterrupted(t *testing.T) {
	s := testSession(t, newRoot(t))
	useCreateBackup(t, func(ctx context.Context, dir string, report func(string)) (*backup.Result, error) {
		report("dumping the database")
		s.guard.cancel()
		<-ctx.Done()
		return nil, fmt.Errorf("docker exec kvs-mariadb: %w (signal: terminated): ", context.Cause(ctx))
	})
	if err := runBackup(s, 5); err == nil || err.Error() != "backup interrupted, no archive was kept" {
		t.Fatalf("an interrupted backup ends with %v", err)
	}
}

// An interrupt that comes once the archive is written keeps it, and the
// backup says so: a failure after the archive took its name is said as it
// is, and an archive complete when the interrupt came is kept without the
// prune the interrupt stopped.
func TestBackupInterruptedOnceTheArchiveIsWritten(t *testing.T) {
	s := testSession(t, newRoot(t))
	path := filepath.Join(s.inst.BackupDir(), "backup-unknown-20261007-010600.tar")
	pruned := false
	old := pruneBackups
	pruneBackups = func(string, int, ...string) ([]string, error) {
		pruned = true
		return nil, nil
	}
	t.Cleanup(func() { pruneBackups = old })
	unflushed := fmt.Errorf("%s is written but its directory could not be flushed: %w", path, syscall.EIO)
	useCreateBackup(t, func(context.Context, string, func(string)) (*backup.Result, error) {
		s.guard.cancel()
		return nil, unflushed
	})
	if err := runBackup(s, 5); err == nil || err.Error() != unflushed.Error() {
		t.Errorf("an interrupted backup whose directory was not flushed ends with %v, want %v", err, unflushed)
	}
	useCreateBackup(t, func(context.Context, string, func(string)) (*backup.Result, error) {
		s.guard.cancel()
		return &backup.Result{Path: path, Size: 3}, nil
	})
	want := "backup interrupted once " + path + " was written: the archive is kept, and the older backups were not pruned"
	if err := runBackup(s, 5); err == nil || err.Error() != want || exitCode(err) != exitError || pruned {
		t.Errorf("a backup interrupted once its archive was written ends with %v (pruned %v), want %q", err, pruned, want)
	}
}

// A backup written whose older archives could not all be removed exits 1
// after a change: its message says the archive is there.
func TestBackupSaysTheArchiveIsKeptWhenThePruneFails(t *testing.T) {
	if os.Geteuid() == 0 {
		t.Skip("root removes files from a read-only directory")
	}
	root := newRoot(t)
	s := testSession(t, root)
	dir := s.inst.BackupDir()
	if err := os.MkdirAll(dir, 0o700); err != nil {
		t.Fatal(err)
	}
	old := filepath.Join(dir, "backup-unknown-20200101-000000.tar")
	if err := os.WriteFile(old, []byte("old"), 0o600); err != nil {
		t.Fatal(err)
	}
	path := filepath.Join(dir, "backup-unknown-20261007-010600.tar")
	useCreateBackup(t, func(ctx context.Context, dir string, report func(string)) (*backup.Result, error) {
		if err := os.WriteFile(path, []byte("new"), 0o600); err != nil {
			return nil, err
		}
		// The directory takes no removal from now on, as a sticky one
		// owned by another user does.
		if err := os.Chmod(dir, 0o500); err != nil {
			return nil, err
		}
		return &backup.Result{Path: path, Size: 3}, nil
	})
	t.Cleanup(func() { _ = os.Chmod(dir, 0o700) })
	err := runBackup(s, 1)
	if err == nil || !strings.HasPrefix(err.Error(), path+" is written, but removing the older backups failed: ") || exitCode(err) != exitError {
		t.Fatalf("a backup whose prune failed ends with %v", err)
	}
	if _, serr := os.Stat(path); serr != nil {
		t.Fatalf("the archive is gone: %v", serr)
	}
}

// A prune that removed archives before it failed says how many went: with
// --quiet, nothing else tells.
func TestBackupSaysHowManyArchivesThePruneRemoved(t *testing.T) {
	s := testSession(t, newRoot(t))
	path := filepath.Join(s.inst.BackupDir(), "backup-unknown-20261007-010600.tar")
	useCreateBackup(t, func(context.Context, string, func(string)) (*backup.Result, error) {
		return &backup.Result{Path: path, Size: 3}, nil
	})
	old := pruneBackups
	pruneBackups = func(string, int, ...string) ([]string, error) {
		return []string{"/b/backup-unknown-20200101-000000.tar", "/b/backup-unknown-20200102-000000.tar"}, errors.New("remove /b/backup-unknown-20200103-000000.tar: operation not permitted")
	}
	t.Cleanup(func() { pruneBackups = old })
	want := path + " is written, but removing the older backups failed after 2 of them were removed: remove /b/backup-unknown-20200103-000000.tar: operation not permitted"
	if err := runBackup(s, 1); err == nil || err.Error() != want {
		t.Fatalf("a prune that stopped part way ends with %v, want %q", err, want)
	}
}

// A backup that works is all progress for --quiet: its lines, its archive
// and the archives it removed go to the log, and a cron job mails nothing.
func TestQuietBackupPrintsNothing(t *testing.T) {
	old := flagQuiet
	flagQuiet = true
	t.Cleanup(func() { flagQuiet = old })
	root := newRoot(t)
	s := testSession(t, root)
	out := useRoot(t, root)
	dir := s.inst.BackupDir()
	if err := os.MkdirAll(dir, 0o700); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(dir, "backup-unknown-20200101-000000.tar"), []byte("old"), 0o600); err != nil {
		t.Fatal(err)
	}
	path := filepath.Join(dir, "backup-unknown-20261007-010600.tar")
	useCreateBackup(t, func(_ context.Context, _ string, report func(string)) (*backup.Result, error) {
		report("dumping the database")
		if err := os.WriteFile(path, []byte("new"), 0o600); err != nil {
			return nil, err
		}
		return &backup.Result{Path: path, Size: 3}, nil
	})
	if err := runBackup(s, 1); err != nil {
		t.Fatal(err)
	}
	if out.Len() != 0 {
		t.Fatalf("a quiet backup printed:\n%s", out)
	}
	data, err := os.ReadFile(s.log.Path())
	if err != nil {
		t.Fatal(err)
	}
	for _, line := range []string{"dumping the database", path + " (3 B, 0s)", "removed backup-unknown-20200101-000000.tar"} {
		if !strings.Contains(string(data), line) {
			t.Errorf("the log lacks %q:\n%s", line, data)
		}
	}
}

// With --quiet an upgrade with nothing to do prints nothing, and a blocked
// one its blockers alone, with the log named in its error: a cron job
// mails only what needs a look. Without it, both say what they found.
func TestQuietUpgrade(t *testing.T) {
	root := newRoot(t)
	useRoot(t, root)
	useStderr(t)
	saveState(t, root, &instance.State{Current: "1.0.0", Files: []string{"docker/docker-compose.yml"}})
	m := readyPlan().Manifest
	usePlan(t, &upgrade.Plan{Current: "1.0.0", Target: &m.Releases[2], Manifest: m, UpToDate: true})
	if out, err := runKvsctl(t, "upgrade", "--root", root, "--yes", "--quiet"); err != nil || out != "" {
		t.Fatalf("a quiet upgrade with nothing to do: %v, printed %q", err, out)
	}
	if out, err := runKvsctl(t, "upgrade", "--root", root, "--yes"); err != nil || !strings.HasSuffix(out, "\nAlready on 1.0.0, with the images it pins.\n") {
		t.Fatalf("an upgrade with nothing to do: %v, printed %q", err, out)
	}

	blocked := readyPlan()
	blocked.Blockers = []string{"1 release file changed since 1.0.0 was installed (README.md): copy it aside, or pass --allow-local-changes"}
	usePlan(t, blocked)
	out, err := runKvsctl(t, "upgrade", "--root", root, "--yes", "--quiet")
	if exitCode(err) != exitBlocked || !strings.Contains(err.Error(), "; log: ") || out != "Blocked\n  - "+blocked.Blockers[0]+"\n" {
		t.Fatalf("a quiet blocked upgrade: %v, printed %q", err, out)
	}
	out, err = runKvsctl(t, "upgrade", "--root", root, "--yes")
	if exitCode(err) != exitBlocked || !strings.Contains(out, "\nTarget       1.1.0 (2026-10-01)\n") || !strings.HasSuffix(out, "Blocked\n  - "+blocked.Blockers[0]+"\n") {
		t.Fatalf("a blocked upgrade: %v, printed %q", err, out)
	}
}

// A failure kvsctl remembers answers for the build that met it: the one
// update-cli installs, which may read what this one could not, reads the
// manifest at once instead of repeating, for the rest of the hour, the
// failure of the build it replaced.
func TestAnotherBuildReadsTheManifestAgain(t *testing.T) {
	root := newRoot(t)
	useRoot(t, root)
	useStderr(t)
	inst := saveState(t, root, &instance.State{Current: "1.0.0"})
	url := signedManifestOf(t, manifest.Schema+1, testRelease("1.1.0", "2026-10-01", ""))
	if _, err := latestRelease(inst, reminderWait, manifest.Fetch); err == nil || !strings.Contains(err.Error(), "'kvsctl update-cli'") {
		t.Fatalf("a manifest of a later schema: %v", err)
	}
	// The build update-cli installed reads that schema: the same URL now
	// serves a list it reads.
	readable := signedManifest(t, testRelease("1.1.0", "2026-10-01", ""), testRelease("1.0.0", "2026-09-01", ""))
	if err := os.Rename(strings.TrimPrefix(readable, "file://"), strings.TrimPrefix(url, "file://")); err != nil {
		t.Fatal(err)
	}
	if err := os.Rename(strings.TrimPrefix(readable, "file://")+".sig", strings.TrimPrefix(url, "file://")+".sig"); err != nil {
		t.Fatal(err)
	}
	useManifest(t, url)
	old := Version
	Version = "1.1.0"
	t.Cleanup(func() { Version = old })
	latest, err := latestRelease(inst, reminderWait, manifest.Fetch)
	if err != nil || latest.Version != "1.1.0" {
		t.Fatalf("the next build answers %+v, %v: the failure of the build before it", latest, err)
	}
}

// A read an interrupt cut short says nothing of the manifest server: it is
// not remembered, and the next command reads the manifest again.
func TestAnInterruptedReadIsNotRemembered(t *testing.T) {
	root := newRoot(t)
	useRoot(t, root)
	useStderr(t)
	inst := saveState(t, root, &instance.State{Current: "1.0.0"})
	url := signedManifest(t, testRelease("1.1.0", "2026-10-01", ""), testRelease("1.0.0", "2026-09-01", ""))
	cut := func(string) (*manifest.Document, error) { return nil, manifest.ErrInterrupted }
	if _, err := latestRelease(inst, reminderWait, cut); !errors.Is(err, manifest.ErrInterrupted) {
		t.Fatalf("an interrupted read: %v", err)
	}
	if known := loadLatestKnown(inst)[url]; known != nil && !known.Failed.IsZero() {
		t.Fatalf("the interrupted read is remembered as a failure: %+v", known)
	}
	if latest, err := latestRelease(inst, reminderWait, manifest.Fetch); err != nil || latest.Version != "1.1.0" {
		t.Fatalf("the read after it: %+v, %v", latest, err)
	}
}

// A release candidate is installed only when its version is named: the
// reminder and status announce the latest stable release, which upgrade
// installs, and a candidate a kvsctl older than that rule kept is no
// answer either.
func TestRecordKeepsTheLatestStableRelease(t *testing.T) {
	now := time.Now()
	k := &latestKnown{}
	k.record(&manifest.Manifest{Releases: []manifest.Release{
		{Version: "1.2.0-rc1", Date: "2026-10-09", Commit: "c12rc"},
		{Version: "1.1.0", Date: "2026-10-01", Commit: "c11"},
	}}, now)
	if k.Version != "1.1.0" || k.Date != "2026-10-01" || k.Commit != "c11" {
		t.Fatalf("a list led by a candidate recorded %+v", k)
	}
	k = &latestKnown{Version: "1.2.0-rc1", Date: "2026-10-09"}
	k.record(&manifest.Manifest{Releases: []manifest.Release{{Version: "1.1.0", Date: "2026-10-01"}}}, now)
	if k.Version != "1.1.0" {
		t.Fatalf("the candidate an older kvsctl kept stays: %+v", k)
	}
	k.record(&manifest.Manifest{Releases: []manifest.Release{{Version: "1.3.0-rc1"}}}, now)
	if k.Version != "1.1.0" || !k.Read.Equal(now) {
		t.Fatalf("a list of candidates only recorded %+v", k)
	}

	root := newRoot(t)
	useRoot(t, root)
	useStderr(t)
	inst := saveState(t, root, &instance.State{Current: "1.0.0"})
	url := signedManifest(t, testRelease("1.1.0", "2026-10-01", ""), testRelease("1.0.0", "2026-09-01", ""))
	saveLatestKnown(inst, map[string]*latestKnown{url: {Read: now, Version: "1.2.0-rc1"}})
	if latest, err := latestRelease(inst, reminderWait, manifest.Fetch); err != nil || latest.Version != "1.1.0" {
		t.Fatalf("a candidate kept by an older kvsctl answers %+v, %v", latest, err)
	}
}

// version --check reads the manifest as update-cli does: a manifest of a
// later schema, which update-cli installs from, and the latest stable
// release, never a release candidate update-cli would not install without
// its version.
func TestVersionCheckNamesTheLatestStableRelease(t *testing.T) {
	useStderr(t)
	pub, priv, err := ed25519.GenerateKey(nil)
	if err != nil {
		t.Fatal(err)
	}
	t.Setenv(releaseKeyEnv, base64.StdEncoding.EncodeToString(pub))
	old := Version
	Version = "27.3.0"
	t.Cleanup(func() { Version = old })
	cli := fmt.Sprintf(`{%q:{"url":"https://example.com/kvsctl","sha256":"%s"}}`, cliPlatform(), strings.Repeat("0", 64))
	// A new root command sets every flag to its default: --manifest is
	// given again each time.
	pointAtSignedRaw(t, fmt.Sprintf(`{"schema":%d,"channel":"stable","updated":"2027-03-01T08:00:00Z","releases":[{"version":"27.4.0-rc1","cli":%s,"images":"elsewhere"},{"version":"27.3.0","cli":%s}]}`, manifest.Schema+1, cli, cli), priv)
	out, err := runKvsctl(t, "version", "--check", "--manifest", flagManifest)
	if err != nil || !strings.HasSuffix(out, "\nkvsctl 27.3.0 is the build of release 27.3.0\n") {
		t.Fatalf("version --check: %v\n%s", err, out)
	}
	pointAtSignedRaw(t, fmt.Sprintf(`{"schema":%d,"channel":"candidate","updated":"2027-03-01T08:00:00Z","releases":[{"version":"27.4.0-rc1","cli":%s}]}`, manifest.Schema, cli), priv)
	out, err = runKvsctl(t, "version", "--check", "--manifest", flagManifest)
	if err != nil || !strings.HasSuffix(out, "\nthe manifest lists release candidates only (27.4.0-rc1 is the newest): no stable release ships a kvsctl to compare with\n") {
		t.Fatalf("version --check on candidates only: %v\n%s", err, out)
	}
}

// An upgrade with no version named on a stack that runs a release newer
// than the latest stable one, a candidate the manifest no longer lists,
// has nothing to do: it says so and exits 0, nothing at all with --quiet.
// An older version named is a mistake, which exits 1.
func TestUpgradeWithNothingNewer(t *testing.T) {
	root := newRoot(t)
	useRoot(t, root)
	useStderr(t)
	saveState(t, root, &instance.State{Current: "1.2.0-rc1", Files: []string{"docker/docker-compose.yml"}})
	url := signedManifest(t, testRelease("1.1.0", "2026-10-01", ""), testRelease("1.0.0", "2026-09-01", ""))
	const nothing = "the installed 1.2.0-rc1 is newer than 1.1.0, the latest stable release: there is nothing to upgrade to\n"
	if out, err := runKvsctl(t, "upgrade", "--root", root, "--manifest", url, "--yes"); err != nil || !strings.HasSuffix(out, "\n"+nothing) {
		t.Fatalf("an upgrade with nothing newer: %v, printed %q", err, out)
	}
	if out, err := runKvsctl(t, "upgrade", "--root", root, "--manifest", url, "--yes", "--quiet"); err != nil || out != "" {
		t.Fatalf("a quiet upgrade with nothing newer: %v, printed %q", err, out)
	}
	if _, err := runKvsctl(t, "upgrade", "--root", root, "--manifest", url, "--yes", "--version", "1.1.0"); exitCode(err) != exitError || !strings.Contains(err.Error(), "1.1.0 is older than the installed 1.2.0-rc1") {
		t.Fatalf("an older version named: %v", err)
	}
}

// What the plan of an upgrade read of the manifest is kept for the
// reminder and status, as check keeps it.
func TestUpgradeKeepsTheManifestItRead(t *testing.T) {
	root := newRoot(t)
	useRoot(t, root)
	useStderr(t)
	inst := saveState(t, root, &instance.State{Current: "1.0.0", Files: []string{"docker/docker-compose.yml"}})
	plan := readyPlan()
	plan.Target, plan.UpToDate = &plan.Manifest.Releases[2], true
	usePlan(t, plan)
	const url = "https://example.com/manifest.json"
	if out, err := runKvsctl(t, "upgrade", "--root", root, "--manifest", url, "--yes"); err != nil {
		t.Fatalf("upgrade: %v\n%s", err, out)
	}
	if known := loadLatestKnown(inst)[url]; known == nil || known.Version != "1.2.0" || known.MinFrom["1.2.0"] != "1.1.0" {
		t.Fatalf("the read of the upgrade was not kept: %+v", known)
	}
}

// The waits of a run that restarts the stack: MariaDB alone gets the wait
// its series change calls for unless --db-timeout names one, which the
// default of 0 leaves to the run.
func TestTimeoutDefaults(t *testing.T) {
	for _, cmd := range []*cobra.Command{upgradeCmd(), rollbackCmd(), recoverCmd()} {
		if got := cmd.Flags().Lookup("db-timeout").DefValue; got != "0s" {
			t.Errorf("%s --db-timeout defaults to %s, want 0s", cmd.Name(), got)
		}
		if got := cmd.Flags().Lookup("health-timeout").DefValue; got != "2m0s" {
			t.Errorf("%s --health-timeout defaults to %s, want 2m0s", cmd.Name(), got)
		}
	}
}

// recover names the run it finishes in its title, a run that failed with
// when it failed: the failure, which can be long, is the first line of the
// run, under the title. A run that passed its verification is only
// recorded, which needs no engine: DOCKER_HOST names a socket nothing
// listens on.
func TestRecoverTitleOfAFailedRun(t *testing.T) {
	root := newRoot(t)
	inst := saveState(t, root, &instance.State{Current: "1.0.0", Files: []string{"docker/docker-compose.yml"}})
	failed := time.Date(2026, 10, 7, 1, 0, 0, 0, time.UTC)
	const failure = "the state could not be written: no space left on device"
	if err := inst.SaveJournal(&instance.Journal{Action: instance.ActionUpgrade, From: "1.0.0", To: "1.1.0", Phase: instance.PhaseRecord, Failed: failed, Failure: failure}); err != nil {
		t.Fatal(err)
	}
	out := useRoot(t, root)
	t.Setenv("DOCKER_HOST", "unix://"+filepath.Join(t.TempDir(), "none.sock"))
	keepFlags(t)
	cmd := rootCmd()
	cmd.SetArgs([]string{"recover", "--root", root, "--plain", "--yes"})
	_ = cmd.Execute()
	const title = "KVS stack · example.com · recover: an upgrade from 1.0.0 to 1.1.0 failed during record on 2026-10-07 01:00 UTC\n"
	if !strings.Contains(out.String(), "\n"+title) {
		t.Fatalf("recover printed\n%s\nwithout the title %q", out.String(), title)
	}
	if got := recoverTitle(&instance.Journal{Action: instance.ActionUpgrade, From: "1.0.0", To: "1.1.0", Phase: instance.PhaseRestart, Started: failed}, nil); got != "an upgrade from 1.0.0 to 1.1.0 was interrupted during restart on 2026-10-07 01:00 UTC" {
		t.Fatalf("the title of an interrupted run: %q", got)
	}
}

// kvsctl backup records the KVS version the site runs in its archive, as
// the backups of an upgrade and a rollback do: a replay then tells that it
// takes the database back across a KVS update. The docker CLI is a script
// that answers the two commands a backup runs in the database container.
func TestBackupRecordsTheKVSVersion(t *testing.T) {
	root := newRoot(t)
	s := testSession(t, root)
	if space, err := diskspace.Measure(t.TempDir()); err != nil || space.Avail < max(int64(1)<<30, space.Size/50)+64<<20 {
		t.Skipf("the filesystem of the temporary directory is too full for a backup: %+v, %v", space, err)
	}
	s.inst.WebRoot = t.TempDir()
	version := filepath.Join(s.inst.WebRoot, "admin", "include", "version.php")
	if err := os.MkdirAll(filepath.Dir(version), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(version, []byte("<?php\n$config['project_version'] = '7.0.0';\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	bin := t.TempDir()
	const docker = `#!/bin/sh
# docker exec -i <container> sh -c <script>
case "$6" in
*information_schema*) printf '0\t\n' ;;
*mariadb-dump*) printf 'CREATE TABLE t (id int);\n' ;;
*) echo "unexpected: $*" >&2; exit 1 ;;
esac
`
	if err := os.WriteFile(filepath.Join(bin, "docker"), []byte(docker), 0o755); err != nil {
		t.Fatal(err)
	}
	t.Setenv("PATH", bin+string(os.PathListSeparator)+os.Getenv("PATH"))
	if err := runBackup(s, 5); err != nil {
		t.Fatal(err)
	}
	list, err := backup.List(s.inst.BackupDir())
	if err != nil || len(list) != 1 || list[0].KVSVersion != "7.0.0" {
		t.Fatalf("the backup records %+v (%v), want KVS 7.0.0", list, err)
	}
}
