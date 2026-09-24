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
)

// LockedError says another kvsctl holds the lock of the instance, and names
// the run that holds it.
type LockedError struct {
	PID     int
	Command string
	Since   time.Time
}

func (e *LockedError) Error() string {
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
	return "another kvsctl is running (" + who + ")"
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

// Lock takes the exclusive kvsctl lock of the instance for command and
// returns the function that releases it. The hold is a flock, so a run that
// dies, whatever the way, never leaves a stale lock behind. A lock another
// run holds comes back as a *LockedError naming it.
func (i *Instance) Lock(command string) (func(), error) {
	if err := os.MkdirAll(i.StateDir(), 0o750); err != nil {
		return nil, err
	}
	path := i.lockPath()
	f, err := os.OpenFile(path, os.O_CREATE|os.O_RDWR, 0o600)
	if err != nil {
		return nil, err
	}
	if err := syscall.Flock(int(f.Fd()), syscall.LOCK_EX|syscall.LOCK_NB); err != nil {
		held := readHolder(path)
		f.Close()
		if errors.Is(err, syscall.EWOULDBLOCK) {
			return nil, &LockedError{PID: held.PID, Command: held.Command, Since: held.Since}
		}
		return nil, fmt.Errorf("lock %s: %w", path, err)
	}
	if err := writeHolder(f, holder{PID: os.Getpid(), Command: command, Since: time.Now()}); err != nil {
		syscall.Flock(int(f.Fd()), syscall.LOCK_UN)
		f.Close()
		return nil, fmt.Errorf("write %s: %w", path, err)
	}
	var once sync.Once
	return func() {
		once.Do(func() {
			syscall.Flock(int(f.Fd()), syscall.LOCK_UN)
			f.Close()
		})
	}, nil
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
