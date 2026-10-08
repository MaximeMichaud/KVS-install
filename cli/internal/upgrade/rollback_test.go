package upgrade

import (
	"bytes"
	"context"
	"errors"
	"io/fs"
	"maps"
	"os"
	"os/exec"
	"path/filepath"
	"regexp"
	"slices"
	"strings"
	"testing"

	"github.com/MaximeMichaud/KVS-install/cli/internal/backup"
	"github.com/MaximeMichaud/KVS-install/cli/internal/instance"
)

// writeData stands for what the site wrote to its database since the last
// change: a dump taken now holds label.
func (s *stack) writeData(label string) {
	s.f.with(func(f *fakeDocker) { f.db = label })
}

// backupNow takes a backup labelled version of what the database holds.
func (s *stack) backupNow(version string) string {
	s.t.Helper()
	inst, err := instance.Detect(s.root)
	if err != nil {
		s.t.Fatal(err)
	}
	result, err := backup.Create(context.Background(), inst.BackupDir(), version, "kvs-mariadb", inst.EnvPath, filepath.Join(inst.StateDir(), "state.json"), nil)
	if err != nil {
		s.t.Fatal(err)
	}
	return result.Path
}

// holds replays an archive into the fake and reports what its dump holds.
func (s *stack) holds(archive string) string {
	s.t.Helper()
	var before string
	s.f.with(func(f *fakeDocker) { before = f.db })
	if err := backup.RestoreDatabase(context.Background(), archive, "kvs-mariadb", nil); err != nil {
		s.t.Fatal(err)
	}
	var label string
	s.f.with(func(f *fakeDocker) {
		label = f.db
		f.db = before
		f.replays = f.replays[:len(f.replays)-1]
		f.replayedWith = f.replayedWith[:len(f.replayedWith)-1]
	})
	return label
}

// A manual rollback of a release that changed the database replays the
// exact archive its upgrade took, not the newest backup of the previous
// version, and backs up the live database first, labelled with the version
// it leaves. Run again, it is refused: it would go forward.
func TestManualRollbackReplaysTheExactArchive(t *testing.T) {
	s := newStack(t, "", rel{version: "1.0.0"}, rel{version: "1.1.0", database: migrates})
	if err := s.upgrade(s.runner()); err != nil {
		t.Fatalf("upgrade: %v", err)
	}
	upgradeBackup := s.state().UpgradeBackup
	s.writeData("decoy")
	decoy := s.backupNow("1.0.0")
	s.writeData("data-2")

	// The newest backup of 1.0.0 is the decoy: that is what a state that
	// names no archive falls back to, and only then.
	r := s.runner()
	state := s.state()
	if path, _, err := r.rollbackDump(state); err != nil || path != upgradeBackup {
		t.Errorf("rollbackDump = %s (%v), want the archive of the upgrade", path, err)
	}
	state.UpgradeBackup = ""
	if path, _, err := r.rollbackDump(state); err != nil || path != decoy {
		t.Errorf("without a recorded archive rollbackDump = %s (%v), want the newest backup of 1.0.0", path, err)
	}
	unreadable := filepath.Join(s.root, "backups", "backup-1.0.0-20260101-000000.tar")
	if err := os.WriteFile(unreadable, []byte("not an archive"), 0o600); err != nil {
		t.Fatal(err)
	}
	state.UpgradeBackup = unreadable
	if _, _, err := r.rollbackDump(state); err == nil || !strings.Contains(err.Error(), "cannot be read") {
		t.Errorf("an unreadable archive was accepted: %v", err)
	}

	s.fresh()
	err := s.rollback(s.runner(func(o *Options) { o.Yes = false }))
	if err != nil {
		t.Fatalf("rollback: %v", err)
	}
	s.ended(nil)
	s.back("1.0.0")
	q := s.rep.questions
	if len(q) != 1 || !strings.HasPrefix(q[0], "Roll back to 1.0.0 and replay "+filepath.Base(upgradeBackup)+", taken ") ||
		!strings.HasSuffix(q[0], "What was written to the database since then is replaced; a backup of it is taken first.") {
		t.Errorf("question: %q", q)
	}
	if db, _, moved, _ := s.world(); db != "data-1" || len(moved) != 0 {
		t.Errorf("the database holds %s after the rollback (moved %v), want the archive of the upgrade", db, moved)
	}
	safety, err := backup.Latest(filepath.Join(s.root, "backups"), "1.1.0")
	if err != nil || safety == "" {
		t.Fatalf("no backup of 1.1.0 was taken: %v", err)
	}
	if got := s.holds(safety); got != "data-2" {
		t.Errorf("the safety backup holds %s, want the live database of 1.1.0", got)
	}

	state = s.state()
	if state.Previous != "1.1.0" || state.UpgradeBackup != "" || state.Database != "" || state.OneWay {
		t.Errorf("state after the rollback: previous %s, backup %q, database %q, one way %v", state.Previous, state.UpgradeBackup, state.Database, state.OneWay)
	}
	if last := state.History[len(state.History)-1]; last.Action != instance.ActionRollback || last.Note != "by hand from 1.1.0, the database of 1.1.0 is in "+filepath.Base(safety) {
		t.Errorf("history ends with %+v", last)
	}

	s.fresh()
	err = s.rollback(s.runner())
	if err == nil || !strings.Contains(err.Error(), "kvsctl upgrade --version 1.1.0") {
		t.Errorf("a second rollback was not refused: %v", err)
	}
	s.ended(err)
}

// A rollback of a release that left the database alone replays nothing
// and takes no backup.
func TestManualRollbackOfAPlainRelease(t *testing.T) {
	s := newStack(t, "", rel{version: "1.0.0"}, rel{version: "1.1.0"})
	if err := s.upgrade(s.runner()); err != nil {
		t.Fatalf("upgrade: %v", err)
	}
	s.writeData("data-2")
	s.fresh()
	if err := s.rollback(s.runner(func(o *Options) { o.Yes = false })); err != nil {
		t.Fatalf("rollback: %v", err)
	}
	s.back("1.0.0")
	if q := s.rep.questions; len(q) != 1 || q[0] != "Roll back to 1.0.0? The database is left as it is." {
		t.Errorf("question: %q", q)
	}
	if db, replays, _, _ := s.world(); db != "data-2" || len(replays) != 0 {
		t.Errorf("database %s, replays %v", db, replays)
	}
	if path, _ := backup.Latest(filepath.Join(s.root, "backups"), "1.1.0"); path != "" {
		t.Errorf("a backup was taken: %s", path)
	}
	// MariaDB keeps its image: it is not started alone first, and nothing
	// waits for it on its own.
	if s.ran("compose up -d mariadb") >= 0 {
		t.Errorf("MariaDB was started alone: %v", s.f.commands())
	}
}

// A MariaDB that runs and fails its health check stops a manual rollback
// before its first change, --allow-unhealthy or not: the services that
// need it wait for it to be healthy, so compose could start none of them
// and the site would stay down, whichever version it starts.
func TestManualRollbackRefusesAnUnhealthyMariaDB(t *testing.T) {
	for _, allow := range []bool{false, true} {
		s := newStack(t, "", rel{version: "1.0.0"}, rel{version: "1.1.0", database: migrates})
		if err := s.upgrade(s.runner()); err != nil {
			t.Fatalf("upgrade: %v", err)
		}
		s.restartWith("mariadb", behavior{unhealthy: true})
		s.fresh()
		before := len(s.f.commands())
		err := s.rollback(s.runner(quick, func(o *Options) { o.AllowUnhealthy = allow }))
		if err == nil || errors.Is(err, ErrRollbackFailed) || !strings.HasPrefix(err.Error(), "kvs-mariadb is unhealthy: the services that need MariaDB wait for it to be healthy") ||
			!strings.HasSuffix(err.Error(), "nothing was changed, the stack is still on 1.1.0") {
			t.Errorf("--allow-unhealthy %v: %v", allow, err)
		}
		s.ended(err)
		s.back("1.1.0")
		if path, _ := backup.Latest(filepath.Join(s.root, "backups"), "1.1.0"); path != "" {
			t.Errorf("--allow-unhealthy %v: a backup was taken: %s", allow, path)
		}
		for _, cmd := range s.f.commands()[before:] {
			if cmd != "compose config --services" {
				t.Errorf("--allow-unhealthy %v: the rollback ran %q", allow, cmd)
			}
		}
	}
}

// A manual rollback that puts back the MariaDB image of the version
// before starts MariaDB alone on it first, and the services that need it
// once it is healthy: a MariaDB the newer image left unhealthy is no
// reason to refuse it, since the rollback is the repair, --allow-unhealthy
// or not.
func TestManualRollbackRepairsMariaDBWithThePreviousImage(t *testing.T) {
	for _, allow := range []bool{false, true} {
		s := newStack(t, "11.8", rel{version: "1.0.0", mariadb: map[string]string{"11.8": "11.8.9"}}, rel{version: "1.1.0", mariadb: map[string]string{"11.8": "11.8.10"}})
		if err := s.upgrade(s.runner()); err != nil {
			t.Fatalf("upgrade: %v", err)
		}
		s.f.behave("mariadb:11.8.10", behavior{unhealthy: true})
		s.restartWith("mariadb", behavior{unhealthy: true})
		s.writeData("data-2")
		s.fresh()
		before := len(s.f.commands())
		if err := s.rollback(s.runner(quick, func(o *Options) { o.AllowUnhealthy = allow })); err != nil {
			t.Fatalf("--allow-unhealthy %v: %v", allow, err)
		}
		s.back("1.0.0")
		commands := s.f.commands()[before:]
		alone, all := slices.Index(commands, "compose up -d mariadb"), slices.Index(commands, "compose up -d")
		if alone < 0 || all < alone {
			t.Errorf("--allow-unhealthy %v: MariaDB was not brought up alone first: %v", allow, commands)
		}
		if !s.rep.said("kvs-mariadb is unhealthy: the rollback starts MariaDB alone first, as 1.0.0 runs it, and the services that need it once it is healthy") {
			t.Errorf("--allow-unhealthy %v: the state of MariaDB was not said: %v", allow, s.rep.logs())
		}
		if db, replays, _, _ := s.world(); db != "data-2" || len(replays) != 0 {
			t.Errorf("--allow-unhealthy %v: database %q, replays %v", allow, db, replays)
		}
	}
}

// A rollback that replays an archive backs up the live database first,
// which a MariaDB that fails its health check cannot give: one that puts
// back another MariaDB, or recreates its data directory, is refused before
// its first change all the same, and names --no-backup, which rolls back
// without that backup on the MariaDB of the version before, or on a fresh
// data directory. A one-way rollback keeps the data files of the version
// it leaves aside in the data volume. broken is the MariaDB image of the
// newer version, which fails its health check in every container; without
// one, only the running container fails, as when its data files are the
// cause.
func TestManualRollbackBacksUpOnlyAMariaDBThatAnswers(t *testing.T) {
	cases := []struct {
		name, series, broken string
		installed, newer     rel
		opts                 []func(*Options)
	}{
		{
			name: "release that changes the database", series: "11.8", broken: "mariadb:11.8.10",
			installed: rel{version: "1.0.0", mariadb: map[string]string{"11.8": "11.8.9"}},
			newer:     rel{version: "1.1.0", database: migrates, mariadb: map[string]string{"11.8": "11.8.10"}},
		},
		{
			name: "series change", series: "11.8", broken: "mariadb:12.3.3",
			installed: rel{version: "1.0.0"}, newer: rel{version: "1.1.0"},
			opts: []func(*Options){series("12.3")},
		},
		{
			name: "one-way release", series: "11.8",
			installed: rel{version: "1.0.0"}, newer: rel{version: "1.1.0", oneWay: true},
		},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			s := newStack(t, c.series, c.installed, c.newer)
			if err := s.upgrade(s.runner(c.opts...)); err != nil {
				t.Fatalf("upgrade: %v", err)
			}
			oneWay := s.state().OneWay
			s.writeData("data-2")
			if c.broken != "" {
				s.f.behave(c.broken, behavior{unhealthy: true})
			}
			s.restartWith("mariadb", behavior{unhealthy: true})
			s.fresh()
			before := len(s.f.commands())
			err := s.rollback(s.runner(quick))
			if err == nil || errors.Is(err, ErrRollbackFailed) || !strings.HasPrefix(err.Error(), "kvs-mariadb is unhealthy: the rollback backs up the live database before it replays backup-1.0.0-") ||
				!strings.Contains(err.Error(), "repair MariaDB first (read 'docker logs kvs-mariadb'), or pass --no-backup to roll back without that backup") ||
				!strings.HasSuffix(err.Error(), "nothing was changed, the stack is still on 1.1.0") ||
				strings.Contains(err.Error(), "the data files of 1.1.0 then kept aside in the MariaDB data volume") != oneWay {
				t.Fatalf("err = %v", err)
			}
			s.back("1.1.0")
			if cmds := s.f.commands()[before:]; len(cmds) != 0 {
				t.Errorf("the refused rollback ran %v", cmds)
			}
			s.fresh()
			if err := s.rollback(s.runner(quick, func(o *Options) { o.NoBackup = true })); err != nil {
				t.Fatalf("rollback --no-backup: %v", err)
			}
			s.back("1.0.0")
			db, _, moved, dataSeries := s.world()
			if db != "data-1" || dataSeries != "11.8" || (len(moved) == 1) != oneWay {
				t.Errorf("after the rollback: database %q, series %s, moved %v", db, dataSeries, moved)
			}
		})
	}
}

// A manual rollback is the repair of a broken upgrade: an unhealthy
// service does not stop it from starting, and its verification judges
// every service. A service broken in both versions, for a reason that is
// not the release, is left out with --allow-unhealthy, and only that one.
func TestManualRollbackAcceptsWhatWasUnhealthyBefore(t *testing.T) {
	for _, allow := range []bool{false, true} {
		s := newStack(t, "", rel{version: "1.0.0"}, rel{version: "1.1.0"})
		if err := s.upgrade(s.runner()); err != nil {
			t.Fatalf("upgrade: %v", err)
		}
		s.restartWith("nginx", behavior{unhealthy: true})
		s.f.behave(registry+"nginx:1.0.0", behavior{unhealthy: true})
		s.fresh()
		err := s.rollback(s.runner(quick, func(o *Options) { o.AllowUnhealthy = allow }))
		if !allow {
			if !errors.Is(err, ErrRollbackFailed) || !strings.Contains(err.Error(), "failed part way: not healthy after 300ms: kvs-nginx is unhealthy") {
				t.Errorf("without --allow-unhealthy: %v", err)
			}
			continue
		}
		if err != nil {
			t.Fatalf("with --allow-unhealthy: %v", err)
		}
		s.back("1.0.0")
		if !s.rep.said("accepted as they are (--allow-unhealthy): kvs-nginx is unhealthy") || !s.rep.said("left out of the verification, unhealthy before the run: nginx") {
			t.Errorf("the accepted service was not named: %v", s.rep.logs())
		}
	}
}

// A series change end to end: MariaDB moves to the next series on request,
// alone first, with MARIADB_VERSION written next to the image; the manual
// rollback recreates the data directory for the previous server, replays
// the dump into MariaDB alone and puts MARIADB_VERSION back. Without
// --db-timeout, MariaDB has 30 minutes to be ready both ways, the time a
// change of series takes to upgrade its system tables. --no-backup is
// said in the question and honoured.
func TestMariaDBSeriesChangeAndBack(t *testing.T) {
	s := newStack(t, "11.8", rel{version: "1.0.0"}, rel{version: "1.1.0"})
	defaults := func(o *Options) { o.DBTimeout = 0 }
	r := s.runner(series("12.3"), defaults)
	state, plan := s.plan(r)
	if !plan.MariaDBUpgrade || !plan.OneWay || plan.Database != migrates || !plan.MariaDBImageChanges || plan.action() != "upgrade from 1.0.0 to 1.1.0 and move MariaDB from 11.8 to 12.3" {
		t.Fatalf("plan: %+v", plan)
	}
	if err := r.Run(context.Background(), state, plan); err != nil {
		t.Fatalf("upgrade: %v", err)
	}
	s.back("1.1.0")
	alone, all := s.ran("compose up -d mariadb"), s.ran("compose up -d")
	if alone < 0 || all < alone {
		t.Errorf("MariaDB was not brought up alone first: %v", s.f.commands())
	}
	if !s.rep.said("starting MariaDB alone first, the other services follow once it is healthy; MariaDB has 30m0s to be ready (--db-timeout)") {
		t.Errorf("the upgrade did not give MariaDB the budget of a series change: %v", s.rep.logs())
	}
	if _, _, _, dataSeries := s.world(); dataSeries != "12.3" {
		t.Errorf("the data files are on %s", dataSeries)
	}
	env := s.env()
	if env["MARIADB_VERSION"] != "12.3" || env["KVS_MARIADB_IMAGE"] != s.pin("1.1.0", "mariadb@12.3") {
		t.Errorf(".env after the series change: %v", env)
	}
	recorded := s.state()
	if recorded.Images[mariadbVersionKey] != "12.3" || recorded.PreviousImages[mariadbVersionKey] != "11.8" || !recorded.OneWay || recorded.Database != migrates {
		t.Errorf("state after the series change: %+v", recorded)
	}

	s.writeData("data-2")
	s.fresh()
	before := len(s.f.commands())
	if err := s.rollback(s.runner(defaults, func(o *Options) { o.Yes, o.NoBackup = false, true })); err != nil {
		t.Fatalf("rollback: %v", err)
	}
	s.back("1.0.0")
	if q := s.rep.questions; len(q) != 1 || !strings.Contains(q[0], "The MariaDB data directory is recreated first.") || !strings.HasSuffix(q[0], "replaced and lost: --no-backup takes no backup of it first.") {
		t.Errorf("question: %q", q)
	}
	commands := s.f.commands()[before:]
	alone, all = slices.Index(commands, "compose up -d mariadb"), slices.Index(commands, "compose up -d")
	if alone < 0 || all < alone {
		t.Errorf("the rollback did not bring MariaDB up alone first: %v", commands)
	}
	if !s.rep.said("starting MariaDB alone: the other services start once the database is in place; MariaDB has 30m0s to be ready (--db-timeout)") {
		t.Errorf("the rollback did not give MariaDB the budget of a series change: %v", s.rep.logs())
	}
	db, replays, moved, dataSeries := s.world()
	if db != "data-1" || replays[len(replays)-1] != "data-1" || len(moved) != 1 || dataSeries != "11.8" {
		t.Errorf("database %s, replays %v, moved %v, series %s", db, replays, moved, dataSeries)
	}
	if env := s.env(); env["MARIADB_VERSION"] != "11.8" || env["KVS_MARIADB_IMAGE"] != s.pin("1.0.0", "mariadb@11.8") {
		t.Errorf(".env after the rollback: %v", env)
	}
	if path, _ := backup.Latest(filepath.Join(s.root, "backups"), "1.1.0"); path != "" {
		t.Errorf("--no-backup took a backup: %s", path)
	}
	if last := s.state().History; last[len(last)-1].Note != "by hand from 1.1.0" {
		t.Errorf("history ends with %+v", last[len(last)-1])
	}
}

// A manual rollback that fails after its first change keeps its journal:
// recover returns the stack to the version it started from and replays the
// live database the rollback saved.
func TestManualRollbackFailingPartWayIsRecovered(t *testing.T) {
	s := newStack(t, "", rel{version: "1.0.0"}, rel{version: "1.1.0", database: migrates})
	if err := s.upgrade(s.runner()); err != nil {
		t.Fatalf("upgrade: %v", err)
	}
	s.writeData("data-2")
	s.f.behave(registry+"php:1.0.0-php8.1", behavior{unhealthy: true})
	s.fresh()
	err := s.rollback(s.runner(quick))
	if !errors.Is(err, ErrRollbackFailed) || !strings.Contains(err.Error(), "the rollback to 1.0.0 failed part way") ||
		!regexp.MustCompile(`'kvsctl recover' returns it to 1\.1\.0, replaying backup-1\.1\.0-\d{8}-\d{6}\.tar; log: `).MatchString(err.Error()) {
		t.Fatalf("err = %v", err)
	}
	s.ended(err)
	j := s.journal()
	if j == nil || j.Action != instance.ActionRollback || j.Phase != instance.PhaseVerify || !strings.Contains(j.Backup, "backup-1.1.0-") {
		t.Fatalf("journal: %+v", j)
	}
	if db, _, _, _ := s.world(); db != "data-1" {
		t.Fatalf("the rollback did not replay the archive of the upgrade: %s", db)
	}

	s.fresh()
	if err := s.recover(s.runner(quick)); err != nil {
		t.Fatalf("recover: %v", err)
	}
	s.back("1.1.0")
	if db, _, _, _ := s.world(); db != "data-2" {
		t.Errorf("the database holds %s, want the live one of 1.1.0", db)
	}
	// Both replays, the rollback's and the one recover undoes it with,
	// went in with nothing else running.
	_, replays := s.during()
	onlyMariaDB(t, "replay", replays)
	state := s.state()
	if state.Previous != "1.0.0" || state.UpgradeBackup == "" {
		t.Errorf("state after the recovery: %+v", state)
	}
	if last := state.History[len(state.History)-1]; last.Version != "1.1.0" || last.Action != instance.ActionRollback || last.Note != "the rollback to 1.0.0 failed: not healthy after 300ms: kvs-php-fpm is unhealthy" {
		t.Errorf("history ends with %+v", last)
	}
	undid(t, state, instance.ActionRollback, "1.0.0", instance.OutcomeFailed, "not healthy after 300ms: kvs-php-fpm is unhealthy")
	if !slices.ContainsFunc(s.rep.logs(), func(l string) bool { return strings.Contains(l, "the rollback replayed an older dump") }) {
		t.Error("recover did not say why it replays")
	}
}

// oneWayUpgraded is a stack that moved from MariaDB 11.8 on 1.0.0 to 12.3
// on 1.1.0, a one-way upgrade, and wrote data-2 since.
func oneWayUpgraded(t *testing.T) *stack {
	t.Helper()
	s := newStack(t, "11.8", rel{version: "1.0.0"}, rel{version: "1.1.0"})
	if err := s.upgrade(s.runner(series("12.3"))); err != nil {
		t.Fatalf("upgrade: %v", err)
	}
	if state := s.state(); !state.OneWay {
		t.Fatalf("the series change is not one way: %+v", state)
	}
	s.writeData("data-2")
	return s
}

// movedAlone fails the test unless nothing ran while the data files moved:
// MariaDB stopped, and no service that would write.
func (s *stack) movedAlone() {
	s.t.Helper()
	var moves [][]string
	s.f.with(func(f *fakeDocker) { moves = slices.Clone(f.movedWith) })
	if len(moves) == 0 {
		s.t.Error("no data file moved")
	}
	for i, running := range moves {
		if len(running) != 0 {
			s.t.Errorf("move %d of the data files ran while %v ran", i+1, running)
		}
	}
}

// A one-way rollback taken without a backup of the live database moves
// the data files of the newer version aside: they are the only copy of
// what it wrote. When that rollback fails, recover puts them back, the
// fresh files the older server wrote in a folder of their own, and starts
// the newer version on them: never on the fresh data directory.
func TestOneWayRollbackWithoutBackupFailingIsRecoveredOnItsDataFiles(t *testing.T) {
	s := oneWayUpgraded(t)
	s.f.behave(registry+"php:1.0.0-php8.1", behavior{unhealthy: true})
	s.fresh()
	err := s.rollback(s.runner(quick, func(o *Options) { o.NoBackup = true }))
	j := s.journal()
	if j == nil || j.DataFolder == "" || !j.DataMoved || !j.OneWay || j.Backup != "" {
		t.Fatalf("journal after the failed rollback: %+v", j)
	}
	if !errors.Is(err, ErrRollbackFailed) || !strings.Contains(err.Error(), "'kvsctl recover' returns it to 1.1.0, moving its data files back from "+j.DataFolder+" inside the MariaDB data volume") {
		t.Fatalf("err = %v", err)
	}
	if db, _, moved, dataSeries := s.world(); db != "data-1" || !slices.Equal(moved, []string{j.DataFolder}) || dataSeries != "11.8" {
		t.Fatalf("after the failed rollback: database %q, moved %v, series %s", db, moved, dataSeries)
	}

	s.fresh()
	if err := s.recover(s.runner(quick, func(o *Options) { o.Yes = false })); err != nil {
		t.Fatalf("recover: %v", err)
	}
	s.back("1.1.0")
	if q := s.rep.questions; len(q) != 1 || !strings.HasSuffix(q[0], " The data files of 1.1.0 come back from "+j.DataFolder+", inside the MariaDB data volume.") {
		t.Errorf("question: %q", q)
	}
	if !s.rep.said("the run moved the MariaDB data files to " + j.DataFolder + " inside the data volume") {
		t.Errorf("the folder was not named: %v", s.rep.logs())
	}
	db, replays, _, dataSeries := s.world()
	if db != "data-2" || dataSeries != "12.3" || len(replays) != 1 {
		t.Errorf("after recover: database %q, series %s, replays %v", db, dataSeries, replays)
	}
	s.f.with(func(f *fakeDocker) {
		if fresh, ok := f.folders[j.DataFolder+"-fresh"]; !ok || fresh.series != "11.8" || fresh.db != "data-1" {
			t.Errorf("the files the older server wrote are not kept aside: %+v (folders %v)", fresh, f.folders)
		}
		if _, ok := f.folders[j.DataFolder]; ok {
			t.Error("the folder still holds the data files of 1.1.0")
		}
	})
	s.movedAlone()
	if last := s.state().History; last[len(last)-1].Note != "the rollback to 1.0.0 failed: not healthy after 300ms: kvs-php-fpm is unhealthy" {
		t.Errorf("history ends with %+v", last[len(last)-1])
	}
}

// Killed once its data files moved aside, before the dump went in, the
// same rollback is recovered the same way: the newer version starts again
// on its own data files, not on the empty data directory.
func TestOneWayRollbackWithoutBackupCutIsRecoveredOnItsDataFiles(t *testing.T) {
	s := oneWayUpgraded(t)
	s.fresh()
	s.rep.cut = isLog("starting MariaDB alone")
	cutRun(t, s.rep, func() { _ = s.rollback(s.runner(func(o *Options) { o.NoBackup = true })) })
	j := s.journal()
	if j == nil || !j.DataMoved || j.Backup != "" {
		t.Fatalf("journal after the cut: %+v", j)
	}
	if db, _, _, _ := s.world(); db != "" {
		t.Fatalf("the data directory is not the fresh one after the cut: %q", db)
	}
	s.fresh()
	if err := s.recover(s.runner()); err != nil {
		t.Fatalf("recover: %v", err)
	}
	s.back("1.1.0")
	if db, _, _, dataSeries := s.world(); db != "data-2" || dataSeries != "12.3" {
		t.Errorf("after recover: database %q, series %s", db, dataSeries)
	}
	s.movedAlone()
}

// When the folder the data files went to is gone, recover cannot put
// them back: it stops there, naming the folder, and never starts the newer
// version on the fresh data directory.
func TestOneWayRollbackWithoutItsFolderStopsRecover(t *testing.T) {
	s := oneWayUpgraded(t)
	s.f.behave(registry+"php:1.0.0-php8.1", behavior{unhealthy: true})
	s.fresh()
	if err := s.rollback(s.runner(quick, func(o *Options) { o.NoBackup = true })); !errors.Is(err, ErrRollbackFailed) {
		t.Fatalf("rollback: %v", err)
	}
	j := s.journal()
	s.f.with(func(f *fakeDocker) { delete(f.folders, j.DataFolder) })
	s.fresh()
	err := s.recover(s.runner(quick))
	if !errors.Is(err, ErrRollbackFailed) || !strings.Contains(err.Error(), "the data files of 1.1.0 could not be moved back from "+j.DataFolder+" inside the MariaDB data volume") ||
		!strings.Contains(err.Error(), "they are the only copy of what 1.1.0 wrote: the rollback took no backup of it") {
		t.Fatalf("recover: %v", err)
	}
	if j := s.journal(); j == nil || j.DataBack {
		t.Errorf("journal after the failed recover: %+v", j)
	}
	if stopped := s.stopped(); !slices.Contains(stopped, mariadbService) {
		t.Errorf("MariaDB runs on the fresh data directory: stopped %v", stopped)
	}
}

// A one-way rollback killed once the move of its data files began: the
// compose run it started carries on without it and moves every file, but
// the journal never hears that the move is over. It named the folder
// before the move began, so recover puts back whatever went there and
// starts the newer version on its own data files, never on the fresh
// data directory.
func TestOneWayRollbackKilledWhileItsDataFilesMove(t *testing.T) {
	s := oneWayUpgraded(t)
	s.fresh()
	var folder string
	s.rep.cut = func(e Event) bool {
		rest, ok := strings.CutPrefix(e.Message, "moving the data files to ")
		if e.Kind != KindLog || !ok {
			return false
		}
		folder, _, _ = strings.Cut(rest, " ")
		return true
	}
	cutRun(t, s.rep, func() { _ = s.rollback(s.runner(func(o *Options) { o.NoBackup = true })) })
	s.f.with(func(f *fakeDocker) {
		f.folders[folder] = fakeData{series: f.dataSeries, db: f.db}
		f.moved = append(f.moved, folder)
		f.dataSeries, f.db = "", ""
	})
	if j := s.journal(); j == nil || j.DataFolder != folder || j.DataMoved {
		t.Fatalf("journal after the kill, the move to %s begun: %+v", folder, j)
	}
	s.fresh()
	if err := s.recover(s.runner()); err != nil {
		t.Fatalf("recover: %v", err)
	}
	s.back("1.1.0")
	if db, _, _, dataSeries := s.world(); db != "data-2" || dataSeries != "12.3" {
		t.Errorf("after recover: database %q, series %s", db, dataSeries)
	}
	s.f.with(func(f *fakeDocker) {
		if _, ok := f.folders[folder]; ok {
			t.Errorf("the data files of 1.1.0 are still in %s", folder)
		}
	})
}

// The data files a one-way rollback moved aside come back on recover, and
// with them the database the newer version wrote: what the cache took from
// the archive the rollback replayed is emptied, and Manticore rebuilds its
// indexes from the database that came back, once the services run.
func TestRecoverEmptiesTheCacheOnceTheDataFilesAreBack(t *testing.T) {
	s := newStack(t, "11.8", rel{version: "1.0.0"}, rel{version: "1.1.0"})
	if err := s.upgrade(s.runner(series("12.3"))); err != nil {
		t.Fatalf("upgrade: %v", err)
	}
	s.withSearch()
	s.writeData("data-2")
	s.f.behave(registry+"php:1.0.0-php8.1", behavior{unhealthy: true})
	s.fresh()
	if err := s.rollback(s.runner(quick, func(o *Options) { o.NoBackup = true })); !errors.Is(err, ErrRollbackFailed) {
		t.Fatalf("rollback: %v", err)
	}
	cache := s.containerID("memcached")
	var rebuilds int
	s.f.with(func(f *fakeDocker) { rebuilds = len(f.rebuilds) })
	before := len(s.f.commands())
	s.fresh()
	if err := s.recover(s.runner(quick)); err != nil {
		t.Fatalf("recover: %v", err)
	}
	s.back("1.1.0")
	if db, _, _, dataSeries := s.world(); db != "data-2" || dataSeries != "12.3" {
		t.Errorf("after recover: database %q, series %s", db, dataSeries)
	}
	cmds := s.f.commands()[before:]
	back := slices.IndexFunc(cmds, func(cmd string) bool {
		return strings.HasPrefix(cmd, "compose run --rm --no-deps --entrypoint sh mariadb")
	})
	rm := slices.Index(cmds, "compose rm --stop --force -v memcached")
	all := -1
	if rm >= 0 {
		if i := slices.Index(cmds[rm:], "compose up -d"); i >= 0 {
			all = rm + i
		}
	}
	touch := slices.Index(cmds, "compose run --rm --no-deps -T --entrypoint touch manticore "+manticoreRebuild)
	if back < 0 || rm < back || all < rm || touch < all {
		t.Errorf("recover moved the files back at %d, emptied the cache at %d, started the services at %d, asked for a rebuild at %d:\n%s", back, rm, all, touch, strings.Join(cmds, "\n"))
	}
	if id := s.containerID("memcached"); id == "" || id == cache {
		t.Errorf("the cache container is %q, it was %q", id, cache)
	}
	s.f.with(func(f *fakeDocker) {
		if len(f.rebuilds) != rebuilds+1 {
			t.Errorf("rebuilds asked before recover %d, after %d", rebuilds, len(f.rebuilds))
		}
	})
}

// prune removes from the engine the images of version no container uses,
// the way 'docker image prune -a' frees the space of the images a stack
// left behind, and unless keepRegistry removes them from the registry too.
// It returns a function that publishes them again.
func (s *stack) prune(version string, keepRegistry bool) (republish func()) {
	s.t.Helper()
	gone := map[string]*fakeImage{}
	s.f.with(func(f *fakeDocker) {
		used := map[*fakeImage]bool{}
		for _, c := range f.containers {
			used[c.image] = true
		}
		for _, img := range s.images[version] {
			found := f.registry[img.Digest]
			if found == nil || used[found] {
				continue
			}
			f.held = slices.DeleteFunc(f.held, func(held *fakeImage) bool { return held == found })
			if !keepRegistry {
				gone[img.Digest] = found
				delete(f.registry, img.Digest)
			}
		}
	})
	if len(gone) == 0 && !keepRegistry {
		s.t.Fatalf("no image of %s to remove from the registry", version)
	}
	return func() {
		s.f.with(func(f *fakeDocker) { maps.Copy(f.registry, gone) })
	}
}

// The images of the previous version may be gone from the engine by the
// time a rollback runs: it pulls them by digest while the site still
// runs, before anything changes.
func TestManualRollbackPullsThePreviousImages(t *testing.T) {
	s := newStack(t, "", rel{version: "1.0.0"}, rel{version: "1.1.0"})
	if err := s.upgrade(s.runner()); err != nil {
		t.Fatalf("upgrade: %v", err)
	}
	s.prune("1.0.0", true)
	if s.held("1.0.0", "nginx") || s.held("1.0.0", "php-fpm@8.1") {
		t.Fatal("the images of 1.0.0 are still on the engine")
	}
	s.fresh()
	if err := s.rollback(s.runner()); err != nil {
		t.Fatalf("rollback: %v", err)
	}
	s.back("1.0.0")
	for _, service := range []string{"nginx", "php-fpm@8.1"} {
		if !s.rep.said("pulling "+s.pin("1.0.0", service)+": the engine no longer holds it") || !s.held("1.0.0", service) {
			t.Errorf("the image of %s was not pulled: %v", service, s.rep.logs())
		}
	}
}

// A rollback interrupted while it pulls the images the engine no longer
// holds ends in plain words, the error of the pull it stopped on a line of
// the run: no journal, no backup, no service stopped.
func TestManualRollbackInterruptedDuringItsPullChangesNothing(t *testing.T) {
	s := newStack(t, "", rel{version: "1.0.0"}, rel{version: "1.1.0", database: migrates})
	if err := s.upgrade(s.runner()); err != nil {
		t.Fatalf("upgrade: %v", err)
	}
	s.prune("1.0.0", true)
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	s.fresh()
	s.rep.on = func(e Event) {
		if e.Kind == KindLog && strings.HasPrefix(e.Message, "pulling ") {
			cancel()
		}
	}
	err := s.runner().Rollback(ctx, s.state())
	if err == nil || err.Error() != "rollback interrupted, nothing was changed, the stack is still on 1.1.0" {
		t.Fatalf("err = %v", err)
	}
	s.ended(err)
	if !s.rep.said("cancelled: " + s.pin("1.0.0", "nginx") + " is not on this machine any more and could not be pulled: ") {
		t.Errorf("the error of the pull is not a line of the run: %q", s.rep.logs())
	}
	s.back("1.1.0")
	if path, _ := backup.Latest(filepath.Join(s.root, "backups"), "1.1.0"); path != "" {
		t.Errorf("a backup was taken: %s", path)
	}
	if s.ran("compose stop nginx php-fpm") >= 0 {
		t.Errorf("the services were stopped: %v", s.f.commands())
	}
}

// status names the images a rollback would have to pull: none while the
// engine holds what the previous version runs, and once a prune took them,
// those of the services that version runs, a service only it runs
// included, but not the image of a service whose profile is off.
func TestMissingRollbackImages(t *testing.T) {
	s := newStack(t, "", rel{version: "1.0.0", extra: []string{"legacy"}}, rel{version: "1.1.0"})
	r := s.runner()
	ctx := context.Background()
	if missing, err := r.MissingRollbackImages(ctx, s.state()); err != nil || len(missing) != 0 {
		t.Errorf("without a previous version: %v %v", missing, err)
	}
	if err := s.upgrade(s.runner()); err != nil {
		t.Fatalf("upgrade: %v", err)
	}
	if missing, err := r.MissingRollbackImages(ctx, s.state()); err != nil || len(missing) != 0 {
		t.Errorf("with the images of 1.0.0 on the engine: %v %v", missing, err)
	}
	s.prune("1.0.0", true)
	want := []string{s.pin("1.0.0", "legacy"), s.pin("1.0.0", "nginx"), s.pin("1.0.0", "php-fpm@8.1")}
	slices.Sort(want)
	if missing, err := r.MissingRollbackImages(ctx, s.state()); err != nil || !slices.Equal(missing, want) {
		t.Errorf("once the images of 1.0.0 are pruned: %v %v, want %v", missing, err, want)
	}
}

// A rollback whose previous images can be neither found on the engine nor
// pulled is refused before its first change: no journal, no backup, the
// stack still on the version it runs.
func TestManualRollbackRefusesImagesItCannotPull(t *testing.T) {
	s := newStack(t, "", rel{version: "1.0.0"}, rel{version: "1.1.0", database: migrates})
	if err := s.upgrade(s.runner()); err != nil {
		t.Fatalf("upgrade: %v", err)
	}
	s.prune("1.0.0", false)
	s.fresh()
	err := s.rollback(s.runner())
	if err == nil || errors.Is(err, ErrRollbackFailed) || !strings.Contains(err.Error(), "is not on this machine any more and could not be pulled") ||
		!strings.HasSuffix(err.Error(), "nothing was changed, the stack is still on 1.1.0") {
		t.Fatalf("err = %v", err)
	}
	s.ended(err)
	s.back("1.1.0")
	if path, _ := backup.Latest(filepath.Join(s.root, "backups"), "1.1.0"); path != "" {
		t.Errorf("a backup was taken: %s", path)
	}
	if s.ran("compose stop nginx php-fpm") >= 0 {
		t.Errorf("the services were stopped: %v", s.f.commands())
	}
}

// A rollback whose files cannot take their place is refused before its
// first change: 1.1.0 made conf/extra, a file of 1.0.0, a directory, and
// the operator keeps a file of their own in it since. Nothing is asked,
// pulled, stopped or laid, and no journal is written.
func TestManualRollbackRefusesFilesThatCannotTakeTheirPlace(t *testing.T) {
	s := newStack(t, "",
		rel{version: "1.0.0", database: migrates, files: map[string]string{"conf/extra": "a file in 1.0.0\n"}},
		rel{version: "1.1.0", database: migrates, files: map[string]string{"conf/extra/site.conf": "a directory in 1.1.0\n"}})
	if err := s.upgrade(s.runner()); err != nil {
		t.Fatalf("upgrade: %v", err)
	}
	mine := filepath.Join(s.root, "conf", "extra", "mine.conf")
	if err := os.WriteFile(mine, []byte("the operator's\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	before := len(s.f.commands())
	s.fresh()
	err := s.rollback(s.runner(func(o *Options) { o.Yes = false }))
	want := "the files of 1.0.0 cannot take their place: " + filepath.Join(s.root, "conf", "extra") + " is a directory, where the release lays a file, and it holds " + mine +
		", which the release does not ship: move it away; nothing was changed, the stack is still on 1.1.0"
	if err == nil || err.Error() != want {
		t.Fatalf("err = %v\nwant %s", err, want)
	}
	s.ended(err)
	s.back("1.1.0")
	if cmds := s.f.commands()[before:]; len(cmds) != 0 {
		t.Errorf("the refused rollback ran %v", cmds)
	}
	if len(s.rep.questions) != 0 {
		t.Errorf("the refused rollback asked %q", s.rep.questions)
	}
	if s.file("conf/extra/mine.conf") != "the operator's\n" || s.file("conf/extra/site.conf") != "a directory in 1.1.0\n" {
		t.Error("the files of 1.1.0 changed")
	}
}

// recover after a run cut short pulls the images of the version it
// returns to when they left the engine since; while they cannot be
// pulled, it changes nothing and keeps the journal.
func TestRecoverPullsTheImagesItReturnsTo(t *testing.T) {
	s := newStack(t, "", rel{version: "1.0.0"}, rel{version: "1.1.0"})
	s.cutUpgrade(s.runner(), isStep(KindStepStart, StepVerify))
	republish := s.prune("1.0.0", false)
	s.fresh()
	err := s.recover(s.runner())
	if !errors.Is(err, ErrRollbackFailed) || !strings.Contains(err.Error(), "nothing was rolled back yet: once the images can be pulled, 'kvsctl recover' runs the rollback") {
		t.Fatalf("recover without the images: %v", err)
	}
	if got := s.file("docker/RELEASE"); got != "1.1.0\n" || s.journal() == nil {
		t.Fatalf("recover changed the stack: RELEASE %q, journal %+v", got, s.journal())
	}
	republish()
	s.fresh()
	if err := s.recover(s.runner()); err != nil {
		t.Fatalf("recover: %v", err)
	}
	s.back("1.0.0")
	if !s.rep.said("pulling " + s.pin("1.0.0", "nginx") + ": the engine no longer holds it") {
		t.Errorf("the image of nginx was not pulled: %v", s.rep.logs())
	}
}

// dropImage removes the image of one service of a version from the engine
// and from the registry, the way a prune and a registry out of reach leave
// it, and returns a function that publishes it again.
func (s *stack) dropImage(version, service string) (republish func()) {
	s.t.Helper()
	digest := s.images[version][service].Digest
	var gone *fakeImage
	s.f.with(func(f *fakeDocker) {
		gone = f.registry[digest]
		f.held = slices.DeleteFunc(f.held, func(held *fakeImage) bool { return held == gone })
		delete(f.registry, digest)
	})
	if gone == nil {
		s.t.Fatalf("no image of %s in %s", service, version)
	}
	return func() {
		s.f.with(func(f *fakeDocker) { f.registry[digest] = gone })
	}
}

// A service the installed version dropped runs again once a rollback
// returns to the version before. The upgrade removed its container, so
// nothing holds its image any more and a prune may have taken it: the
// rollback checks that image before its first change, as it checks the
// images of the services both versions run, pulls it, and is refused with
// nothing changed while it cannot.
func TestManualRollbackChecksTheImageOfADroppedService(t *testing.T) {
	s := newStack(t, "", rel{version: "1.0.0", extra: []string{"legacy"}}, rel{version: "1.1.0"})
	if err := s.upgrade(s.runner()); err != nil {
		t.Fatalf("upgrade: %v", err)
	}
	if id := s.containerID("legacy"); id != "" {
		t.Fatal("the upgrade kept the container of legacy")
	}
	republish := s.dropImage("1.0.0", "legacy")
	s.fresh()
	err := s.rollback(s.runner())
	if err == nil || errors.Is(err, ErrRollbackFailed) || !strings.Contains(err.Error(), s.pin("1.0.0", "legacy")+" is not on this machine any more and could not be pulled") ||
		!strings.HasSuffix(err.Error(), "nothing was changed, the stack is still on 1.1.0") {
		t.Fatalf("err = %v", err)
	}
	s.back("1.1.0")
	republish()
	s.fresh()
	if err := s.rollback(s.runner()); err != nil {
		t.Fatalf("rollback once the image can be pulled: %v", err)
	}
	s.back("1.0.0")
	if got := s.running("legacy"); got != s.pin("1.0.0", "legacy") {
		t.Errorf("legacy runs %q after the rollback", got)
	}
	if !s.rep.said("pulling " + s.pin("1.0.0", "legacy") + ": the engine no longer holds it") {
		t.Errorf("the image of legacy was not pulled: %v", s.rep.logs())
	}
}

// recover returns the stack to a version that runs a service the failed
// release dropped: its container went with the upgrade, so its image may
// be gone by the time recover runs. recover checks it before anything
// moves, keeps the journal while it cannot be pulled, and runs the
// rollback once it can.
func TestRecoverChecksTheImageOfAServiceTheFailedReleaseDropped(t *testing.T) {
	s := newStack(t, "", rel{version: "1.0.0", extra: []string{"legacy"}}, rel{version: "1.1.0"})
	s.cutUpgrade(s.runner(), isStep(KindStepStart, StepVerify))
	if id := s.containerID("legacy"); id != "" {
		t.Fatal("the upgrade kept the container of legacy")
	}
	republish := s.dropImage("1.0.0", "legacy")
	s.fresh()
	err := s.recover(s.runner())
	if !errors.Is(err, ErrRollbackFailed) || !strings.Contains(err.Error(), s.pin("1.0.0", "legacy")+" is not on this machine any more and could not be pulled") ||
		!strings.Contains(err.Error(), "nothing was rolled back yet: once the images can be pulled, 'kvsctl recover' runs the rollback") {
		t.Fatalf("recover without the image: %v", err)
	}
	if got := s.file("docker/RELEASE"); got != "1.1.0\n" || s.journal() == nil {
		t.Fatalf("recover changed the stack: RELEASE %q, journal %+v", got, s.journal())
	}
	republish()
	s.fresh()
	if err := s.recover(s.runner()); err != nil {
		t.Fatalf("recover: %v", err)
	}
	s.back("1.0.0")
	if got := s.running("legacy"); got != s.pin("1.0.0", "legacy") {
		t.Errorf("legacy runs %q after recover", got)
	}
}

// A rollback interrupted during the backup of the live database changed
// nothing but the services it stopped for that backup: they start again,
// the journal goes, and the stack is still on the version it runs.
func TestManualRollbackInterruptedDuringItsBackupChangesNothing(t *testing.T) {
	s := newStack(t, "", rel{version: "1.0.0"}, rel{version: "1.1.0", database: migrates})
	if err := s.upgrade(s.runner()); err != nil {
		t.Fatalf("upgrade: %v", err)
	}
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	s.fresh()
	s.rep.on = func(e Event) {
		if e.Kind == KindStepStart && e.Step == StepBackup {
			cancel()
		}
	}
	err := s.runner().Rollback(ctx, s.state())
	if err == nil || err.Error() != "rollback interrupted during the backup of the live database, nothing was changed, the stack is still on 1.1.0" {
		t.Fatalf("err = %v", err)
	}
	if got := s.rep.first(KindStepFail, StepBackup); got != "cancelled" {
		t.Errorf("the backup step failed with %q", got)
	}
	s.back("1.1.0")
	if stopped := s.stopped(); len(stopped) != 0 {
		t.Errorf("still stopped: %v", stopped)
	}
	if _, replays, _, _ := s.world(); len(replays) != 0 {
		t.Errorf("replays %v", replays)
	}
}

// The same rollback, its stop of the services that write interrupted
// before its backup, ends in plain words too, the error of the docker
// command the interrupt stopped on a line of the run; a stop that fails
// says why. Either way 1.1.0 runs as it did.
func TestManualRollbackThatCannotStopTheWritersChangesNothing(t *testing.T) {
	for _, interrupt := range []bool{true, false} {
		t.Run(map[bool]string{true: "interrupted", false: "failed"}[interrupt], func(t *testing.T) {
			s := newStack(t, "", rel{version: "1.0.0"}, rel{version: "1.1.0", database: migrates})
			if err := s.upgrade(s.runner()); err != nil {
				t.Fatalf("upgrade: %v", err)
			}
			ctx, cancel := context.WithCancel(context.Background())
			defer cancel()
			s.fresh()
			if interrupt {
				s.rep.on = func(e Event) {
					if e.Kind == KindLog && strings.HasPrefix(e.Message, "stopping ") {
						cancel()
					}
				}
			} else {
				s.failOnce("compose stop nginx php-fpm", "Error response from daemon: cannot stop container kvs-nginx")
			}
			err := s.runner().Rollback(ctx, s.state())
			switch {
			case err == nil:
				t.Fatal("the rollback went on")
			case interrupt && err.Error() != "rollback interrupted while it stopped the services that write, nothing was changed, the stack is still on 1.1.0":
				t.Fatalf("err = %v", err)
			case !interrupt && (!strings.Contains(err.Error(), "cannot stop container kvs-nginx") || !strings.HasSuffix(err.Error(), "; nothing was changed, the stack is still on 1.1.0")):
				t.Fatalf("err = %v", err)
			}
			if got := s.rep.said("cancelled: docker compose stop "); got != interrupt {
				t.Errorf("the run logs the error of a stopped command: %v, want %v: %q", got, interrupt, s.rep.logs())
			}
			if got := s.rep.first(KindStepStart, StepBackup); got != "" {
				t.Errorf("the backup began: %q", got)
			}
			s.back("1.1.0")
			if stopped := s.stopped(); len(stopped) != 0 {
				t.Errorf("still stopped: %v", stopped)
			}
			if _, replays, _, _ := s.world(); len(replays) != 0 {
				t.Errorf("replays %v", replays)
			}
		})
	}
}

// dataScript runs fn, which moves the MariaDB data files aside or back,
// with the fake answering the compose run that would run the script of
// the move in a container of the MariaDB image, and returns that script
// with the data directory it changes into turned into dir.
func (s *stack) dataScript(dir string, fn func()) string {
	s.t.Helper()
	var script string
	s.f.with(func(f *fakeDocker) {
		f.hook = func(_ *fakeDocker, req cliRequest) (cliResponse, bool) {
			if len(req.Args) < 2 || req.Args[0] != "compose" || req.Args[1] != "run" {
				return cliResponse{}, false
			}
			script = req.Args[len(req.Args)-1]
			return cliResponse{}, true
		}
	})
	fn()
	var got string
	s.f.with(func(f *fakeDocker) { f.hook, got = nil, script })
	cd := "cd " + mariadbDataDir + ";"
	if !strings.Contains(got, cd) {
		s.t.Fatalf("the script does not change into the data directory: %q", got)
	}
	return strings.Replace(got, cd, "cd '"+dir+"';", 1)
}

// runScript runs a script with sh and returns its exit code and what it
// wrote on its standard error.
func runScript(t *testing.T, script string) (int, string) {
	t.Helper()
	var stderr bytes.Buffer
	cmd := exec.Command("sh", "-c", script)
	cmd.Stderr = &stderr
	err := cmd.Run()
	var exit *exec.ExitError
	if errors.As(err, &exit) {
		return exit.ExitCode(), stderr.String()
	}
	if err != nil {
		t.Fatal(err)
	}
	return 0, stderr.String()
}

// writeTree writes files under dir, each by its path relative to dir.
func writeTree(t *testing.T, dir string, files map[string]string) {
	t.Helper()
	for name, content := range files {
		path := filepath.Join(dir, filepath.FromSlash(name))
		if err := os.MkdirAll(filepath.Dir(path), 0o755); err != nil {
			t.Fatal(err)
		}
		if err := os.WriteFile(path, []byte(content), 0o644); err != nil {
			t.Fatal(err)
		}
	}
}

// readTree is every file under dir by its path relative to dir, with its
// content; an empty directory is listed with a trailing slash.
func readTree(t *testing.T, dir string) map[string]string {
	t.Helper()
	out := map[string]string{}
	err := filepath.WalkDir(dir, func(path string, d fs.DirEntry, err error) error {
		if err != nil || path == dir {
			return err
		}
		rel, err := filepath.Rel(dir, path)
		if err != nil {
			return err
		}
		rel = filepath.ToSlash(rel)
		if d.IsDir() {
			entries, err := os.ReadDir(path)
			if err == nil && len(entries) == 0 {
				out[rel+"/"] = ""
			}
			return err
		}
		data, err := os.ReadFile(path)
		out[rel] = string(data)
		return err
	})
	if err != nil {
		t.Fatal(err)
	}
	return out
}

// under is files moved into folder.
func under(folder string, files map[string]string) map[string]string {
	out := map[string]string{}
	for name, content := range files {
		out[folder+"/"+name] = content
	}
	return out
}

// merged is the files of every set together.
func merged(sets ...map[string]string) map[string]string {
	out := map[string]string{}
	for _, set := range sets {
		maps.Copy(out, set)
	}
	return out
}

// The scripts that move the MariaDB data files aside and back run on real
// files. Every file of the data directory, dot files and odd names
// included, goes to the dated folder and none is deleted; the folders of
// earlier rollbacks stay where they are; run again, as a move cut short
// is, the move moves nothing more. The move back puts the files the older
// server wrote in a folder of their own before it brings the others back,
// and one cut short and run again only finishes bringing them back. A
// folder that is gone stops the move back of files that did move, and a
// rollback cut before its move began has nothing to bring back.
func TestTheDataMoveScriptsKeepEveryFile(t *testing.T) {
	s := newStack(t, "11.8", rel{version: "1.0.0"}, rel{version: "1.1.0"})
	r := s.runner()
	ctx := context.Background()
	state := s.state()
	dir := t.TempDir()
	data := map[string]string{
		"ibdata1":             "data",
		"aria_log_control":    "data",
		"mysql/user.MAD":      "data",
		".my-healthcheck.cnf": "data",
		"..odd":               "data",
	}
	earlier := under(keptPrefix+"20200101-000000", map[string]string{"ibdata1": "an earlier rollback"})
	writeTree(t, dir, merged(data, earlier))

	j := &instance.Journal{Action: instance.ActionRollback, From: "1.1.0", To: "1.0.0", Phase: instance.PhaseRestart}
	move := s.dataScript(dir, func() {
		if err := r.recreateDatadir(ctx, j); err != nil {
			t.Fatalf("recreateDatadir: %v", err)
		}
	})
	if !j.DataMoved || !strings.HasPrefix(j.DataFolder, keptPrefix) {
		t.Fatalf("journal after the move: %+v", j)
	}
	aside := merged(earlier, under(j.DataFolder, data))
	for run := 1; run <= 2; run++ {
		if code, stderr := runScript(t, move); code != 0 {
			t.Fatalf("the move, run %d: exit %d: %s", run, code, stderr)
		}
		if got := readTree(t, dir); !maps.Equal(got, aside) {
			t.Fatalf("after the move, run %d:\n%v\nwant\n%v", run, got, aside)
		}
	}

	// The older server initialised a fresh data directory.
	fresh := map[string]string{"ibdata1": "fresh", "mysql/user.MAD": "fresh", ".my-healthcheck.cnf": "fresh"}
	writeTree(t, dir, fresh)
	back := func(folder string, moved bool) string {
		return s.dataScript(dir, func() {
			jb := &instance.Journal{Action: instance.ActionRollback, From: "1.1.0", To: "1.0.0", DataFolder: folder, DataMoved: moved}
			if err := r.dataBack(ctx, state, jb); err != nil {
				t.Fatalf("dataBack: %v", err)
			}
		})
	}
	moveBack := back(j.DataFolder, true)
	inPlace := merged(earlier, data, under(j.DataFolder+"-fresh", merged(fresh, map[string]string{backMarker: ""})))
	for run := 1; run <= 2; run++ {
		if code, stderr := runScript(t, moveBack); code != 0 {
			t.Fatalf("the move back, run %d: exit %d: %s", run, code, stderr)
		}
		if got := readTree(t, dir); !maps.Equal(got, inPlace) {
			t.Fatalf("after the move back, run %d:\n%v\nwant\n%v", run, got, inPlace)
		}
	}

	// Cut part way: the fresh files are aside, aria_log_control is not
	// back yet. Run again, the move back brings it and leaves the files
	// at the top of the data directory where they are.
	writeTree(t, dir, under(j.DataFolder, map[string]string{"aria_log_control": "data"}))
	if err := os.Remove(filepath.Join(dir, "aria_log_control")); err != nil {
		t.Fatal(err)
	}
	if code, stderr := runScript(t, moveBack); code != 0 {
		t.Fatalf("the move back after a cut: exit %d: %s", code, stderr)
	}
	if got := readTree(t, dir); !maps.Equal(got, inPlace) {
		t.Errorf("after the move back cut short:\n%v\nwant\n%v", got, inPlace)
	}

	gone := keptPrefix + "20990101-000000"
	if code, stderr := runScript(t, back(gone, true)); code != 3 || !strings.Contains(stderr, gone+" is not in the MariaDB data volume") {
		t.Errorf("a move back without its folder: exit %d: %s", code, stderr)
	}
	if code, stderr := runScript(t, back(gone, false)); code != 0 {
		t.Errorf("the move back of a move that never began: exit %d: %s", code, stderr)
	}
	if got := readTree(t, dir); !maps.Equal(got, inPlace) {
		t.Errorf("after the moves back that had nothing to bring:\n%v\nwant\n%v", got, inPlace)
	}
}

// A one-way manual rollback that took its backup of the live database,
// killed once the data files of the newer version moved aside and before
// the dump went in: its journal said compose started before the move, so
// recover brings MariaDB up again, on the data files of the newer version
// moved back in place, and never leaves it stopped on the fresh data
// directory.
func TestRecoverAManualRollbackCutAfterItsDataFilesMoved(t *testing.T) {
	s := oneWayUpgraded(t)
	s.fresh()
	s.rep.cut = isLog("starting MariaDB alone")
	cutRun(t, s.rep, func() { _ = s.rollback(s.runner()) })
	j := s.journal()
	if j == nil || j.Phase != instance.PhaseRestart || !j.DataMoved || !strings.Contains(j.Backup, "backup-1.1.0-") {
		t.Fatalf("journal after the cut: %+v", j)
	}
	if !j.ComposeStarted {
		t.Error("the journal of the rollback cut after the move does not say compose started")
	}
	if db, _, moved, _ := s.world(); db != "" || !slices.Equal(moved, []string{j.DataFolder}) {
		t.Fatalf("after the cut: database %q, moved %v", db, moved)
	}
	s.fresh()
	if err := s.recover(s.runner(quick)); err != nil {
		t.Fatalf("recover: %v", err)
	}
	s.back("1.1.0")
	if db, replays, _, dataSeries := s.world(); db != "data-2" || dataSeries != "12.3" || len(replays) != 0 {
		t.Errorf("after recover: database %q, series %s, replays %v", db, dataSeries, replays)
	}
	if stopped := s.stopped(); len(stopped) != 0 {
		t.Errorf("still stopped after recover: %v", stopped)
	}
	s.movedAlone()
}

// --restore-db has a manual rollback replay the archive the upgrade took
// even when the release declared no change to the database, after a
// backup of the live database.
func TestManualRollbackWithRestoreDB(t *testing.T) {
	s := newStack(t, "", rel{version: "1.0.0"}, rel{version: "1.1.0"})
	if err := s.upgrade(s.runner()); err != nil {
		t.Fatalf("upgrade: %v", err)
	}
	upgradeBackup := s.state().UpgradeBackup
	s.writeData("data-2")
	s.fresh()
	if err := s.rollback(s.runner(func(o *Options) { o.Yes, o.RestoreDB = false, true })); err != nil {
		t.Fatalf("rollback: %v", err)
	}
	s.back("1.0.0")
	if q := s.rep.questions; len(q) != 1 || !strings.HasPrefix(q[0], "Roll back to 1.0.0 and replay "+filepath.Base(upgradeBackup)+", taken ") {
		t.Errorf("question: %q", q)
	}
	if db, replays, _, _ := s.world(); db != "data-1" || !slices.Equal(replays, []string{"data-1"}) {
		t.Errorf("rollback --restore-db: database %q, replays %v, want the archive of the upgrade", db, replays)
	}
	safety, err := backup.Latest(filepath.Join(s.root, "backups"), "1.1.0")
	if err != nil || safety == "" {
		t.Fatalf("no backup of 1.1.0 was taken: %v", err)
	}
	if got := s.holds(safety); got != "data-2" {
		t.Errorf("the safety backup holds %s, want the live database of 1.1.0", got)
	}
}

// A manual rollback that changes the MariaDB image, to the previous build
// of the same series, starts MariaDB alone first and the other services
// once it is healthy, within the budget of a change that keeps the series,
// as the upgrade did; the database is left as it is.
func TestManualRollbackStartsMariaDBAloneWhenItsImageChanges(t *testing.T) {
	s := newStack(t, "11.8", rel{version: "1.0.0", mariadb: map[string]string{"11.8": "11.8.9"}}, rel{version: "1.1.0", mariadb: map[string]string{"11.8": "11.8.10"}})
	if err := s.upgrade(s.runner()); err != nil {
		t.Fatalf("upgrade: %v", err)
	}
	if got := s.running("mariadb"); got != s.pin("1.1.0", "mariadb@11.8") {
		t.Fatalf("mariadb runs %s after the upgrade", got)
	}
	s.writeData("data-2")
	s.fresh()
	before := len(s.f.commands())
	if err := s.rollback(s.runner(func(o *Options) { o.DBTimeout = 0 })); err != nil {
		t.Fatalf("rollback: %v", err)
	}
	s.back("1.0.0")
	commands := s.f.commands()[before:]
	alone, all := slices.Index(commands, "compose up -d mariadb"), slices.Index(commands, "compose up -d")
	if alone < 0 || all < alone {
		t.Errorf("MariaDB was not brought up alone first: %v", commands)
	}
	if !s.rep.said("starting MariaDB alone first, the other services follow once it is healthy; MariaDB has 10m0s to be ready (--db-timeout)") {
		t.Errorf("the budget of MariaDB was not said: %v", s.rep.logs())
	}
	if db, replays, _, _ := s.world(); db != "data-2" || len(replays) != 0 {
		t.Errorf("database %q, replays %v", db, replays)
	}
}

// A manual rollback that replays an archive and stops before compose
// started has not touched the database, but it stopped the services that
// write, for its backup or, with --no-backup, for its replay: its error
// says they stay stopped and names recover as the way back without a
// replay, and recover asks to return the stack saying what becomes of the
// database and that they start again, which they do, and leaves the
// database as it is.
func TestManualRollbackStoppedBeforeComposeLeavesTheDatabase(t *testing.T) {
	for _, noBackup := range []bool{false, true} {
		s := newStack(t, "", rel{version: "1.0.0"}, rel{version: "1.1.0", database: migrates})
		if err := s.upgrade(s.runner()); err != nil {
			t.Fatalf("upgrade: %v", err)
		}
		s.writeData("data-2")
		s.failOnce("compose config --quiet", "yaml: line 3: mapping values are not allowed in this context")
		s.fresh()
		err := s.rollback(s.runner(func(o *Options) { o.NoBackup = noBackup }))
		if !errors.Is(err, ErrRollbackFailed) || !strings.HasPrefix(err.Error(), "the rollback to 1.0.0 failed part way: compose cannot read the project, no container was started, and nginx, php-fpm, which the rollback stopped, stay stopped: docker compose config --quiet: exit status 1: yaml: line 3: mapping values are not allowed in this context; the stack is in an unknown state: 'kvsctl recover' returns it to 1.1.0; log: ") {
			t.Fatalf("--no-backup %v: err = %v", noBackup, err)
		}
		if j := s.journal(); j == nil || j.ComposeStarted || (j.Backup == "") != noBackup || !slices.Equal(j.Stopped, []string{"nginx", "php-fpm"}) {
			t.Fatalf("--no-backup %v: journal: %+v", noBackup, j)
		}
		if stopped := s.stopped(); !slices.Equal(stopped, []string{"nginx", "php-fpm"}) {
			t.Fatalf("--no-backup %v: stopped after the failed rollback: %v", noBackup, stopped)
		}
		s.fresh()
		if err := s.recover(s.runner(func(o *Options) { o.Yes = false })); err != nil {
			t.Fatalf("--no-backup %v: recover: %v", noBackup, err)
		}
		s.back("1.1.0")
		database := "Compose never started: the database was not touched"
		if noBackup {
			database = "No backup was taken, the database is left as it is"
		}
		if q := s.rep.questions; len(q) != 1 || q[0] != "Return the stack to 1.1.0, undoing what the rollback to 1.0.0 did? "+database+", and nginx, php-fpm, which the rollback stopped, start again." {
			t.Errorf("--no-backup %v: question: %q", noBackup, q)
		}
		if stopped := s.stopped(); len(stopped) != 0 {
			t.Errorf("--no-backup %v: still stopped after recover: %v", noBackup, stopped)
		}
		if db, replays, _, _ := s.world(); db != "data-2" || len(replays) != 0 {
			t.Errorf("--no-backup %v: database %q, replays %v", noBackup, db, replays)
		}
	}
}
