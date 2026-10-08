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

// Space is what a filesystem holds, in bytes.
type Space struct {
	// Avail is what an unprivileged process may still write: the reserved
	// blocks of the filesystem are not free space.
	Avail int64
	// Size is the whole filesystem, which a floor in percent is taken of.
	Size int64
	// Device names the filesystem, zero when it could not be read. Two
	// paths on the same device share one free space, so what an upgrade
	// writes to each of them adds up there.
	Device uint64
}

// Measure reads the filesystem under path. A path that does not exist yet,
// which is what a state directory looks like before the first upgrade, is
// measured on the nearest parent that does.
func Measure(path string) (Space, error) {
	if path == "" {
		return Space{}, errors.New("no path to measure")
	}
	dir, err := filepath.Abs(path)
	if err != nil {
		return Space{}, err
	}
	for {
		var st unix.Statfs_t
		err := unix.Statfs(dir, &st)
		if err == nil {
			space := Space{Avail: int64(st.Bavail) * st.Bsize, Size: int64(st.Blocks) * st.Bsize}
			var info unix.Stat_t
			if unix.Stat(dir, &info) == nil {
				space.Device = info.Dev
			}
			return space, nil
		}
		parent := filepath.Dir(dir)
		if !errors.Is(err, os.ErrNotExist) || parent == dir {
			return Space{}, fmt.Errorf("statfs %s: %w", dir, err)
		}
		dir = parent
	}
}

// Avail is the number of bytes still writable under path, as Measure reads
// it.
func Avail(path string) (int64, error) {
	space, err := Measure(path)
	return space.Avail, err
}
