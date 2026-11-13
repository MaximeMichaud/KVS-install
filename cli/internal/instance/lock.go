package instance

import (
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"sync"
	"syscall"
	"time"

	"github.com/MaximeMichaud/KVS-install/cli/internal/dockerx"
)

// LockedError says the lock of the instance is held, and names who holds
// it. Orphaned is a run that has ended, killed, while a
// docker command it started still runs: that command holds the lock (see
// Lock), and Path is the lock file it holds open. Script is a lock no kvsctl
// holds: setup.sh, reconfigure.sh and kvs-install.sh hold it shared for as
// long as they run, and the lock file names no run of theirs.
type LockedError struct {
	PID      int
	Command  string
	Since    time.Time
	Orphaned bool
	Script   bool
	Path     string
}

func (e *LockedError) Error() string {
	if e.Script {
		msg := "a setup.sh, reconfigure.sh or kvs-install.sh run is changing this installation and holds its lock; wait until it is done"
		if e.Path != "" {
			msg += " ('fuser -v " + e.Path + "' names it)"
		}
		return msg
	}
	who := "pid unknown"
	if e.PID > 0 {
		who = fmt.Sprintf("pid %d", e.PID)
	}
	if e.Command != "" {
		who += ", " + e.Command
	}
	if !e.Since.IsZero() {
		who += ", started " + ago(time.Since(e.Since))
	}
	if e.Orphaned {
		msg := "the kvsctl run that holds the lock has ended (" + who + "), but a docker command it started still runs and holds it; wait for that command to end"
		if e.Path != "" {
			msg += " ('fuser -v " + e.Path + "' names it)"
		}
		return msg
	}
	return "another kvsctl is running (" + who + ")"
}

// locked is the LockedError of the lock file at path, which another run
// holds: an orphan when the run that wrote it is gone.
func locked(path string) *LockedError {
	held := readHolder(path)
	return &LockedError{PID: held.PID, Command: held.Command, Since: held.Since, Orphaned: gone(held.PID), Path: path}
}

// gone reports whether no process has the pid any more.
func gone(pid int) bool {
	return pid > 0 && errors.Is(syscall.Kill(pid, 0), syscall.ESRCH)
}

// ago reads a duration the way an operator says it.
func ago(d time.Duration) string {
	switch {
	case d < 2*time.Second:
		return "just now"
	case d < time.Minute:
		return fmt.Sprintf("%d seconds ago", int(d.Seconds()))
	case d < 2*time.Minute:
		return "1 minute ago"
	case d < time.Hour:
		return fmt.Sprintf("%d minutes ago", int(d.Minutes()))
	case d < 2*time.Hour:
		return "1 hour ago"
	default:
		return fmt.Sprintf("%d hours ago", int(d.Hours()))
	}
}

// holder is what the lock file carries, so the run that finds it held can
// say who holds it.
type holder struct {
	PID     int       `json:"pid"`
	Command string    `json:"command"`
	Since   time.Time `json:"since"`
}

func (i *Instance) lockPath() string { return filepath.Join(i.StateDir(), "lock") }

// orphanWait is how long Lock asks again for a lock whose run has ended
// before it names what holds it, every orphanPoll: a shared hold of a
// reader lasts a moment, a docker command a killed run left lasts.
const (
	orphanWait = 500 * time.Millisecond
	orphanPoll = 10 * time.Millisecond
)

// Lock takes the exclusive kvsctl lock of the instance for command and
// returns the function that releases it. The hold is a flock, so a run that
// dies, whatever the way, never leaves a stale lock behind. Every docker
// child of the run inherits the lock (dockerx.Inherit), and a flock is held
// while any descriptor of it is open: a docker compose a killed run left
// behind keeps the instance locked until it ends, so a recover cannot start
// a second compose on the project beside it. The release closes the
// descriptor instead of unlocking it, for the same reason. A lock another
// run holds comes back as a *LockedError naming it, at once while that run
// lives, after orphanWait once it has ended. A lock held only shared is no
// kvsctl run and no docker command one left, which hold it exclusive: it is
// kvsctl status reading for a moment, or a script that holds it for its
// whole run, named as such once orphanWait has passed.
func (i *Instance) Lock(command string) (func(), error) {
	if err := os.MkdirAll(i.StateDir(), 0o750); err != nil {
		return nil, err
	}
	path := i.lockPath()
	f, err := os.OpenFile(path, os.O_CREATE|os.O_RDWR, 0o600)
	if err != nil {
		return nil, err
	}
	err = syscall.Flock(int(f.Fd()), syscall.LOCK_EX|syscall.LOCK_NB)
	if errors.Is(err, syscall.EWOULDBLOCK) && (sharedOnly(f) || gone(readHolder(path).PID)) {
		// What holds the lock is no kvsctl that lives: a docker command a
		// run that has ended left, kvsctl status reading for a moment, or
		// a script. The lock is asked for again a while before what still
		// holds it is named.
		for deadline := time.Now().Add(orphanWait); errors.Is(err, syscall.EWOULDBLOCK) && time.Now().Before(deadline); {
			time.Sleep(orphanPoll)
			err = syscall.Flock(int(f.Fd()), syscall.LOCK_EX|syscall.LOCK_NB)
		}
	}
	if errors.Is(err, syscall.EWOULDBLOCK) && sharedOnly(f) {
		// Held shared and nothing else: a script, unless it has just let
		// go, which the last ask for the lock tells.
		if err = syscall.Flock(int(f.Fd()), syscall.LOCK_EX|syscall.LOCK_NB); errors.Is(err, syscall.EWOULDBLOCK) {
			f.Close()
			return nil, &LockedError{Script: true, Path: path}
		}
	}
	if err != nil {
		f.Close()
		if errors.Is(err, syscall.EWOULDBLOCK) {
			return nil, locked(path)
		}
		return nil, fmt.Errorf("lock %s: %w", path, err)
	}
	if err := writeHolder(f, holder{PID: os.Getpid(), Command: command, Since: time.Now()}); err != nil {
		syscall.Flock(int(f.Fd()), syscall.LOCK_UN)
		f.Close()
		return nil, fmt.Errorf("write %s: %w", path, err)
	}
	forget := dockerx.Inherit(f)
	var once sync.Once
	// The release runs once the run is over: no docker command starts any
	// more, and the descriptor can go.
	return func() {
		once.Do(func() {
			forget()
			f.Close()
		})
	}, nil
}

// sharedOnly reports whether the lock f is the file of is held shared and
// by nobody exclusive: a shared hold of f is granted, and let go at once.
func sharedOnly(f *os.File) bool {
	if syscall.Flock(int(f.Fd()), syscall.LOCK_SH|syscall.LOCK_NB) != nil {
		return false
	}
	_ = syscall.Flock(int(f.Fd()), syscall.LOCK_UN)
	return true
}

// Holder names the run that holds the lock of the instance, nil when no run
// does, without taking the lock or writing anything: status shows a run in
// progress this way, and must change nothing. A shared lock is refused
// exactly while a run holds the exclusive one, and is let go at once.
func (i *Instance) Holder() (*LockedError, error) {
	path := i.lockPath()
	f, err := os.Open(path)
	if errors.Is(err, os.ErrNotExist) {
		return nil, nil
	}
	if err != nil {
		return nil, err
	}
	defer f.Close()
	err = syscall.Flock(int(f.Fd()), syscall.LOCK_SH|syscall.LOCK_NB)
	if errors.Is(err, syscall.EWOULDBLOCK) {
		return locked(path), nil
	}
	if err != nil {
		return nil, fmt.Errorf("lock %s: %w", path, err)
	}
	_ = syscall.Flock(int(f.Fd()), syscall.LOCK_UN)
	return nil, nil
}

func writeHolder(f *os.File, h holder) error {
	data, err := json.Marshal(h)
	if err != nil {
		return err
	}
	if err := f.Truncate(0); err != nil {
		return err
	}
	if _, err := f.Seek(0, io.SeekStart); err != nil {
		return err
	}
	if _, err := f.Write(append(data, '\n')); err != nil {
		return err
	}
	return f.Sync()
}

// readHolder reads who holds the lock; an unreadable or half written file
// only costs the details of the message.
func readHolder(path string) holder {
	var h holder
	if data, err := os.ReadFile(path); err == nil {
		_ = json.Unmarshal(data, &h)
	}
	return h
}
