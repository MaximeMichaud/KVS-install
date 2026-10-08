//go:build !linux

package manifest

import (
	"os"
	"syscall"
)

// raise sends sig to the process. kvsctl runs on Linux; this keeps the
// package, which kvsctl-release uses too, building elsewhere.
func raise(sig syscall.Signal) {
	if p, err := os.FindProcess(os.Getpid()); err == nil {
		_ = p.Signal(sig)
	}
}
