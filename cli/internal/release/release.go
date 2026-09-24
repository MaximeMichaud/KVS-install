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
	"io"
	"net/http"
	"os"
	"path/filepath"
	"sort"
	"strings"
	"time"
)

// Paths are the repository paths a release ships, relative to the
// checkout: the stack, its configuration and the scripts. Instance data
// (.env, archives, dumps, rendered configuration) and the tests stay out,
// and adopt records the same paths of a git checkout.
var Paths = []string{"docker", "conf", "kvs-export.sh", "kvs-install.sh", "README.md", "LICENSE"}

// Download fetches url into dest and checks its sha256; report receives
// the bytes written so far. A cancelled ctx ends the transfer at once,
// which is what Ctrl-C during a bundle download must do.
func Download(ctx context.Context, url, sha string, dest string, report func(int64)) error {
	if err := os.MkdirAll(filepath.Dir(dest), 0o750); err != nil {
		return err
	}
	var reader io.ReadCloser
	switch {
	case strings.HasPrefix(url, "file://"):
		f, err := os.Open(strings.TrimPrefix(url, "file://"))
		if err != nil {
			return err
		}
		reader = f
	case strings.HasPrefix(url, "http://"), strings.HasPrefix(url, "https://"):
		client := &http.Client{Timeout: 10 * time.Minute}
		req, err := http.NewRequestWithContext(ctx, http.MethodGet, url, nil)
		if err != nil {
			return err
		}
		resp, err := client.Do(req)
		if err != nil {
			return err
		}
		if resp.StatusCode != http.StatusOK {
			resp.Body.Close()
			return fmt.Errorf("%s answered %s", url, resp.Status)
		}
		reader = resp.Body
	default:
		return fmt.Errorf("unsupported URL %q", url)
	}
	defer reader.Close()
	tmp := dest + ".part"
	out, err := os.Create(tmp)
	if err != nil {
		return err
	}
	hash := sha256.New()
	var written int64
	buf := make([]byte, 256<<10)
	for {
		if err := ctx.Err(); err != nil {
			out.Close()
			return err
		}
		n, err := reader.Read(buf)
		if n > 0 {
			if _, werr := out.Write(buf[:n]); werr != nil {
				out.Close()
				return werr
			}
			hash.Write(buf[:n])
			written += int64(n)
			if report != nil {
				report(written)
			}
		}
		if errors.Is(err, io.EOF) {
			break
		}
		if err != nil {
			out.Close()
			return err
		}
	}
	if err := out.Close(); err != nil {
		return err
	}
	if got := hex.EncodeToString(hash.Sum(nil)); got != strings.ToLower(sha) {
		os.Remove(tmp)
		return fmt.Errorf("bundle checksum mismatch: manifest says %s, download is %s", sha, got)
	}
	return os.Rename(tmp, dest)
}

// maxEntries and maxBytes cap what a bundle unpacks to. A release is a few
// hundred files and a few megabytes, and the checksum comes from a signed
// manifest, so these only bound what a compromised key could unpack.
const (
	maxEntries = 20000
	maxBytes   = 1 << 30
)

// Extract unpacks a .tar.gz bundle into dir and lists its files. Paths that
// leave dir, links and devices are refused: a bundle only carries files.
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
	entries := 0
	budget := int64(maxBytes)
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
		name := filepath.Clean(hdr.Name)
		if name == "." || strings.HasPrefix(name, "..") || filepath.IsAbs(name) {
			return nil, fmt.Errorf("bundle entry %q leaves the bundle", hdr.Name)
		}
		target := filepath.Join(dir, name)
		switch hdr.Typeflag {
		case tar.TypeDir:
			if err := os.MkdirAll(target, 0o755); err != nil {
				return nil, err
			}
		case tar.TypeReg:
			if err := os.MkdirAll(filepath.Dir(target), 0o755); err != nil {
				return nil, err
			}
			out, err := os.OpenFile(target, os.O_CREATE|os.O_WRONLY|os.O_TRUNC, os.FileMode(hdr.Mode).Perm()|0o600)
			if err != nil {
				return nil, err
			}
			written, err := io.Copy(out, io.LimitReader(tr, budget+1))
			if err != nil {
				out.Close()
				return nil, err
			}
			if err := out.Close(); err != nil {
				return nil, err
			}
			if written > budget {
				return nil, fmt.Errorf("bundle unpacks to more than %d MiB", maxBytes>>20)
			}
			budget -= written
			files = append(files, filepath.ToSlash(name))
		default:
			return nil, fmt.Errorf("bundle entry %q is not a plain file", hdr.Name)
		}
	}
	sort.Strings(files)
	return files, nil
}

// Sync copies the files of src (a release directory) over root and removes
// the files of the previous release that the new one no longer ships. The
// instance's own data is never listed in a release, so it is never touched.
func Sync(src, root string, files, previous []string) error {
	keep := map[string]bool{}
	for _, f := range files {
		keep[f] = true
		if err := copyFile(filepath.Join(src, f), filepath.Join(root, f)); err != nil {
			return err
		}
	}
	for _, f := range previous {
		if keep[f] {
			continue
		}
		target := filepath.Join(root, f)
		if err := os.Remove(target); err != nil && !errors.Is(err, os.ErrNotExist) {
			return err
		}
		removeEmptyParents(filepath.Dir(target), root)
	}
	return nil
}

// Snapshot copies the listed files of root into dest, which is how the
// running version is kept before an upgrade replaces it. The copy is built
// beside dest and renamed into place, so a crash or a full disk never
// leaves a half tree where a rollback would read a whole one.
func Snapshot(root, dest string, files []string) error {
	parent := filepath.Dir(dest)
	if err := os.MkdirAll(parent, 0o750); err != nil {
		return err
	}
	tmp, err := os.MkdirTemp(parent, filepath.Base(dest)+".tmp-")
	if err != nil {
		return err
	}
	for _, f := range files {
		if err := copyFile(filepath.Join(root, f), filepath.Join(tmp, f)); err != nil {
			os.RemoveAll(tmp)
			return err
		}
	}
	if err := os.RemoveAll(dest); err != nil {
		os.RemoveAll(tmp)
		return err
	}
	if err := os.Rename(tmp, dest); err != nil {
		os.RemoveAll(tmp)
		return err
	}
	return nil
}

// Checksums is the sha256 of each listed file of root, relative path to hex
// sum. A missing file is an error: the list is what a release laid down.
func Checksums(root string, files []string) (map[string]string, error) {
	sums := make(map[string]string, len(files))
	for _, f := range files {
		sum, err := sha256File(filepath.Join(root, f))
		if err != nil {
			return nil, fmt.Errorf("checksum %s: %w", f, err)
		}
		sums[f] = sum
	}
	return sums, nil
}

// Verify lists, sorted, the files of root whose content no longer matches
// sums, the missing ones included: what was edited on the machine since the
// release laid its files down.
func Verify(root string, sums map[string]string) (changed []string, err error) {
	for f, want := range sums {
		got, err := sha256File(filepath.Join(root, f))
		switch {
		case errors.Is(err, os.ErrNotExist):
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

func sha256File(path string) (string, error) {
	f, err := os.Open(path)
	if err != nil {
		return "", err
	}
	defer f.Close()
	hash := sha256.New()
	if _, err := io.Copy(hash, f); err != nil {
		return "", err
	}
	return hex.EncodeToString(hash.Sum(nil)), nil
}

func copyFile(src, dst string) error {
	info, err := os.Lstat(src)
	if err != nil {
		return err
	}
	if !info.Mode().IsRegular() {
		return fmt.Errorf("%s is not a regular file", src)
	}
	in, err := os.Open(src)
	if err != nil {
		return err
	}
	defer in.Close()
	if err := os.MkdirAll(filepath.Dir(dst), 0o755); err != nil {
		return err
	}
	tmp := dst + ".kvsctl.tmp"
	out, err := os.OpenFile(tmp, os.O_CREATE|os.O_WRONLY|os.O_TRUNC, info.Mode().Perm())
	if err != nil {
		return err
	}
	if _, err := io.Copy(out, in); err != nil {
		out.Close()
		os.Remove(tmp)
		return err
	}
	if err := out.Close(); err != nil {
		os.Remove(tmp)
		return err
	}
	if err := os.Chmod(tmp, info.Mode().Perm()); err != nil {
		os.Remove(tmp)
		return err
	}
	return os.Rename(tmp, dst)
}

func removeEmptyParents(dir, root string) {
	for dir != root && strings.HasPrefix(dir, root) {
		if err := os.Remove(dir); err != nil {
			return
		}
		dir = filepath.Dir(dir)
	}
}
