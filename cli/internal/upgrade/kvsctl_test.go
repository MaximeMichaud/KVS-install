//go:build linux

package upgrade

import (
	"bytes"
	"encoding/base64"
	"errors"
	"fmt"
	"net"
	"os"
	"os/exec"
	"path/filepath"
	"regexp"
	"slices"
	"sort"
	"strings"
	"sync"
	"syscall"
	"testing"
	"time"

	"golang.org/x/sys/unix"

	"github.com/MaximeMichaud/KVS-install/cli/internal/instance"
)

// The tests of this file build kvsctl and run it as a process of its own on
// a stack of the fake world, with a pseudo-terminal when the scenario needs
// one: what a signal, a terminal that goes away or a closed pipe do to a
// run only shows in a real process, with the signals the kernel sends.

// kvsctlBuild is the kvsctl the tests run, built once for the package.
var kvsctlBuild struct {
	once sync.Once
	path string
	err  error
}

// kvsctlBinary builds kvsctl, with the race detector when the tests run
// with it, and returns its path.
func kvsctlBinary(t *testing.T) string {
	t.Helper()
	if testing.Short() {
		t.Skip("builds kvsctl and runs it as a process")
	}
	kvsctlBuild.once.Do(func() {
		goTool, err := exec.LookPath("go")
		if err != nil {
			kvsctlBuild.err = fmt.Errorf("the go command, which builds kvsctl, is not on PATH: %w", err)
			return
		}
		dir, err := os.MkdirTemp("", "kvsctl-build")
		if err != nil {
			kvsctlBuild.err = err
			return
		}
		afterTests = append(afterTests, func() { os.RemoveAll(dir) })
		path := filepath.Join(dir, "kvsctl")
		args := []string{"build", "-o", path}
		if raceBuild {
			args = append(args, "-race")
		}
		args = append(args, "github.com/MaximeMichaud/KVS-install/cli/cmd/kvsctl")
		if out, err := exec.Command(goTool, args...).CombinedOutput(); err != nil {
			kvsctlBuild.err = fmt.Errorf("go build: %v\n%s", err, out)
			return
		}
		kvsctlBuild.path = path
	})
	if kvsctlBuild.err != nil {
		t.Fatal(kvsctlBuild.err)
	}
	return kvsctlBuild.path
}

// streams is what kvsctl gets as its standard input and output.
type streams int

const (
	// pipes: stdout and stderr go to the test, stdin is /dev/null.
	pipes streams = iota
	// terminal: a pseudo-terminal is stdin, stdout, stderr and the
	// controlling terminal of kvsctl, which leads a session of its own as
	// a login shell does.
	terminal
	// closedPipe: stdout is a pipe nobody reads any more, as when the
	// output goes through head; stderr goes to the test.
	closedPipe
)

// kvsctlRun is kvsctl running as a process on a stack.
type kvsctlRun struct {
	t   *testing.T
	cmd *exec.Cmd
	// pty is the master side of its terminal, nil when it has none.
	pty *os.File
	// out is what it wrote on its terminal, or on stdout and stderr.
	out     lockedBuffer
	drained chan struct{}
	exited  chan struct{}
	// code is the exit code, -1 when a signal killed it, and status how
	// it ended, as the test says it.
	code   int
	status string
}

type lockedBuffer struct {
	mu  sync.Mutex
	buf bytes.Buffer
}

func (b *lockedBuffer) Write(p []byte) (int, error) {
	b.mu.Lock()
	defer b.mu.Unlock()
	return b.buf.Write(p)
}

func (b *lockedBuffer) String() string {
	b.mu.Lock()
	defer b.mu.Unlock()
	return b.buf.String()
}

// e2eStack is a stack on 1.0.0 with 1.1.0 published, whose containers are
// healthy the moment they start: kvsctl as a process looks at them every
// 3 s, which a container still starting would cost each time.
func e2eStack(t *testing.T) *stack {
	t.Helper()
	s := newStack(t, "", rel{version: "1.0.0"}, rel{version: "1.1.0"})
	for _, images := range s.images {
		for _, img := range images {
			s.f.behave(img.Ref, behavior{})
		}
	}
	return s
}

// kvsctl starts kvsctl on the stack with args, the root, the manifest and
// the key of the stack added; args that name a manifest keep theirs.
func (s *stack) kvsctl(io streams, args ...string) *kvsctlRun {
	t := s.t
	t.Helper()
	bin := kvsctlBinary(t)
	args = append(args, "--root", s.root)
	if !slices.Contains(args, "--manifest") {
		args = append(args, "--manifest", "file://"+filepath.Join(s.dir, "manifest.json"))
	}
	cmd := exec.Command(bin, args...)
	cmd.Env = append(os.Environ(), "KVSCTL_RELEASE_KEY="+base64.StdEncoding.EncodeToString(s.pub), "TERM=xterm-256color")
	r := &kvsctlRun{t: t, cmd: cmd, drained: make(chan struct{}), exited: make(chan struct{})}
	var childEnds []*os.File
	switch io {
	case terminal:
		master, slave := openPTY(t)
		r.pty = master
		cmd.Stdin, cmd.Stdout, cmd.Stderr = slave, slave, slave
		cmd.SysProcAttr = &syscall.SysProcAttr{Setsid: true, Setctty: true, Ctty: 0}
		childEnds = append(childEnds, slave)
	case closedPipe:
		reader, writer, err := os.Pipe()
		if err != nil {
			t.Fatal(err)
		}
		reader.Close()
		cmd.Stdout, cmd.Stderr = writer, &r.out
		childEnds = append(childEnds, writer)
	default:
		cmd.Stdout, cmd.Stderr = &r.out, &r.out
	}
	err := cmd.Start()
	for _, f := range childEnds {
		f.Close()
	}
	if err != nil {
		if r.pty != nil {
			r.pty.Close()
		}
		t.Fatal(err)
	}
	if r.pty != nil {
		go r.drain()
	} else {
		close(r.drained)
	}
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
		if r.pty != nil {
			r.pty.Close()
		}
		<-r.drained
	})
	return r
}

// openPTY opens a pseudo-terminal of 160 columns: its master side for the
// test, its slave side for kvsctl.
func openPTY(t *testing.T) (master, slave *os.File) {
	t.Helper()
	master, err := os.OpenFile("/dev/ptmx", os.O_RDWR|unix.O_NOCTTY, 0)
	if err != nil {
		t.Fatalf("a pseudo-terminal: %v", err)
	}
	var n uint32
	conn, err := master.SyscallConn()
	if err == nil {
		var ioctlErr error
		err = conn.Control(func(fd uintptr) {
			if ioctlErr = unix.IoctlSetPointerInt(int(fd), unix.TIOCSPTLCK, 0); ioctlErr != nil {
				return
			}
			if n, ioctlErr = unix.IoctlGetUint32(int(fd), unix.TIOCGPTN); ioctlErr != nil {
				return
			}
			ioctlErr = unix.IoctlSetWinsize(int(fd), unix.TIOCSWINSZ, &unix.Winsize{Row: 40, Col: 160})
		})
		if err == nil {
			err = ioctlErr
		}
	}
	if err == nil {
		slave, err = os.OpenFile(fmt.Sprintf("/dev/pts/%d", n), os.O_RDWR|unix.O_NOCTTY, 0)
	}
	if err != nil {
		master.Close()
		t.Fatalf("a pseudo-terminal: %v", err)
	}
	return master, slave
}

// drain keeps reading what kvsctl writes on its terminal, which would
// block it once the buffer of the terminal is full, and answers the
// position of the cursor the way a terminal does: Bubble Tea asks for it
// when kvsctl starts, after the colour of the background, and would wait
// 5 seconds for an answer that never comes.
func (r *kvsctlRun) drain() {
	defer close(r.drained)
	buf := make([]byte, 4096)
	answered := 0
	for {
		n, err := r.pty.Read(buf)
		_, _ = r.out.Write(buf[:n])
		for asked := strings.Count(r.out.String(), "\x1b[6n"); answered < asked; answered++ {
			_, _ = r.pty.WriteString("\x1b[1;1R")
		}
		if err != nil {
			return
		}
	}
}

var escapeRe = regexp.MustCompile(`\x1b\[[0-?]*[ -/]*[@-~]|\x1b\][^\x07\x1b]*(?:\x07|\x1b\\)|\x1b[()][0-9A-Za-z]|\x1b[=>78]`)

// output is what kvsctl printed, without the escape sequences of the
// screen.
func (r *kvsctlRun) output() string {
	return strings.ReplaceAll(escapeRe.ReplaceAllString(r.out.String(), ""), "\r", "")
}

// wait waits for kvsctl to end and returns its exit code.
func (r *kvsctlRun) wait() int {
	r.t.Helper()
	select {
	case <-r.exited:
	case <-time.After(2 * time.Minute):
		r.t.Fatalf("kvsctl %s did not end in 2 minutes; it printed:\n%s", strings.Join(r.cmd.Args[1:], " "), r.output())
	}
	select {
	case <-r.drained:
	case <-time.After(10 * time.Second):
	}
	return r.code
}

// waitFor waits until cond holds; kvsctl ending first, or a minute passing,
// fails the test.
func (r *kvsctlRun) waitFor(what string, cond func() bool) {
	r.t.Helper()
	deadline := time.Now().Add(time.Minute)
	for !cond() {
		select {
		case <-r.exited:
			if cond() {
				return
			}
			r.t.Fatalf("kvsctl ended (%s) before %s; it printed:\n%s", r.status, what, r.output())
		case <-time.After(10 * time.Millisecond):
		}
		if time.Now().After(deadline) {
			r.t.Fatalf("still no %s after a minute; kvsctl printed:\n%s", what, r.output())
		}
	}
}

// send types text on the terminal of kvsctl.
func (r *kvsctlRun) send(text string) {
	r.t.Helper()
	if _, err := r.pty.WriteString(text); err != nil {
		r.t.Fatal(err)
	}
}

// hangUp closes the master side of the terminal, the way an SSH session or
// a terminal window that goes away does: the kernel hangs the terminal up
// and sends SIGHUP to kvsctl, the leader of its session.
func (r *kvsctlRun) hangUp() {
	r.t.Helper()
	if err := r.pty.Close(); err != nil {
		r.t.Fatal(err)
	}
}

// raw reports whether the screen has put the terminal in raw mode, where
// Ctrl-C is a key it reads and no longer a SIGINT from the terminal.
func (r *kvsctlRun) raw() bool {
	conn, err := r.pty.SyscallConn()
	if err != nil {
		return false
	}
	raw := false
	_ = conn.Control(func(fd uintptr) {
		// On the master side, the terminal settings read are those of
		// the slave side, the ones kvsctl set.
		tio, err := unix.IoctlGetTermios(int(fd), unix.TCGETS)
		raw = err == nil && tio.Lflag&unix.ISIG == 0
	})
	return raw
}

// heldCommand is a docker command the fake keeps waiting until the test
// releases it, or until kvsctl kills it.
type heldCommand struct {
	args    string
	release chan struct{}
	// gone is closed when the docker command went away.
	gone <-chan struct{}
}

// holdFirst holds each of cmds, docker arguments joined, the first time it
// runs; the test receives each once it waits.
func (s *stack) holdFirst(cmds ...string) <-chan *heldCommand {
	matches := make([]func(string) bool, 0, len(cmds))
	for _, c := range cmds {
		matches = append(matches, func(args string) bool { return args == c })
	}
	return s.holdFirstOf(matches...)
}

// dumping matches the docker command that dumps the database, the backup a
// command takes.
func dumping(args string) bool {
	return strings.HasPrefix(args, "exec ") && strings.Contains(args, "mariadb-dump")
}

// replaying matches the docker command that replays a dump into the
// database.
func replaying(args string) bool {
	return strings.HasPrefix(args, "exec ") && strings.HasSuffix(args, `exec mariadb "$MARIADB_DATABASE"`)
}

// holdFirstOf holds the first docker command each of matches accepts, its
// arguments joined, the way holdFirst holds the commands it names.
func (s *stack) holdFirstOf(matches ...func(args string) bool) <-chan *heldCommand {
	ch := make(chan *heldCommand)
	var mu sync.Mutex
	pending := slices.Clone(matches)
	s.f.with(func(f *fakeDocker) {
		f.gate = func(req cliRequest, gone <-chan struct{}) {
			args := strings.Join(req.Args, " ")
			mu.Lock()
			i := slices.IndexFunc(pending, func(match func(string) bool) bool { return match(args) })
			if i >= 0 {
				pending = slices.Delete(pending, i, i+1)
			}
			mu.Unlock()
			if i < 0 {
				return
			}
			h := &heldCommand{args: args, release: make(chan struct{}), gone: gone}
			select {
			case ch <- h:
			case <-gone:
				return
			}
			select {
			case <-h.release:
			case <-gone:
			}
		}
	})
	return ch
}

// next waits for the next docker command the fake holds.
func (r *kvsctlRun) next(held <-chan *heldCommand) *heldCommand {
	r.t.Helper()
	select {
	case h := <-held:
		return h
	case <-r.exited:
		r.t.Fatalf("kvsctl ended (%s) before the docker command it was to wait at; it printed:\n%s", r.status, r.output())
	case <-time.After(time.Minute):
		r.t.Fatalf("no docker command was held after a minute; kvsctl printed:\n%s", r.output())
	}
	return nil
}

// waitUnlocked waits until no process holds the lock of the instance, the
// docker commands a killed kvsctl left behind included: they inherited it.
func (s *stack) waitUnlocked() {
	s.t.Helper()
	path := filepath.Join(s.root, "kvsctl", "lock")
	deadline := time.Now().Add(time.Minute)
	for {
		f, err := os.Open(path)
		if err != nil {
			s.t.Fatal(err)
		}
		err = syscall.Flock(int(f.Fd()), syscall.LOCK_SH|syscall.LOCK_NB)
		f.Close()
		if err == nil {
			return
		}
		if !errors.Is(err, syscall.EWOULDBLOCK) || time.Now().After(deadline) {
			s.t.Fatalf("the lock %s is still held: %v", path, err)
		}
		time.Sleep(10 * time.Millisecond)
	}
}

// closed reports whether ch is closed, for waitFor.
func closed(ch <-chan struct{}) func() bool {
	return func() bool {
		select {
		case <-ch:
			return true
		default:
			return false
		}
	}
}

// runLog is the newest run log of command under the root, "" when there
// is none.
func (s *stack) runLog(command string) string {
	paths, _ := filepath.Glob(filepath.Join(s.root, "kvsctl", "logs", "*-"+command+".log"))
	if len(paths) == 0 {
		return ""
	}
	sort.Strings(paths)
	data, _ := os.ReadFile(paths[len(paths)-1])
	return string(data)
}

// logged is a condition for waitFor: the run log of command has text.
func (s *stack) logged(command, text string) func() bool {
	return func() bool { return strings.Contains(s.runLog(command), text) }
}

// contains fails the test for every one of wants that text lacks.
func contains(t *testing.T, what, text string, wants ...string) {
	t.Helper()
	for _, want := range wants {
		if !strings.Contains(text, want) {
			t.Errorf("%s lacks %q:\n%s", what, want, text)
		}
	}
}

// A terminal that goes away while the screen shows the upgrade stops
// neither the upgrade nor anything it runs: the kernel sends SIGHUP to
// kvsctl, the screen ends, the run carries on to its end and its log says
// what happened.
func TestKvsctlCarriesOnWhenTheTerminalGoesAway(t *testing.T) {
	s := e2eStack(t)
	held := s.holdFirst("compose up -d")
	run := s.kvsctl(terminal, "upgrade", "--yes", "--health-timeout", "20s")
	up := run.next(held)
	run.waitFor("the screen on the terminal", run.raw)
	run.hangUp()
	run.waitFor("the hang-up in the log", s.logged("upgrade", "the terminal went away, kvsctl carries on"))
	if closed(up.gone)() {
		t.Fatal("the hang-up reached the docker command of the upgrade")
	}
	close(up.release)
	if code := run.wait(); code != 0 {
		t.Fatalf("%s, want exit 0; the log:\n%s", run.status, s.runLog("upgrade"))
	}
	s.back("1.1.0")
	contains(t, "the log", s.runLog("upgrade"),
		"release keys from KVSCTL_RELEASE_KEY, not the ones this build embeds",
		"the terminal went away, kvsctl carries on; log: "+filepath.Join(s.root, "kvsctl", "logs"),
		"exit 0")
}

// Ctrl-C in plain mode is a SIGINT the terminal sends to kvsctl alone: the
// docker commands run in process groups of their own. The first one stops
// the upgrade, which rolls back; a second one during the rollback is said
// and ignored, and the rollback runs to its end.
func TestKvsctlIgnoresASecondInterruptDuringTheRollback(t *testing.T) {
	s := e2eStack(t)
	// The upgrade's compose up, then the rollback's: MariaDB keeps its
	// image, so the rollback does not start it alone first.
	held := s.holdFirst("compose up -d", "compose up -d")
	run := s.kvsctl(terminal, "upgrade", "--yes", "--plain", "--health-timeout", "20s")
	up := run.next(held)
	run.send("\x03")
	run.waitFor("the docker command of the upgrade to be stopped", closed(up.gone))
	back := run.next(held)
	if back.args != "compose up -d" {
		t.Fatalf("the rollback was held at %q", back.args)
	}
	run.send("\x03")
	run.waitFor("the second SIGINT in the log", s.logged("upgrade", "SIGINT: the rollback is running and is not interrupted"))
	close(back.release)
	// A SIGINT that reached the docker command of the rollback would have
	// failed it: exit 4 is also a rollback whose docker commands the
	// terminal never interrupted.
	if code := run.wait(); code != 4 {
		t.Fatalf("%s, want exit 4; it printed:\n%s", run.status, run.output())
	}
	s.back("1.0.0")
	log := s.runLog("upgrade")
	contains(t, "the log", log,
		"SIGINT: the upgrade stops, and what it already changed is rolled back",
		"SIGINT: the rollback is running and is not interrupted",
		"exit 4: upgrade to 1.1.0 was cancelled; 1.0.0 is back and healthy")
	out := run.output()
	if !strings.HasPrefix(out, "log: "+filepath.Join(s.root, "kvsctl", "logs")) {
		t.Errorf("the output does not begin with the log:\n%s", out)
	}
	contains(t, "the output", out, "SIGINT: the rollback is running and is not interrupted", "1.0.0 is back and healthy; log: ")
}

// On the screen, Ctrl-C is a key: the first stops the upgrade, which rolls
// back, and the screen says that a second one does not interrupt the
// rollback.
func TestKvsctlScreenKeepsCtrlCFromTheRollback(t *testing.T) {
	s := e2eStack(t)
	held := s.holdFirst("compose up -d", "compose up -d")
	run := s.kvsctl(terminal, "upgrade", "--yes", "--health-timeout", "20s")
	up := run.next(held)
	run.waitFor("the screen on the terminal", run.raw)
	run.send("\x03")
	run.waitFor("the docker command of the upgrade to be stopped", closed(up.gone))
	back := run.next(held)
	run.send("\x03")
	run.waitFor("the screen to say the rollback goes on", func() bool {
		return strings.Contains(run.output(), "rollback in progress: Ctrl-C does not interrupt it")
	})
	close(back.release)
	if code := run.wait(); code != 4 {
		t.Fatalf("%s, want exit 4; it printed:\n%s", run.status, run.output())
	}
	s.back("1.0.0")
	contains(t, "the log", s.runLog("upgrade"),
		"Ctrl-C: the upgrade stops, and what it already changed is rolled back",
		"Ctrl-C: the rollback is running and is not interrupted",
		"exit 4")
	contains(t, "the screen", run.output(), "log: "+filepath.Join(s.root, "kvsctl", "logs"))
}

// An upgrade whose output nobody reads any more, piped into head that
// quit, runs to its end: the writes fail and the run goes on.
func TestKvsctlCarriesOnWhenStdoutIsClosed(t *testing.T) {
	s := e2eStack(t)
	run := s.kvsctl(closedPipe, "upgrade", "--yes", "--health-timeout", "20s")
	if code := run.wait(); code != 0 {
		t.Fatalf("%s, want exit 0; stderr:\n%s\nthe log:\n%s", run.status, run.output(), s.runLog("upgrade"))
	}
	s.back("1.1.0")
	contains(t, "the log", s.runLog("upgrade"), "exit 0")
}

// While the journal of an interrupted run is there, status names it first,
// the commands that would change the stack refuse without writing a log,
// and recover finishes the run.
func TestKvsctlRefusesUntilRecover(t *testing.T) {
	s := e2eStack(t)
	s.cutUpgrade(s.runner(), isStep(KindStepStart, StepVerify))
	if s.journal() == nil {
		t.Fatal("the cut run left no journal")
	}
	status := s.kvsctl(pipes, "status")
	if code := status.wait(); code != 0 {
		t.Fatalf("status: %s; it printed:\n%s", status.status, status.output())
	}
	out := status.output()
	if i, j := strings.Index(out, "Interrupted"), strings.Index(out, "Site"); i < 0 || j < i || !strings.Contains(out, "run 'kvsctl recover'") {
		t.Errorf("status does not name the interrupted run first:\n%s", out)
	}
	for _, args := range [][]string{{"upgrade", "--yes"}, {"check"}, {"rollback", "--yes"}, {"backup"}} {
		run := s.kvsctl(pipes, args...)
		if code := run.wait(); code != 1 {
			t.Errorf("%s: %s, want exit 1; it printed:\n%s", args[0], run.status, run.output())
		}
		contains(t, args[0], run.output(), "run 'kvsctl recover'")
		if log := s.runLog(args[0]); log != "" {
			t.Errorf("the refused %s wrote a log:\n%s", args[0], log)
		}
	}
	recovered := s.kvsctl(pipes, "recover", "--yes")
	if code := recovered.wait(); code != 0 {
		t.Fatalf("recover: %s; it printed:\n%s", recovered.status, recovered.output())
	}
	s.back("1.0.0")
	contains(t, "the log of recover", s.runLog("recover"), "exit 0")
	again := s.kvsctl(pipes, "status")
	if code := again.wait(); code != 0 || strings.Contains(again.output(), "Interrupted") {
		t.Errorf("status after recover: %s\n%s", again.status, again.output())
	}
}

// status, check, history and the reminder tell how the last upgrade ended
// from what the history keeps of it. An upgrade whose rollback failed too,
// which recover finished, failed: its own cause is named with the log of
// its run, and the next step waits for that cause to be fixed. So does an
// upgrade the engine failed in words that name a cancel: only the first
// Ctrl-C or a SIGTERM makes a cancelled run.
func TestKvsctlStatusTellsHowTheLastUpgradeEnded(t *testing.T) {
	cases := []struct {
		name  string
		setup func(s *stack)
		code  int
		cause string
	}{
		{"a failed rollback finished by recover", func(s *stack) {
			s.f.behave(s.images["1.1.0"]["nginx"].Ref, behavior{unhealthy: true})
			// The upgrade's compose up, then the rollback's.
			s.failAt(2, "compose up -d", "Error response from daemon: no space left on device")
		}, 5, "not healthy after 1s: kvs-nginx is unhealthy"},
		{"an engine that answers context canceled", func(s *stack) {
			s.failOnce("compose up -d", "Error response from daemon: context canceled")
		}, 4, "docker compose up -d: exit status 1: Error response from daemon: context canceled"},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			s := e2eStack(t)
			c.setup(s)
			upgrade := s.kvsctl(pipes, "upgrade", "--yes", "--health-timeout", "1s")
			if code := upgrade.wait(); code != c.code {
				t.Fatalf("upgrade: %s, want exit %d; it printed:\n%s", upgrade.status, c.code, upgrade.output())
			}
			if c.code == 5 {
				recovered := s.kvsctl(pipes, "recover", "--yes", "--health-timeout", "20s")
				if code := recovered.wait(); code != 0 {
					t.Fatalf("recover: %s; it printed:\n%s", recovered.status, recovered.output())
				}
			}
			s.back("1.0.0")
			history := s.state().History
			at := history[len(history)-1].Date.UTC().Format("2006-01-02 15:04 UTC")
			logs, _ := filepath.Glob(filepath.Join(s.root, "kvsctl", "logs", "*-upgrade.log"))
			if len(logs) != 1 {
				t.Fatalf("upgrade logs: %v", logs)
			}
			last := "Last upgrade to 1.1.0 failed on " + at + " and was rolled back: " + c.cause + " (log: " + logs[0] + ")\n"
			status := s.kvsctl(pipes, "status")
			if code := status.wait(); code != 0 {
				t.Fatalf("status: %s; it printed:\n%s", status.status, status.output())
			}
			contains(t, "status", status.output(), last, "' once the cause is fixed\n")
			check := s.kvsctl(pipes, "check")
			if code := check.wait(); code != 0 {
				t.Fatalf("check: %s; it printed:\n%s", check.status, check.output())
			}
			contains(t, "check", check.output(), last)
			// The reminder after a command that reads the history.
			listed := s.kvsctl(pipes, "history")
			if code := listed.wait(); code != 0 {
				t.Fatalf("history: %s; it printed:\n%s", listed.status, listed.output())
			}
			contains(t, "history", listed.output(), "' once the cause is fixed: the last upgrade to 1.1.0 failed on "+at+" and was rolled back ("+c.cause+")")
		})
	}
}

// An interrupt during the dump a command takes first ends it in plain
// words: restore says that the backup before it was interrupted and that
// nothing was changed, and the backup step of an upgrade that it was
// cancelled. Neither gives the error of the docker command the interrupt
// stopped as the outcome of a step or of the run.
func TestKvsctlInterruptDuringTheDumpEndsPlainly(t *testing.T) {
	s := e2eStack(t)
	archive := s.kvsctlBackup()
	held := s.holdFirstOf(dumping)
	restore := s.kvsctl(pipes, "restore", archive, "--yes")
	h := restore.next(held)
	_ = restore.cmd.Process.Signal(syscall.SIGTERM)
	restore.waitFor("the dump to go", closed(h.gone))
	if code := restore.wait(); code != 1 {
		t.Fatalf("restore: %s, want exit 1; it printed:\n%s", restore.status, restore.output())
	}
	if out := restore.output(); !strings.HasSuffix(out, "\nkvsctl: restore interrupted during the backup before it, nothing was changed\n") {
		t.Errorf("restore does not end in plain words:\n%s", out)
	}

	held = s.holdFirstOf(dumping)
	upgrade := s.kvsctl(pipes, "upgrade", "--yes")
	h = upgrade.next(held)
	_ = upgrade.cmd.Process.Signal(syscall.SIGINT)
	upgrade.waitFor("the dump to go", closed(h.gone))
	if code := upgrade.wait(); code != 1 {
		t.Fatalf("upgrade: %s, want exit 1; it printed:\n%s", upgrade.status, upgrade.output())
	}
	out := upgrade.output()
	contains(t, "upgrade", out, "\n==> Backup: database and configuration\n", "\n    FAILED: cancelled\n",
		"\nkvsctl: upgrade to 1.1.0 cancelled: nothing was changed, the stack is still on 1.0.0\n")
	for _, line := range strings.Split(out, "\n") {
		if strings.Contains(line, "FAILED") && strings.Contains(line, "context canceled") {
			t.Errorf("a step or the run ends on the error of the stopped command: %q", line)
		}
	}
	s.back("1.0.0")
}

// The recover that finishes a restore cut during its replay shows a
// restore step, then the verification of the stack, and an interrupt
// during it is refused as during any recovery: the replay of the archive
// is under way and runs to its end.
func TestKvsctlRecoverOfARestoreIsNotInterrupted(t *testing.T) {
	s := e2eStack(t)
	archive := s.kvsctlBackup()
	s.writeData("data-2")
	held := s.holdFirstOf(replaying)
	restore := s.kvsctl(pipes, "restore", filepath.Base(archive), "--yes")
	replay := restore.next(held)
	if err := restore.cmd.Process.Kill(); err != nil {
		t.Fatal(err)
	}
	restore.wait()
	close(replay.release)
	s.waitUnlocked()
	held = s.holdFirstOf(replaying)
	recovered := s.kvsctl(pipes, "recover", "--yes", "--plain")
	h := recovered.next(held)
	_ = recovered.cmd.Process.Signal(syscall.SIGINT)
	recovered.waitFor("the interrupt to be answered", func() bool { return strings.Contains(recovered.output(), "SIGINT: ") })
	close(h.release)
	if code := recovered.wait(); code != 0 {
		t.Fatalf("recover: %s, want exit 0; it printed:\n%s", recovered.status, recovered.output())
	}
	out := recovered.output()
	contains(t, "recover", out, "\n==> Restoring the database: the restore of "+filepath.Base(archive)+"\n",
		"\n    SIGINT: the recovery is running and is not interrupted\n",
		"done: the database holds "+filepath.Base(archive)+" and the services start again",
		"\n==> Verifying: containers, site, admin\n", "done: healthy")
	if db, _, _, _ := s.world(); db != "data-1" {
		t.Errorf("the database holds %q, want data-1, which the archive holds", db)
	}
	if j := s.journal(); j != nil {
		t.Errorf("the journal is still there: %+v", j)
	}
}

// A restore interrupted while compose stops the services that write ends
// on one plain line too: the error of the stopped command is only the line
// of the run that records it.
func TestKvsctlRestoreInterruptedWhileItStopsTheWritersEndsPlainly(t *testing.T) {
	s := e2eStack(t)
	archive := s.kvsctlBackup()
	s.writeData("data-2")
	held := s.holdFirstOf(func(args string) bool { return strings.HasPrefix(args, "compose stop ") })
	restore := s.kvsctl(pipes, "restore", filepath.Base(archive), "--yes")
	h := restore.next(held)
	_ = restore.cmd.Process.Signal(syscall.SIGTERM)
	restore.waitFor("the stop to go", closed(h.gone))
	if code := restore.wait(); code != 1 {
		t.Fatalf("restore: %s, want exit 1; it printed:\n%s", restore.status, restore.output())
	}
	out := restore.output()
	if !strings.HasSuffix(out, "\nkvsctl: restore interrupted while it stopped the services that write, nothing was changed\n") {
		t.Errorf("restore does not end in plain words:\n%s", out)
	}
	for _, line := range strings.Split(out, "\n") {
		if strings.HasPrefix(line, ";") || (strings.Contains(line, "context canceled") && !strings.HasPrefix(line, "  cancelled: docker compose stop ")) {
			t.Errorf("a line carries the error of the stopped command: %q", line)
		}
	}
	if j := s.journal(); j != nil {
		t.Errorf("the journal is still there: %+v", j)
	}
	if db, replays, _, _ := s.world(); db != "data-2" || len(replays) != 0 {
		t.Errorf("database %q, replays %v", db, replays)
	}
}

// A Ctrl-C once the release is staged, before the upgrade writes its
// journal, stops it there: no journal, no file laid and none laid back.
// The line of the interrupt and the last line both say that nothing was
// changed, and the reads the interrupt cut short are no errors of the
// stack.
func TestKvsctlInterruptBeforeTheJournalChangesNothing(t *testing.T) {
	s := e2eStack(t)
	staged := func(args string) bool {
		if !strings.Contains(args, "config --services") {
			return false
		}
		_, err := os.Stat(filepath.Join(s.root, "kvsctl", "releases", "1.1.0"))
		return err == nil
	}
	held := s.holdFirstOf(staged)
	run := s.kvsctl(pipes, "upgrade", "--plain", "--yes", "--health-timeout", "20s")
	h := run.next(held)
	if err := run.cmd.Process.Signal(syscall.SIGINT); err != nil {
		t.Fatal(err)
	}
	run.waitFor("the line of the interrupt", func() bool { return strings.Contains(run.output(), "SIGINT: ") })
	close(h.release)
	if code := run.wait(); code != 1 {
		t.Fatalf("upgrade: %s, want exit 1; it printed:\n%s", run.status, run.output())
	}
	out := run.output()
	if !strings.HasSuffix(out, "\nkvsctl: upgrade to 1.1.0 cancelled: nothing was changed, the stack is still on 1.0.0\n") {
		t.Errorf("the upgrade does not end on nothing was changed:\n%s", out)
	}
	if !strings.Contains(out, "\n    SIGINT: the upgrade stops, and nothing was changed\n") {
		t.Errorf("the interrupt does not say that nothing was changed:\n%s", out)
	}
	for _, laid := range []string{"Rolling back", "are back", "done: 6 files"} {
		if strings.Contains(out, laid) {
			t.Errorf("the run went on to %q:\n%s", laid, out)
		}
	}
	for _, said := range []string{"rolled back", "could not be listed", "could not be read"} {
		if strings.Contains(out, said) {
			t.Errorf("the run says %q:\n%s", said, out)
		}
	}
	if j := s.journal(); j != nil {
		t.Errorf("the journal is there: %+v", j)
	}
	s.back("1.0.0")
}

// A rollback that gives up before its first change starts again the
// services it stopped; the ones that do not start are named with the
// command that starts them, under --quiet too: the site is down until
// someone runs it.
func TestKvsctlQuietRollbackNamesTheServicesItCouldNotStart(t *testing.T) {
	s := e2eStack(t)
	if err := s.upgrade(s.runner()); err != nil {
		t.Fatal(err)
	}
	held := s.holdFirstOf(func(args string) bool { return strings.HasPrefix(args, "compose stop ") })
	s.failOnce("compose start nginx php-fpm", "Error response from daemon: no space left on device")
	run := s.kvsctl(pipes, "rollback", "--yes", "--quiet", "--restore-db")
	h := run.next(held)
	_ = run.cmd.Process.Signal(syscall.SIGTERM)
	run.waitFor("the stop to go", closed(h.gone))
	if code := run.wait(); code != 1 {
		t.Fatalf("rollback: %s, want exit 1; it printed:\n%s", run.status, run.output())
	}
	contains(t, "rollback --quiet", run.output(),
		"\n    nginx, php-fpm could not be started again: ",
		"no space left on device; run 'docker compose start nginx php-fpm' in "+filepath.Join(s.root, "docker")+"\n",
		"kvsctl: rollback interrupted while it stopped the services that write, ")
	s.back("1.1.0")
}

// A command that changes the stack asks the engine what it is before its
// first change. An interrupt while it asks ends the command on what it
// left, never on an engine that does not answer: the error of the request
// it cut short is a line of its log.
func TestKvsctlInterruptedWhileItAsksTheEngine(t *testing.T) {
	cases := []struct {
		name string
		// args readies the stack and returns the command line.
		args func(s *stack) []string
		want string
	}{
		{"restore", func(s *stack) []string {
			return []string{"restore", filepath.Base(s.kvsctlBackup()), "--yes"}
		}, "restore interrupted, nothing was changed"},
		{"rollback", func(s *stack) []string {
			if err := s.upgrade(s.runner()); err != nil {
				s.t.Fatal(err)
			}
			return []string{"rollback", "--yes"}
		}, "rollback interrupted, nothing was changed, the stack is still on 1.1.0"},
		{"recover", func(s *stack) []string {
			s.cutUpgrade(s.runner(), isStep(KindStepStart, StepVerify))
			return []string{"recover", "--yes"}
		}, "recover interrupted, nothing was changed"},
		{"clean", func(s *stack) []string {
			if err := s.upgrade(s.runner()); err != nil {
				s.t.Fatal(err)
			}
			return []string{"clean", "--yes"}
		}, "clean interrupted, nothing was removed"},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			s := e2eStack(t)
			args := c.args(s)
			journal, state := s.journal(), s.state()
			asked, let := s.holdInfo()
			run := s.kvsctl(pipes, args...)
			select {
			case <-asked:
			case <-run.exited:
				t.Fatalf("%s ended (%s) before it asked the engine; it printed:\n%s", c.name, run.status, run.output())
			case <-time.After(time.Minute):
				t.Fatalf("%s did not ask the engine; it printed:\n%s", c.name, run.output())
			}
			_ = run.cmd.Process.Signal(syscall.SIGTERM)
			code := run.wait()
			let()
			out := run.output()
			if code != 1 || !strings.HasSuffix(out, "\nkvsctl: "+c.want+"\n") {
				t.Errorf("%s: %s, want exit 1 on %q; it printed:\n%s", c.name, run.status, c.want, out)
			}
			if strings.Contains(out, "cannot talk to the Docker engine") {
				t.Errorf("the interrupted %s blames the engine:\n%s", c.name, out)
			}
			contains(t, "the log of "+c.name, s.runLog(c.name), "Z cancelled: kvsctl cannot talk to the Docker engine (", "Z exit 1: "+c.want+"\n")
			if after := s.journal(); (after == nil) != (journal == nil) {
				t.Errorf("the journal was %+v and is %+v", journal, after)
			}
			if after := s.state(); after.Current != state.Current || len(after.History) != len(state.History) {
				t.Errorf("the state changed: %s with %d entries, then %s with %d", state.Current, len(state.History), after.Current, len(after.History))
			}
		})
	}
}

// holdInfo holds the first request that asks the engine what it is until
// the test lets it go, at its end at the latest; the fake answers nothing
// else meanwhile. asked is closed once the request came.
func (s *stack) holdInfo() (asked <-chan struct{}, let func()) {
	came, release := make(chan struct{}), make(chan struct{})
	var first, done sync.Once
	s.f.with(func(f *fakeDocker) {
		f.apiFail = func(path string) bool {
			if path == "/info" {
				held := false
				first.Do(func() { close(came); held = true })
				if held {
					<-release
				}
			}
			return false
		}
	})
	let = func() { done.Do(func() { close(release) }) }
	s.t.Cleanup(let)
	return came, let
}

// An engine too old for kvsctl is named with what to install: status
// stops at it, upgrade is blocked by it and changes nothing.
func TestKvsctlNamesAnEngineTooOld(t *testing.T) {
	s := e2eStack(t)
	s.f.with(func(f *fakeDocker) {
		f.refusal = "client version 1.47 is too new. Maximum supported API version is 1.39"
	})
	status := s.kvsctl(pipes, "status")
	if code := status.wait(); code != 1 {
		t.Errorf("status: %s, want exit 1", status.status)
	}
	contains(t, "status", status.output(), "speaks API 1.39, and kvsctl needs API 1.40 or newer")
	upgrade := s.kvsctl(pipes, "upgrade", "--yes")
	if code := upgrade.wait(); code != 3 {
		t.Errorf("upgrade: %s, want exit 3", upgrade.status)
	}
	contains(t, "upgrade", upgrade.output(), "Blocked", "speaks API 1.39", "upgrade Docker")
	if strings.Contains(upgrade.output(), "Download") {
		t.Errorf("the plan of an engine it cannot read says more than the blocker:\n%s", upgrade.output())
	}
	s.back("1.0.0")
}

// Every command ends its help with the exit codes, and a command line
// kvsctl cannot parse exits 2.
func TestKvsctlHelpAndUsage(t *testing.T) {
	s := e2eStack(t)
	for _, command := range []string{"upgrade", "rollback", "recover", "status"} {
		help := s.kvsctl(pipes, command, "--help")
		if code := help.wait(); code != 0 {
			t.Errorf("%s --help: %s", command, help.status)
		}
		contains(t, command+" --help", help.output(), "Exit codes:", "  8  the change succeeded but could not be recorded: run 'kvsctl recover'")
	}
	wrong := s.kvsctl(pipes, "upgrade", "--no-such-flag")
	if code := wrong.wait(); code != 2 {
		t.Errorf("an unknown flag: %s, want exit 2; it printed:\n%s", wrong.status, wrong.output())
	}
}

// Once its run is over, kvsctl gives Ctrl-C back. A command that changes
// the stack reads the manifest after its run, to say whether a newer
// release exists, and a server that never answers must not keep it from
// ending at the first Ctrl-C.
func TestKvsctlEndsAtCtrlCOnceItsRunIsOver(t *testing.T) {
	s := e2eStack(t)
	addr, asked := silentServer(t)
	run := s.kvsctl(terminal, "backup", "--manifest", "http://"+addr+"/manifest.json")
	select {
	case <-asked:
	case <-run.exited:
		t.Fatalf("kvsctl ended (%s) before it read the manifest; it printed:\n%s", run.status, run.output())
	case <-time.After(time.Minute):
		t.Fatalf("kvsctl did not read the manifest after a minute; it printed:\n%s", run.output())
	}
	contains(t, "the log", s.runLog("backup"), "exit 0")
	run.send("\x03")
	select {
	case <-run.exited:
	case <-time.After(10 * time.Second):
		t.Fatalf("kvsctl did not end at the Ctrl-C that came after its run; it printed:\n%s", run.output())
	}
	run.wait()
	if run.status != "signal: interrupt" {
		t.Errorf("kvsctl ended with %s, want the Ctrl-C to end it", run.status)
	}
}

// silentServer takes connections and never answers them, the way a server
// behind a firewall that drops its answers looks. It returns its address,
// and a channel that receives one value per connection.
func silentServer(t *testing.T) (string, <-chan struct{}) {
	t.Helper()
	listener, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	asked := make(chan struct{}, 16)
	var mu sync.Mutex
	var conns []net.Conn
	go func() {
		for {
			conn, err := listener.Accept()
			if err != nil {
				return
			}
			mu.Lock()
			conns = append(conns, conn)
			mu.Unlock()
			select {
			case asked <- struct{}{}:
			default:
			}
		}
	}()
	t.Cleanup(func() {
		listener.Close()
		mu.Lock()
		defer mu.Unlock()
		for _, conn := range conns {
			conn.Close()
		}
	})
	return listener.Addr().String(), asked
}

// status shows the run another kvsctl has in progress first, a backup as
// much as an upgrade, and says nothing of it once that run is over.
func TestKvsctlStatusShowsARunInProgress(t *testing.T) {
	s := e2eStack(t)
	held := s.holdFirstOf(dumping)
	backup := s.kvsctl(pipes, "backup")
	dump := backup.next(held)
	status := s.kvsctl(pipes, "status")
	if code := status.wait(); code != 0 {
		t.Fatalf("status: %s; it printed:\n%s", status.status, status.output())
	}
	out := status.output()
	running := fmt.Sprintf("Running      another kvsctl is running (pid %d, backup, started ", backup.cmd.Process.Pid)
	if i, j := strings.Index(out, running), strings.Index(out, "Site"); i < 0 || j < i {
		t.Errorf("status does not show the backup in progress first:\n%s", out)
	}
	close(dump.release)
	if code := backup.wait(); code != 0 {
		t.Fatalf("backup: %s; it printed:\n%s", backup.status, backup.output())
	}
	after := s.kvsctl(pipes, "status")
	if code := after.wait(); code != 0 || strings.Contains(after.output(), "another kvsctl") {
		t.Errorf("status once the backup is over: %s\n%s", after.status, after.output())
	}
}

// restore --env makes sure .env can be replaced before it changes anything:
// a docker directory it cannot write to stops it with exit 1, before the
// backup it takes first and before the replay.
func TestKvsctlRestoreEnvChecksTheEnvFirst(t *testing.T) {
	if os.Geteuid() == 0 {
		t.Skip("root writes to a directory whatever its permissions")
	}
	s := e2eStack(t)
	archive := s.kvsctlBackup()
	before := s.file("docker/.env")
	readOnly(t, filepath.Join(s.root, "docker"))
	run := s.kvsctl(pipes, "restore", "--latest", "--yes", "--env")
	if code := run.wait(); code != 1 {
		t.Fatalf("%s, want exit 1; it printed:\n%s", run.status, run.output())
	}
	contains(t, "restore", run.output(), filepath.Join(s.root, "docker", ".env")+" cannot be replaced", "nothing was changed")
	if _, replays, _, _ := s.world(); len(replays) != 0 {
		t.Errorf("the database was replayed: %v", replays)
	}
	if archives, _ := filepath.Glob(filepath.Join(s.root, "backups", "backup-*.tar")); len(archives) != 1 || archives[0] != archive {
		t.Errorf("the backups are %v, want %s alone", archives, archive)
	}
	if got := s.file("docker/.env"); got != before {
		t.Errorf(".env changed:\n%s", got)
	}
}

// restore --env reads the .env it would leave, the archive's merged with
// the live values kvsctl keeps, the way compose reads it, before it changes
// anything: one compose would refuse stops it with exit 1, before the
// backup it takes first and before the replay, whether the archived file
// cannot be read at all, holds a value compose cannot expand, or needs a
// setting kvsctl keeps from the live file, which does not have it.
func TestKvsctlRestoreEnvRefusesAnEnvComposeCannotRead(t *testing.T) {
	s := e2eStack(t)
	archive := s.kvsctlBackup()
	before := s.file("docker/.env")
	original, err := os.ReadFile(archive)
	if err != nil {
		t.Fatal(err)
	}
	if strings.Contains(before, "PHP_CLI_BASE") {
		t.Fatalf("the live .env sets PHP_CLI_BASE:\n%s", before)
	}
	for _, broken := range []string{"SETTING=\"never closed\n", "SETTING=${}\n", "PHP_CLI_BASE=php:8.1-cli\nSETTING=${PHP_CLI_BASE:?}\n"} {
		if err := os.WriteFile(archive, original, 0o600); err != nil {
			t.Fatal(err)
		}
		rewriteArchive(t, archive, func(name string, body []byte) []byte {
			if name == ".env" {
				return append(body, broken...)
			}
			return body
		})
		run := s.kvsctl(pipes, "restore", filepath.Base(archive), "--yes", "--env")
		if code := run.wait(); code != 1 {
			t.Fatalf("%q: %s, want exit 1; it printed:\n%s", broken, run.status, run.output())
		}
		contains(t, "restore", run.output(), "nothing was changed")
		if _, replays, _, _ := s.world(); len(replays) != 0 {
			t.Fatalf("%q: the database was replayed: %v", broken, replays)
		}
		if archives, _ := filepath.Glob(filepath.Join(s.root, "backups", "backup-*.tar")); len(archives) != 1 {
			t.Errorf("%q: the backups are %v, want %s alone", broken, archives, archive)
		}
		if got := s.file("docker/.env"); got != before {
			t.Errorf("%q: .env changed:\n%s", broken, got)
		}
		if j := s.journal(); j != nil {
			t.Fatalf("%q: a journal was left: %+v", broken, j)
		}
	}
}

// A .env that cannot be replaced once the database is replayed leaves the
// restore part way: exit 5, with the log and the ways to finish it, and
// the journal that has every other command wait for recover, which puts
// the .env back without replaying the archive again.
func TestKvsctlRestoreEnvStoppedPartWay(t *testing.T) {
	if os.Geteuid() == 0 {
		t.Skip("root writes to a directory whatever its permissions")
	}
	s := e2eStack(t)
	archive := s.kvsctlBackup()
	s.setEnv("SETTING_LIVE", "1")
	held := s.holdFirstOf(replaying)
	run := s.kvsctl(pipes, "restore", "--latest", "--yes", "--no-backup", "--env")
	replay := run.next(held)
	docker := filepath.Join(s.root, "docker")
	readOnly(t, docker)
	close(replay.release)
	if code := run.wait(); code != 5 {
		t.Fatalf("%s, want exit 5; it printed:\n%s", run.status, run.output())
	}
	contains(t, "restore", run.output(),
		"the database is restored from "+filepath.Base(archive),
		"run 'kvsctl recover' to finish it",
		"tar -xOf "+archive+" .env",
		"; log: "+filepath.Join(s.root, "kvsctl", "logs"))
	if _, replays, _, _ := s.world(); len(replays) != 1 {
		t.Errorf("replays %v, want the one of the archive", replays)
	}
	contains(t, "the log", s.runLog("restore"), "exit 5: ")
	if j := s.journal(); j == nil || j.Action != instance.ActionRestore || j.Phase != instance.PhaseRestart {
		t.Fatalf("journal after the restore stopped: %+v", j)
	}
	// The restore failed, and is said to have: when, and why.
	upgrade := s.kvsctl(pipes, "upgrade", "--yes")
	if code := upgrade.wait(); code != 1 || !strings.Contains(upgrade.output(), "a restore of "+filepath.Base(archive)+" failed during restart on ") ||
		!strings.Contains(upgrade.output(), ".env was not replaced: ") || !strings.Contains(upgrade.output(), "once the cause is fixed, run 'kvsctl recover'") {
		t.Errorf("upgrade while the restore is unfinished: %s\n%s", upgrade.status, upgrade.output())
	}
	if err := os.Chmod(docker, 0o755); err != nil {
		t.Fatal(err)
	}
	recovered := s.kvsctl(pipes, "recover", "--yes", "--plain")
	if code := recovered.wait(); code != 0 {
		t.Fatalf("recover: %s; it printed:\n%s", recovered.status, recovered.output())
	}
	if _, replays, _, _ := s.world(); len(replays) != 1 {
		t.Errorf("recover replayed the archive again: %v", replays)
	}
	if env := s.env(); env["SETTING_LIVE"] != "" || env["DOMAIN"] != "example.com" {
		t.Errorf(".env after recover is not the archive's: %v", env)
	}
	if j := s.journal(); j != nil {
		t.Errorf("the journal is still there: %+v", j)
	}
}

// A restore killed during its replay, by kill -9, the OOM killer or a
// power cut, leaves its journal: while the docker command of the replay
// still runs, it holds the lock it inherited and recover waits for it;
// once it has ended, status names the restore, the commands that would
// work on the half replayed database refuse, the backup and the upgrade
// that would archive it included, and recover replays the archive again,
// from the start, names the backup of the database as it was before, and
// starts the services the restore stopped.
func TestKvsctlRestoreKilledDuringItsReplay(t *testing.T) {
	s := e2eStack(t)
	archive := s.kvsctlBackup()
	s.writeData("data-2")
	held := s.holdFirstOf(replaying)
	run := s.kvsctl(pipes, "restore", filepath.Base(archive), "--yes")
	replay := run.next(held)
	if err := run.cmd.Process.Kill(); err != nil {
		t.Fatal(err)
	}
	if code := run.wait(); code != -1 && code != 137 {
		t.Fatalf("restore: %s, want killed; it printed:\n%s", run.status, run.output())
	}
	early := s.kvsctl(pipes, "recover", "--yes", "--plain")
	if code := early.wait(); code != 6 {
		t.Fatalf("recover while the replay still runs: %s, want exit 6; it printed:\n%s", early.status, early.output())
	}
	contains(t, "recover while the replay still runs", early.output(), "a docker command it started still runs and holds it")
	// Its input cut by the kill, the mariadb client ends with the part of
	// the dump it took, and the lock goes with it.
	close(replay.release)
	s.waitUnlocked()
	s.writeData("partly replayed")
	j := s.journal()
	if j == nil || j.Action != instance.ActionRestore || j.Phase != instance.PhaseReplay || j.Replay != archive || j.Backup == "" {
		t.Fatalf("journal after the kill: %+v", j)
	}
	interrupted := "a restore of " + filepath.Base(archive) + " was interrupted during replay"
	status := s.kvsctl(pipes, "status")
	if code := status.wait(); code != 0 {
		t.Fatalf("status: %s; it printed:\n%s", status.status, status.output())
	}
	contains(t, "status", status.output(), "Interrupted", interrupted, "run 'kvsctl recover'")
	for _, args := range [][]string{{"upgrade", "--yes"}, {"backup"}, {"restore", filepath.Base(archive), "--yes"}} {
		refused := s.kvsctl(pipes, args...)
		if code := refused.wait(); code != 1 {
			t.Errorf("%s: %s, want exit 1; it printed:\n%s", args[0], refused.status, refused.output())
		}
		contains(t, args[0], refused.output(), interrupted)
	}
	recovered := s.kvsctl(pipes, "recover", "--yes", "--plain")
	if code := recovered.wait(); code != 0 {
		t.Fatalf("recover: %s; it printed:\n%s", recovered.status, recovered.output())
	}
	contains(t, "the log of recover", s.runLog("recover"), "the database as it was before the restore is in "+j.Backup, "exit 0")
	// The replays are the one the kill cut, then the one of recover.
	if db, replays, _, _ := s.world(); db != "data-1" || len(replays) != 2 {
		t.Errorf("after recover: database %q, replays %v", db, replays)
	}
	if stopped := s.stopped(); len(stopped) != 0 {
		t.Errorf("still stopped after recover: %v", stopped)
	}
	if j := s.journal(); j != nil {
		t.Errorf("the journal is still there: %+v", j)
	}
}

// An archive of another site is refused unless --other-site: its database
// holds the settings and the server paths of that site. Taken with the
// flag, the question names both sites, and --env keeps the live values of
// the settings that name this one.
func TestKvsctlRestoreOfAnotherSite(t *testing.T) {
	s := e2eStack(t)
	archive := s.kvsctlBackup()
	rewriteArchive(t, archive, func(name string, body []byte) []byte {
		switch name {
		case "backup.json":
			return bytes.Replace(body, []byte(`"domain": "example.com"`), []byte(`"domain": "example.org"`), 1)
		case ".env":
			text := strings.Replace(string(body), "DOMAIN=example.com", "DOMAIN=example.org", 1)
			text = strings.Replace(text, "SITE_PREFIX=kvs", "SITE_PREFIX=org", 1)
			return []byte(text + "COMPOSE_PROJECT_NAME=org\nSETTING_ARCHIVED=1\n")
		}
		return body
	})
	refused := s.kvsctl(pipes, "restore", filepath.Base(archive), "--yes", "--env")
	if code := refused.wait(); code != 1 {
		t.Fatalf("restore: %s, want exit 1; it printed:\n%s", refused.status, refused.output())
	}
	contains(t, "restore", refused.output(), filepath.Base(archive)+" is an archive of example.org, and this site is example.com", "pass --other-site", "nothing was changed")
	if db, replays, _, _ := s.world(); db != "data-1" || len(replays) != 0 || s.journal() != nil {
		t.Fatalf("the refused restore changed the stack: database %q, replays %v", db, replays)
	}

	s.writeData("data-2")
	run := s.kvsctl(pipes, "restore", filepath.Base(archive), "--yes", "--env", "--other-site")
	if code := run.wait(); code != 0 {
		t.Fatalf("restore --other-site: %s; it printed:\n%s", run.status, run.output())
	}
	contains(t, "restore", run.output(), "this archive comes from example.org, another site than example.com (--other-site)")
	contains(t, "the log", s.runLog("restore"), "question: Restore the database of example.com from "+filepath.Base(archive)+" (an archive of example.org), and its .env?")
	env := s.env()
	if env["DOMAIN"] != "example.com" || env["SITE_PREFIX"] != "kvs" || env["SETTING_ARCHIVED"] != "1" {
		t.Errorf(".env after the restore: %v", env)
	}
	if _, ok := env["COMPOSE_PROJECT_NAME"]; ok {
		t.Errorf("the archive named the compose project: %v", env)
	}
	if db, _, _, _ := s.world(); db != "data-1" {
		t.Errorf("database %q", db)
	}
}

// The archive an upgrade took records the KVS of the site, and kvsctl
// restore names it, in what it shows of the archive and in its question:
// the replay takes the tables back to that KVS, whatever the files of the
// site run.
func TestKvsctlRestoreNamesTheKVSOfTheArchive(t *testing.T) {
	s := e2eStack(t)
	r := s.runner()
	kvsSite(t, r, "6.3.1")
	if err := s.upgrade(r); err != nil {
		t.Fatalf("upgrade: %v", err)
	}
	archive := s.state().UpgradeBackup
	run := s.kvsctl(pipes, "restore", filepath.Base(archive), "--yes")
	if code := run.wait(); code != 0 {
		t.Fatalf("restore: %s; it printed:\n%s", run.status, run.output())
	}
	contains(t, "restore", run.output(), ", KVS 6.3.1, by kvsctl ")
	contains(t, "the log", s.runLog("restore"), "question: Restore the database of example.com from "+filepath.Base(archive)+" (KVS 6.3.1")
}

// kvsctl restore backs up the live database before it replays the archive
// over it, keeps that backup and says where it is: a restore of the wrong
// archive is never the last word.
func TestKvsctlRestoreBacksUpTheLiveDatabaseFirst(t *testing.T) {
	s := e2eStack(t)
	archive := s.kvsctlBackup()
	s.writeData("data-2")
	run := s.kvsctl(pipes, "restore", "--latest", "--yes")
	if code := run.wait(); code != 0 {
		t.Fatalf("restore: %s; it printed:\n%s", run.status, run.output())
	}
	archives, _ := filepath.Glob(filepath.Join(s.root, "backups", "backup-*.tar"))
	safety := ""
	for _, a := range archives {
		if a != archive {
			safety = a
		}
	}
	if len(archives) != 2 || safety == "" {
		t.Fatalf("the backups after the restore are %v, want %s and a backup of the live database", archives, archive)
	}
	if got := s.holds(safety); got != "data-2" {
		t.Errorf("the backup taken before the restore holds %q, want the live database", got)
	}
	if db, replays, _, _ := s.world(); db != "data-1" || len(replays) != 1 {
		t.Errorf("after the restore: database %q, replays %v", db, replays)
	}
	contains(t, "restore", run.output(), safety)
}

// A restore whose replay stops, the server gone in the middle of the dump,
// exits 5: the database may hold part of the archive, and the stack is in
// no known state. The journal says the restore failed, when and why, which
// status shows, and recover replays the archive again once the cause is
// gone.
func TestKvsctlRestoreReplayStoppedIsExit5(t *testing.T) {
	s := e2eStack(t)
	archive := s.kvsctlBackup()
	s.writeData("data-2")
	s.f.with(func(f *fakeDocker) {
		f.hook = func(_ *fakeDocker, req cliRequest) (cliResponse, bool) {
			if !replaying(strings.Join(req.Args, " ")) {
				return cliResponse{}, false
			}
			return cliResponse{Stderr: "ERROR 2013 (HY000) at line 40: Lost connection to server during query\n", Code: 1}, true
		}
	})
	run := s.kvsctl(pipes, "restore", filepath.Base(archive), "--yes")
	if code := run.wait(); code != 5 {
		t.Fatalf("restore: %s, want exit 5; it printed:\n%s", run.status, run.output())
	}
	contains(t, "restore", run.output(),
		"the replay of "+filepath.Base(archive)+" stopped: ",
		"Lost connection to server during query",
		"the database may be partly replayed",
		"'kvsctl recover' replays "+filepath.Base(archive)+" again")
	contains(t, "the log", s.runLog("restore"), "exit 5: ")
	status := s.kvsctl(pipes, "status")
	if code := status.wait(); code != 0 {
		t.Fatalf("status: %s; it printed:\n%s", status.status, status.output())
	}
	contains(t, "status", status.output(), "a restore of "+filepath.Base(archive)+" failed during replay on ", "Lost connection to server during query", "once the cause is fixed, run 'kvsctl recover'")
	s.f.with(func(f *fakeDocker) { f.hook = nil })
	recovered := s.kvsctl(pipes, "recover", "--yes", "--plain")
	if code := recovered.wait(); code != 0 {
		t.Fatalf("recover: %s; it printed:\n%s", recovered.status, recovered.output())
	}
	if db, replays, _, _ := s.world(); db != "data-1" || len(replays) != 1 {
		t.Errorf("after recover: database %q, replays %v", db, replays)
	}
	if stopped := s.stopped(); len(stopped) != 0 {
		t.Errorf("still stopped after recover: %v", stopped)
	}
}

// A restore whose stack does not come up once the database is replayed
// exits 1, with what is wrong on its last line: the restore is over, the
// database holds the archive, and nothing is left for recover to do.
func TestKvsctlRestoreOfAStackThatDoesNotComeUpIsExit1(t *testing.T) {
	s := e2eStack(t)
	archive := s.kvsctlBackup()
	s.writeData("data-2")
	s.f.behave(registry+"php:1.0.0-php8.1", behavior{unhealthy: true})
	run := s.kvsctl(pipes, "restore", filepath.Base(archive), "--yes", "--health-timeout", "1s")
	if code := run.wait(); code != 1 {
		t.Fatalf("restore: %s, want exit 1; it printed:\n%s", run.status, run.output())
	}
	contains(t, "restore", run.output(),
		"\nkvsctl: the database holds "+filepath.Base(archive)+", but the stack is not healthy: ",
		"kvs-php-fpm is unhealthy",
		"kvsctl recover has nothing to do")
	contains(t, "the log", s.runLog("restore"), "exit 1: ")
	if db, _, _, _ := s.world(); db != "data-1" {
		t.Errorf("the database holds %q, want data-1, which the archive holds", db)
	}
	if j := s.journal(); j != nil {
		t.Errorf("a journal was left: %+v", j)
	}
}

// Under --quiet, restore prints what the operator has to read and none of
// its progress: the warning that the archive comes from another stack
// version, what became of .env with what to run about it, and its result.
// The description of the archive the command line named, the backup taken
// first and the replay go to its log alone.
func TestKvsctlRestoreQuietPrintsOnlyWhatMatters(t *testing.T) {
	s := e2eStack(t)
	archive := s.kvsctlBackup()
	upgrade := s.kvsctl(pipes, "upgrade", "--yes", "--health-timeout", "20s")
	if code := upgrade.wait(); code != 0 {
		t.Fatalf("upgrade: %s; it printed:\n%s", upgrade.status, upgrade.output())
	}
	run := s.kvsctl(pipes, "restore", archive, "--yes", "--quiet", "--env")
	if code := run.wait(); code != 0 {
		t.Fatalf("restore: %s; it printed:\n%s", run.status, run.output())
	}
	docker := filepath.Join(s.root, "docker")
	want := regexp.MustCompile("^" + regexp.QuoteMeta("Warning:     this archive comes from stack 1.0.0, and the stack runs 1.1.0\n"+
		"  "+filepath.Join(docker, ".env")+" comes from the archive; ") + `[A-Z0-9_, ]+` +
		regexp.QuoteMeta(" kept the live values, since kvsctl manages them or they name the site\n"+
			"  run 'docker compose up -d' in "+docker+" for the containers to read it\n"+
			"example.com restored from "+filepath.Base(archive)+" (stack 1.0.0) in ") + `\d+s\n$`)
	if out := run.output(); !want.MatchString(out) {
		t.Errorf("restore --quiet printed:\n%s\nwant it to match\n%s", out, want)
	}
	contains(t, "the log of the restore", s.runLog("restore"),
		"Archive:     "+filepath.Base(archive),
		"Backing up the current database first.",
		"dumping the database",
		"Restoring the database from "+filepath.Base(archive)+".")
}

// restore --latest names its archive itself, as an argument does: under
// --quiet the description of the archive goes to the log alone, and the
// result line is all the restore prints.
func TestKvsctlRestoreLatestQuietPrintsItsResultAlone(t *testing.T) {
	s := e2eStack(t)
	archive := s.kvsctlBackup()
	run := s.kvsctl(pipes, "restore", "--latest", "--yes", "--quiet")
	if code := run.wait(); code != 0 {
		t.Fatalf("restore: %s; it printed:\n%s", run.status, run.output())
	}
	want := regexp.MustCompile("^" + regexp.QuoteMeta("example.com restored from "+filepath.Base(archive)+" (stack 1.0.0) in ") + `\d+s\n$`)
	if out := run.output(); !want.MatchString(out) {
		t.Errorf("restore --latest --quiet printed:\n%s\nwant it to match\n%s", out, want)
	}
	contains(t, "the log of the restore", s.runLog("restore"), "Archive:     "+filepath.Base(archive), "Holds:       ")
}

// A series change run with the default budgets gives MariaDB alone 30
// minutes to be ready, the upgrade and its rollback alike. A backup taken
// in between with --keep 1 keeps the archive the upgrade took, which the
// rollback of a series change cannot do without.
func TestKvsctlSeriesChangeKeepsItsWayBack(t *testing.T) {
	s := e2eStack(t)
	upgrade := s.kvsctl(pipes, "upgrade", "--yes", "--plain", "--mariadb-series", "12.3")
	if code := upgrade.wait(); code != 0 {
		t.Fatalf("upgrade: %s; it printed:\n%s", upgrade.status, upgrade.output())
	}
	contains(t, "the log of the upgrade", s.runLog("upgrade"), "MariaDB has 30m0s to be ready (--db-timeout)")
	archive := s.state().UpgradeBackup
	backup := s.kvsctl(pipes, "backup", "--keep", "1")
	if code := backup.wait(); code != 0 {
		t.Fatalf("backup: %s; it printed:\n%s", backup.status, backup.output())
	}
	if _, err := os.Stat(archive); err != nil {
		t.Errorf("kvsctl backup --keep 1 removed the archive the rollback replays: %v", err)
	}
	rollback := s.kvsctl(pipes, "rollback", "--yes", "--plain")
	if code := rollback.wait(); code != 0 {
		t.Fatalf("rollback: %s; it printed:\n%s", rollback.status, rollback.output())
	}
	contains(t, "the log of the rollback", s.runLog("rollback"), "MariaDB has 30m0s to be ready (--db-timeout)")
	s.back("1.0.0")
	if db, _, _, dataSeries := s.world(); db != "data-1" || dataSeries != "11.8" {
		t.Errorf("after the rollback: database %q, series %s", db, dataSeries)
	}
}

// kvsctlBackup takes a backup with kvsctl and returns its path.
func (s *stack) kvsctlBackup() string {
	s.t.Helper()
	run := s.kvsctl(pipes, "backup")
	if code := run.wait(); code != 0 {
		s.t.Fatalf("backup: %s; it printed:\n%s", run.status, run.output())
	}
	archives, _ := filepath.Glob(filepath.Join(s.root, "backups", "backup-*.tar"))
	if len(archives) != 1 {
		s.t.Fatalf("backups %v after one backup", archives)
	}
	return archives[0]
}

// readOnly takes the write permission of dir away for the rest of the
// test.
func readOnly(t *testing.T, dir string) {
	t.Helper()
	if err := os.Chmod(dir, 0o555); err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = os.Chmod(dir, 0o755) })
}
