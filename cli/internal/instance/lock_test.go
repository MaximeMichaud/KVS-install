package instance

import (
	"context"
	"errors"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"strconv"
	"strings"
	"syscall"
	"testing"
	"time"

	"github.com/MaximeMichaud/KVS-install/cli/internal/dockerx"
)

// killedRunEnv names the root a run of this test binary locks, before it
// starts a docker command and dies with SIGKILL (killedRun).
const killedRunEnv = "KVSCTL_TEST_KILLED_RUN"

func TestMain(m *testing.M) {
	if root := os.Getenv(killedRunEnv); root != "" {
		killedRun(root)
	}
	os.Exit(m.Run())
}

// killedRun takes the lock of the instance at root as an upgrade does,
// starts a docker compose that keeps running, and is killed with SIGKILL
// once it runs, the way kill -9 ends kvsctl.
func killedRun(root string) {
	inst := &Instance{Root: root}
	if _, err := inst.Lock("upgrade"); err != nil {
		fmt.Fprintln(os.Stderr, err)
		os.Exit(2)
	}
	go func() { _ = dockerx.Compose(context.Background(), root, nil, "up", "-d") }()
	for deadline := time.Now().Add(30 * time.Second); time.Now().Before(deadline); time.Sleep(10 * time.Millisecond) {
		if _, err := os.Stat(os.Getenv("FAKE_DOCKER_PID")); err == nil {
			_ = syscall.Kill(os.Getpid(), syscall.SIGKILL)
		}
	}
	fmt.Fprintln(os.Stderr, "the docker command never started")
	os.Exit(3)
}

// A run killed while its docker compose runs leaves the lock held by that
// compose, and the next run, a recover, is refused with what holds the lock
// until the compose ends.
func TestLockOutlivesARunKilledDuringADockerCommand(t *testing.T) {
	inst := newInstance(t, "DOMAIN=example.com\n")
	bin, pidFile := t.TempDir(), filepath.Join(t.TempDir(), "docker.pid")
	fake := "#!/bin/sh\necho $$ > \"$FAKE_DOCKER_PID.tmp\"\nmv \"$FAKE_DOCKER_PID.tmp\" \"$FAKE_DOCKER_PID\"\nexec sleep 300\n"
	if err := os.WriteFile(filepath.Join(bin, "docker"), []byte(fake), 0o755); err != nil {
		t.Fatal(err)
	}
	output, err := os.Create(filepath.Join(t.TempDir(), "run.log"))
	if err != nil {
		t.Fatal(err)
	}
	defer output.Close()
	ctx, cancel := context.WithTimeout(context.Background(), time.Minute)
	defer cancel()
	run := exec.CommandContext(ctx, os.Args[0], "-test.run=^$")
	run.Env = append(os.Environ(), killedRunEnv+"="+inst.Root, "FAKE_DOCKER_PID="+pidFile,
		"PATH="+bin+string(os.PathListSeparator)+os.Getenv("PATH"))
	run.Stdout, run.Stderr = output, output
	err = run.Run()
	var exit *exec.ExitError
	if !errors.As(err, &exit) || exit.Sys().(syscall.WaitStatus).Signal() != syscall.SIGKILL {
		logged, _ := os.ReadFile(output.Name())
		t.Fatalf("the run must die by SIGKILL: %v\n%s", err, logged)
	}
	data, err := os.ReadFile(pidFile)
	if err != nil {
		t.Fatal(err)
	}
	pid, err := strconv.Atoi(strings.TrimSpace(string(data)))
	if err != nil {
		t.Fatal(err)
	}
	// The docker command leads a process group of its own.
	t.Cleanup(func() { _ = syscall.Kill(-pid, syscall.SIGKILL) })

	release, err := inst.Lock("recover")
	if err == nil {
		release()
		t.Fatal("the lock was free while the docker command of the killed run still ran")
	}
	var held *LockedError
	if !errors.As(err, &held) || held.Command != "upgrade" || !held.Orphaned {
		t.Fatalf("Lock = %v (%+v), want the killed upgrade, orphaned", err, held)
	}
	for _, want := range []string{"the kvsctl run that holds the lock has ended (pid ", "upgrade, started", "a docker command it started still runs and holds it", "fuser -v " + inst.lockPath()} {
		if !strings.Contains(err.Error(), want) {
			t.Errorf("the message lacks %q: %s", want, err)
		}
	}
	if live, err := inst.Holder(); err != nil || live == nil || !live.Orphaned {
		t.Errorf("Holder = %+v, %v; want the orphaned run", live, err)
	}

	// Once the docker command ends, the lock is free.
	if err := syscall.Kill(-pid, syscall.SIGKILL); err != nil {
		t.Fatal(err)
	}
	for deadline := time.Now().Add(10 * time.Second); ; time.Sleep(20 * time.Millisecond) {
		release, err := inst.Lock("recover")
		if err == nil {
			release()
			break
		}
		if time.Now().After(deadline) {
			t.Fatalf("the lock stayed held after the docker command ended: %v", err)
		}
	}
}

// A reader that holds the lock shared for a moment, as kvsctl status does,
// is no docker command a killed run left: Lock asks again and takes the
// lock when the reader lets it go, whatever the lock file names: a run
// that has ended, no run at all (the empty file a script makes), or a
// process that lives and holds nothing (a pid used again). A run that
// lives, which holds the lock exclusive, is named at once. A shared hold
// that outlasts the wait is a script (setup.sh, reconfigure.sh,
// kvs-install.sh hold it shared for their whole run), named as such even
// though the lock file still names a run that has ended; an exclusive one
// that outlasts it is what a killed run left.
func TestLockWaitsForAMomentaryReader(t *testing.T) {
	inst := newInstance(t, "DOMAIN=example.com\n")
	ended := exec.Command("true")
	if err := ended.Run(); err != nil {
		t.Fatal(err)
	}
	hold := func(pid, how int) *os.File {
		t.Helper()
		if err := os.MkdirAll(inst.StateDir(), 0o750); err != nil {
			t.Fatal(err)
		}
		f, err := os.OpenFile(inst.lockPath(), os.O_CREATE|os.O_RDWR, 0o600)
		if err != nil {
			t.Fatal(err)
		}
		if pid == 0 {
			// The lock file a script makes: empty, naming no run.
			err = f.Truncate(0)
		} else {
			err = writeHolder(f, holder{PID: pid, Command: "upgrade", Since: time.Now()})
		}
		if err != nil {
			t.Fatal(err)
		}
		if err := syscall.Flock(int(f.Fd()), how); err != nil {
			t.Fatal(err)
		}
		return f
	}

	for _, pid := range []int{ended.ProcessState.Pid(), 0, os.Getpid()} {
		moment := hold(pid, syscall.LOCK_SH)
		time.AfterFunc(100*time.Millisecond, func() { moment.Close() })
		release, err := inst.Lock("recover")
		if err != nil {
			t.Fatalf("a shared hold of a moment beside a lock file naming pid %d: %v", pid, err)
		}
		release()
	}

	live := hold(os.Getpid(), syscall.LOCK_EX)
	start := time.Now()
	_, err := inst.Lock("recover")
	took := time.Since(start)
	live.Close()
	var held *LockedError
	if !errors.As(err, &held) || held.Orphaned || held.Script || took >= orphanWait {
		t.Errorf("a run that lives: %v after %s, want it named at once", err, took)
	}

	script := hold(ended.ProcessState.Pid(), syscall.LOCK_SH)
	start = time.Now()
	_, err = inst.Lock("recover")
	took = time.Since(start)
	script.Close()
	if !errors.As(err, &held) || !held.Script || held.Orphaned || took < orphanWait {
		t.Errorf("a shared hold that lasts: %v after %s, want a script named after %s", err, took, orphanWait)
	} else if msg := err.Error(); !strings.Contains(msg, "setup.sh, reconfigure.sh or kvs-install.sh") || !strings.Contains(msg, inst.lockPath()) {
		t.Errorf("a script's hold is named %q", msg)
	}

	lasting := hold(ended.ProcessState.Pid(), syscall.LOCK_EX)
	defer lasting.Close()
	start = time.Now()
	_, err = inst.Lock("recover")
	if took := time.Since(start); !errors.As(err, &held) || !held.Orphaned || held.Script || took < orphanWait {
		t.Errorf("an exclusive hold that lasts: %v after %s, want what the run left named after %s", err, took, orphanWait)
	}
}

// The lock a script holds the way setup.sh does (flock --shared on a
// descriptor of its own, for its whole run, from another process) refuses
// every run of kvsctl until the script ends, and the next run then takes it.
func TestScriptHoldRefusesARunUntilItEnds(t *testing.T) {
	inst := newInstance(t, "DOMAIN=example.com\n")
	if _, err := exec.LookPath("flock"); err != nil {
		t.Skip("flock(1) is not installed")
	}
	if err := os.MkdirAll(inst.StateDir(), 0o750); err != nil {
		t.Fatal(err)
	}
	ready := filepath.Join(t.TempDir(), "ready")
	script := exec.Command("bash", "-c", `exec {fd}<>"$1" && flock --shared --nonblock "$fd" && : > "$2" && exec sleep 300`, "script", inst.lockPath(), ready)
	if err := script.Start(); err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = script.Process.Kill(); _ = script.Wait() })
	for deadline := time.Now().Add(10 * time.Second); ; time.Sleep(10 * time.Millisecond) {
		if _, err := os.Stat(ready); err == nil {
			break
		}
		if time.Now().After(deadline) {
			t.Fatal("the script never held the lock")
		}
	}
	_, err := inst.Lock("backup")
	var held *LockedError
	if !errors.As(err, &held) || !held.Script {
		t.Fatalf("a run beside a script that holds the lock: %v", err)
	}
	_ = script.Process.Kill()
	_ = script.Wait()
	release, err := inst.Lock("backup")
	if err != nil {
		t.Fatalf("the lock stayed held after the script ended: %v", err)
	}
	release()
}

// A docker command run while the lock is held holds it too, and so does
// anything it leaves running: the lock is free once the run let it go and
// the last of them ended.
func TestReleaseLeavesTheLockToARunningDockerCommand(t *testing.T) {
	inst := newInstance(t, "DOMAIN=example.com\n")
	bin, pidFile := t.TempDir(), filepath.Join(t.TempDir(), "docker.pid")
	// The docker command leaves a process behind, in its process group,
	// and ends.
	fake := "#!/bin/sh\nsleep 300 </dev/null >/dev/null 2>&1 &\necho $$ > \"$FAKE_DOCKER_PID\"\n"
	if err := os.WriteFile(filepath.Join(bin, "docker"), []byte(fake), 0o755); err != nil {
		t.Fatal(err)
	}
	t.Setenv("PATH", bin+string(os.PathListSeparator)+os.Getenv("PATH"))
	t.Setenv("FAKE_DOCKER_PID", pidFile)
	release, err := inst.Lock("upgrade")
	if err != nil {
		t.Fatal(err)
	}
	if err := dockerx.Compose(context.Background(), inst.Root, nil, "up", "-d"); err != nil {
		t.Fatal(err)
	}
	data, err := os.ReadFile(pidFile)
	if err != nil {
		t.Fatal(err)
	}
	group, err := strconv.Atoi(strings.TrimSpace(string(data)))
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = syscall.Kill(-group, syscall.SIGKILL) })
	release()
	if next, err := inst.Lock("recover"); err == nil {
		next()
		t.Fatal("a release must not free the lock what a docker command left running holds")
	}
	if err := syscall.Kill(-group, syscall.SIGKILL); err != nil {
		t.Fatal(err)
	}
	for deadline := time.Now().Add(10 * time.Second); ; time.Sleep(20 * time.Millisecond) {
		next, err := inst.Lock("recover")
		if err == nil {
			next()
			break
		}
		if time.Now().After(deadline) {
			t.Fatalf("the lock stayed held after the docker command ended: %v", err)
		}
	}
}
