package backup

import (
	"archive/tar"
	"bytes"
	"context"
	"io"
	"math/rand"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/klauspost/compress/zstd"
)

// stubExec replaces the docker exec for one test.
func stubExec(t *testing.T, fn func(ctx context.Context, name string, stdin io.Reader, stdout io.Writer, args ...string) error) {
	t.Helper()
	previous := execFn
	execFn = fn
	t.Cleanup(func() { execFn = previous })
}

func writeEnv(t *testing.T, dir string) string {
	t.Helper()
	path := filepath.Join(dir, ".env")
	if err := os.WriteFile(path, []byte("DOMAIN=example.test\nMARIADB_ROOT_PASSWORD=secret\n"), 0o600); err != nil {
		t.Fatal(err)
	}
	return path
}

// TestCreateStreamsTheDump writes a 64 MiB dump through the stub and
// checks that it went to a temporary file next to the archive instead of
// a buffer, that the archive holds the compressed member with the size
// the metadata announces, and that nothing is left behind.
func TestCreateStreamsTheDump(t *testing.T) {
	dir := t.TempDir()
	env := writeEnv(t, dir)
	state := filepath.Join(dir, "state.json")
	if err := os.WriteFile(state, []byte(`{"current":"0.2.0"}`), 0o600); err != nil {
		t.Fatal(err)
	}
	const dumpSize = 64 << 20
	block := make([]byte, 64<<10)
	rand.New(rand.NewSource(1)).Read(block)
	sawTempFile := false
	stubExec(t, func(ctx context.Context, name string, stdin io.Reader, stdout io.Writer, args ...string) error {
		for written := 0; written < dumpSize; written += len(block) {
			if _, err := stdout.Write(block); err != nil {
				return err
			}
			if !sawTempFile {
				parts, _ := filepath.Glob(filepath.Join(dir, "*.dump.part"))
				sawTempFile = len(parts) == 1
			}
		}
		return nil
	})
	result, err := Create(context.Background(), dir, "0.2.0", "kvs-mariadb", env, state, nil)
	if err != nil {
		t.Fatal(err)
	}
	if !sawTempFile {
		t.Fatal("the dump was not streamed into a temporary file next to the archive")
	}
	if !strings.HasSuffix(result.Path, ".tar") {
		t.Fatalf("archive is %s, wanted a plain tar", result.Path)
	}
	leftovers, _ := filepath.Glob(filepath.Join(dir, "*.part"))
	if len(leftovers) != 0 {
		t.Fatalf("left behind: %v", leftovers)
	}
	meta, members, err := Describe(result.Path)
	if err != nil {
		t.Fatal(err)
	}
	if meta == nil {
		t.Fatal("the archive carries no backup.json")
	}
	if meta.Format != Format || meta.Version != "0.2.0" || meta.Domain != "example.test" {
		t.Fatalf("metadata is %+v", meta)
	}
	if meta.DumpBytes != dumpSize {
		t.Fatalf("dump is %d bytes, wanted %d", meta.DumpBytes, dumpSize)
	}
	if meta.Tool != "unknown" {
		t.Fatalf("tool is %q", meta.Tool)
	}
	if meta.Date.IsZero() || time.Since(meta.Date) > time.Hour {
		t.Fatalf("date is %s", meta.Date)
	}
	want := []string{metaName, ".env", "state.json", dumpName}
	if strings.Join(members, ",") != strings.Join(want, ",") {
		t.Fatalf("members are %v, wanted %v", members, want)
	}
	size, raw := memberSize(t, result.Path, dumpName)
	if size != meta.CompressedBytes {
		t.Fatalf("%s is %d bytes, metadata says %d", dumpName, size, meta.CompressedBytes)
	}
	if raw != dumpSize {
		t.Fatalf("%s decompresses to %d bytes, wanted %d", dumpName, raw, dumpSize)
	}
}

// memberSize returns the size of a member and, for the compressed dump,
// how many bytes it holds once decompressed.
func memberSize(t *testing.T, path, member string) (int64, int64) {
	t.Helper()
	f, err := os.Open(path)
	if err != nil {
		t.Fatal(err)
	}
	defer f.Close()
	tr, closer, err := openArchive(f)
	if err != nil {
		t.Fatal(err)
	}
	defer closer()
	for {
		hdr, err := tr.Next()
		if err != nil {
			t.Fatalf("%s holds no %s: %v", path, member, err)
		}
		if hdr.Name != member {
			continue
		}
		zr, err := zstd.NewReader(tr)
		if err != nil {
			t.Fatal(err)
		}
		defer zr.Close()
		raw, err := io.Copy(io.Discard, zr)
		if err != nil {
			t.Fatal(err)
		}
		return hdr.Size, raw
	}
}

func TestCreateRefusesAnEmptyDump(t *testing.T) {
	dir := t.TempDir()
	stubExec(t, func(ctx context.Context, name string, stdin io.Reader, stdout io.Writer, args ...string) error {
		return nil
	})
	if _, err := Create(context.Background(), dir, "0.2.0", "kvs-mariadb", writeEnv(t, dir), "", nil); err == nil {
		t.Fatal("an empty dump was accepted")
	}
	leftovers, _ := filepath.Glob(filepath.Join(dir, "*.part"))
	if len(leftovers) != 0 {
		t.Fatalf("left behind: %v", leftovers)
	}
}

func TestRestoreDatabaseBothFormats(t *testing.T) {
	dir := t.TempDir()
	const sql = "CREATE TABLE t (id INT);\n"
	stubExec(t, func(ctx context.Context, name string, stdin io.Reader, stdout io.Writer, args ...string) error {
		_, err := stdout.Write([]byte(sql))
		return err
	})
	result, err := Create(context.Background(), dir, "0.2.0", "kvs-mariadb", writeEnv(t, dir), "", nil)
	if err != nil {
		t.Fatal(err)
	}
	legacy := writeLegacyArchive(t, dir, sql)
	for _, path := range []string{result.Path, legacy} {
		var replayed bytes.Buffer
		stubExec(t, func(ctx context.Context, name string, stdin io.Reader, stdout io.Writer, args ...string) error {
			_, err := io.Copy(&replayed, stdin)
			return err
		})
		if err := RestoreDatabase(context.Background(), path, "kvs-mariadb"); err != nil {
			t.Fatalf("%s: %v", path, err)
		}
		if replayed.String() != sql {
			t.Fatalf("%s replayed %q", path, replayed.String())
		}
	}
}

// writeLegacyArchive builds the proof-of-concept format: a .tar.zst with
// a plain database.sql.
func writeLegacyArchive(t *testing.T, dir, sql string) string {
	t.Helper()
	path := filepath.Join(dir, "backup-0.1.0-20260101-101010.tar.zst")
	f, err := os.Create(path)
	if err != nil {
		t.Fatal(err)
	}
	defer f.Close()
	zw, err := zstd.NewWriter(f)
	if err != nil {
		t.Fatal(err)
	}
	tw := tar.NewWriter(zw)
	if err := addBytes(tw, legacyDump, []byte(sql), time.Now()); err != nil {
		t.Fatal(err)
	}
	if err := tw.Close(); err != nil {
		t.Fatal(err)
	}
	if err := zw.Close(); err != nil {
		t.Fatal(err)
	}
	return path
}

func TestRestoreEnv(t *testing.T) {
	dir := t.TempDir()
	env := writeEnv(t, dir)
	stubExec(t, func(ctx context.Context, name string, stdin io.Reader, stdout io.Writer, args ...string) error {
		_, err := stdout.Write([]byte("SELECT 1;\n"))
		return err
	})
	result, err := Create(context.Background(), dir, "0.2.0", "kvs-mariadb", env, "", nil)
	if err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(env, []byte("DOMAIN=broken.test\n"), 0o640); err != nil {
		t.Fatal(err)
	}
	if err := os.Chmod(env, 0o640); err != nil {
		t.Fatal(err)
	}
	if err := RestoreEnv(context.Background(), result.Path, env); err != nil {
		t.Fatal(err)
	}
	data, err := os.ReadFile(env)
	if err != nil {
		t.Fatal(err)
	}
	if !strings.Contains(string(data), "DOMAIN=example.test") {
		t.Fatalf(".env is %q", string(data))
	}
	info, err := os.Stat(env)
	if err != nil {
		t.Fatal(err)
	}
	if info.Mode().Perm() != 0o640 {
		t.Fatalf("mode is %v, wanted 0640", info.Mode().Perm())
	}
}

func TestListLatestAndPrune(t *testing.T) {
	dir := t.TempDir()
	names := []string{
		"backup-0.1.0-20260101-101010.tar.zst",
		"backup-0.2.0-20260201-101010.tar",
		"backup-0.2.0-20260301-101010.tar",
		"backup-unknown-20260401-101010.tar",
		"notes.txt",
		"backup-0.2.0-20260501-101010.tar.part",
	}
	for _, name := range names {
		if err := os.WriteFile(filepath.Join(dir, name), []byte("x"), 0o600); err != nil {
			t.Fatal(err)
		}
	}
	list, err := List(dir)
	if err != nil {
		t.Fatal(err)
	}
	if len(list) != 4 {
		t.Fatalf("listed %d backups: %+v", len(list), list)
	}
	if list[0].Name != "backup-unknown-20260401-101010.tar" || list[0].Version != "unknown" {
		t.Fatalf("newest is %+v", list[0])
	}
	if !list[3].Legacy || list[3].Version != "0.1.0" {
		t.Fatalf("oldest is %+v", list[3])
	}
	if want := time.Date(2026, 4, 1, 10, 10, 10, 0, time.UTC); !list[0].Date.Equal(want) {
		t.Fatalf("date is %s, wanted %s", list[0].Date, want)
	}
	latest, err := Latest(dir, "0.2.0")
	if err != nil {
		t.Fatal(err)
	}
	if filepath.Base(latest) != "backup-0.2.0-20260301-101010.tar" {
		t.Fatalf("latest 0.2.0 is %s", latest)
	}
	if missing, err := Latest(dir, "9.9.9"); err != nil || missing != "" {
		t.Fatalf("Latest of an unknown version is %q, %v", missing, err)
	}
	keep := filepath.Join(dir, "backup-0.1.0-20260101-101010.tar.zst")
	removed, err := Prune(dir, 1, keep)
	if err != nil {
		t.Fatal(err)
	}
	if len(removed) != 3 {
		t.Fatalf("removed %v", removed)
	}
	left, err := List(dir)
	if err != nil {
		t.Fatal(err)
	}
	if len(left) != 2 || left[1].Path != keep {
		t.Fatalf("kept %+v", left)
	}
	if _, err := os.Stat(filepath.Join(dir, "notes.txt")); err != nil {
		t.Fatal("a foreign file was removed")
	}
	if parts, _ := filepath.Glob(filepath.Join(dir, "*.part")); len(parts) != 0 {
		t.Fatalf("stale parts left: %v", parts)
	}
}
