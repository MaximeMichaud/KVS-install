package instance

import (
	"os"
	"path/filepath"
	"reflect"
	"strings"
	"testing"
	"time"
)

func TestJournalRoundTrip(t *testing.T) {
	inst := newInstance(t, "DOMAIN=example.com\n")
	if j, err := inst.LoadJournal(); err != nil || j != nil {
		t.Fatalf("no run was interrupted, so there is no journal: %+v %v", j, err)
	}
	if err := inst.RemoveJournal(); err != nil {
		t.Errorf("removing a journal that is not there: %v", err)
	}
	started := time.Date(2026, 10, 6, 14, 3, 0, 0, time.UTC)
	j := &Journal{
		Action:            ActionUpgrade,
		From:              "26.10.0",
		To:                "26.10.1",
		Started:           started,
		Phase:             PhaseApply,
		Log:               filepath.Join(inst.StateDir(), "logs", "20261006-140300-upgrade.log"),
		Backup:            filepath.Join(inst.BackupDir(), "backup-26.10.0-20261006-140301.tar"),
		Applied:           true,
		ComposeStarted:    true,
		MariaDB:           ContainerMark{ID: "c0ffee", Started: started.Add(-time.Hour)},
		MariaDBRecreated:  true,
		OneWay:            true,
		Database:          "migrates",
		RestoreDB:         true,
		Files:             []string{"docker/docker-compose.yml", "docker/setup.sh"},
		ImagesBefore:      map[string]string{"KVS_MARIADB_IMAGE": "mariadb:11.4.8@sha256:" + strings.Repeat("a", 64)},
		ImagesAfter:       map[string]string{"KVS_MARIADB_IMAGE": "mariadb:11.8.3@sha256:" + strings.Repeat("b", 64)},
		ComposeFileBefore: "docker-compose.yml:docker-compose.override.yml",
		Pins:              []string{"mariadb:11.8.3@sha256:" + strings.Repeat("b", 64)},
		Ignored:           []string{"manticore"},
	}
	before := time.Now().UTC()
	if err := inst.SaveJournal(j); err != nil {
		t.Fatal(err)
	}
	if !j.Started.Equal(started) {
		t.Errorf("a save keeps the start the run gave: %v", j.Started)
	}
	if j.Updated.Before(before.Truncate(time.Second)) {
		t.Errorf("a save stamps the time it was written: %v", j.Updated)
	}
	got, err := inst.LoadJournal()
	if err != nil {
		t.Fatal(err)
	}
	if !reflect.DeepEqual(got, j) {
		t.Errorf("journal after a round trip:\n%+v\nwant\n%+v", got, j)
	}
	info, err := os.Stat(filepath.Join(inst.StateDir(), "journal.json"))
	if err != nil {
		t.Fatal(err)
	}
	if info.Mode().Perm() != 0o600 {
		t.Errorf("journal mode %o, want 600: it names the backups", info.Mode().Perm())
	}

	// A later phase replaces the record in one rename, nothing is left
	// beside it.
	j.Phase = PhaseVerify
	if err := inst.SaveJournal(j); err != nil {
		t.Fatal(err)
	}
	if got, err := inst.LoadJournal(); err != nil || got.Phase != PhaseVerify {
		t.Errorf("phase after the second save: %+v %v", got, err)
	}
	entries, err := os.ReadDir(inst.StateDir())
	if err != nil {
		t.Fatal(err)
	}
	if len(entries) != 1 || entries[0].Name() != "journal.json" {
		t.Errorf("the state directory holds %v, want the journal alone", entries)
	}

	if err := inst.RemoveJournal(); err != nil {
		t.Fatal(err)
	}
	if got, err := inst.LoadJournal(); err != nil || got != nil {
		t.Errorf("a removed journal is gone: %+v %v", got, err)
	}
}

func TestJournalStartsOnTheFirstSave(t *testing.T) {
	inst := newInstance(t, "DOMAIN=example.com\n")
	j := &Journal{Action: ActionRollback, From: "26.10.1", To: "26.10.0", Phase: PhaseApply}
	if err := inst.SaveJournal(j); err != nil {
		t.Fatal(err)
	}
	if j.Started.IsZero() || !j.Started.Equal(j.Updated) {
		t.Errorf("a run without a start takes the first save's: started %v, updated %v", j.Started, j.Updated)
	}
	first := j.Started
	j.Phase = PhaseRestart
	if err := inst.SaveJournal(j); err != nil {
		t.Fatal(err)
	}
	if !j.Started.Equal(first) {
		t.Errorf("a later save moved the start from %v to %v", first, j.Started)
	}
}

// The first save of a run gives its journal the format of this kvsctl. The
// journal of a run an older kvsctl began has none, and keeps none through
// the saves of the recover that finishes it: the format says how the
// history dates the entry of the run.
func TestJournalFormat(t *testing.T) {
	inst := newInstance(t, "DOMAIN=example.com\n")
	j := &Journal{Action: ActionUpgrade, From: "26.10.0", To: "26.10.1", Phase: PhaseApply}
	if err := inst.SaveJournal(j); err != nil {
		t.Fatal(err)
	}
	got, err := inst.LoadJournal()
	if err != nil || got == nil || got.Format != JournalFormat {
		t.Fatalf("the journal of a run this kvsctl began: %+v %v, want format %d", got, err, JournalFormat)
	}
	older := `{"action":"upgrade","from":"26.10.0","to":"26.10.1","started":"2026-10-06T14:03:00Z","updated":"2026-10-06T14:03:05Z","phase":"verify"}` + "\n"
	if err := os.WriteFile(filepath.Join(inst.StateDir(), "journal.json"), []byte(older), 0o600); err != nil {
		t.Fatal(err)
	}
	j, err = inst.LoadJournal()
	if err != nil || j == nil {
		t.Fatalf("the journal of an older kvsctl: %+v %v", j, err)
	}
	j.Phase = PhaseRollback
	if err := inst.SaveJournal(j); err != nil {
		t.Fatal(err)
	}
	if got, err := inst.LoadJournal(); err != nil || got == nil || got.Format != 0 || got.Phase != PhaseRollback || !got.Started.Equal(time.Date(2026, 10, 6, 14, 3, 0, 0, time.UTC)) {
		t.Errorf("the journal of an older kvsctl saved again: %+v %v", got, err)
	}
}

func TestJournalRefusal(t *testing.T) {
	j := &Journal{Action: ActionUpgrade, From: "26.10.0", To: "26.10.1", Phase: PhaseRestart, Started: time.Date(2026, 10, 6, 14, 3, 59, 0, time.UTC)}
	want := "an upgrade from 26.10.0 to 26.10.1 was interrupted during restart on 2026-10-06 14:03 UTC: run 'kvsctl recover'"
	if got := j.Interrupted(nil).Error(); got != want {
		t.Errorf("refusal = %q\nwant      %q", got, want)
	}
	j.Action, j.From, j.To, j.Phase = ActionRollback, "26.10.1", "26.10.0", PhaseVerify
	j.Started = time.Date(2026, 10, 6, 16, 3, 0, 0, time.FixedZone("CEST", 2*3600))
	want = "a rollback from 26.10.1 to 26.10.0 was interrupted during verify on 2026-10-06 14:03 UTC"
	if got := j.Describe(nil); got != want {
		t.Errorf("description = %q\nwant          %q", got, want)
	}
	// The journal keeps 0.0.0, and the operator reads the checkout adopt
	// recorded.
	adopted := &State{Current: "26.10.1", Previous: Unreleased, AdoptedCommit: "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"}
	j.To = Unreleased
	want = "a rollback from 26.10.1 to unreleased checkout aaaaaaaaaaaa was interrupted during verify on 2026-10-06 14:03 UTC: run 'kvsctl recover'"
	if got := j.Interrupted(adopted).Error(); got != want {
		t.Errorf("refusal = %q\nwant      %q", got, want)
	}
}

// A run that failed, or whose rollback failed, is told as one that failed:
// dated when it failed, not when it started, with what made it fail, and
// recover is to be run once that is fixed. Each kind of run says what
// failed in its own words.
func TestJournalOfARunThatFailed(t *testing.T) {
	started := time.Date(2026, 10, 6, 14, 3, 0, 0, time.UTC)
	failed := time.Date(2026, 10, 6, 15, 41, 30, 0, time.FixedZone("CEST", 2*3600))
	cases := []struct {
		name string
		j    Journal
		want string
	}{
		{"the rollback of an upgrade", Journal{Action: ActionUpgrade, From: "26.10.0", To: "26.10.1", Phase: PhaseRollback},
			"the rollback of an upgrade from 26.10.0 to 26.10.1 failed on 2026-10-06 13:41 UTC: docker compose up -d: exit status 1: no space left on device"},
		{"a manual rollback part way", Journal{Action: ActionRollback, From: "26.10.1", To: "26.10.0", Phase: PhaseVerify},
			"a rollback from 26.10.1 to 26.10.0 failed during verify on 2026-10-06 13:41 UTC: docker compose up -d: exit status 1: no space left on device"},
		{"the undoing of a manual rollback", Journal{Action: ActionRollback, From: "26.10.1", To: "26.10.0", Phase: PhaseRollback},
			"undoing a rollback from 26.10.1 to 26.10.0 failed on 2026-10-06 13:41 UTC: docker compose up -d: exit status 1: no space left on device"},
		{"a restore", Journal{Action: ActionRestore, From: "26.10.1", To: "26.10.1", Phase: PhaseReplay, Replay: "/opt/kvs/backups/backup-26.10.1-20261006-140300.tar"},
			"a restore of backup-26.10.1-20261006-140300.tar failed during replay on 2026-10-06 13:41 UTC: docker compose up -d: exit status 1: no space left on device"},
	}
	for _, c := range cases {
		j := c.j
		j.Started, j.Failed, j.Failure = started, failed, "docker compose up -d: exit status 1: no space left on device"
		if got := j.Describe(nil); got != c.want {
			t.Errorf("%s: description = %q\nwant %q", c.name, got, c.want)
		}
		if got, want := j.Interrupted(nil).Error(), c.want+"; once the cause is fixed, run 'kvsctl recover'"; got != want {
			t.Errorf("%s: refusal = %q\nwant %q", c.name, got, want)
		}
	}
	// The record survives the file, the cause of the run with it.
	inst := newInstance(t, "DOMAIN=example.com\n")
	j := &Journal{Action: ActionUpgrade, From: "26.10.0", To: "26.10.1", Phase: PhaseRollback, Cause: "not healthy after 2m0s: kvs-nginx is unhealthy", Failed: failed, Failure: "no space left on device"}
	if err := inst.SaveJournal(j); err != nil {
		t.Fatal(err)
	}
	loaded, err := inst.LoadJournal()
	if err != nil {
		t.Fatal(err)
	}
	if !loaded.Failed.Equal(failed) || loaded.Failure != j.Failure || loaded.Cause != j.Cause {
		t.Errorf("loaded %+v, saved %+v", loaded, j)
	}
}

func TestDamagedJournalIsNamed(t *testing.T) {
	inst := newInstance(t, "DOMAIN=example.com\n")
	if err := os.MkdirAll(inst.StateDir(), 0o750); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(inst.StateDir(), "journal.json"), []byte(`{"action":`), 0o600); err != nil {
		t.Fatal(err)
	}
	if _, err := inst.LoadJournal(); err == nil || !strings.Contains(err.Error(), "journal.json") {
		t.Errorf("a damaged journal must be named, got %v", err)
	}
}

func TestStateRecordsTheUpgradeBackupAndTheAdoptedCommit(t *testing.T) {
	inst := newInstance(t, "DOMAIN=example.com\n")
	date := time.Date(2026, 9, 30, 18, 4, 5, 0, time.UTC)
	want := &State{
		Current:           "26.10.1",
		UpgradeBackup:     filepath.Join(inst.BackupDir(), "backup-26.10.0-20261006-140301.tar"),
		AdoptedCommit:     strings.Repeat("e", 40),
		AdoptedCommitDate: date,
		History:           []Entry{{Version: "26.10.0", Action: "adopt", Date: date}},
	}
	if err := inst.SaveState(want); err != nil {
		t.Fatal(err)
	}
	got, err := inst.LoadState()
	if err != nil {
		t.Fatal(err)
	}
	if got.UpgradeBackup != want.UpgradeBackup || got.AdoptedCommit != want.AdoptedCommit || !got.AdoptedCommitDate.Equal(date) {
		t.Errorf("state after a round trip: %+v", got)
	}

	// A stack that was never adopted from a checkout writes no commit.
	if err := inst.SaveState(&State{Current: "26.10.1"}); err != nil {
		t.Fatal(err)
	}
	data, err := os.ReadFile(filepath.Join(inst.StateDir(), "state.json"))
	if err != nil {
		t.Fatal(err)
	}
	for _, key := range []string{"upgrade_backup", "adopted_commit", "adopted_commit_date"} {
		if strings.Contains(string(data), key) {
			t.Errorf("an unset %s is written:\n%s", key, data)
		}
	}
}

func TestUpgraded(t *testing.T) {
	adopted := []Entry{{Version: "26.10.0", Action: "adopt"}}
	cases := []struct {
		name  string
		state *State
		want  bool
	}{
		{"no state", nil, false},
		{"adopted", &State{History: adopted}, false},
		{"rolled back after a failed upgrade", &State{History: append(adopted, Entry{Version: "26.10.0", Action: "rollback", Note: "26.10.1 failed: unhealthy"})}, false},
		{"upgraded", &State{History: append(adopted, Entry{Version: "26.10.1", Action: "upgrade"})}, true},
		{"upgraded then rolled back by hand", &State{History: append(adopted, Entry{Version: "26.10.1", Action: "upgrade"}, Entry{Version: "26.10.0", Action: "rollback"})}, true},
	}
	for _, c := range cases {
		if got := c.state.Upgraded(); got != c.want {
			t.Errorf("%s: Upgraded() = %v, want %v", c.name, got, c.want)
		}
	}
}

// The version adopt records for a checkout no release names reads as that
// checkout, by its commit; every other version reads as itself.
func TestLabel(t *testing.T) {
	adopted := &State{Current: Unreleased, AdoptedCommit: "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"}
	if got := adopted.Label(Unreleased); got != "unreleased checkout aaaaaaaaaaaa" {
		t.Errorf("an unreleased checkout reads %q", got)
	}
	if got := adopted.Label("26.10.0"); got != "26.10.0" {
		t.Errorf("a release reads %q", got)
	}
	if got := (&State{Current: Unreleased}).Label(Unreleased); got != Unreleased {
		t.Errorf("0.0.0 without a commit reads %q", got)
	}
	var none *State
	if got := none.Label(Unreleased); got != Unreleased {
		t.Errorf("0.0.0 without a state reads %q", got)
	}
}
