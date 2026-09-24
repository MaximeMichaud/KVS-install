package main

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/MaximeMichaud/KVS-install/cli/internal/backup"
)

func sampleBackups(dir string) []backup.Info {
	return []backup.Info{
		{Name: "backup-0.2.0-20260924-033804.tar", Path: filepath.Join(dir, "backup-0.2.0-20260924-033804.tar"), Version: "0.2.0", Size: 431000, Date: time.Date(2026, 9, 24, 3, 38, 4, 0, time.UTC)},
		{Name: "backup-0.1.0-20260901-101010.tar.zst", Path: filepath.Join(dir, "backup-0.1.0-20260901-101010.tar.zst"), Version: "0.1.0", Size: 4000, Date: time.Date(2026, 9, 1, 10, 10, 10, 0, time.UTC), Legacy: true},
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
	if path, err := chooseBackup(dir, "", true, list); err != nil || path != list[0].Path {
		t.Fatalf("--latest: %q, %v", path, err)
	}
	if _, err := chooseBackup(dir, "", true, nil); err == nil {
		t.Fatal("--latest on an empty directory was accepted")
	}
	// Tests run without a terminal, which is the cron case: the argument
	// or --latest is required instead of a picker nobody can answer.
	_, err := chooseBackup(dir, "", false, list)
	if err == nil || !strings.Contains(err.Error(), "--latest") {
		t.Fatalf("without a terminal: %v", err)
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
