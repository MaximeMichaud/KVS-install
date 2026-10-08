// Package release downloads a release bundle, verifies it and lays its
// files over the instance, keeping the previous set for a rollback.
package release

import (
	"archive/tar"
	"compress/gzip"
	"context"
	"crypto/sha256"
	"encoding/hex"
	"errors"
	"fmt"
	"hash"
	"io"
	"net/http"
	"os"
	"path"
	"path/filepath"
	"slices"
	"sort"
	"strings"
	"time"

	"golang.org/x/sys/unix"
)

// Paths are the repository paths a release ships, relative to the
// checkout: the stack, its configuration and the scripts. Instance data
// (.env, archives, dumps, rendered configuration) and the tests stay out,
// and adopt records the same paths of a git checkout.
var Paths = []string{"docker", "conf", "kvs-export.sh", "kvs-install.sh", "README.md", "LICENSE"}

// maxDownload bounds a download whose size the manifest does not give: a
// release bundle is a few megabytes and a kvsctl build a few tens. A
// variable so a test can lower it.
var maxDownload int64 = 128 << 20

// Download is DownloadSized for a download whose size the manifest does not
// give: it stops past maxDownload.
func Download(ctx context.Context, url, sha string, dest string, report func(int64)) error {
	return DownloadSized(ctx, url, sha, 0, dest, report)
}

// DownloadSized fetches url into dest and checks its sha256; size is the
// length the signed manifest gives, 0 when it gives none, and report
// receives the bytes written so far. The download stops as soon as it
// passes size (maxDownload without one), and a server that announces more
// is refused before the first byte is written: a replaced asset must not
// fill the disk the backups share before its checksum refuses it. A
// cancelled ctx ends the transfer at once, which is what Ctrl-C during a
// bundle download must do. The file reaches the disk before it takes the
// name dest, and a download that fails or does not match leaves nothing
// behind.
func DownloadSized(ctx context.Context, url, sha string, size int64, dest string, report func(int64)) error {
	limit := downloadLimit(size)
	if err := os.MkdirAll(filepath.Dir(dest), 0o750); err != nil {
		return err
	}
	reader, err := fetch(ctx, url, limit, size)
	if err != nil {
		return err
	}
	defer reader.Close()
	tmp := dest + ".part"
	out, err := os.OpenFile(tmp, os.O_RDWR|os.O_CREATE|os.O_TRUNC|unix.O_NOFOLLOW, 0o644)
	if err != nil {
		return err
	}
	sum := sha256.New()
	written, err := copyDownload(ctx, out, io.TeeReader(reader, sum), limit, report)
	switch {
	case errors.Is(err, errTooLarge):
		err = tooLarge(url, -1, size)
	case err == nil:
		err = checkDownload(url, sha, size, written, sum)
	}
	if err == nil {
		err = syncFile(out)
	}
	if cerr := out.Close(); err == nil {
		err = cerr
	}
	if err == nil {
		err = os.Rename(tmp, dest)
	}
	if err != nil {
		os.Remove(tmp)
		return err
	}
	syncDirs(map[string]bool{filepath.Dir(dest): true})
	return nil
}

// downloadLimit is the most a download of the signed size may read: that
// size, or maxDownload when the manifest gives none.
func downloadLimit(size int64) int64 {
	if size <= 0 {
		return maxDownload
	}
	return size
}

// fetch opens url, a file:// path or an http(s) URL, for reading. A server
// that announces more than limit is refused before its body is read.
func fetch(ctx context.Context, url string, limit, size int64) (io.ReadCloser, error) {
	switch {
	case strings.HasPrefix(url, "file://"):
		f, err := os.Open(strings.TrimPrefix(url, "file://"))
		if err != nil {
			return nil, err
		}
		return f, nil
	case strings.HasPrefix(url, "http://"), strings.HasPrefix(url, "https://"):
		client := &http.Client{Timeout: 10 * time.Minute}
		req, err := http.NewRequestWithContext(ctx, http.MethodGet, url, nil)
		if err != nil {
			return nil, err
		}
		resp, err := client.Do(req)
		if err != nil {
			return nil, err
		}
		if resp.StatusCode != http.StatusOK {
			resp.Body.Close()
			return nil, fmt.Errorf("%s answered %s", url, resp.Status)
		}
		if resp.ContentLength > limit {
			resp.Body.Close()
			return nil, tooLarge(url, resp.ContentLength, size)
		}
		return resp.Body, nil
	}
	return nil, fmt.Errorf("unsupported URL %q", url)
}

// checkDownload holds a download read to its end, written bytes whose
// sha256 is sum, to the size and the sha256 the manifest gives.
func checkDownload(url, sha string, size, written int64, sum hash.Hash) error {
	if size > 0 && written != size {
		return fmt.Errorf("%s ended after %d of the %d bytes the manifest gives", url, written, size)
	}
	if got := hex.EncodeToString(sum.Sum(nil)); got != strings.ToLower(sha) {
		return fmt.Errorf("checksum mismatch: the manifest says %s, the download is %s", sha, got)
	}
	return nil
}

// ReadBundle reads the bundle at url in one pass, without writing
// anything, and lists its files, sorted, the way Extract would list them:
// what a plan compares with the installation (Conflicts) before an upgrade
// takes a backup and pulls images for a release whose files could not take
// their place. It keeps the content of the files want names (slash
// separated) as Extract leaves them, the last entry of a name, up to limit
// bytes: a name the bundle does not ship, or ships larger, is left out. The
// bundle is read under the bounds of DownloadSized and must match the size
// and the sha256 the signed manifest gives, or nothing is returned.
func ReadBundle(ctx context.Context, url, sha string, size, limit int64, want ...string) ([]string, map[string][]byte, error) {
	bound := downloadLimit(size)
	body, err := fetch(ctx, url, bound, size)
	if err != nil {
		return nil, nil, err
	}
	defer body.Close()
	in := &boundedReader{ctx: ctx, r: body, limit: bound}
	sum := sha256.New()
	tee := io.TeeReader(in, sum)
	files, kept, listErr := listBundle(tee, want, limit)
	// The rest of the asset is read too, past the end of the archive or a
	// part that could not be read: only its checksum tells an asset that was
	// replaced from a signed bundle that Extract would refuse as well.
	if in.err == nil {
		_, _ = io.Copy(io.Discard, tee)
	}
	switch {
	case errors.Is(in.err, errTooLarge):
		return nil, nil, tooLarge(url, -1, size)
	case in.err != nil:
		return nil, nil, in.err
	}
	if err := checkDownload(url, sha, size, in.n, sum); err != nil {
		return nil, nil, err
	}
	if listErr != nil {
		return nil, nil, listErr
	}
	return files, kept, nil
}

// boundedReader reads r until limit bytes, stopping at once when ctx ends.
// err keeps the first error it gave, whatever a reader above it made of it.
type boundedReader struct {
	ctx   context.Context
	r     io.Reader
	limit int64
	n     int64
	err   error
}

func (b *boundedReader) Read(p []byte) (int, error) {
	if b.err != nil {
		return 0, b.err
	}
	if err := b.ctx.Err(); err != nil {
		b.err = err
		return 0, err
	}
	n, err := b.r.Read(p)
	if b.n+int64(n) > b.limit {
		b.err = errTooLarge
		return 0, b.err
	}
	b.n += int64(n)
	if err != nil && !errors.Is(err, io.EOF) {
		b.err = err
	}
	return n, err
}

// errTooLarge stops a download that goes past its limit.
var errTooLarge = errors.New("too large")

// tooLarge is the refusal of a download larger than it may be; announced
// is the length the server announced, -1 when it went past the limit while
// it was read.
func tooLarge(url string, announced, size int64) error {
	what := "goes past"
	if announced >= 0 {
		what = fmt.Sprintf("announces %d bytes, more than", announced)
	}
	if size > 0 {
		return fmt.Errorf("%s %s the %d bytes the signed manifest gives: refused", url, what, size)
	}
	return fmt.Errorf("%s %s the %d MiB kvsctl downloads without a size from the manifest: refused", url, what, maxDownload>>20)
}

// copyDownload copies in to out until the end, stopping at once when ctx
// ends, and reports the bytes written so far. A read that would take the
// total past limit is not written: errTooLarge.
func copyDownload(ctx context.Context, out io.Writer, in io.Reader, limit int64, report func(int64)) (int64, error) {
	var written int64
	buf := make([]byte, 256<<10)
	for {
		if err := ctx.Err(); err != nil {
			return written, err
		}
		n, err := in.Read(buf)
		if n > 0 {
			if written+int64(n) > limit {
				return written, errTooLarge
			}
			if _, werr := out.Write(buf[:n]); werr != nil {
				return written, werr
			}
			written += int64(n)
			if report != nil {
				report(written)
			}
		}
		if errors.Is(err, io.EOF) {
			return written, nil
		}
		if err != nil {
			return written, err
		}
	}
}

// syncFile flushes a file to disk; a variable so the tests see when it
// runs. Every file kvsctl puts in place is flushed before it takes its
// name: after a power cut, a rename that survived must not point at a file
// that did not.
var syncFile = func(f *os.File) error { return f.Sync() }

// syncDir flushes a directory, which makes the names it holds survive a
// power cut; a variable so the tests see when it runs.
var syncDir = func(dir string) error {
	// O_DIRECTORY: a fifo put in the place of a directory is refused
	// instead of waiting for a writer.
	fd, err := unix.Open(dir, unix.O_RDONLY|unix.O_DIRECTORY|unix.O_CLOEXEC, 0)
	if err != nil {
		return &os.PathError{Op: "open", Path: dir, Err: err}
	}
	defer unix.Close(fd)
	return unix.Fsync(fd)
}

// syncDirs flushes the directories that gained or lost a name. It is best
// effort: the files themselves already reached the disk, and a filesystem
// that cannot flush a directory must not fail an upgrade that has already
// laid its files.
func syncDirs(dirs map[string]bool) {
	for dir := range dirs {
		_ = syncDir(dir)
	}
}

// recordParents adds to dirs the parents of path up to the first one
// already in it: each of them gained an entry when path was made. The walk
// ends at the top directory the caller put in dirs first, or at the root
// of the filesystem.
func recordParents(dirs map[string]bool, path string) {
	for dir := filepath.Dir(path); !dirs[dir]; dir = filepath.Dir(dir) {
		dirs[dir] = true
	}
}

// maxEntries and maxBytes cap what a bundle unpacks to. A release is a few
// hundred files and a few megabytes, and the checksum comes from a signed
// manifest, so these only bound what a compromised key could unpack;
// maxBytes is a variable so a test can lower it.
const maxEntries = 20000

var maxBytes int64 = 1 << 30

// Extract unpacks a .tar.gz bundle into dir and lists its files. Paths that
// leave dir, links and devices are refused: a bundle only carries files.
// Every file is flushed to the disk as it is written, and the directories
// once the bundle is whole.
func Extract(archive, dir string) ([]string, error) {
	f, err := os.Open(archive)
	if err != nil {
		return nil, err
	}
	defer f.Close()
	gz, err := gzip.NewReader(f)
	if err != nil {
		return nil, fmt.Errorf("bundle is not gzip: %w", err)
	}
	defer gz.Close()
	if err := os.MkdirAll(dir, 0o750); err != nil {
		return nil, err
	}
	tr := tar.NewReader(gz)
	var files []string
	// The release directory took a name in its parent too.
	dirs := map[string]bool{filepath.Dir(dir): true, dir: true}
	entries := 0
	budget := maxBytes
	for {
		hdr, err := tr.Next()
		if errors.Is(err, io.EOF) {
			break
		}
		if err != nil {
			return nil, err
		}
		if entries++; entries > maxEntries {
			return nil, fmt.Errorf("bundle holds more than %d entries", maxEntries)
		}
		name, err := entryName(hdr)
		if err != nil {
			return nil, err
		}
		target := filepath.Join(dir, name)
		switch hdr.Typeflag {
		case tar.TypeDir:
			if err := os.MkdirAll(target, 0o755); err != nil {
				return nil, err
			}
			recordParents(dirs, target)
		case tar.TypeReg:
			if err := os.MkdirAll(filepath.Dir(target), 0o755); err != nil {
				return nil, err
			}
			recordParents(dirs, target)
			mode := os.FileMode(hdr.Mode).Perm() | 0o600
			out, err := os.OpenFile(target, os.O_CREATE|os.O_WRONLY|os.O_TRUNC|unix.O_NOFOLLOW, mode)
			if err != nil {
				return nil, err
			}
			written, err := io.Copy(out, io.LimitReader(tr, budget+1))
			if err == nil {
				// The mode is set on the file, not left to the umask
				// kvsctl runs under: the scripts must stay executable
				// and the files readable by the containers.
				err = out.Chmod(mode)
			}
			if err == nil {
				// A release directory is what a later rollback lays
				// back, so it reaches the disk like the files laid
				// over the installation.
				err = syncFile(out)
			}
			if cerr := out.Close(); err == nil {
				err = cerr
			}
			if err != nil {
				return nil, err
			}
			if written > budget {
				return nil, fmt.Errorf("bundle unpacks to more than %d MiB", maxBytes>>20)
			}
			budget -= written
			files = append(files, name)
		}
	}
	syncDirs(dirs)
	sort.Strings(files)
	return files, nil
}

// entryName is the path of a bundle entry, slash separated and relative to
// the bundle; an entry that leaves the bundle, or that is neither a
// directory nor a regular file, is refused.
func entryName(hdr *tar.Header) (string, error) {
	name := filepath.Clean(hdr.Name)
	if name == "." || strings.HasPrefix(name, "..") || filepath.IsAbs(name) {
		return "", fmt.Errorf("bundle entry %q leaves the bundle", hdr.Name)
	}
	if hdr.Typeflag != tar.TypeDir && hdr.Typeflag != tar.TypeReg {
		return "", fmt.Errorf("bundle entry %q is not a plain file", hdr.Name)
	}
	return filepath.ToSlash(name), nil
}

// listBundle lists the files of the .tar.gz bundle r holds, sorted, under
// the rules and bounds of Extract, and keeps the content of the files want
// names, up to limit bytes each (ReadBundle).
func listBundle(r io.Reader, want []string, limit int64) ([]string, map[string][]byte, error) {
	gz, err := gzip.NewReader(r)
	if err != nil {
		return nil, nil, fmt.Errorf("bundle is not gzip: %w", err)
	}
	defer gz.Close()
	tr := tar.NewReader(gz)
	var files []string
	kept := map[string][]byte{}
	entries := 0
	var total int64
	for {
		hdr, err := tr.Next()
		if errors.Is(err, io.EOF) {
			break
		}
		if err != nil {
			return nil, nil, err
		}
		if entries++; entries > maxEntries {
			return nil, nil, fmt.Errorf("bundle holds more than %d entries", maxEntries)
		}
		name, err := entryName(hdr)
		if err != nil {
			return nil, nil, err
		}
		if hdr.Typeflag != tar.TypeReg {
			continue
		}
		if total += hdr.Size; total > maxBytes {
			return nil, nil, fmt.Errorf("bundle unpacks to more than %d MiB", maxBytes>>20)
		}
		files = append(files, name)
		if !slices.Contains(want, name) {
			continue
		}
		// A later entry of the name is the one Extract leaves in place.
		delete(kept, name)
		if hdr.Size <= limit {
			data, err := io.ReadAll(tr)
			if err != nil {
				return nil, nil, err
			}
			kept[name] = data
		}
	}
	sort.Strings(files)
	return files, kept, nil
}

// Sync copies the files of src (a release directory) over root and removes
// the files of the previous release that the new one no longer ships. The
// instance's own data is never listed in a release, so it is never touched.
// Nothing below root is reached through a link (see beneath.go), and what
// Conflicts finds in the way stops Sync before it changes anything. The
// files the new set drops go first: one of them may stand where the new
// set needs a directory, or its directory where the new set lays a file.
// Each file reaches the disk before it replaces the one in place, and the
// directories that changed are flushed at the end.
func Sync(src, root string, files, previous []string) error {
	if problems := Conflicts(root, files, previous); len(problems) > 0 {
		return &ConflictError{Problems: problems}
	}
	keep := map[string]bool{}
	needed := map[string]bool{}
	for _, f := range files {
		keep[f] = true
		for dir := path.Dir(f); dir != "."; dir = path.Dir(dir) {
			needed[dir] = true
		}
	}
	// The directories are flushed even when a step fails: what changed
	// before the failure is the installation now, and a recovery reads it.
	dirs := map[string]bool{root: true}
	defer func() { syncDirs(dirs) }()
	for _, f := range previous {
		if keep[f] {
			continue
		}
		standing, err := remove(root, f, needed)
		if err != nil {
			return err
		}
		if standing != "" {
			dirs[standing] = true
		}
	}
	for _, f := range files {
		if err := lay(src, root, f); err != nil {
			return err
		}
		// Replacing a file is a new entry in its directory, so the
		// directory of every laid file is flushed, not only new ones.
		recordParents(dirs, filepath.Join(root, f))
	}
	return nil
}

// Snapshot copies the listed files of root into dest, which is how the
// running version is kept before an upgrade replaces it. The copy is built
// beside dest, flushed to the disk and renamed into place, so a crash, a
// power cut or a full disk never leaves a half tree where a rollback would
// read a whole one. The files are read below root the way Sync lays them:
// through real directories, regular files only.
func Snapshot(root, dest string, files []string) error {
	parent := filepath.Dir(dest)
	if err := os.MkdirAll(parent, 0o750); err != nil {
		return err
	}
	tmp, err := os.MkdirTemp(parent, filepath.Base(dest)+".tmp-")
	if err != nil {
		return err
	}
	dirs := map[string]bool{tmp: true}
	for _, f := range files {
		if err := lay(root, tmp, f); err != nil {
			os.RemoveAll(tmp)
			return err
		}
		recordParents(dirs, filepath.Join(tmp, f))
	}
	// The whole tree reaches the disk before it takes the name a rollback
	// reads it by.
	syncDirs(dirs)
	if err := os.RemoveAll(dest); err != nil {
		os.RemoveAll(tmp)
		return err
	}
	if err := os.Rename(tmp, dest); err != nil {
		os.RemoveAll(tmp)
		return err
	}
	syncDirs(map[string]bool{parent: true})
	return nil
}

// Checksums is the sha256 of each listed file of root, relative path to hex
// sum. A missing file is an error: the list is what a release laid down.
func Checksums(root string, files []string) (map[string]string, error) {
	sums := make(map[string]string, len(files))
	for _, f := range files {
		sum, err := sha256Beneath(root, f)
		if err != nil {
			return nil, fmt.Errorf("checksum %s: %w", f, err)
		}
		sums[f] = sum
	}
	return sums, nil
}

// Verify lists, sorted, the files of root whose content no longer matches
// sums, the missing ones included: what was edited on the machine since the
// release laid its files down. A file that is now a link, a fifo, a device
// or a directory, or that is reached through a link, is not the one the
// release laid either, and is listed without being read.
func Verify(root string, sums map[string]string) (changed []string, err error) {
	for f, want := range sums {
		got, err := sha256Beneath(root, f)
		switch {
		case errors.Is(err, os.ErrNotExist), errors.Is(err, errNotLaid), errors.Is(err, errOversized):
			// A file that is gone, or is not one kvsctl laid, or one
			// larger than any release file, is not the release's any more.
			changed = append(changed, f)
		case err != nil:
			return nil, fmt.Errorf("checksum %s: %w", f, err)
		case got != want:
			changed = append(changed, f)
		}
	}
	sort.Strings(changed)
	return changed, nil
}

// errOversized is a file larger than any release file can be.
var errOversized = errors.New("larger than any release file")

// sha256Beneath hashes the regular file rel below root, which is no larger
// than a whole bundle unpacks to.
func sha256Beneath(root, rel string) (string, error) {
	f, err := openFile(root, rel)
	if err != nil {
		return "", err
	}
	defer f.Close()
	info, err := f.Stat()
	if err != nil {
		return "", err
	}
	if info.Size() > maxBytes {
		return "", fmt.Errorf("%s: %w (%d MiB)", f.Name(), errOversized, maxBytes>>20)
	}
	sum := sha256.New()
	n, err := io.Copy(sum, io.LimitReader(f, maxBytes+1))
	if err != nil {
		return "", err
	}
	if n > maxBytes {
		return "", fmt.Errorf("%s: %w (%d MiB)", f.Name(), errOversized, maxBytes>>20)
	}
	return hex.EncodeToString(sum.Sum(nil)), nil
}
