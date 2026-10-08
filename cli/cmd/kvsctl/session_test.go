package main

import (
	"bytes"
	"context"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"slices"
	"strings"
	"sync"
	"syscall"
	"testing"
	"time"

	"github.com/MaximeMichaud/KVS-install/cli/internal/dockerx"
	"github.com/MaximeMichaud/KVS-install/cli/internal/instance"
	"github.com/MaximeMichaud/KVS-install/cli/internal/runlog"
	"github.com/MaximeMichaud/KVS-install/cli/internal/upgrade"
)

// newRoot lays out an installation kvsctl detects: the compose file and a
// .env naming the site, plus files.
func newRoot(t *testing.T, files ...string) string {
	t.Helper()
	root := t.TempDir()
	write := func(name, content string) {
		path := filepath.Join(root, name)
		if err := os.MkdirAll(filepath.Dir(path), 0o755); err != nil {
			t.Fatal(err)
		}
		if err := os.WriteFile(path, []byte(content), 0o644); err != nil {
			t.Fatal(err)
		}
	}
	write("docker/docker-compose.yml", "services: {}\n")
	write("docker/.env", "DOMAIN=example.com\n")
	for i := 0; i+1 < len(files); i += 2 {
		write(files[i], files[i+1])
	}
	return root
}

// useRoot points the commands at root, and their printed lines at a
// buffer, for the length of the test.
func useRoot(t *testing.T, root string) *bytes.Buffer {
	t.Helper()
	oldRoot, oldOut, oldYes := flagRoot, stdout, flagYes
	out := &bytes.Buffer{}
	flagRoot, stdout = root, &lockedBuffer{b: out}
	t.Cleanup(func() { flagRoot, stdout, flagYes = oldRoot, oldOut, oldYes })
	return out
}

// lockedBuffer is a buffer the guard and the test may write together.
type lockedBuffer struct {
	mu sync.Mutex
	b  *bytes.Buffer
}

func (l *lockedBuffer) Write(p []byte) (int, error) {
	l.mu.Lock()
	defer l.mu.Unlock()
	return l.b.Write(p)
}

func (l *lockedBuffer) String() string {
	l.mu.Lock()
	defer l.mu.Unlock()
	return l.b.String()
}

// testSession opens a session of the adopt command on root; the test ends
// it.
func testSession(t *testing.T, root string) *session {
	t.Helper()
	useRoot(t, root)
	g := newGuard("stops", nil)
	t.Cleanup(g.stop)
	s, err := openSession("adopt", g, sessionOptions{})
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = s.finish(nil) })
	return s
}

func interruptedJournal(t *testing.T, root string) *instance.Journal {
	t.Helper()
	inst, err := instance.Detect(root)
	if err != nil {
		t.Fatal(err)
	}
	j := &instance.Journal{Action: instance.ActionUpgrade, From: "26.10.0", To: "26.11.0", Phase: instance.PhaseRestart, Log: "/opt/kvs/kvsctl/logs/20261006-120000-upgrade.log"}
	if err := inst.SaveJournal(j); err != nil {
		t.Fatal(err)
	}
	return j
}

func TestExitCodes(t *testing.T) {
	cases := []struct {
		err  error
		want int
	}{
		{nil, 0},
		{errors.New("no stack in /opt/kvs"), exitError},
		{usageError{errors.New("bad version")}, exitUsage},
		{errors.New(`unknown flag: --allow-mariadb-upgrade`), exitUsage},
		{upgrade.ErrBlocked, exitBlocked},
		{fmt.Errorf("upgrade to 26.11.0 failed: %w", upgrade.ErrRolledBack), exitRolledBack},
		{fmt.Errorf("the rollback failed: %w", upgrade.ErrRollbackFailed), exitRollbackFailed},
		{&instance.LockedError{PID: 42, Command: "upgrade"}, exitLocked},
		{fmt.Errorf("manifest: %w", upgrade.ErrStaleManifest), exitStaleManifest},
		{fmt.Errorf("recorded nothing: %w", upgrade.ErrNotRecorded), exitNotRecorded},
		{&loggedError{err: upgrade.ErrNotRecorded, path: "/x.log"}, exitNotRecorded},
		{&codedError{code: exitRollbackFailed, err: errors.New("the replay stopped")}, exitRollbackFailed},
	}
	for _, c := range cases {
		if got := exitCode(c.err); got != c.want {
			t.Errorf("exitCode(%v) = %d, want %d", c.err, got, c.want)
		}
	}
}

// The error of a run that changed the stack and did not end where it
// should names its log, once; the others do not.
func TestWithLog(t *testing.T) {
	const path = "/opt/kvs/kvsctl/logs/20261006-120000-upgrade.log"
	for _, code := range []int{exitRolledBack, exitRollbackFailed, exitNotRecorded} {
		err := withLog(upgrade.ErrRolledBack, code, path)
		if !strings.HasSuffix(err.Error(), "; log: "+path) || !errors.Is(err, upgrade.ErrRolledBack) {
			t.Fatalf("code %d: %v", code, err)
		}
	}
	named := errors.New("the rollback failed; read " + path)
	if err := withLog(named, exitRollbackFailed, path); err != named {
		t.Fatalf("a message that names the log got it twice: %v", err)
	}
	if err := withLog(upgrade.ErrBlocked, exitBlocked, path); err != upgrade.ErrBlocked {
		t.Fatalf("a blocked upgrade names the log: %v", err)
	}
}

// A session takes the lock first, then writes its log, names it first
// thing, and gives both up at the end with the result in the log.
func TestSessionLocksAndLogs(t *testing.T) {
	root := newRoot(t)
	out := useRoot(t, root)
	g := newGuard("stops", nil)
	defer g.stop()
	s, err := openSession("backup", g, sessionOptions{})
	if err != nil {
		t.Fatal(err)
	}
	if want := "log: " + s.log.Path() + "\n"; out.String() != want {
		t.Fatalf("the session printed %q, want %q", out.String(), want)
	}
	inst, _ := instance.Detect(root)
	if _, err := inst.Lock("other"); err == nil {
		t.Fatal("the session does not hold the lock")
	}
	s.say("a line of the command")
	if err := s.finish(upgrade.ErrRolledBack); !strings.Contains(err.Error(), s.log.Path()) {
		t.Fatalf("an exit 4 does not name the log: %v", err)
	}
	unlock, err := inst.Lock("other")
	if err != nil {
		t.Fatalf("the lock was not released: %v", err)
	}
	unlock()
	logs, _ := runlog.List(inst.StateDir())
	if len(logs) != 1 {
		t.Fatalf("%d run logs", len(logs))
	}
	data, _ := os.ReadFile(logs[0])
	for _, want := range []string{"kvsctl " + Version, "a line of the command", "exit 4: "} {
		if !strings.Contains(string(data), want) {
			t.Fatalf("the log lacks %q:\n%s", want, data)
		}
	}
}

// A session reads the installation once it holds the lock: a run that
// changed .env and let go of the lock after this one first read the
// installation must not leave it with the settings from before that run.
func TestSessionReadsTheInstallationUnderTheLock(t *testing.T) {
	root := newRoot(t)
	useRoot(t, root)
	lock := takeLock
	t.Cleanup(func() { takeLock = lock })
	const list = "docker-compose.yml:docker-compose.release.yml"
	takeLock = func(inst *instance.Instance, command string) (func(), error) {
		if err := os.WriteFile(inst.EnvPath, []byte("DOMAIN=example.com\nCOMPOSE_FILE="+list+"\n"), 0o644); err != nil {
			t.Fatal(err)
		}
		return lock(inst, command)
	}
	g := newGuard("stops", nil)
	defer g.stop()
	s, err := openSession("upgrade", g, sessionOptions{})
	if err != nil {
		t.Fatal(err)
	}
	defer func() { _ = s.finish(nil) }()
	if got := s.inst.Env["COMPOSE_FILE"]; got != list {
		t.Fatalf("the session reads COMPOSE_FILE=%q, the .env under the lock holds %q", got, list)
	}
}

// With --quiet a session names its log only in the error of a run that
// failed, whatever the exit code, and the lines that tell how a run goes
// stay in the log: a cron job whose run went well mails nothing.
func TestQuietSession(t *testing.T) {
	root := newRoot(t)
	out := useRoot(t, root)
	old := flagQuiet
	flagQuiet = true
	t.Cleanup(func() { flagQuiet = old })
	g := newGuard("stops", nil)
	defer g.stop()
	s, err := openSession("backup", g, sessionOptions{})
	if err != nil {
		t.Fatal(err)
	}
	s.detail("dumping the database")
	s.say("Warning: the archive comes from another stack")
	if got, want := out.String(), "Warning: the archive comes from another stack\n"; got != want {
		t.Fatalf("a quiet session printed %q, want %q", got, want)
	}
	path := s.log.Path()
	err = s.finish(errors.New("the dump failed"))
	if err == nil || err.Error() != "the dump failed; log: "+path {
		t.Fatalf("the error of a quiet run is %v, want it to name %s", err, path)
	}
	data, rerr := os.ReadFile(path)
	if rerr != nil || !strings.Contains(string(data), "dumping the database") {
		t.Fatalf("the log lacks the progress (%v):\n%s", rerr, data)
	}
}

// With --yes nothing is asked, so the screen does not list the
// confirmation as a step still to come under the ones that run.
func TestScreenStepsWithYes(t *testing.T) {
	got := screenSteps(upgrade.UpgradeSteps, true)
	if slices.Contains(got, upgrade.StepConfirm) || len(got) != len(upgrade.UpgradeSteps)-1 {
		t.Fatalf("with --yes the screen lists %v", got)
	}
	if got := screenSteps(upgrade.UpgradeSteps, false); !slices.Equal(got, upgrade.UpgradeSteps) {
		t.Fatalf("without --yes the screen lists %v", got)
	}
	if !slices.Contains(upgrade.UpgradeSteps, upgrade.StepConfirm) {
		t.Fatal("the steps of the upgrade lost the confirmation")
	}
}

// Another kvsctl holding the lock is exit 6, and the run writes no log.
func TestSessionLocked(t *testing.T) {
	root := newRoot(t)
	useRoot(t, root)
	inst, _ := instance.Detect(root)
	unlock, err := inst.Lock("upgrade")
	if err != nil {
		t.Fatal(err)
	}
	defer unlock()
	g := newGuard("stops", nil)
	defer g.stop()
	_, err = openSession("backup", g, sessionOptions{})
	if exitCode(err) != exitLocked {
		t.Fatalf("a held lock gives %v", err)
	}
	if logs, _ := runlog.List(inst.StateDir()); len(logs) != 0 {
		t.Fatalf("a locked run wrote %v", logs)
	}
}

// While the journal of an interrupted run is there, a command that
// changes the stack refuses, names recover and the log of that run, lets
// go of the lock and writes no log of its own; recover itself goes on.
func TestSessionRefusesAnInterruptedRun(t *testing.T) {
	root := newRoot(t)
	j := interruptedJournal(t, root)
	useRoot(t, root)
	g := newGuard("stops", nil)
	defer g.stop()
	_, err := openSession("backup", g, sessionOptions{})
	if err == nil || exitCode(err) != exitError {
		t.Fatalf("an interrupted run gives %v", err)
	}
	for _, want := range []string{"was interrupted during restart", "kvsctl recover", j.Log} {
		if !strings.Contains(err.Error(), want) {
			t.Fatalf("%q lacks %q", err, want)
		}
	}
	inst, _ := instance.Detect(root)
	unlock, lerr := inst.Lock("other")
	if lerr != nil {
		t.Fatalf("the refusal kept the lock: %v", lerr)
	}
	unlock()
	if logs, _ := runlog.List(inst.StateDir()); len(logs) != 0 {
		t.Fatalf("the refusal wrote %v", logs)
	}
	s, err := openSession("recover", g, sessionOptions{recovering: true})
	if err != nil {
		t.Fatalf("recover was refused: %v", err)
	}
	_ = s.finish(nil)
}

// Every command but status, version, history, logs, releases and recover
// refuses while a run is interrupted, before it reads anything else.
func TestCommandsRefuseAnInterruptedRun(t *testing.T) {
	dir := newRoot(t)
	interruptedJournal(t, dir)
	useRoot(t, dir)
	missing := "file://" + filepath.Join(t.TempDir(), "manifest.json")
	keepFlags(t)
	for _, args := range [][]string{
		{"check"}, {"upgrade"}, {"rollback"}, {"backup"}, {"adopt"},
		{"restore", "--latest"}, {"clean"}, {"update-cli"},
	} {
		cmd := rootCmd()
		cmd.SetArgs(append(args, "--root", dir, "--manifest", missing, "--plain", "--yes"))
		err := cmd.Execute()
		if err == nil || !strings.Contains(err.Error(), "kvsctl recover") {
			t.Errorf("%s: %v", args[0], err)
		}
	}
	cmd := rootCmd()
	cmd.SetArgs([]string{"history", "--root", dir})
	if err := cmd.Execute(); err != nil {
		t.Errorf("history refused: %v", err)
	}
}

// status puts an interrupted run first, and tells it from a run that is
// still going in another kvsctl, which it shows before that run changed
// anything too.
func TestPrintRun(t *testing.T) {
	j := &instance.Journal{Action: instance.ActionUpgrade, From: "26.10.0", To: "26.11.0", Phase: instance.PhaseVerify, Log: "/x.log", Started: time.Date(2026, 10, 6, 12, 0, 0, 0, time.UTC)}
	var out bytes.Buffer
	printRun(&out, nil, j, nil)
	if got := out.String(); !strings.HasPrefix(got, "Interrupted ") || !strings.Contains(got, "kvsctl recover") || !strings.Contains(got, "/x.log") {
		t.Fatalf("interrupted: %q", got)
	}
	out.Reset()
	printRun(&out, nil, j, &instance.LockedError{PID: 42, Command: "upgrade"})
	if got := out.String(); !strings.HasPrefix(got, "Running ") || !strings.Contains(got, "now at its verify phase") || strings.Contains(got, "recover") {
		t.Fatalf("running: %q", got)
	}
	out.Reset()
	printRun(&out, nil, nil, &instance.LockedError{PID: 42, Command: "backup"})
	if got := out.String(); got != "Running      another kvsctl is running (pid 42, backup)\n" {
		t.Fatalf("running without a journal: %q", got)
	}
	out.Reset()
	printRun(&out, nil, nil, nil)
	if out.Len() != 0 {
		t.Fatalf("no journal printed %q", out.String())
	}

	// A run that failed is told as such, with its cause, and a lock that
	// a docker command holds after its kvsctl ended is no run in progress.
	failed := *j
	failed.Phase, failed.Failed, failed.Failure = instance.PhaseRollback, j.Started.Add(time.Minute), "docker compose up -d: exit status 1"
	out.Reset()
	printRun(&out, nil, &failed, nil)
	if got, want := out.String(), "Failed       the rollback of an upgrade from 26.10.0 to 26.11.0 failed on 2026-10-06 12:01 UTC: docker compose up -d: exit status 1; once the cause is fixed, run 'kvsctl recover' (its log: /x.log)\n"; got != want {
		t.Fatalf("a failed run: %q\nwant %q", got, want)
	}
	orphan := &instance.LockedError{PID: 42, Command: "upgrade", Orphaned: true, Path: "/opt/kvs/kvsctl/lock"}
	out.Reset()
	printRun(&out, nil, nil, orphan)
	if got := out.String(); !strings.HasPrefix(got, "Locked       the kvsctl run that holds the lock has ended (pid 42, upgrade)") {
		t.Fatalf("an orphaned lock: %q", got)
	}
	out.Reset()
	printRun(&out, nil, j, orphan)
	if got := out.String(); !strings.HasPrefix(got, "Locked       the kvsctl run that holds the lock has ended") || !strings.HasSuffix(got, ": upgrade from 26.10.0 to 26.11.0, stopped at its verify phase\n") {
		t.Fatalf("an orphaned lock with a journal: %q", got)
	}

	// The state names the unreleased checkout an adopt recorded by its
	// commit, in a run cut short and in one still going.
	adopted := &instance.State{Current: "26.10.0", Previous: instance.Unreleased, AdoptedCommit: strings.Repeat("a", 40)}
	back := &instance.Journal{Action: instance.ActionRollback, From: "26.10.0", To: instance.Unreleased, Phase: instance.PhaseRestart, Started: j.Started}
	out.Reset()
	printRun(&out, adopted, back, nil)
	if got, want := out.String(), "Interrupted  a rollback from 26.10.0 to unreleased checkout aaaaaaaaaaaa was interrupted during restart on 2026-10-06 12:00 UTC: run 'kvsctl recover'\n"; got != want {
		t.Fatalf("interrupted rollback: %q\nwant %q", got, want)
	}
	out.Reset()
	printRun(&out, adopted, back, &instance.LockedError{PID: 42, Command: "rollback"})
	if got, want := out.String(), "Running      another kvsctl is running (pid 42, rollback): rollback from 26.10.0 to unreleased checkout aaaaaaaaaaaa, now at its restart phase\n"; got != want {
		t.Fatalf("rollback in progress: %q\nwant %q", got, want)
	}
}

// A refusal names the unreleased checkout an adopt recorded by its commit,
// in the commands that take the lock and in the ones that do not. A state
// that cannot be read leaves the version as the journal records it, and
// the refusal stands.
func TestRefusalNamesAnUnreleasedCheckout(t *testing.T) {
	root := newRoot(t)
	inst, err := instance.Detect(root)
	if err != nil {
		t.Fatal(err)
	}
	if err := inst.SaveState(&instance.State{Current: "26.10.0", Previous: instance.Unreleased, AdoptedCommit: strings.Repeat("a", 40)}); err != nil {
		t.Fatal(err)
	}
	if err := inst.SaveJournal(&instance.Journal{Action: instance.ActionRollback, From: "26.10.0", To: instance.Unreleased, Phase: instance.PhaseRestart}); err != nil {
		t.Fatal(err)
	}
	const want = "a rollback from 26.10.0 to unreleased checkout aaaaaaaaaaaa was interrupted during restart"
	useRoot(t, root)
	g := newGuard("stops", nil)
	defer g.stop()
	if _, err := openSession("backup", g, sessionOptions{}); err == nil || !strings.Contains(err.Error(), want) {
		t.Errorf("a command that takes the lock: %v", err)
	}
	if err := refuseInterrupted(inst); err == nil || !strings.Contains(err.Error(), want) {
		t.Errorf("a command that takes no lock: %v", err)
	}
	if err := os.WriteFile(filepath.Join(inst.StateDir(), "state.json"), []byte("{"), 0o600); err != nil {
		t.Fatal(err)
	}
	if err := refuseInterrupted(inst); err == nil || !strings.Contains(err.Error(), "a rollback from 26.10.0 to 0.0.0 was interrupted during restart") || !strings.Contains(err.Error(), "run 'kvsctl recover'") {
		t.Errorf("with a damaged state: %v", err)
	}
}

// recover names the run it finishes in its title, an unreleased checkout by
// its commit. A rollback that passed its verification is only recorded,
// which needs no engine: DOCKER_HOST names a socket nothing listens on.
func TestRecoverNamesAnUnreleasedCheckout(t *testing.T) {
	root := newRoot(t)
	inst, err := instance.Detect(root)
	if err != nil {
		t.Fatal(err)
	}
	if err := inst.SaveState(&instance.State{Current: "26.10.0", Previous: instance.Unreleased, AdoptedCommit: strings.Repeat("a", 40)}); err != nil {
		t.Fatal(err)
	}
	if err := inst.SaveJournal(&instance.Journal{Action: instance.ActionRollback, From: "26.10.0", To: instance.Unreleased, Phase: instance.PhaseRecord}); err != nil {
		t.Fatal(err)
	}
	out := useRoot(t, root)
	t.Setenv("DOCKER_HOST", "unix://"+filepath.Join(t.TempDir(), "none.sock"))
	keepFlags(t)
	cmd := rootCmd()
	cmd.SetArgs([]string{"recover", "--root", root, "--plain", "--yes"})
	if err := cmd.Execute(); err != nil {
		t.Fatalf("recover: %v", err)
	}
	const title = "KVS stack · example.com · recover: a rollback from 26.10.0 to unreleased checkout aaaaaaaaaaaa was interrupted during record on "
	if !strings.Contains(out.String(), "\n"+title) {
		t.Errorf("recover printed\n%s\nwithout the title %q", out.String(), title)
	}
	state, err := inst.LoadState()
	if err != nil || state.Current != instance.Unreleased || state.Previous != "26.10.0" {
		t.Errorf("after recover the state is %+v (%v)", state, err)
	}
	if j, err := inst.LoadJournal(); j != nil || err != nil {
		t.Errorf("the journal is still there: %+v (%v)", j, err)
	}
}

// status names the unreleased checkout an adopt recorded by its commit,
// installed or as the version a rollback returns to.
func TestStackLine(t *testing.T) {
	const commit = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
	if got := stackLine(&instance.State{Current: instance.Unreleased, AdoptedCommit: commit}); got != "unreleased checkout aaaaaaaaaaaa" {
		t.Fatalf("an unreleased checkout reads %q", got)
	}
	if got := stackLine(&instance.State{Current: "26.10.0", Previous: instance.Unreleased, AdoptedCommit: commit}); got != "26.10.0 (previous unreleased checkout aaaaaaaaaaaa)" {
		t.Fatalf("an upgraded checkout reads %q", got)
	}
	if got := stackLine(nil); !strings.Contains(got, "kvsctl adopt") {
		t.Fatalf("a stack without a record reads %q", got)
	}
}

// status warns about an operator's override that COMPOSE_FILE leaves out,
// which compose then ignores.
func TestOverrideWarning(t *testing.T) {
	root := newRoot(t)
	inst, err := instance.Detect(root)
	if err != nil {
		t.Fatal(err)
	}
	if got := overrideWarning(inst); got != "" {
		t.Fatalf("no override: %q", got)
	}
	if err := os.WriteFile(filepath.Join(inst.DockerDir, upgrade.OverrideFile), []byte("services: {}\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	cases := map[string]bool{
		"": false,
		"docker-compose.yml:docker-compose.release.yml":                             true,
		"docker-compose.yml:docker-compose.override.yml:docker-compose.release.yml": false,
		"docker-compose.yml:./docker-compose.override.yml":                          false,
	}
	for list, warns := range cases {
		inst.Env["COMPOSE_FILE"] = list
		if got := overrideWarning(inst); (got != "") != warns {
			t.Errorf("COMPOSE_FILE=%q: %q", list, got)
		}
	}
	inst.Env["COMPOSE_PATH_SEPARATOR"], inst.Env["COMPOSE_FILE"] = ",", "docker-compose.yml,docker-compose.override.yml"
	if got := overrideWarning(inst); got != "" {
		t.Fatalf("another separator: %q", got)
	}

	// The override is the one compose loads by itself, under whichever of
	// its names, compose.override.yaml for one.
	if err := os.Remove(filepath.Join(inst.DockerDir, upgrade.OverrideFile)); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(inst.DockerDir, "compose.override.yaml"), []byte("services: {}\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	delete(inst.Env, "COMPOSE_PATH_SEPARATOR")
	inst.Env["COMPOSE_FILE"] = "docker-compose.yml:docker-compose.release.yml"
	if got := overrideWarning(inst); !strings.HasPrefix(got, filepath.Join(inst.DockerDir, "compose.override.yaml")+" exists, and COMPOSE_FILE") {
		t.Fatalf("compose.override.yaml left out: %q", got)
	}
	inst.Env["COMPOSE_FILE"] = "docker-compose.yml:compose.override.yaml:docker-compose.release.yml"
	if got := overrideWarning(inst); got != "" {
		t.Fatalf("compose.override.yaml loaded: %q", got)
	}

	// Beside another override that COMPOSE_FILE loads, the one compose
	// would load by itself is ignored, and no run adds it: a list that
	// names an override, by any name, is kept as it is.
	if err := os.WriteFile(filepath.Join(inst.DockerDir, upgrade.OverrideFile), []byte("services: {}\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	inst.Env["COMPOSE_FILE"] = "docker-compose.yml:./docker-compose.override.yml:docker-compose.release.yml"
	want := filepath.Join(inst.DockerDir, "compose.override.yaml") + " exists, and COMPOSE_FILE in " + inst.EnvPath + " loads another override, ./docker-compose.override.yml, and not this one, so compose ignores it: upgrades and rollbacks keep that list as it is, so add it to COMPOSE_FILE by hand"
	if got := overrideWarning(inst); got != want {
		t.Fatalf("another override listed:\n%q, want\n%q", got, want)
	}
	inst.Env["COMPOSE_FILE"] = "docker-compose.yml:docker-compose.release.yml"
	if got := overrideWarning(inst); !strings.HasSuffix(got, "so compose ignores it: the next upgrade or rollback adds it, or add it to COMPOSE_FILE by hand") {
		t.Fatalf("no override listed: %q", got)
	}
}

// The first interrupt cancels the run, a later one only says so, one that
// comes during a protected step names it, and one after the end is silent.
func TestGuardInterrupts(t *testing.T) {
	g := newGuard("the upgrade stops, and what it already changed is rolled back", map[string]string{upgrade.StepRollbck: "rollback"})
	defer g.stop()
	line, running := g.interrupt("SIGINT")
	if line != "SIGINT: the upgrade stops, and what it already changed is rolled back" || running != "" {
		t.Fatalf("first: %q %q", line, running)
	}
	if g.ctx.Err() == nil {
		t.Fatal("the first interrupt did not cancel")
	}
	if line, _ := g.interrupt("SIGTERM"); !strings.Contains(line, "already stopping") {
		t.Fatalf("second: %q", line)
	}
	g.observe(upgrade.Event{Kind: upgrade.KindStepStart, Step: upgrade.StepRollbck, Message: "back to 26.10.0"})
	if line, running := g.interrupt("SIGINT"); line != "SIGINT: the rollback is running and is not interrupted" || running != "rollback" {
		t.Fatalf("during the rollback: %q %q", line, running)
	}
	g.finish()
	if line, _ := g.interrupt("SIGINT"); line != "" {
		t.Fatalf("after the end: %q", line)
	}
}

// Ctrl-C on the screen: the first one cancels and the screen shows why,
// one during the rollback shows that it goes on; both reach the log.
func TestGuardScreenInterrupt(t *testing.T) {
	root := newRoot(t)
	useRoot(t, root)
	g := newGuard("the upgrade stops, and what it already changed is rolled back", map[string]string{upgrade.StepRollbck: "rollback"})
	defer g.stop()
	s, err := openSession("upgrade", g, sessionOptions{screen: true})
	if err != nil {
		t.Fatal(err)
	}
	if got := g.screenInterrupt(); got != "Ctrl-C: the upgrade stops, and what it already changed is rolled back" {
		t.Fatalf("first: %q", got)
	}
	g.observe(upgrade.Event{Kind: upgrade.KindStepStart, Step: upgrade.StepRollbck})
	if got := g.screenInterrupt(); got != "rollback in progress: Ctrl-C does not interrupt it" {
		t.Fatalf("during the rollback: %q", got)
	}
	_ = s.finish(nil)
	data, _ := os.ReadFile(s.log.Path())
	if !strings.Contains(string(data), "Ctrl-C: the rollback is running and is not interrupted") {
		t.Fatalf("the log lacks the second Ctrl-C:\n%s", data)
	}
}

// A hang-up detaches the screen once and says so, and the run carries on:
// its context is not cancelled.
func TestGuardHangup(t *testing.T) {
	g := newGuard("stops", nil)
	defer g.stop()
	log, err := runlog.Open(t.TempDir(), "upgrade")
	if err != nil {
		t.Fatal(err)
	}
	defer log.Close()
	var lines []string
	var mu sync.Mutex
	g.attach(log, func(line string) {
		mu.Lock()
		defer mu.Unlock()
		lines = append(lines, line)
	})
	detached := 0
	g.screen(func() { detached++ })
	g.hangup()
	g.hangup()
	if detached != 1 || !g.wasHungUp() {
		t.Fatalf("detached %d times", detached)
	}
	if g.ctx.Err() != nil {
		t.Fatal("a hang-up cancelled the run")
	}
	mu.Lock()
	defer mu.Unlock()
	if len(lines) != 1 || lines[0] != "the terminal went away, kvsctl carries on; log: "+log.Path() {
		t.Fatalf("said %q", lines)
	}
}

// The guard owns the signals for real: SIGHUP detaches, SIGPIPE is taken
// without effect, SIGTERM cancels, and the process lives through all three.
func TestGuardOwnsTheSignals(t *testing.T) {
	g := newGuard("stops", nil)
	defer g.stop()
	var mu sync.Mutex
	var lines []string
	g.attach(nil, func(line string) {
		mu.Lock()
		defer mu.Unlock()
		lines = append(lines, line)
	})
	for _, sig := range []syscall.Signal{syscall.SIGPIPE, syscall.SIGHUP} {
		if err := syscall.Kill(os.Getpid(), sig); err != nil {
			t.Fatal(err)
		}
	}
	waitFor(t, "the hang-up", g.wasHungUp)
	if g.ctx.Err() != nil {
		t.Fatal("SIGHUP or SIGPIPE cancelled the run")
	}
	if err := syscall.Kill(os.Getpid(), syscall.SIGTERM); err != nil {
		t.Fatal(err)
	}
	waitFor(t, "the cancel", func() bool { return g.ctx.Err() != nil })
	waitFor(t, "the SIGTERM line", func() bool {
		mu.Lock()
		defer mu.Unlock()
		return len(lines) == 2 && lines[1] == "SIGTERM: stops"
	})
}

func waitFor(t *testing.T, what string, done func() bool) {
	t.Helper()
	deadline := time.Now().Add(5 * time.Second)
	for !done() {
		if time.Now().After(deadline) {
			t.Fatalf("no %s", what)
		}
		time.Sleep(10 * time.Millisecond)
	}
}

// The watcher tells the guard when a protected step starts, and passes
// every event and question on.
func TestWatcher(t *testing.T) {
	g := newGuard("stops", map[string]string{upgrade.StepApply: "rollback"})
	defer g.stop()
	next := &countingReporter{}
	w := &watcher{guard: g, next: next}
	w.Event(upgrade.Event{Kind: upgrade.KindStepStart, Step: upgrade.StepBackup})
	if _, running := g.interrupt("probe"); running != "" {
		t.Fatal("an unprotected step protected the run")
	}
	g2 := newGuard("stops", map[string]string{upgrade.StepApply: "rollback"})
	defer g2.stop()
	w = &watcher{guard: g2, next: next}
	w.Event(upgrade.Event{Kind: upgrade.KindStepStart, Step: upgrade.StepApply})
	if _, running := g2.interrupt("probe"); running != "rollback" {
		t.Fatal("the protected step was not seen")
	}
	if !w.Confirm(context.Background(), "?") || next.events != 3 {
		t.Fatalf("passed %d events", next.events)
	}
}

type countingReporter struct{ events int }

func (c *countingReporter) Event(upgrade.Event)                  { c.events++ }
func (c *countingReporter) Confirm(context.Context, string) bool { c.events++; return true }

func TestLineSink(t *testing.T) {
	var lines []string
	sink := &lineSink{say: func(line string) { lines = append(lines, line) }}
	fmt.Fprintf(sink, "Site  example.com\nBlocked\n  - ")
	fmt.Fprintf(sink, "a blocker\n")
	if strings.Join(lines, "|") != "Site  example.com|Blocked|  - a blocker" {
		t.Fatalf("lines %q", lines)
	}
}

// Until the run has begun to change the stack, the first interrupt says
// that it stops and nothing was changed: an upgrade being planned, backing
// up, pulling or staging its release has nothing to roll back, and the run
// that then asks to begin its first change is told no. Once the guard has
// told it yes, the first interrupt says that what it changed is rolled
// back, whatever step it is in.
func TestGuardSaysWhenNothingWasChanged(t *testing.T) {
	for _, c := range []struct {
		name  string
		began bool
		step  string
		want  string
	}{
		{"nothing changed", false, "", "SIGINT: the upgrade stops, and nothing was changed"},
		{"while it pulls", false, upgrade.StepPull, "SIGINT: the upgrade stops, and nothing was changed"},
		{"while it stages", false, upgrade.StepApply, "SIGINT: the upgrade stops, and nothing was changed"},
		{"a change begun", true, "", "SIGINT: the upgrade stops, and what it already changed is rolled back"},
		{"the files being laid", true, upgrade.StepApply, "SIGINT: the upgrade stops, and what it already changed is rolled back"},
		{"the stack restarted", true, upgrade.StepRestart, "SIGINT: the upgrade stops, and what it already changed is rolled back"},
	} {
		g := newGuard("the upgrade stops, and what it already changed is rolled back", map[string]string{upgrade.StepRollbck: "rollback"})
		g.beforeChange("the upgrade stops, and nothing was changed")
		w := &watcher{guard: g, next: &countingReporter{}}
		if c.began && !w.Begin() {
			t.Errorf("%s: a run not interrupted may not begin", c.name)
		}
		if c.step != "" {
			w.Event(upgrade.Event{Kind: upgrade.KindStepStart, Step: c.step})
		}
		if line, _ := g.interrupt("SIGINT"); line != c.want {
			t.Errorf("%s: %q, want %q", c.name, line, c.want)
		}
		if g.ctx.Err() == nil {
			t.Errorf("%s: the interrupt did not cancel", c.name)
		}
		if !c.began && w.Begin() {
			t.Errorf("%s: the run may begin its first change after the interrupt said nothing was changed", c.name)
		}
		if line, _ := g.interrupt("SIGINT"); !strings.Contains(line, "already stopping") {
			t.Errorf("%s: a second interrupt: %q", c.name, line)
		}
		g.stop()
	}
}

// The run asking to begin and the first interrupt are one decision, in
// whatever order they come: a run told yes is one the interrupt says it
// rolls back, and a run told no one it says changed nothing.
func TestGuardBeginAndInterruptAgree(t *testing.T) {
	for i := range 200 {
		g := newGuard("the upgrade stops, and what it already changed is rolled back", map[string]string{upgrade.StepRollbck: "rollback"})
		g.beforeChange("the upgrade stops, and nothing was changed")
		began := make(chan bool, 1)
		go func() { began <- g.begin() }()
		line, _ := g.interrupt("SIGINT")
		yes := <-began
		if rolledBack := line == "SIGINT: the upgrade stops, and what it already changed is rolled back"; yes != rolledBack {
			t.Fatalf("try %d: the run was told %v, and the interrupt said %q", i, yes, line)
		}
		g.stop()
	}
}

// The first Ctrl-C while an upgrade is being planned stops it and says
// that nothing was changed, never that what it changed is rolled back; the
// plan, which a slow manifest server can make long, is announced first.
func TestUpgradeInterruptedWhileItIsPlanned(t *testing.T) {
	root := newRoot(t)
	useRoot(t, root)
	useStderr(t)
	saveState(t, root, &instance.State{Current: "1.0.0", Files: []string{"docker/docker-compose.yml"}})
	old := planUpgrade
	t.Cleanup(func() { planUpgrade = old })
	planUpgrade = func(_ *upgrade.Runner, ctx context.Context, _ *instance.State) (*upgrade.Plan, error) {
		if err := syscall.Kill(os.Getpid(), syscall.SIGINT); err != nil {
			return nil, err
		}
		select {
		case <-ctx.Done():
			return nil, ctx.Err()
		case <-time.After(10 * time.Second):
			return nil, errors.New("the interrupt did not stop the plan")
		}
	}
	const url = "https://example.com/manifest.json"
	keepFlags(t)
	cmd := rootCmd()
	cmd.SetArgs([]string{"upgrade", "--root", root, "--manifest", url, "--plain"})
	err := cmd.Execute()
	if err == nil || err.Error() != "upgrade interrupted while it was being planned, nothing was changed" {
		t.Fatalf("an upgrade interrupted while it is planned: %v", err)
	}
	// The guard says what the interrupt does from its own goroutine, which
	// can come after the run returned.
	out := stdout.(*lockedBuffer)
	waitFor(t, "line of the interrupt", func() bool { return strings.Contains(out.String(), "SIGINT: ") })
	text := out.String()
	for _, want := range []string{"Planning the upgrade: reading the manifest at " + url + "\n", "SIGINT: the upgrade stops, and nothing was changed\n"} {
		if !strings.Contains(text, want) {
			t.Errorf("the upgrade lacks %q:\n%s", want, text)
		}
	}
	if strings.Contains(text, "rolled back") {
		t.Errorf("the upgrade says it rolls back what it never changed:\n%s", text)
	}
}

// With --quiet a run prints its steps, its failures and its questions,
// and no title above them; without it, the title comes first.
func TestQuietRunsPrintNoTitle(t *testing.T) {
	for _, quiet := range []bool{true, false} {
		root := newRoot(t)
		s := testSession(t, root)
		out := stdout.(*lockedBuffer)
		old := flagQuiet
		flagQuiet = quiet
		runner := &upgrade.Runner{Inst: s.inst}
		err := s.runScreen(runner, "KVS stack · example.com · upgrade from 1.0.0 to 1.1.0", upgrade.UpgradeSteps, func(ctx context.Context) error {
			runner.Reporter.Event(upgrade.Event{Kind: upgrade.KindStepStart, Step: upgrade.StepPull, Message: "1 image"})
			runner.Reporter.Event(upgrade.Event{Kind: upgrade.KindImages, Total: dockerx.Progress{Current: 2048, Total: 2048, Done: true}})
			runner.Reporter.Event(upgrade.Event{Kind: upgrade.KindDone})
			return nil
		})
		flagQuiet = old
		if err != nil {
			t.Fatal(err)
		}
		text := out.String()
		if titled := strings.Contains(text, "KVS stack · "); titled == quiet {
			t.Errorf("--quiet %v prints the title %v:\n%s", quiet, titled, text)
		}
		if pulled := strings.Contains(text, "all images pulled"); pulled == quiet {
			t.Errorf("--quiet %v prints the total of the pull %v:\n%s", quiet, pulled, text)
		}
		if !strings.Contains(text, "==> Pulling images: 1 image\n") {
			t.Errorf("--quiet %v drops the step:\n%s", quiet, text)
		}
	}
}
