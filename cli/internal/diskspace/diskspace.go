// Package diskspace reports how much a filesystem can still take, so an
// upgrade refuses to pull images the machine has no room for.
package diskspace

import (
	"errors"
	"fmt"
	"os"
	"path/filepath"

	"golang.org/x/sys/unix"
)

// Avail is the number of bytes still writable under path, counting only
// what an unprivileged process may use (the reserved blocks of the
// filesystem are not free space). A path that does not exist yet, which is
// what a state directory looks like before the first upgrade, is measured
// on the nearest parent that does.
func Avail(path string) (int64, error) {
	if path == "" {
		return 0, errors.New("no path to measure")
	}
	dir, err := filepath.Abs(path)
	if err != nil {
		return 0, err
	}
	for {
		var st unix.Statfs_t
		err := unix.Statfs(dir, &st)
		if err == nil {
			return int64(st.Bavail) * st.Bsize, nil
		}
		parent := filepath.Dir(dir)
		if !errors.Is(err, os.ErrNotExist) || parent == dir {
			return 0, fmt.Errorf("statfs %s: %w", dir, err)
		}
		dir = parent
	}
}
