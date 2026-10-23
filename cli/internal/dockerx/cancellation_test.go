package dockerx

import (
	"context"
	"errors"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"syscall"
	"testing"
	"time"

	"golang.org/x/sys/unix"
)

// A descendant can keep the instance locked even after the docker CLI
// exits and even when it no longer holds either output pipe open.
func TestCanceledCommandsReleaseDescendantLocks(t *testing.T) {
	// Adopt the fixture descendants, so cleanup reaps every orphan itself.
	if err := unix.Prctl(unix.PR_SET_CHILD_SUBREAPER, 1, 0, 0, 0); err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() {
		if err := unix.Prctl(unix.PR_SET_CHILD_SUBREAPER, 0, 0, 0, 0); err != nil {
			t.Error(err)
		}
	})
	previous := killDelay
	killDelay = 250 * time.Millisecond
	t.Cleanup(func() { killDelay = previous })
	compose := func(ctx context.Context, dir string) error {
		_, err := ComposeStarted(ctx, dir, nil, "up", "-d")
		return err
	}
	cases := []struct {
		name, mode string
		run        func(context.Context, string) error
	}{
		{"wait-parent-stubborn", "stubborn-family", compose},
		{"wait-parent-exits", "stubborn-child", compose},
		{"wait-closed-pipes", "stubborn-child-closed", compose},
		{"wait-cooperative-closed-pipes", "cooperative-child-closed", compose},
		{"run", "stubborn-child-closed", func(ctx context.Context, dir string) error {
			_, err := ComposeOutput(ctx, dir, "up", "-d")
			return err
		}},
		{"output", "stubborn-child-closed", func(ctx context.Context, _ string) error {
			_, err := ComposeVersion(ctx)
			return err
		}},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			log := installFakeDocker(t, tc.mode)
			dir := t.TempDir()
			held, err := os.Create(filepath.Join(dir, "lock"))
			if err != nil {
				t.Fatal(err)
			}
			defer held.Close()
			if err := syscall.Flock(int(held.Fd()), syscall.LOCK_EX|syscall.LOCK_NB); err != nil {
				t.Fatal(err)
			}
			forget := Inherit(held)
			defer forget()
			ctx, cancel := context.WithCancel(context.Background())
			done := make(chan error, 1)
			returned := false
			// Cleanup also runs after a failed assertion, and only signals the
			// fixture's own process group. Its descendants are our children.
			t.Cleanup(func() {
				cancel()
				group, _ := strconv.Atoi(logged(readLog(t, log), "pgid"))
				if group > 1 {
					_ = syscall.Kill(-group, syscall.SIGKILL)
				}
				if !returned {
					select {
					case <-done:
					case <-time.After(3 * time.Second):
						t.Error("the fixture command did not stop during cleanup")
						return
					}
				}
				if group > 1 {
					for deadline := time.Now().Add(time.Second); ; time.Sleep(time.Millisecond) {
						var status syscall.WaitStatus
						_, err := syscall.Wait4(-group, &status, syscall.WNOHANG, nil)
						if errors.Is(err, syscall.ECHILD) {
							break
						}
						if err != nil || time.Now().After(deadline) {
							t.Errorf("fixture descendants were not reaped: %v", err)
							break
						}
					}
				}
			})
			go func() { done <- tc.run(ctx, dir) }()
			waitLogged(t, log, "ready")
			cancel()
			select {
			case err := <-done:
				returned = true
				if err == nil {
					t.Error("the canceled command succeeded")
				}
			case <-time.After(3 * time.Second):
				t.Fatal("the command did not return after cancellation")
			}
			if tc.mode == "cooperative-child-closed" && !strings.Contains(readLog(t, log), "child-cleaned") {
				t.Error("the descendant's cooperative cleanup was cut short")
			}
			forget()
			// Close rather than LOCK_UN, exactly as Instance.Lock releases it.
			if err := held.Close(); err != nil {
				t.Fatal(err)
			}
			probe, err := os.OpenFile(held.Name(), os.O_RDWR, 0)
			if err != nil {
				t.Fatal(err)
			}
			defer probe.Close()
			for deadline := time.Now().Add(time.Second); ; time.Sleep(time.Millisecond) {
				err := syscall.Flock(int(probe.Fd()), syscall.LOCK_EX|syscall.LOCK_NB)
				if err == nil {
					break
				}
				if !errors.Is(err, syscall.EWOULDBLOCK) || time.Now().After(deadline) {
					t.Fatalf("the canceled command left a descendant holding the lock: %v", err)
				}
			}
		})
	}
}
