package upgrade

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"regexp"
	"slices"
	"strings"
	"testing"
	"time"

	"github.com/MaximeMichaud/KVS-install/cli/internal/instance"
)

// An upgrade killed while it laid the files: nothing was started, so
// recover lays the previous files and settings back and starts nothing.
func TestRecoverAfterACutDuringApply(t *testing.T) {
	s := newStack(t, "", rel{version: "1.0.0"}, rel{version: "1.1.0", database: migrates})
	s.cutUpgrade(s.runner(), isLog("added 1 new settings"))
	j := s.journal()
	if j == nil || j.Phase != instance.PhaseApply || !j.Applied || j.ComposeStarted {
		t.Fatalf("journal: %+v", j)
	}
	if s.file("docker/RELEASE") != "1.1.0\n" {
		t.Fatal("the cut came before the files were laid")
	}
	s.fresh()
	if err := s.recover(s.runner()); err != nil {
		t.Fatalf("recover: %v", err)
	}
	s.back("1.0.0")
	if s.count("compose up") != 0 {
		t.Error("recover started compose for a run that never did")
	}
	if _, replays, _, _ := s.world(); len(replays) != 0 || !s.rep.said("compose never started") {
		t.Errorf("replays: %v", replays)
	}
	history := s.state().History
	if last := history[len(history)-1]; last.Action != instance.ActionRollback || last.Note != "1.1.0 was interrupted during apply" {
		t.Errorf("history ends with %+v", last)
	}
	undid(t, s.state(), instance.ActionUpgrade, "1.1.0", instance.OutcomeInterrupted, "interrupted during apply")
}

// An upgrade killed while it laid conf/extra/site.conf, a file of the
// directory that replaces the file conf/extra of 1.0.0: the kill leaves
// the temporary file of that lay in conf/extra, which is kvsctl's own, so
// recover lays conf/extra back as the file of 1.0.0 and finishes, and a
// second recover has nothing left to do.
func TestRecoverAfterAKillInATypeChange(t *testing.T) {
	s := newStack(t, "",
		rel{version: "1.0.0", files: map[string]string{"conf/extra": "file in 1.0.0\n"}},
		rel{version: "1.1.0", files: map[string]string{"conf/extra/site.conf": "file in 1.1.0\n"}})
	s.cutUpgrade(s.runner(quick), isStep(KindStepDone, StepApply))
	// The tree a SIGKILL during the lay of site.conf leaves.
	if err := os.Rename(filepath.Join(s.root, "conf/extra/site.conf"), filepath.Join(s.root, "conf/extra/.site.conf.kvsctl")); err != nil {
		t.Fatal(err)
	}
	if j := s.journal(); j == nil || j.Phase != instance.PhaseApply || !j.Applied {
		t.Fatalf("journal: %+v", j)
	}
	s.fresh()
	if err := s.recover(s.runner(quick)); err != nil {
		t.Fatalf("recover: %v", err)
	}
	s.back("1.0.0")
	if got := s.file("conf/extra"); got != "file in 1.0.0\n" {
		t.Errorf("conf/extra holds %q, want the file of 1.0.0", got)
	}
	s.fresh()
	if err := s.recover(s.runner(quick)); err == nil || err.Error() != "nothing to recover: no run was interrupted" {
		t.Errorf("a second recover: %v", err)
	}
}

// undid checks the run the last entry of the history says a rollback
// undid: which run, the version it went to, how it ended and why.
func undid(t *testing.T, state *instance.State, action, to, outcome, cause string) {
	t.Helper()
	last := state.History[len(state.History)-1]
	want := instance.Undone{Action: action, To: to, Outcome: outcome, Cause: cause}
	if last.Action != instance.ActionRollback || last.Undid == nil || *last.Undid != want {
		t.Errorf("the last entry of the history undid %+v, want %+v (entry %+v)", last.Undid, want, last)
	}
}

// An upgrade killed once its files were laid and before compose started,
// whose files someone brought up since, with 'docker compose up -d' or
// setup.sh: the containers are not the ones the run began with, so recover
// undoes it as a run whose compose started, replaying the backup over
// what the release did to the database and, on a series change, moving
// aside the data files the newer server upgraded.
func TestRecoverAfterACutAndAComposeUpByHand(t *testing.T) {
	cases := []struct {
		name    string
		release rel
		opts    []func(*Options)
		moved   int
		// says is what the question of recover says of the database.
		says string
	}{
		{"release that changes the database", rel{version: "1.1.0", database: migrates}, nil, 0, "1.1.0 changes the database: "},
		{"MariaDB series change", rel{version: "1.1.0"}, []func(*Options){series("12.3")}, 1, "MariaDB was recreated by a one-way run: its data files are moved aside and "},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			s := newStack(t, "11.8", rel{version: "1.0.0"}, c.release)
			s.f.behave(registry+"php:1.1.0-php8.1", behavior{migrate: "data-1 migrated by 1.1.0"})
			s.cutUpgrade(s.runner(c.opts...), isStep(KindStepDone, StepApply))
			if j := s.journal(); j == nil || j.Phase != instance.PhaseApply || j.ComposeStarted {
				t.Fatalf("journal: %+v", j)
			}
			s.f.with(func(f *fakeDocker) {
				if resp := f.up(filepath.Join(s.root, "docker"), nil); resp.Code != 0 {
					t.Fatalf("compose up by hand: %s", resp.Stderr)
				}
			})
			if db, _, _, _ := s.world(); db != "data-1 migrated by 1.1.0" {
				t.Fatalf("the release did not run: %q", db)
			}
			s.fresh()
			if err := s.recover(s.runner(func(o *Options) { o.Yes = false })); err != nil {
				t.Fatalf("recover: %v", err)
			}
			s.back("1.0.0")
			if q := s.rep.questions; len(q) != 1 || !regexp.MustCompile(`^Return the stack to 1\.0\.0, undoing what the upgrade to 1\.1\.0 did\? `+regexp.QuoteMeta(c.says)+`backup-1\.0\.0-\d{8}-\d{6}\.tar is replayed\. What was written to the database since that backup was taken is replaced, and the site is down until the replay is over\.$`).MatchString(q[0]) {
				t.Errorf("question: %q", q)
			}
			db, replays, moved, dataSeries := s.world()
			if db != "data-1" || !slices.Equal(replays, []string{"data-1"}) || len(moved) != c.moved || dataSeries != "11.8" {
				t.Errorf("database %q, replays %v, moved %v, series %s", db, replays, moved, dataSeries)
			}
			if !s.rep.said("are not the ones the run began with: compose ran since") {
				t.Errorf("recover did not say why it takes compose as started: %v", s.rep.logs())
			}
		})
	}
}

// Killed right before compose up: the journal already says compose
// started, the safe side, so the run is undone as one that may have
// changed the database; MariaDB was never recreated, so its files stay.
func TestRecoverAfterACutBeforeComposeUp(t *testing.T) {
	s := newStack(t, "11.8", rel{version: "1.0.0"}, rel{version: "1.1.0"})
	mariadbID := s.containerID("mariadb")
	s.cutUpgrade(s.runner(series("12.3")), isLog("starting MariaDB alone first"))
	if j := s.journal(); j == nil || j.Phase != instance.PhaseRestart || !j.ComposeStarted || s.count("compose up") != 0 {
		t.Fatalf("journal %+v after %v", j, s.f.commands())
	}
	s.fresh()
	if err := s.recover(s.runner()); err != nil {
		t.Fatalf("recover: %v", err)
	}
	s.back("1.0.0")
	if _, replays, moved, dataSeries := s.world(); !slices.Equal(replays, []string{"data-1"}) || len(moved) != 0 || dataSeries != "11.8" {
		t.Errorf("replays %v, moved %v, series %s", replays, moved, dataSeries)
	}
	if s.containerID("mariadb") != mariadbID {
		t.Error("the mariadb container was recreated")
	}
	if env := s.env(); env["MARIADB_VERSION"] != "11.8" {
		t.Errorf("MARIADB_VERSION = %q", env["MARIADB_VERSION"])
	}
}

// A host reboot between the cut and recover starts the same mariadb
// container again, with a new start time: no other server opened the data
// files, so they stay where they are. Only another container, which
// compose creates when the image changes, counts as recreated.
func TestRecoverAfterARebootLeavesTheDataFiles(t *testing.T) {
	s := newStack(t, "11.8", rel{version: "1.0.0"}, rel{version: "1.1.0"})
	mariadbID := s.containerID("mariadb")
	s.cutUpgrade(s.runner(series("12.3")), isLog("starting MariaDB alone first"))
	s.restartWith("mariadb", behavior{})
	s.fresh()
	if err := s.recover(s.runner()); err != nil {
		t.Fatalf("recover: %v", err)
	}
	s.back("1.0.0")
	if _, _, moved, dataSeries := s.world(); len(moved) != 0 || dataSeries != "11.8" {
		t.Errorf("moved %v, series %s", moved, dataSeries)
	}
	if s.containerID("mariadb") != mariadbID {
		t.Error("the mariadb container was recreated")
	}
}

// An automatic rollback that fails keeps its journal, in its rollback
// phase: the stack is between two versions, and recover, the way the error
// names first, runs the rollback again once the cause is gone; the way by
// hand comes after it.
func TestFailedRollbackIsFinishedByRecover(t *testing.T) {
	s := newStack(t, "", rel{version: "1.0.0"}, rel{version: "1.1.0", database: migrates})
	s.f.behave(registry+"php:1.1.0-php8.1", behavior{unhealthy: true})
	s.f.behave(registry+"php:1.0.0-php8.1", behavior{unhealthy: true})
	err := s.upgrade(s.runner(quick))
	if !errors.Is(err, ErrRollbackFailed) {
		t.Fatalf("err = %v", err)
	}
	msg := err.Error()
	recoverAt, restoreAt := strings.Index(msg, "'kvsctl recover' runs the rollback again"), strings.Index(msg, "'kvsctl restore ")
	if recoverAt < 0 || restoreAt < recoverAt || !strings.Contains(msg, "; log: ") {
		t.Fatalf("err = %v", err)
	}
	s.ended(err)
	if j := s.journal(); j == nil || j.Phase != instance.PhaseRollback {
		t.Fatalf("journal: %+v", j)
	}
	if history := s.state().History; history[len(history)-1].Action == instance.ActionRollback {
		t.Error("the rollback that failed was recorded")
	}

	// The cause is still there: recover runs the rollback again, which
	// fails the same way. The stack is in no known state, which is exit 5,
	// and the journal stays, with the failure.
	s.fresh()
	err = s.recover(s.runner(quick))
	if !errors.Is(err, ErrRollbackFailed) || !strings.Contains(err.Error(), "; the rollback to 1.0.0 failed: not healthy after 300ms: kvs-php-fpm is unhealthy; ") {
		t.Fatalf("recover while the cause is there: %v", err)
	}
	s.ended(err)
	if j := s.journal(); j == nil || j.Phase != instance.PhaseRollback || j.Failure != "not healthy after 300ms: kvs-php-fpm is unhealthy" {
		t.Fatalf("journal after the recover that failed: %+v", j)
	}

	// The cause is gone: the php-fpm of 1.0.0 starts again.
	s.f.behave(registry+"php:1.0.0-php8.1", behavior{})
	s.restartWith("php-fpm", behavior{})
	s.fresh()
	if err := s.recover(s.runner(quick)); err != nil {
		t.Fatalf("recover: %v", err)
	}
	s.back("1.0.0")
	if db, replays, _, _ := s.world(); db != "data-1" || !slices.Equal(replays, []string{"data-1", "data-1", "data-1"}) {
		t.Errorf("database %s, replays %v", db, replays)
	}
	history := s.state().History
	if last := history[len(history)-1]; last.Version != "1.0.0" || last.Action != instance.ActionRollback ||
		last.Note != "1.1.0 failed: not healthy after 300ms: kvs-php-fpm is unhealthy; its rollback failed first (not healthy after 300ms: kvs-php-fpm is unhealthy), and recover finished it" {
		t.Errorf("history ends with %+v", last)
	}
}

// Killed once compose had brought MariaDB up on the new series, before the
// journal said so: recover finds the container recreated, moves the data
// files aside and replays the backup.
func TestRecoverAfterACutAfterComposeUp(t *testing.T) {
	s := newStack(t, "11.8", rel{version: "1.0.0"}, rel{version: "1.1.0"})
	s.cutUpgrade(s.runner(series("12.3")), isLog("the mariadb container was"))
	if j := s.journal(); j == nil || j.Phase != instance.PhaseRestart || j.MariaDBRecreated {
		t.Fatalf("journal: %+v", j)
	}
	if _, _, _, dataSeries := s.world(); dataSeries != "12.3" {
		t.Fatalf("MariaDB did not run the new series before the cut: %s", dataSeries)
	}
	s.fresh()
	if err := s.recover(s.runner()); err != nil {
		t.Fatalf("recover: %v", err)
	}
	s.back("1.0.0")
	if db, replays, moved, dataSeries := s.world(); db != "data-1" || !slices.Equal(replays, []string{"data-1"}) || len(moved) != 1 || dataSeries != "11.8" {
		t.Errorf("database %s, replays %v, moved %v, series %s", db, replays, moved, dataSeries)
	}
	if env := s.env(); env["MARIADB_VERSION"] != "11.8" {
		t.Errorf("MARIADB_VERSION = %q", env["MARIADB_VERSION"])
	}
}

// Killed during the verification of a release that changes the database:
// the backup is replayed over what its code did.
func TestRecoverAfterACutDuringVerify(t *testing.T) {
	s := newStack(t, "", rel{version: "1.0.0"}, rel{version: "1.1.0", database: migrates})
	s.f.behave(registry+"php:1.1.0-php8.1", behavior{migrate: "data-1 migrated by 1.1.0"})
	s.cutUpgrade(s.runner(), isStep(KindStepStart, StepVerify))
	if j := s.journal(); j == nil || j.Phase != instance.PhaseVerify {
		t.Fatalf("journal: %+v", j)
	}
	s.fresh()
	r := s.runner(func(o *Options) { o.Yes = false })
	if err := s.recover(r); err != nil {
		t.Fatalf("recover: %v", err)
	}
	s.back("1.0.0")
	if q := s.rep.questions; len(q) != 1 || !strings.HasPrefix(q[0], "Return the stack to 1.0.0, undoing what the upgrade to 1.1.0 did? 1.1.0 changes the database: backup-1.0.0-") ||
		!strings.HasSuffix(q[0], ".tar is replayed. What was written to the database since that backup was taken is replaced, and the site is down until the replay is over.") {
		t.Errorf("question: %q", q)
	}
	if db, replays, _, _ := s.world(); db != "data-1" || !slices.Equal(replays, []string{"data-1"}) {
		t.Errorf("database %s, replays %v", db, replays)
	}
}

// Killed after the verification passed: recover records the upgrade as the
// run would have, without touching the stack.
func TestRecoverRecordsARunThatPassedItsVerification(t *testing.T) {
	s := newStack(t, "", rel{version: "1.0.0"}, rel{version: "1.1.0"})
	s.cutUpgrade(s.runner(), isStep(KindStepDone, StepVerify))
	if j := s.journal(); j == nil || j.Phase != instance.PhaseRecord || s.state().Current != "1.0.0" {
		t.Fatalf("journal: %+v", j)
	}
	s.fresh()
	commands := len(s.f.commands())
	if err := s.recover(s.runner(func(o *Options) { o.Yes = false })); err != nil {
		t.Fatalf("recover: %v", err)
	}
	s.ended(nil)
	s.back("1.1.0")
	if q := s.rep.questions; len(q) != 1 || q[0] != "Record the upgrade to 1.1.0, which passed its verification before kvsctl stopped?" {
		t.Errorf("question: %q", q)
	}
	if len(s.f.commands()) != commands {
		t.Errorf("recover ran docker: %v", s.f.commands()[commands:])
	}
	state := s.state()
	if state.Previous != "1.0.0" || !strings.Contains(state.UpgradeBackup, "backup-1.0.0-") {
		t.Errorf("state: previous %s, backup %s", state.Previous, state.UpgradeBackup)
	}
	if env := s.env(); env["KVS_STACK_VERSION"] != "1.1.0" {
		t.Errorf("KVS_STACK_VERSION = %q", env["KVS_STACK_VERSION"])
	}
}

// Killed while it rolled back a failed upgrade: recover runs the rollback
// again, and the history keeps why the upgrade failed.
func TestRecoverAfterACutDuringTheRollback(t *testing.T) {
	s := newStack(t, "", rel{version: "1.0.0"}, rel{version: "1.1.0"})
	s.f.behave(registry+"php:1.1.0-php8.1", behavior{unhealthy: true})
	s.cutUpgrade(s.runner(quick), isLog("does not change the database"))
	if j := s.journal(); j == nil || j.Phase != instance.PhaseRollback {
		t.Fatalf("journal: %+v", j)
	}
	s.fresh()
	if err := s.recover(s.runner(quick)); err != nil {
		t.Fatalf("recover: %v", err)
	}
	s.back("1.0.0")
	history := s.state().History
	if last := history[len(history)-1]; last.Version != "1.0.0" || last.Note != "1.1.0 failed: not healthy after 300ms: kvs-php-fpm is unhealthy" {
		t.Errorf("history ends with %+v", last)
	}
	undid(t, s.state(), instance.ActionUpgrade, "1.1.0", instance.OutcomeFailed, "not healthy after 300ms: kvs-php-fpm is unhealthy")
}

// A journal whose run the state already records, which a crash between the
// two writes leaves, is only removed: the run is not done twice.
func TestRecoverRemovesTheJournalOfARunAlreadyRecorded(t *testing.T) {
	cases := []struct {
		name  string
		at    func(Event) bool
		fails bool
		want  string
	}{
		{"recorded", isStep(KindStepDone, StepVerify), false, "1.1.0"},
		{"rolled back", isLog("does not change the database"), true, "1.0.0"},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			s := newStack(t, "", rel{version: "1.0.0"}, rel{version: "1.1.0"})
			if c.fails {
				s.f.behave(registry+"php:1.1.0-php8.1", behavior{unhealthy: true})
			}
			journal := filepath.Join(s.root, "kvsctl", "journal.json")
			var saved []byte
			s.rep.on = func(e Event) {
				if c.at(e) {
					saved, _ = os.ReadFile(journal)
				}
			}
			_ = s.upgrade(s.runner(quick))
			if len(saved) == 0 || s.journal() != nil {
				t.Fatal("the journal was not captured, or not removed by the run")
			}
			if err := os.WriteFile(journal, saved, 0o600); err != nil {
				t.Fatal(err)
			}
			before := s.state()
			commands := len(s.f.commands())
			s.fresh()
			if err := s.recover(s.runner()); err != nil {
				t.Fatalf("recover: %v", err)
			}
			s.back(c.want)
			if !s.rep.said("the state already records its end") || len(s.f.commands()) != commands {
				t.Errorf("recover did more than remove the journal: %v", s.f.commands()[commands:])
			}
			if after := s.state(); len(after.History) != len(before.History) {
				t.Error("recover wrote the history again")
			}
		})
	}
}

// The same for a manual rollback, killed between the write of its record
// and the removal of its journal: the entry it added to the history is
// dated by the start of the rollback, which names it, so recover finds
// the rollback recorded and only removes the journal.
func TestRecoverRemovesTheJournalOfARecordedRollback(t *testing.T) {
	s := newStack(t, "", rel{version: "1.0.0"}, rel{version: "1.1.0"})
	if err := s.upgrade(s.runner()); err != nil {
		t.Fatalf("upgrade: %v", err)
	}
	journal := filepath.Join(s.root, "kvsctl", "journal.json")
	var saved []byte
	s.fresh().on = func(e Event) {
		if e.Kind == KindStepDone && e.Step == StepVerify {
			saved, _ = os.ReadFile(journal)
		}
	}
	if err := s.rollback(s.runner()); err != nil {
		t.Fatalf("rollback: %v", err)
	}
	if len(saved) == 0 || s.journal() != nil {
		t.Fatal("the journal was not captured, or not removed by the rollback")
	}
	if err := os.WriteFile(journal, saved, 0o600); err != nil {
		t.Fatal(err)
	}
	before := s.state()
	commands := len(s.f.commands())
	s.fresh()
	if err := s.recover(s.runner()); err != nil {
		t.Fatalf("recover: %v", err)
	}
	s.back("1.0.0")
	if !s.rep.said("the state already records its end") || len(s.f.commands()) != commands {
		t.Errorf("recover did more than remove the journal: %v", s.f.commands()[commands:])
	}
	if after := s.state(); len(after.History) != len(before.History) {
		t.Errorf("the history went from %d to %d entries", len(before.History), len(after.History))
	}
}

// The entry a run adds to the history carries the start of the run, which
// names it: an entry another run wrote while the clock was ahead, dated
// after this run began, does not pass for its end. The automatic rollback
// of this run, killed once its journal said so, is run again by recover.
func TestRecoverIsNotFooledByAnEntryFromTheFuture(t *testing.T) {
	s := newStack(t, "", rel{version: "1.0.0"}, rel{version: "1.1.0", database: migrates})
	state := s.state()
	state.History = append(state.History, instance.Entry{Version: "1.0.0", Action: instance.ActionRollback, Date: time.Now().UTC().Add(time.Hour), Note: "written while the clock was ahead"})
	r := s.runner()
	if err := r.Inst.SaveState(state); err != nil {
		t.Fatal(err)
	}
	s.f.behave(registry+"php:1.1.0-php8.1", behavior{migrate: "data-1 migrated by 1.1.0"})
	s.cutUpgrade(s.runner(), isStep(KindStepStart, StepVerify))
	// The automatic rollback began: its journal says so, and nothing of
	// it ran yet.
	j := s.journal()
	j.Phase = instance.PhaseRollback
	if err := r.Inst.SaveJournal(j); err != nil {
		t.Fatal(err)
	}
	s.fresh()
	if err := s.recover(s.runner()); err != nil {
		t.Fatalf("recover: %v", err)
	}
	s.back("1.0.0")
	if db, replays, _, _ := s.world(); db != "data-1" || len(replays) != 1 {
		t.Errorf("database %q, replays %v", db, replays)
	}
	history := s.state().History
	if last := history[len(history)-1]; last.Action != instance.ActionRollback || !last.Date.Equal(j.Started) || last.Note != "1.1.0 was interrupted during rollback" {
		t.Errorf("history ends with %+v, the run began %s", last, j.Started)
	}
	undid(t, s.state(), instance.ActionUpgrade, "1.1.0", instance.OutcomeInterrupted, "interrupted during rollback")
}

// A run whose journal began under a clock that was ahead, corrected before
// the run was recorded, is still recognised as recorded by the entry it
// added: recover only removes its journal, for an upgrade as for a
// re-apply, which it neither refuses nor records twice.
func TestRecoverRecognisesARunRecordedAfterTheClockWentBack(t *testing.T) {
	cases := []struct {
		name string
		opts []func(*Options)
		want string
	}{
		{"upgrade", nil, "1.1.0"},
		{"re-apply", []func(*Options){func(o *Options) { o.Version = "1.0.0" }}, "1.0.0"},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			s := newStack(t, "", rel{version: "1.0.0", php: []string{"8.1", "8.3"}}, rel{version: "1.1.0"})
			if c.want == "1.0.0" {
				s.setEnv("PHP_VERSION", "8.3")
			}
			s.cutUpgrade(s.runner(c.opts...), isStep(KindStepDone, StepVerify))
			r := s.runner()
			j := s.journal()
			if j == nil || j.Phase != instance.PhaseRecord {
				t.Fatalf("journal: %+v", j)
			}
			j.Started = j.Started.Add(time.Hour)
			if err := r.Inst.SaveJournal(j); err != nil {
				t.Fatal(err)
			}
			journal := filepath.Join(s.root, "kvsctl", "journal.json")
			saved, err := os.ReadFile(journal)
			if err != nil {
				t.Fatal(err)
			}
			s.fresh()
			if err := s.recover(s.runner()); err != nil {
				t.Fatalf("recover: %v", err)
			}
			// Killed between the record and the removal of the journal.
			if err := os.WriteFile(journal, saved, 0o600); err != nil {
				t.Fatal(err)
			}
			before := s.state()
			s.fresh()
			if err := s.recover(s.runner()); err != nil {
				t.Fatalf("recover once the run is recorded: %v", err)
			}
			if !s.rep.said("the state already records its end") {
				t.Errorf("recover did more than remove the journal: %v", s.rep.logs())
			}
			s.back(c.want)
			if after := s.state(); len(after.History) != len(before.History) {
				t.Errorf("the history went from %d to %d entries", len(before.History), len(after.History))
			}
		})
	}
}

// olderJournal rewrites the journal on disk the way a kvsctl older than its
// format wrote it: the fields that kvsctl knew, and no format.
func (s *stack) olderJournal() {
	s.t.Helper()
	path := filepath.Join(s.root, "kvsctl", "journal.json")
	data, err := os.ReadFile(path)
	if err != nil {
		s.t.Fatal(err)
	}
	var fields map[string]json.RawMessage
	if err := json.Unmarshal(data, &fields); err != nil {
		s.t.Fatal(err)
	}
	known := []string{"action", "from", "to", "started", "updated", "phase", "log", "backup", "replay", "applied", "compose_started", "mariadb", "mariadb_recreated", "one_way", "database", "restore_db", "files", "images_before", "images_after", "compose_file_before", "pins", "ignored"}
	for key := range fields {
		if !slices.Contains(known, key) {
			delete(fields, key)
		}
	}
	if data, err = json.MarshalIndent(fields, "", "  "); err != nil {
		s.t.Fatal(err)
	}
	if err := os.WriteFile(path, data, 0o600); err != nil {
		s.t.Fatal(err)
	}
}

// A journal an older kvsctl left, after a crash between the write of the
// state and the removal of the journal: that kvsctl dated the entry the
// run adds to the history when it wrote it, a moment after the start of
// the run. recover, on a binary swapped by hand meanwhile, takes the run
// for finished by the rule of that kvsctl: it only removes the journal,
// and never replays a rollback the state records over what the site wrote
// since, refuses an upgrade it records, or records a re-apply twice. A run
// that journal names and the state does not record is still undone.
func TestRecoverOfAJournalAnOlderKvsctlWrote(t *testing.T) {
	cases := []struct {
		name             string
		installed, newer rel
		php              string
		opts             []func(*Options)
		// at is where the journal is copied, in the phase it is left in.
		at func(s *stack) func(Event) bool
		// recorded is whether the run went on and the state records it.
		recorded bool
		want     string
	}{
		{
			name: "rollback recorded", installed: rel{version: "1.0.0"}, newer: rel{version: "1.1.0", database: migrates},
			at: func(s *stack) func(Event) bool {
				return func(e Event) bool {
					j := s.journal()
					return e.Kind == KindLog && j != nil && j.Phase == instance.PhaseRollback
				}
			},
			recorded: true, want: "1.0.0",
		},
		{
			name: "upgrade recorded", installed: rel{version: "1.0.0"}, newer: rel{version: "1.1.0"},
			at:       func(*stack) func(Event) bool { return isStep(KindStepDone, StepVerify) },
			recorded: true, want: "1.1.0",
		},
		{
			name: "re-apply recorded", installed: rel{version: "1.0.0", php: []string{"8.1", "8.3"}}, newer: rel{version: "1.1.0"},
			php: "8.3", opts: []func(*Options){func(o *Options) { o.Version = "1.0.0" }},
			at:       func(*stack) func(Event) bool { return isStep(KindStepDone, StepVerify) },
			recorded: true, want: "1.0.0",
		},
		{
			name: "upgrade not recorded", installed: rel{version: "1.0.0"}, newer: rel{version: "1.1.0"},
			at:   func(*stack) func(Event) bool { return isStep(KindStepStart, StepVerify) },
			want: "1.0.0",
		},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			s := newStack(t, "", c.installed, c.newer)
			if c.php != "" {
				s.setEnv("PHP_VERSION", c.php)
			}
			if c.name == "rollback recorded" {
				s.f.behave(registry+"php:1.1.0-php8.1", behavior{unhealthy: true, migrate: "data-1 migrated by 1.1.0"})
			}
			journal := filepath.Join(s.root, "kvsctl", "journal.json")
			var saved []byte
			at := c.at(s)
			if c.recorded {
				s.rep.on = func(e Event) {
					if saved == nil && at(e) {
						saved, _ = os.ReadFile(journal)
					}
				}
				_ = s.upgrade(s.runner(append([]func(*Options){quick}, c.opts...)...))
				s.rep.on = nil
				if saved == nil || s.journal() != nil {
					t.Fatal("the journal was not copied, or not removed by the run")
				}
				if err := os.WriteFile(journal, saved, 0o600); err != nil {
					t.Fatal(err)
				}
			} else {
				s.cutUpgrade(s.runner(c.opts...), at)
			}
			s.olderJournal()
			j := s.journal()
			if j.Format != 0 {
				t.Fatalf("the journal of the older kvsctl has format %d", j.Format)
			}
			state := s.state()
			if c.recorded {
				last := &state.History[len(state.History)-1]
				if !last.Date.Equal(j.Started) {
					t.Fatalf("the entry of the run is dated %s, it began %s", last.Date, j.Started)
				}
				last.Date = j.Started.Add(3 * time.Second)
				if err := s.runner().Inst.SaveState(state); err != nil {
					t.Fatal(err)
				}
			}
			s.writeData("data-3")
			_, replays, _, _ := s.world()
			s.fresh()
			if err := s.recover(s.runner()); err != nil {
				t.Fatalf("recover: %v", err)
			}
			s.back(c.want)
			after := s.state()
			if !c.recorded {
				if last := after.History[len(after.History)-1]; len(after.History) != len(state.History)+1 || last.Action != instance.ActionRollback || !last.Date.Equal(j.Started) {
					t.Errorf("the run was not undone: history %+v", after.History)
				}
				return
			}
			if !s.rep.said("the state already records its end") || len(after.History) != len(state.History) {
				t.Errorf("recover did more than remove the journal: history from %d to %d entries, log %v", len(state.History), len(after.History), s.rep.logs())
			}
			if db, now, _, _ := s.world(); db != "data-3" || len(now) != len(replays) {
				t.Errorf("database %q, replays %v then %v: what the site wrote since was replaced", db, replays, now)
			}
		})
	}
}

func TestRecoverWithoutAJournal(t *testing.T) {
	s := newStack(t, "", rel{version: "1.0.0"})
	err := s.recover(s.runner())
	if err == nil || err.Error() != "nothing to recover: no run was interrupted" {
		t.Errorf("err = %v", err)
	}
	s.ended(err)
}

// A journal that does not start from the installed version cannot be
// undone safely: recover says what to do by hand instead.
func TestRecoverRefusesAJournalFromAnotherVersion(t *testing.T) {
	s := newStack(t, "", rel{version: "1.0.0"})
	r := s.runner()
	if err := r.Inst.SaveJournal(&instance.Journal{Action: instance.ActionUpgrade, From: "0.9.0", To: "1.0.0", Phase: instance.PhaseVerify, Log: "/var/log/kvsctl-test.log"}); err != nil {
		t.Fatal(err)
	}
	err := s.recover(r)
	if err == nil || !strings.Contains(err.Error(), "the state records 1.0.0 as installed") || !strings.Contains(err.Error(), "/var/log/kvsctl-test.log") || !strings.Contains(err.Error(), "journal.json") {
		t.Errorf("err = %v", err)
	}
	if s.journal() == nil {
		t.Error("the journal was removed")
	}
}

// The screen of recover shows the steps it runs: a restore is finished and
// its stack verified, whatever phase it reached, not rolled back.
func TestRecoverSteps(t *testing.T) {
	if got := RecoverSteps(&instance.Journal{Phase: instance.PhaseRecord}); !slices.Equal(got, []string{StepConfirm, StepRecord}) {
		t.Errorf("record phase: %v", got)
	}
	for _, phase := range []string{instance.PhaseApply, instance.PhaseRestart, instance.PhaseVerify, instance.PhaseRollback} {
		if got := RecoverSteps(&instance.Journal{Phase: phase}); !slices.Equal(got, []string{StepConfirm, StepRollbck}) {
			t.Errorf("%s phase: %v", phase, got)
		}
	}
	for _, phase := range []string{instance.PhaseBackup, instance.PhaseReplay, instance.PhaseRestart} {
		if got := RecoverSteps(&instance.Journal{Action: instance.ActionRestore, Phase: phase}); !slices.Equal(got, []string{StepConfirm, StepRestore, StepVerify}) {
			t.Errorf("a restore in its %s phase: %v", phase, got)
		}
	}
}

// An upgrade that failed and was rolled back is tried again: the second
// attempt fails too, and its automatic rollback is killed once the files
// went back, before the replay. The rollback the history records is the
// one of the first attempt, not the end of this one: recover runs the
// rollback again and replays the backup over what the second attempt did
// to the database.
func TestRecoverAfterASecondAttemptCutDuringItsRollback(t *testing.T) {
	s := newStack(t, "", rel{version: "1.0.0"}, rel{version: "1.1.0", database: migrates})
	s.f.behave(registry+"php:1.1.0-php8.1", behavior{unhealthy: true, migrate: "data-1 migrated by 1.1.0"})
	if err := s.upgrade(s.runner(quick)); !errors.Is(err, ErrRolledBack) {
		t.Fatalf("first attempt: %v", err)
	}
	if history := s.state().History; history[len(history)-1].Action != instance.ActionRollback {
		t.Fatalf("the first attempt left no rollback in the history: %+v", history)
	}
	s.fresh()
	s.cutUpgrade(s.runner(quick), isLog("1.1.0 changes the database: "))
	j := s.journal()
	if j == nil || j.Phase != instance.PhaseRollback || s.file("docker/RELEASE") != "1.0.0\n" || s.running("nginx") != s.pin("1.1.0", "nginx") {
		t.Fatalf("after the cut: journal %+v, RELEASE %q, nginx on %s", j, s.file("docker/RELEASE"), s.running("nginx"))
	}
	if db, _, _, _ := s.world(); db != "data-1 migrated by 1.1.0" {
		t.Fatalf("the second attempt did not run: %q", db)
	}
	s.fresh()
	if err := s.recover(s.runner(quick)); err != nil {
		t.Fatalf("recover: %v", err)
	}
	s.back("1.0.0")
	if db, replays, _, _ := s.world(); db != "data-1" || len(replays) != 2 {
		t.Errorf("after recover: database %q, replays %v, want the backup replayed again", db, replays)
	}
	if s.rep.said("the state already records its end") {
		t.Error("recover took the rollback of the first attempt for the end of the second")
	}
}

// A series change killed while kvsctl waited for MariaDB alone on the new
// series, after which the operator ran 'docker compose down': the journal
// says compose started but not whether MariaDB was recreated, and no
// container is left to tell. A mariadb container that cannot be inspected
// counts as recreated, so recover moves aside the data files the newer
// server opened and replays the backup, and does not start the older
// server on them.
func TestRecoverAfterComposeDownDuringASeriesChange(t *testing.T) {
	s := newStack(t, "11.8", rel{version: "1.0.0"}, rel{version: "1.1.0"})
	s.f.behave("mariadb:12.3.3", behavior{ready: 2 * time.Second})
	s.cutUpgrade(s.runner(series("12.3")), isLog("waiting for the database"))
	j := s.journal()
	if j == nil || j.Phase != instance.PhaseRestart || !j.ComposeStarted || j.MariaDBRecreated {
		t.Fatalf("journal after the cut: %+v", j)
	}
	if _, _, _, dataSeries := s.world(); dataSeries != "12.3" {
		t.Fatalf("MariaDB did not open the data files on the new series: %s", dataSeries)
	}
	s.f.with(func(f *fakeDocker) { f.containers = map[string]*fakeContainer{} })
	s.fresh()
	if err := s.recover(s.runner(quick)); err != nil {
		t.Fatalf("recover: %v", err)
	}
	s.back("1.0.0")
	if db, replays, moved, dataSeries := s.world(); db != "data-1" || !slices.Equal(replays, []string{"data-1"}) || len(moved) != 1 || dataSeries != "11.8" {
		t.Errorf("after recover: database %q, replays %v, moved %v, series %s", db, replays, moved, dataSeries)
	}
	if !s.rep.said("MariaDB was recreated by a one-way run") {
		t.Errorf("recover did not say why it moves the data files: %v", s.rep.logs())
	}
}

// A rollback that fails is told as a failure, in the words compose gave,
// and kept as one. The journal it leaves says when it failed and why,
// which every refusal and recover repeat instead of calling the run
// interrupted when it began; the history recover writes once it finished
// the rollback keeps why the upgrade failed and why its rollback did.
func TestAFailedRollbackIsToldAndRecordedAsFailed(t *testing.T) {
	s := newStack(t, "", rel{version: "1.0.0"}, rel{version: "1.1.0"})
	s.f.behave(registry+"nginx:1.1.0", behavior{unhealthy: true})
	s.rep.on = func(e Event) {
		if e.Kind == KindStepStart && e.Step == StepRollbck {
			s.failOnce("compose up -d", "Error response from daemon: no space left on device")
		}
	}
	start := time.Now()
	err := s.upgrade(s.runner(quick))
	end := time.Now()
	failure := "docker compose up -d: exit status 1: Error response from daemon: no space left on device"
	if !errors.Is(err, ErrRollbackFailed) || !strings.HasPrefix(err.Error(), "upgrade to 1.1.0 failed: not healthy after 300ms: kvs-nginx is unhealthy; the rollback to 1.0.0 failed too: "+failure+"; ") {
		t.Fatalf("err = %v", err)
	}
	if got := s.rep.first(KindStepFail, StepRollbck); got != failure {
		t.Errorf("the rollback step failed with %q", got)
	}
	j := s.journal()
	if j == nil || j.Phase != instance.PhaseRollback || j.Failure != failure || j.Cause != "not healthy after 300ms: kvs-nginx is unhealthy" || j.Failed.Before(start) || j.Failed.After(end) {
		t.Fatalf("journal: %+v", j)
	}
	// A long run: it began two hours before its rollback failed, and is
	// dated by the failure.
	r := s.runner()
	j.Started = j.Started.Add(-2 * time.Hour)
	if err := r.Inst.SaveJournal(j); err != nil {
		t.Fatal(err)
	}
	state := s.state()
	want := fmt.Sprintf("the rollback of an upgrade from 1.0.0 to 1.1.0 failed on %s UTC: %s", j.Failed.UTC().Format("2006-01-02 15:04"), failure)
	if got := j.Describe(state); got != want {
		t.Errorf("the journal reads %q, want %q", got, want)
	}
	if err := r.noJournal(state); err == nil || err.Error() != want+"; once the cause is fixed, run 'kvsctl recover'" {
		t.Errorf("refusal: %v", err)
	}

	s.fresh()
	if err := s.recover(s.runner(quick, func(o *Options) { o.Yes = false })); err != nil {
		t.Fatalf("recover: %v", err)
	}
	s.back("1.0.0")
	if got := s.rep.first(KindStepStart, StepConfirm); got != capitalize(want) {
		t.Errorf("recover asks under %q", got)
	}
	history := s.state().History
	if last := history[len(history)-1]; last.Action != instance.ActionRollback || last.Note != "1.1.0 failed: not healthy after 300ms: kvs-nginx is unhealthy; its rollback failed first ("+failure+"), and recover finished it" {
		t.Errorf("history ends with %+v", last)
	}
	// The run failed by itself: recover, finishing its rollback, records
	// it as failed, with the cause of the run and not where it stopped.
	undid(t, s.state(), instance.ActionUpgrade, "1.1.0", instance.OutcomeFailed, "not healthy after 300ms: kvs-nginx is unhealthy")
}

// A run the operator cancelled whose rollback failed too is still a
// cancelled run once recover finished that rollback: the journal keeps how
// the run ended with why, and the history says it, so status asks for no
// cause to be fixed before the upgrade runs again.
func TestACancelledRunStaysCancelledThroughRecover(t *testing.T) {
	s := newStack(t, "", rel{version: "1.0.0"}, rel{version: "1.1.0"})
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	s.rep.on = func(e Event) {
		switch {
		case isStep(KindStepStart, StepVerify)(e):
			cancel()
		case isStep(KindStepStart, StepRollbck)(e):
			s.failOnce("compose up -d", "Error response from daemon: no space left on device")
		}
	}
	r := s.runner(quick)
	state, plan := s.plan(r)
	err := r.Run(ctx, state, plan)
	if !errors.Is(err, ErrRollbackFailed) || !strings.HasPrefix(err.Error(), "upgrade to 1.1.0 was cancelled; the rollback to 1.0.0 failed too: ") {
		t.Fatalf("err = %v", err)
	}
	j := s.journal()
	if j == nil || j.Outcome != instance.OutcomeCancelled || !strings.Contains(j.Cause, "context canceled") {
		t.Fatalf("journal: %+v", j)
	}
	s.fresh()
	if err := s.recover(s.runner(quick)); err != nil {
		t.Fatalf("recover: %v", err)
	}
	s.back("1.0.0")
	undid(t, s.state(), instance.ActionUpgrade, "1.1.0", instance.OutcomeCancelled, j.Cause)
	if history := s.state().History; !strings.HasPrefix(history[len(history)-1].Note, "1.1.0 was cancelled: "+j.Cause+"; its rollback failed first (") {
		t.Errorf("the note says %q", history[len(history)-1].Note)
	}
}

// How a run ended comes from its journal: as it records it, cut short when
// it records no cause, and from the cause alone in the journal of a kvsctl
// that recorded no outcome.
func TestRunOutcome(t *testing.T) {
	const cancelled = "docker compose up -d: context canceled (signal: terminated)"
	for _, c := range []struct {
		j    instance.Journal
		want string
	}{
		{instance.Journal{Cause: "not healthy after 1s", Outcome: instance.OutcomeFailed}, instance.OutcomeFailed},
		{instance.Journal{Cause: "docker compose up -d: exit status 1: Error response from daemon: context canceled", Outcome: instance.OutcomeFailed}, instance.OutcomeFailed},
		{instance.Journal{Cause: cancelled, Outcome: instance.OutcomeCancelled}, instance.OutcomeCancelled},
		{instance.Journal{}, instance.OutcomeInterrupted},
		{instance.Journal{Cause: cancelled}, instance.OutcomeCancelled},
		{instance.Journal{Cause: "not healthy after 1s"}, instance.OutcomeFailed},
	} {
		if got := runOutcome(&c.j); got != c.want {
			t.Errorf("cause %q, outcome %q: %s, want %s", c.j.Cause, c.j.Outcome, got, c.want)
		}
	}
}

// Before it undoes a run, recover says what it does with the database by
// the rule it applies: a release that does not change the database leaves
// it as it is, even when its code ran; one that does has the backup
// replayed over what was written since; a run cut before compose started
// touched neither the containers nor the database.
func TestRecoverQuestionSaysWhatHappensToTheDatabase(t *testing.T) {
	ask := regexp.QuoteMeta("Return the stack to 1.0.0, undoing what the upgrade to 1.1.0 did? ")
	cases := []struct {
		name    string
		release rel
		cut     func(Event) bool
		says    string
		db      string
		replays int
	}{
		{"plain release that ran", rel{version: "1.1.0"}, isStep(KindStepStart, StepVerify),
			regexp.QuoteMeta("1.1.0 does not change the database, it is left as it is."), "data-1 written by 1.1.0", 0},
		{"release that changes the database", rel{version: "1.1.0", database: migrates}, isStep(KindStepStart, StepVerify),
			`1\.1\.0 changes the database: backup-1\.0\.0-\d{8}-\d{6}\.tar is replayed\. ` + regexp.QuoteMeta("What was written to the database since that backup was taken is replaced, and the site is down until the replay is over."), "data-1", 1},
		{"cut before compose started", rel{version: "1.1.0", database: migrates}, isStep(KindStepDone, StepApply),
			regexp.QuoteMeta("Compose never started: the containers and the database were not touched."), "data-1", 0},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			s := newStack(t, "", rel{version: "1.0.0"}, c.release)
			s.f.behave(registry+"php:1.1.0-php8.1", behavior{migrate: "data-1 written by 1.1.0"})
			s.cutUpgrade(s.runner(), c.cut)
			s.fresh()
			if err := s.recover(s.runner(func(o *Options) { o.Yes = false })); err != nil {
				t.Fatalf("recover: %v", err)
			}
			s.back("1.0.0")
			if q := s.rep.questions; len(q) != 1 || !regexp.MustCompile("^"+ask+c.says+"$").MatchString(q[0]) {
				t.Errorf("question: %q", q)
			}
			if db, replays, _, _ := s.world(); db != c.db || len(replays) != c.replays {
				t.Errorf("database %q, replays %v", db, replays)
			}
		})
	}
}
