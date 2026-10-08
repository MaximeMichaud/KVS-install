package main

import (
	"context"
	"io"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/MaximeMichaud/KVS-install/cli/internal/backup"
	"github.com/MaximeMichaud/KVS-install/cli/internal/ui"
	"github.com/MaximeMichaud/KVS-install/cli/internal/upgrade"
)

func sampleBackups(dir string) []backup.Info {
	return []backup.Info{
		{Name: "backup-0.2.0-20260924-033804.tar", Path: filepath.Join(dir, "backup-0.2.0-20260924-033804.tar"), Version: "0.2.0", Size: 431000, Date: time.Date(2026, 9, 24, 3, 38, 4, 0, time.UTC)},
		{Name: "backup-0.1.0-20260901-101010.tar", Path: filepath.Join(dir, "backup-0.1.0-20260901-101010.tar"), Version: "0.1.0", Size: 4000, Date: time.Date(2026, 9, 1, 10, 10, 10, 0, time.UTC)},
	}
}

func TestResolveBackup(t *testing.T) {
	dir := t.TempDir()
	list := sampleBackups(dir)
	path, err := resolveBackup(dir, "backup-0.2.0-20260924-033804.tar", list)
	if err != nil || path != list[0].Path {
		t.Fatalf("by name: %q, %v", path, err)
	}
	if path, err := resolveBackup(dir, list[1].Path, list); err != nil || path != list[1].Path {
		t.Fatalf("by path: %q, %v", path, err)
	}
	elsewhere := filepath.Join(t.TempDir(), "kept.tar")
	if err := os.WriteFile(elsewhere, []byte("x"), 0o600); err != nil {
		t.Fatal(err)
	}
	if path, err := resolveBackup(dir, elsewhere, list); err != nil || path != elsewhere {
		t.Fatalf("a file outside the directory: %q, %v", path, err)
	}
	if _, err := resolveBackup(dir, "backup-9.9.9-20260101-000000.tar", list); err == nil {
		t.Fatal("an unknown name was accepted")
	}
}

func TestChooseBackup(t *testing.T) {
	dir := t.TempDir()
	list := sampleBackups(dir)
	ctx := context.Background()
	noTerminal := ui.NewPlain(io.Discard, nil, false)
	if path, err := chooseBackup(ctx, nil, noTerminal, dir, "", true, list); err != nil || path != list[0].Path {
		t.Fatalf("--latest: %q, %v", path, err)
	}
	if _, err := chooseBackup(ctx, nil, noTerminal, dir, "", true, nil); err == nil {
		t.Fatal("--latest on an empty directory was accepted")
	}
	// Without a terminal, the cron case, the argument or --latest is
	// required instead of a picker nobody can answer.
	_, err := chooseBackup(ctx, nil, noTerminal, dir, "", false, list)
	if err == nil || !strings.Contains(err.Error(), "--latest") {
		t.Fatalf("without a terminal: %v", err)
	}
}

// The picker reads the number from the terminal, and Ctrl-C at the
// question leaves without a choice.
func TestChooseBackupAsks(t *testing.T) {
	dir := t.TempDir()
	list := sampleBackups(dir)
	s := testSession(t, newRoot(t))
	typed := ui.NewPlain(io.Discard, strings.NewReader("2\n"), false)
	if path, err := chooseBackup(context.Background(), s, typed, dir, "", false, list); err != nil || path != list[1].Path {
		t.Fatalf("answer 2: %q, %v", path, err)
	}
	if _, err := chooseBackup(context.Background(), s, ui.NewPlain(io.Discard, strings.NewReader("9\n"), false), dir, "", false, list); err == nil {
		t.Fatal("an answer off the list was accepted")
	}
	ctx, cancel := context.WithCancel(context.Background())
	cancel()
	silent, _ := io.Pipe()
	if _, err := chooseBackup(ctx, s, ui.NewPlain(io.Discard, silent, false), dir, "", false, list); err == nil {
		t.Fatal("an interrupted question chose a backup")
	}
}

// The question names the site whose database is replaced, the site the
// archive comes from when it is another one, the KVS of its database, and
// that the site is down meanwhile.
func TestRestoreQuestion(t *testing.T) {
	meta := &backup.Meta{Domain: "example.org"}
	got := restoreQuestion("example.com", "/opt/kvs/backups/a.tar", meta, true, "KVS 6.3.1, and the site runs KVS 6.4.0", true)
	want := "Restore the database of example.com from a.tar (an archive of example.org; KVS 6.3.1, and the site runs KVS 6.4.0), and its .env? The current data will be replaced, and the site is down until the replay is over"
	if got != want {
		t.Fatalf("question:\n%s\nwant:\n%s", got, want)
	}
	if got := restoreQuestion("example.com", "/opt/kvs/backups/a.tar", &backup.Meta{Domain: "example.com"}, false, "", false); got != "Restore the database of example.com from a.tar? The current data will be replaced, and the site is down until the replay is over" {
		t.Fatalf("an archive of this site: %q", got)
	}
}

func TestFormatBackupLine(t *testing.T) {
	line := formatBackupLine(1, sampleBackups(t.TempDir())[0])
	for _, want := range []string{"1) backup-0.2.0-20260924-033804.tar", "2026-09-24 03:38 UTC", "431 kB", "0.2.0"} {
		if !strings.Contains(line, want) {
			t.Fatalf("line %q lacks %q", line, want)
		}
	}
}

// Under --quiet, a restore prints the notices of its run, what became of
// .env, and none of its progress, which the log keeps; without --quiet it
// prints both. A step that fails prints nothing: the error of the run says
// why.
func TestRestoreSayerUnderQuiet(t *testing.T) {
	events := []upgrade.Event{
		{Kind: upgrade.KindStepStart, Step: upgrade.StepBackup, Message: "Backing up the current database first"},
		{Kind: upgrade.KindLog, Message: "dumping the database"},
		{Kind: upgrade.KindStepDone, Step: upgrade.StepBackup, Message: "/opt/kvs/backups/backup-1.0.0-20261007-120000.tar (6 kB, 0s)"},
		{Kind: upgrade.KindStepFail, Step: upgrade.StepRestore, Message: "the replay stopped"},
		{Kind: upgrade.KindLog, Message: "run 'docker compose up -d' in /opt/kvs/docker for the containers to read it", Notice: true},
	}
	progress := "Backing up the current database first.\n  dumping the database\n  /opt/kvs/backups/backup-1.0.0-20261007-120000.tar (6 kB, 0s)\n"
	notice := "  run 'docker compose up -d' in /opt/kvs/docker for the containers to read it\n"
	for _, quiet := range []bool{false, true} {
		root := newRoot(t)
		out := useRoot(t, root)
		old := flagQuiet
		flagQuiet = quiet
		g := newGuard("stops", nil)
		s, err := openSession("restore", g, sessionOptions{})
		if err != nil {
			t.Fatal(err)
		}
		printed := out.Len()
		p := &sayer{s: s}
		for _, e := range events {
			p.Event(e)
		}
		got := out.String()[printed:]
		path := s.log.Path()
		_ = s.finish(nil)
		g.stop()
		flagQuiet = old
		want := progress + notice
		if quiet {
			want = notice
		}
		if got != want {
			t.Errorf("quiet %v: printed\n%s\nwant\n%s", quiet, got, want)
		}
		log, err := os.ReadFile(path)
		if err != nil || !strings.Contains(string(log), "dumping the database") || !strings.Contains(string(log), "Backing up the current database first.") {
			t.Errorf("quiet %v: the log lacks the progress (%v):\n%s", quiet, err, log)
		}
	}
}
