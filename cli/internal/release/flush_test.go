package release

import (
	"context"
	"errors"
	"os"
	"path/filepath"
	"slices"
	"strings"
	"testing"
)

// stubFlushes replaces the flushes of the package for one test, so the
// test sees when they run and what was already in place at that moment.
func stubFlushes(t *testing.T, file func(*os.File) error, dir func(string) error) {
	t.Helper()
	oldFile, oldDir := syncFile, syncDir
	t.Cleanup(func() { syncFile, syncDir = oldFile, oldDir })
	syncFile, syncDir = file, dir
}

func writeTree(t *testing.T, root string, files map[string]string) {
	t.Helper()
	for name, content := range files {
		path := filepath.Join(root, name)
		if err := os.MkdirAll(filepath.Dir(path), 0o755); err != nil {
			t.Fatal(err)
		}
		if err := os.WriteFile(path, []byte(content), 0o644); err != nil {
			t.Fatal(err)
		}
	}
}

func exists(path string) bool {
	_, err := os.Stat(path)
	return err == nil
}

// laidName is the file a temporary file of Sync is laid as: .NAME.kvsctl,
// or .NAME.kvsctl-RANDOM when that name is taken, in the same directory.
func laidName(tmp string) (string, bool) {
	base := filepath.Base(tmp)
	cut := strings.LastIndex(base, ".kvsctl")
	if !strings.HasPrefix(base, ".") || cut < 1 {
		return "", false
	}
	return filepath.Join(filepath.Dir(tmp), base[1:cut]), true
}

func TestDownloadFlushesBeforeTheRename(t *testing.T) {
	dir := t.TempDir()
	bundle := filepath.Join(dir, "b.tar.gz")
	sha := makeBundle(t, bundle, map[string]string{"docker/setup.sh": "setup"})
	dest := filepath.Join(dir, "dl", "b.tar.gz")
	var events []string
	stubFlushes(t, func(f *os.File) error {
		if exists(dest) {
			t.Error("the bundle took its name before it was flushed")
		}
		events = append(events, "file "+f.Name())
		return nil
	}, func(d string) error {
		if !exists(dest) {
			t.Error("the directory was flushed before the bundle took its name")
		}
		events = append(events, "dir "+d)
		return nil
	})
	if err := Download(context.Background(), "file://"+bundle, sha, dest, nil); err != nil {
		t.Fatal(err)
	}
	want := []string{"file " + dest + ".part", "dir " + filepath.Dir(dest)}
	if !slices.Equal(events, want) {
		t.Errorf("flushes = %q, want %q", events, want)
	}

	// A download that does not match the manifest is not worth a flush,
	// and leaves nothing behind.
	events = nil
	other := filepath.Join(dir, "dl", "other.tar.gz")
	if err := Download(context.Background(), "file://"+bundle, strings.Repeat("0", 64), other, nil); err == nil {
		t.Fatal("a wrong checksum must be refused")
	}
	if len(events) != 0 || exists(other) || exists(other+".part") {
		t.Errorf("a refused download flushed %q and left a file: %v %v", events, exists(other), exists(other+".part"))
	}

	// A flush that fails fails the download: a bundle that may not be on
	// the disk never takes its name.
	stubFlushes(t, func(*os.File) error { return errors.New("input/output error") }, func(string) error { return nil })
	if err := Download(context.Background(), "file://"+bundle, sha, other, nil); err == nil || !strings.Contains(err.Error(), "input/output error") {
		t.Fatalf("a failed flush must fail the download, got %v", err)
	}
	if exists(other) || exists(other+".part") {
		t.Error("a download that was not flushed must leave nothing behind")
	}
}

func TestSyncFlushesEachFileBeforeItsName(t *testing.T) {
	dir := t.TempDir()
	src, root := filepath.Join(dir, "rel"), filepath.Join(dir, "root")
	shipped := map[string]string{"docker/setup.sh": "new setup", "conf/new/kvs.conf": "new conf"}
	writeTree(t, src, shipped)
	writeTree(t, root, map[string]string{"docker/setup.sh": "old setup", "docker/old/gone.sh": "gone"})
	files := []string{"conf/new/kvs.conf", "docker/setup.sh"}
	previous := []string{"docker/old/gone.sh", "docker/setup.sh"}

	var laid []string
	dirs := map[string]bool{}
	stubFlushes(t, func(f *os.File) error {
		final, ok := laidName(f.Name())
		if !ok {
			t.Errorf("%s was flushed under its own name, not before its rename", f.Name())
		}
		rel, _ := filepath.Rel(root, final)
		if got, _ := os.ReadFile(f.Name()); string(got) != shipped[rel] {
			t.Errorf("%s was flushed before it was whole: %q", rel, got)
		}
		if got, _ := os.ReadFile(final); string(got) == shipped[rel] {
			t.Errorf("%s took its name before it was flushed", rel)
		}
		laid = append(laid, rel)
		return f.Sync()
	}, func(d string) error {
		if got, _ := os.ReadFile(filepath.Join(root, "docker/setup.sh")); string(got) != "new setup" {
			t.Errorf("%s was flushed before the files took their names", d)
		}
		dirs[d] = true
		// Directory flushes are best effort: this failure must not fail
		// the sync.
		return errors.New("operation not supported")
	})
	if err := Sync(src, root, files, previous); err != nil {
		t.Fatalf("a directory that cannot be flushed must not fail the sync: %v", err)
	}
	slices.Sort(laid)
	if !slices.Equal(laid, files) {
		t.Errorf("flushed files = %v, want %v", laid, files)
	}
	for _, d := range []string{root, filepath.Join(root, "conf"), filepath.Join(root, "conf/new"), filepath.Join(root, "docker")} {
		if !dirs[d] {
			t.Errorf("%s gained or lost an entry and was not flushed", d)
		}
	}
	if dirs[filepath.Join(root, "docker/old")] {
		t.Error("a directory that was removed cannot be flushed")
	}
}

func TestSyncKeepsTheOldFileWhenAFlushFails(t *testing.T) {
	dir := t.TempDir()
	src, root := filepath.Join(dir, "rel"), filepath.Join(dir, "root")
	writeTree(t, src, map[string]string{"docker/setup.sh": "new setup"})
	writeTree(t, root, map[string]string{"docker/setup.sh": "old setup"})
	stubFlushes(t, func(*os.File) error { return errors.New("no space left on device") }, func(string) error { return nil })
	err := Sync(src, root, []string{"docker/setup.sh"}, []string{"docker/setup.sh"})
	if err == nil || !strings.Contains(err.Error(), "no space left on device") {
		t.Fatalf("a failed flush must fail the sync, got %v", err)
	}
	if got, _ := os.ReadFile(filepath.Join(root, "docker/setup.sh")); string(got) != "old setup" {
		t.Errorf("a file that was not flushed replaced the old one: %q", got)
	}
	if names, _ := os.ReadDir(filepath.Join(root, "docker")); len(names) != 1 {
		t.Errorf("a failed copy leaves no temporary file: %v", names)
	}
}

func TestSnapshotFlushesTheTreeBeforeItsName(t *testing.T) {
	dir := t.TempDir()
	root := filepath.Join(dir, "root")
	writeTree(t, root, map[string]string{"docker/setup.sh": "setup", "conf/nginx/kvs.conf": "conf"})
	dest := filepath.Join(dir, "releases", "0.1.0")
	var events []string
	stubFlushes(t, func(f *os.File) error {
		if exists(dest) {
			t.Errorf("%s was flushed after the snapshot took its name", f.Name())
		}
		events = append(events, "file")
		return nil
	}, func(d string) error {
		parent := d == filepath.Dir(dest)
		if exists(dest) != parent {
			t.Errorf("%s flushed with the snapshot in place = %v", d, exists(dest))
		}
		if parent {
			events = append(events, "parent")
		} else {
			events = append(events, "tree")
		}
		return nil
	})
	if err := Snapshot(root, dest, []string{"conf/nginx/kvs.conf", "docker/setup.sh"}); err != nil {
		t.Fatal(err)
	}
	// Two files, then the four directories of the temporary tree (its top,
	// docker, conf and conf/nginx), then the directory that holds the name.
	want := []string{"file", "file", "tree", "tree", "tree", "tree", "parent"}
	if !slices.Equal(events, want) {
		t.Errorf("flushes = %v, want %v", events, want)
	}
}

func TestExtractFlushesEveryFile(t *testing.T) {
	dir := t.TempDir()
	bundle := filepath.Join(dir, "b.tar.gz")
	makeBundle(t, bundle, map[string]string{"docker/setup.sh": "setup", "docker/lib/a.sh": "a", "conf/x.conf": "x"})
	out := filepath.Join(dir, "releases", "0.2.0")
	var flushed []string
	dirs := map[string]bool{}
	stubFlushes(t, func(f *os.File) error {
		if len(dirs) != 0 {
			t.Errorf("%s was flushed after the directories", f.Name())
		}
		rel, _ := filepath.Rel(out, f.Name())
		flushed = append(flushed, filepath.ToSlash(rel))
		return nil
	}, func(d string) error {
		dirs[d] = true
		return nil
	})
	files, err := Extract(bundle, out)
	if err != nil {
		t.Fatal(err)
	}
	slices.Sort(flushed)
	if !slices.Equal(flushed, files) {
		t.Errorf("flushed %v, want every extracted file %v", flushed, files)
	}
	for _, d := range []string{filepath.Dir(out), out, filepath.Join(out, "docker"), filepath.Join(out, "docker/lib"), filepath.Join(out, "conf")} {
		if !dirs[d] {
			t.Errorf("%s gained an entry and was not flushed", d)
		}
	}
}
