package release

import (
	"errors"
	"fmt"
	"io"
	"io/fs"
	"os"
	"path"
	"path/filepath"
	"strconv"
	"strings"

	"golang.org/x/sys/unix"
)

// Some directories of an installation are written by containers: the nginx
// container writes docker/nginx/conf.d through a bind mount, as root, and
// the PHP container owns the web root. kvsctl runs as root on the host, so a
// link planted there must never make it read, write or change a file
// elsewhere. Below a root, every path is therefore walked one directory at a
// time without following a link, a file is only read once it is known to be
// a regular file, and a file is published inside its directory without
// writing through an existing link. The root itself is opened as given:
// an operator may reach the installation through a link.

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
	tmpName, tmp, err := createTemp(dirfd, name)
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

var renameNew = unix.Renameat2
var linkNew = unix.Linkat

// lay puts a copy of the regular file rel of srcRoot at rel below root,
// with the mode of the source. The copy is written to a new temporary file
// in the target directory and published only after it has been flushed.
func lay(srcRoot, root, rel string, managed bool, journal *SyncJournal) error {
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
	tmpName, tmp, err := createTemp(dirfd, name)
	if err != nil {
		return err
	}
	published := false
	defer func() {
		if !published {
			_ = unix.Unlinkat(dirfd, tmpName, 0)
		}
	}()
	if journal != nil {
		var st unix.Stat_t
		if err := unix.Fstat(int(tmp.Fd()), &st); err != nil {
			tmp.Close()
			return err
		}
		pending := PendingCopy{File: rel, Temporary: path.Join(dir, tmpName), Device: uint64(st.Dev), Inode: st.Ino}
		if err := journal.Pending(pending); err != nil {
			tmp.Close()
			return err
		}
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
		err = tmp.Chmod(info.Mode() & 0o755)
	}
	if err == nil {
		err = syncFile(tmp)
	}
	if cerr := tmp.Close(); err == nil {
		err = cerr
	}
	if err != nil {
		return err
	}
	if managed {
		err = replace(dirfd, tmpName, name, root, rel)
	} else {
		err = renameNew(dirfd, tmpName, dirfd, name, unix.RENAME_NOREPLACE)
		// ENOTSUP and EOPNOTSUPP are the same errno on Linux.
		switch err {
		case unix.ENOSYS, unix.EINVAL, unix.EOPNOTSUPP:
			err = linkNew(dirfd, tmpName, dirfd, name, 0)
			if err == nil {
				// Until unlink completes, both names refer to the journaled inode.
				err = unix.Unlinkat(dirfd, tmpName, 0)
			}
		}
		if err != nil {
			err = &os.PathError{Op: "publish new release file without replacing an existing entry", Path: filepath.Join(root, rel), Err: err}
		}
	}
	if err != nil {
		return err
	}
	published = true
	if !managed && journal != nil {
		return journal.Created(rel)
	}
	return nil
}

// Keep the reservation short and distinct from the destination, even when a
// release ships a file whose name looks like a temporary.
func tempPrefix(name string) string {
	if strings.HasPrefix(name, ".kvsctl-") {
		return ".kvsctl."
	}
	return ".kvsctl-"
}

// Use the open directory as CreateTemp's parent. Looking it up again
// through root would let a concurrent directory change redirect the copy.
func createTemp(dirfd int, name string) (string, *os.File, error) {
	tmp, err := os.CreateTemp("/proc/self/fd/"+strconv.Itoa(dirfd), tempPrefix(name)+"*")
	if err != nil {
		return "", nil, err
	}
	return path.Base(tmp.Name()), tmp, nil
}

// PendingCopy names the temporary reserved in the destination directory.
// Its inode distinguishes it from a local file later given the same name.
type PendingCopy struct {
	File      string `json:"file"`
	Temporary string `json:"temporary"`
	Device    uint64 `json:"device"`
	Inode     uint64 `json:"inode"`
}

// RemovePending removes only the file named and identified by this journal.
func RemovePending(root string, pending PendingCopy) error {
	file, tmp := pending.File, pending.Temporary
	base, name := path.Base(tmp), path.Base(file)
	suffix, ok := strings.CutPrefix(base, tempPrefix(name))
	if !ok {
		// Journals from earlier runs used the final name in the prefix.
		suffix, ok = strings.CutPrefix(base, "."+name+".kvsctl-")
	}
	if !IsFile(file) || path.Clean(tmp) != tmp || path.Dir(tmp) != path.Dir(file) || !ok || suffix == "" {
		return fmt.Errorf("invalid journal temporary %q for %q", tmp, file)
	}
	fd, err := openDir(root, path.Dir(tmp), false)
	if errors.Is(err, unix.ENOENT) || errors.Is(err, unix.ENOTDIR) {
		return nil
	}
	if err != nil {
		return err
	}
	defer unix.Close(fd)
	st, err := statAt(fd, path.Base(tmp), filepath.Join(root, tmp))
	if err != nil || st == nil {
		return err
	}
	if uint64(st.Dev) != pending.Device || st.Ino != pending.Inode || st.Mode&unix.S_IFMT != unix.S_IFREG {
		return nil
	}
	if err := unix.Unlinkat(fd, path.Base(tmp), 0); err != nil && !errors.Is(err, unix.ENOENT) {
		return err
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

// remove removes the file rel below root and prunes empty directories up to
// a directory that the files being laid need. A file that is gone, or whose directory is gone or is now a file,
// is no error: nothing of it is left to remove. A directory standing where
// the file was goes when it is empty and stays when it holds something,
// which is not the release's to remove; Conflicts tells when the release
// needs its place. A link on the way is an error: kvsctl does not reach
// through it. It returns the nearest directory still standing, the one that
// lost an entry.
func remove(root, rel string, needed, incoming map[string]bool) (string, error) {
	dir := path.Dir(rel)
	dirfd, err := openDir(root, dir, false)
	if errors.Is(err, fs.ErrNotExist) {
		// The leaf directory may already be gone while an empty managed
		// ancestor still stands where the incoming release needs a file.
		for ancestor := dir; ancestor != "."; ancestor = path.Dir(ancestor) {
			if incoming[ancestor] {
				return pruneParents(root, dir, needed), nil
			}
		}
		return "", nil
	}
	if errors.Is(err, unix.ENOTDIR) {
		return "", nil
	}
	if err != nil {
		return "", err
	}
	name := path.Base(rel)
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
	return pruneParents(root, dir, needed), nil
}

func pruneParents(root, dir string, needed map[string]bool) string {
	// The directories the removal left empty go too, nearest first, up to
	// one the files being laid need.
	for dir != "." && !needed[dir] {
		parent, name := path.Dir(dir), path.Base(dir)
		pfd, err := openDir(root, parent, false)
		if err == nil {
			err = unix.Unlinkat(pfd, name, unix.AT_REMOVEDIR)
			unix.Close(pfd)
		}
		if err != nil && !errors.Is(err, unix.ENOENT) {
			break
		}
		dir = parent
	}
	return filepath.Join(root, dir)
}

// ConflictError lists what keeps the files of a release from taking their
// place; Sync returns it before it changes anything.
type ConflictError struct {
	Problems []string
}

func (e *ConflictError) Error() string {
	return strings.Join(e.Problems, "; ")
}

// Conflicts reports obstacles before Sync starts removing or laying files.
// Only paths owned by the previous release can give way. A directory the
// release used is replaceable only when it holds no local entries.
func Conflicts(root string, files, previous []string) []string {
	// Older state can name local files even when the new bundle is valid.
	for _, list := range [][]string{files, previous} {
		for _, name := range list {
			if !releasePath(name, false) {
				return []string{fmt.Sprintf("%q is outside the release paths", name)}
			}
		}
	}
	shipped := map[string]bool{}
	for _, f := range files {
		shipped[f] = true
	}
	old := map[string]bool{}
	oldDirs := map[string]bool{}
	for _, f := range previous {
		for dir := path.Dir(f); dir != "."; dir = path.Dir(dir) {
			oldDirs[dir] = true
		}
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
		if err != nil {
			if !errors.Is(err, fs.ErrNotExist) {
				report(fmt.Sprintf("%s cannot be read: %v", filepath.Join(root, f), err))
			}
			continue
		}
		if info.IsDir() {
			if other := foreign(root, f, old); other != "" {
				report(fmt.Sprintf("%s is a directory, where the release lays a file, and it holds %s, which the release does not ship: move it away", filepath.Join(root, f), other))
				continue
			}
			if oldDirs[f] {
				continue
			}
		}
		if !old[f] {
			report(fmt.Sprintf("%s is a local file the previous release did not own: move it away", filepath.Join(root, f)))
		}
	}
	for _, f := range previous {
		if !shipped[f] {
			dirsOf(f, func(string) string { return "" })
		}
	}
	return problems
}

// foreign is the first entry in a managed directory that would survive
// removal of the previous release files. Unrecorded temporaries are local.
func foreign(root, dir string, old map[string]bool) string {
	holders := map[string]bool{}
	for f := range old {
		if strings.HasPrefix(f, dir+"/") {
			for d := path.Dir(f); d != dir; d = path.Dir(d) {
				holders[d] = true
			}
		}
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
		}
		found = p
		return filepath.SkipAll
	})
	return found
}
