package runlog

import (
	"errors"
	"os"
	"path/filepath"
	"regexp"
	"strings"
	"sync"
	"sync/atomic"
	"testing"
	"time"
)

// setClock fixes the clock of the package for one test.
func setClock(t *testing.T, at time.Time) {
	t.Helper()
	old := now
	t.Cleanup(func() { now = old })
	now = func() time.Time { return at }
}

func readLog(t *testing.T, path string) string {
	t.Helper()
	data, err := os.ReadFile(path)
	if err != nil {
		t.Fatal(err)
	}
	return string(data)
}

func TestOpenNamesTheLogAfterTheRun(t *testing.T) {
	// 14:03:09 in a zone two hours ahead is 12:03:09 UTC, which is what
	// the name and the lines carry.
	setClock(t, time.Date(2026, 10, 6, 14, 3, 9, 0, time.FixedZone("CEST", 2*3600)))
	state := t.TempDir()
	// A logs directory another tool made readable by all is closed again.
	if err := os.MkdirAll(Dir(state), 0o755); err != nil {
		t.Fatal(err)
	}
	l, err := Open(state, "upgrade")
	if err != nil {
		t.Fatal(err)
	}
	want := filepath.Join(state, "logs", "20261006-120309-upgrade.log")
	if l.Path() != want {
		t.Errorf("path = %s, want %s", l.Path(), want)
	}
	l.Printf("stack %s on %s", "26.10.0", "example.com")
	l.Printf("compose failed:\nline one\r\nline two\n")
	if err := l.Close(); err != nil {
		t.Fatal(err)
	}
	got := readLog(t, l.Path())
	wantLog := "2026-10-06T12:03:09Z stack 26.10.0 on example.com\n" +
		"2026-10-06T12:03:09Z compose failed:\n" +
		"2026-10-06T12:03:09Z line one\n" +
		"2026-10-06T12:03:09Z line two\n"
	if got != wantLog {
		t.Errorf("log =\n%s\nwant\n%s", got, wantLog)
	}
	for path, mode := range map[string]os.FileMode{Dir(state): 0o700, l.Path(): 0o600} {
		info, err := os.Stat(path)
		if err != nil {
			t.Fatal(err)
		}
		if info.Mode().Perm() != mode {
			t.Errorf("%s has mode %o, want %o: a log names the backups and the site", path, info.Mode().Perm(), mode)
		}
	}
}

func TestOpenRefusesANameThatIsNotACommand(t *testing.T) {
	state := t.TempDir()
	for _, command := range []string{"", "../state", "Upgrade", "up grade", "-x"} {
		if _, err := Open(state, command); err == nil {
			t.Errorf("Open(%q) must be refused", command)
		}
	}
}

// Two runs of one command in the same second do not share a log.
func TestOpenMovesTheStampOnWhenTheSecondIsTaken(t *testing.T) {
	setClock(t, time.Date(2026, 10, 6, 12, 3, 9, 0, time.UTC))
	state := t.TempDir()
	first, err := Open(state, "backup")
	if err != nil {
		t.Fatal(err)
	}
	defer first.Close()
	second, err := Open(state, "backup")
	if err != nil {
		t.Fatal(err)
	}
	defer second.Close()
	if filepath.Base(second.Path()) != "20261006-120310-backup.log" {
		t.Errorf("second log = %s, want the next second", second.Path())
	}
	other, err := Open(state, "restore")
	if err != nil {
		t.Fatal(err)
	}
	defer other.Close()
	if filepath.Base(other.Path()) != "20261006-120309-restore.log" {
		t.Errorf("another command keeps its second: %s", other.Path())
	}
}

func TestOpenKeepsTheNewestLogs(t *testing.T) {
	state := t.TempDir()
	dir := Dir(state)
	if err := os.MkdirAll(dir, 0o700); err != nil {
		t.Fatal(err)
	}
	base := time.Date(2026, 9, 1, 0, 0, 0, 0, time.UTC)
	for n := 0; n < Keep+5; n++ {
		name := base.Add(time.Duration(n)*time.Hour).Format(stampLayout) + "-upgrade.log"
		if err := os.WriteFile(filepath.Join(dir, name), []byte("old run\n"), 0o600); err != nil {
			t.Fatal(err)
		}
	}
	others := []string{"notes.txt", "20260801-000000-upgrade.log.gz"}
	for _, name := range others {
		if err := os.WriteFile(filepath.Join(dir, name), nil, 0o600); err != nil {
			t.Fatal(err)
		}
	}
	setClock(t, base.Add(24*time.Hour*30))
	l, err := Open(state, "upgrade")
	if err != nil {
		t.Fatal(err)
	}
	defer l.Close()
	logs, err := List(state)
	if err != nil {
		t.Fatal(err)
	}
	if len(logs) != Keep || logs[0] != l.Path() {
		t.Fatalf("%d logs, newest %s: want %d with the new one first", len(logs), logs[0], Keep)
	}
	oldestKept := base.Add(time.Duration(6)*time.Hour).Format(stampLayout) + "-upgrade.log"
	if filepath.Base(logs[Keep-1]) != oldestKept {
		t.Errorf("oldest kept = %s, want %s", logs[Keep-1], oldestKept)
	}
	for _, name := range others {
		if _, err := os.Stat(filepath.Join(dir, name)); err != nil {
			t.Errorf("%s is not a log and must stay: %v", name, err)
		}
	}
	if logs, err := List(t.TempDir()); err != nil || logs != nil {
		t.Errorf("a state directory without logs lists none: %v %v", logs, err)
	}
}

// The log of an interrupted run stays whatever its age: recover names it,
// and every run of recover writes a log of its own.
func TestOpenSparesTheLogsItIsToldToKeep(t *testing.T) {
	state := t.TempDir()
	dir := Dir(state)
	if err := os.MkdirAll(dir, 0o700); err != nil {
		t.Fatal(err)
	}
	base := time.Date(2026, 9, 1, 0, 0, 0, 0, time.UTC)
	interrupted := filepath.Join(dir, base.Format(stampLayout)+"-upgrade.log")
	for n := 0; n < Keep+3; n++ {
		name := base.Add(time.Duration(n)*time.Hour).Format(stampLayout) + "-recover.log"
		if n == 0 {
			name = filepath.Base(interrupted)
		}
		if err := os.WriteFile(filepath.Join(dir, name), []byte("run\n"), 0o600); err != nil {
			t.Fatal(err)
		}
	}
	setClock(t, base.Add(24*time.Hour*30))
	l, err := Open(state, "recover", interrupted)
	if err != nil {
		t.Fatal(err)
	}
	defer l.Close()
	if _, err := os.Stat(interrupted); err != nil {
		t.Fatalf("the log of the interrupted run was pruned: %v", err)
	}
	logs, err := List(state)
	if err != nil {
		t.Fatal(err)
	}
	if len(logs) != Keep+1 || logs[0] != l.Path() || logs[len(logs)-1] != interrupted {
		t.Fatalf("%d logs, from %s to %s", len(logs), logs[0], logs[len(logs)-1])
	}
}

func TestPrintfIsSafeForConcurrentUse(t *testing.T) {
	l, err := Open(t.TempDir(), "upgrade")
	if err != nil {
		t.Fatal(err)
	}
	const workers, lines = 8, 200
	var wg sync.WaitGroup
	for w := 0; w < workers; w++ {
		wg.Add(1)
		go func() {
			defer wg.Done()
			for n := 0; n < lines; n++ {
				l.Printf("worker %d line %d", w, n)
			}
		}()
	}
	wg.Wait()
	if err := l.Close(); err != nil {
		t.Fatal(err)
	}
	got := strings.Split(strings.TrimSuffix(readLog(t, l.Path()), "\n"), "\n")
	if len(got) != workers*lines {
		t.Fatalf("%d lines, want %d", len(got), workers*lines)
	}
	line := regexp.MustCompile(`^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z worker \d line \d+$`)
	for _, entry := range got {
		if !line.MatchString(entry) {
			t.Fatalf("interleaved line %q", entry)
		}
	}
}

// A run that ends while goroutines still log, the copy of a docker output
// or a signal handler, closes its log under them: nothing is written to
// the closed file, so neither Close nor Err reports an error, and every
// line the log holds is whole. Under the race detector, which CI runs, the
// test also fails when Printf does not take the lock that Close and Err
// take.
func TestPrintfAndCloseAtTheSameTime(t *testing.T) {
	line := regexp.MustCompile(`^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z worker \d line \d+$`)
	for round := 0; round < 20; round++ {
		l, err := Open(t.TempDir(), "upgrade")
		if err != nil {
			t.Fatal(err)
		}
		start := make(chan struct{})
		var wg sync.WaitGroup
		for w := 0; w < 8; w++ {
			wg.Add(1)
			go func() {
				defer wg.Done()
				<-start
				for n := 0; n < 50; n++ {
					l.Printf("worker %d line %d", w, n)
					_ = l.Err()
				}
			}()
		}
		closed := make(chan error, 1)
		go func() {
			<-start
			closed <- l.Close()
		}()
		close(start)
		wg.Wait()
		if err := <-closed; err != nil {
			t.Fatalf("Close: %v", err)
		}
		if err := l.Err(); err != nil {
			t.Fatalf("an entry went to the log after it was closed: %v", err)
		}
		for _, entry := range strings.Split(strings.TrimSuffix(readLog(t, l.Path()), "\n"), "\n") {
			if entry != "" && !line.MatchString(entry) {
				t.Fatalf("broken line %q", entry)
			}
		}
	}
}

// slowFailure fails every write, after a moment in which another write
// could start, and counts the writes.
type slowFailure struct{ calls atomic.Int32 }

func (w *slowFailure) Write([]byte) (int, error) {
	w.calls.Add(1)
	time.Sleep(2 * time.Millisecond)
	return 0, errors.New("no space left on device")
}

// Goroutines that log at once into a log that can no longer be written:
// the first failure is the only write tried, and the error the log keeps.
func TestConcurrentPrintfStopsAtTheFirstFailure(t *testing.T) {
	l, err := Open(t.TempDir(), "upgrade")
	if err != nil {
		t.Fatal(err)
	}
	defer l.Close()
	broken := &slowFailure{}
	l.w = broken
	start := make(chan struct{})
	var wg sync.WaitGroup
	for w := 0; w < 8; w++ {
		wg.Add(1)
		go func() {
			defer wg.Done()
			<-start
			l.Printf("worker %d", w)
		}()
	}
	close(start)
	wg.Wait()
	if calls := broken.calls.Load(); calls != 1 {
		t.Errorf("%d writes were tried, want the first alone: the log goes on writing after it failed", calls)
	}
	if err := l.Err(); err == nil || !strings.Contains(err.Error(), "no space left on device") {
		t.Errorf("Err() = %v, want the write error", err)
	}
}

// failingWriter fails every write and counts them.
type failingWriter struct{ calls int }

func (w *failingWriter) Write([]byte) (int, error) {
	w.calls++
	return 0, errors.New("no space left on device")
}

func TestAFailedWriteNeverFailsTheRun(t *testing.T) {
	l, err := Open(t.TempDir(), "upgrade")
	if err != nil {
		t.Fatal(err)
	}
	broken := &failingWriter{}
	l.w = broken
	l.Printf("first")
	l.Printf("second")
	if broken.calls != 1 {
		t.Errorf("the log went on writing after it failed: %d writes", broken.calls)
	}
	err = l.Err()
	if err == nil || !strings.Contains(err.Error(), l.Path()) || !strings.Contains(err.Error(), "no space left on device") {
		t.Errorf("Err() = %v, want the write error naming the log", err)
	}
	if first := l.failure(); first == nil {
		t.Error("the failure is told the first time")
	}
	if again := l.failure(); again != nil {
		t.Errorf("the failure is told once, got it again: %v", again)
	}
	if cerr := l.Close(); cerr == nil || !strings.Contains(cerr.Error(), "no space left on device") {
		t.Errorf("Close() = %v, want the write error: the log is incomplete", cerr)
	}
}

func TestCloseEndsTheLog(t *testing.T) {
	l, err := Open(t.TempDir(), "restore")
	if err != nil {
		t.Fatal(err)
	}
	l.Printf("replayed")
	if err := l.Close(); err != nil {
		t.Fatal(err)
	}
	l.Printf("after the end")
	if err := l.Close(); err != nil {
		t.Errorf("a second Close: %v", err)
	}
	if got := readLog(t, l.Path()); strings.Count(got, "\n") != 1 || !strings.HasSuffix(got, " replayed\n") {
		t.Errorf("log = %q, want the one line written before Close", got)
	}
}
