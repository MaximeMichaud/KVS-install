package release

import (
	"archive/tar"
	"compress/gzip"
	"context"
	"crypto/sha256"
	"encoding/hex"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func makeBundle(t *testing.T, path string, files map[string]string) string {
	t.Helper()
	f, err := os.Create(path)
	if err != nil {
		t.Fatal(err)
	}
	gz := gzip.NewWriter(f)
	tw := tar.NewWriter(gz)
	for name, content := range files {
		if err := tw.WriteHeader(&tar.Header{Name: name, Mode: 0o755, Size: int64(len(content)), Typeflag: tar.TypeReg}); err != nil {
			t.Fatal(err)
		}
		if _, err := tw.Write([]byte(content)); err != nil {
			t.Fatal(err)
		}
	}
	tw.Close()
	gz.Close()
	f.Close()
	data, _ := os.ReadFile(path)
	sum := sha256.Sum256(data)
	return hex.EncodeToString(sum[:])
}

func TestDownloadExtractSync(t *testing.T) {
	dir := t.TempDir()
	bundle := filepath.Join(dir, "b.tar.gz")
	sha := makeBundle(t, bundle, map[string]string{"docker/setup.sh": "new setup", "docker/lib/new.sh": "added"})
	dest := filepath.Join(dir, "dl", "b.tar.gz")
	ctx := context.Background()
	if err := Download(ctx, "file://"+bundle, "0000000000000000000000000000000000000000000000000000000000000000", dest, nil); err == nil {
		t.Fatal("a wrong checksum must be refused")
	}
	var seen int64
	if err := Download(ctx, "file://"+bundle, sha, dest, func(n int64) { seen = n }); err != nil {
		t.Fatal(err)
	}
	cancelled, cancel := context.WithCancel(ctx)
	cancel()
	if err := Download(cancelled, "file://"+bundle, sha, dest, nil); !errors.Is(err, context.Canceled) {
		t.Errorf("a cancelled download must stop at once, got %v", err)
	}
	if seen == 0 {
		t.Error("progress was not reported")
	}
	files, err := Extract(dest, filepath.Join(dir, "rel"))
	if err != nil {
		t.Fatal(err)
	}
	if len(files) != 2 || files[0] != "docker/lib/new.sh" {
		t.Errorf("files = %v", files)
	}
	root := filepath.Join(dir, "root")
	if err := os.MkdirAll(filepath.Join(root, "docker", "old"), 0o755); err != nil {
		t.Fatal(err)
	}
	os.WriteFile(filepath.Join(root, "docker", "setup.sh"), []byte("old setup"), 0o755)
	os.WriteFile(filepath.Join(root, "docker", "old", "gone.sh"), []byte("gone"), 0o644)
	os.WriteFile(filepath.Join(root, "docker", ".env"), []byte("DOMAIN=x\n"), 0o600)
	previous := []string{"docker/setup.sh", "docker/old/gone.sh"}
	if err := Snapshot(root, filepath.Join(dir, "snap"), previous); err != nil {
		t.Fatal(err)
	}
	if err := Sync(filepath.Join(dir, "rel"), root, files, previous); err != nil {
		t.Fatal(err)
	}
	got, _ := os.ReadFile(filepath.Join(root, "docker", "setup.sh"))
	if string(got) != "new setup" {
		t.Errorf("setup.sh = %q", got)
	}
	if _, err := os.Stat(filepath.Join(root, "docker", "old")); !os.IsNotExist(err) {
		t.Error("a file the new release no longer ships must go, with its empty directory")
	}
	if _, err := os.Stat(filepath.Join(root, "docker", ".env")); err != nil {
		t.Error("instance data must survive a sync")
	}
	if err := Sync(filepath.Join(dir, "snap"), root, previous, files); err != nil {
		t.Fatal(err)
	}
	got, _ = os.ReadFile(filepath.Join(root, "docker", "setup.sh"))
	if string(got) != "old setup" {
		t.Errorf("rollback left setup.sh = %q", got)
	}
	if _, err := os.Stat(filepath.Join(root, "docker", "lib")); !os.IsNotExist(err) {
		t.Error("a rollback removes the files the newer release added")
	}
	evil := filepath.Join(dir, "evil.tar.gz")
	makeBundle(t, evil, map[string]string{"../escape.sh": "x"})
	if _, err := Extract(evil, filepath.Join(dir, "evil")); err == nil {
		t.Error("a path leaving the bundle must be refused")
	}
}

func TestExtractRefusesTooManyEntries(t *testing.T) {
	dir := t.TempDir()
	files := make(map[string]string, maxEntries+1)
	for n := 0; n <= maxEntries; n++ {
		files[fmt.Sprintf("docker/f%05d", n)] = "x"
	}
	bundle := filepath.Join(dir, "many.tar.gz")
	makeBundle(t, bundle, files)
	_, err := Extract(bundle, filepath.Join(dir, "out"))
	if err == nil || !strings.Contains(err.Error(), "more than") {
		t.Fatalf("a bundle over the entry cap must be refused, got %v", err)
	}
}

func TestSnapshotIsAtomic(t *testing.T) {
	dir := t.TempDir()
	root := filepath.Join(dir, "root")
	files := []string{"docker/setup.sh", "conf/nginx/kvs.conf"}
	for _, f := range files {
		path := filepath.Join(root, f)
		if err := os.MkdirAll(filepath.Dir(path), 0o755); err != nil {
			t.Fatal(err)
		}
		if err := os.WriteFile(path, []byte("content of "+f), 0o644); err != nil {
			t.Fatal(err)
		}
	}
	dest := filepath.Join(dir, "releases", "0.1.0")
	if err := Snapshot(root, dest, files); err != nil {
		t.Fatal(err)
	}
	for _, f := range files {
		got, err := os.ReadFile(filepath.Join(dest, f))
		if err != nil || string(got) != "content of "+f {
			t.Errorf("%s in the snapshot: %q %v", f, got, err)
		}
	}
	siblings, err := os.ReadDir(filepath.Join(dir, "releases"))
	if err != nil {
		t.Fatal(err)
	}
	if len(siblings) != 1 || siblings[0].Name() != "0.1.0" {
		t.Errorf("a finished snapshot leaves nothing beside it: %v", siblings)
	}
	// A snapshot that cannot read one of its files leaves the previous one
	// in place instead of a half tree.
	if err := Snapshot(root, dest, append(files, "docker/gone.sh")); err == nil {
		t.Fatal("a missing file must fail the snapshot")
	}
	if _, err := os.Stat(filepath.Join(dest, "docker/setup.sh")); err != nil {
		t.Errorf("the snapshot of the running version must survive a failed one: %v", err)
	}
	siblings, err = os.ReadDir(filepath.Join(dir, "releases"))
	if err != nil {
		t.Fatal(err)
	}
	if len(siblings) != 1 {
		t.Errorf("a failed snapshot leaves no temporary directory: %v", siblings)
	}
}

func TestChecksumsAndVerify(t *testing.T) {
	root := t.TempDir()
	files := []string{"docker/setup.sh", "docker/php/php.ini"}
	for _, f := range files {
		path := filepath.Join(root, f)
		if err := os.MkdirAll(filepath.Dir(path), 0o755); err != nil {
			t.Fatal(err)
		}
		if err := os.WriteFile(path, []byte("as the release ships it"), 0o644); err != nil {
			t.Fatal(err)
		}
	}
	sums, err := Checksums(root, files)
	if err != nil {
		t.Fatal(err)
	}
	if len(sums) != 2 || len(sums[files[0]]) != 64 {
		t.Fatalf("checksums = %v", sums)
	}
	changed, err := Verify(root, sums)
	if err != nil || len(changed) != 0 {
		t.Fatalf("untouched files: %v %v", changed, err)
	}
	if err := os.WriteFile(filepath.Join(root, files[1]), []byte("edited on the machine"), 0o644); err != nil {
		t.Fatal(err)
	}
	if err := os.Remove(filepath.Join(root, files[0])); err != nil {
		t.Fatal(err)
	}
	changed, err = Verify(root, sums)
	if err != nil {
		t.Fatal(err)
	}
	if len(changed) != 2 || changed[0] != "docker/php/php.ini" || changed[1] != "docker/setup.sh" {
		t.Errorf("changed = %v, want the edited and the missing one, sorted", changed)
	}
	if _, err := Checksums(root, files); err == nil {
		t.Error("a missing release file must fail the checksums")
	}
}
