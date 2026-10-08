package upgrade

import (
	"context"
	"errors"
	"fmt"
	"maps"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"slices"
	"strings"
	"testing"
	"time"

	"github.com/MaximeMichaud/KVS-install/cli/internal/backup"
	"github.com/MaximeMichaud/KVS-install/cli/internal/instance"
	"github.com/MaximeMichaud/KVS-install/cli/internal/manifest"
	"github.com/MaximeMichaud/KVS-install/cli/internal/release"
)

// The whole upgrade against the fake engine: what it pulls, the order of
// the compose commands, what it writes and what it records.
func TestRunUpgradesEndToEnd(t *testing.T) {
	s := newStack(t, "", rel{version: "1.0.0"}, rel{version: "1.1.0", notes: "faster thumbnails"})
	mariadbID := s.containerID("mariadb")
	before := s.state()
	err := s.upgrade(s.runner())
	if err != nil {
		t.Fatalf("upgrade: %v", err)
	}
	s.ended(nil)
	s.back("1.1.0")

	state := s.state()
	if state.Previous != "1.0.0" || !slices.Equal(state.PreviousFiles, before.Files) {
		t.Errorf("previous %s with %v", state.Previous, state.PreviousFiles)
	}
	if !strings.HasPrefix(filepath.Base(state.UpgradeBackup), "backup-1.0.0-") {
		t.Errorf("the backup of the upgrade is not recorded: %q", state.UpgradeBackup)
	} else if _, err := os.Stat(state.UpgradeBackup); err != nil {
		t.Errorf("the recorded backup is not there: %v", err)
	}
	if got, want := state.Images["KVS_PHP_FPM_IMAGE"], s.pin("1.1.0", "php-fpm@8.1"); got != want {
		t.Errorf("KVS_PHP_FPM_IMAGE recorded as %s, want %s", got, want)
	}
	// What 1.0.0 ran with: its images, the PHP series and COMPOSE_FILE.
	want := withComposeFile(before.Images, "docker-compose.yml:"+ReleaseOverride)
	want["PHP_VERSION"] = "8.1"
	if !maps.Equal(state.PreviousImages, want) {
		t.Errorf("previous images %v, want %v", state.PreviousImages, want)
	}
	if len(state.ReleaseImages["1.1.0"]) != 5 {
		t.Errorf("the pins of 1.1.0: %v", state.ReleaseImages["1.1.0"])
	}
	if last := state.History[len(state.History)-1]; last.Version != "1.1.0" || last.Action != instance.ActionUpgrade || last.Note != "from 1.0.0" {
		t.Errorf("history ends with %+v", last)
	}
	env := s.env()
	if env["KVS_STACK_VERSION"] != "1.1.0" || env["SETTING_1_1_0"] != "1" || env["MARIADB_VERSION"] != "11.8" {
		t.Errorf(".env after the upgrade: %v", env)
	}

	// Only what the active services run was pulled, and MariaDB, whose
	// image did not change, was left alone.
	if !s.held("1.1.0", "nginx") || !s.held("1.1.0", "php-fpm@8.1") || s.held("1.1.0", "manticore") || s.held("1.1.0", "kvs-init") {
		t.Error("the pulls do not follow the active services")
	}
	if s.containerID("mariadb") != mariadbID || s.ran("compose up -d mariadb") >= 0 {
		t.Error("MariaDB was restarted though its image did not change")
	}
	if config, up := s.ran("compose config --quiet"), s.ran("compose up -d"); config < 0 || config > up {
		t.Errorf("compose read the project at %d and started at %d", config, up)
	}
	if db, replays, moved, _ := s.world(); db != "data-1" || len(replays) != 0 || len(moved) != 0 {
		t.Errorf("the database was touched: %s %v %v", db, replays, moved)
	}
	if !s.rep.said("1.1.0: faster thumbnails") {
		t.Error("the notes of the release were not shown")
	}
}

// The image a release pins that the container of its service already
// runs, the same digest under another name, here MariaDB pinned from a
// mirror of the registry the stack pulled it from, downloads nothing: the
// pull step neither lists it nor counts it among the images it pulls. It
// is still pulled by its digest before the first change, so compose finds
// it under the name the release gives it without a registry.
func TestPullShowsOnlyTheImagesToDownload(t *testing.T) {
	s := newStack(t, "", rel{version: "1.0.0"}, rel{version: "1.1.0"})
	target := s.release("1.1.0")
	mirrored := s.f.mirror(target.Variants[manifest.VariantMariaDB]["11.8"][0], "mirror.example.com/library/mariadb")
	target.Variants[manifest.VariantMariaDB]["11.8"] = []manifest.Image{mirrored}
	s.writeManifest()
	if err := s.upgrade(s.runner()); err != nil {
		t.Fatalf("upgrade: %v", err)
	}
	s.back("1.1.0")
	if got := s.running(mariadbService); got != mirrored.Ref+"@"+mirrored.Digest {
		t.Errorf("mariadb runs %s, want the mirrored image", got)
	}
	var start string
	var shown []string
	pulling := false
	for _, e := range s.rep.events {
		switch {
		case e.Kind == KindStepStart && e.Step == StepPull:
			start, pulling = e.Message, true
		case e.Kind == KindStepDone && e.Step == StepPull:
			pulling = false
		case pulling && e.Kind == KindImage:
			shown = append(shown, e.Service)
		}
	}
	if start != "2 images, 2 kB to download" {
		t.Errorf("the pull step starts with %q", start)
	}
	if slices.Contains(shown, mariadbService) || !slices.Contains(shown, "nginx") || !slices.Contains(shown, "php-fpm") {
		t.Errorf("the pull step showed the images of %v", shown)
	}
}

// Compose cannot read the laid files, so no container was touched, and the
// rollback puts the files back without replaying anything, even for a
// release that changes the database.
func TestRunConfigErrorTouchesNoContainer(t *testing.T) {
	s := newStack(t, "", rel{version: "1.0.0"}, rel{version: "1.1.0", database: migrates})
	s.failOnce("compose config --quiet", "yaml: line 3: mapping values are not allowed in this context")
	err := s.upgrade(s.runner(quick))
	if !errors.Is(err, ErrRolledBack) || !strings.Contains(err.Error(), "compose cannot read the project, no container was touched") || !strings.Contains(err.Error(), "1.0.0 is back and healthy") {
		t.Fatalf("err = %v", err)
	}
	s.ended(err)
	s.back("1.0.0")
	if s.count("compose up") != 0 {
		t.Error("compose started")
	}
	if _, replays, _, _ := s.world(); len(replays) != 0 || !s.rep.said("compose never started") {
		t.Errorf("the database was replayed: %v", replays)
	}
}

// A Ctrl-C between the files and the restart rolls the files back and
// starts nothing.
func TestRunCancelledBeforeComposeUp(t *testing.T) {
	s := newStack(t, "", rel{version: "1.0.0"}, rel{version: "1.1.0", database: migrates})
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	s.rep.on = func(e Event) {
		if isStep(KindStepDone, StepApply)(e) {
			cancel()
		}
	}
	r := s.runner(quick)
	state, plan := s.plan(r)
	err := r.Run(ctx, state, plan)
	if !errors.Is(err, ErrRolledBack) || !strings.Contains(err.Error(), "upgrade to 1.1.0 was cancelled; 1.0.0 is back and healthy") {
		t.Fatalf("err = %v", err)
	}
	if got := s.rep.first(KindStepFail, StepRestart); got != "cancelled" {
		t.Errorf("the restart step failed with %q", got)
	}
	s.back("1.0.0")
	if s.count("compose up") != 0 || s.count("compose config --quiet") != 0 {
		t.Errorf("compose ran after the cancel: %v", s.f.commands())
	}
	if _, replays, _, _ := s.world(); len(replays) != 0 {
		t.Errorf("the database was replayed: %v", replays)
	}
	undid(t, s.state(), instance.ActionUpgrade, "1.1.0", instance.OutcomeCancelled, "context canceled")
	if last := s.state().History; last[len(last)-1].Note != "1.1.0 was cancelled: context canceled" {
		t.Errorf("the note says %q", last[len(last)-1].Note)
	}
}

// A Ctrl-C during the backup of an upgrade changes nothing, and is said in
// plain words: the backup step was cancelled, which is all its line says;
// the error of the dump the cancel stopped goes to a line of its own.
func TestRunCancelledDuringItsBackupSaysSo(t *testing.T) {
	s := newStack(t, "", rel{version: "1.0.0"}, rel{version: "1.1.0"})
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	s.rep.on = func(e Event) {
		if isLog("dumping the database")(e) {
			cancel()
		}
	}
	r := s.runner()
	state, plan := s.plan(r)
	err := r.Run(ctx, state, plan)
	if err == nil || err.Error() != "upgrade to 1.1.0 cancelled: nothing was changed, the stack is still on 1.0.0" {
		t.Fatalf("err = %v", err)
	}
	if got := s.rep.first(KindStepFail, StepBackup); got != "cancelled" {
		t.Errorf("the backup step failed with %q", got)
	}
	if !s.rep.said("cancelled: docker exec kvs-mariadb: context canceled") {
		t.Errorf("the error of the dump is not kept: %v", s.rep.logs())
	}
	s.back("1.0.0")
}

// A backup whose archive is written but whose directory cannot be flushed
// stops the upgrade before its first change. The error names the archive
// as written, and it stays: this backup did not leave nothing behind.
func TestRunStopsOnABackupWrittenButNotFlushed(t *testing.T) {
	if os.Geteuid() == 0 {
		t.Skip("root opens a directory whatever its mode")
	}
	s := newStack(t, "", rel{version: "1.0.0"}, rel{version: "1.1.0"})
	dir := filepath.Join(s.root, "backups")
	s.rep.on = func(e Event) {
		if isLog("dumping the database")(e) {
			// The archive can still take its name in the directory, which
			// cannot be opened to be flushed.
			if err := os.Chmod(dir, 0o300); err != nil {
				t.Error(err)
			}
		}
	}
	t.Cleanup(func() { _ = os.Chmod(dir, 0o700) })
	err := s.upgrade(s.runner())
	if err := os.Chmod(dir, 0o700); err != nil {
		t.Fatal(err)
	}
	var written *backup.WrittenError
	if !errors.As(err, &written) || !strings.HasPrefix(err.Error(), "upgrade to 1.1.0 failed: backup: "+written.Path+" is written but its directory could not be flushed: ") ||
		!strings.HasSuffix(err.Error(), "; nothing was changed, the stack is still on 1.0.0") {
		t.Fatalf("err = %v", err)
	}
	if _, err := os.Stat(written.Path); err != nil {
		t.Errorf("the archive is gone: %v", err)
	}
	s.back("1.0.0")
}

// A failure in words that name a cancel, an engine that answered "context
// canceled" for a reason of its own, is still a failure: only the cancel
// of the run, the first Ctrl-C or a SIGTERM, makes it a cancelled run, and
// the history keeps which it was.
func TestRunFailingOnAnEngineCancelIsAFailure(t *testing.T) {
	s := newStack(t, "", rel{version: "1.0.0"}, rel{version: "1.1.0"})
	s.failOnce("compose up -d", "Error response from daemon: context canceled")
	err := s.upgrade(s.runner(quick))
	cause := "docker compose up -d: exit status 1: Error response from daemon: context canceled"
	if !errors.Is(err, ErrRolledBack) || !strings.HasPrefix(err.Error(), "upgrade to 1.1.0 failed: "+cause+"; 1.0.0 is back and healthy") {
		t.Fatalf("err = %v", err)
	}
	s.back("1.0.0")
	undid(t, s.state(), instance.ActionUpgrade, "1.1.0", instance.OutcomeFailed, cause)
}

// A series change whose first step, MariaDB alone, fails before the
// container was recreated: the data files were never opened by the new
// server, so they stay, and the backup is replayed because compose ran on
// a run that changes the database. The error says why compose failed, in
// the words compose gave, and not only its exit status.
func TestRunMariaDBFailingAloneKeepsItsDataFiles(t *testing.T) {
	s := newStack(t, "11.8", rel{version: "1.0.0"}, rel{version: "1.1.0"})
	mariadbID := s.containerID("mariadb")
	s.failOnce("compose up -d mariadb", "Error response from daemon: no space left on device")
	err := s.upgrade(s.runner(quick, series("12.3")))
	if !errors.Is(err, ErrRolledBack) || !strings.HasPrefix(err.Error(), "upgrade to 1.1.0 failed: docker compose up -d mariadb: exit status 1: Error response from daemon: no space left on device; 1.0.0 is back and healthy") {
		t.Fatalf("err = %v", err)
	}
	if got := s.rep.first(KindStepFail, StepRestart); got != "docker compose up -d mariadb: exit status 1: Error response from daemon: no space left on device" {
		t.Errorf("the restart step failed with %q", got)
	}
	s.back("1.0.0")
	db, replays, moved, dataSeries := s.world()
	if db != "data-1" || !slices.Equal(replays, []string{"data-1"}) || len(moved) != 0 || dataSeries != "11.8" {
		t.Errorf("database %s, replays %v, moved %v, series %s", db, replays, moved, dataSeries)
	}
	if s.containerID("mariadb") != mariadbID {
		t.Error("the mariadb container was recreated")
	}
	if env := s.env(); env["MARIADB_VERSION"] != "11.8" {
		t.Errorf("MARIADB_VERSION = %q", env["MARIADB_VERSION"])
	}
}

// A series change that failed after MariaDB came up on the new series: the
// previous server cannot open the files the new one upgraded, so they are
// moved aside inside the volume and the backup is replayed into a fresh
// data directory. Without --db-timeout, MariaDB has 30 minutes to be ready
// in the run and in its rollback alike.
func TestRunMariaDBOnANewSeriesIsUndoneFromTheBackup(t *testing.T) {
	s := newStack(t, "11.8", rel{version: "1.0.0"}, rel{version: "1.1.0"})
	s.failOnce("compose up -d", "Error response from daemon: driver failed programming external connectivity")
	err := s.upgrade(s.runner(quick, series("12.3"), func(o *Options) { o.DBTimeout = 0 }))
	if !errors.Is(err, ErrRolledBack) {
		t.Fatalf("err = %v", err)
	}
	for _, line := range []string{
		"starting MariaDB alone first, the other services follow once it is healthy; MariaDB has 30m0s to be ready (--db-timeout)",
		"starting MariaDB alone: the other services start once the database is in place; MariaDB has 30m0s to be ready (--db-timeout)",
	} {
		if !s.rep.said(line) {
			t.Errorf("the run did not say %q: %v", line, s.rep.logs())
		}
	}
	s.back("1.0.0")
	db, replays, moved, dataSeries := s.world()
	if db != "data-1" || !slices.Equal(replays, []string{"data-1"}) || dataSeries != "11.8" {
		t.Errorf("database %s, replays %v, series %s", db, replays, dataSeries)
	}
	if len(moved) != 1 || !strings.HasPrefix(moved[0], keptPrefix) || !s.rep.said("moved aside") {
		t.Errorf("the data files were not moved aside: %v", moved)
	}
	if env := s.env(); env["MARIADB_VERSION"] != "11.8" || env["KVS_MARIADB_IMAGE"] != s.pin("1.0.0", "mariadb@11.8") {
		t.Errorf(".env after the rollback: %v", env)
	}
}

// A release that changes the database and fails its verification: the
// backup is replayed over what its code did to the schema.
func TestRunMigratingReleaseFailingIsReplayed(t *testing.T) {
	s := newStack(t, "", rel{version: "1.0.0"}, rel{version: "1.1.0", database: migrates})
	s.f.behave(registry+"php:1.1.0-php8.1", behavior{unhealthy: true, migrate: "data-1 migrated by 1.1.0"})
	err := s.upgrade(s.runner(quick))
	if !errors.Is(err, ErrRolledBack) || !strings.Contains(err.Error(), "not healthy after") || !strings.Contains(err.Error(), "; log: ") {
		t.Fatalf("err = %v", err)
	}
	s.back("1.0.0")
	if db, replays, moved, _ := s.world(); db != "data-1" || !slices.Equal(replays, []string{"data-1"}) || len(moved) != 0 {
		t.Errorf("database %s, replays %v, moved %v", db, replays, moved)
	}
}

// A release that declares no database change leaves the database as it
// is, and so does a one-way release whose run never recreated MariaDB; an
// operator who wants the dump back asks with --restore-db.
func TestRunLeavesTheDatabaseUnlessItChanged(t *testing.T) {
	cases := []struct {
		name    string
		release rel
		restore bool
		replays []string
	}{
		{"plain", rel{version: "1.1.0"}, false, nil},
		{"one way, MariaDB untouched", rel{version: "1.1.0", oneWay: true}, false, nil},
		{"restore-db", rel{version: "1.1.0"}, true, []string{"data-1"}},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			s := newStack(t, "", rel{version: "1.0.0"}, c.release)
			mariadbID := s.containerID("mariadb")
			s.f.behave(registry+"php:1.1.0-php8.1", behavior{unhealthy: true, migrate: "data-1 written by 1.1.0"})
			err := s.upgrade(s.runner(quick, func(o *Options) { o.RestoreDB = c.restore }))
			if !errors.Is(err, ErrRolledBack) {
				t.Fatalf("err = %v", err)
			}
			s.back("1.0.0")
			db, replays, moved, _ := s.world()
			if !slices.Equal(replays, c.replays) || len(moved) != 0 {
				t.Errorf("replays %v, moved %v", replays, moved)
			}
			if c.replays == nil && db != "data-1 written by 1.1.0" {
				t.Errorf("the database was changed: %s", db)
			}
			// MariaDB keeps its image: nothing starts it alone, and so
			// nothing waits for it alone, unless a dump is replayed.
			if c.replays == nil && s.ran("compose up -d mariadb") >= 0 {
				t.Errorf("MariaDB was started alone: %v", s.f.commands())
			}
			if s.containerID("mariadb") != mariadbID {
				t.Error("the mariadb container was recreated")
			}
		})
	}
}

// A run answers for the containers of the services it adds or drops: the
// rollback of a release that added a service removes its container, which
// would otherwise keep running the code of that release against the
// database the rollback put back, a manual rollback of that release does
// the same, and an upgrade to a release that dropped a service removes the
// container of that service. The container of a service whose profile is
// off is left alone throughout.
func TestRunsRemoveTheContainersOfTheServicesTheyDrop(t *testing.T) {
	gone := func(t *testing.T, s *stack, why string) {
		t.Helper()
		if id := s.containerID("worker"); id != "" {
			t.Errorf("the container of worker is still there")
		}
		if !s.rep.said("removing the containers of worker: " + why) {
			t.Errorf("the removal was not said: %v", s.rep.logs())
		}
		if slices.Contains(s.f.commands(), "compose up -d --remove-orphans") {
			t.Error("compose removed the orphans")
		}
	}
	// offProfile gives the stack the container of a service whose profile
	// is off, stopped.
	offProfile := func(s *stack) {
		s.f.with(func(f *fakeDocker) {
			img := f.registry[s.images["1.0.0"]["manticore"].Digest]
			f.containers["kvs-manticore"] = &fakeContainer{id: fmt.Sprintf("%064x", 999), name: "kvs-manticore", service: "manticore", ref: s.pin("1.0.0", "manticore"), image: img, started: time.Now(), stopped: true}
		})
	}
	t.Run("failed release that adds a service", func(t *testing.T) {
		s := newStack(t, "", rel{version: "1.0.0"}, rel{version: "1.1.0", database: migrates, extra: []string{"worker"}})
		offProfile(s)
		s.f.behave(registry+"php:1.1.0-php8.1", behavior{unhealthy: true, migrate: "data-1 migrated by 1.1.0"})
		if err := s.upgrade(s.runner(quick)); !errors.Is(err, ErrRolledBack) {
			t.Fatalf("err = %v", err)
		}
		s.back("1.0.0")
		gone(t, s, "the run undone added them")
		if s.containerID("manticore") == "" {
			t.Error("the container of a service whose profile is off was removed")
		}
		if s.rep.said("pulling " + s.pin("1.0.0", "manticore")) {
			t.Error("the image of a service whose profile is off was pulled")
		}
	})
	t.Run("manual rollback of a release that adds a service", func(t *testing.T) {
		s := newStack(t, "", rel{version: "1.0.0"}, rel{version: "1.1.0", extra: []string{"worker"}})
		if err := s.upgrade(s.runner()); err != nil {
			t.Fatalf("upgrade: %v", err)
		}
		if s.running("worker") != s.pin("1.1.0", "worker") {
			t.Fatalf("worker does not run the image of 1.1.0: %q", s.running("worker"))
		}
		s.fresh()
		if err := s.rollback(s.runner()); err != nil {
			t.Fatalf("rollback: %v", err)
		}
		s.back("1.0.0")
		gone(t, s, "the files laid no longer run them")
	})
	t.Run("release that drops a service", func(t *testing.T) {
		s := newStack(t, "", rel{version: "1.0.0", extra: []string{"worker"}}, rel{version: "1.1.0"})
		offProfile(s)
		if err := s.upgrade(s.runner()); err != nil {
			t.Fatalf("upgrade: %v", err)
		}
		s.back("1.1.0")
		gone(t, s, "the files laid no longer run them")
		if s.containerID("manticore") == "" {
			t.Error("the container of a service whose profile is off was removed")
		}
	})
}

// A failure before the journal, here a pull, changes nothing and is no
// rollback: none of the sentinels, so kvsctl exits 1, not 4.
func TestRunFailingBeforeAnyChangeLeavesTheStack(t *testing.T) {
	s := newStack(t, "", rel{version: "1.0.0"}, rel{version: "1.1.0"})
	s.f.with(func(f *fakeDocker) { delete(f.registry, s.images["1.1.0"]["php-fpm@8.1"].Digest) })
	err := s.upgrade(s.runner())
	if err == nil || errors.Is(err, ErrRolledBack) || !strings.Contains(err.Error(), "nothing was changed, the stack is still on 1.0.0") {
		t.Fatalf("err = %v", err)
	}
	s.ended(err)
	s.back("1.0.0")
	if s.count("compose up") != 0 {
		t.Error("compose started")
	}
}

// The bundle is read no further than the size the signed manifest gives:
// a server that sends more without announcing it, an asset replaced since
// the release, is cut off there, before what it sends fills the disk the
// backups share and well before its checksum would refuse it. The run ends
// as one that changed nothing.
func TestRunStopsTheBundleAtItsSignedSize(t *testing.T) {
	s := newStack(t, "", rel{version: "1.0.0"}, rel{version: "1.1.0"})
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		chunk := make([]byte, 64<<10)
		for range 64 {
			if _, err := w.Write(chunk); err != nil {
				return
			}
			w.(http.Flusher).Flush()
		}
	}))
	defer srv.Close()
	r := s.runner()
	state, plan := s.plan(r)
	plan.Target.Bundle.URL = srv.URL + "/kvs-stack-1.1.0.tar.gz"
	err := r.Run(context.Background(), state, plan)
	past := fmt.Sprintf("goes past the %d bytes the signed manifest gives: refused", plan.Target.Bundle.Size)
	if err == nil || !strings.Contains(err.Error(), past) || !strings.HasSuffix(err.Error(), "nothing was changed, the stack is still on 1.0.0") || errors.Is(err, ErrRolledBack) {
		t.Fatalf("err = %v", err)
	}
	s.back("1.0.0")
	if _, err := os.Stat(filepath.Join(s.root, "kvsctl", "downloads", "kvs-stack-1.1.0.tar.gz.part")); !errors.Is(err, os.ErrNotExist) {
		t.Errorf("the part of the download is left: %v", err)
	}
	if s.count("compose up") != 0 {
		t.Error("compose started")
	}
}

// What stands in the way of the files of a release, found as they are
// laid, stops Sync before its first change: here a release directory the
// operator replaced by a link to a copy kept elsewhere, after the plan. The
// run ends there, as one that changed nothing: no rollback lays the files
// back through the same link, no journal is left, and the message says
// what to do. A re-apply leaves no staged release behind either.
func TestRunWhoseFilesCannotTakeTheirPlaceChangesNothing(t *testing.T) {
	geoip := func(v string) map[string]string {
		return map[string]string{"docker/geoip/README.md": "GeoIP database of " + v + "\n"}
	}
	for _, reapply := range []bool{false, true} {
		t.Run(fmt.Sprintf("re-apply %v", reapply), func(t *testing.T) {
			releases := []rel{{version: "1.1.0", files: geoip("1.1.0")}}
			target := "1.1.0"
			if reapply {
				releases, target = nil, "1.0.0"
			}
			s := newStack(t, "", rel{version: "1.0.0", php: []string{"8.1", "8.3"}, files: geoip("1.0.0")}, releases...)
			if reapply {
				s.setEnv("PHP_VERSION", "8.3")
			}
			r := s.runner()
			state, plan := s.plan(r)
			if plan.Reapply != reapply || len(plan.Blockers) > 0 {
				t.Fatalf("plan: re-apply %v, blockers %v", plan.Reapply, plan.Blockers)
			}
			// The files of 1.0.0 are kept, as on a stack kvsctl upgraded.
			if err := release.Snapshot(s.root, r.releaseDir("1.0.0"), state.Files); err != nil {
				t.Fatal(err)
			}
			link, shared := filepath.Join(s.root, "docker", "geoip"), filepath.Join(t.TempDir(), "GeoIP")
			if err := os.Rename(link, shared); err != nil {
				t.Fatal(err)
			}
			if err := os.Symlink(shared, link); err != nil {
				t.Fatal(err)
			}
			envBefore, before := s.file("docker/.env"), len(s.f.commands())
			err := r.Run(context.Background(), state, plan)
			if err == nil || !strings.Contains(err.Error(), "upgrade to "+target+" failed: lay the release files: docker/geoip is a symbolic link, which kvsctl does not follow below "+s.root+": make it a directory") ||
				!strings.HasSuffix(err.Error(), "nothing was changed, the stack is still on 1.0.0") || errors.Is(err, ErrRolledBack) || errors.Is(err, ErrRollbackFailed) {
				t.Fatalf("err = %v", err)
			}
			s.ended(err)
			s.back("1.0.0")
			if got := s.file("docker/.env"); got != envBefore {
				t.Errorf(".env changed:\n%s", got)
			}
			if got, err := os.Readlink(link); err != nil || got != shared {
				t.Errorf("the link is now %q, %v", got, err)
			}
			for _, cmd := range s.f.commands()[before:] {
				if strings.HasPrefix(cmd, "compose ") && !strings.HasPrefix(cmd, "compose config ") {
					t.Errorf("the run ran docker %s", cmd)
				}
			}
			if _, err := os.Stat(r.stagingDir("1.0.0")); !errors.Is(err, os.ErrNotExist) {
				t.Errorf("the staged release is left: %v", err)
			}
		})
	}
}

// An interrupt while the release is staged stops the run before its
// journal: nothing of the installation changed, so nothing is laid and
// nothing laid back, and a re-apply leaves no staged release behind.
func TestRunInterruptedWhileItStagesChangesNothing(t *testing.T) {
	for _, reapply := range []bool{false, true} {
		t.Run(fmt.Sprintf("re-apply %v", reapply), func(t *testing.T) {
			releases := []rel{{version: "1.1.0"}}
			target := "1.1.0"
			if reapply {
				releases, target = nil, "1.0.0"
			}
			s := newStack(t, "", rel{version: "1.0.0", php: []string{"8.1", "8.3"}}, releases...)
			if reapply {
				s.setEnv("PHP_VERSION", "8.3")
			}
			r := s.runner()
			state, plan := s.plan(r)
			ctx, cancel := context.WithCancel(context.Background())
			defer cancel()
			s.rep.on = func(e Event) {
				if e.Kind == KindLog && strings.HasPrefix(e.Message, "bundle verified") {
					cancel()
				}
			}
			envBefore := s.file("docker/.env")
			err := r.Run(ctx, state, plan)
			if want := "upgrade to " + target + " cancelled: nothing was changed, the stack is still on 1.0.0"; err == nil || err.Error() != want {
				t.Fatalf("err = %v, want %q", err, want)
			}
			s.ended(err)
			s.back("1.0.0")
			if got := s.file("docker/.env"); got != envBefore {
				t.Errorf(".env changed:\n%s", got)
			}
			if got := s.rep.first(KindStepStart, StepRollbck); got != "" {
				t.Errorf("a rollback ran: %q", got)
			}
			if _, err := os.Stat(r.stagingDir("1.0.0")); !errors.Is(err, os.ErrNotExist) {
				t.Errorf("the staged release is left: %v", err)
			}
		})
	}
}

// gate is a recorder that answers Begin as the guard of kvsctl does: yes,
// or no, and then, when set, the interrupt that follows the answer.
type gate struct {
	*recorder
	yes   bool
	then  func()
	asked int
}

func (g *gate) Begin() bool {
	g.asked++
	if g.then != nil {
		g.then()
	}
	return g.yes
}

// A reporter that owns the interrupt decides whether the upgrade begins its
// first change, its journal: a no stops the run there, its context still
// live, and a yes holds although the interrupt comes right after it, so
// the run goes on and rolls back what it changed, as that reporter said.
func TestRunAsksTheGateBeforeItsFirstChange(t *testing.T) {
	t.Run("no", func(t *testing.T) {
		s := newStack(t, "", rel{version: "1.0.0"}, rel{version: "1.1.0"})
		r := s.runner()
		g := &gate{recorder: s.rep}
		r.Reporter = g
		state, plan := s.plan(r)
		err := r.Run(context.Background(), state, plan)
		if want := "upgrade to 1.1.0 cancelled: nothing was changed, the stack is still on 1.0.0"; err == nil || err.Error() != want {
			t.Fatalf("err = %v, want %q", err, want)
		}
		if g.asked != 1 {
			t.Errorf("asked %d times", g.asked)
		}
		s.ended(err)
		s.back("1.0.0")
		if j := s.journal(); j != nil {
			t.Errorf("the journal is there: %+v", j)
		}
		if got := s.rep.first(KindStepStart, StepRollbck); got != "" {
			t.Errorf("a rollback ran: %q", got)
		}
	})
	t.Run("yes, then the interrupt", func(t *testing.T) {
		s := newStack(t, "", rel{version: "1.0.0"}, rel{version: "1.1.0"})
		ctx, cancel := context.WithCancel(context.Background())
		defer cancel()
		r := s.runner(quick)
		g := &gate{recorder: s.rep, yes: true, then: cancel}
		r.Reporter = g
		state, plan := s.plan(r)
		err := r.Run(ctx, state, plan)
		if !errors.Is(err, ErrRolledBack) || !strings.Contains(err.Error(), "upgrade to 1.1.0 was cancelled; 1.0.0 is back and healthy") {
			t.Fatalf("err = %v", err)
		}
		if g.asked != 1 {
			t.Errorf("asked %d times", g.asked)
		}
		if got := s.rep.first(KindStepDone, StepApply); got == "" {
			t.Error("the files were not laid")
		}
		s.back("1.0.0")
	})
}

// A lay that fails after its first write, for a reason Sync cannot see
// before it changes anything (here a directory it may not write to, met
// once the files before it are laid), is no conflict: the run is rolled
// back under its journal, and never says that nothing was changed. The
// directory takes writes again once the rollback starts, as after an
// operator who fixed it.
func TestRunWhoseLayFailsPartWayRollsBack(t *testing.T) {
	if os.Geteuid() == 0 {
		t.Skip("root writes to a directory whatever its mode")
	}
	conf := func(v string) map[string]string {
		return map[string]string{"conf/site.conf": "site of " + v + "\n"}
	}
	s := newStack(t, "", rel{version: "1.0.0", files: conf("1.0.0")}, rel{version: "1.1.0", files: conf("1.1.0")})
	r := s.runner(quick)
	state, plan := s.plan(r)
	dir := filepath.Join(s.root, "conf")
	if err := os.Chmod(dir, 0o555); err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = os.Chmod(dir, 0o755) })
	laid := ""
	s.rep.on = func(e Event) {
		if e.Kind == KindStepStart && e.Step == StepRollbck {
			laid = s.file("README.md")
			if err := os.Chmod(dir, 0o755); err != nil {
				t.Error(err)
			}
		}
	}
	err := r.Run(context.Background(), state, plan)
	if !errors.Is(err, ErrRolledBack) || !strings.Contains(err.Error(), "lay the release files: ") || strings.Contains(err.Error(), "nothing was changed") {
		t.Fatalf("err = %v, want a rollback of the files laid", err)
	}
	if !strings.Contains(laid, "1.1.0") {
		t.Errorf("the lay had not changed README.md when it failed: %q", laid)
	}
	s.ended(err)
	s.back("1.0.0")
	if got := s.file("conf/site.conf"); got != "site of 1.0.0\n" {
		t.Errorf("conf/site.conf holds %q", got)
	}
}

// The installed release applied again with the images of another PHP
// series: its files are staged apart until it is recorded, both versions
// of the state are the same, and the next plan finds the stack up to date.
func TestReapplyMovesToAnotherPHPSeries(t *testing.T) {
	s := newStack(t, "", rel{version: "1.0.0", php: []string{"8.1", "8.3"}})
	before := s.state()
	s.setEnv("PHP_VERSION", "8.3")
	r := s.runner()
	state, plan := s.plan(r)
	if !plan.Reapply || plan.UpToDate || plan.PHPSeries != "8.3" || len(plan.Blockers) != 0 {
		t.Fatalf("plan: reapply %v, up to date %v, PHP %s, blockers %v", plan.Reapply, plan.UpToDate, plan.PHPSeries, plan.Blockers)
	}
	if err := r.Run(context.Background(), state, plan); err != nil {
		t.Fatalf("re-apply: %v", err)
	}
	s.back("1.0.0")
	after := s.state()
	// The version before ran PHP 8.1, which .env no longer says: the
	// series of the images the state recorded tells it.
	want := withComposeFile(before.Images, "docker-compose.yml:"+ReleaseOverride)
	want["PHP_VERSION"] = "8.1"
	if after.Previous != "1.0.0" || after.Images["KVS_PHP_FPM_IMAGE"] != s.pin("1.0.0", "php-fpm@8.3") || after.Images["PHP_VERSION"] != "8.3" || !maps.Equal(after.PreviousImages, want) {
		t.Errorf("state after the re-apply: previous %s, images %v, previous images %v", after.Previous, after.Images, after.PreviousImages)
	}
	if !slices.Equal(after.PreviousFiles, after.Files) {
		t.Errorf("previous files %v, files %v", after.PreviousFiles, after.Files)
	}
	if pins := after.ReleaseImages["1.0.0"]; !slices.Contains(pins, s.pin("1.0.0", "php-fpm@8.1")) || !slices.Contains(pins, s.pin("1.0.0", "php-fpm@8.3")) {
		t.Errorf("the images of both series are not kept for the version: %v", pins)
	}
	if last := after.History[len(after.History)-1]; last.Note != "applied again with other images" {
		t.Errorf("history ends with %+v", last)
	}
	if _, err := os.Stat(r.stagingDir("1.0.0")); !errors.Is(err, os.ErrNotExist) {
		t.Errorf("the staging directory is still there: %v", err)
	}
	if _, err := os.Stat(filepath.Join(r.releaseDir("1.0.0"), "docker", "RELEASE")); err != nil {
		t.Errorf("the release directory lost its files: %v", err)
	}
	if _, again := s.plan(s.runner()); !again.UpToDate {
		t.Errorf("the stack is not up to date after the re-apply: %v", again.Blockers)
	}
}

// A re-apply that fails puts the images the version ran before back.
func TestReapplyFailureRestoresTheImages(t *testing.T) {
	s := newStack(t, "", rel{version: "1.0.0", php: []string{"8.1", "8.3"}})
	before := s.state()
	s.setEnv("PHP_VERSION", "8.3")
	s.f.behave(registry+"php:1.0.0-php8.3", behavior{unhealthy: true})
	r := s.runner(quick)
	err := s.upgrade(r)
	if !errors.Is(err, ErrRolledBack) || !strings.Contains(err.Error(), "1.0.0 with the images it ran before is back and healthy") {
		t.Fatalf("err = %v", err)
	}
	s.back("1.0.0")
	after := s.state()
	if after.Previous != "" || !maps.Equal(after.Images, before.Images) {
		t.Errorf("state after the failed re-apply: previous %q, images %v", after.Previous, after.Images)
	}
	if _, err := os.Stat(r.stagingDir("1.0.0")); !errors.Is(err, os.ErrNotExist) {
		t.Errorf("the staging directory is still there: %v", err)
	}
	// The PHP series the stack runs is the one .env says again: the next
	// plan does not ask for the same re-apply.
	if env := s.env(); env["PHP_VERSION"] != "8.1" {
		t.Errorf("PHP_VERSION=%s after the rollback to the images of PHP 8.1", env["PHP_VERSION"])
	}
	if _, again := s.plan(s.runner()); !again.UpToDate {
		t.Errorf("the next plan: re-apply %v, PHP %s, blockers %v", again.Reapply, again.PHPSeries, again.Blockers)
	}
}

// A re-apply after an upgrade keeps the version before as the way back,
// with its files, its images and the settings it ran with, PHP_VERSION
// included: the manual rollback returns to it and puts them all back.
func TestReapplyAfterAnUpgradeKeepsTheWayBack(t *testing.T) {
	s := newStack(t, "", rel{version: "1.0.0"}, rel{version: "1.1.0", php: []string{"8.1", "8.3"}})
	if err := s.upgrade(s.runner()); err != nil {
		t.Fatalf("upgrade: %v", err)
	}
	upgraded := s.state()
	s.setEnv("PHP_VERSION", "8.3")
	r := s.runner()
	state, plan := s.plan(r)
	if !plan.Reapply || plan.PHPSeries != "8.3" {
		t.Fatalf("plan: re-apply %v, PHP %s", plan.Reapply, plan.PHPSeries)
	}
	if err := r.Run(context.Background(), state, plan); err != nil {
		t.Fatalf("re-apply: %v", err)
	}
	s.back("1.1.0")
	after := s.state()
	if after.Previous != "1.0.0" || !slices.Equal(after.PreviousFiles, upgraded.PreviousFiles) || !maps.Equal(after.PreviousImages, upgraded.PreviousImages) {
		t.Errorf("the way back after the re-apply: previous %s, files %v, images %v", after.Previous, after.PreviousFiles, after.PreviousImages)
	}
	if after.Images["PHP_VERSION"] != "8.3" || after.Images["KVS_PHP_FPM_IMAGE"] != s.pin("1.1.0", "php-fpm@8.3") {
		t.Errorf("images after the re-apply: %v", after.Images)
	}
	if _, err := os.Stat(filepath.Join(r.releaseDir("1.0.0"), "docker", "RELEASE")); err != nil {
		t.Errorf("the files of 1.0.0 are not kept: %v", err)
	}

	s.fresh()
	if err := s.rollback(s.runner()); err != nil {
		t.Fatalf("rollback: %v", err)
	}
	s.back("1.0.0")
	if env := s.env(); env["PHP_VERSION"] != "8.1" {
		t.Errorf("PHP_VERSION=%s after the rollback to 1.0.0", env["PHP_VERSION"])
	}
	if got := s.state(); got.Previous != "1.1.0" || got.PreviousImages["PHP_VERSION"] != "8.3" {
		t.Errorf("state after the rollback: previous %s, previous images %v", got.Previous, got.PreviousImages)
	}
}

// A re-apply that moves MariaDB to the next series after an upgrade that
// left the series alone: the way back records the series the version
// before ran, which that upgrade had no reason to record, so the manual
// rollback puts MARIADB_VERSION back with the image, and the archive goes
// back into data files of that series.
func TestSeriesReapplyAfterAnUpgradeRolledBack(t *testing.T) {
	s := newStack(t, "", rel{version: "1.0.0"}, rel{version: "1.1.0"})
	if err := s.upgrade(s.runner()); err != nil {
		t.Fatalf("upgrade: %v", err)
	}
	if previous, ok := s.state().PreviousImages[mariadbVersionKey]; ok {
		t.Fatalf("the upgrade recorded MARIADB_VERSION=%s for 1.0.0", previous)
	}
	r := s.runner(series("12.3"))
	state, plan := s.plan(r)
	if !plan.Reapply || !plan.MariaDBUpgrade {
		t.Fatalf("plan: re-apply %v, series change %v, blockers %v", plan.Reapply, plan.MariaDBUpgrade, plan.Blockers)
	}
	if err := r.Run(context.Background(), state, plan); err != nil {
		t.Fatalf("re-apply on 12.3: %v", err)
	}
	if after := s.state(); after.Previous != "1.0.0" || after.PreviousImages[mariadbVersionKey] != "11.8" {
		t.Errorf("the way back after the re-apply: %s with %v", after.Previous, after.PreviousImages)
	}
	s.fresh()
	if err := s.rollback(s.runner()); err != nil {
		t.Fatalf("rollback: %v", err)
	}
	s.back("1.0.0")
	if env := s.env(); env[mariadbVersionKey] != "11.8" {
		t.Errorf("MARIADB_VERSION=%q after the rollback to 1.0.0, which ran 11.8", env[mariadbVersionKey])
	}
	if db, _, _, dataSeries := s.world(); db != "data-1" || dataSeries != "11.8" {
		t.Errorf("after the rollback: database %q on data files of %s", db, dataSeries)
	}
}

// The other side of the rule: an upgrade that moved MariaDB wrote
// MARIADB_VERSION into a .env that had no such line, and its way back
// records that absence. A re-apply that moves MariaDB again must keep it,
// image key or not, so the manual rollback removes the line and the
// version before runs as it did, on its image and data files of 11.4.
func TestSeriesReapplyKeepsAMissingSettingMissing(t *testing.T) {
	versions := map[string]string{"11.4": "11.4.13", "11.8": "11.8.9", "12.3": "12.3.3"}
	s := newStack(t, "11.4", rel{version: "1.0.0", mariadb: versions}, rel{version: "1.1.0", mariadb: versions})
	inst, err := instance.Detect(s.root)
	if err != nil {
		t.Fatal(err)
	}
	if err := inst.UnsetEnv(mariadbVersionKey); err != nil {
		t.Fatal(err)
	}
	image := s.env()[ImageEnvKey(mariadbService)]
	if err := s.upgrade(s.runner(series("11.8"))); err != nil {
		t.Fatalf("upgrade to 1.1.0 on 11.8: %v", err)
	}
	if previous, ok := s.state().PreviousImages[mariadbVersionKey]; ok {
		t.Fatalf("the upgrade recorded MARIADB_VERSION=%s for 1.0.0, which ran without it", previous)
	}
	r := s.runner(series("12.3"))
	state, plan := s.plan(r)
	if !plan.Reapply || !plan.MariaDBUpgrade {
		t.Fatalf("plan: re-apply %v, series change %v, blockers %v", plan.Reapply, plan.MariaDBUpgrade, plan.Blockers)
	}
	if err := r.Run(context.Background(), state, plan); err != nil {
		t.Fatalf("re-apply on 12.3: %v", err)
	}
	if previous, ok := s.state().PreviousImages[mariadbVersionKey]; ok {
		t.Errorf("the way back after the re-apply records MARIADB_VERSION=%s, which 1.0.0 ran without", previous)
	}
	s.fresh()
	if err := s.rollback(s.runner()); err != nil {
		t.Fatalf("rollback: %v", err)
	}
	s.back("1.0.0")
	env := s.env()
	if v, ok := env[mariadbVersionKey]; ok {
		t.Errorf("MARIADB_VERSION=%s after the rollback to 1.0.0, which ran without it", v)
	}
	if got := env[ImageEnvKey(mariadbService)]; got != image {
		t.Errorf("%s=%s after the rollback, want %s", ImageEnvKey(mariadbService), got, image)
	}
	if db, _, _, dataSeries := s.world(); db != "data-1" || dataSeries != "11.4" {
		t.Errorf("after the rollback: database %q on data files of %s, want data-1 on 11.4", db, dataSeries)
	}
}

// A re-apply after an upgrade that changed the database keeps the archive
// that upgrade took as the one a rollback replays: the archive the re-apply
// takes holds the database the newer version migrated, which the version
// before cannot run on.
func TestReapplyKeepsTheArchiveOfTheVersionBefore(t *testing.T) {
	s := newStack(t, "", rel{version: "1.0.0"}, rel{version: "1.1.0", database: migrates, php: []string{"8.1", "8.3"}})
	s.f.behave(registry+"php:1.1.0-php8.1", behavior{migrate: "data-1 migrated by 1.1.0"})
	if err := s.upgrade(s.runner()); err != nil {
		t.Fatalf("upgrade: %v", err)
	}
	first := s.state().UpgradeBackup
	s.reapplyOnPHP83()
	if got := s.state().UpgradeBackup; got != first {
		t.Errorf("the archive a rollback replays is %s, want %s, which the upgrade from 1.0.0 took", filepath.Base(got), filepath.Base(first))
	}
	s.fresh()
	if err := s.rollback(s.runner()); err != nil {
		t.Fatalf("rollback: %v", err)
	}
	s.back("1.0.0")
	if db, _, _, _ := s.world(); db != "data-1" {
		t.Errorf("the database after the rollback to 1.0.0 is %q, want data-1", db)
	}
}

// The installed release applied again to move MariaDB to the next series.
// Its manual rollback returns to the previous series, and the rollback after
// that is refused: only an upgrade moves MariaDB forward.
func TestReapplyMovesMariaDBToTheNextSeries(t *testing.T) {
	s := newStack(t, "11.8", rel{version: "1.0.0"})
	r := s.runner(series("12.3"))
	state, plan := s.plan(r)
	if !plan.Reapply || !plan.MariaDBUpgrade || !plan.OneWay || plan.action() != "apply 1.0.0 again with the images of PHP 8.1 and MariaDB moved from 11.8 to 12.3" {
		t.Fatalf("plan: %+v", plan)
	}
	if err := r.Run(context.Background(), state, plan); err != nil {
		t.Fatalf("re-apply: %v", err)
	}
	s.back("1.0.0")
	if _, _, _, dataSeries := s.world(); dataSeries != "12.3" || s.env()["MARIADB_VERSION"] != "12.3" {
		t.Fatalf("MariaDB runs %s, MARIADB_VERSION=%s", dataSeries, s.env()["MARIADB_VERSION"])
	}

	s.fresh()
	if err := s.rollback(s.runner()); err != nil {
		t.Fatalf("rollback: %v", err)
	}
	s.back("1.0.0")
	if _, _, moved, dataSeries := s.world(); len(moved) != 1 || dataSeries != "11.8" || s.env()["MARIADB_VERSION"] != "11.8" {
		t.Errorf("after the rollback: moved %v, series %s, MARIADB_VERSION=%s", moved, dataSeries, s.env()["MARIADB_VERSION"])
	}
	if _, again := s.plan(s.runner()); !again.UpToDate {
		t.Errorf("the stack is not up to date on its series: %v", again.Blockers)
	}

	s.fresh()
	err := s.rollback(s.runner())
	if err == nil || !strings.Contains(err.Error(), "a rollback never moves MariaDB to a newer series; to move it again run 'kvsctl upgrade --version 1.0.0 --mariadb-series 12.3'") {
		t.Errorf("err = %v", err)
	}
}

func TestRunRefusesAnUpToDateStack(t *testing.T) {
	s := newStack(t, "", rel{version: "1.0.0"})
	r := s.runner()
	state, plan := s.plan(r)
	if !plan.UpToDate {
		t.Fatalf("plan is not up to date: %+v", plan.Blockers)
	}
	err := r.Run(context.Background(), state, plan)
	if err == nil || err.Error() != "1.0.0 is already installed with the images it pins" {
		t.Errorf("err = %v", err)
	}
	s.ended(err)
}

// A jump over a release that changes the database and is one way carries
// both, shows the notes of every release it installs before the question,
// and refuses --skip-backup.
func TestJumpCarriesTheFlagsOfSkippedReleases(t *testing.T) {
	s := newStack(t, "", rel{version: "1.0.0"},
		rel{version: "1.1.0", database: migrates, oneWay: true, notes: "new tables for playlists"},
		rel{version: "1.2.0", notes: "faster thumbnails"})
	_, skipped := s.plan(s.runner(func(o *Options) { o.SkipBackup = true }))
	if !slices.ContainsFunc(skipped.Blockers, func(b string) bool {
		return strings.Contains(b, "--skip-backup cannot be used here: 1.1.0 cannot be undone")
	}) {
		t.Errorf("--skip-backup was not refused: %v", skipped.Blockers)
	}

	s.rep.answer = false
	r := s.runner(func(o *Options) { o.Yes = false })
	state, plan := s.plan(r)
	if plan.Target.Version != "1.2.0" || len(plan.Releases) != 2 || plan.Database != migrates || !plan.OneWay {
		t.Fatalf("plan: target %s, %d releases, database %q, one way %v", plan.Target.Version, len(plan.Releases), plan.Database, plan.OneWay)
	}
	err := r.Run(context.Background(), state, plan)
	if err == nil || err.Error() != "upgrade cancelled, nothing was changed" {
		t.Fatalf("err = %v", err)
	}
	if len(s.rep.questions) != 1 || !strings.HasPrefix(s.rep.questions[0], "example.com: upgrade from 1.0.0 to 1.2.0 (") {
		t.Fatalf("questions: %q", s.rep.questions)
	}
	asked := s.rep.asked[0]
	for _, line := range []string{"1.1.0: new tables for playlists", "1.2.0: faster thumbnails", "the database changes (1.1.0)", "this upgrade is one way"} {
		at := slices.IndexFunc(s.rep.events, func(e Event) bool { return e.Kind == KindLog && strings.Contains(e.Message, line) })
		if at < 0 || at > asked {
			t.Errorf("%q was not shown before the question (event %d, question after %d)", line, at, asked)
		}
	}
	if list, _ := os.ReadDir(filepath.Join(s.root, "backups")); len(list) != 0 || s.journal() != nil {
		t.Error("a declined upgrade took a backup or left a journal")
	}

	s.fresh()
	if err := s.upgrade(s.runner()); err != nil {
		t.Fatalf("upgrade: %v", err)
	}
	if after := s.state(); after.Current != "1.2.0" || after.Database != migrates || !after.OneWay {
		t.Errorf("the state does not carry what the jump did: %s %q %v", after.Current, after.Database, after.OneWay)
	}
}

// ErrNotRecorded, exit 8: the upgrade passed its verification but the
// state could not be written. The journal is left in its record phase, and
// recover writes the record once the cause is gone.
func TestRunThatCannotBeRecordedIsRecordedByRecover(t *testing.T) {
	s := newStack(t, "", rel{version: "1.0.0"}, rel{version: "1.1.0"})
	statePath := filepath.Join(s.root, "kvsctl", "state.json")
	saved, err := os.ReadFile(statePath)
	if err != nil {
		t.Fatal(err)
	}
	s.rep.on = func(e Event) {
		if isStep(KindStepDone, StepVerify)(e) {
			// A directory where the state goes: the atomic rename fails.
			_ = os.Remove(statePath)
			_ = os.MkdirAll(filepath.Join(statePath, "in-the-way"), 0o755)
		}
	}
	err = s.upgrade(s.runner())
	if !errors.Is(err, ErrNotRecorded) || !strings.Contains(err.Error(), "1.1.0 is installed and the site is healthy, but its record in") || !strings.Contains(err.Error(), "run 'kvsctl recover' to record it; log: ") {
		t.Fatalf("err = %v", err)
	}
	if j := s.journal(); j == nil || j.Phase != instance.PhaseRecord {
		t.Fatalf("journal: %+v", j)
	}
	if err := os.RemoveAll(statePath); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(statePath, saved, 0o600); err != nil {
		t.Fatal(err)
	}
	s.fresh()
	ups := s.count("compose up")
	if err := s.recover(s.runner()); err != nil {
		t.Fatalf("recover: %v", err)
	}
	s.back("1.1.0")
	if s.count("compose up") != ups {
		t.Error("recover restarted the stack to record a run")
	}
	if env := s.env(); env["KVS_STACK_VERSION"] != "1.1.0" {
		t.Errorf("KVS_STACK_VERSION = %q", env["KVS_STACK_VERSION"])
	}
}

// A run never starts over the journal of one that was interrupted.
func TestRunRefusesWhileAJournalIsThere(t *testing.T) {
	s := newStack(t, "", rel{version: "1.0.0"}, rel{version: "1.1.0"})
	r := s.runner()
	state, plan := s.plan(r)
	if err := r.Inst.SaveJournal(&instance.Journal{Action: instance.ActionUpgrade, From: "1.0.0", To: "1.1.0", Phase: instance.PhaseVerify}); err != nil {
		t.Fatal(err)
	}
	err := r.Run(context.Background(), state, plan)
	if err == nil || !strings.Contains(err.Error(), "an upgrade from 1.0.0 to 1.1.0 was interrupted during verify") || !strings.Contains(err.Error(), "run 'kvsctl recover'") {
		t.Fatalf("err = %v", err)
	}
	s.ended(err)
	if s.count("compose up") != 0 || s.count("exec") != 1 {
		t.Errorf("the refused run did something: %v", s.f.commands())
	}
}

// adoptUnreleased records the installed stack the way adopt records a git
// checkout that no release names: version 0.0.0, with its commit, made
// before the releases of the manifest. It returns how kvsctl names it.
func (s *stack) adoptUnreleased() string {
	s.t.Helper()
	inst, err := instance.Detect(s.root)
	if err != nil {
		s.t.Fatal(err)
	}
	state := s.state()
	state.Current = instance.Unreleased
	state.AdoptedCommit = commit("checkout")
	state.AdoptedCommitDate = time.Date(2026, 9, 20, 10, 0, 0, 0, time.UTC)
	state.ReleaseImages = nil
	state.History = []instance.Entry{{Version: instance.Unreleased, Action: "adopt", Date: time.Now().UTC().Add(-time.Hour), Note: "commit " + commit("checkout")[:12]}}
	if err := inst.SaveState(state); err != nil {
		s.t.Fatal(err)
	}
	return "unreleased checkout " + commit("checkout")[:12]
}

// first is the message of the first event of a kind for a step.
func (r *recorder) first(kind Kind, step string) string {
	r.mu.Lock()
	defer r.mu.Unlock()
	for _, e := range r.events {
		if e.Kind == kind && e.Step == step {
			return e.Message
		}
	}
	return ""
}

// The checkout adopt recorded as 0.0.0 reads as that checkout, by its
// commit, wherever a run names it: the question of the first upgrade and
// the blockers of its plan, the rollback of an upgrade that failed, a
// manual rollback back to it, a target older than the release installed
// since, a rollback to it cut short, as a refusal and in recover, and one
// whose record cannot be written. The state, the journal and the history
// keep 0.0.0.
func TestAnUnreleasedCheckoutReadsAsItsCommit(t *testing.T) {
	t.Run("upgrade and rollback", func(t *testing.T) {
		s := newStack(t, "", rel{version: "1.0.0"}, rel{version: "1.1.0"})
		label := s.adoptUnreleased()
		readme := filepath.Join(s.root, "README.md")
		original, err := os.ReadFile(readme)
		if err != nil {
			t.Fatal(err)
		}
		if err := os.WriteFile(readme, []byte("edited\n"), 0o644); err != nil {
			t.Fatal(err)
		}
		_, plan := s.plan(s.runner())
		blocked(t, plan, "1 release file changed since "+label+" was installed (README.md)")
		if err := os.WriteFile(readme, original, 0o644); err != nil {
			t.Fatal(err)
		}

		if err := s.upgrade(s.runner(func(o *Options) { o.Yes = false })); err != nil {
			t.Fatalf("upgrade: %v", err)
		}
		if q := s.rep.questions; len(q) != 1 || !strings.HasPrefix(q[0], "example.com: upgrade from "+label+" to 1.1.0 (") {
			t.Errorf("question: %q", q)
		}
		if got := s.rep.first(KindStepStart, StepConfirm); got != "Upgrade from "+label+" to 1.1.0?" {
			t.Errorf("confirm step: %q", got)
		}
		if !s.rep.said("keeping the files of " + label + " for a rollback") {
			t.Errorf("the log does not name the files kept: %q", s.rep.logs())
		}
		state := s.state()
		if state.Current != "1.1.0" || state.Previous != instance.Unreleased || state.History[len(state.History)-1].Note != "from 0.0.0" {
			t.Errorf("the state records %s, previous %s, history %+v", state.Current, state.Previous, state.History)
		}

		s.fresh()
		if err := s.rollback(s.runner(func(o *Options) { o.Yes = false })); err != nil {
			t.Fatalf("rollback: %v", err)
		}
		if q := s.rep.questions; len(q) != 1 || q[0] != "Roll back to "+label+"? The database is left as it is." {
			t.Errorf("rollback question: %q", q)
		}
		if got := s.rep.first(KindStepStart, StepConfirm); got != "Roll example.com back from 1.1.0 to "+label+"?" {
			t.Errorf("rollback confirm step: %q", got)
		}
		if got := s.rep.first(KindStepStart, StepApply); got != "files of "+label {
			t.Errorf("rollback apply step: %q", got)
		}
		if state := s.state(); state.Current != instance.Unreleased || state.Previous != "1.1.0" {
			t.Errorf("after the rollback the state records %s, previous %s", state.Current, state.Previous)
		}
	})
	t.Run("failed upgrade", func(t *testing.T) {
		s := newStack(t, "", rel{version: "1.0.0"}, rel{version: "1.1.0"})
		label := s.adoptUnreleased()
		s.f.behave(registry+"php:1.1.0-php8.1", behavior{unhealthy: true})
		err := s.upgrade(s.runner(quick))
		if !errors.Is(err, ErrRolledBack) || !strings.Contains(err.Error(), "; "+label+" is back and healthy") {
			t.Fatalf("err = %v", err)
		}
		if got := s.rep.first(KindStepStart, StepRollbck); got != "back to "+label {
			t.Errorf("rollback step: %q", got)
		}
		if !s.rep.said(" files of " + label + " are back") {
			t.Errorf("the log does not name the files laid back: %q", s.rep.logs())
		}
		if state := s.state(); state.Current != instance.Unreleased {
			t.Errorf("the state records %s", state.Current)
		}
	})
	t.Run("older target", func(t *testing.T) {
		s := newStack(t, "", rel{version: "1.0.0"}, rel{version: "1.1.0"})
		label := s.adoptUnreleased()
		if err := s.upgrade(s.runner(func(o *Options) { o.Version = "1.1.0" })); err != nil {
			t.Fatalf("upgrade: %v", err)
		}
		_, plan := s.plan(s.runner(func(o *Options) { o.Version = "1.0.0" }))
		if want := "1.0.0 is older than the installed 1.1.0: use 'kvsctl rollback' (previous is " + label + ")"; !plan.Downgrade || plan.DowngradeMessage() != want {
			t.Errorf("downgrade %v: %q\nwant %q", plan.Downgrade, plan.DowngradeMessage(), want)
		}
	})
	t.Run("rollback cut short", func(t *testing.T) {
		s := newStack(t, "", rel{version: "1.0.0"}, rel{version: "1.1.0"})
		label := s.adoptUnreleased()
		if err := s.upgrade(s.runner()); err != nil {
			t.Fatalf("upgrade: %v", err)
		}
		s.fresh()
		r := s.runner()
		state, err := r.Inst.LoadState()
		if err != nil {
			t.Fatal(err)
		}
		s.rep.cut = isStep(KindStepDone, StepVerify)
		cutRun(t, s.rep, func() { _ = r.Rollback(context.Background(), state) })
		if j := s.journal(); j == nil || j.Action != instance.ActionRollback || j.To != instance.Unreleased || j.Phase != instance.PhaseRecord {
			t.Fatalf("journal: %+v", j)
		}
		interrupted := "rollback from 1.1.0 to " + label + " was interrupted during record"

		s.fresh()
		if err := s.rollback(s.runner()); err == nil || !strings.Contains(err.Error(), "a "+interrupted) {
			t.Fatalf("a rollback over the journal: %v", err)
		}
		s.fresh()
		if err := s.recover(s.runner(func(o *Options) { o.Yes = false })); err != nil {
			t.Fatalf("recover: %v", err)
		}
		if got := s.rep.first(KindStepStart, StepConfirm); !strings.HasPrefix(got, "A "+interrupted+" on ") {
			t.Errorf("recover confirm step: %q", got)
		}
		if q := s.rep.questions; len(q) != 1 || q[0] != "Record the rollback to "+label+", which passed its verification before kvsctl stopped?" {
			t.Errorf("recover question: %q", q)
		}
		if got := s.rep.first(KindStepStart, StepRecord); got != label+" passed its verification" {
			t.Errorf("record step: %q", got)
		}
		if got := s.rep.first(KindStepDone, StepRecord); got != label+" recorded" {
			t.Errorf("record step done: %q", got)
		}
		if state := s.state(); state.Current != instance.Unreleased || state.Previous != "1.1.0" {
			t.Errorf("after recover the state records %s, previous %s", state.Current, state.Previous)
		}
	})
	t.Run("rollback not recorded", func(t *testing.T) {
		s := newStack(t, "", rel{version: "1.0.0"}, rel{version: "1.1.0"})
		label := s.adoptUnreleased()
		if err := s.upgrade(s.runner()); err != nil {
			t.Fatalf("upgrade: %v", err)
		}
		statePath := filepath.Join(s.root, "kvsctl", "state.json")
		s.fresh()
		s.rep.on = func(e Event) {
			if isStep(KindStepDone, StepVerify)(e) {
				// A directory where the state goes: the atomic rename fails.
				_ = os.Remove(statePath)
				_ = os.MkdirAll(filepath.Join(statePath, "in-the-way"), 0o755)
			}
		}
		err := s.rollback(s.runner())
		if !errors.Is(err, ErrNotRecorded) || !strings.HasPrefix(err.Error(), label+" is back and the site is healthy, but its record in ") {
			t.Fatalf("err = %v", err)
		}
	})
}

// MariaDB alone has 30 minutes to be ready when its series changes, which
// upgrades its system tables, and 10 minutes otherwise; --db-timeout, when
// given, is the budget either way.
func TestDBBudget(t *testing.T) {
	r := &Runner{}
	if got := r.dbBudget(true); got != 30*time.Minute {
		t.Errorf("series change: %s, want 30m", got)
	}
	if got := r.dbBudget(false); got != 10*time.Minute {
		t.Errorf("same series: %s, want 10m", got)
	}
	r.Opts.DBTimeout = 45 * time.Second
	for _, change := range []bool{true, false} {
		if got := r.dbBudget(change); got != 45*time.Second {
			t.Errorf("--db-timeout 45s, series change %v: %s", change, got)
		}
	}
}

// A run records the checksums of the release files it lays: the plan that
// follows it, after an upgrade as after a manual rollback, finds no local
// change, and the next upgrade is not blocked by the files kvsctl laid.
func TestPlanAfterARunSeesNoLocalChange(t *testing.T) {
	s := newStack(t, "", rel{version: "1.0.0"}, rel{version: "1.1.0"}, rel{version: "1.2.0"})
	clean := func(after string) {
		t.Helper()
		_, plan := s.plan(s.runner())
		if len(plan.LocalChanges) != 0 || len(plan.Blockers) != 0 || plan.Target == nil || plan.Target.Version != "1.2.0" {
			t.Errorf("plan after %s: local changes %v, blockers %q", after, plan.LocalChanges, plan.Blockers)
		}
	}
	if err := s.upgrade(s.runner(func(o *Options) { o.Version = "1.1.0" })); err != nil {
		t.Fatalf("upgrade: %v", err)
	}
	clean("the upgrade to 1.1.0")
	s.fresh()
	if err := s.rollback(s.runner()); err != nil {
		t.Fatalf("rollback: %v", err)
	}
	s.back("1.0.0")
	clean("the manual rollback to 1.0.0")
}

// An upgrade prunes the older backups, but never the archive a manual
// rollback of the installed version replays: an upgrade that fails leaves
// that version in place, and its rollback still needs that archive.
func TestUpgradeKeepsTheArchiveARollbackReplays(t *testing.T) {
	s := newStack(t, "", rel{version: "1.0.0"}, rel{version: "1.1.0", database: migrates}, rel{version: "1.2.0"})
	if err := s.upgrade(s.runner(func(o *Options) { o.Version = "1.1.0" })); err != nil {
		t.Fatalf("upgrade to 1.1.0: %v", err)
	}
	archive := s.state().UpgradeBackup
	s.backupNow("1.1.0")
	s.f.behave(registry+"php:1.2.0-php8.1", behavior{unhealthy: true})
	s.fresh()
	if err := s.upgrade(s.runner(quick, func(o *Options) { o.KeepBackups = 1 })); !errors.Is(err, ErrRolledBack) {
		t.Fatalf("upgrade to 1.2.0: %v", err)
	}
	if _, err := os.Stat(archive); err != nil {
		t.Fatalf("the archive a rollback of 1.1.0 replays was pruned: %v", err)
	}
	s.writeData("data-2")
	s.fresh()
	if err := s.rollback(s.runner()); err != nil {
		t.Fatalf("rollback to 1.0.0: %v", err)
	}
	s.back("1.0.0")
	if db, _, _, _ := s.world(); db != "data-1" {
		t.Errorf("the database holds %q after the rollback, want the archive of the upgrade to 1.1.0", db)
	}
}
