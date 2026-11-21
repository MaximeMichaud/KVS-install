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
	// Twenty thousand flushes take more than a minute on a slow disk, and
	// the cap is what this test is about.
	stubFlushes(t, func(*os.File) error { return nil }, func(string) error { return nil })
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

func TestBundlePaths(t *testing.T) {
	for _, name := range []string{
		"local.txt", "kvsctl/state.json", ".git/config", "docker-extra/file", "README.md/extra",
		"docker/.env", "docker/.env/extra", "docker/.kvs-scripts.lock",
		"docker/compose.override.yml", "docker/compose.override.yaml",
		"docker/docker-compose.override.yml", "docker/docker-compose.override.yaml",
		"docker/kvs-archive/file", "docker/data/file", "docker/nginx/ssl/file",
		"docker/nginx/dhparam.pem", "docker/nginx/conf.d/site.conf",
		"docker/multi-site/sites/site/file", "docker/multi-site/caddy/sites/site.caddy",
		"docker/import/dump", "docker/mariadb/init/01-kvs-import.sql", "docker/geoip/country.mmdb",
		"docker/geoip/country.mmdb.gz", "docker/geoip/country.tar.gz", "docker/geoip/.GeoLite2-Country.download.fixture",
	} {
		t.Run(name, func(t *testing.T) {
			dir := t.TempDir()
			bundle := filepath.Join(dir, "bundle")
			sum := makeBundle(t, bundle, map[string]string{name: "fixture"})
			_, _, readErr := ReadBundle(context.Background(), "file://"+bundle, sum, 0, 0)
			_, extractErr := Extract(bundle, filepath.Join(dir, "stage"))
			for _, err := range []error{readErr, extractErr} {
				if err == nil || !strings.Contains(err.Error(), name) {
					t.Errorf("expected path refusal: %v", err)
				}
			}
		})
	}
	dir := t.TempDir()
	bundle := filepath.Join(dir, "allowed")
	files := map[string]string{"docker/RELEASE": "", "docker/docker-compose.release.yml": "", "docker/.env.example": "", "docker/nginx/conf.d/.gitignore": "", "docker/multi-site/caddy/sites/site.caddy.template": "", "conf/site": "", "README.md": ""}
	makeBundle(t, bundle, files)
	if got, err := Extract(bundle, filepath.Join(dir, "stage")); err != nil || len(got) != len(files) {
		t.Fatalf("release paths: %v, %v", got, err)
	}
}

func TestSyncChecksPreviouslyRecordedPaths(t *testing.T) {
	const local = "docker/.env"
	root, src := t.TempDir(), t.TempDir()
	writeTree(t, root, map[string]string{local: "site", "docker/setup.sh": "old"})
	writeTree(t, src, map[string]string{local: "fixture", "docker/setup.sh": "new"})
	paths := []string{"docker/setup.sh"}
	legacy := []string{"docker/setup.sh", local}
	for _, lists := range [][2][]string{{paths, legacy}, {legacy, paths}} {
		if err := Sync(src, root, lists[0], lists[1]); err == nil || !strings.Contains(err.Error(), local) {
			t.Errorf("unsafe saved file list: %v", err)
		}
		if got := content(t, filepath.Join(root, "docker/setup.sh")); got != "old" {
			t.Errorf("other file changed: %q", got)
		}
		if got := content(t, filepath.Join(root, local)); got != "site" {
			t.Errorf("instance file changed: %q", got)
		}
	}
}

func TestExtractChecksAllHeadersBeforeWriting(t *testing.T) {
	for _, name := range []string{"local.txt", `conf/guide\chapter`, `conf/bad\name/../guide`} {
		dir := t.TempDir()
		bundle := filepath.Join(dir, "bundle")
		makeTar(t, bundle, file("README.md", 0644, "new"), file(name, 0644, "local"))
		f, err := os.Open(bundle)
		if err != nil {
			t.Fatal(err)
		}
		_, _, err = listBundle(f, nil, 0)
		f.Close()
		if err == nil {
			t.Fatalf("accepted %q when planning", name)
		}
		dest := t.TempDir()
		writeTree(t, dest, map[string]string{"README.md": "keep"})
		if _, err := Extract(bundle, dest); err == nil {
			t.Fatalf("accepted %q when extracting", name)
		}
		if got := content(t, filepath.Join(dest, "README.md")); got != "keep" {
			t.Fatalf("the first entry replaced existing content: %q", got)
		}
	}
}

func TestBundleConflictingTypes(t *testing.T) {
	f := file("conf/site", 0o644, "policy")
	child := file("conf/site/local/settings", 0o644, "settings")
	d := tarEntry{hdr: tar.Header{Name: "conf/site/", Typeflag: tar.TypeDir}}
	for _, tc := range []struct {
		name          string
		first, second tarEntry
	}{
		{"file then child", f, child}, {"child then file", child, f},
		{"file then directory", f, d}, {"directory then file", d, f},
	} {
		t.Run(tc.name, func(t *testing.T) {
			root := t.TempDir()
			bundle, stage := filepath.Join(root, "bundle"), filepath.Join(root, "stage")
			makeTar(t, bundle, file("README.md", 0o644, "first"), tc.first, tc.second)
			data, err := os.ReadFile(bundle)
			if err != nil {
				t.Fatal(err)
			}
			sum := fmt.Sprintf("%x", sha256.Sum256(data))
			_, _, readErr := ReadBundle(context.Background(), "file://"+bundle, sum, 0, 0)
			_, extractErr := Extract(bundle, stage)
			for _, err := range []error{readErr, extractErr} {
				if err == nil || !strings.Contains(err.Error(), "conf/site") {
					t.Errorf("expected conflicting path in error, got %v", err)
				}
			}
			if _, err := os.Lstat(stage); !errors.Is(err, os.ErrNotExist) {
				t.Errorf("staging began before validation: %v", err)
			}
		})
	}
}

func TestNewReleaseFileConflictsWithLocalFile(t *testing.T) {
	const policy = "docker/php/media-security-policy.xml"
	root, stage := t.TempDir(), t.TempDir()
	files, previous := []string{"README.md", policy}, []string{"README.md", "LICENSE"}
	writeTree(t, root, map[string]string{"README.md": "installed", "LICENSE": "installed"})
	writeTree(t, stage, map[string]string{"README.md": "replacement", policy: "release policy"})
	if problems := Conflicts(root, files, previous); len(problems) != 0 {
		t.Fatal(problems)
	}
	writeTree(t, root, map[string]string{policy: "local policy"})
	if problems := Conflicts(root, files, previous); len(problems) != 1 || !strings.Contains(problems[0], policy) {
		t.Errorf("plan missed local file: %v", problems)
	}
	var conflict *ConflictError
	if err := Sync(stage, root, files, previous); !errors.As(err, &conflict) || !strings.Contains(err.Error(), policy) {
		t.Errorf("sync missed local file: %v", err)
	}
	for name, want := range map[string]string{policy: "local policy", "README.md": "installed", "LICENSE": "installed"} {
		if got := content(t, filepath.Join(root, name)); got != want {
			t.Errorf("%s changed to %q", name, got)
		}
	}
}
