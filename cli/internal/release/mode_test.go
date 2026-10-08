package release

import (
	"archive/tar"
	"compress/gzip"
	"crypto/sha256"
	"encoding/hex"
	"errors"
	"os"
	"path/filepath"
	"slices"
	"strings"
	"syscall"
	"testing"
)

// tarEntry is one member of a test bundle.
type tarEntry struct {
	hdr     tar.Header
	content string
}

func makeTar(t *testing.T, path string, entries ...tarEntry) {
	t.Helper()
	f, err := os.Create(path)
	if err != nil {
		t.Fatal(err)
	}
	gz := gzip.NewWriter(f)
	tw := tar.NewWriter(gz)
	for _, e := range entries {
		hdr := e.hdr
		if hdr.Typeflag == tar.TypeReg {
			hdr.Size = int64(len(e.content))
		}
		if err := tw.WriteHeader(&hdr); err != nil {
			t.Fatal(err)
		}
		if _, err := tw.Write([]byte(e.content)); err != nil {
			t.Fatal(err)
		}
	}
	for _, c := range []interface{ Close() error }{tw, gz, f} {
		if err := c.Close(); err != nil {
			t.Fatal(err)
		}
	}
}

func file(name string, mode int64, content string) tarEntry {
	return tarEntry{hdr: tar.Header{Name: name, Mode: mode, Typeflag: tar.TypeReg}, content: content}
}

func modeOf(t *testing.T, p string) os.FileMode {
	t.Helper()
	info, err := os.Lstat(p)
	if err != nil {
		t.Fatal(err)
	}
	return info.Mode()
}

// The scripts of a release stay executable and its files readable by the
// containers after Extract, Sync and Snapshot, whatever umask kvsctl runs
// under: phpmyadmin-init runs docker/phpmyadmin/init.sh as its entrypoint.
func TestExtractSyncAndSnapshotKeepModes(t *testing.T) {
	old := syscall.Umask(0o077)
	t.Cleanup(func() { syscall.Umask(old) })
	dir := t.TempDir()
	bundle := filepath.Join(dir, "b.tar.gz")
	makeTar(t, bundle,
		file("docker/phpmyadmin/init.sh", 0o755, "#!/bin/sh\n"),
		file("docker/php/kvs.ini", 0o644, "memory_limit=512M\n"),
		file("docker/secret.example", 0o600, "x\n"))
	rel := filepath.Join(dir, "rel")
	if _, err := Extract(bundle, rel); err != nil {
		t.Fatal(err)
	}
	want := map[string]os.FileMode{"docker/phpmyadmin/init.sh": 0o755, "docker/php/kvs.ini": 0o644, "docker/secret.example": 0o600}
	files := []string{"docker/php/kvs.ini", "docker/phpmyadmin/init.sh", "docker/secret.example"}
	for f, mode := range want {
		if got := modeOf(t, filepath.Join(rel, f)); got != mode {
			t.Errorf("%s after Extract: %v, want %v", f, got, mode)
		}
	}
	root := mkdir(t, filepath.Join(dir, "root"))
	// The files in place had other modes: the release decides.
	writeTree(t, root, map[string]string{"docker/phpmyadmin/init.sh": "old", "docker/php/kvs.ini": "old"})
	os.Chmod(filepath.Join(root, "docker/phpmyadmin/init.sh"), 0o600)
	os.Chmod(filepath.Join(root, "docker/php/kvs.ini"), 0o600)
	if err := Sync(rel, root, files, files[:2]); err != nil {
		t.Fatal(err)
	}
	for f, mode := range want {
		if got := modeOf(t, filepath.Join(root, f)); got != mode {
			t.Errorf("%s after Sync: %v, want %v", f, got, mode)
		}
	}
	snap := filepath.Join(dir, "snap")
	if err := Snapshot(root, snap, files); err != nil {
		t.Fatal(err)
	}
	for f, mode := range want {
		if got := modeOf(t, filepath.Join(snap, f)); got != mode {
			t.Errorf("%s in the snapshot: %v, want %v", f, got, mode)
		}
	}
}

// A bundle only carries plain files: a link, a hard link or a device is
// refused, and nothing is made at its name.
func TestExtractRefusesWhatIsNotAPlainFile(t *testing.T) {
	dir := t.TempDir()
	for _, e := range []tarEntry{
		{hdr: tar.Header{Name: "docker/setup.sh", Typeflag: tar.TypeSymlink, Linkname: "/etc/passwd", Mode: 0o777}},
		{hdr: tar.Header{Name: "docker/setup.sh", Typeflag: tar.TypeLink, Linkname: "docker/other.sh", Mode: 0o644}},
		{hdr: tar.Header{Name: "docker/setup.sh", Typeflag: tar.TypeChar, Devmajor: 1, Devminor: 3, Mode: 0o666}},
		{hdr: tar.Header{Name: "docker/setup.sh", Typeflag: tar.TypeFifo, Mode: 0o644}},
	} {
		bundle := filepath.Join(dir, "b.tar.gz")
		makeTar(t, bundle, file("docker/other.sh", 0o755, "other"), e)
		out := filepath.Join(dir, "out")
		os.RemoveAll(out)
		_, err := Extract(bundle, out)
		if err == nil || !strings.Contains(err.Error(), `"docker/setup.sh" is not a plain file`) {
			t.Errorf("type %q: %v, want a refusal", e.hdr.Typeflag, err)
		}
		if _, err := os.Lstat(filepath.Join(out, "docker/setup.sh")); !errors.Is(err, os.ErrNotExist) {
			t.Errorf("type %q: something was made at its name: %v", e.hdr.Typeflag, err)
		}
	}
}

// What a bundle unpacks to is bounded in bytes, whatever its member headers
// say.
func TestExtractRefusesABundleOverTheByteBudget(t *testing.T) {
	old := maxBytes
	t.Cleanup(func() { maxBytes = old })
	maxBytes = 64
	dir := t.TempDir()
	bundle := filepath.Join(dir, "b.tar.gz")
	makeTar(t, bundle, file("a", 0o644, strings.Repeat("a", 40)), file("b", 0o644, strings.Repeat("b", 40)))
	if _, err := Extract(bundle, filepath.Join(dir, "out")); err == nil || !strings.Contains(err.Error(), "bundle unpacks to more than") {
		t.Errorf("a bundle over the byte budget: %v", err)
	}
	makeTar(t, bundle, file("a", 0o644, strings.Repeat("a", 30)), file("b", 0o644, strings.Repeat("b", 30)))
	if _, err := Extract(bundle, filepath.Join(dir, "fits")); err != nil {
		t.Errorf("a bundle within the byte budget: %v", err)
	}
	// Sync and Snapshot never copy a file larger than a bundle can unpack
	// to: the release directory or the tree changed since.
	root := mkdir(t, filepath.Join(dir, "root"))
	writeTree(t, filepath.Join(dir, "big"), map[string]string{"a": strings.Repeat("x", 65)})
	if err := Sync(filepath.Join(dir, "big"), root, []string{"a"}, nil); err == nil || !strings.Contains(err.Error(), "larger than any release file") {
		t.Errorf("Sync of a file over the budget: %v", err)
	}
	if err := Snapshot(filepath.Join(dir, "big"), filepath.Join(dir, "snap"), []string{"a"}); err == nil || !strings.Contains(err.Error(), "larger than any release file") {
		t.Errorf("Snapshot of a file over the budget: %v", err)
	}
	// Nor is such a file hashed: Checksums refuses it, and Verify lists it
	// as changed even when the sum of its content is the one on record.
	if _, err := Checksums(filepath.Join(dir, "big"), []string{"a"}); !errors.Is(err, errOversized) {
		t.Errorf("Checksums of a file over the budget: %v", err)
	}
	whole := sha256.Sum256([]byte(strings.Repeat("x", 65)))
	if changed, err := Verify(filepath.Join(dir, "big"), map[string]string{"a": hex.EncodeToString(whole[:])}); err != nil || !slices.Equal(changed, []string{"a"}) {
		t.Errorf("Verify of a file over the budget = %q, %v; want it listed", changed, err)
	}
}

// Sync lays and Snapshot keeps only regular files: a link in the release
// directory or in the tree is refused, and nothing is laid in its place.
func TestSyncAndSnapshotCopyOnlyRegularFiles(t *testing.T) {
	dir := t.TempDir()
	secret := victim(t, dir, "secret")
	src, root := filepath.Join(dir, "rel"), mkdir(t, filepath.Join(dir, "root"))
	writeTree(t, src, map[string]string{"docker/a.sh": "a"})
	symlink(t, secret, filepath.Join(src, "docker/setup.sh"))
	files := []string{"docker/a.sh", "docker/setup.sh"}
	if err := Sync(src, root, files, nil); !errors.Is(err, errNotLaid) {
		t.Errorf("Sync of a link: %v, want a refusal", err)
	}
	if _, err := os.Lstat(filepath.Join(root, "docker/setup.sh")); !errors.Is(err, os.ErrNotExist) {
		t.Errorf("Sync laid something for a link: %v", err)
	}
	writeTree(t, root, map[string]string{"docker/a.sh": "a"})
	symlink(t, secret, filepath.Join(root, "docker/setup.sh"))
	if err := Snapshot(root, filepath.Join(dir, "snap"), files); !errors.Is(err, errNotLaid) {
		t.Errorf("Snapshot of a link: %v, want a refusal", err)
	}
	if _, err := os.Lstat(filepath.Join(dir, "snap")); !errors.Is(err, os.ErrNotExist) {
		t.Errorf("a refused snapshot leaves nothing: %v", err)
	}
	untouched(t, secret)
}

// A directory Sync makes for the files of a release is 0755 whatever umask
// kvsctl runs under: the containers read what is laid in it.
func TestSyncMakesDirectoriesTheContainersRead(t *testing.T) {
	old := syscall.Umask(0o077)
	t.Cleanup(func() { syscall.Umask(old) })
	dir := t.TempDir()
	src, root := filepath.Join(dir, "rel"), mkdir(t, filepath.Join(dir, "root"))
	writeTree(t, src, map[string]string{"docker/nginx/snippets/site.conf": "location / {}\n"})
	if err := Sync(src, root, []string{"docker/nginx/snippets/site.conf"}, nil); err != nil {
		t.Fatal(err)
	}
	for _, d := range []string{"docker", "docker/nginx", "docker/nginx/snippets"} {
		if got := modeOf(t, filepath.Join(root, d)); got != os.ModeDir|0o755 {
			t.Errorf("%s: %v, want %v", d, got, os.ModeDir|0o755)
		}
	}
}
