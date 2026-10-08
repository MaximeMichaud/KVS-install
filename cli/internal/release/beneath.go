package release

import (
	"errors"
	"fmt"
	"io"
	"io/fs"
	"math/rand/v2"
	"os"
	"path"
	"path/filepath"
	"strings"

	"golang.org/x/sys/unix"
)

// Some directories of an installation are written by containers: the nginx
// container writes docker/nginx/conf.d through a bind mount, as root, and
// the PHP container owns the web root. kvsctl runs as root on the host, so a
// link planted there must never make it read, write or change a file
// elsewhere. Below a root, every path is therefore walked one directory at a
// time without following a link, a file is only read once it is known to be
// a regular file, and a file only takes its place by a rename inside its
// directory, which replaces a link where writing would go through it. The
// root itself is opened as given: an operator may reach the installation
// through a link.

// errNotLaid marks a path that holds something else than a regular file
// reached through real directories: a link, a fifo, a device, or a
// directory on its way that is a link or a file. Verify counts such a file
// as changed; it is not the one kvsctl laid.
var errNotLaid = errors.New("not a regular file reached through real directories")

// notDirError is a directory below root that is now a file, a fifo or a
// device: what was below it is gone, and nothing below it was laid there.
type notDirError struct{ path string }

func (e *notDirError) Error() string { return e.path + " is not a directory" }

func (e *notDirError) Is(target error) bool {
	return target == unix.ENOTDIR || target == errNotLaid
}

// openDir opens the directory rel (slash separated, relative to root, "."
// for root) without following a link below root; create makes the
// directories that are missing, mode 0755 whatever the umask kvsctl runs
// under, since the containers read what the release lays in them.
func openDir(root, rel string, create bool) (int, error) {
	fd, err := unix.Open(root, unix.O_RDONLY|unix.O_DIRECTORY|unix.O_CLOEXEC, 0)
	if err != nil {
		return -1, &os.PathError{Op: "open", Path: root, Err: err}
	}
	walked := ""
	for _, name := range strings.Split(rel, "/") {
		if name == "" || name == "." {
			continue
		}
		walked = path.Join(walked, name)
		if name == ".." {
			unix.Close(fd)
			return -1, fmt.Errorf("%s leaves %s", rel, root)
		}
		made := false
		next, err := openat(fd, name, unix.O_RDONLY|unix.O_DIRECTORY|unix.O_NOFOLLOW|unix.O_CLOEXEC)
		if errors.Is(err, unix.ENOENT) && create {
			switch merr := unix.Mkdirat(fd, name, 0o755); {
			case merr == nil:
				made = true
			case !errors.Is(merr, unix.EEXIST):
				unix.Close(fd)
				return -1, &os.PathError{Op: "mkdir", Path: filepath.Join(root, walked), Err: merr}
			}
			next, err = openat(fd, name, unix.O_RDONLY|unix.O_DIRECTORY|unix.O_NOFOLLOW|unix.O_CLOEXEC)
		}
		if err == nil && made {
			// The mode goes on the directory opened, never through its
			// name.
			if cerr := unix.Fchmod(next, 0o755); cerr != nil {
				unix.Close(next)
				unix.Close(fd)
				return -1, &os.PathError{Op: "chmod", Path: filepath.Join(root, walked), Err: cerr}
			}
		}
		if err != nil {
			err = describeDir(fd, name, root, walked, err)
			unix.Close(fd)
			return -1, err
		}
		unix.Close(fd)
		fd = next
	}
	return fd, nil
}

// openat is unix.Openat, retried when a signal interrupts it.
func openat(dirfd int, name string, flags int) (int, error) {
	for {
		fd, err := unix.Openat(dirfd, name, flags, 0)
		if !errors.Is(err, unix.EINTR) {
			return fd, err
		}
	}
}

// describeDir turns the error of opening the directory rel below root into
// one an operator can act on: a link, or a file where a directory should
// be, is named as such.
func describeDir(dirfd int, name, root, rel string, err error) error {
	full := filepath.Join(root, rel)
	if errors.Is(err, unix.ELOOP) || errors.Is(err, unix.ENOTDIR) {
		var st unix.Stat_t
		if unix.Fstatat(dirfd, name, &st, unix.AT_SYMLINK_NOFOLLOW) == nil {
			switch st.Mode & unix.S_IFMT {
			case unix.S_IFLNK:
				return linkError(root, rel)
			case unix.S_IFDIR:
			default:
				return &notDirError{path: full}
			}
		}
	}
	return &os.PathError{Op: "open", Path: full, Err: err}
}

// linkError is the refusal of a link found at rel below root.
func linkError(root, rel string) error {
	return fmt.Errorf("%s is a symbolic link, which kvsctl does not follow below %s: %w", rel, root, errNotLaid)
}

// openFile opens the regular file rel below root for reading. A link, a
// fifo, a socket or a device is refused without being opened: its type is
// read first, and read again on what was opened, in case the name changed
// in between; the open itself does not wait for the writer of a fifo.
func openFile(root, rel string) (*os.File, error) {
	dirfd, err := openDir(root, path.Dir(rel), false)
	if err != nil {
		return nil, err
	}
	defer unix.Close(dirfd)
	name, full := path.Base(rel), filepath.Join(root, rel)
	var before unix.Stat_t
	if err := unix.Fstatat(dirfd, name, &before, unix.AT_SYMLINK_NOFOLLOW); err != nil {
		return nil, &os.PathError{Op: "stat", Path: full, Err: err}
	}
	switch before.Mode & unix.S_IFMT {
	case unix.S_IFREG:
	case unix.S_IFLNK:
		return nil, linkError(root, rel)
	default:
		return nil, fmt.Errorf("%s is not a regular file: %w", full, errNotLaid)
	}
	fd, err := openat(dirfd, name, unix.O_RDONLY|unix.O_NOFOLLOW|unix.O_NONBLOCK|unix.O_CLOEXEC)
	if err != nil {
		if errors.Is(err, unix.ELOOP) {
			return nil, linkError(root, rel)
		}
		return nil, &os.PathError{Op: "open", Path: full, Err: err}
	}
	var st unix.Stat_t
	if err := unix.Fstat(fd, &st); err != nil {
		unix.Close(fd)
		return nil, &os.PathError{Op: "stat", Path: full, Err: err}
	}
	if st.Mode&unix.S_IFMT != unix.S_IFREG || st.Dev != before.Dev || st.Ino != before.Ino {
		unix.Close(fd)
		return nil, fmt.Errorf("%s changed while kvsctl opened it: %w", full, errNotLaid)
	}
	if err := unix.SetNonblock(fd, false); err != nil {
		unix.Close(fd)
		return nil, &os.PathError{Op: "fcntl", Path: full, Err: err}
	}
	return os.NewFile(uintptr(fd), full), nil
}

// ReadBeneath reads the regular file rel (slash separated) below root,
// reached through real directories, refusing one larger than limit: the
// way kvsctl reads a file a container can write, such as the version.php
// of the site.
func ReadBeneath(root, rel string, limit int64) ([]byte, error) {
	f, err := openFile(root, rel)
	if err != nil {
		return nil, err
	}
	defer f.Close()
	data, err := io.ReadAll(io.LimitReader(f, limit+1))
	if err != nil {
		return nil, err
	}
	if int64(len(data)) > limit {
		return nil, fmt.Errorf("%s is larger than %d bytes", f.Name(), limit)
	}
	return data, nil
}

// WriteFile replaces the file rel (slash separated) below root with data.
// The data goes to a new temporary file in the directory of rel, which
// takes mode and, through prepare when it is not nil, anything else such
// as an owner, reaches the disk, and is renamed over rel: a link at rel is
// replaced, never written through, and no directory below root is reached
// through a link, so the write lands where its path says. prepare gets the
// new file and what stands at rel, read without following a link, nil when
// nothing does. Two kvsctl writing the same file at once each write a
// temporary file of their own. The directory is flushed once the name
// changed, and a failure to flush it is returned.
func WriteFile(root, rel string, data []byte, mode os.FileMode, prepare func(f *os.File, replaced *unix.Stat_t) error) error {
	dirfd, err := openDir(root, path.Dir(rel), false)
	if err != nil {
		return err
	}
	defer unix.Close(dirfd)
	name, dir := path.Base(rel), filepath.Join(root, path.Dir(rel))
	tmpName, tmp, err := createTemp(dirfd, name, dir, false)
	if err != nil {
		return err
	}
	_, err = tmp.Write(data)
	if err == nil {
		err = tmp.Chmod(mode)
	}
	if err == nil && prepare != nil {
		var replaced *unix.Stat_t
		if replaced, err = statAt(dirfd, name, filepath.Join(dir, name)); err == nil {
			err = prepare(tmp, replaced)
		}
	}
	if err == nil {
		err = syncFile(tmp)
	}
	if cerr := tmp.Close(); err == nil {
		err = cerr
	}
	if err == nil {
		err = replace(dirfd, tmpName, name, root, rel)
	}
	if err != nil {
		_ = unix.Unlinkat(dirfd, tmpName, 0)
		return err
	}
	if err := unix.Fsync(dirfd); err != nil {
		return &os.PathError{Op: "sync", Path: dir, Err: err}
	}
	return nil
}

// statAt reads what stands at name in dirfd without following a link, nil
// when nothing does; full names it in an error.
func statAt(dirfd int, name, full string) (*unix.Stat_t, error) {
	var st unix.Stat_t
	err := unix.Fstatat(dirfd, name, &st, unix.AT_SYMLINK_NOFOLLOW)
	switch {
	case errors.Is(err, unix.ENOENT):
		return nil, nil
	case err != nil:
		return nil, &os.PathError{Op: "stat", Path: full, Err: err}
	}
	return &st, nil
}

// lay puts a copy of the regular file rel of srcRoot at rel below root,
// with the mode of the source. The copy is written to a new temporary file
// in the target directory, flushed, then renamed over the target: a link
// standing there is replaced, never written through, and an empty directory
// standing there is removed first. Its callers, Sync and Snapshot, run
// under the lock of the installation, so the temporary file a killed run
// left is reclaimed (createTemp).
func lay(srcRoot, root, rel string) error {
	src, err := openFile(srcRoot, rel)
	if err != nil {
		return err
	}
	defer src.Close()
	info, err := src.Stat()
	if err != nil {
		return err
	}
	dir := path.Dir(rel)
	dirfd, err := openDir(root, dir, true)
	if err != nil {
		return err
	}
	defer unix.Close(dirfd)
	name := path.Base(rel)
	tmpName, tmp, err := createTemp(dirfd, name, filepath.Join(root, dir), true)
	if err != nil {
		return err
	}
	// No release file is larger than a whole bundle unpacks to.
	if info.Size() > maxBytes {
		err = fmt.Errorf("%s is larger than any release file (%d MiB)", src.Name(), maxBytes>>20)
	}
	if err == nil {
		var n int64
		if n, err = io.Copy(tmp, io.LimitReader(src, maxBytes+1)); err == nil && n > maxBytes {
			err = fmt.Errorf("%s grew past %d MiB while it was copied", src.Name(), maxBytes>>20)
		}
	}
	if err == nil {
		err = tmp.Chmod(info.Mode().Perm())
	}
	if err == nil {
		err = syncFile(tmp)
	}
	if cerr := tmp.Close(); err == nil {
		err = cerr
	}
	if err == nil {
		err = replace(dirfd, tmpName, name, root, rel)
	}
	if err != nil {
		_ = unix.Unlinkat(dirfd, tmpName, 0)
		return err
	}
	return nil
}

// createTemp creates a new file in dirfd for name, and never opens one
// that exists: a name planted in advance, a link included, is not used.
// The name starts with a dot and does not end like name, so the include of
// a configuration directory (conf.d/*.conf) never reads a half written
// file. With reclaim, for a caller that holds the lock of the installation,
// the first name tried is always the same and a file a killed run left
// there is removed, so such files never pile up in the tree. Without it,
// as for the state files that the commands which only read the manifest
// write too, a name in use may be the file another kvsctl is writing, and
// it is left alone: every name is a random one.
func createTemp(dirfd int, name, dir string, reclaim bool) (string, *os.File, error) {
	for try := range 100 {
		tmpName := tempName(name)
		if !reclaim || try > 1 {
			tmpName += "-" + fmt.Sprintf("%0*x", tempSuffixLen, rand.Uint64())
		}
		fd, err := openat(dirfd, tmpName, unix.O_WRONLY|unix.O_CREAT|unix.O_EXCL|unix.O_NOFOLLOW|unix.O_CLOEXEC)
		switch {
		case err == nil:
			return tmpName, os.NewFile(uintptr(fd), filepath.Join(dir, tmpName)), nil
		case errors.Is(err, unix.EEXIST):
			if reclaim && try == 0 {
				// Unlinking never follows a link, and a directory
				// stays: the next names are random ones then.
				_ = unix.Unlinkat(dirfd, tmpName, 0)
			}
		default:
			return "", nil, &os.PathError{Op: "create", Path: filepath.Join(dir, tmpName), Err: err}
		}
	}
	return "", nil, fmt.Errorf("no free temporary name for %s in %s", name, dir)
}

// tempName is the first name createTemp gives the temporary file of name.
func tempName(name string) string { return "." + name + ".kvsctl" }

// tempSuffixLen is the width of the random number createTemp writes after
// the dash of a temporary name: 64 bits in lowercase hexadecimal, zeros
// first. Only that exact width is taken for kvsctl's, so a name an operator
// gives, such as .site.conf.kvsctl-old or .site.conf.kvsctl-20261007, stays
// the operator's.
const tempSuffixLen = 16

// temporaryOf reports whether entry is a name createTemp gives a temporary
// file of name: tempName(name), alone or with a dash and tempSuffixLen
// lowercase hexadecimal digits. Any other name is the operator's.
func temporaryOf(entry, name string) bool {
	rest, ok := strings.CutPrefix(entry, tempName(name))
	if !ok {
		return false
	}
	if rest == "" {
		return true
	}
	suffix, ok := strings.CutPrefix(rest, "-")
	if !ok || len(suffix) != tempSuffixLen {
		return false
	}
	return strings.Trim(suffix, "0123456789abcdef") == ""
}

// dropTemporaries removes from dirfd, dir by name, the temporary files of
// name: a run killed while it laid name left one there. Sync calls it for
// the files it removes, which no later lay reclaims, so the directory they
// leave empty can go, or take the file a release lays in its place. A
// directory under such a name is not kvsctl's, and stays.
func dropTemporaries(dirfd int, name, dir string) error {
	fd, err := openat(dirfd, ".", unix.O_RDONLY|unix.O_DIRECTORY|unix.O_CLOEXEC)
	if err != nil {
		return &os.PathError{Op: "open", Path: dir, Err: err}
	}
	listing := os.NewFile(uintptr(fd), dir)
	entries, err := listing.Readdirnames(-1)
	listing.Close()
	if err != nil {
		return err
	}
	for _, entry := range entries {
		if !temporaryOf(entry, name) {
			continue
		}
		err := unix.Unlinkat(dirfd, entry, 0)
		if err != nil && !errors.Is(err, unix.ENOENT) && !errors.Is(err, unix.EISDIR) {
			return &os.PathError{Op: "remove", Path: filepath.Join(dir, entry), Err: err}
		}
	}
	return nil
}

// replace renames from to to inside dirfd. A directory standing at to is
// removed first when it is empty: the files of the previous release in it
// are gone by then, and what is left belongs to the operator, which stays.
func replace(dirfd int, from, to, root, rel string) error {
	err := unix.Renameat(dirfd, from, dirfd, to)
	if errors.Is(err, unix.EISDIR) || errors.Is(err, unix.ENOTEMPTY) || errors.Is(err, unix.EEXIST) {
		if rmErr := unix.Unlinkat(dirfd, to, unix.AT_REMOVEDIR); rmErr != nil {
			if errors.Is(rmErr, unix.ENOTEMPTY) || errors.Is(rmErr, unix.EEXIST) {
				return fmt.Errorf("%s is a directory that holds files the release does not ship, where the release lays a file: move them away", filepath.Join(root, rel))
			}
			return &os.PathError{Op: "remove", Path: filepath.Join(root, rel), Err: rmErr}
		}
		err = unix.Renameat(dirfd, from, dirfd, to)
	}
	if err != nil {
		return &os.PathError{Op: "rename", Path: filepath.Join(root, rel), Err: err}
	}
	return nil
}

// remove removes the file rel below root, with the temporary files of it a
// killed run left beside it, and then the directories it leaves empty, up
// to root; needed are the directories the files being laid need, which
// stay. A file that is gone, or whose directory is gone or is now a file,
// is no error: nothing of it is left to remove. A directory standing where
// the file was goes when it is empty and stays when it holds something,
// which is not the release's to remove; Conflicts tells when the release
// needs its place. A link on the way is an error: kvsctl does not reach
// through it. It returns the nearest directory still standing, the one that
// lost an entry.
func remove(root, rel string, needed map[string]bool) (string, error) {
	dir := path.Dir(rel)
	dirfd, err := openDir(root, dir, false)
	if errors.Is(err, fs.ErrNotExist) || errors.Is(err, unix.ENOTDIR) {
		return "", nil
	}
	if err != nil {
		return "", err
	}
	name := path.Base(rel)
	if err := dropTemporaries(dirfd, name, filepath.Join(root, dir)); err != nil {
		unix.Close(dirfd)
		return "", err
	}
	err = unix.Unlinkat(dirfd, name, 0)
	if errors.Is(err, unix.EISDIR) {
		err = nil
		if !needed[rel] {
			err = unix.Unlinkat(dirfd, name, unix.AT_REMOVEDIR)
		}
		if errors.Is(err, unix.ENOTEMPTY) || errors.Is(err, unix.EEXIST) {
			unix.Close(dirfd)
			return "", nil
		}
	}
	unix.Close(dirfd)
	if err != nil && !errors.Is(err, unix.ENOENT) {
		return "", &os.PathError{Op: "remove", Path: filepath.Join(root, rel), Err: err}
	}
	// The directories the removal left empty go too, nearest first, up to
	// one the files being laid need.
	for dir != "." && !needed[dir] {
		parent, name := path.Dir(dir), path.Base(dir)
		pfd, err := openDir(root, parent, false)
		if err != nil {
			break
		}
		err = unix.Unlinkat(pfd, name, unix.AT_REMOVEDIR)
		unix.Close(pfd)
		if err != nil {
			break
		}
		dir = parent
	}
	return filepath.Join(root, dir), nil
}

// ConflictError lists what keeps the files of a release from taking their
// place; Sync returns it before it changes anything.
type ConflictError struct {
	Problems []string
}

func (e *ConflictError) Error() string {
	return strings.Join(e.Problems, "; ")
}

// Conflicts lists what keeps files, the release files about to be laid over
// root, from taking their place, previous being the files of the release in
// place: a link, or a file the operator keeps, standing where a directory
// must go; a directory holding anything else than files of previous and
// the temporary files a killed run left beside them, an empty directory of
// the operator's included, where a file must go; a link on the way to a
// file to remove. A file of the release in place is never
// in the way, since Sync removes the ones the new set drops before it lays
// it, and a link or a file at the place of a release file is replaced.
// Sync refuses to start while the list is not empty, so a caller that
// checks first, such as a plan reading the files of a bundle with
// ReadBundle, changes nothing either.
func Conflicts(root string, files, previous []string) []string {
	shipped := map[string]bool{}
	for _, f := range files {
		shipped[f] = true
	}
	old := map[string]bool{}
	for _, f := range previous {
		old[f] = true
	}
	var problems []string
	seen := map[string]bool{}
	report := func(msg string) {
		if !seen[msg] {
			seen[msg] = true
			problems = append(problems, msg)
		}
	}
	// dirsOf walks the directories on the way to rel and reports whether
	// they are all real ones; obstacle tells what to say about a file in
	// the way, "" to let it be.
	dirsOf := func(rel string, obstacle func(dir string) string) bool {
		parts := strings.Split(rel, "/")
		for n := 1; n < len(parts); n++ {
			dir := strings.Join(parts[:n], "/")
			info, err := os.Lstat(filepath.Join(root, dir))
			switch {
			case errors.Is(err, fs.ErrNotExist):
				return false
			case err != nil:
				report(fmt.Sprintf("%s cannot be read: %v", filepath.Join(root, dir), err))
				return false
			case info.Mode()&fs.ModeSymlink != 0:
				report(fmt.Sprintf("%s is a symbolic link, which kvsctl does not follow below %s: make it a directory", dir, root))
				return false
			case !info.IsDir():
				if msg := obstacle(dir); msg != "" {
					report(msg)
				}
				return false
			}
		}
		return true
	}
	for _, f := range files {
		whole := dirsOf(f, func(dir string) string {
			if old[dir] && !shipped[dir] {
				return ""
			}
			return fmt.Sprintf("%s is a file, where the release needs a directory for %s: move it away", filepath.Join(root, dir), f)
		})
		if !whole {
			continue
		}
		info, err := os.Lstat(filepath.Join(root, f))
		if err != nil || !info.IsDir() {
			continue
		}
		if other := foreign(root, f, old); other != "" {
			report(fmt.Sprintf("%s is a directory, where the release lays a file, and it holds %s, which the release does not ship: move it away", filepath.Join(root, f), other))
		}
	}
	for _, f := range previous {
		if !shipped[f] {
			dirsOf(f, func(string) string { return "" })
		}
	}
	return problems
}

// foreign is the first entry below dir that Sync would leave in place, ""
// when there is none: anything but a file of old or a temporary file of
// one, a directory included unless a file of old lies below it. Sync
// removes the files of old with the temporary files a killed run left
// beside them (remove), and the directories they leave empty, so dir is
// then empty and takes a file. A temporary file is kvsctl's own, never the
// operator's: counting it would refuse every recover of a run killed while
// it laid a file in a directory that replaced a file.
func foreign(root, dir string, old map[string]bool) string {
	holders := map[string]bool{}
	laid := map[string][]string{}
	for f := range old {
		if strings.HasPrefix(f, dir+"/") {
			laid[path.Dir(f)] = append(laid[path.Dir(f)], path.Base(f))
			for d := path.Dir(f); d != dir; d = path.Dir(d) {
				holders[d] = true
			}
		}
	}
	temporary := func(rel string) bool {
		for _, name := range laid[path.Dir(rel)] {
			if temporaryOf(path.Base(rel), name) {
				return true
			}
		}
		return false
	}
	top := filepath.Join(root, dir)
	found := ""
	_ = filepath.WalkDir(top, func(p string, d fs.DirEntry, err error) error {
		if err != nil {
			found = p
			return filepath.SkipAll
		}
		if p == top {
			return nil
		}
		rel, rerr := filepath.Rel(root, p)
		rel = filepath.ToSlash(rel)
		switch {
		case rerr != nil:
		case d.IsDir() && holders[rel]:
			return nil
		case d.Type().IsRegular() && old[rel]:
			return nil
		case !d.IsDir() && temporary(rel):
			return nil
		}
		found = p
		return filepath.SkipAll
	})
	return found
}
