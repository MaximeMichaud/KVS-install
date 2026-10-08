package dockerx

import (
	"bytes"
	"context"
	"errors"
	"os"
	"os/exec"
	"strings"
	"sync"
	"syscall"
	"time"
)

// killDelay is how long a child that was asked to stop may take before it
// is killed. Compose stops what it was doing on SIGTERM, which takes a few
// seconds; it is a variable so the tests do not wait that long.
var killDelay = 30 * time.Second

// command builds a child of kvsctl that the terminal does not reach: the
// docker CLI, the compose plugin it starts, a credential helper. It runs in
// a process group of its own, so the SIGINT of a Ctrl-C or the SIGHUP of a
// dropped SSH session goes to kvsctl alone, which decides what happens. A
// signal that reached compose directly would stop it half way through
// recreating the services, behind the back of the rollback. When ctx ends,
// the whole group gets SIGTERM, which lets compose stop cleanly, and the
// child is killed killDelay later if it is still there. The child inherits
// the files Inherit names, the lock of the instance among them.
func command(ctx context.Context, name string, args ...string) *exec.Cmd {
	cmd := exec.CommandContext(ctx, name, args...)
	cmd.SysProcAttr = &syscall.SysProcAttr{Setpgid: true}
	cmd.ExtraFiles = inheritedFiles()
	cmd.Cancel = func() error {
		// The negative pid names the group: the docker CLI and the
		// compose plugin it runs as a child of its own.
		err := syscall.Kill(-cmd.Process.Pid, syscall.SIGTERM)
		if errors.Is(err, syscall.ESRCH) {
			return os.ErrProcessDone
		}
		return err
	}
	cmd.WaitDelay = killDelay
	return cmd
}

// maxLine and keptLines bound what lineWriter holds: a line that never
// ends is cut rather than kept whole, and the last lines are what an error
// message quotes.
const (
	maxLine   = 1 << 20
	keptLines = 20
)

// lineWriter hands every line written to it to sink as soon as it is
// complete, and keeps the last ones for the error message of a command
// that failed. It is the stdout and the stderr of compose at once, so the
// lines arrive in the order compose wrote them.
type lineWriter struct {
	mu   sync.Mutex
	sink func(string)
	part []byte
	last []string
}

func (w *lineWriter) Write(p []byte) (int, error) {
	w.mu.Lock()
	defer w.mu.Unlock()
	n := len(p)
	for len(p) > 0 {
		i := bytes.IndexByte(p, '\n')
		if i < 0 {
			w.part = append(w.part, p...)
			if len(w.part) >= maxLine {
				w.emit()
			}
			break
		}
		w.part = append(w.part, p[:i]...)
		w.emit()
		p = p[i+1:]
	}
	return n, nil
}

// flush hands over a last line the command did not end.
func (w *lineWriter) flush() {
	w.mu.Lock()
	defer w.mu.Unlock()
	if len(w.part) > 0 {
		w.emit()
	}
}

func (w *lineWriter) emit() {
	line := strings.TrimRight(string(w.part), "\r")
	w.part = w.part[:0]
	w.last = append(w.last, line)
	if len(w.last) > keptLines {
		w.last = w.last[len(w.last)-keptLines:]
	}
	if w.sink != nil {
		w.sink(line)
	}
}

// lines are the last lines seen, oldest first.
func (w *lineWriter) lines() string {
	w.mu.Lock()
	defer w.mu.Unlock()
	return strings.Join(w.last, "\n")
}

// said is the last lines as the end of an error message, on lines of their
// own, or nothing when the command wrote nothing but blanks.
func (w *lineWriter) said() string {
	if lines := w.lines(); strings.TrimSpace(lines) != "" {
		return "\n" + lines
	}
	return ""
}

// tailBuffer keeps the last max bytes written to it: the end of what a
// command wrote on stderr is what explains its failure, and a command that
// keeps writing must not grow the memory of kvsctl.
type tailBuffer struct {
	mu  sync.Mutex
	max int
	buf []byte
}

func (t *tailBuffer) Write(p []byte) (int, error) {
	t.mu.Lock()
	defer t.mu.Unlock()
	t.buf = append(t.buf, p...)
	if over := len(t.buf) - t.max; over > 0 {
		t.buf = append(t.buf[:0], t.buf[over:]...)
	}
	return len(p), nil
}

func (t *tailBuffer) String() string {
	t.mu.Lock()
	defer t.mu.Unlock()
	return strings.TrimSpace(string(t.buf))
}
