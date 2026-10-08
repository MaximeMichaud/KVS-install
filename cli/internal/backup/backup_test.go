package backup

import (
	"archive/tar"
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"math/rand"
	"os"
	"path/filepath"
	"regexp"
	"slices"
	"strings"
	"sync"
	"sync/atomic"
	"testing"
	"time"

	"github.com/klauspost/compress/zstd"

	"github.com/MaximeMichaud/KVS-install/cli/internal/diskspace"
)

// stubExec replaces the docker exec for one test.
func stubExec(t *testing.T, fn func(ctx context.Context, name string, stdin io.Reader, stdout io.Writer, args ...string) error) {
	t.Helper()
	previous := execFn
	execFn = fn
	t.Cleanup(func() { execFn = previous })
}

// server stands for the MariaDB container: it answers each command a
// backup or a replay runs there, told apart by its script, and fails the
// test on any other.
type server struct {
	// engines is the answer to enginesScript; empty means "0<TAB>": every
	// table takes part in transactions.
	engines string
	// dump writes the dump of a backup; script is the dump command.
	dump func(ctx context.Context, script string, stdout io.Writer) error
	// replay takes the input of a replay.
	replay func(ctx context.Context, stdin io.Reader) error
	// probe answers the question about the connection of a replay, which
	// holds lock.
	probe func(ctx context.Context, lock string) (string, error)
	// end ends the connection of a replay that was stopped, which holds
	// lock; nil ends it without a word.
	end func(ctx context.Context, lock string) error
}

// stubServer makes s the MariaDB container of one test.
func stubServer(t *testing.T, s *server) {
	t.Helper()
	stubExec(t, func(ctx context.Context, name string, stdin io.Reader, stdout io.Writer, args ...string) error {
		if name == "kvs-mariadb" && len(args) >= 3 && args[0] == "sh" && args[1] == "-c" {
			switch script := args[2]; {
			case script == enginesScript && len(args) == 3:
				answer := s.engines
				if answer == "" {
					answer = "0\t\n"
				}
				_, err := io.WriteString(stdout, answer)
				return err
			case (script == dumpScript || script == lockedDumpScript) && len(args) == 3 && s.dump != nil:
				return s.dump(ctx, script, stdout)
			case script == restoreScript && len(args) == 3 && s.replay != nil:
				return s.replay(ctx, stdin)
			case script == probeScript && len(args) == 5 && args[3] == "sh" && s.probe != nil:
				answer, err := s.probe(ctx, args[4])
				if err != nil {
					return err
				}
				_, err = io.WriteString(stdout, answer)
				return err
			case script == endScript && len(args) == 5 && args[3] == "sh":
				if s.end == nil {
					return nil
				}
				return s.end(ctx, args[4])
			}
		}
		t.Errorf("ran %s %q", name, args)
		return errors.New("not a command of this test")
	})
}

// dumpOf is a server whose dump is sql, and nothing else.
func dumpOf(sql string) *server {
	return &server{dump: func(ctx context.Context, script string, stdout io.Writer) error {
		_, err := io.WriteString(stdout, sql)
		return err
	}}
}

// preambleEnd ends replayPreamble: what a replay reads before the dump.
const preambleEnd = "SET FOREIGN_KEY_CHECKS = @kvsctl_foreign_key_checks;\n"

// readPreamble reads the preamble of a replay from its input, one byte at a
// time so that nothing of the dump is read with it, checks it, and returns
// the name of the lock it takes.
func readPreamble(stdin io.Reader) (string, error) {
	var got []byte
	one := make([]byte, 1)
	for !bytes.HasSuffix(got, []byte(preambleEnd)) {
		if _, err := io.ReadFull(stdin, one); err != nil {
			return "", fmt.Errorf("the replay ended in its preamble, after %q: %w", got, err)
		}
		got = append(got, one[0])
	}
	m := regexp.MustCompile(`^DO GET_LOCK\('(kvsctl-replay-[0-9]+-[0-9]+)', 0\);\n`).FindSubmatch(got)
	if m == nil {
		return "", fmt.Errorf("the replay does not start with its lock: %q", got)
	}
	if want := fmt.Sprintf(replayPreamble, m[1]); string(got) != want {
		return "", fmt.Errorf("the preamble of the replay is\n%s\nwant\n%s", got, want)
	}
	return string(m[1]), nil
}

// guarded is the context of a replay the watchdog must stop: should it never
// fire, the replay ends after a while all the same, and the test fails on
// the error it gets instead of hanging.
func guarded(t *testing.T) context.Context {
	ctx, cancel := context.WithTimeout(context.Background(), 20*time.Second)
	t.Cleanup(cancel)
	return ctx
}

// setVar changes one of the bounds of the package for one test.
func setVar[T any](t *testing.T, v *T, value T) {
	t.Helper()
	previous := *v
	*v = value
	t.Cleanup(func() { *v = previous })
}

// plentyOfSpace stands for a filesystem far from full, so a test does not
// depend on the disk it runs on.
func plentyOfSpace(t *testing.T) {
	setVar(t, &measureSpace, func(string) (diskspace.Space, error) {
		return diskspace.Space{Avail: 1 << 40, Size: 2 << 40}, nil
	})
}

func writeEnv(t *testing.T, dir string) string {
	t.Helper()
	path := filepath.Join(dir, ".env")
	if err := os.WriteFile(path, []byte("DOMAIN=example.test\nMARIADB_ROOT_PASSWORD=secret\n"), 0o600); err != nil { // pragma: allowlist secret
		t.Fatal(err)
	}
	return path
}

// randomDump writes size bytes no compressor can shrink, so what reaches
// the archive is about what the dump wrote. Every block is new: zstd would
// find a repeated one in its window.
type randomDump struct {
	rng   *rand.Rand
	block []byte
}

func newRandomDump() *randomDump {
	return &randomDump{rng: rand.New(rand.NewSource(1)), block: make([]byte, 64<<10)}
}

// next is the next block of the dump.
func (r *randomDump) next() []byte {
	r.rng.Read(r.block)
	return r.block
}

// TestCreateStreamsTheDumpIntoTheArchive writes a 64 MiB dump through the
// stub and checks that it went into the archive itself as it streamed, with
// no other copy beside it, then that the archive holds the dump first with
// the size the metadata announces, and the other members after it.
func TestCreateStreamsTheDumpIntoTheArchive(t *testing.T) {
	plentyOfSpace(t)
	dir := t.TempDir()
	backups := filepath.Join(dir, "backups")
	env := writeEnv(t, dir)
	state := filepath.Join(dir, "state.json")
	if err := os.WriteFile(state, []byte(`{"current":"0.2.0"}`), 0o600); err != nil {
		t.Fatal(err)
	}
	const dumpSize = 64 << 20
	dump := newRandomDump()
	var midway []string
	var midwaySize int64
	stubServer(t, &server{dump: func(ctx context.Context, script string, stdout io.Writer) error {
		for written := 0; written < dumpSize; written += 64 << 10 {
			if written == dumpSize/2 {
				midway, _ = filepath.Glob(filepath.Join(backups, "*"))
				if len(midway) == 1 {
					if info, err := os.Stat(midway[0]); err == nil {
						midwaySize = info.Size()
					}
				}
			}
			if _, err := stdout.Write(dump.next()); err != nil {
				return err
			}
		}
		return nil
	}})
	result, err := Create(context.Background(), backups, "0.2.0", "kvs-mariadb", env, state, nil)
	if err != nil {
		t.Fatal(err)
	}
	if len(midway) != 1 || !strings.HasSuffix(midway[0], ".tar.part") {
		t.Fatalf("half way through the dump the directory held %v, want the archive being written and nothing else", midway)
	}
	if midwaySize < dumpSize/4 {
		t.Errorf("half way through the dump the archive was %d bytes: the dump is not streamed into it", midwaySize)
	}
	if !strings.HasSuffix(result.Path, ".tar") || filepath.Dir(result.Path) != backups {
		t.Fatalf("archive is %s", result.Path)
	}
	leftovers, _ := filepath.Glob(filepath.Join(backups, "*.part"))
	if len(leftovers) != 0 {
		t.Fatalf("left behind: %v", leftovers)
	}
	info, err := os.Stat(result.Path)
	if err != nil {
		t.Fatal(err)
	}
	if info.Mode().Perm() != 0o600 || info.Size() != result.Size {
		t.Errorf("archive mode %v, size %d (result says %d)", info.Mode().Perm(), info.Size(), result.Size)
	}
	meta, members, err := Describe(result.Path)
	if err != nil {
		t.Fatal(err)
	}
	if meta.Format != Format || meta.Version != "0.2.0" || meta.Domain != "example.test" || meta.Tool != "unknown" {
		t.Fatalf("metadata is %+v", meta)
	}
	if meta.DumpBytes != dumpSize {
		t.Fatalf("dump is %d bytes, wanted %d", meta.DumpBytes, dumpSize)
	}
	if meta.Date.IsZero() || time.Since(meta.Date) > time.Hour {
		t.Fatalf("date is %s", meta.Date)
	}
	want := []string{dumpName, ".env", "state.json", metaName}
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
	// Any tar reader reads the archive, not only this package.
	f, err := os.Open(result.Path)
	if err != nil {
		t.Fatal(err)
	}
	defer f.Close()
	tr := tar.NewReader(f)
	first, err := tr.Next()
	if err != nil || first.Name != dumpName || first.Size != meta.CompressedBytes || first.Format != tar.FormatGNU {
		t.Fatalf("the first header is %+v, %v", first, err)
	}
}

// memberSize returns the size of a member and, for the compressed dump,
// how many bytes it holds once decompressed.
func memberSize(t *testing.T, path, name string) (int64, int64) {
	t.Helper()
	a, err := openArchive(path)
	if err != nil {
		t.Fatal(err)
	}
	defer a.Close()
	section, err := a.section(name)
	if err != nil {
		t.Fatal(err)
	}
	zr, err := zstd.NewReader(section)
	if err != nil {
		t.Fatal(err)
	}
	defer zr.Close()
	raw, err := io.Copy(io.Discard, zr)
	if err != nil {
		t.Fatal(err)
	}
	return section.Size(), raw
}

func TestCreateRefusesAnEmptyDump(t *testing.T) {
	plentyOfSpace(t)
	dir := t.TempDir()
	stubServer(t, dumpOf(""))
	if _, err := Create(context.Background(), dir, "0.2.0", "kvs-mariadb", writeEnv(t, dir), "", nil); err == nil {
		t.Fatal("an empty dump was accepted")
	}
	leftovers, _ := filepath.Glob(filepath.Join(dir, "*.part"))
	if len(leftovers) != 0 {
		t.Fatalf("left behind: %v", leftovers)
	}
}

// A dump that would take the filesystem below its floor stops, its partial
// archive goes, and the error says why: the database may share that disk.
func TestCreateStopsBeforeTheDiskFills(t *testing.T) {
	setVar(t, &spaceCheckEvery, 1<<20)
	dir := t.TempDir()
	backups := filepath.Join(dir, "backups")
	// The filesystem has 10 MiB above its floor of 1 GiB, minus what the
	// archive being written already took.
	setVar(t, &measureSpace, func(string) (diskspace.Space, error) {
		var used int64
		parts, _ := filepath.Glob(filepath.Join(backups, "*.part"))
		for _, p := range parts {
			if info, err := os.Stat(p); err == nil {
				used += info.Size()
			}
		}
		return diskspace.Space{Avail: 1<<30 + 10<<20 - used, Size: 10 << 30}, nil
	})
	dump := newRandomDump()
	var mu sync.Mutex
	var stoppedAt int
	var cancelled bool
	stubServer(t, &server{dump: func(ctx context.Context, script string, stdout io.Writer) error {
		for written := 0; written < 64<<20; written += 64 << 10 {
			if _, err := stdout.Write(dump.next()); err != nil {
				mu.Lock()
				stoppedAt, cancelled = written, ctx.Err() != nil
				mu.Unlock()
				return err
			}
		}
		return nil
	}})
	_, err := Create(context.Background(), backups, "0.2.0", "kvs-mariadb", writeEnv(t, dir), "", nil)
	if err == nil || !strings.Contains(err.Error(), "left on the filesystem of "+backups+", which the running database may share") {
		t.Fatalf("err = %v", err)
	}
	mu.Lock()
	defer mu.Unlock()
	if stoppedAt == 0 || stoppedAt > 16<<20 {
		t.Errorf("the dump stopped after %d bytes, want soon after the 10 MiB above the floor", stoppedAt)
	}
	if !cancelled {
		t.Error("the dump must be stopped, not only its output cut")
	}
	if left, _ := filepath.Glob(filepath.Join(backups, "*")); len(left) != 0 {
		t.Errorf("the partial archive is still there: %v", left)
	}
}

// A filesystem already below its floor gets no dump at all, and the floor
// is 2% of a large filesystem.
func TestCreateDoesNotStartBelowTheFloor(t *testing.T) {
	dir := t.TempDir()
	setVar(t, &measureSpace, func(string) (diskspace.Space, error) {
		return diskspace.Space{Avail: 15 << 30, Size: 1000 << 30}, nil
	})
	ran := false
	stubServer(t, &server{dump: func(ctx context.Context, script string, stdout io.Writer) error {
		ran = true
		return nil
	}})
	_, err := Create(context.Background(), dir, "0.2.0", "kvs-mariadb", writeEnv(t, dir), "", nil)
	if err == nil || !strings.Contains(err.Error(), "a backup stops below 21.47 GB") {
		t.Fatalf("15 GiB free of 1000 GiB is under 2%%: %v", err)
	}
	if ran {
		t.Error("the dump started below the floor")
	}
	if left, _ := filepath.Glob(filepath.Join(dir, "backup-*")); len(left) != 0 {
		t.Errorf("left behind: %v", left)
	}
}

// A filesystem that cannot be measured says nothing about the room left,
// and does not stop a backup.
func TestCreateWhenTheFilesystemCannotBeMeasured(t *testing.T) {
	dir := t.TempDir()
	setVar(t, &measureSpace, func(string) (diskspace.Space, error) {
		return diskspace.Space{}, errors.New("statfs: input/output error")
	})
	stubServer(t, dumpOf("CREATE TABLE t (id INT);\n"))
	if _, err := Create(context.Background(), dir, "0.2.0", "kvs-mariadb", writeEnv(t, dir), "", nil); err != nil {
		t.Fatal(err)
	}
}

func TestCreateReportsProgress(t *testing.T) {
	plentyOfSpace(t)
	setVar(t, &progressInterval, 0)
	dir := t.TempDir()
	dump := newRandomDump()
	stubServer(t, &server{dump: func(ctx context.Context, script string, stdout io.Writer) error {
		for i := 0; i < 16; i++ {
			if _, err := stdout.Write(dump.next()); err != nil {
				return err
			}
		}
		return nil
	}})
	var reports []string
	if _, err := Create(context.Background(), dir, "0.2.0", "kvs-mariadb", writeEnv(t, dir), "", func(msg string) { reports = append(reports, msg) }); err != nil {
		t.Fatal(err)
	}
	if len(reports) < 3 || reports[0] != "dumping the database" || !strings.HasPrefix(reports[len(reports)-1], "dumped 1 MB, 1 MB compressed") {
		t.Fatalf("reports %q", reports)
	}
	sawProgress := false
	for _, msg := range reports[1 : len(reports)-1] {
		sawProgress = sawProgress || strings.Contains(msg, " so far, ")
	}
	if !sawProgress {
		t.Errorf("no progress while the dump streamed: %q", reports)
	}
	// With the real interval a quick dump reports its start and its end.
	setVar(t, &progressInterval, 30*time.Second)
	reports = nil
	if _, err := Create(context.Background(), t.TempDir(), "0.2.0", "kvs-mariadb", writeEnv(t, dir), "", func(msg string) { reports = append(reports, msg) }); err != nil {
		t.Fatal(err)
	}
	if len(reports) != 2 {
		t.Errorf("reports %q, want the start and the end", reports)
	}
}

// A backup taken in the same second as another keeps the earlier one.
func TestFreeName(t *testing.T) {
	dir := t.TempDir()
	start := time.Date(2026, 10, 6, 12, 0, 0, 0, time.UTC)
	for _, name := range []string{"backup-0.2.0-20261006-120000.tar", "backup-0.2.0-20261006-120001.tar.part"} {
		if err := os.WriteFile(filepath.Join(dir, name), nil, 0o600); err != nil {
			t.Fatal(err)
		}
	}
	got, err := freeName(dir, "0.2.0", start)
	if err != nil || filepath.Base(got) != "backup-0.2.0-20261006-120002.tar" {
		t.Errorf("freeName = %q, %v", got, err)
	}
}

// The header of a dump of 8 GiB or more, which octal cannot write, still
// takes one block and reads back with the size it was given.
func TestDumpHeaderBeyond8GiB(t *testing.T) {
	mod := time.Date(2026, 10, 6, 12, 0, 0, 0, time.UTC)
	for _, size := range []int64{0, 511, 8<<30 - 1, 8 << 30, 9<<30 + 100, 1 << 40} {
		header, err := dumpHeader(size, mod)
		if err != nil {
			t.Fatalf("%d: %v", size, err)
		}
		if len(header) != blockSize {
			t.Fatalf("%d: the header is %d bytes", size, len(header))
		}
		hdr, err := tar.NewReader(bytes.NewReader(header)).Next()
		if err != nil {
			t.Fatalf("%d: %v", size, err)
		}
		if hdr.Name != dumpName || hdr.Size != size || !hdr.ModTime.Equal(mod) || hdr.Typeflag != tar.TypeReg {
			t.Errorf("%d: read back %+v", size, hdr)
		}
	}
}

// TestArchiveBeyond8GiB lays out an archive whose dump is 9 GiB on a
// sparse file: the dump is a hole the filesystem never writes, and the
// header goes over the placeholder the way Create does it. The members
// after the dump are then found by seeking past it.
func TestArchiveBeyond8GiB(t *testing.T) {
	dir := t.TempDir()
	path := filepath.Join(dir, "backup-0.2.0-20261006-120000.tar")
	f, err := os.OpenFile(path, os.O_CREATE|os.O_EXCL|os.O_WRONLY, 0o600)
	if err != nil {
		t.Fatal(err)
	}
	defer f.Close()
	start := time.Date(2026, 10, 6, 12, 0, 0, 0, time.UTC)
	placeholder, err := dumpHeader(0, start)
	if err != nil {
		t.Fatal(err)
	}
	if _, err := f.Write(placeholder); err != nil {
		t.Fatal(err)
	}
	const compressed = 9<<30 + 100
	if _, err := f.Seek(compressed, io.SeekCurrent); err != nil {
		t.Fatal(err)
	}
	env := writeEnv(t, dir)
	if err := finishArchive(f, 30<<30, compressed, archiveInput{envPath: env, version: "0.2.0", start: start}); err != nil {
		t.Skipf("this filesystem does not take a sparse file of 9 GiB: %v", err)
	}
	if err := f.Close(); err != nil {
		t.Fatal(err)
	}
	meta, members, err := Describe(path)
	if err != nil {
		t.Fatal(err)
	}
	if strings.Join(members, ",") != dumpName+",.env,"+metaName {
		t.Errorf("members %v", members)
	}
	if meta.CompressedBytes != compressed || meta.DumpBytes != 30<<30 {
		t.Errorf("metadata %+v", meta)
	}
	a, err := openArchive(path)
	if err != nil {
		t.Fatal(err)
	}
	defer a.Close()
	if m := a.members[dumpName]; m.offset != blockSize || m.size != compressed {
		t.Errorf("the dump is at %d for %d bytes", m.offset, m.size)
	}
	// The dump is padded to a block, then the header of .env follows.
	if m := a.members[".env"]; m.offset != blockSize+compressed+412+blockSize {
		t.Errorf(".env starts at %d", m.offset)
	}
	data, err := ArchivedEnv(path)
	if err != nil || !strings.Contains(string(data), "DOMAIN=example.test") {
		t.Errorf("the .env behind the dump reads %q, %v", data, err)
	}
}

func TestRestoreDatabaseReportsProgress(t *testing.T) {
	plentyOfSpace(t)
	dir := t.TempDir()
	sql := strings.Repeat("INSERT INTO t VALUES (1);\n", 4096)
	s := dumpOf(sql)
	stubServer(t, s)
	result, err := Create(context.Background(), dir, "0.2.0", "kvs-mariadb", writeEnv(t, dir), "", nil)
	if err != nil {
		t.Fatal(err)
	}
	var replayed bytes.Buffer
	s.replay = func(ctx context.Context, stdin io.Reader) error {
		if _, err := readPreamble(stdin); err != nil {
			return err
		}
		_, err := io.Copy(&replayed, stdin)
		return err
	}
	setVar(t, &progressInterval, 0)
	var mu sync.Mutex
	var reports [][2]int64
	err = RestoreDatabase(context.Background(), result.Path, "kvs-mariadb", func(done, total int64) {
		mu.Lock()
		defer mu.Unlock()
		reports = append(reports, [2]int64{done, total})
	})
	if err != nil {
		t.Fatal(err)
	}
	if replayed.String() != sql {
		t.Fatalf("replayed %d bytes, want the %d of the dump", replayed.Len(), len(sql))
	}
	mu.Lock()
	defer mu.Unlock()
	if len(reports) == 0 {
		t.Fatal("no progress was reported")
	}
	last := reports[len(reports)-1]
	if last[0] != int64(len(sql)) || last[1] != int64(len(sql)) {
		t.Errorf("the last report is %v, want the whole dump of %d bytes", last, len(sql))
	}
	for i := 1; i < len(reports); i++ {
		if reports[i][0] < reports[i-1][0] {
			t.Errorf("progress went back: %v", reports)
		}
	}
	// Without a callback the replay is the same.
	replayed.Reset()
	if err := RestoreDatabase(context.Background(), result.Path, "kvs-mariadb", nil); err != nil || replayed.String() != sql {
		t.Errorf("without progress: %v, %d bytes", err, replayed.Len())
	}
}

// createSQL takes a backup whose dump is sql.
func createSQL(t *testing.T, dir, sql string) string {
	t.Helper()
	plentyOfSpace(t)
	stubServer(t, dumpOf(sql))
	result, err := Create(context.Background(), dir, "0.2.0", "kvs-mariadb", writeEnv(t, dir), "", nil)
	if err != nil {
		t.Fatal(err)
	}
	return result.Path
}

// A database that stops taking the dump, its connection idle, ends the
// replay after stallTimeout, with an error that says so and what the
// server showed. The server is asked about the connection the replay
// named by its lock, and that connection is ended.
func TestRestoreDatabaseStopsWhenTheDatabaseStalls(t *testing.T) {
	path := createSQL(t, t.TempDir(), strings.Repeat("INSERT INTO t VALUES (1);\n", 1000))
	setVar(t, &stallTimeout, 300*time.Millisecond)
	var mu sync.Mutex
	var taken, asked string
	var ended []string
	stubServer(t, &server{
		replay: func(ctx context.Context, stdin io.Reader) error {
			lock, err := readPreamble(stdin)
			if err != nil {
				return err
			}
			mu.Lock()
			taken = lock
			mu.Unlock()
			if _, err := io.ReadFull(stdin, make([]byte, 10)); err != nil {
				return err
			}
			<-ctx.Done()
			return ctx.Err()
		},
		probe: func(ctx context.Context, lock string) (string, error) {
			mu.Lock()
			defer mu.Unlock()
			asked = lock
			return "Sleep\t1000.000\t\n", nil
		},
		end: func(ctx context.Context, lock string) error {
			mu.Lock()
			defer mu.Unlock()
			ended = append(ended, lock)
			return nil
		},
	})
	start := time.Now()
	err := RestoreDatabase(guarded(t), path, "kvs-mariadb", nil)
	var stalled *stallError
	if !errors.As(err, &stalled) || err.Error() != "the database took nothing from the dump for 300ms, at 10 B of 26 kB, and the connection of the replay has waited for input for 1s: the replay was stopped, the archive is intact" {
		t.Fatalf("err = %v", err)
	}
	if waited := time.Since(start); waited < stallTimeout || waited > 10*time.Second {
		t.Errorf("stopped after %s", waited)
	}
	mu.Lock()
	defer mu.Unlock()
	if taken == "" || asked != taken {
		t.Errorf("the server was asked about %q, the replay holds %q", asked, taken)
	}
	if !slices.Equal(ended, []string{taken}) {
		t.Errorf("ended the connections that hold %q, want the one of the replay, %q", ended, taken)
	}
}

// A statement that waits on the server for what the replay does not
// control, a lock another connection keeps or room on a full disk, is not
// at work: once it has waited the stall timeout the replay is stopped,
// where the server would let it wait a day or forever, and its connection
// is ended, so the statement does not run once the lock goes.
func TestRestoreDatabaseStopsAStatementThatWaits(t *testing.T) {
	path := createSQL(t, t.TempDir(), strings.Repeat("INSERT INTO t VALUES (1);\n", 1000))
	setVar(t, &stallTimeout, 200*time.Millisecond)
	for _, state := range []string{"Waiting for table metadata lock", "Waiting for someone to free space", "Waiting for table level lock", "Waiting for backup lock", "User lock"} {
		var mu sync.Mutex
		var taken string
		var began time.Time
		var ended []string
		stubServer(t, &server{
			replay: func(ctx context.Context, stdin io.Reader) error {
				lock, err := readPreamble(stdin)
				if err != nil {
					return err
				}
				// The first statement waits from the start.
				mu.Lock()
				taken, began = lock, time.Now()
				mu.Unlock()
				<-ctx.Done()
				return ctx.Err()
			},
			probe: func(ctx context.Context, lock string) (string, error) {
				mu.Lock()
				defer mu.Unlock()
				return fmt.Sprintf("Query\t%.3f\t%s\n", float64(time.Since(began).Microseconds())/1000, state), nil
			},
			end: func(ctx context.Context, lock string) error {
				mu.Lock()
				defer mu.Unlock()
				ended = append(ended, lock)
				return nil
			},
		})
		start := time.Now()
		err := RestoreDatabase(guarded(t), path, "kvs-mariadb", nil)
		want := regexp.MustCompile(`^the database took nothing from the dump for 200ms, at 0 B of 26 kB, and the server shows the statement of the replay, begun [0-9]+m?s ago, waiting \(` + regexp.QuoteMeta(state) + `\): the replay was stopped, the archive is intact$`)
		var stalled *stallError
		if !errors.As(err, &stalled) || !want.MatchString(err.Error()) {
			t.Errorf("%s: err = %v", state, err)
		}
		if waited := time.Since(start); waited > 10*time.Second {
			t.Errorf("%s: stopped after %s", state, waited)
		}
		mu.Lock()
		if taken == "" || !slices.Equal(ended, []string{taken}) {
			t.Errorf("%s: ended the connections that hold %q, want the one of the replay, %q", state, ended, taken)
		}
		mu.Unlock()
	}
}

// The server shows a statement at work, an idle connection, or a statement
// that waits for something outside the replay, by its command and state.
func TestWhatTheServerShows(t *testing.T) {
	for _, c := range []struct {
		command, state string
		working        bool
	}{
		{"Query", "Enabling keys", true},
		{"Query", "Repair by sorting", true},
		{"Query", "copy to tmp table", true},
		{"Query", "User sleep", true},
		{"Query", "", true},
		{"Query", "NULL", true},
		{"Sleep", "", false},
		{"Query", "Waiting for table metadata lock", false},
		{"Query", "Waiting for table level lock", false},
		{"Query", "Waiting for someone to free space", false},
		{"Query", "Waiting for semi-sync ACK from slave", false},
		{"Query", "User lock", false},
	} {
		if got := (sight{command: c.command, state: c.state}).working(); got != c.working {
			t.Errorf("%s %q: at work %v, want %v", c.command, c.state, got, c.working)
		}
	}
}

// A statement that began after the replay last read and waits, the server
// running what mariadb had read ahead, ended the one before it when it
// began: the stall timeout counts from there, not from the last read.
func TestRestoreDatabaseCountsAWaitFromItsStart(t *testing.T) {
	sql := strings.Repeat("INSERT INTO t VALUES (1);\n", 1000)
	path := createSQL(t, t.TempDir(), sql)
	setVar(t, &stallTimeout, time.Second)
	asked := make(chan struct{})
	var once sync.Once
	var replayed bytes.Buffer
	stubServer(t, &server{
		replay: func(ctx context.Context, stdin io.Reader) error {
			if _, err := readPreamble(stdin); err != nil {
				return err
			}
			if _, err := io.CopyN(&replayed, stdin, 100); err != nil {
				return err
			}
			// The wait goes on a moment after the server showed it, and
			// ends well before it has lasted the stall timeout.
			select {
			case <-asked:
			case <-ctx.Done():
				return ctx.Err()
			}
			select {
			case <-time.After(stallTimeout / 4):
			case <-ctx.Done():
				return ctx.Err()
			}
			_, err := io.Copy(&replayed, stdin)
			return err
		},
		probe: func(ctx context.Context, lock string) (string, error) {
			once.Do(func() { close(asked) })
			return fmt.Sprintf("Query\t%d.000\tWaiting for table metadata lock\n", (stallTimeout / 2).Milliseconds()), nil
		},
	})
	if err := RestoreDatabase(guarded(t), path, "kvs-mariadb", nil); err != nil {
		t.Fatal(err)
	}
	if replayed.String() != sql {
		t.Errorf("replayed %d bytes, want the %d of the dump", replayed.Len(), len(sql))
	}
}

// A replay that is stopped, by the watchdog or by its context, has its
// connection ended on the server, and says so when that fails; a replay
// that mariadb ended itself, on an error of the dump, has none to end.
func TestRestoreDatabaseEndsTheConnectionItStops(t *testing.T) {
	path := createSQL(t, t.TempDir(), strings.Repeat("INSERT INTO t VALUES (1);\n", 1000))
	setVar(t, &stallTimeout, 100*time.Millisecond)
	cases := []struct {
		name string
		// replay is the replay after its preamble.
		replay  func(ctx context.Context, cancel context.CancelFunc) error
		end     error
		ended   bool
		wantErr string
	}{
		{
			name:    "stalled",
			replay:  func(ctx context.Context, _ context.CancelFunc) error { <-ctx.Done(); return ctx.Err() },
			ended:   true,
			wantErr: "the database took nothing from the dump for 100ms, at 0 B of 26 kB, and the connection of the replay has waited for input for 1m0s: the replay was stopped, the archive is intact",
		},
		{
			name: "cancelled",
			replay: func(ctx context.Context, cancel context.CancelFunc) error {
				cancel()
				<-ctx.Done()
				return ctx.Err()
			},
			ended:   true,
			wantErr: "context canceled",
		},
		{
			name:    "not ended",
			replay:  func(ctx context.Context, _ context.CancelFunc) error { <-ctx.Done(); return ctx.Err() },
			end:     errors.New("docker exec kvs-mariadb: exit status 1"),
			ended:   true,
			wantErr: "the database took nothing from the dump for 100ms, at 0 B of 26 kB, and the connection of the replay has waited for input for 1m0s: the replay was stopped, the archive is intact; its connection to the database could not be ended (docker exec kvs-mariadb: exit status 1), and the server may still run its last statement: end it, or restart the MariaDB container, before the archive is replayed again",
		},
		{
			name:    "failed",
			replay:  func(context.Context, context.CancelFunc) error { return errors.New("ERROR 1064 (42000) at line 2") },
			ended:   false,
			wantErr: "ERROR 1064 (42000) at line 2",
		},
	}
	for _, c := range cases {
		ctx, cancel := context.WithTimeout(context.Background(), 20*time.Second)
		var mu sync.Mutex
		var taken string
		var ended []string
		stubServer(t, &server{
			replay: func(ctx context.Context, stdin io.Reader) error {
				lock, err := readPreamble(stdin)
				if err != nil {
					return err
				}
				mu.Lock()
				taken = lock
				mu.Unlock()
				return c.replay(ctx, cancel)
			},
			probe: func(ctx context.Context, lock string) (string, error) { return "Sleep\t60000.000\t\n", nil },
			end: func(ctx context.Context, lock string) error {
				if err := ctx.Err(); err != nil {
					return fmt.Errorf("asked with an ended context: %w", err)
				}
				mu.Lock()
				defer mu.Unlock()
				ended = append(ended, lock)
				return c.end
			},
		})
		err := RestoreDatabase(ctx, path, "kvs-mariadb", nil)
		cancel()
		if err == nil || err.Error() != c.wantErr {
			t.Errorf("%s: err = %v, want %s", c.name, err, c.wantErr)
		}
		mu.Lock()
		var want []string
		if c.ended {
			want = []string{taken}
		}
		if !slices.Equal(ended, want) {
			t.Errorf("%s: ended the connections that hold %q, want %q", c.name, ended, want)
		}
		mu.Unlock()
	}
}

// A statement that runs long, an index rebuilt on a large table, takes no
// input while it runs: the server shows it at work, and the replay waits
// for it, however long past the stall timeout.
func TestRestoreDatabaseWaitsWhileTheServerRunsAStatement(t *testing.T) {
	sql := strings.Repeat("INSERT INTO t VALUES (1);\n", 1000)
	path := createSQL(t, t.TempDir(), sql)
	setVar(t, &stallTimeout, 100*time.Millisecond)
	var running atomic.Bool
	var asked atomic.Int32
	var replayed bytes.Buffer
	stubServer(t, &server{
		replay: func(ctx context.Context, stdin io.Reader) error {
			if _, err := readPreamble(stdin); err != nil {
				return err
			}
			if _, err := io.CopyN(&replayed, stdin, 100); err != nil {
				return err
			}
			// ALTER TABLE ... ENABLE KEYS, for eight stall timeouts.
			running.Store(true)
			select {
			case <-time.After(8 * stallTimeout):
			case <-ctx.Done():
				return ctx.Err()
			}
			running.Store(false)
			_, err := io.Copy(&replayed, stdin)
			return err
		},
		probe: func(ctx context.Context, lock string) (string, error) {
			asked.Add(1)
			if running.Load() {
				return "Query\t1012.345\tEnabling keys\n", nil
			}
			return "Sleep\t0.020\t\n", nil
		},
	})
	if err := RestoreDatabase(context.Background(), path, "kvs-mariadb", nil); err != nil {
		t.Fatal(err)
	}
	if replayed.String() != sql {
		t.Errorf("replayed %d bytes, want the %d of the dump", replayed.Len(), len(sql))
	}
	if asked.Load() == 0 {
		t.Error("the server was never asked whether the replay runs")
	}
}

// When the server cannot show the replay at work, because its connection
// is gone, or it does not answer, three times in a row, the replay is a
// stall.
func TestRestoreDatabaseStallsWhenTheServerShowsNoWork(t *testing.T) {
	path := createSQL(t, t.TempDir(), strings.Repeat("INSERT INTO t VALUES (1);\n", 1000))
	setVar(t, &stallTimeout, 100*time.Millisecond)
	setVar(t, &probeTimeout, 200*time.Millisecond)
	cases := []struct {
		probe func(ctx context.Context) (string, error)
		why   string
	}{
		{func(context.Context) (string, error) { return "", nil }, "the replay has no connection to the database any more"},
		{func(context.Context) (string, error) { return "", errors.New("docker exec kvs-mariadb: exit status 1") }, "the database did not say whether the replay runs (docker exec kvs-mariadb: exit status 1)"},
		{func(ctx context.Context) (string, error) { <-ctx.Done(); return "", ctx.Err() }, "the database did not say whether the replay runs (context deadline exceeded)"},
		{func(context.Context) (string, error) { return "1048576\n", nil }, `the database answered "1048576" about the replay`},
		{func(context.Context) (string, error) { return "Sleep\tlong\t\n", nil }, `the database answered "Sleep\tlong\t" about the replay`},
	}
	for _, c := range cases {
		var asked atomic.Int32
		stubServer(t, &server{
			replay: func(ctx context.Context, stdin io.Reader) error {
				if _, err := readPreamble(stdin); err != nil {
					return err
				}
				<-ctx.Done()
				return ctx.Err()
			},
			probe: func(ctx context.Context, lock string) (string, error) {
				asked.Add(1)
				return c.probe(ctx)
			},
		})
		err := RestoreDatabase(guarded(t), path, "kvs-mariadb", nil)
		var stalled *stallError
		if !errors.As(err, &stalled) || !strings.HasSuffix(err.Error(), ", and "+c.why+": the replay was stopped, the archive is intact") {
			t.Errorf("err = %v, want the stall saying %q", err, c.why)
		}
		if n := asked.Load(); n != 3 {
			t.Errorf("%q: the server was asked %d times, want 3", c.why, n)
		}
	}
}

// A question the server does not answer, a docker exec that fails, is asked
// again: a server that shows the replay at work by the third question keeps
// it going.
func TestRestoreDatabaseAsksTheServerAgain(t *testing.T) {
	sql := strings.Repeat("INSERT INTO t VALUES (1);\n", 1000)
	path := createSQL(t, t.TempDir(), sql)
	setVar(t, &stallTimeout, 100*time.Millisecond)
	var asked atomic.Int32
	var replayed bytes.Buffer
	stubServer(t, &server{
		replay: func(ctx context.Context, stdin io.Reader) error {
			if _, err := readPreamble(stdin); err != nil {
				return err
			}
			select {
			case <-time.After(8 * stallTimeout):
			case <-ctx.Done():
				return ctx.Err()
			}
			_, err := io.Copy(&replayed, stdin)
			return err
		},
		probe: func(ctx context.Context, lock string) (string, error) {
			if asked.Add(1) <= 2 {
				return "", errors.New("docker exec kvs-mariadb: exit status 1: OCI runtime exec failed")
			}
			return "Query\t250.000\tcopy to tmp table\n", nil
		},
	})
	if err := RestoreDatabase(guarded(t), path, "kvs-mariadb", nil); err != nil {
		t.Fatal(err)
	}
	if replayed.String() != sql {
		t.Errorf("replayed %d bytes, want the %d of the dump", replayed.Len(), len(sql))
	}
	if n := asked.Load(); n < 3 {
		t.Errorf("the server was asked %d times, want 3 at least", n)
	}
}

// mariadb reads its input ahead: after a long statement it can run many
// short ones from what it holds before it reads again. The server shows
// its connection idle for a moment between two of them, which is work
// that just ended, not a stall.
func TestRestoreDatabaseCountsAStatementThatJustEnded(t *testing.T) {
	sql := strings.Repeat("INSERT INTO t VALUES (1);\n", 1000)
	path := createSQL(t, t.TempDir(), sql)
	setVar(t, &stallTimeout, 100*time.Millisecond)
	var asked atomic.Int32
	var replayed bytes.Buffer
	stubServer(t, &server{
		replay: func(ctx context.Context, stdin io.Reader) error {
			if _, err := readPreamble(stdin); err != nil {
				return err
			}
			if _, err := io.CopyN(&replayed, stdin, 100); err != nil {
				return err
			}
			select {
			case <-time.After(6 * stallTimeout):
			case <-ctx.Done():
				return ctx.Err()
			}
			_, err := io.Copy(&replayed, stdin)
			return err
		},
		probe: func(ctx context.Context, lock string) (string, error) {
			asked.Add(1)
			return "Sleep\t2.500\t\n", nil
		},
	})
	if err := RestoreDatabase(guarded(t), path, "kvs-mariadb", nil); err != nil {
		t.Fatal(err)
	}
	if replayed.String() != sql {
		t.Errorf("replayed %d bytes, want the %d of the dump", replayed.Len(), len(sql))
	}
	if asked.Load() == 0 {
		t.Error("the server was never asked whether the replay runs")
	}
}

// The replay empties the database before the dump: a dump that holds
// nothing, or that cannot be read from its start, would leave an empty
// database. Neither runs anything in the container.
func TestRestoreDatabaseRefusesADumpThatCannotStart(t *testing.T) {
	dir := t.TempDir()
	var empty bytes.Buffer
	zw, err := zstd.NewWriter(&empty)
	if err != nil {
		t.Fatal(err)
	}
	if err := zw.Close(); err != nil {
		t.Fatal(err)
	}
	meta, _ := json.Marshal(Meta{Format: Format, Version: "0.2.0"})
	cases := []struct{ name, dump, want string }{
		{"backup-0.2.0-20261007-120000.tar", empty.String(), "the dump of backup-0.2.0-20261007-120000.tar is empty: the database was not touched"},
		{"backup-0.2.0-20261007-120001.tar", "CREATE TABLE t (id INT);\n", "the dump of backup-0.2.0-20261007-120001.tar cannot be read, the database was not touched: "},
	}
	for _, c := range cases {
		path := writeTar(t, dir, c.name, [][2]string{{dumpName, c.dump}, {metaName, string(meta)}})
		stubExec(t, func(ctx context.Context, name string, stdin io.Reader, stdout io.Writer, args ...string) error {
			t.Errorf("ran %s %q", name, args)
			return errors.New("not a command of this test")
		})
		if err := RestoreDatabase(context.Background(), path, "kvs-mariadb", nil); err == nil || !strings.HasPrefix(err.Error(), c.want) {
			t.Errorf("err = %v, want %q", err, c.want)
		}
	}
}

// A replay that keeps going is never cut, however long it takes in all.
func TestRestoreDatabaseHasNoTimeLimit(t *testing.T) {
	sql := strings.Repeat("x", 40)
	path := createSQL(t, t.TempDir(), sql)
	setVar(t, &stallTimeout, 300*time.Millisecond)
	stubServer(t, &server{replay: func(ctx context.Context, stdin io.Reader) error {
		if _, err := readPreamble(stdin); err != nil {
			return err
		}
		one := make([]byte, 1)
		for {
			_, err := io.ReadFull(stdin, one)
			if errors.Is(err, io.EOF) {
				return nil
			}
			if err != nil {
				return err
			}
			time.Sleep(25 * time.Millisecond)
		}
	}})
	start := time.Now()
	if err := RestoreDatabase(context.Background(), path, "kvs-mariadb", nil); err != nil {
		t.Fatal(err)
	}
	if waited := time.Since(start); waited < 3*stallTimeout {
		t.Errorf("the replay took %s, the test wants one longer than the stall timeout", waited)
	}
}

// Once the whole dump is handed over, the server may take its time on the
// last statements: that is not a stall, and the server is not even asked.
func TestRestoreDatabaseWaitsForTheLastStatements(t *testing.T) {
	path := createSQL(t, t.TempDir(), "CREATE TABLE t (id INT);\n")
	setVar(t, &stallTimeout, 100*time.Millisecond)
	stubServer(t, &server{replay: func(ctx context.Context, stdin io.Reader) error {
		if _, err := io.Copy(io.Discard, stdin); err != nil {
			return err
		}
		select {
		case <-time.After(500 * time.Millisecond):
			return nil
		case <-ctx.Done():
			return ctx.Err()
		}
	}})
	if err := RestoreDatabase(context.Background(), path, "kvs-mariadb", nil); err != nil {
		t.Fatal(err)
	}
}

func TestRestoreDatabaseNoticesAnIncompleteReplay(t *testing.T) {
	path := createSQL(t, t.TempDir(), strings.Repeat("INSERT INTO t VALUES (1);\n", 1000))
	stubServer(t, &server{replay: func(ctx context.Context, stdin io.Reader) error {
		if _, err := readPreamble(stdin); err != nil {
			return err
		}
		_, err := io.ReadFull(stdin, make([]byte, 100))
		return err
	}})
	err := RestoreDatabase(context.Background(), path, "kvs-mariadb", nil)
	if err == nil || !strings.Contains(err.Error(), "mariadb ended at 100 B of the 26 kB dump") || !strings.Contains(err.Error(), "the replay is incomplete") {
		t.Fatalf("err = %v", err)
	}
}

// The first builds of format 2 wrote backup.json first and the dump last:
// members are found by name, so those archives read the same.
func TestReadsTheEarlierLayout(t *testing.T) {
	dir := t.TempDir()
	const sql = "CREATE TABLE t (id INT);\n"
	var dump bytes.Buffer
	zw, err := zstd.NewWriter(&dump)
	if err != nil {
		t.Fatal(err)
	}
	if _, err := zw.Write([]byte(sql)); err != nil {
		t.Fatal(err)
	}
	if err := zw.Close(); err != nil {
		t.Fatal(err)
	}
	meta, _ := json.Marshal(Meta{Format: Format, Version: "0.1.0", DumpBytes: int64(len(sql)), CompressedBytes: int64(dump.Len())})
	path := writeTar(t, dir, "backup-0.1.0-20260924-033804.tar", [][2]string{{metaName, string(meta)}, {".env", "DOMAIN=example.test\n"}, {dumpName, dump.String()}})
	var replayed bytes.Buffer
	stubServer(t, &server{replay: func(ctx context.Context, stdin io.Reader) error {
		if _, err := readPreamble(stdin); err != nil {
			return err
		}
		_, err := io.Copy(&replayed, stdin)
		return err
	}})
	if err := RestoreDatabase(context.Background(), path, "kvs-mariadb", nil); err != nil || replayed.String() != sql {
		t.Fatalf("replayed %q, %v", replayed.String(), err)
	}
	got, members, err := Describe(path)
	if err != nil || got.Version != "0.1.0" || len(members) != 3 {
		t.Errorf("Describe = %+v %v %v", got, members, err)
	}
}

// writeTar writes an archive with the members given, in that order.
func writeTar(t *testing.T, dir, name string, members [][2]string) string {
	t.Helper()
	path := filepath.Join(dir, name)
	f, err := os.Create(path)
	if err != nil {
		t.Fatal(err)
	}
	defer f.Close()
	tw := tar.NewWriter(f)
	for _, m := range members {
		if err := addBytes(tw, m[0], []byte(m[1]), time.Now()); err != nil {
			t.Fatal(err)
		}
	}
	if err := tw.Close(); err != nil {
		t.Fatal(err)
	}
	return path
}

// Only an archive this build knows is read: one without backup.json is
// not a kvsctl backup, and another format is refused, not guessed at.
func TestRefusesWhatItDoesNotKnow(t *testing.T) {
	dir := t.TempDir()
	newer, _ := json.Marshal(Meta{Format: Format + 1})
	cases := map[string][][2]string{
		"no metadata":  {{".env", "DOMAIN=example.test\n"}},
		"newer format": {{metaName, string(newer)}, {dumpName, "x"}},
		"bad metadata": {{metaName, "{not json"}},
	}
	for what, members := range cases {
		path := writeTar(t, dir, "backup-0.1.0-20260924-033804.tar", members)
		if _, _, err := Describe(path); err == nil {
			t.Errorf("%s: Describe accepted it", what)
		}
		if err := RestoreDatabase(context.Background(), path, "kvs-mariadb", nil); err == nil {
			t.Errorf("%s: RestoreDatabase accepted it", what)
		}
	}
	// A zstd stream, the proof of concept's format, is no plain tar.
	path := filepath.Join(dir, "backup-0.1.0-20260101-101010.tar")
	if err := os.WriteFile(path, []byte{0x28, 0xb5, 0x2f, 0xfd, 0, 0, 0, 0}, 0o600); err != nil {
		t.Fatal(err)
	}
	if _, _, err := Describe(path); err == nil {
		t.Error("a compressed archive was read")
	}
}

func TestRestoreEnv(t *testing.T) {
	dir := t.TempDir()
	env := writeEnv(t, dir)
	path := createSQL(t, dir, "SELECT 1;\n")
	if err := os.WriteFile(env, []byte("DOMAIN=broken.test\n"), 0o640); err != nil {
		t.Fatal(err)
	}
	if err := os.Chmod(env, 0o640); err != nil {
		t.Fatal(err)
	}
	if err := RestoreEnv(context.Background(), path, env); err != nil {
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
	if left, _ := filepath.Glob(filepath.Join(dir, "*.kvsctl.tmp")); len(left) != 0 {
		t.Errorf("left behind: %v", left)
	}
	archived, err := ArchivedEnv(path)
	if err != nil || !strings.Contains(string(archived), "DOMAIN=example.test") {
		t.Errorf("ArchivedEnv = %q, %v", archived, err)
	}
}

func TestDatabaseSize(t *testing.T) {
	stubExec(t, func(ctx context.Context, name string, stdin io.Reader, stdout io.Writer, args ...string) error {
		script := args[len(args)-1]
		if name != "kvs-mariadb" || !strings.Contains(script, "information_schema.tables") || !strings.Contains(script, "data_length + index_length") || !strings.Contains(script, `MYSQL_PWD="$MARIADB_ROOT_PASSWORD"`) {
			t.Errorf("ran %s %v", name, args)
		}
		_, err := io.WriteString(stdout, "3160000000\n")
		return err
	})
	if size, err := DatabaseSize(context.Background(), "kvs-mariadb"); err != nil || size != 3160000000 {
		t.Errorf("size %d, %v", size, err)
	}
	stubExec(t, func(ctx context.Context, name string, stdin io.Reader, stdout io.Writer, args ...string) error {
		_, err := io.WriteString(stdout, "ERROR 1045 (28000): Access denied\n")
		return err
	})
	if _, err := DatabaseSize(context.Background(), "kvs-mariadb"); err == nil {
		t.Error("an answer that is not a number was accepted")
	}
	stubExec(t, func(ctx context.Context, name string, stdin io.Reader, stdout io.Writer, args ...string) error {
		return errors.New("docker exec kvs-mariadb: exit status 1")
	})
	if _, err := DatabaseSize(context.Background(), "kvs-mariadb"); err == nil {
		t.Error("a failed query was accepted")
	}
}

func TestListLatestAndPrune(t *testing.T) {
	dir := t.TempDir()
	real := createSQL(t, dir, "SELECT 1;\n")
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
	if list[0].Path != real || list[0].Domain != "example.test" || list[0].DumpBytes != int64(len("SELECT 1;\n")) || list[0].CompressedBytes == 0 {
		t.Fatalf("newest is %+v", list[0])
	}
	if list[1].Name != "backup-unknown-20260401-101010.tar" || list[1].Version != "unknown" || list[1].Domain != "" {
		t.Fatalf("second is %+v", list[1])
	}
	if want := time.Date(2026, 4, 1, 10, 10, 10, 0, time.UTC); !list[1].Date.Equal(want) {
		t.Fatalf("date is %s, wanted %s", list[1].Date, want)
	}
	latest, err := Latest(dir, "unknown")
	if err != nil {
		t.Fatal(err)
	}
	if filepath.Base(latest) != "backup-unknown-20260401-101010.tar" {
		t.Fatalf("latest unknown is %s", latest)
	}
	if missing, err := Latest(dir, "9.9.9"); err != nil || missing != "" {
		t.Fatalf("Latest of an unknown version is %q, %v", missing, err)
	}
	keep := filepath.Join(dir, "backup-0.2.0-20260201-101010.tar")
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
	if len(left) != 2 || left[0].Path != real || left[1].Path != keep {
		t.Fatalf("kept %+v", left)
	}
	for _, other := range []string{"notes.txt", "backup-0.1.0-20260101-101010.tar.zst"} {
		if _, err := os.Stat(filepath.Join(dir, other)); err != nil {
			t.Errorf("%s is not a backup of this format and must be left alone", other)
		}
	}
	if parts, _ := filepath.Glob(filepath.Join(dir, "*.part")); len(parts) != 0 {
		t.Fatalf("stale parts left: %v", parts)
	}
}

// Every archive named is kept, however old: the one a run just took and
// the one a manual rollback of the installed version replays.
func TestPruneKeepsEveryArchiveNamed(t *testing.T) {
	dir := t.TempDir()
	names := []string{
		"backup-0.1.0-20260101-101010.tar",
		"backup-0.2.0-20260201-101010.tar",
		"backup-0.2.0-20260301-101010.tar",
		"backup-0.3.0-20260401-101010.tar",
	}
	for _, name := range names {
		if err := os.WriteFile(filepath.Join(dir, name), []byte("x"), 0o600); err != nil {
			t.Fatal(err)
		}
	}
	upgradeBackup := filepath.Join(dir, names[0])
	removed, err := Prune(dir, 1, filepath.Join(dir, names[1]), "", upgradeBackup)
	if err != nil {
		t.Fatal(err)
	}
	if len(removed) != 1 || filepath.Base(removed[0]) != names[2] {
		t.Fatalf("removed %v, want only %s", removed, names[2])
	}
	for _, name := range []string{names[0], names[1], names[3]} {
		if _, err := os.Stat(filepath.Join(dir, name)); err != nil {
			t.Errorf("%s was removed: %v", name, err)
		}
	}
}

// An archive taken while the clock was ahead is named after a later date
// than the archives taken once it is right again. The archives keep the
// order they were written in, which is what restore --latest, backup
// --keep and the archive a rollback falls back on read.
func TestArchivesKeepTheOrderTheyWereWrittenIn(t *testing.T) {
	dir := t.TempDir()
	first := createSQL(t, dir, "SELECT 1;\n")
	// The clock was two months ahead when the first one was taken.
	ahead := filepath.Join(dir, "backup-0.2.0-"+time.Now().UTC().AddDate(0, 2, 0).Format(stampLayout)+".tar")
	if err := os.Rename(first, ahead); err != nil {
		t.Fatal(err)
	}
	second := createSQL(t, dir, "SELECT 2;\n")
	list, err := List(dir)
	if err != nil {
		t.Fatal(err)
	}
	if len(list) != 2 || list[0].Path != second || list[0].Sequence != 2 || list[1].Path != ahead || list[1].Sequence != 1 {
		t.Fatalf("listed %+v, want %s (2) then %s (1)", list, filepath.Base(second), filepath.Base(ahead))
	}
	if latest, err := Latest(dir, "0.2.0"); err != nil || latest != second {
		t.Errorf("Latest = %s, %v, want %s", latest, err, second)
	}
	removed, err := Prune(dir, 1)
	if err != nil || len(removed) != 1 || removed[0] != ahead {
		t.Errorf("Prune(1) removed %v, %v, want %s", removed, err, ahead)
	}
}

// A failure once the archive has its name, a directory that cannot be
// flushed or a size that cannot be read back, is a *WrittenError that
// names the archive, which is complete and stays: no caller may take it
// for a backup that left nothing behind.
func TestCreateFailingOnceTheArchiveIsNamedKeepsIt(t *testing.T) {
	cases := []struct {
		name string
		// after runs where the directory is flushed, once the archive has
		// its name.
		after func(t *testing.T, dir string) error
		says  string
	}{
		{"the directory cannot be flushed", func(*testing.T, string) error {
			return errors.New("input/output error")
		}, " is written but its directory could not be flushed: input/output error"},
		{"the size cannot be read back", func(t *testing.T, dir string) error {
			if os.Geteuid() == 0 {
				t.Skip("root reads a directory whatever its mode")
			}
			// No search permission: the name is there, and cannot be
			// looked up.
			if err := os.Chmod(dir, 0o600); err != nil {
				t.Fatal(err)
			}
			t.Cleanup(func() { _ = os.Chmod(dir, 0o700) })
			return nil
		}, " is written but its size could not be read: "},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			plentyOfSpace(t)
			stubServer(t, dumpOf("SELECT 1;\n"))
			dir := t.TempDir()
			env := writeEnv(t, t.TempDir())
			setVar(t, &flushDir, func(dir string) error { return c.after(t, dir) })
			result, err := Create(context.Background(), dir, "0.2.0", "kvs-mariadb", env, "", nil)
			var written *WrittenError
			if result != nil || !errors.As(err, &written) {
				t.Fatalf("Create = %+v, %v (%T), want a *WrittenError", result, err, err)
			}
			if err := os.Chmod(dir, 0o700); err != nil {
				t.Fatal(err)
			}
			if filepath.Dir(written.Path) != dir || !strings.HasPrefix(err.Error(), written.Path+c.says) {
				t.Errorf("the error names %s and says %q", written.Path, err)
			}
			if meta, _, err := Describe(written.Path); err != nil || meta.DumpBytes != int64(len("SELECT 1;\n")) {
				t.Errorf("the archive %s is not complete: %+v, %v", written.Path, meta, err)
			}
		})
	}
}

// The archive taken after a prune comes first, whatever the prune left:
// its sequence follows the highest one kept. One more than the number of
// archives kept is a sequence already in use, which would put the newest
// archive behind an older one for Latest and restore --latest.
func TestArchiveTakenAfterAPruneComesFirst(t *testing.T) {
	dir := t.TempDir()
	for i := range 7 {
		createSQL(t, dir, fmt.Sprintf("SELECT %d;\n", i))
	}
	if removed, err := Prune(dir, 5); err != nil || len(removed) != 2 {
		t.Fatalf("Prune(5) removed %v, %v", removed, err)
	}
	newest := createSQL(t, dir, "SELECT 7;\n")
	list, err := List(dir)
	if err != nil {
		t.Fatal(err)
	}
	if len(list) != 6 || list[0].Path != newest || list[0].Sequence != 8 {
		t.Fatalf("listed %s first (sequence %d) of %d, want %s with sequence 8", list[0].Name, list[0].Sequence, len(list), filepath.Base(newest))
	}
	if latest, err := Latest(dir, ""); err != nil || latest != newest {
		t.Errorf("Latest = %s, %v, want %s", latest, err, newest)
	}
}

// Archives written before kvsctl numbered them carry no sequence. They
// were written before every numbered one, and among themselves the date of
// their name orders them; the first numbered archive is 1.
func TestArchivesWithoutASequence(t *testing.T) {
	dir := t.TempDir()
	meta, _ := json.Marshal(Meta{Format: Format, Version: "0.1.0"})
	for _, name := range []string{"backup-0.1.0-20260101-101010.tar", "backup-0.1.0-20260301-101010.tar", "backup-0.1.0-20990101-101010.tar"} {
		writeTar(t, dir, name, [][2]string{{metaName, string(meta)}})
	}
	newest := createSQL(t, dir, "SELECT 1;\n")
	list, err := List(dir)
	if err != nil {
		t.Fatal(err)
	}
	var got []string
	for _, b := range list {
		got = append(got, fmt.Sprintf("%s %d", b.Name, b.Sequence))
	}
	want := []string{filepath.Base(newest) + " 1", "backup-0.1.0-20990101-101010.tar 0", "backup-0.1.0-20260301-101010.tar 0", "backup-0.1.0-20260101-101010.tar 0"}
	if !slices.Equal(got, want) {
		t.Errorf("listed\n%s\nwant\n%s", strings.Join(got, "\n"), strings.Join(want, "\n"))
	}
	if again := createSQL(t, dir, "SELECT 2;\n"); !strings.HasSuffix(again, ".tar") {
		t.Fatal(again)
	}
	if list, _ := List(dir); list[0].Sequence != 2 {
		t.Errorf("the next archive is %+v, want sequence 2", list[0])
	}
}

// backup.json records the KVS version the site runs when it is given, and
// says nothing of it when it is not.
func TestCreateRecordsTheKVSVersion(t *testing.T) {
	plentyOfSpace(t)
	stubServer(t, dumpOf("SELECT 1;\n"))
	for _, kvs := range []string{"6.3.2", ""} {
		dir := t.TempDir()
		result, err := Create(context.Background(), dir, "0.2.0", "kvs-mariadb", writeEnv(t, dir), "", nil, WithKVSVersion(kvs))
		if err != nil {
			t.Fatal(err)
		}
		meta, _, err := Describe(result.Path)
		if err != nil || meta.KVSVersion != kvs {
			t.Errorf("KVS version %q recorded as %+v, %v", kvs, meta, err)
		}
		a, err := openArchive(result.Path)
		if err != nil {
			t.Fatal(err)
		}
		raw, err := a.read(metaName, 64<<10)
		a.Close()
		if err != nil {
			t.Fatal(err)
		}
		want := `"kvs_version": "` + kvs + `"`
		if kvs == "" {
			if strings.Contains(string(raw), `"kvs_version"`) {
				t.Errorf("no KVS version given, backup.json:\n%s", raw)
			}
		} else if !strings.Contains(string(raw), want) {
			t.Errorf("KVS version %q, backup.json:\n%s", kvs, raw)
		}
		if list, _ := List(dir); len(list) != 1 || list[0].KVSVersion != kvs {
			t.Errorf("List = %+v", list)
		}
	}
}
