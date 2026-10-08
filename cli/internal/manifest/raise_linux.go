package manifest

import (
	"runtime"
	"syscall"

	"golang.org/x/sys/unix"
)

// raise sends sig to the thread that runs it, which takes the signal before
// the call returns: a process that does not catch it ends there, and one
// that does carries on. Sent to the process, the signal could reach another
// thread after this one had already printed and exited.
func raise(sig syscall.Signal) {
	runtime.LockOSThread()
	defer runtime.UnlockOSThread()
	_ = unix.Tgkill(unix.Getpid(), unix.Gettid(), sig)
}
