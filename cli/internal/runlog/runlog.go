// Package runlog keeps the log of every kvsctl run that changes a stack:
// kvsctl/logs/<UTC yyyymmdd-hhmmss>-<command>.log, one timestamped line per
// event, decision and line of docker output. A screen shows a run while it
// lasts; the log is what is left to read once the terminal is gone, the
// run failed at night, or support asks what happened.
package runlog

import (
	"errors"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"regexp"
	"slices"
	"sort"
	"strings"
	"sync"
	"time"
)

// Keep is how many logs a state directory keeps: Open removes the older
// ones.
const Keep = 30

// stampLayout dates a log file name, in UTC, so the names sort in the order
// the runs started.
const stampLayout = "20060102-150405"

// now is the clock of the package; the tests set it.
var now = time.Now

var (
	commandRe = regexp.MustCompile(`^[a-z0-9][a-z0-9-]*$`)
	nameRe    = regexp.MustCompile(`^\d{8}-\d{6}-[a-z0-9][a-z0-9-]*\.log$`)
)

// Logger appends timestamped lines to one log file. It is safe for
// concurrent use. A write that fails never fails the run it logs: the first
// error is kept, Err returns it, and the logger writes nothing more, since
// a log with a hole in it would be read as a complete one.
type Logger struct {
	mu   sync.Mutex
	f    *os.File
	w    io.Writer
	path string
	err  error
	// reported is set once the first error was handed to a caller that
	// tells the operator, so it is told once.
	reported bool
	closed   bool
}

// Dir is where the logs of a state directory live.
func Dir(stateDir string) string { return filepath.Join(stateDir, "logs") }

// Open creates the log of a run of command in stateDir/logs, a directory
// only its owner reads, and removes the logs beyond the Keep newest, never
// one of the paths in keep: the log of a run that was interrupted is what
// tells how to finish it, however many runs of recover come after it. The
// name carries the UTC start of the run; when a run of the same command
// already took that second, the stamp moves a second on rather than
// writing into another run's log.
func Open(stateDir, command string, keep ...string) (*Logger, error) {
	if !commandRe.MatchString(command) {
		return nil, fmt.Errorf("%q cannot name a log file", command)
	}
	dir := Dir(stateDir)
	if err := os.MkdirAll(dir, 0o700); err != nil {
		return nil, err
	}
	// MkdirAll leaves an existing directory as it found it.
	if err := os.Chmod(dir, 0o700); err != nil {
		return nil, err
	}
	start := now().UTC()
	var f *os.File
	var err error
	for i := 0; i < 60; i++ {
		name := fmt.Sprintf("%s-%s.log", start.Add(time.Duration(i)*time.Second).Format(stampLayout), command)
		f, err = os.OpenFile(filepath.Join(dir, name), os.O_CREATE|os.O_EXCL|os.O_WRONLY|os.O_APPEND, 0o600)
		if !errors.Is(err, os.ErrExist) {
			break
		}
	}
	if err != nil {
		return nil, err
	}
	l := &Logger{f: f, w: f, path: f.Name()}
	for _, path := range prune(dir, append([]string{f.Name()}, keep...)) {
		l.Printf("could not remove the old log %s", path)
	}
	return l, nil
}

// prune removes the logs of dir beyond the Keep newest, never one of keep,
// and returns the ones it could not remove. Files that are not logs stay.
func prune(dir string, keep []string) (failed []string) {
	logs, err := list(dir)
	if err != nil {
		return nil
	}
	for n, path := range logs {
		if n < Keep || slices.Contains(keep, path) {
			continue
		}
		if err := os.Remove(path); err != nil && !errors.Is(err, os.ErrNotExist) {
			failed = append(failed, path)
		}
	}
	return failed
}

// List is the logs of a state directory, newest first, by their paths.
func List(stateDir string) ([]string, error) {
	logs, err := list(Dir(stateDir))
	if errors.Is(err, os.ErrNotExist) {
		return nil, nil
	}
	return logs, err
}

func list(dir string) ([]string, error) {
	entries, err := os.ReadDir(dir)
	if err != nil {
		return nil, err
	}
	var logs []string
	for _, e := range entries {
		if e.Type().IsRegular() && nameRe.MatchString(e.Name()) {
			logs = append(logs, e.Name())
		}
	}
	sort.Sort(sort.Reverse(sort.StringSlice(logs)))
	for n, name := range logs {
		logs[n] = filepath.Join(dir, name)
	}
	return logs, nil
}

// Path is the file the logger writes, to print at the start of a run and
// in the message of one that failed.
func (l *Logger) Path() string { return l.path }

// Printf writes one entry. Every line of it starts with the UTC time of the
// entry, so a multi-line error or a block of docker output stays readable
// line by line.
func (l *Logger) Printf(format string, args ...any) {
	stamp := now().UTC().Format(time.RFC3339)
	msg := strings.TrimRight(fmt.Sprintf(format, args...), "\n")
	var b strings.Builder
	for _, line := range strings.Split(msg, "\n") {
		b.WriteString(stamp)
		if line = strings.TrimRight(line, "\r"); line != "" {
			b.WriteByte(' ')
			b.WriteString(line)
		}
		b.WriteByte('\n')
	}
	l.mu.Lock()
	defer l.mu.Unlock()
	if l.err != nil || l.closed {
		return
	}
	if _, err := io.WriteString(l.w, b.String()); err != nil {
		l.err = fmt.Errorf("write %s: %w", l.path, err)
	}
}

// Err is the first error the log met, nil while every line got written.
func (l *Logger) Err() error {
	l.mu.Lock()
	defer l.mu.Unlock()
	return l.err
}

// failure returns the first error of the log the first time it is asked
// for, and nil before it happened and after, so it is told once.
func (l *Logger) failure() error {
	l.mu.Lock()
	defer l.mu.Unlock()
	if l.err == nil || l.reported {
		return nil
	}
	l.reported = true
	return l.err
}

// Close flushes the log to the disk and closes it. It returns the first
// error the log met, a failed write included, so the final message of a
// run can say its log is incomplete. Entries written after Close are
// dropped.
func (l *Logger) Close() error {
	l.mu.Lock()
	defer l.mu.Unlock()
	if l.closed {
		return l.err
	}
	l.closed = true
	err := l.f.Sync()
	if cerr := l.f.Close(); err == nil {
		err = cerr
	}
	if l.err == nil && err != nil {
		l.err = fmt.Errorf("close %s: %w", l.path, err)
	}
	return l.err
}
