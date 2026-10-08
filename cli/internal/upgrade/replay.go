package upgrade

import (
	"context"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"slices"
	"strings"
	"time"

	"github.com/MaximeMichaud/KVS-install/cli/internal/backup"
	"github.com/MaximeMichaud/KVS-install/cli/internal/dockerx"
	"github.com/MaximeMichaud/KVS-install/cli/internal/dotenv"
	"github.com/MaximeMichaud/KVS-install/cli/internal/instance"
)

// manticoreService is the compose service of the search engine, whose
// indexes are built from the database.
const manticoreService = "manticore"

// manticoreRebuild is the file of the Manticore data volume that has its
// entrypoint rebuild every index before searchd answers, the request
// manticore_request_rebuild of docker/lib/manticore.sh writes.
const manticoreRebuild = "/var/lib/manticore/kvs-rebuild-before-start"

// cacheServices are the compose services KVS keeps its object cache in:
// memcached or Dragonfly, whichever COMPOSE_PROFILES turns on.
var cacheServices = []string{"memcached", "dragonfly"}

// stopWriters stops every service of the stack that runs, MariaDB aside, so
// that no request and no cron job writes to the database while a backup of
// it is taken or a dump is replayed: the site is down until they start
// again. The journal names them before they stop, so a run cut short
// starts them again.
func (r *Runner) stopWriters(ctx context.Context, j *instance.Journal) error {
	services, err := dockerx.ActiveServices(ctx, r.Inst.DockerDir)
	if err != nil {
		return fmt.Errorf("the services of the stack could not be listed, none was stopped: %w", err)
	}
	states, err := r.Docker.Containers(ctx, r.Inst.ProjectName())
	if err != nil {
		return fmt.Errorf("the containers of the stack could not be read, none was stopped: %w", err)
	}
	running := map[string]bool{}
	for _, s := range states {
		if !s.OneShot && (s.State == "running" || s.State == "restarting") {
			running[s.Service] = true
		}
	}
	var stop []string
	for _, s := range services {
		if s != mariadbService && running[s] {
			stop = append(stop, s)
		}
	}
	if len(stop) == 0 {
		return nil
	}
	j.Stopped = union(j.Stopped, stop)
	if err := r.Inst.SaveJournal(j); err != nil {
		return fmt.Errorf("the journal could not be updated, no service was stopped: %w", err)
	}
	r.log("stopping " + strings.Join(stop, ", ") + ": the site is down until they start again, once the database is replayed")
	return dockerx.Compose(ctx, r.Inst.DockerDir, r.log, append([]string{"stop"}, stop...)...)
}

// startWriters starts the services stopWriters stopped, in the containers
// they had: nothing is recreated.
func (r *Runner) startWriters(ctx context.Context, services []string) error {
	if len(services) == 0 {
		return nil
	}
	r.log("starting " + strings.Join(services, ", ") + " again")
	return dockerx.Compose(ctx, r.Inst.DockerDir, r.log, append([]string{"start"}, services...)...)
}

// emptyCache creates the containers of the cache services again, with new
// anonymous volumes, before the services that read the cache start: what
// KVS cached from the database a replay replaced must not outlive it, and
// a cache started again in the container it had may keep what it held.
// services are the active services of the stack.
func (r *Runner) emptyCache(ctx context.Context, services []string) error {
	var caches []string
	for _, s := range cacheServices {
		if slices.Contains(services, s) {
			caches = append(caches, s)
		}
	}
	if len(caches) == 0 {
		return nil
	}
	r.log("emptying the cache: " + strings.Join(caches, ", ") + " is created again, so nothing read from the replaced database is served")
	if err := dockerx.Compose(ctx, r.Inst.DockerDir, r.log, append([]string{"rm", "--stop", "--force", "-v"}, caches...)...); err != nil {
		return fmt.Errorf("the cache could not be emptied, it still holds what was read from the database before the replay: %w", err)
	}
	if err := dockerx.Compose(ctx, r.Inst.DockerDir, r.log, append([]string{"up", "-d", "--no-deps"}, caches...)...); err != nil {
		return fmt.Errorf("the cache was emptied but could not be started again: %w", err)
	}
	return nil
}

// rebuildSearch has Manticore rebuild every index before it answers again,
// as manticore_request_rebuild of docker/lib/manticore.sh asks for it, when
// search is among the active services: the indexes it keeps were built
// from the database a replay replaced, and a build that began before the
// replay ended read half of it. The request is a file of its data volume
// that its entrypoint reads at start, so the container is created again,
// after the replay and the start of the stack. Every step can run again.
// slow names the services the verification that follows gives the database
// budget: Manticore builds every index before it answers.
func (r *Runner) rebuildSearch(ctx context.Context, services []string) (slow []string, err error) {
	if !slices.Contains(services, manticoreService) {
		return nil, nil
	}
	steps := [][]string{
		{"run", "--rm", "--no-deps", "-T", "--entrypoint", "touch", manticoreService, manticoreRebuild},
		{"rm", "--stop", "--force", manticoreService},
		{"up", "-d", manticoreService},
	}
	r.log("Manticore rebuilds its indexes from the replayed database: search answers once they are built")
	for _, args := range steps {
		if err := dockerx.Compose(ctx, r.Inst.DockerDir, r.log, args...); err != nil {
			var by []string
			for _, step := range steps {
				by = append(by, "docker compose "+strings.Join(step, " "))
			}
			return nil, fmt.Errorf("Manticore was not asked to rebuild its indexes (%w): run in %s: %s", err, r.Inst.DockerDir, strings.Join(by, "; "))
		}
	}
	return []string{manticoreService}, nil
}

// Restore replays archive over the database of the stack. The services
// that write are stopped first, so the backup of the live database taken
// next holds every write the site acknowledged and nothing writes while the
// dump goes in: the site is down until the replay is over. A journal
// follows each step, and a restore cut short is finished by recover, which
// replays the archive again from the start when the replay had begun.
// withEnv puts back the .env the archive carries, with the live values of
// the settings kvsctl manages and of the ones that name the site. protect
// is called right before the replay begins: from there on the restore runs
// to its end, which is the verification of the stack it started again.
func (r *Runner) Restore(ctx context.Context, state *instance.State, archive string, withEnv bool, protect func()) error {
	if err := r.noJournal(state); err != nil {
		return err
	}
	if err := r.mariadbUsable(ctx, state); err != nil {
		return err
	}
	failing, err := r.failingBefore(ctx)
	if err != nil {
		return err
	}
	version := "unknown"
	if state != nil && state.Current != "" {
		version = state.Current
	}
	j := &instance.Journal{
		Action:  instance.ActionRestore,
		From:    version,
		To:      version,
		Phase:   instance.PhaseBackup,
		Log:     r.Opts.LogPath,
		Replay:  archive,
		Env:     withEnv,
		Ignored: failing,
	}
	if err := r.Inst.SaveJournal(j); err != nil {
		return fmt.Errorf("the journal could not be written: %w; nothing was changed", err)
	}
	if err := r.stopWriters(ctx, j); err != nil {
		interrupted := r.interrupted(ctx, err)
		r.giveUp(ctx, j)
		if interrupted {
			return errors.New("restore interrupted while it stopped the services that write, nothing was changed")
		}
		return fmt.Errorf("%w; nothing was changed", err)
	}
	if r.Opts.NoBackup {
		r.start(StepBackup, "No backup of the current database first (--no-backup)")
		r.done(StepBackup, "skipped")
	} else {
		r.start(StepBackup, "Backing up the current database first")
		result, err := backup.Create(ctx, r.Inst.BackupDir(), version, r.mariadbContainer(), r.Inst.EnvPath, r.statePath(), r.log, backup.WithKVSVersion(r.Inst.KVSVersion()))
		if err != nil {
			r.failStep(StepBackup, err)
			r.giveUp(ctx, j)
			if ctx.Err() != nil {
				return errors.New("restore interrupted during the backup before it, nothing was changed")
			}
			return fmt.Errorf("backup before the restore: %w; nothing was changed", err)
		}
		r.done(StepBackup, fmt.Sprintf("%s (%s, %s)", result.Path, humanBytes(result.Size), result.Duration.Round(time.Second)))
		j.Backup = result.Path
	}
	if ctx.Err() != nil {
		r.giveUp(ctx, j)
		return errors.New("restore interrupted before the replay, the database was not touched")
	}
	// From here on an interrupt would leave a database half replayed: the
	// replay runs to its end, bounded by its own stall detection.
	protect()
	ctx = context.WithoutCancel(ctx)
	j.Phase = instance.PhaseReplay
	if err := r.Inst.SaveJournal(j); err != nil {
		r.giveUp(ctx, j)
		return fmt.Errorf("the journal could not be updated: %w; the replay did not begin, nothing was changed", err)
	}
	r.start(StepRestore, "Restoring the database from "+filepath.Base(archive))
	if err := r.replay(ctx, archive, r.dbBudget(false)); err != nil {
		r.fail(StepRestore, errLine(err))
		r.noteFailure(j, err)
		return &failure{msg: replayStopped(j, err) + r.logNote(), cause: err, kind: ErrRollbackFailed}
	}
	j.Phase = instance.PhaseRestart
	if err := r.Inst.SaveJournal(j); err != nil {
		r.log("the journal could not be updated, the restore goes on: " + err.Error())
	}
	services, slow, err := r.finishRestore(ctx, j)
	if err != nil {
		r.fail(StepRestore, errLine(err))
		r.noteFailure(j, err)
		return &failure{msg: r.finishStopped(j, err) + r.logNote(), cause: err, kind: ErrRollbackFailed}
	}
	r.done(StepRestore, "the database holds "+filepath.Base(archive))
	r.dropJournal()
	return r.verifyRestore(ctx, services, j.Ignored, slow, "Checking the containers, the site and the admin", "the database holds "+filepath.Base(archive))
}

// failingBefore names the services that are unhealthy, restarting or
// stopped before a restore changes anything. The verification it ends with
// leaves them out, as a restore does not repair them, and the log names
// them; a MariaDB in that state refuses the restore before.
func (r *Runner) failingBefore(ctx context.Context) ([]string, error) {
	services, err := dockerx.ActiveServices(ctx, r.Inst.DockerDir)
	if err != nil {
		return nil, fmt.Errorf("the services of the stack could not be listed (%w): nothing was changed", err)
	}
	problems, failing, err := r.unhealthy(ctx, services)
	if err != nil {
		return nil, fmt.Errorf("the containers of the stack could not be read (%w): nothing was changed", err)
	}
	if len(failing) > 0 {
		r.log("not healthy before the restore, so left out of its verification: " + strings.Join(problems, "; "))
	}
	return failing, nil
}

// verifyRestore waits for the stack a restore started again to be healthy
// and for the site to answer, the verification an upgrade and a rollback
// end with: the services that failed before the restore are left out, and
// Manticore, which rebuilds its indexes from the replayed database, gets
// the time the database gets. The restore is over by then and its journal
// is gone, so a stack that does not come up is an error that says what is
// wrong and leaves nothing for recover to do. services are the ones the
// containers run for, nil to list them; label begins the step on the
// screen of the caller; done says where the database stands, which the
// error repeats.
func (r *Runner) verifyRestore(ctx context.Context, services, ignored, slow []string, label, done string) error {
	r.start(StepVerify, label)
	if err := r.verifyServices(ctx, services, ignored, r.dbBudget(false), slow...); err != nil {
		r.fail(StepVerify, errLine(err))
		return fmt.Errorf("%s, but the stack is not healthy: %s; the restore is over and kvsctl recover has nothing to do: repair what is named, 'docker compose ps' in %s shows the services%s", done, errLine(err), r.Inst.DockerDir, r.logNote())
	}
	r.done(StepVerify, "healthy")
	return nil
}

// replayStopped is the error of a restore whose replay stopped: the
// database may hold part of the archive, so the services stay stopped and
// the way out is said in full.
func replayStopped(j *instance.Journal, err error) string {
	msg := fmt.Sprintf("the replay of %s stopped: %v; the database may be partly replayed, so the services stopped for it stay stopped: once the cause is fixed, 'kvsctl recover' replays %s again, from the start, and starts them", filepath.Base(j.Replay), errLine(err), filepath.Base(j.Replay))
	if j.Backup != "" {
		msg += fmt.Sprintf("; the database as it was before the restore is in %s", j.Backup)
	}
	return msg
}

// finishStopped is the error of a restore whose replay is over and that
// could not finish: what is left is said, with recover to do it, and for a
// .env that could not be written, the way to do it by hand.
func (r *Runner) finishStopped(j *instance.Journal, err error) string {
	msg := fmt.Sprintf("the database is restored from %s, but the restore could not finish: %v; once the cause is fixed, run 'kvsctl recover' to finish it", filepath.Base(j.Replay), errLine(err))
	if kept, ok := envKept(err); ok {
		msg += fmt.Sprintf(", or take the .env of the archive by hand (tar -xOf %s .env)", j.Replay)
		if len(kept) > 0 {
			msg += " with the live values of " + strings.Join(kept, ", ")
		}
		msg += " and remove " + filepath.Join(r.Inst.StateDir(), "journal.json")
	}
	return msg
}

// finishRestore ends a restore whose database is replayed: the cache is
// emptied, the services it stopped start again, Manticore rebuilds its
// indexes, and the .env the archive carries is put back when the restore
// was asked to. Every step can run again, which is how recover finishes a
// restore that stopped part way. It returns the services the containers
// run for, listed before the .env of the archive is put back, and slow,
// the ones the verification that follows gives the database budget.
func (r *Runner) finishRestore(ctx context.Context, j *instance.Journal) (services, slow []string, err error) {
	services, err = dockerx.ActiveServices(ctx, r.Inst.DockerDir)
	if err != nil {
		return nil, nil, fmt.Errorf("the services of the stack could not be listed, none was started again: %w", err)
	}
	if err := r.emptyCache(ctx, services); err != nil {
		return nil, nil, err
	}
	if err := r.startWriters(ctx, j.Stopped); err != nil {
		return nil, nil, fmt.Errorf("the services stopped for the replay could not be started again: %w", err)
	}
	if slow, err = r.rebuildSearch(ctx, services); err != nil {
		return nil, nil, err
	}
	if !j.Env {
		return services, slow, nil
	}
	archived, err := backup.ArchivedEnv(j.Replay)
	if err != nil {
		return nil, nil, fmt.Errorf("the .env of %s cannot be read: %w", filepath.Base(j.Replay), err)
	}
	live, err := os.ReadFile(r.Inst.EnvPath)
	if err != nil {
		return nil, nil, err
	}
	merged, kept, err := MergeArchivedEnv(archived, live)
	if err == nil {
		err = r.Inst.ReplaceEnv(merged)
	}
	if err != nil {
		return nil, nil, &envError{path: r.Inst.EnvPath, kept: kept, err: err}
	}
	if len(kept) > 0 {
		r.notice(fmt.Sprintf("%s comes from the archive; %s kept the live values, since kvsctl manages them or they name the site", r.Inst.EnvPath, strings.Join(kept, ", ")))
	} else {
		r.notice(r.Inst.EnvPath + " comes from the archive")
	}
	r.notice("run 'docker compose up -d' in " + r.Inst.DockerDir + " for the containers to read it")
	return services, slow, nil
}

// envError is a .env a restore could not write once the database was
// replayed, with the settings that keep their live values.
type envError struct {
	path string
	kept []string
	err  error
}

func (e *envError) Error() string { return fmt.Sprintf("%s was not replaced: %v", e.path, e.err) }
func (e *envError) Unwrap() error { return e.err }

// envKept names the settings a .env that a restore could not write keeps
// from the live file, and reports whether err is that error.
func envKept(err error) ([]string, bool) {
	var e *envError
	if errors.As(err, &e) {
		return e.kept, true
	}
	return nil, false
}

// recoverRestore finishes the restore a journal names. One cut before its
// replay began changed nothing but the services it stopped, which start
// again. One cut during the replay replays the archive again, from the
// start: the replay empties the database first. One cut after the replay
// finishes what was left, without touching the database again. Each ends
// with the verification a restore ends with.
func (r *Runner) recoverRestore(ctx context.Context, state *instance.State, j *instance.Journal) error {
	what := j.Describe(state)
	r.log(what)
	if j.Backup != "" {
		r.log("the database as it was before the restore is in " + j.Backup)
	}
	if !r.Opts.Yes {
		r.start(StepConfirm, capitalize(what))
		if !r.Reporter.Confirm(ctx, restoreQuestion(j)) {
			r.fail(StepConfirm, "cancelled")
			return errors.New("recover cancelled, nothing was changed")
		}
		r.done(StepConfirm, "yes")
	}
	ctx = context.WithoutCancel(ctx)
	archive := filepath.Base(j.Replay)
	r.start(StepRestore, "the restore of "+archive)
	var services, slow []string
	err := func() error {
		switch j.Phase {
		case instance.PhaseBackup:
			r.log("the restore stopped before its replay began: the database was not touched")
			return r.startWriters(ctx, j.Stopped)
		case instance.PhaseReplay:
			// Nothing may write while the archive is replayed again, the
			// services someone started since included.
			if err := r.stopWriters(ctx, j); err != nil {
				return err
			}
			if err := r.replay(ctx, j.Replay, r.dbBudget(false)); err != nil {
				return err
			}
			j.Phase = instance.PhaseRestart
			if err := r.Inst.SaveJournal(j); err != nil {
				r.log("the journal could not be updated, the restore goes on: " + err.Error())
			}
		}
		var err error
		services, slow, err = r.finishRestore(ctx, j)
		return err
	}()
	if err != nil {
		r.fail(StepRestore, errLine(err))
		r.noteFailure(j, err)
		return &failure{
			msg:   fmt.Sprintf("%s, and recover could not finish it: %s; once the cause is fixed, run 'kvsctl recover' again%s", what, errLine(err), r.logNote()),
			cause: err,
			kind:  ErrRollbackFailed,
		}
	}
	r.dropJournal()
	if j.Phase == instance.PhaseBackup {
		r.done(StepRestore, "the services start again, the database is as it was")
		return r.verifyRestore(ctx, nil, j.Ignored, nil, "containers, site, admin", "the database is as it was before the restore")
	}
	r.done(StepRestore, "the database holds "+archive+" and the services start again")
	return r.verifyRestore(ctx, services, j.Ignored, slow, "containers, site, admin", "the database holds "+archive)
}

// restoreQuestion is what recover asks before it finishes a restore.
func restoreQuestion(j *instance.Journal) string {
	archive := filepath.Base(j.Replay)
	switch j.Phase {
	case instance.PhaseBackup:
		return fmt.Sprintf("Start again the services the restore of %s stopped? Its replay never began, the database was not touched.", archive)
	case instance.PhaseReplay:
		return fmt.Sprintf("Replay %s again, from the start, and finish the restore? The site is down until the replay is over.", archive)
	}
	return fmt.Sprintf("Finish the restore of %s, whose database is replayed?", archive)
}

// ArchiveKVSVersion is the KVS version the backup.json of an archive
// records, "" when it records none (an archive older than that record) or
// cannot be read.
func ArchiveKVSVersion(path string) string {
	meta, _, err := backup.Describe(path)
	if err != nil {
		return ""
	}
	return meta.KVSVersion
}

// KVSNote says which KVS a replay puts back, for the question that asks
// for it: the version backup.json records, and a warning when the site
// runs another one. It is "" when the archive records none.
func KVSNote(archived, running string) string {
	switch {
	case archived == "":
		return ""
	case running == "" || running == archived:
		return "KVS " + archived
	}
	return fmt.Sprintf("KVS %s, and the site runs KVS %s", archived, running)
}

// MergeArchivedEnv is the archived .env with the live settings of the keys
// kvsctl manages and of the ones that name the site: the images it pinned,
// the compose files that load them, the version they belong to, the PHP
// bases, the domain, and the compose project with the prefix of its
// containers. An archive of an older version would otherwise point the
// stack at images the files of the running version were not written for,
// and the archive of another site at its directory and its database. Both
// files are read the way compose reads them (dotenv.Graft), an export line
// included, and one compose cannot read is refused. A managed key the live
// file lacks is left out, since its absence is a setting too (no
// COMPOSE_FILE is compose's default list), and the managed keys only the
// live file has are added at the end. It returns the merged file and the
// managed keys that are in either file, sorted.
func MergeArchivedEnv(archived, live []byte) ([]byte, []string, error) {
	if _, err := dotenv.Scan(archived); err != nil {
		return nil, nil, fmt.Errorf("the archived .env cannot be read: %w", err)
	}
	entries, err := dotenv.Scan(live)
	if err != nil {
		return nil, nil, fmt.Errorf("the live .env cannot be read: %w", err)
	}
	pinsMariaDB := slices.ContainsFunc(entries, func(e dotenv.Entry) bool { return e.Key == ImageEnvKey(mariadbService) })
	managed := func(key string) bool {
		switch key {
		case "COMPOSE_FILE", "KVS_STACK_VERSION", "PHP_FPM_BASE", "PHP_CLI_BASE", "DOMAIN", "COMPOSE_PROJECT_NAME", "SITE_PREFIX":
			return true
		}
		if isImageKey(key) {
			return true
		}
		// The series of the MariaDB data files goes with the image that
		// runs them.
		return key == mariadbVersionKey && pinsMariaDB
	}
	return dotenv.Graft(archived, live, managed)
}
