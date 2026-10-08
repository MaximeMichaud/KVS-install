package upgrade

import (
	"archive/tar"
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"io"
	"net/http"
	"os"
	"path/filepath"
	"slices"
	"strings"
	"testing"
	"time"

	"github.com/MaximeMichaud/KVS-install/cli/internal/backup"
	"github.com/MaximeMichaud/KVS-install/cli/internal/instance"
)

// The archived .env comes back with the live values of what kvsctl
// manages, the images it pinned, the compose files that load them, the
// version, the PHP bases and the MariaDB series once .env pins the MariaDB
// image, and of the settings that name the site: an archive of another
// site never points the stack at its directory, its database or its
// containers.
func TestMergeArchivedEnv(t *testing.T) {
	archived := strings.Join([]string{
		"# Site",
		"DOMAIN=old.example.org",
		"SITE_PREFIX=old",
		"COMPOSE_PROJECT_NAME=old",
		"MARIADB_PASSWORD=archived", // pragma: allowlist secret
		"COMPOSE_FILE=docker-compose.yml",
		"KVS_PHP_FPM_IMAGE=ghcr.io/example/php:26.9.0@sha256:aaaa",
		"MARIADB_VERSION=11.4",
		"PHP_FPM_BASE=php:8.1-fpm",
		"KVS_PHP_FPM_IMAGE=ghcr.io/example/php:26.8.0@sha256:bbbb",
		"",
	}, "\n")
	live := strings.Join([]string{
		"DOMAIN=example.com",
		"SITE_PREFIX=kvs",
		"COMPOSE_FILE=docker-compose.yml:docker-compose.release.yml",
		"KVS_PHP_FPM_IMAGE=ghcr.io/example/php:26.11.0@sha256:cccc",
		"KVS_MARIADB_IMAGE=mariadb:11.8.9@sha256:dddd",
		"MARIADB_VERSION=11.8",
		"KVS_STACK_VERSION=26.11.0",
		"",
	}, "\n")
	merged, kept, err := MergeArchivedEnv([]byte(archived), []byte(live))
	if err != nil {
		t.Fatal(err)
	}
	want := strings.Join([]string{
		"# Site",
		"DOMAIN=example.com",
		"SITE_PREFIX=kvs",
		"MARIADB_PASSWORD=archived", // pragma: allowlist secret
		"COMPOSE_FILE=docker-compose.yml:docker-compose.release.yml",
		"KVS_PHP_FPM_IMAGE=ghcr.io/example/php:26.11.0@sha256:cccc",
		"MARIADB_VERSION=11.8",
		"KVS_MARIADB_IMAGE=mariadb:11.8.9@sha256:dddd",
		"KVS_STACK_VERSION=26.11.0",
		"",
	}, "\n")
	if string(merged) != want {
		t.Fatalf("merged .env:\n%s\nwanted:\n%s", merged, want)
	}
	if got := strings.Join(kept, ","); got != "COMPOSE_FILE,COMPOSE_PROJECT_NAME,DOMAIN,KVS_MARIADB_IMAGE,KVS_PHP_FPM_IMAGE,KVS_STACK_VERSION,MARIADB_VERSION,PHP_FPM_BASE,SITE_PREFIX" {
		t.Fatalf("kept %s", got)
	}
	// Without a pinned MariaDB image the series is the operator's, and
	// the archive's value comes back.
	merged, _, err = MergeArchivedEnv([]byte("MARIADB_VERSION=11.4\n"), []byte("MARIADB_VERSION=11.8\n"))
	if err != nil || string(merged) != "MARIADB_VERSION=11.4\n" {
		t.Fatalf("an unpinned series was kept from the live file: %q, %v", merged, err)
	}
}

// Both files are read the way compose reads them: a key set on an export
// line is the key, so the live values of what kvsctl manages win there
// too, and a file compose cannot read is refused rather than merged line
// by line into one it reads otherwise.
func TestMergeArchivedEnvReadsTheFilesAsComposeDoes(t *testing.T) {
	archived := "DOMAIN=example.com\nexport KVS_PHP_FPM_IMAGE=registry.example.com/php:1.0.0@sha256:aaaa\nexport KVS_STACK_VERSION=1.0.0\nSETTING=archived\n"
	live := "DOMAIN=example.com\nexport KVS_PHP_FPM_IMAGE=registry.example.com/php:1.1.0@sha256:bbbb\nKVS_STACK_VERSION=1.1.0\nSETTING=live\n"
	merged, kept, err := MergeArchivedEnv([]byte(archived), []byte(live))
	if err != nil {
		t.Fatal(err)
	}
	want := "DOMAIN=example.com\nexport KVS_PHP_FPM_IMAGE=registry.example.com/php:1.1.0@sha256:bbbb\nKVS_STACK_VERSION=1.1.0\nSETTING=archived\n"
	if string(merged) != want || strings.Join(kept, ",") != "DOMAIN,KVS_PHP_FPM_IMAGE,KVS_STACK_VERSION" {
		t.Errorf("merged:\n%s\nkept %v, want:\n%s", merged, kept, want)
	}
	for _, c := range []struct{ name, archived, live string }{
		{"an archived .env compose cannot read", "DOMAIN=example.com\nSETTING=\"never closed\n", live},
		{"a live .env compose cannot read", archived, "DOMAIN=example.com\nSETTING='never closed\n"},
	} {
		if merged, _, err := MergeArchivedEnv([]byte(c.archived), []byte(c.live)); err == nil {
			t.Errorf("%s was merged:\n%s", c.name, merged)
		}
	}
}

func TestReplayLine(t *testing.T) {
	if got := replayLine(250<<20, 1000<<20, 95*time.Second); got != "replayed 262 MB of 1.05 GB (25%), 1m35s" {
		t.Fatalf("with a size: %q", got)
	}
	if got := replayLine(250<<20, 0, time.Second); got != "replayed 262 MB, 1s" {
		t.Fatalf("without one: %q", got)
	}
}

// A replay that stopped says that recover replays the archive again and
// starts the services, and where the database as it was before is.
func TestReplayStopped(t *testing.T) {
	j := &instance.Journal{Action: instance.ActionRestore, Replay: "/opt/kvs/backups/a.tar", Backup: "/opt/kvs/backups/b.tar"}
	msg := replayStopped(j, errors.New("the database took nothing"))
	for _, want := range []string{"the replay of a.tar stopped: the database took nothing", "partly replayed", "'kvsctl recover' replays a.tar again, from the start, and starts them", "the database as it was before the restore is in /opt/kvs/backups/b.tar"} {
		if !strings.Contains(msg, want) {
			t.Fatalf("%q lacks %q", msg, want)
		}
	}
	j.Backup = ""
	if msg := replayStopped(j, errors.New("x")); strings.Contains(msg, "as it was before") {
		t.Fatalf("without a backup first: %q", msg)
	}
}

// A .env that could not be written once the database was replayed is a
// restore stopped part way: the message says how to finish it with
// recover or by hand, with the settings to keep.
func TestFinishStopped(t *testing.T) {
	s := newStack(t, "", rel{version: "1.0.0"})
	r := s.runner()
	j := &instance.Journal{Action: instance.ActionRestore, Replay: "/opt/kvs/backups/a.tar"}
	cause := &envError{path: r.Inst.EnvPath, kept: []string{"COMPOSE_FILE", "DOMAIN"}, err: errors.New("read-only file system")}
	msg := r.finishStopped(j, cause)
	for _, want := range []string{
		"the database is restored from a.tar, but the restore could not finish: " + r.Inst.EnvPath + " was not replaced: read-only file system",
		"run 'kvsctl recover' to finish it",
		"(tar -xOf /opt/kvs/backups/a.tar .env) with the live values of COMPOSE_FILE, DOMAIN and remove " + filepath.Join(r.Inst.StateDir(), "journal.json"),
	} {
		if !strings.Contains(msg, want) {
			t.Fatalf("%q lacks %q", msg, want)
		}
	}
	if msg := r.finishStopped(j, errors.New("compose start failed")); strings.Contains(msg, "tar -xOf") {
		t.Fatalf("a failure that is not the .env: %q", msg)
	}
}

// withSearch turns on the profiles of the search engine and of the cache
// KVS reads, with their images on the engine, and starts them.
func (s *stack) withSearch() {
	s.t.Helper()
	s.f.hold(s.images[s.state().Current]["manticore"])
	s.f.with(func(f *fakeDocker) {
		f.held = append(f.held, &fakeImage{id: digestOf("id memcached:1.6"), repo: "memcached", digest: digestOf("memcached:1.6"), tags: []string{"1.6"}})
	})
	s.setEnv("COMPOSE_PROFILES", "manticore,memcached")
	s.f.with(func(f *fakeDocker) {
		if resp := f.up(filepath.Join(s.root, "docker"), nil); resp.Code != 0 {
			s.t.Fatalf("compose up: %s", resp.Stderr)
		}
	})
}

// during reads which services ran while each dump was taken and each
// replay went in.
func (s *stack) during() (dumps, replays [][]string) {
	s.f.with(func(f *fakeDocker) {
		dumps, replays = slices.Clone(f.dumpedWith), slices.Clone(f.replayedWith)
	})
	return dumps, replays
}

// onlyMariaDB fails the test unless MariaDB ran alone during each of runs,
// the services that ran during dumps or replays.
func onlyMariaDB(t *testing.T, what string, runs [][]string) {
	t.Helper()
	if len(runs) == 0 {
		t.Errorf("no %s ran", what)
	}
	for i, services := range runs {
		if !slices.Equal(services, []string{mariadbService}) {
			t.Errorf("%s %d ran while %v ran", what, i+1, services)
		}
	}
}

// refreshed checks what follows a replay: the cache container was removed
// with its anonymous volumes after the dump went in and before the
// services that read it started again, by start, and Manticore was asked
// to rebuild its indexes once they had, and runs.
func (s *stack) refreshed(cacheBefore string, start func(cmd string) bool) {
	s.t.Helper()
	cmds := s.f.commands()
	replay := slices.IndexFunc(cmds, replaying)
	rm := slices.Index(cmds, "compose rm --stop --force -v memcached")
	started := -1
	for i := max(rm, 0); i < len(cmds); i++ {
		if start(cmds[i]) {
			started = i
			break
		}
	}
	touch := slices.Index(cmds, "compose run --rm --no-deps -T --entrypoint touch manticore "+manticoreRebuild)
	if replay < 0 || rm < replay || started < rm || touch < started {
		s.t.Errorf("after the replay: replay at %d, cache removed at %d, services started at %d, rebuild asked at %d:\n%s", replay, rm, started, touch, strings.Join(cmds, "\n"))
	}
	if id := s.containerID("memcached"); id == "" || id == cacheBefore {
		s.t.Errorf("the cache container is %q, it was %q", id, cacheBefore)
	}
	var rebuilds []string
	s.f.with(func(f *fakeDocker) { rebuilds = slices.Clone(f.rebuilds) })
	if !slices.Equal(rebuilds, []string{manticoreService}) {
		s.t.Errorf("rebuilds asked: %v", rebuilds)
	}
	if stopped := s.stopped(); len(stopped) != 0 {
		s.t.Errorf("still stopped: %v", stopped)
	}
}

// stopped are the services whose containers are there and stopped.
func (s *stack) stopped() []string {
	var out []string
	s.f.with(func(f *fakeDocker) {
		for _, c := range f.sortedContainers() {
			if c.stopped {
				out = append(out, c.service)
			}
		}
	})
	return out
}

func composeUpAll(cmd string) bool { return cmd == "compose up -d" }

// The automatic rollback of a release that changed the database replays
// the backup with MariaDB the only service that runs: no request and no
// cron job writes to the database while the dump goes in. Then the cache
// starts empty, before the services that read it, and Manticore rebuilds
// its indexes from the replayed database.
func TestAutomaticRollbackReplaysWithTheWritersStopped(t *testing.T) {
	s := newStack(t, "", rel{version: "1.0.0"}, rel{version: "1.1.0", database: migrates})
	s.withSearch()
	cache := s.containerID("memcached")
	s.f.behave(registry+"php:1.1.0-php8.1", behavior{unhealthy: true, migrate: "data-1 migrated by 1.1.0"})
	if err := s.upgrade(s.runner(quick)); !errors.Is(err, ErrRolledBack) {
		t.Fatalf("err = %v", err)
	}
	s.back("1.0.0")
	if db, replays, _, _ := s.world(); db != "data-1" || len(replays) != 1 {
		t.Errorf("database %q, replays %v", db, replays)
	}
	_, replays := s.during()
	onlyMariaDB(t, "replay", replays)
	s.refreshed(cache, composeUpAll)
}

// A manual rollback of a release that changed the database stops every
// service but MariaDB before the backup of the live database, so the
// backup holds every write the site acknowledged, and keeps them stopped
// until the archive of the upgrade is replayed; the question says the site
// is down meanwhile.
func TestManualRollbackReplaysWithTheWritersStopped(t *testing.T) {
	s := newStack(t, "", rel{version: "1.0.0"}, rel{version: "1.1.0", database: migrates})
	s.withSearch()
	s.f.behave(registry+"php:1.1.0-php8.1", behavior{migrate: "data-1 migrated by 1.1.0"})
	if err := s.upgrade(s.runner()); err != nil {
		t.Fatalf("upgrade: %v", err)
	}
	dumpsBefore, _ := s.during()
	cache := s.containerID("memcached")
	s.fresh()
	if err := s.rollback(s.runner(func(o *Options) { o.Yes = false })); err != nil {
		t.Fatalf("rollback: %v", err)
	}
	s.back("1.0.0")
	if q := s.rep.questions; len(q) != 1 || !strings.Contains(q[0], "? The site is down until the replay is over.") {
		t.Errorf("question: %q", q)
	}
	dumps, replays := s.during()
	onlyMariaDB(t, "backup of the live database", dumps[len(dumpsBefore):])
	onlyMariaDB(t, "replay", replays)
	s.refreshed(cache, composeUpAll)
	if db, _, _, _ := s.world(); db != "data-1" {
		t.Errorf("database %q", db)
	}
}

// A restore stops the services that write before its backup of the live
// database and keeps them stopped while the archive is replayed; then the
// cache starts empty, the services start again in the containers they had,
// and Manticore rebuilds its indexes.
func TestRestoreReplaysWithTheWritersStopped(t *testing.T) {
	s := newStack(t, "", rel{version: "1.0.0"})
	s.withSearch()
	archive := s.backupNow("1.0.0")
	s.writeData("data-2")
	cache, php := s.containerID("memcached"), s.containerID("php-fpm")
	if err := s.restore(s.runner(), archive); err != nil {
		t.Fatalf("restore: %v", err)
	}
	if db, _, _, _ := s.world(); db != "data-1" {
		t.Errorf("database %q", db)
	}
	dumps, replays := s.during()
	onlyMariaDB(t, "backup of the live database", dumps[1:])
	onlyMariaDB(t, "replay", replays)
	s.refreshed(cache, func(cmd string) bool { return strings.HasPrefix(cmd, "compose start ") })
	if s.containerID("php-fpm") != php {
		t.Error("php-fpm was not started again in its container")
	}
	if j := s.journal(); j != nil {
		t.Errorf("the journal is still there: %+v", j)
	}
	if archives, _ := filepath.Glob(filepath.Join(s.root, "backups", "backup-*.tar")); len(archives) != 2 {
		t.Errorf("the backups are %v: the live database was not backed up first", archives)
	}
}

// A restore ends with the verification an upgrade ends with: it waits for
// the services it started again to be healthy and for the site to answer.
func TestRestoreWaitsForTheStackItStartedAgain(t *testing.T) {
	s := newStack(t, "", rel{version: "1.0.0"})
	archive := s.backupNow("1.0.0")
	s.f.behave(registry+"php:1.0.0-php8.1", behavior{ready: 300 * time.Millisecond})
	if err := s.restore(s.runner(), archive); err != nil {
		t.Fatalf("restore: %v", err)
	}
	if !s.rep.said("php-fpm is starting") {
		t.Errorf("the restore did not wait for php-fpm: %q", s.rep.logs())
	}
	if got := s.rep.first(KindStepDone, StepVerify); got != "healthy" {
		t.Errorf("the verification ended with %q", got)
	}
	if !s.rep.said("GET / answered 200") || !s.rep.said("GET /admin/ answered 200") {
		t.Errorf("the site was not asked: %q", s.rep.logs())
	}
}

// A stack that does not come up once the database is replayed ends the
// restore with an error that says what is wrong and where the database
// stands, and no more: the restore is over, its journal is gone, and the
// error is no rollback that failed.
func TestRestoreOfAStackThatDoesNotComeUp(t *testing.T) {
	for _, c := range []struct {
		name, want string
		break_     func(s *stack)
	}{
		{"a service", "kvs-php-fpm is unhealthy", func(s *stack) {
			s.f.behave(registry+"php:1.0.0-php8.1", behavior{unhealthy: true})
		}},
		{"the site", "GET / answered 502 Bad Gateway", func(s *stack) {
			s.rep.on = func(e Event) {
				if e.Kind == KindStepStart && e.Step == StepVerify {
					s.site.Store(http.StatusBadGateway)
				}
			}
		}},
	} {
		t.Run(c.name, func(t *testing.T) {
			s := newStack(t, "", rel{version: "1.0.0"})
			archive := s.backupNow("1.0.0")
			s.writeData("data-2")
			c.break_(s)
			err := s.restore(s.runner(func(o *Options) { o.HealthTimeout = 100 * time.Millisecond }), archive)
			if err == nil || errors.Is(err, ErrRollbackFailed) {
				t.Fatalf("err = %v", err)
			}
			for _, want := range []string{"the database holds " + filepath.Base(archive) + ", but the stack is not healthy: ", c.want, "kvsctl recover has nothing to do"} {
				if !strings.Contains(err.Error(), want) {
					t.Errorf("the error lacks %q: %v", want, err)
				}
			}
			if got := s.rep.first(KindStepFail, StepVerify); !strings.Contains(got, c.want) {
				t.Errorf("the verification failed with %q", got)
			}
			if db, _, _, _ := s.world(); db != "data-1" {
				t.Errorf("database %q", db)
			}
			if j := s.journal(); j != nil {
				t.Errorf("the journal is still there: %+v", j)
			}
		})
	}
}

// A service that is not healthy before the restore begins is left out of
// its verification, which the log says: a restore is no repair of it.
func TestRestoreLeavesOutWhatFailedBefore(t *testing.T) {
	s := newStack(t, "", rel{version: "1.0.0"})
	archive := s.backupNow("1.0.0")
	s.f.behave(registry+"nginx:1.0.0", behavior{unhealthy: true})
	s.restartWith("nginx", behavior{unhealthy: true})
	if err := s.restore(s.runner(func(o *Options) { o.HealthTimeout = 100 * time.Millisecond }), archive); err != nil {
		t.Fatalf("restore: %v", err)
	}
	if !s.rep.said("not healthy before the restore, so left out of its verification: kvs-nginx is unhealthy") {
		t.Errorf("the log does not name what was left out: %q", s.rep.logs())
	}
	if got := s.rep.first(KindStepDone, StepVerify); got != "healthy" {
		t.Errorf("the verification ended with %q", got)
	}
}

// A restore that puts back the .env of an archive whose COMPOSE_PROFILES
// turn on a service the stack does not run verifies the services the
// containers run for: the .env of the archive reaches them at the next
// 'docker compose up -d', which the restore names, not before.
func TestRestoreEnvVerifiesTheServicesThatRun(t *testing.T) {
	s := newStack(t, "", rel{version: "1.0.0"})
	archive := s.backupNow("1.0.0")
	rewriteArchive(t, archive, func(name string, body []byte) []byte {
		if name == ".env" {
			return append(body, "COMPOSE_PROFILES=manticore\n"...)
		}
		return body
	})
	r := s.runner(quick)
	state, err := r.Inst.LoadState()
	if err != nil {
		t.Fatal(err)
	}
	if err := r.Restore(context.Background(), state, archive, true, func() {}); err != nil {
		t.Fatalf("restore: %v", err)
	}
	if !strings.Contains(s.file("docker/.env"), "COMPOSE_PROFILES=manticore") {
		t.Errorf("the .env of the archive was not put back:\n%s", s.file("docker/.env"))
	}
	if got := s.rep.first(KindStepDone, StepVerify); got != "healthy" {
		t.Errorf("the verification ended with %q", got)
	}
}

// restore runs a restore of archive with r, as the restore command does.
func (s *stack) restore(r *Runner, archive string) error {
	s.t.Helper()
	state, err := r.Inst.LoadState()
	if err != nil {
		s.t.Fatal(err)
	}
	return r.Restore(context.Background(), state, archive, false, func() {})
}

// A restore cut during its replay leaves its journal, which names it:
// another restore refuses, and recover replays the archive again, from
// the start, names the backup of the live database and starts the services
// the restore stopped.
func TestRestoreCutDuringItsReplayIsFinishedByRecover(t *testing.T) {
	s := newStack(t, "", rel{version: "1.0.0"})
	archive := s.backupNow("1.0.0")
	s.writeData("data-2")
	s.rep.cut = isLog("replaying backups/" + filepath.Base(archive))
	cutRun(t, s.rep, func() { _ = s.restore(s.runner(), archive) })
	j := s.journal()
	if j == nil || j.Action != instance.ActionRestore || j.Phase != instance.PhaseReplay || j.Replay != archive || j.Backup == "" || !slices.Equal(j.Stopped, []string{"nginx", "php-fpm"}) {
		t.Fatalf("journal after the cut: %+v", j)
	}
	if got, want := j.Describe(s.state()), "a restore of "+filepath.Base(archive)+" was interrupted during replay on "+j.Started.UTC().Format("2006-01-02 15:04")+" UTC"; got != want {
		t.Errorf("described as %q, want %q", got, want)
	}
	s.fresh()
	if err := s.restore(s.runner(), archive); err == nil || !strings.Contains(err.Error(), "a restore of "+filepath.Base(archive)+" was interrupted during replay") {
		t.Errorf("a restore while the restore is unfinished: %v", err)
	}
	s.fresh()
	if err := s.recover(s.runner()); err != nil {
		t.Fatalf("recover: %v", err)
	}
	// Recover shows the step it runs, the steps RecoverSteps gave the
	// screen: the restore, which is no rollback.
	if got := s.rep.first(KindStepDone, StepRestore); got != "the database holds "+filepath.Base(archive)+" and the services start again" {
		t.Errorf("the restore step of recover ended with %q", got)
	}
	if got := s.rep.first(KindStepDone, StepVerify); got != "healthy" {
		t.Errorf("the verification of recover ended with %q", got)
	}
	if got := s.rep.first(KindStepStart, StepRollbck); got != "" {
		t.Errorf("recover of a restore shows a rollback step: %q", got)
	}
	if db, replays, _, _ := s.world(); db != "data-1" || len(replays) != 1 {
		t.Errorf("database %q, replays %v", db, replays)
	}
	_, replays := s.during()
	onlyMariaDB(t, "replay", replays)
	if stopped := s.stopped(); len(stopped) != 0 {
		t.Errorf("still stopped after recover: %v", stopped)
	}
	if !s.rep.said("the database as it was before the restore is in " + j.Backup) {
		t.Errorf("recover did not name the backup of the live database: %v", s.rep.logs())
	}
	if j := s.journal(); j != nil {
		t.Errorf("the journal is still there: %+v", j)
	}
}

// A restore cut during its replay, then the site started again by hand:
// recover stops what was started before it replays the archive again, so
// nothing writes while the dump goes in, and starts it once it is in.
func TestRecoverOfARestoreStopsWhatWasStartedSince(t *testing.T) {
	s := newStack(t, "", rel{version: "1.0.0"})
	archive := s.backupNow("1.0.0")
	s.writeData("data-2")
	s.rep.cut = isLog("replaying backups/" + filepath.Base(archive))
	cutRun(t, s.rep, func() { _ = s.restore(s.runner(), archive) })
	s.f.with(func(f *fakeDocker) {
		for _, c := range f.containers {
			if c.stopped {
				f.start(c)
			}
		}
	})
	if stopped := s.stopped(); len(stopped) != 0 {
		t.Fatalf("still stopped after the start by hand: %v", stopped)
	}
	s.fresh()
	if err := s.recover(s.runner()); err != nil {
		t.Fatalf("recover: %v", err)
	}
	if db, replays, _, _ := s.world(); db != "data-1" || len(replays) != 1 {
		t.Errorf("database %q, replays %v", db, replays)
	}
	_, replays := s.during()
	onlyMariaDB(t, "replay", replays)
	if stopped := s.stopped(); len(stopped) != 0 {
		t.Errorf("still stopped after recover: %v", stopped)
	}
	if j := s.journal(); j != nil {
		t.Errorf("the journal is still there: %+v", j)
	}
}

// A restore cut before its replay began changed nothing but the services
// it stopped: recover starts them again and leaves the database alone.
func TestRestoreCutBeforeItsReplayIsUndoneByRecover(t *testing.T) {
	s := newStack(t, "", rel{version: "1.0.0"})
	archive := s.backupNow("1.0.0")
	s.writeData("data-2")
	s.rep.cut = isStep(KindStepStart, StepBackup)
	cutRun(t, s.rep, func() { _ = s.restore(s.runner(), archive) })
	if j := s.journal(); j == nil || j.Phase != instance.PhaseBackup || !slices.Equal(s.stopped(), []string{"nginx", "php-fpm"}) {
		t.Fatalf("after the cut: journal %+v, stopped %v", j, s.stopped())
	}
	s.fresh()
	if err := s.recover(s.runner()); err != nil {
		t.Fatalf("recover: %v", err)
	}
	if db, replays, _, _ := s.world(); db != "data-2" || len(replays) != 0 {
		t.Errorf("database %q, replays %v", db, replays)
	}
	if stopped := s.stopped(); len(stopped) != 0 {
		t.Errorf("still stopped after recover: %v", stopped)
	}
	if j := s.journal(); j != nil {
		t.Errorf("the journal is still there: %+v", j)
	}
}

// A restore interrupted during the backup it takes first changed nothing
// but the services it stopped: they start again, the journal goes, and the
// database is left as it is.
func TestRestoreInterruptedDuringItsBackupChangesNothing(t *testing.T) {
	s := newStack(t, "", rel{version: "1.0.0"})
	archive := s.backupNow("1.0.0")
	s.writeData("data-2")
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	s.rep.on = func(e Event) {
		if e.Kind == KindStepStart && e.Step == StepBackup {
			cancel()
		}
	}
	r := s.runner()
	state, err := r.Inst.LoadState()
	if err != nil {
		t.Fatal(err)
	}
	err = r.Restore(ctx, state, archive, false, func() { t.Error("the restore went past its backup") })
	if err == nil || err.Error() != "restore interrupted during the backup before it, nothing was changed" {
		t.Fatalf("err = %v", err)
	}
	if got := s.rep.first(KindStepFail, StepBackup); got != "cancelled" {
		t.Errorf("the backup step failed with %q", got)
	}
	if db, replays, _, _ := s.world(); db != "data-2" || len(replays) != 0 {
		t.Errorf("database %q, replays %v", db, replays)
	}
	if stopped := s.stopped(); len(stopped) != 0 {
		t.Errorf("still stopped: %v", stopped)
	}
	if j := s.journal(); j != nil {
		t.Errorf("the journal is still there: %+v", j)
	}
}

// A restore whose stop of the services that write is interrupted, before
// its backup, says so in plain words, the error of the docker command the
// interrupt stopped on a line of the run; one whose stop fails says why.
// Either way the services run, the database is as it was, and the journal
// is gone.
func TestRestoreThatCannotStopTheWritersChangesNothing(t *testing.T) {
	for _, interrupt := range []bool{true, false} {
		t.Run(map[bool]string{true: "interrupted", false: "failed"}[interrupt], func(t *testing.T) {
			s := newStack(t, "", rel{version: "1.0.0"})
			archive := s.backupNow("1.0.0")
			s.writeData("data-2")
			ctx, cancel := context.WithCancel(context.Background())
			defer cancel()
			if interrupt {
				s.rep.on = func(e Event) {
					if e.Kind == KindLog && strings.HasPrefix(e.Message, "stopping ") {
						cancel()
					}
				}
			} else {
				s.failOnce("compose stop nginx php-fpm", "Error response from daemon: cannot stop container kvs-nginx")
			}
			r := s.runner()
			state, err := r.Inst.LoadState()
			if err != nil {
				t.Fatal(err)
			}
			err = r.Restore(ctx, state, archive, false, func() { t.Error("the restore went past its backup") })
			switch {
			case err == nil:
				t.Fatal("the restore went on")
			case interrupt && err.Error() != "restore interrupted while it stopped the services that write, nothing was changed":
				t.Fatalf("err = %v", err)
			case !interrupt && (!strings.Contains(err.Error(), "cannot stop container kvs-nginx") || !strings.HasSuffix(err.Error(), "; nothing was changed")):
				t.Fatalf("err = %v", err)
			}
			if got := s.rep.said("cancelled: docker compose stop "); got != interrupt {
				t.Errorf("the run logs the error of a stopped command: %v, want %v: %q", got, interrupt, s.rep.logs())
			}
			if got := s.rep.first(KindStepStart, StepBackup); got != "" {
				t.Errorf("the backup began: %q", got)
			}
			if db, replays, _, _ := s.world(); db != "data-2" || len(replays) != 0 {
				t.Errorf("database %q, replays %v", db, replays)
			}
			if stopped := s.stopped(); len(stopped) != 0 {
				t.Errorf("still stopped: %v", stopped)
			}
			if j := s.journal(); j != nil {
				t.Errorf("the journal is still there: %+v", j)
			}
		})
	}
}

// Services a restore stopped that do not start again leave the site down:
// the line that says what to run is a notice, on one line, which restore
// prints even under --quiet.
func TestRestoreTellsTheServicesThatDidNotStartAgain(t *testing.T) {
	s := newStack(t, "", rel{version: "1.0.0"})
	archive := s.backupNow("1.0.0")
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	s.rep.on = func(e Event) {
		if e.Kind == KindLog && strings.HasPrefix(e.Message, "stopping ") {
			cancel()
		}
	}
	s.failOnce("compose start nginx php-fpm", "Error response from daemon: no space left on device")
	r := s.runner()
	state, err := r.Inst.LoadState()
	if err != nil {
		t.Fatal(err)
	}
	err = r.Restore(ctx, state, archive, false, func() { t.Error("the restore went past its backup") })
	if err == nil || !strings.HasPrefix(err.Error(), "restore interrupted while it stopped the services that write") {
		t.Fatalf("err = %v", err)
	}
	notices := s.rep.notices()
	tail := "; run 'docker compose start nginx php-fpm' in " + r.Inst.DockerDir
	if len(notices) != 1 || !strings.HasPrefix(notices[0], "nginx, php-fpm could not be started again: ") ||
		!strings.Contains(notices[0], "no space left on device") || !strings.HasSuffix(notices[0], tail) || strings.Contains(notices[0], "\n") {
		t.Errorf("the notices of the run: %q", notices)
	}
}

// An archived .env that cannot be read leaves the live one as it is once
// the database is replayed: the restore stops there, as for a .env it
// could not write, and its journal waits for recover. The command reads
// that .env before the replay; recover, which finishes a restore cut
// short, meets it only here.
func TestRestoreKeepsTheLiveEnvWhenTheArchivedOneCannotBeRead(t *testing.T) {
	s := newStack(t, "", rel{version: "1.0.0"})
	archive := s.backupNow("1.0.0")
	rewriteArchive(t, archive, func(name string, body []byte) []byte {
		if name == ".env" {
			return append(body, "SETTING=\"never closed\n"...)
		}
		return body
	})
	before := s.file("docker/.env")
	r := s.runner()
	state, err := r.Inst.LoadState()
	if err != nil {
		t.Fatal(err)
	}
	err = r.Restore(context.Background(), state, archive, true, func() {})
	if _, ok := envKept(err); !ok || !errors.Is(err, ErrRollbackFailed) || !strings.Contains(err.Error(), r.Inst.EnvPath+" was not replaced: the archived .env cannot be read: ") {
		t.Fatalf("err = %v", err)
	}
	if got := s.file("docker/.env"); got != before {
		t.Errorf(".env changed:\n%s", got)
	}
	if db, replays, _, _ := s.world(); db != "data-1" || len(replays) != 1 {
		t.Errorf("database %q, replays %v", db, replays)
	}
	if j := s.journal(); j == nil || j.Failed.IsZero() {
		t.Errorf("the journal of the restore is %+v, want one that recover finishes", j)
	}
}

// A restore refuses a MariaDB that runs and fails its health check before
// it stops anything, as a rollback does: the services it starts again once
// the dump is in wait for MariaDB to be healthy. A stack kvsctl recorded no
// state for is refused the same way.
func TestRestoreRefusesAnUnhealthyMariaDB(t *testing.T) {
	for _, recorded := range []bool{true, false} {
		s := newStack(t, "", rel{version: "1.0.0"})
		archive := s.backupNow("1.0.0")
		s.writeData("data-2")
		s.restartWith("mariadb", behavior{unhealthy: true})
		var state *instance.State
		if recorded {
			state = s.state()
		}
		before := len(s.f.commands())
		err := s.runner().Restore(context.Background(), state, archive, false, func() { t.Error("the restore went past its backup") })
		if err == nil || !strings.HasPrefix(err.Error(), "kvs-mariadb is unhealthy: the services that need MariaDB wait for it to be healthy") || !strings.Contains(err.Error(), "nothing was changed") {
			t.Errorf("with a state %v: %v", recorded, err)
		}
		if db, replays, _, _ := s.world(); db != "data-2" || len(replays) != 0 {
			t.Errorf("with a state %v: database %q, replays %v", recorded, db, replays)
		}
		if cmds := s.f.commands()[before:]; len(cmds) != 0 {
			t.Errorf("with a state %v: the restore ran %v", recorded, cmds)
		}
		if j := s.journal(); j != nil {
			t.Errorf("with a state %v: a journal was left: %+v", recorded, j)
		}
	}
}

// rewriteArchive rewrites the members of an archive with edit, which gets
// the name and the content of each and returns the new content: an archive
// of another site, or of a kvsctl that records the KVS version, made from
// one of this site.
func rewriteArchive(t *testing.T, path string, edit func(name string, body []byte) []byte) {
	t.Helper()
	data, err := os.ReadFile(path)
	if err != nil {
		t.Fatal(err)
	}
	var out bytes.Buffer
	tr, tw := tar.NewReader(bytes.NewReader(data)), tar.NewWriter(&out)
	for {
		hdr, err := tr.Next()
		if errors.Is(err, io.EOF) {
			break
		}
		if err != nil {
			t.Fatal(err)
		}
		body, err := io.ReadAll(tr)
		if err != nil {
			t.Fatal(err)
		}
		body = edit(hdr.Name, body)
		hdr.Size, hdr.Format = int64(len(body)), tar.FormatUnknown
		if err := tw.WriteHeader(hdr); err != nil {
			t.Fatal(err)
		}
		if _, err := tw.Write(body); err != nil {
			t.Fatal(err)
		}
	}
	if err := tw.Close(); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(path, out.Bytes(), 0o600); err != nil {
		t.Fatal(err)
	}
}

// setMeta changes backup.json of an archive with edit.
func setMeta(t *testing.T, path string, edit func(meta map[string]any)) {
	t.Helper()
	rewriteArchive(t, path, func(name string, body []byte) []byte {
		if name != "backup.json" {
			return body
		}
		var meta map[string]any
		if err := json.Unmarshal(body, &meta); err != nil {
			t.Fatal(err)
		}
		edit(meta)
		out, err := json.Marshal(meta)
		if err != nil {
			t.Fatal(err)
		}
		return out
	})
}

// kvsSite gives the runner a site whose files are those of KVS version.
func kvsSite(t *testing.T, r *Runner, version string) {
	t.Helper()
	r.Inst.WebRoot = t.TempDir()
	dir := filepath.Join(r.Inst.WebRoot, "admin", "include")
	if err := os.MkdirAll(dir, 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(dir, "version.php"), []byte("<?php\n$config['project_version']='"+version+"';\n"), 0o644); err != nil {
		t.Fatal(err)
	}
}

// The question of a rollback that replays an archive names the KVS whose
// database the archive holds, and the KVS the site runs when it is
// another one: the replay puts the tables of that KVS under the files of
// this one.
func TestRollbackQuestionNamesTheKVSOfTheArchive(t *testing.T) {
	s := newStack(t, "", rel{version: "1.0.0"}, rel{version: "1.1.0", database: migrates})
	if err := s.upgrade(s.runner()); err != nil {
		t.Fatalf("upgrade: %v", err)
	}
	state := s.state()
	setMeta(t, state.UpgradeBackup, func(meta map[string]any) { meta["kvs_version"] = "6.3.1" })
	if got := ArchiveKVSVersion(state.UpgradeBackup); got != "6.3.1" {
		t.Fatalf("ArchiveKVSVersion = %q", got)
	}
	r := s.runner()
	kvsSite(t, r, "6.4.0")
	replay, taken, err := r.rollbackDump(state)
	if err != nil {
		t.Fatal(err)
	}
	if q := r.rollbackQuestion(state, replay, taken); !strings.Contains(q, ", taken "+taken.UTC().Format("2006-01-02 15:04 UTC")+" with KVS 6.3.1, and the site runs KVS 6.4.0? ") {
		t.Errorf("question: %q", q)
	}
	kvsSite(t, r, "6.3.1")
	if q := r.rollbackQuestion(state, replay, taken); !strings.Contains(q, " with KVS 6.3.1? ") || strings.Contains(q, "the site runs") {
		t.Errorf("the same KVS: %q", q)
	}
	setMeta(t, state.UpgradeBackup, func(meta map[string]any) { delete(meta, "kvs_version") })
	if q := r.rollbackQuestion(state, replay, taken); strings.Contains(q, "KVS") {
		t.Errorf("an archive that records no KVS: %q", q)
	}
	// The rollback replays the rewritten archive all the same.
	if err := s.rollback(s.runner()); err != nil {
		t.Fatalf("rollback: %v", err)
	}
	s.back("1.0.0")
}

// archivedKVS is the KVS version backup.json of an archive records.
func archivedKVS(t *testing.T, path string) string {
	t.Helper()
	meta, _, err := backup.Describe(path)
	if err != nil {
		t.Fatal(err)
	}
	return meta.KVSVersion
}

// newestArchive is the archive of the stack written last.
func (s *stack) newestArchive() string {
	s.t.Helper()
	list, err := backup.List(filepath.Join(s.root, "backups"))
	if err != nil || len(list) == 0 {
		s.t.Fatalf("the backups of the stack: %v, %v", list, err)
	}
	return list[0].Path
}

// Every archive a run takes records the KVS version the site runs: the
// backup of an upgrade, the backup of the live database a manual rollback
// takes before it replays an older one, and the one a restore takes first.
// The question of the rollback then names the KVS of the archive it
// replays, and the site's when it moved on since.
func TestArchivesRecordTheKVSOfTheSite(t *testing.T) {
	s := newStack(t, "", rel{version: "1.0.0"}, rel{version: "1.1.0", database: migrates})
	r := s.runner()
	kvsSite(t, r, "6.3.1")
	if err := s.upgrade(r); err != nil {
		t.Fatalf("upgrade: %v", err)
	}
	upgraded := s.state().UpgradeBackup
	if got := archivedKVS(t, upgraded); got != "6.3.1" {
		t.Errorf("the backup of the upgrade records KVS %q, want 6.3.1", got)
	}

	s.fresh()
	r = s.runner(func(o *Options) { o.Yes = false })
	kvsSite(t, r, "6.4.0")
	if err := s.rollback(r); err != nil {
		t.Fatalf("rollback: %v", err)
	}
	if q := s.rep.questions; len(q) != 1 || !strings.Contains(q[0], " with KVS 6.3.1, and the site runs KVS 6.4.0? ") {
		t.Errorf("the question of the rollback: %q", q)
	}
	if safety := s.newestArchive(); safety == upgraded || archivedKVS(t, safety) != "6.4.0" {
		t.Errorf("the backup of the live database the rollback took, %s, records KVS %q, want 6.4.0", filepath.Base(safety), archivedKVS(t, safety))
	}

	s.fresh()
	r = s.runner()
	kvsSite(t, r, "6.4.0")
	if err := s.restore(r, upgraded); err != nil {
		t.Fatalf("restore: %v", err)
	}
	if safety := s.newestArchive(); safety == upgraded || archivedKVS(t, safety) != "6.4.0" {
		t.Errorf("the backup of the live database the restore took, %s, records KVS %q, want 6.4.0", filepath.Base(safety), archivedKVS(t, safety))
	}
}

func TestKVSNote(t *testing.T) {
	for _, c := range []struct{ archived, running, want string }{
		{"", "6.4.0", ""},
		{"6.3.1", "", "KVS 6.3.1"},
		{"6.3.1", "6.3.1", "KVS 6.3.1"},
		{"6.3.1", "6.4.0", "KVS 6.3.1, and the site runs KVS 6.4.0"},
	} {
		if got := KVSNote(c.archived, c.running); got != c.want {
			t.Errorf("KVSNote(%q, %q) = %q, want %q", c.archived, c.running, got, c.want)
		}
	}
	if got := ArchiveKVSVersion(filepath.Join(t.TempDir(), "missing.tar")); got != "" {
		t.Errorf("a missing archive: %q", got)
	}
}
