package dockerx

import (
	"context"
	"errors"
	"io"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"syscall"
	"testing"
	"time"
)

// fakeDocker is a docker CLI that records how it was run in a log, then
// does what FAKE_DOCKER_MODE says.
const fakeDocker = `#!/bin/sh
# The fourth descriptor is read first: a pipe the script opens later would
# take it when it is free.
if [ -e /proc/$$/fd/3 ]; then fd3=$(readlink /proc/$$/fd/3); else fd3=none; fi
log=$FAKE_DOCKER_LOG
read -r _ _ _ _ pgid _ < /proc/$$/stat
{
	printf 'args=%s\n' "$*"
	printf 'pid=%s\npgid=%s\n' "$$" "$pgid"
	printf 'dir=%s\n' "$(pwd -P)"
	printf 'COMPOSE_FILE=%s\n' "${COMPOSE_FILE-unset}"
	printf 'COMPOSE_PROGRESS=%s\n' "${COMPOSE_PROGRESS-unset}"
	for key in PWD DOMAIN KVS_PHP_FPM_IMAGE KVS_CRON_IMAGE NEW_SETTING MARIADB_VERSION \
		COMPOSE_ENV_FILES COMPOSE_DISABLE_ENV_FILE FROM_SHELL; do
		eval "value=\${$key-unset}"
		printf '%s=%s\n' "$key" "$value"
	done
	printf 'fd3=%s\n' "$fd3"
} >> "$log"
case "$FAKE_DOCKER_MODE" in
lines)
	printf 'Container kvs-php Recreated\n'
	printf 'Container kvs-nginx Started\n' >&2
	printf 'no newline at the end'
	;;
fail)
	echo 'service "php-fpm" refers to undefined volume x' >&2
	exit 1
	;;
silent)
	printf '  \n' >&2
	exit 1
	;;
services)
	printf 'php-fpm\nmariadb\n\nnginx\n'
	;;
images)
	printf 'kvs-example-nginx\nmariadb:11.8\nghcr.io/x/php:1.1.0@sha256:%064d\nkvs-example-nginx\nlocalhost:5000/kvs/cron\n' 0
	;;
project)
	printf '{"name":"kvs-example","services":{"nginx":{"build":{"context":"."}}}}\n'
	;;
empty)
	;;
stdin)
	cat
	;;
version)
	echo v2.29.7
	;;
term)
	# Ready only once the child traps SIGTERM: on a loaded machine the
	# subshell may not have run its first line yet.
	( trap 'echo child-term >> "$log"; exit 0' TERM; echo child-ready >> "$log"; while :; do sleep 0.05; done ) &
	trap 'echo term >> "$log"; exit 143' TERM
	until grep -q child-ready "$log"; do sleep 0.01; done
	echo ready >> "$log"
	while :; do sleep 0.05; done
	;;
hushed)
	# Stopped as term is, without a word: the notices the shell writes of
	# the sleep the signal ended go nowhere.
	exec 2>/dev/null
	trap 'exit 143' TERM
	echo ready >> "$log"
	while :; do sleep 0.05; done
	;;
chatty)
	# Stopped as hushed is, after a line of its own.
	printf 'Container kvs-php Stopping\n'
	exec 2>/dev/null
	trap 'exit 143' TERM
	echo ready >> "$log"
	while :; do sleep 0.05; done
	;;
stubborn)
	trap '' TERM
	echo ready >> "$log"
	while :; do sleep 0.05; done
	;;
esac
`

// installFakeDocker puts the fake first on PATH and returns its log.
func installFakeDocker(t *testing.T, mode string) string {
	t.Helper()
	bin := t.TempDir()
	if err := os.WriteFile(filepath.Join(bin, "docker"), []byte(fakeDocker), 0o755); err != nil {
		t.Fatal(err)
	}
	log := filepath.Join(t.TempDir(), "docker.log")
	t.Setenv("PATH", bin+string(os.PathListSeparator)+os.Getenv("PATH"))
	t.Setenv("FAKE_DOCKER_LOG", log)
	t.Setenv("FAKE_DOCKER_MODE", mode)
	return log
}

func readLog(t *testing.T, log string) string {
	t.Helper()
	data, err := os.ReadFile(log)
	if err != nil && !errors.Is(err, os.ErrNotExist) {
		t.Fatal(err)
	}
	return string(data)
}

// logged returns the value of the first key=value line of the log.
func logged(text, key string) string {
	for _, line := range strings.Split(text, "\n") {
		if value, ok := strings.CutPrefix(line, key+"="); ok {
			return value
		}
	}
	return ""
}

// waitLogged waits for a line of the log, which is how a test knows the
// fake got as far as a signal can reach it.
func waitLogged(t *testing.T, log, line string) {
	t.Helper()
	deadline := time.Now().Add(10 * time.Second)
	for time.Now().Before(deadline) {
		if strings.Contains(readLog(t, log), "\n"+line+"\n") {
			return
		}
		time.Sleep(10 * time.Millisecond)
	}
	t.Fatalf("the fake never logged %q:\n%s", line, readLog(t, log))
}

// assertOwnGroup checks the fake led a process group of its own, which is
// what keeps a signal of the terminal away from it.
func assertOwnGroup(t *testing.T, text string) {
	t.Helper()
	pid, pgid := logged(text, "pid"), logged(text, "pgid")
	if pid == "" || pid != pgid {
		t.Errorf("the child is not the leader of its own group: pid %s, pgid %s", pid, pgid)
	}
	if pgid == strconv.Itoa(syscall.Getpgrp()) {
		t.Errorf("the child shares the process group of kvsctl (%s)", pgid)
	}
}

func TestComposeRunsInTheProjectWithItsOwnGroup(t *testing.T) {
	log := installFakeDocker(t, "lines")
	t.Setenv("COMPOSE_FILE", "from-an-old-shell.yml")
	dir := t.TempDir()
	var lines []string
	started, err := ComposeStarted(context.Background(), dir, func(line string) { lines = append(lines, line) }, "up", "-d")
	if err != nil || !started {
		t.Fatalf("started %v, err %v", started, err)
	}
	want := []string{"Container kvs-php Recreated", "Container kvs-nginx Started", "no newline at the end"}
	if strings.Join(lines, "|") != strings.Join(want, "|") {
		t.Errorf("lines %q, want %q", lines, want)
	}
	text := readLog(t, log)
	if args := logged(text, "args"); args != "compose up -d" {
		t.Errorf("args %q", args)
	}
	real, _ := filepath.EvalSymlinks(dir)
	if got := logged(text, "dir"); got != real {
		t.Errorf("ran in %q, want the project directory %q", got, real)
	}
	if got := logged(text, "COMPOSE_FILE"); got != "unset" {
		t.Errorf("COMPOSE_FILE reached compose from the shell: %q", got)
	}
	if got := logged(text, "COMPOSE_PROGRESS"); got != "plain" {
		t.Errorf("COMPOSE_PROGRESS = %q", got)
	}
	assertOwnGroup(t, text)
}

func TestComposeFailureQuotesTheOutput(t *testing.T) {
	installFakeDocker(t, "fail")
	started, err := ComposeStarted(context.Background(), t.TempDir(), nil, "up", "-d")
	if !started {
		t.Error("compose ran and failed: it started")
	}
	if err == nil || !strings.Contains(err.Error(), "docker compose up -d: exit status 1") || !strings.Contains(err.Error(), "undefined volume x") {
		t.Errorf("err = %v", err)
	}
	if err := Compose(context.Background(), t.TempDir(), nil, "up", "-d"); err == nil {
		t.Error("Compose must return the same failure")
	}
}

// Compose that never started is what tells a rollback the containers were
// left alone: a context already over, or no docker to run.
func TestComposeThatNeverStarted(t *testing.T) {
	log := installFakeDocker(t, "lines")
	ctx, cancel := context.WithCancel(context.Background())
	cancel()
	started, err := ComposeStarted(ctx, t.TempDir(), nil, "up", "-d")
	if started || !errors.Is(err, context.Canceled) {
		t.Errorf("a cancelled context: started %v, err %v", started, err)
	}
	if text := readLog(t, log); text != "" {
		t.Errorf("the fake ran anyway:\n%s", text)
	}
	t.Setenv("PATH", t.TempDir())
	started, err = ComposeStarted(context.Background(), t.TempDir(), nil, "up", "-d")
	if started || err == nil {
		t.Errorf("no docker binary: started %v, err %v", started, err)
	}
}

// The end of the context stops compose with SIGTERM, sent to its whole
// group: the compose plugin is a child of the docker CLI.
func TestComposeIsStoppedWithSIGTERM(t *testing.T) {
	log := installFakeDocker(t, "term")
	ctx, cancel := context.WithCancel(context.Background())
	done := make(chan error, 1)
	go func() {
		_, err := ComposeStarted(ctx, t.TempDir(), nil, "up", "-d")
		done <- err
	}()
	waitLogged(t, log, "ready")
	cancel()
	select {
	case err := <-done:
		if !errors.Is(err, context.Canceled) {
			t.Errorf("err = %v, want the cancellation", err)
		}
	case <-time.After(10 * time.Second):
		t.Fatal("compose did not stop")
	}
	waitLogged(t, log, "term")
	waitLogged(t, log, "child-term")
}

// A child that ignores SIGTERM is killed killDelay later.
func TestComposeIsKilledWhenItIgnoresSIGTERM(t *testing.T) {
	previous := killDelay
	killDelay = 300 * time.Millisecond
	t.Cleanup(func() { killDelay = previous })
	log := installFakeDocker(t, "stubborn")
	ctx, cancel := context.WithCancel(context.Background())
	done := make(chan error, 1)
	go func() {
		_, err := ComposeStarted(ctx, t.TempDir(), nil, "up", "-d")
		done <- err
	}()
	waitLogged(t, log, "ready")
	cancel()
	start := time.Now()
	select {
	case err := <-done:
		if err == nil {
			t.Error("a killed compose is a failure")
		}
		if waited := time.Since(start); waited < killDelay {
			t.Errorf("killed after %s, before the %s it is given", waited, killDelay)
		}
	case <-time.After(10 * time.Second):
		t.Fatal("a compose that ignores SIGTERM was never killed")
	}
}

func TestActiveServices(t *testing.T) {
	log := installFakeDocker(t, "services")
	t.Setenv("COMPOSE_PROFILES", "from-an-old-shell")
	services, err := ActiveServices(context.Background(), t.TempDir())
	if err != nil {
		t.Fatal(err)
	}
	if strings.Join(services, " ") != "mariadb nginx php-fpm" {
		t.Errorf("services %v", services)
	}
	text := readLog(t, log)
	if args := logged(text, "args"); args != "compose config --services" {
		t.Errorf("args %q", args)
	}
	assertOwnGroup(t, text)
	t.Setenv("FAKE_DOCKER_MODE", "empty")
	if _, err := ActiveServices(context.Background(), t.TempDir()); err == nil {
		t.Error("a project without a service is an error, not an empty stack")
	}
	t.Setenv("FAKE_DOCKER_MODE", "fail")
	if _, err := ActiveServices(context.Background(), t.TempDir()); err == nil || !strings.Contains(err.Error(), "undefined volume x") {
		t.Errorf("err = %v", err)
	}
}

func TestComposeConfigCheck(t *testing.T) {
	log := installFakeDocker(t, "empty")
	if err := ComposeConfigCheck(context.Background(), t.TempDir()); err != nil {
		t.Fatal(err)
	}
	if args := logged(readLog(t, log), "args"); args != "compose config --quiet" {
		t.Errorf("args %q", args)
	}
	t.Setenv("FAKE_DOCKER_MODE", "fail")
	err := ComposeConfigCheck(context.Background(), t.TempDir())
	if err == nil || !strings.Contains(err.Error(), "undefined volume x") {
		t.Errorf("err = %v, want what compose said", err)
	}
}

func TestComposeVersion(t *testing.T) {
	installFakeDocker(t, "version")
	if v, err := ComposeVersion(context.Background()); err != nil || v != "2.29.7" {
		t.Errorf("version %q, %v", v, err)
	}
}

func TestExec(t *testing.T) {
	log := installFakeDocker(t, "stdin")
	var out strings.Builder
	if err := Exec(context.Background(), "kvs-mariadb", strings.NewReader("SELECT 1;\n"), &out, "sh", "-c", "mariadb"); err != nil {
		t.Fatal(err)
	}
	if out.String() != "SELECT 1;\n" {
		t.Errorf("stdout %q", out.String())
	}
	text := readLog(t, log)
	if args := logged(text, "args"); args != "exec -i kvs-mariadb sh -c mariadb" {
		t.Errorf("args %q", args)
	}
	assertOwnGroup(t, text)
	t.Setenv("FAKE_DOCKER_MODE", "fail")
	err := Exec(context.Background(), "kvs-mariadb", nil, &out)
	if err == nil || !strings.Contains(err.Error(), "docker exec kvs-mariadb") || !strings.Contains(err.Error(), "undefined volume x") {
		t.Errorf("err = %v", err)
	}
}

// A command that fails without a word on stderr, or with blanks only, gives
// an error that ends with its status, not with a separator and nothing
// after it.
func TestFailuresQuoteOnlyWhatTheCommandSaid(t *testing.T) {
	installFakeDocker(t, "silent")
	ctx := context.Background()
	if _, err := ActiveServices(ctx, t.TempDir()); err == nil || err.Error() != "docker compose config --services: exit status 1" {
		t.Errorf("docker compose config: %q", err)
	}
	if err := Exec(ctx, "kvs-mariadb", nil, io.Discard); err == nil || err.Error() != "docker exec kvs-mariadb: exit status 1" {
		t.Errorf("docker exec: %q", err)
	}
	if _, err := ComposeStarted(ctx, t.TempDir(), nil, "up", "-d"); err == nil || err.Error() != "docker compose up -d: exit status 1" {
		t.Errorf("docker compose up: %q", err)
	}
	// Stopped when the operation ended: the cause, the status, and still
	// nothing after them, or the last lines compose wrote when it wrote
	// some.
	for _, stop := range []struct{ mode, what, want string }{
		{"hushed", "docker exec", "docker exec kvs-mariadb: context canceled (exit status 143)"},
		{"hushed", "docker compose up", "docker compose up -d: context canceled (exit status 143)"},
		{"chatty", "docker compose up", "docker compose up -d: context canceled (exit status 143)\nContainer kvs-php Stopping"},
	} {
		log := installFakeDocker(t, stop.mode)
		ctx, cancel := context.WithCancel(context.Background())
		done := make(chan error, 1)
		go func() {
			if stop.what == "docker exec" {
				done <- Exec(ctx, "kvs-mariadb", nil, io.Discard)
				return
			}
			_, err := ComposeStarted(ctx, t.TempDir(), nil, "up", "-d")
			done <- err
		}()
		waitLogged(t, log, "ready")
		cancel()
		select {
		case err := <-done:
			if err == nil || err.Error() != stop.want {
				t.Errorf("%s stopped, %s: %q, want %q", stop.what, stop.mode, err, stop.want)
			}
		case <-time.After(10 * time.Second):
			t.Fatalf("%s did not stop", stop.what)
		}
	}
}

func TestLineWriterCutsALineThatNeverEnds(t *testing.T) {
	var got []int
	w := &lineWriter{sink: func(line string) { got = append(got, len(line)) }}
	if _, err := w.Write([]byte(strings.Repeat("x", maxLine+10))); err != nil {
		t.Fatal(err)
	}
	if _, err := w.Write([]byte("tail\n")); err != nil {
		t.Fatal(err)
	}
	if len(got) != 2 || got[0] != maxLine+10 || got[1] != 4 {
		t.Errorf("lines of %v bytes", got)
	}
	for i := 0; i < keptLines+5; i++ {
		_, _ = w.Write([]byte("line " + strconv.Itoa(i) + "\n"))
	}
	kept := strings.Split(w.lines(), "\n")
	if len(kept) != keptLines || kept[len(kept)-1] != "line "+strconv.Itoa(keptLines+4) {
		t.Errorf("kept %d lines ending with %q", len(kept), kept[len(kept)-1])
	}
}

func TestTailBuffer(t *testing.T) {
	b := &tailBuffer{max: 8}
	_, _ = b.Write([]byte("0123456789"))
	_, _ = b.Write([]byte("ab"))
	if b.String() != "456789ab" {
		t.Errorf("kept %q", b.String())
	}
}
