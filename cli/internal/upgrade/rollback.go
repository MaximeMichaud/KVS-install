package upgrade

import (
	"context"
	"errors"
	"fmt"
	"maps"
	"os"
	"path/filepath"
	"regexp"
	"slices"
	"strings"
	"time"

	"github.com/MaximeMichaud/KVS-install/cli/internal/backup"
	"github.com/MaximeMichaud/KVS-install/cli/internal/dockerx"
	"github.com/MaximeMichaud/KVS-install/cli/internal/instance"
	"github.com/MaximeMichaud/KVS-install/cli/internal/manifest"
	"github.com/MaximeMichaud/KVS-install/cli/internal/release"
	"github.com/MaximeMichaud/KVS-install/cli/internal/semver"
)

// keptPrefix names the folders of the MariaDB data volume that hold the
// data files a rollback moved aside.
const keptPrefix = ".kvsctl-rollback-"

// backMarker is the file the move of data files back leaves among the fresh
// files it put out of the way: a move cut short and run again then only
// finishes bringing the older files back.
const backMarker = ".kvsctl-back"

// errLine is err on one line, for a message that says what went wrong: its
// first line and, when the error carries the output of a command that
// failed, the last line of it. A compose command ends its error with the
// last lines it printed, and the last one says why it failed, which
// "docker compose up -d: exit status 1" alone does not.
func errLine(err error) string {
	first, rest, multi := strings.Cut(err.Error(), "\n")
	if !multi {
		return first
	}
	lines := strings.Split(rest, "\n")
	for i := len(lines) - 1; i >= 0; i-- {
		last := strings.TrimSpace(lines[i])
		if last == "" {
			continue
		}
		if strings.Contains(first, last) {
			return first
		}
		return first + ": " + last
	}
	return first
}

// noteFailure records in the journal when and why the run, or the attempt
// to undo or finish it, stopped on err: status and every refusal then tell
// a run that failed from one that was cut short.
func (r *Runner) noteFailure(j *instance.Journal, err error) {
	j.Failed, j.Failure = time.Now().UTC(), errLine(err)
	if err := r.Inst.SaveJournal(j); err != nil {
		r.log("the journal could not record the failure: " + err.Error())
	}
}

// failed undoes a run that changed the stack and builds the error it ends
// with: what failed, and where the stack stands now.
func (r *Runner) failed(ctx context.Context, state *instance.State, j *instance.Journal, cause error) error {
	what := "failed: " + errLine(cause)
	j.Cause, j.Outcome = errLine(cause), instance.OutcomeFailed
	if errors.Is(cause, context.Canceled) {
		what = "was cancelled"
		j.Outcome = instance.OutcomeCancelled
	}
	if err := r.undo(ctx, state, j, cause); err != nil {
		return &failure{
			msg:   fmt.Sprintf("upgrade to %s %s; the rollback to %s failed too: %s%s", j.To, what, state.Label(j.From), errLine(err), r.logNote()),
			cause: cause,
			kind:  ErrRollbackFailed,
		}
	}
	back := state.Label(j.From)
	if j.From == j.To {
		back += " with the images it ran before"
	}
	return &failure{
		msg:   fmt.Sprintf("upgrade to %s %s; %s is back and healthy%s", j.To, what, back, r.logNote()),
		cause: cause,
		kind:  ErrRolledBack,
	}
}

// undo returns the stack to j.From after a run that changed it failed or
// was cut short, and undoes what the journal says happened, nothing more:
// the files and the settings come back, compose runs only when it ran,
// and the database is replayed only when the run may have changed it. It
// runs to its end whatever the context of the run says, since the Ctrl-C
// that cancelled the run must not leave the stack half way back; each step
// keeps its own bound, and the replay its stall detection.
//
// Compose counts as started when the journal says so, and also when the
// containers are no longer the ones the run began with: compose run by
// hand or by a script after a cut changed them all the same. A dump is
// replayed with MariaDB the only service that runs, so that nothing writes
// to the database meanwhile: the site is down until the replay is over.
//
// The journal stays, in its rollback phase, until the rollback completed,
// its verification included: a rollback that fails leaves it, with when
// and why it failed, and 'kvsctl recover' runs the rollback again. Every
// step of it can run again: the files and the settings are laid as they
// are kept, compose converges, the data files a rollback moved stay moved,
// and the replay starts over.
func (r *Runner) undo(ctx context.Context, state *instance.State, j *instance.Journal, cause error) error {
	ctx = context.WithoutCancel(ctx)
	r.start(StepRollbck, "back to "+state.Label(j.From))
	// A failure the journal records in its rollback phase is an earlier
	// attempt at this rollback: the history says so once it is over.
	again := j.Failure != "" && j.Phase == instance.PhaseRollback
	j.Phase = instance.PhaseRollback
	if !j.ComposeStarted && r.composeRan(ctx, j) {
		j.ComposeStarted = true
	}
	if err := r.Inst.SaveJournal(j); err != nil {
		r.log("the journal could not be updated, the rollback goes on: " + err.Error())
	}
	stopped := func(err error) {
		r.fail(StepRollbck, errLine(err))
		r.noteFailure(j, err)
	}
	recreated := r.recreated(ctx, j)
	if j.ComposeStarted {
		// The images of the version the stack returns to may be gone from
		// the engine by now: they are pulled before anything moves.
		if err := r.ensureImages(ctx, r.targetImages(ctx, state.ReleaseImages[j.From], j.Pins, j.ImagesBefore, j.Services)); err != nil {
			stopped(err)
			return fmt.Errorf("%w; nothing was rolled back yet: once the images can be pulled, 'kvsctl recover' runs the rollback", err)
		}
	}
	if err := r.putBack(state, j); err != nil {
		stopped(err)
		return fmt.Errorf("%w; once that is fixed, 'kvsctl recover' runs the rollback again", err)
	}
	if err := r.dataBack(ctx, state, j); err != nil {
		stopped(err)
		return err
	}
	restore, moveData, why := restorePlan(state, j, recreated)
	r.log(why)
	budget := r.dbBudget(j.OneWay)
	var slow []string
	err := func() error {
		if !j.ComposeStarted {
			return r.startWriters(ctx, j.Stopped)
		}
		if _, err := r.removeLeftovers(ctx, j, true); err != nil {
			return err
		}
		if j.DataBack {
			// The database is the one the data files put back hold:
			// nothing the stack derived from the database the rollback
			// had replayed may outlive it.
			var err error
			slow, err = r.replayAlone(ctx, "", budget)
			return err
		}
		if !restore {
			_, err := r.composeUp(ctx, mariadbChanges(j.ImagesBefore, j.ImagesAfter), budget)
			return err
		}
		if err := r.stopWriters(ctx, j); err != nil {
			return err
		}
		if moveData {
			if err := r.recreateDatadir(ctx, j); err != nil {
				return err
			}
		}
		var err error
		slow, err = r.replayAlone(ctx, j.Backup, budget)
		return err
	}()
	if err == nil {
		err = r.verify(ctx, j.Ignored, budget, slow...)
	}
	if err != nil {
		stopped(err)
		return r.byHand(err, state, j, restore)
	}
	// The entry keeps how the run ended as a field, which status reads,
	// and says it in its note. A run cut short has "interrupted during
	// <phase>" as its cause, which Recover gives it.
	why, outcome := errLine(cause), runOutcome(j)
	var note string
	switch {
	case j.Action == instance.ActionRollback && outcome == instance.OutcomeInterrupted:
		note = fmt.Sprintf("the rollback to %s did not finish: %s", j.To, why)
	case j.Action == instance.ActionRollback:
		note = fmt.Sprintf("the rollback to %s failed: %s", j.To, why)
	case outcome == instance.OutcomeCancelled:
		note = fmt.Sprintf("%s was cancelled: %s", j.To, why)
	case outcome == instance.OutcomeInterrupted:
		note = fmt.Sprintf("%s was %s", j.To, why)
	default:
		note = fmt.Sprintf("%s failed: %s", j.To, why)
	}
	if again {
		what := "its rollback"
		if j.Action == instance.ActionRollback {
			what = "the return to " + j.From
		}
		note += fmt.Sprintf("; %s failed first (%s), and recover finished it", what, j.Failure)
	}
	state.History = append(state.History, instance.Entry{
		Version: j.From, Action: instance.ActionRollback, Date: j.Started, Note: note,
		Undid: &instance.Undone{Action: j.Action, To: j.To, Outcome: outcome, Cause: why},
	})
	if err := r.Inst.SaveState(state); err != nil {
		r.log("the rollback could not be added to the history: " + err.Error())
	}
	r.dropJournal()
	r.done(StepRollbck, state.Label(j.From)+" is back and healthy")
	return nil
}

// runOutcome is how the run a rollback undoes ended, as its journal
// records it. A journal with no cause names a run cut short; the journal
// of a kvsctl that recorded the cause alone tells a cancelled run by the
// error the cancel ended it on.
func runOutcome(j *instance.Journal) string {
	switch {
	case j.Outcome != "":
		return j.Outcome
	case j.Cause == "":
		return instance.OutcomeInterrupted
	case strings.Contains(j.Cause, context.Canceled.Error()):
		return instance.OutcomeCancelled
	}
	return instance.OutcomeFailed
}

// restorePlan decides what a rollback does with the database. The backup
// is replayed when the run took one and either a one-way run had MariaDB
// recreated, or compose started on a run that changes the database or was
// told to replay it. The data files are moved aside first only in the
// one-way case: a server of the previous series cannot open them. Data
// files a one-way rollback moved aside and recover moved back leave the
// database as it was before that rollback. why is the decision as the log
// tells it, with the versions named by the state; for a run that stopped
// services and never started compose, it says they start again.
func restorePlan(state *instance.State, j *instance.Journal, recreated bool) (restore, moveData bool, why string) {
	// A manual rollback stops the services that write before its backup,
	// so before compose starts: undoing it then starts them again.
	again := ""
	if !j.ComposeStarted && len(j.Stopped) > 0 {
		again = fmt.Sprintf(", and %s, which the rollback stopped, start again", strings.Join(j.Stopped, ", "))
	}
	switch {
	case j.DataBack:
		return false, false, fmt.Sprintf("the data files %s ran with are back in place: the database is left as it is", state.Label(j.From))
	case j.Backup == "":
		return false, false, "no backup was taken, the database is left as it is" + again
	case j.OneWay && recreated:
		return true, true, fmt.Sprintf("MariaDB was recreated by a one-way run: its data files are moved aside and %s is replayed", filepath.Base(j.Backup))
	case !j.ComposeStarted && again != "":
		return false, false, "compose never started: the database was not touched" + again
	case !j.ComposeStarted:
		return false, false, "compose never started: the containers and the database were not touched"
	case j.Action == instance.ActionRollback && j.Database == migrates:
		return true, false, fmt.Sprintf("the rollback replayed an older dump: %s, taken before it, is replayed", filepath.Base(j.Backup))
	case j.Database == migrates:
		return true, false, fmt.Sprintf("%s changes the database: %s is replayed", state.Label(j.To), filepath.Base(j.Backup))
	case j.RestoreDB:
		return true, false, fmt.Sprintf("--restore-db: %s is replayed", filepath.Base(j.Backup))
	default:
		return false, false, fmt.Sprintf("%s does not change the database, it is left as it is", state.Label(j.To))
	}
}

// composeRan reports whether the containers changed since the run the
// journal names began, which a journal that never saw compose start cannot
// say: a compose up run by hand, or by setup.sh, after a cut. A journal
// that recorded no containers, or containers that cannot be read, leave
// the journal to say it.
func (r *Runner) composeRan(ctx context.Context, j *instance.Journal) bool {
	if j.Containers == nil {
		return false
	}
	now, err := r.serviceContainers(ctx)
	if err != nil {
		r.log("the containers of the stack could not be read, the journal says what ran: " + firstLine(err.Error()))
		return false
	}
	var changed []string
	for service, id := range now {
		if j.Containers[service] != id {
			changed = append(changed, service)
		}
	}
	for service := range j.Containers {
		if _, ok := now[service]; !ok {
			changed = append(changed, service)
		}
	}
	if len(changed) == 0 {
		return false
	}
	slices.Sort(changed)
	r.log(fmt.Sprintf("the containers of %s are not the ones the run began with: compose ran since, by hand or from a script, and the run is undone as one whose containers changed", strings.Join(slices.Compact(changed), ", ")))
	return true
}

// mariadbChanges reports whether two sets of variant settings run another
// MariaDB: another pinned image or, for a stack that pins none, another
// series.
func mariadbChanges(a, b map[string]string) bool {
	key := ImageEnvKey(mariadbService)
	return a[key] != b[key] || a[mariadbVersionKey] != b[mariadbVersionKey]
}

// replayAlone replays archive with MariaDB the only service that runs, then
// starts the others: nothing writes to the database while the dump goes
// in, and nothing the stack derived from the database it replaced survives
// it, the cache emptied before the services that read it start and the
// search indexes built again. An empty archive replays nothing: the data
// files a rollback moved aside are back in place, which replaces the
// database all the same. slow names the services the verification that
// follows gives the database budget.
func (r *Runner) replayAlone(ctx context.Context, archive string, budget time.Duration) (slow []string, err error) {
	r.log(fmt.Sprintf("starting MariaDB alone: the other services start once the database is in place; MariaDB has %s to be ready (--db-timeout)", shortDuration(budget)))
	if err := dockerx.Compose(ctx, r.Inst.DockerDir, r.log, "up", "-d", mariadbService); err != nil {
		return nil, err
	}
	if archive == "" {
		err = r.waitDatabase(ctx, budget)
	} else {
		err = r.replay(ctx, archive, budget)
	}
	if err != nil {
		return nil, err
	}
	services, err := dockerx.ActiveServices(ctx, r.Inst.DockerDir)
	if err != nil {
		return nil, fmt.Errorf("the services of the stack could not be listed, none was started again: %w", err)
	}
	if err := r.emptyCache(ctx, services); err != nil {
		return nil, err
	}
	if err := dockerx.Compose(ctx, r.Inst.DockerDir, r.log, "up", "-d"); err != nil {
		return nil, err
	}
	return r.rebuildSearch(ctx, services)
}

// putBack lays the files and the settings of j.From back over the
// installation: the files kept for that version, COMPOSE_FILE as it was,
// and the variant settings as they were.
func (r *Runner) putBack(state *instance.State, j *instance.Journal) error {
	if !j.Applied {
		r.log("no release file was laid, the installation is untouched")
		return nil
	}
	if state == nil || len(state.Files) == 0 {
		return fmt.Errorf("the state lists no release file of %s, so the files kept in %s cannot be laid back", state.Label(j.From), r.releaseDir(j.From))
	}
	prev := r.keptDir(j.From, state.Files)
	if _, err := os.Stat(prev); err != nil {
		return fmt.Errorf("the files of %s are not kept in %s: %w", state.Label(j.From), prev, err)
	}
	laid := j.Files
	if len(laid) == 0 {
		// A journal of a run that laid nothing it could list: what the
		// target ships is what may be on disk.
		laid, _ = listFiles(r.releaseDir(j.To))
	}
	if err := release.Sync(prev, r.Inst.Root, state.Files, laid); err != nil {
		return fmt.Errorf("lay the files of %s back: %w", state.Label(j.From), err)
	}
	if err := r.setComposeFile(j.ComposeFileBefore); err != nil {
		return fmt.Errorf("COMPOSE_FILE: %w", err)
	}
	if err := r.restoreEnv(j.ImagesBefore, j.ImagesAfter); err != nil {
		return fmt.Errorf(".env: %w", err)
	}
	if j.Action == instance.ActionUpgrade && j.From == j.To {
		if err := os.RemoveAll(r.stagingDir(j.To)); err != nil {
			r.log("the staged files of the re-apply could not be removed: " + err.Error())
		}
	}
	r.log(fmt.Sprintf("%d files of %s are back", len(state.Files), state.Label(j.From)))
	return nil
}

// dropJournal removes the journal of a run that is over.
func (r *Runner) dropJournal() {
	if err := r.Inst.RemoveJournal(); err != nil {
		r.log("the journal could not be removed: " + err.Error())
	}
}

// byHand is the error of a rollback that put the files back but not the
// rest: what failed, and how to finish. The journal is still there, so
// recover is the way named first. The way by hand is for a cause kvsctl
// cannot get past: every command but recover refuses while the journal is
// there, so it goes first.
func (r *Runner) byHand(err error, state *instance.State, j *instance.Journal, restore bool) error {
	msg := errLine(err)
	if j.DataMoved && !j.DataBack {
		if j.Action == instance.ActionRollback {
			msg += fmt.Sprintf("; the data files of %s are kept in %s inside the MariaDB data volume", state.Label(j.From), j.DataFolder)
		} else {
			msg += fmt.Sprintf("; the data files the newer server wrote are kept in %s inside the MariaDB data volume", j.DataFolder)
		}
	}
	journal := filepath.Join(r.Inst.StateDir(), "journal.json")
	msg += "; once the cause is fixed, 'kvsctl recover' runs the rollback again"
	if restore {
		msg += fmt.Sprintf("; to finish by hand instead, remove %s and run 'kvsctl restore %s' once MariaDB runs", journal, j.Backup)
	} else {
		msg += fmt.Sprintf("; to finish by hand instead, remove %s once the stack runs %s again", journal, state.Label(j.From))
	}
	return errors.New(msg)
}

// recreateDatadir moves the MariaDB data files aside, inside their volume,
// so the previous image initialises a fresh directory and the dump is
// replayed into it. Nothing is deleted: the files stay in a dated folder of
// the volume until the operator removes them, and the folders of earlier
// rollbacks stay where they are. The journal names the folder before the
// move begins and records the move once it is complete, before any server
// starts on the fresh directory: a move cut short is finished into the
// same folder, and a move already made is not made again.
func (r *Runner) recreateDatadir(ctx context.Context, j *instance.Journal) error {
	if j.DataMoved {
		r.log("the data files were already moved to " + j.DataFolder + " inside the MariaDB data volume")
		return nil
	}
	r.log("stopping mariadb: its data files were upgraded in place and the previous image cannot open them")
	if err := dockerx.Compose(ctx, r.Inst.DockerDir, r.log, "stop", mariadbService); err != nil {
		return err
	}
	if j.DataFolder == "" {
		j.DataFolder = keptPrefix + time.Now().UTC().Format("20060102-150405")
		if err := r.Inst.SaveJournal(j); err != nil {
			return fmt.Errorf("the journal could not be updated, the data files were not moved: %w", err)
		}
	}
	script := fmt.Sprintf(`set -e; cd %s; mkdir -p %s; for f in * .[!.]* ..?*; do [ -e "$f" ] || continue; case "$f" in %s*) continue ;; esac; mv "$f" %s/; done`, mariadbDataDir, j.DataFolder, keptPrefix, j.DataFolder)
	r.log("moving the data files to " + j.DataFolder + " inside the MariaDB data volume")
	if err := dockerx.Compose(ctx, r.Inst.DockerDir, r.log, "run", "--rm", "--no-deps", "--entrypoint", "sh", mariadbService, "-c", script); err != nil {
		return fmt.Errorf("move the data files aside: %w", err)
	}
	j.DataMoved = true
	if err := r.Inst.SaveJournal(j); err != nil {
		return fmt.Errorf("the journal could not be updated, MariaDB was not started on the fresh data directory: %w", err)
	}
	return nil
}

// dataBack puts back the data files a one-way manual rollback moved aside,
// so the server of the version that rollback left starts on them again,
// exactly as it stopped: a server of that version started on the fresh
// directory would run the site on an empty or half replayed database, and
// without a backup of the live database those files are the only copy of
// what that version wrote. The files the older server wrote go to a folder
// of their own first. When the files cannot come back, the rollback stops
// there, naming the folder.
func (r *Runner) dataBack(ctx context.Context, state *instance.State, j *instance.Journal) error {
	if j.Action != instance.ActionRollback || j.DataFolder == "" || j.DataBack {
		return nil
	}
	fresh := j.DataFolder + "-fresh"
	moved := 0
	if j.DataMoved {
		moved = 1
	}
	stopped := func(err error) error {
		msg := fmt.Sprintf("the data files of %s could not be moved back from %s inside the MariaDB data volume (%v), so %s was not started on the fresh data directory; once the cause is fixed, 'kvsctl recover' moves them back", state.Label(j.From), j.DataFolder, errLine(err), state.Label(j.From))
		if j.Backup != "" {
			return fmt.Errorf("%s; the database of %s is also in %s", msg, state.Label(j.From), j.Backup)
		}
		return fmt.Errorf("%s; they are the only copy of what %s wrote: the rollback took no backup of it", msg, state.Label(j.From))
	}
	// Nothing may write while the data files change under MariaDB, and
	// the services of the version the rollback laid run until then.
	if err := r.stopWriters(ctx, j); err != nil {
		return stopped(err)
	}
	r.log(fmt.Sprintf("the data files of %s come back from %s inside the MariaDB data volume", state.Label(j.From), j.DataFolder))
	if err := dockerx.Compose(ctx, r.Inst.DockerDir, r.log, "stop", mariadbService); err != nil {
		return stopped(err)
	}
	script := fmt.Sprintf(`set -e; cd %[1]s; if [ ! -e %[3]s/%[4]s ]; then if [ ! -d %[2]s ]; then if [ %[5]d = 1 ]; then echo "%[2]s is not in the MariaDB data volume" >&2; exit 3; fi; exit 0; fi; mkdir -p %[3]s; if [ %[5]d = 1 ]; then for f in * .[!.]* ..?*; do [ -e "$f" ] || continue; case "$f" in %[6]s*) continue ;; esac; mv "$f" %[3]s/; done; fi; touch %[3]s/%[4]s; fi; if [ -d %[2]s ]; then for f in %[2]s/* %[2]s/.[!.]* %[2]s/..?*; do [ -e "$f" ] || continue; mv "$f" .; done; rmdir %[2]s; fi`,
		mariadbDataDir, j.DataFolder, fresh, backMarker, moved, keptPrefix)
	if err := dockerx.Compose(ctx, r.Inst.DockerDir, r.log, "run", "--rm", "--no-deps", "--entrypoint", "sh", mariadbService, "-c", script); err != nil {
		return stopped(err)
	}
	j.DataBack = true
	if err := r.Inst.SaveJournal(j); err != nil {
		r.log("the journal could not be updated, the rollback goes on: " + err.Error())
	}
	if moved == 1 {
		r.log(fmt.Sprintf("the data files of %s are back in place; the ones the older server wrote are kept in %s", state.Label(j.From), fresh))
	} else {
		r.log(fmt.Sprintf("the data files of %s are back in place", state.Label(j.From)))
	}
	return nil
}

// replay restores a backup into the running MariaDB once it is ready, and
// tells how far it got on the way: a large dump takes a long time.
func (r *Runner) replay(ctx context.Context, archive string, budget time.Duration) error {
	if err := r.waitDatabase(ctx, budget); err != nil {
		return err
	}
	r.log("replaying " + relPath(r.Inst.Root, archive) + " into the database")
	start := time.Now()
	err := backup.RestoreDatabase(ctx, archive, r.mariadbContainer(), func(replayed, total int64) {
		r.log(replayLine(replayed, total, time.Since(start)))
	})
	if err != nil {
		return fmt.Errorf("the replay of %s failed: %w", filepath.Base(archive), err)
	}
	r.log("the database holds " + filepath.Base(archive) + " again")
	return nil
}

// replayLine is the progress of a replay: what the database took of the
// dump, of how much when backup.json gave the size, and since when.
func replayLine(replayed, total int64, elapsed time.Duration) string {
	if total <= 0 {
		return fmt.Sprintf("replayed %s, %s", humanBytes(replayed), elapsed.Round(time.Second))
	}
	return fmt.Sprintf("replayed %s of %s (%d%%), %s", humanBytes(replayed), humanBytes(total), replayed*100/total, elapsed.Round(time.Second))
}

// forwardRollback says why a rollback must not run, "" when it may. After
// a rollback the two slots swap, and running it again would reinstall the
// newer version without a backup, without the blockers and around the
// one-way rules; going forward is an upgrade, which keeps the local files
// and images and is quick. The same holds for MariaDB on its own: a
// rollback never moves it to a newer series, which only an upgrade does,
// backup first.
func forwardRollback(state *instance.State) string {
	_, errCurrent := semver.Parse(state.Current)
	_, errPrevious := semver.Parse(state.Previous)
	if errCurrent == nil && errPrevious == nil && semver.Less(state.Current, state.Previous) {
		return fmt.Sprintf("the previous version %s is newer than the installed %s: a rollback only goes back; to install %s again run 'kvsctl upgrade --version %s'", state.Previous, state.Label(state.Current), state.Previous, state.Previous)
	}
	key := ImageEnvKey(mariadbService)
	have, prev := imageSeries(state.Images[key]), imageSeries(state.PreviousImages[key])
	if have != "" && prev != "" && manifest.LessSeries(have, prev) {
		return fmt.Sprintf("the previous images run MariaDB %s and the stack runs %s: a rollback never moves MariaDB to a newer series; to move it again run 'kvsctl upgrade --version %s --mariadb-series %s'", prev, have, state.Previous, prev)
	}
	return ""
}

// Rollback returns the stack to the previous version by hand. When that
// version needs the database it ran with, the archive the upgrade took is
// replayed, after a backup of the live database: what was written since
// the archive would otherwise be lost for good. The services that write
// are stopped before that backup and stay stopped until the replay is
// over. Everything a rollback needs is checked before its first change:
// the files and settings it lays, a MariaDB that compose can start the
// other services on, unless the rollback puts back another one, and the
// images of the previous version, pulled when the engine no longer holds
// them. A rollback that fails part way keeps its journal, and recover
// returns the stack to the version the rollback started from.
func (r *Runner) Rollback(ctx context.Context, state *instance.State) (err error) {
	defer func() { r.event(Event{Kind: KindDone, Err: err}) }()
	if state == nil || state.Previous == "" {
		return errors.New("no previous version to return to")
	}
	if msg := forwardRollback(state); msg != "" {
		return errors.New(msg)
	}
	if err := r.noJournal(state); err != nil {
		return err
	}
	prevDir := r.keptDir(state.Previous, state.PreviousFiles)
	if _, err := os.Stat(prevDir); err != nil {
		return fmt.Errorf("the files of %s are not kept in %s", state.Label(state.Previous), prevDir)
	}
	if len(state.PreviousFiles) == 0 || len(state.Files) == 0 {
		return fmt.Errorf("the state does not list the release files of %s and %s, so a rollback cannot tell which files to put back; nothing was changed, and the files of %s are kept in %s", state.Label(state.Previous), state.Label(state.Current), state.Label(state.Previous), prevDir)
	}
	// What keeps the files of the previous version from taking their place
	// stops the rollback here: met when they are laid, once the services
	// that write are stopped and the database backed up, it would leave
	// the rollback part way.
	if problems := release.Conflicts(r.Inst.Root, state.PreviousFiles, state.Files); len(problems) > 0 {
		return fmt.Errorf("the files of %s cannot take their place: %s; nothing was changed, the stack is still on %s", state.Label(state.Previous), strings.Join(problems, "; "), state.Label(state.Current))
	}
	composeFile := r.rollbackComposeFile(state)
	if err := r.checkSettings(state, prevDir, composeFile); err != nil {
		return err
	}
	replay, taken, err := r.rollbackDump(state)
	if err != nil {
		return err
	}
	ignored, err := r.acceptedUnhealthy(ctx)
	if err != nil {
		return err
	}
	if err := r.rollbackMariaDB(ctx, state, replay); err != nil {
		return err
	}
	if !r.Opts.Yes {
		r.start(StepConfirm, fmt.Sprintf("Roll %s back from %s to %s?", r.Inst.Domain(), state.Label(state.Current), state.Label(state.Previous)))
		if !r.Reporter.Confirm(ctx, r.rollbackQuestion(state, replay, taken)) {
			r.fail(StepConfirm, "cancelled")
			return errors.New("rollback cancelled, nothing was changed")
		}
		r.done(StepConfirm, "yes")
	}
	// The images of the previous version may be gone from the engine since
	// the upgrade, pruned to free space: they are pulled while the site
	// still runs, before anything changes.
	services, containers := r.composeView(ctx)
	if err := r.ensureImages(ctx, r.targetImages(ctx, state.ReleaseImages[state.Previous], state.ReleaseImages[state.Current], state.PreviousImages, services)); err != nil {
		if r.interrupted(ctx, err) {
			return fmt.Errorf("rollback interrupted, nothing was changed, the stack is still on %s", state.Label(state.Current))
		}
		return fmt.Errorf("%w; nothing was changed, the stack is still on %s", err, state.Label(state.Current))
	}
	if err := r.keepFiles(state.Current, state.Files, "keeping the files of "+state.Label(state.Current)+" for a recovery"); err != nil {
		return fmt.Errorf("keep the files of %s: %w; nothing was changed", state.Label(state.Current), err)
	}
	j := &instance.Journal{
		Action:            instance.ActionRollback,
		From:              state.Current,
		To:                state.Previous,
		Phase:             instance.PhaseApply,
		Log:               r.Opts.LogPath,
		Replay:            replay,
		MariaDB:           r.mariadbMark(ctx),
		Files:             state.PreviousFiles,
		ImagesBefore:      r.envBefore(state.Images, state.PreviousImages),
		ImagesAfter:       withoutComposeFile(state.PreviousImages),
		ComposeFileBefore: r.Inst.Env[composeFileKey],
		Pins:              state.ReleaseImages[state.Previous],
		Ignored:           ignored,
		Services:          services,
		Containers:        containers,
	}
	if replay != "" {
		// Undoing this rollback means replaying the live database it saved
		// first, whatever the version left declared, or putting back the
		// data files a one-way rollback moved aside.
		j.Phase, j.Database, j.OneWay = instance.PhaseBackup, migrates, state.OneWay
	}
	if ctx.Err() != nil {
		return fmt.Errorf("rollback interrupted, nothing was changed, the stack is still on %s", state.Label(state.Current))
	}
	if err := r.Inst.SaveJournal(j); err != nil {
		return fmt.Errorf("the journal could not be written: %w; nothing was changed, the stack is still on %s", err, state.Label(state.Current))
	}
	if replay != "" {
		if err := r.backupStopped(ctx, state, j); err != nil {
			return err
		}
	} else {
		r.start(StepBackup, "not needed: the database is not replayed")
		r.done(StepBackup, "skipped")
	}
	if ctx.Err() != nil {
		r.giveUp(ctx, j)
		return fmt.Errorf("rollback interrupted, nothing was changed, the stack is still on %s", state.Label(state.Current))
	}
	// From the first change on, the rollback runs to its end whatever
	// happens to the command: stopped half way, it would leave the stack
	// between two versions.
	ctx = context.WithoutCancel(ctx)
	j.Phase, j.Applied = instance.PhaseApply, true
	if err := r.Inst.SaveJournal(j); err != nil {
		r.giveUp(ctx, j)
		return fmt.Errorf("the journal could not be updated: %w; nothing was changed, the stack is still on %s", err, state.Label(state.Current))
	}
	partWay := func(step string, err error) error {
		r.fail(step, errLine(err))
		return r.partWay(ctx, state, j, err)
	}

	r.start(StepApply, "files of "+state.Label(state.Previous))
	if err := release.Sync(prevDir, r.Inst.Root, state.PreviousFiles, state.Files); err != nil {
		return partWay(StepApply, err)
	}
	if err := r.setComposeFile(composeFile); err != nil {
		return partWay(StepApply, fmt.Errorf("COMPOSE_FILE: %w", err))
	}
	if err := r.restoreEnv(state.PreviousImages, state.Images); err != nil {
		return partWay(StepApply, fmt.Errorf(".env: %w", err))
	}
	r.done(StepApply, fmt.Sprintf("%d files", len(state.PreviousFiles)))

	r.start(StepRestart, "docker compose up")
	budget := r.dbBudget(state.OneWay)
	if err := dockerx.ComposeConfigCheck(ctx, r.Inst.DockerDir); err != nil {
		touched := "no container was touched"
		if len(j.Stopped) > 0 {
			touched = fmt.Sprintf("no container was started, and %s, which the rollback stopped, stay stopped", strings.Join(j.Stopped, ", "))
		}
		return partWay(StepRestart, fmt.Errorf("compose cannot read the project, %s: %w", touched, err))
	}
	mark := r.mariadbMark(ctx)
	j.Phase, j.ComposeStarted, j.MariaDB = instance.PhaseRestart, true, mark
	if err := r.Inst.SaveJournal(j); err != nil {
		j.ComposeStarted = false
		return partWay(StepRestart, fmt.Errorf("the journal could not be updated, compose was not started: %w", err))
	}
	removed, err := r.removeLeftovers(ctx, j, false)
	if err != nil {
		return partWay(StepRestart, err)
	}
	var slow []string
	if replay == "" {
		started, err := r.composeUp(ctx, mariadbChanges(j.ImagesBefore, j.ImagesAfter), budget)
		j.ComposeStarted = started || removed
		if err != nil {
			return partWay(StepRestart, err)
		}
	} else {
		if state.OneWay {
			if err := r.recreateDatadir(ctx, j); err != nil {
				return partWay(StepRestart, err)
			}
		}
		if slow, err = r.replayAlone(ctx, replay, budget); err != nil {
			return partWay(StepRestart, err)
		}
	}
	j.MariaDBRecreated = r.mariadbChanged(ctx, mark)
	j.Phase = instance.PhaseVerify
	if err := r.Inst.SaveJournal(j); err != nil {
		r.log("the journal could not be updated, the rollback goes on: " + err.Error())
	}
	r.done(StepRestart, "services restarted")

	r.start(StepVerify, "containers, site, admin")
	if err := r.verify(ctx, j.Ignored, budget, slow...); err != nil {
		return partWay(StepVerify, err)
	}
	j.Phase = instance.PhaseRecord
	journaled := true
	if err := r.Inst.SaveJournal(j); err != nil {
		journaled = false
		r.log("the journal could not be updated: " + err.Error())
	}
	r.done(StepVerify, "healthy")
	return r.recordRollback(state, j, journaled)
}

// rollbackComposeFile is the COMPOSE_FILE a manual rollback writes: the one
// the previous version ran with, "" for none, when the state recorded it,
// with an override created since added; otherwise the list of its release
// files, the way an upgrade writes it.
func (r *Runner) rollbackComposeFile(state *instance.State) string {
	if value, ok := state.PreviousImages[composeFileKey]; ok {
		return r.withOverride(value)
	}
	return r.composeFilesFor(state.PreviousFiles)
}

// requiredRe finds the variables a compose file cannot do without:
// ${VAR:?message}, which needs a value, and ${VAR?message}, which needs the
// variable set.
var requiredRe = regexp.MustCompile(`\$\{([A-Za-z_][A-Za-z0-9_]*)(:?)\?`)

// checkSettings refuses a rollback compose could not read once it is laid,
// before anything changes: every file the COMPOSE_FILE it writes names must
// be there with the files of the previous version, and every variable
// those files require must have a value in .env as the rollback leaves it.
// The release override of a version reads its variant images from .env,
// and a state that does not record them would otherwise end the rollback
// part way, with the files already laid.
func (r *Runner) checkSettings(state *instance.State, prevDir, composeFile string) error {
	env := maps.Clone(r.Inst.Env)
	if env == nil {
		env = map[string]string{}
	}
	for key := range state.Images {
		if _, ok := state.PreviousImages[key]; !ok {
			delete(env, key)
		}
	}
	for key, value := range state.PreviousImages {
		if key != composeFileKey {
			env[key] = value
		}
	}
	names := []string{"docker-compose.yml"}
	if composeFile != "" {
		names = strings.Split(composeFile, r.composeSeparator())
	} else if override := DefaultOverride(r.Inst.DockerDir); override != "" {
		names = append(names, override)
	}
	refuse := func(why string) error {
		shown := "COMPOSE_FILE=" + composeFile
		if composeFile == "" {
			shown = "no COMPOSE_FILE"
		}
		return fmt.Errorf("the rollback to %s would leave %s with %s: compose could not read the project; nothing was changed, the stack is still on %s", state.Label(state.Previous), shown, why, state.Label(state.Current))
	}
	for _, name := range names {
		if name == "" {
			continue
		}
		path := name
		if !filepath.IsAbs(name) {
			path = filepath.Join(r.Inst.DockerDir, name)
		}
		relName, err := filepath.Rel(r.Inst.Root, path)
		if err == nil {
			relName = filepath.ToSlash(relName)
			switch {
			case slices.Contains(state.PreviousFiles, relName):
				path = filepath.Join(prevDir, filepath.FromSlash(relName))
			case slices.Contains(state.Files, relName):
				return refuse(name + " is a file of " + state.Label(state.Current) + " only")
			}
		}
		data, err := os.ReadFile(path)
		if err != nil {
			return refuse(name + " cannot be read: " + err.Error())
		}
		for _, line := range strings.Split(string(data), "\n") {
			if strings.HasPrefix(strings.TrimSpace(line), "#") {
				continue
			}
			for _, m := range requiredRe.FindAllStringSubmatch(line, -1) {
				value, set := env[m[1]]
				if !set || (m[2] == ":" && value == "") {
					return refuse(fmt.Sprintf("no value for %s, which %s requires", m[1], name))
				}
			}
		}
	}
	return nil
}

// acceptedUnhealthy is what --allow-unhealthy accepts in a manual rollback:
// the services unhealthy, restarting or not running when it begins, which
// its verification then leaves out. A rollback is the repair of a broken
// upgrade, so a stack in that state is no reason to refuse it; a service
// broken in both versions for a reason that is not the release is what the
// flag is for. Without the flag nothing is read and every active service
// is judged.
func (r *Runner) acceptedUnhealthy(ctx context.Context) ([]string, error) {
	if !r.Opts.AllowUnhealthy {
		return nil, nil
	}
	services, err := dockerx.ActiveServices(ctx, r.Inst.DockerDir)
	if err != nil {
		return nil, fmt.Errorf("the services of the stack could not be listed (%w): nothing was changed", err)
	}
	problems, failing, err := r.unhealthy(ctx, services)
	if err != nil {
		return nil, fmt.Errorf("the containers of the stack could not be read (%w): nothing was changed", err)
	}
	if len(failing) == 0 {
		r.log("every active service is healthy: --allow-unhealthy leaves none out")
		return nil, nil
	}
	r.log("accepted as they are (--allow-unhealthy): " + strings.Join(problems, "; "))
	return failing, nil
}

// mariadbUsable refuses a restore, and a rollback that leaves MariaDB as it
// is, while MariaDB runs and fails its health check or keeps restarting,
// --allow-unhealthy or not: the services that need it wait for it to be
// healthy, so compose would leave them created and never started, the site
// down. A MariaDB that does not run is started like any other service.
// state is nil for a restore on a stack kvsctl recorded no state for.
func (r *Runner) mariadbUsable(ctx context.Context, state *instance.State) error {
	if c, broken := r.mariadbBroken(ctx); broken {
		return mariadbRefusal(c, state)
	}
	return nil
}

// mariadbRefusal is the error of a run refused because c, the mariadb
// container, runs unhealthy or keeps restarting.
func mariadbRefusal(c dockerx.ContainerState, state *instance.State) error {
	msg := fmt.Sprintf("%s: the services that need MariaDB wait for it to be healthy, so compose could not start them and the site would stay down; repair MariaDB first (read 'docker logs %s'); nothing was changed", describeContainer(c), c.Name)
	if state != nil && state.Current != "" {
		msg += ", the stack is still on " + state.Label(state.Current)
	}
	return errors.New(msg)
}

// mariadbBroken is the mariadb container, and whether it runs and fails its
// health check or keeps restarting. A container that cannot be read is not
// broken: the rollback or the restore finds out.
func (r *Runner) mariadbBroken(ctx context.Context) (dockerx.ContainerState, bool) {
	c, err := r.Docker.Container(ctx, r.mariadbContainer())
	if err != nil {
		return c, false
	}
	return c, c.State == "restarting" || (c.State == "running" && c.Health == "unhealthy")
}

// rollbackMariaDB checks MariaDB before the first change of a manual
// rollback that replays replay, "" for none. A rollback that puts back
// another MariaDB image, or recreates its data directory, starts MariaDB
// alone first, on what the version it returns to runs, and the services
// that need it once it is healthy: a MariaDB that fails its health check
// or keeps restarting does not stop it, since that may be the repair,
// unless the rollback backs up the live database first, which takes a
// MariaDB that answers. Any other rollback is refused as a restore is.
func (r *Runner) rollbackMariaDB(ctx context.Context, state *instance.State, replay string) error {
	c, broken := r.mariadbBroken(ctx)
	if !broken {
		return nil
	}
	if !state.OneWay && !mariadbChanges(r.envBefore(state.Images, state.PreviousImages), withoutComposeFile(state.PreviousImages)) {
		return mariadbRefusal(c, state)
	}
	if replay != "" && !r.Opts.NoBackup {
		msg := fmt.Sprintf("%s: the rollback backs up the live database before it replays %s, which takes a MariaDB that answers; repair MariaDB first (read 'docker logs %s'), or pass --no-backup to roll back without that backup", describeContainer(c), filepath.Base(replay), c.Name)
		if state.OneWay {
			msg += fmt.Sprintf(", the data files of %s then kept aside in the MariaDB data volume", state.Label(state.Current))
		}
		return fmt.Errorf("%s; nothing was changed, the stack is still on %s", msg, state.Label(state.Current))
	}
	r.log(fmt.Sprintf("%s: the rollback starts MariaDB alone first, as %s runs it, and the services that need it once it is healthy", describeContainer(c), state.Label(state.Previous)))
	return nil
}

// targetImages are the images a rollback starts that the engine must hold:
// the variant images the version it returns to wrote to .env, and the
// images pins, its release, pinned for the services it runs. The
// repository of a pin tells which those are. One that the container of a
// service of active runs is the image of that service. One that no image of
// left, the release of the version the rollback leaves, has is the image of
// a service only the version returned to runs: the run that installed left
// removed its container, so nothing holds the image any more. A pin of
// both releases that no container runs, a service whose profile is off, is
// not started and not needed. active nil, the services unknown, counts
// every container.
func (r *Runner) targetImages(ctx context.Context, pins, left []string, settings map[string]string, active []string) []string {
	repos := map[string]bool{}
	running, err := r.Docker.ServiceImages(ctx, r.Inst.ProjectName())
	if err != nil {
		r.log("the images the containers run could not be read, so the images of the services both versions run are not checked: " + firstLine(err.Error()))
	}
	for service, svc := range running {
		if active == nil || slices.Contains(active, service) {
			repos[dockerx.RefName(svc.Image)] = true
		}
	}
	shared := map[string]bool{}
	for _, pin := range left {
		shared[dockerx.RefName(pin)] = true
	}
	var out []string
	for key, value := range settings {
		if isImageKey(key) && strings.Contains(value, "@") {
			out = append(out, value)
		}
	}
	for _, pin := range pins {
		if repo := dockerx.RefName(pin); repos[repo] || !shared[repo] {
			out = append(out, pin)
		}
	}
	slices.Sort(out)
	return slices.Compact(out)
}

// ensureImages makes sure the engine holds every image of refs, each a
// reference at its digest, and pulls the missing ones by digest with the
// credentials of the machine, the way an upgrade pulls the images of a
// release.
func (r *Runner) ensureImages(ctx context.Context, refs []string) error {
	missing, err := r.missingImages(ctx, refs)
	if err != nil {
		return err
	}
	for _, ref := range missing {
		name, digest, _ := strings.Cut(ref, "@")
		r.log("pulling " + ref + ": the engine no longer holds it")
		if err := r.Docker.Pull(ctx, name, digest, 0, nil); err != nil {
			return fmt.Errorf("%s is not on this machine any more and could not be pulled: %w", ref, err)
		}
	}
	return nil
}

// missingImages are the images of refs, each a reference at its digest,
// that the engine does not hold.
func (r *Runner) missingImages(ctx context.Context, refs []string) ([]string, error) {
	var missing []string
	for _, ref := range refs {
		name, digest, ok := strings.Cut(ref, "@")
		if !ok {
			continue
		}
		has, err := r.Docker.HasDigest(ctx, name, digest)
		if err != nil {
			return nil, fmt.Errorf("the engine could not say whether it holds %s: %w", ref, err)
		}
		if !has {
			missing = append(missing, ref)
		}
	}
	return missing, nil
}

// MissingRollbackImages are the images a manual rollback to the previous
// version would pull before its first change, the ones it starts that the
// engine no longer holds, for status to name: while the registry cannot be
// reached, that rollback is refused. check leaves them out: the rollback of
// the upgrade it plans returns to the installed version, not to that one.
// A state without a previous version has none.
func (r *Runner) MissingRollbackImages(ctx context.Context, state *instance.State) ([]string, error) {
	if state == nil || state.Previous == "" {
		return nil, nil
	}
	// Services that cannot be listed leave every container counted, as
	// the rollback does.
	services, _ := dockerx.ActiveServices(ctx, r.Inst.DockerDir)
	return r.missingImages(ctx, r.targetImages(ctx, state.ReleaseImages[state.Previous], state.ReleaseImages[state.Current], state.PreviousImages, services))
}

// rollbackDump is the archive a rollback replays, "" when the version left
// declared no change to the database and none was asked for: the exact
// archive the upgrade to the installed version took or, for a state that
// does not name one, the newest backup of the previous version. taken is
// when the archive was written.
func (r *Runner) rollbackDump(state *instance.State) (path string, taken time.Time, err error) {
	if state.Database != migrates && !state.OneWay && !r.Opts.RestoreDB {
		return "", time.Time{}, nil
	}
	path = state.UpgradeBackup
	if path == "" {
		if path, err = backup.Latest(r.Inst.BackupDir(), state.Previous); err != nil {
			return "", time.Time{}, err
		}
		if path == "" {
			return "", time.Time{}, fmt.Errorf("%s changed the database and no backup of %s is kept in %s: the old code would run on the new schema, so take the database back by hand first", state.Label(state.Current), state.Label(state.Previous), r.Inst.BackupDir())
		}
	}
	meta, _, err := backup.Describe(path)
	if err != nil {
		return "", time.Time{}, fmt.Errorf("the backup the upgrade to %s took cannot be read (%w): the database %s needs is in no other archive kvsctl can vouch for; nothing was changed", state.Label(state.Current), err, state.Label(state.Previous))
	}
	return path, meta.Date, nil
}

// rollbackQuestion is what the operator agrees to: the version, and when a
// dump is replayed, which one, from when, with which KVS, that the site is
// down meanwhile, and what becomes of what was written since.
func (r *Runner) rollbackQuestion(state *instance.State, replay string, taken time.Time) string {
	if replay == "" {
		return fmt.Sprintf("Roll back to %s? The database is left as it is.", state.Label(state.Previous))
	}
	q := fmt.Sprintf("Roll back to %s and replay %s, taken %s", state.Label(state.Previous), filepath.Base(replay), taken.UTC().Format("2006-01-02 15:04 UTC"))
	if note := KVSNote(ArchiveKVSVersion(replay), r.Inst.KVSVersion()); note != "" {
		q += " with " + note
	}
	q += "? The site is down until the replay is over."
	if state.OneWay {
		q += " The MariaDB data directory is recreated first."
	}
	if r.Opts.NoBackup {
		return q + " What was written to the database since then is replaced and lost: --no-backup takes no backup of it first."
	}
	return q + " What was written to the database since then is replaced; a backup of it is taken first."
}

// backupStopped stops the services that write and backs up the live
// database before a rollback replays an older dump over it, labelled with
// the version being left, so the rollback is never the last word on that
// data and the backup holds every write the site acknowledged. A failure
// starts the services again and removes the journal: nothing was changed.
func (r *Runner) backupStopped(ctx context.Context, state *instance.State, j *instance.Journal) error {
	still := fmt.Sprintf("nothing was changed, the stack is still on %s", state.Label(state.Current))
	if err := r.stopWriters(ctx, j); err != nil {
		interrupted := r.interrupted(ctx, err)
		r.giveUp(ctx, j)
		if interrupted {
			return fmt.Errorf("rollback interrupted while it stopped the services that write, %s", still)
		}
		return fmt.Errorf("%w; %s", err, still)
	}
	if r.Opts.NoBackup {
		r.start(StepBackup, "skipped (--no-backup)")
		r.done(StepBackup, "skipped")
	} else {
		r.start(StepBackup, "the live database of "+state.Label(state.Current))
		result, err := backup.Create(ctx, r.Inst.BackupDir(), state.Current, r.mariadbContainer(), r.Inst.EnvPath, r.statePath(), r.log, backup.WithKVSVersion(r.Inst.KVSVersion()))
		if err != nil {
			r.failStep(StepBackup, err)
			r.giveUp(ctx, j)
			if ctx.Err() != nil {
				return fmt.Errorf("rollback interrupted during the backup of the live database, %s", still)
			}
			return fmt.Errorf("backup of the live database: %w; %s", err, still)
		}
		r.done(StepBackup, fmt.Sprintf("%s (%s, %s)", relPath(r.Inst.Root, result.Path), humanBytes(result.Size), result.Duration.Round(time.Second)))
		j.Backup = result.Path
	}
	if err := r.Inst.SaveJournal(j); err != nil {
		r.giveUp(ctx, j)
		return fmt.Errorf("the journal could not be updated: %w; %s", err, still)
	}
	return nil
}

// giveUp ends a run that changed nothing but the services it stopped: they
// start again, and the journal goes. Services that do not start again
// leave the site down, which the operator is told even where the progress
// of the run is left out.
func (r *Runner) giveUp(ctx context.Context, j *instance.Journal) {
	if err := r.startWriters(context.WithoutCancel(ctx), j.Stopped); err != nil {
		r.notice(fmt.Sprintf("%s could not be started again: %s; run 'docker compose start %s' in %s", strings.Join(j.Stopped, ", "), errLine(err), strings.Join(j.Stopped, " "), r.Inst.DockerDir))
	}
	r.dropJournal()
}

// partWay is the error of a manual rollback that failed after its first
// change: the stack is between two versions, and recover takes it back to
// the one the rollback started from. The journal records the failure, and
// the message says what recover does with the database, by the rule it
// applies.
func (r *Runner) partWay(ctx context.Context, state *instance.State, j *instance.Journal, err error) error {
	j.Cause, j.Outcome = errLine(err), instance.OutcomeFailed
	r.noteFailure(j, err)
	back := fmt.Sprintf("'kvsctl recover' returns it to %s", state.Label(j.From))
	if j.DataFolder != "" {
		back += fmt.Sprintf(", moving its data files back from %s inside the MariaDB data volume", j.DataFolder)
	} else if restore, _, _ := restorePlan(state, j, r.recreated(ctx, j)); restore {
		back += fmt.Sprintf(", replaying %s", filepath.Base(j.Backup))
	}
	msg := fmt.Sprintf("the rollback to %s failed part way: %s; the stack is in an unknown state: %s", state.Label(j.To), errLine(err), back)
	return &failure{msg: msg + r.logNote(), cause: err, kind: ErrRollbackFailed}
}

// recreated reports whether the mariadb container the run began with may
// have been replaced: once compose started, by the journal or by a look at
// the container now. It is what restorePlan needs to know.
func (r *Runner) recreated(ctx context.Context, j *instance.Journal) bool {
	return j.ComposeStarted && (j.MariaDBRecreated || r.mariadbChanged(ctx, j.MariaDB))
}

// recordRollback writes a manual rollback that passed its verification
// into the state: the two versions swap, and so do the settings each ran
// with, COMPOSE_FILE included.
func (r *Runner) recordRollback(state *instance.State, j *instance.Journal, journaled bool) error {
	left := state.Current
	state.Current, state.Previous = state.Previous, state.Current
	state.Files, state.PreviousFiles = state.PreviousFiles, state.Files
	state.Images = withComposeFile(withoutComposeFile(state.PreviousImages), r.Inst.Env[composeFileKey])
	state.PreviousImages = withComposeFile(j.ImagesBefore, j.ComposeFileBefore)
	// What the version now running does to the database is only known from
	// the release it was installed from, which this state no longer names,
	// and neither is the archive its upgrade took.
	state.Database, state.OneWay = "", false
	state.UpgradeBackup = ""
	if sums, err := release.Checksums(r.Inst.Root, state.Files); err != nil {
		r.log("the release files could not be checksummed, local changes will not be detected: " + err.Error())
		state.Checksums = nil
	} else {
		state.Checksums = sums
	}
	note := "by hand from " + left
	if j.Backup != "" {
		note += ", the database of " + left + " is in " + filepath.Base(j.Backup)
	}
	state.History = append(state.History, instance.Entry{Version: state.Current, Action: instance.ActionRollback, Date: j.Started, Note: note})
	if err := r.Inst.SaveState(state); err != nil {
		return r.notRecorded(state, j, journaled, err)
	}
	r.finish(state.Current)
	return nil
}

// withoutComposeFile is a copy of a set of settings without COMPOSE_FILE,
// nil when nothing else is left.
func withoutComposeFile(settings map[string]string) map[string]string {
	out := maps.Clone(settings)
	delete(out, composeFileKey)
	return copyImages(out)
}

// Recover finishes the run an interrupted journal names. A run that passed
// its verification is recorded as it would have been; any other is rolled
// back from what the journal says it did. A journal whose run is already
// in the state, which a crash between the two writes leaves, is only
// removed. A restore is finished: its archive is replayed again when the
// replay was cut.
func (r *Runner) Recover(ctx context.Context, state *instance.State) (err error) {
	defer func() { r.event(Event{Kind: KindDone, Err: err}) }()
	j, err := r.Inst.LoadJournal()
	if err != nil {
		return err
	}
	if j == nil {
		return errors.New("nothing to recover: no run was interrupted")
	}
	if j.Action == instance.ActionRestore {
		return r.recoverRestore(ctx, state, j)
	}
	if recorded, undone := finished(state, j); recorded || undone {
		r.log(j.Describe(state) + ", but the state already records its end: only its journal was left")
		if recorded && j.Action == instance.ActionUpgrade && j.From == j.To {
			// A re-apply moves its files into place before it writes the
			// state; doing it again is harmless.
			if err := r.promote(j.To); err != nil {
				return err
			}
		}
		r.finish(state.Current)
		return nil
	}
	if state == nil || state.Current != j.From {
		recorded := "no version"
		if state != nil {
			recorded = state.Label(state.Current)
		}
		return fmt.Errorf("%s, but the state records %s as installed, so kvsctl cannot tell what the stack runs: read the log of that run (%s), put the stack right by hand, then remove %s", j.Describe(state), recorded, j.Log, filepath.Join(r.Inst.StateDir(), "journal.json"))
	}
	what := j.Describe(state)
	r.log(what)
	if j.DataMoved && !j.DataBack {
		r.log(fmt.Sprintf("the run moved the MariaDB data files to %s inside the data volume", j.DataFolder))
	}
	recording := j.Phase == instance.PhaseRecord
	// Containers that changed since the run began are compose run by hand
	// or from a script: the rollback then counts compose as started, and
	// the question says what it does with the database by the same rule.
	if !recording && !j.ComposeStarted && r.composeRan(ctx, j) {
		j.ComposeStarted = true
	}
	if !r.Opts.Yes {
		r.start(StepConfirm, capitalize(what))
		if !r.Reporter.Confirm(ctx, r.recoverQuestion(ctx, state, j)) {
			r.fail(StepConfirm, "cancelled")
			return errors.New("recover cancelled, nothing was changed")
		}
		r.done(StepConfirm, "yes")
	}
	if recording {
		r.start(StepRecord, state.Label(j.To)+" passed its verification")
		if err := r.record(state, j, true); err != nil {
			r.fail(StepRecord, errLine(err))
			return err
		}
		r.done(StepRecord, state.Label(j.To)+" recorded")
		return nil
	}
	// The history keeps why a run that failed or was cancelled ended, as
	// its journal records it; a run cut short says where it stopped.
	cause := errors.New("interrupted during " + j.Phase)
	if j.Cause != "" {
		cause = errors.New(j.Cause)
	}
	if err := r.undo(ctx, state, j, cause); err != nil {
		return &failure{
			msg:   fmt.Sprintf("%s; the rollback to %s failed: %s%s", what, state.Label(j.From), errLine(err), r.logNote()),
			cause: err,
			kind:  ErrRollbackFailed,
		}
	}
	return nil
}

// recoverQuestion is what recover asks before it acts. Undoing a run, it
// says what becomes of the database by the rule the rollback applies: the
// data files a one-way rollback moved aside come back, the backup is
// replayed, or the database is left as it is, and why.
func (r *Runner) recoverQuestion(ctx context.Context, state *instance.State, j *instance.Journal) string {
	run := "upgrade"
	if j.Action == instance.ActionRollback {
		run = "rollback"
	}
	if j.Phase == instance.PhaseRecord {
		return fmt.Sprintf("Record the %s to %s, which passed its verification before kvsctl stopped?", run, state.Label(j.To))
	}
	q := fmt.Sprintf("Return the stack to %s, undoing what the %s to %s did?", state.Label(j.From), run, state.Label(j.To))
	if j.Action == instance.ActionRollback && j.DataFolder != "" && !j.DataBack {
		return q + fmt.Sprintf(" The data files of %s come back from %s, inside the MariaDB data volume.", state.Label(j.From), j.DataFolder)
	}
	restore, _, why := restorePlan(state, j, r.recreated(ctx, j))
	q += " " + capitalize(why) + "."
	if restore {
		q += " What was written to the database since that backup was taken is replaced, and the site is down until the replay is over."
	}
	return q
}

// finished reports whether the state already records the end of the run
// the journal names: recorded, or rolled back. The entry a run adds to the
// history carries the start of the run as its date, which names the run
// whatever the clock did since: an entry dated in the future by a clock
// that was ahead, or one older than the journal after a clock stepped
// back, is told from it.
func finished(state *instance.State, j *instance.Journal) (recorded, undone bool) {
	if state == nil {
		return false, false
	}
	if j.Format < instance.JournalFormat {
		return finishedBefore(state, j)
	}
	for _, e := range state.History {
		if !e.Date.Equal(j.Started) {
			continue
		}
		switch {
		case state.Current == j.To && e.Version == j.To && e.Action == j.Action:
			recorded = true
		case j.Phase == instance.PhaseRollback && state.Current == j.From && e.Version == j.From && e.Action == instance.ActionRollback:
			undone = true
		}
	}
	if recorded {
		undone = false
	}
	return recorded, undone
}

// finishedBefore is finished for the journal of a run an older kvsctl
// began, which dated the entry the run adds to the history when it wrote
// it: the state records the end of the run when its last entry is that
// entry, dated at the start of the run or after it. A clock that moved
// meanwhile can fool it, which the start of the run as the date of its
// entry, from JournalFormat on, does not.
func finishedBefore(state *instance.State, j *instance.Journal) (recorded, undone bool) {
	if len(state.History) == 0 {
		return false, false
	}
	last := state.History[len(state.History)-1]
	if last.Date.Before(j.Started) {
		return false, false
	}
	recorded = state.Current == j.To && last.Version == j.To && last.Action == j.Action
	undone = !recorded && j.Phase == instance.PhaseRollback && state.Current == j.From && last.Version == j.From && last.Action == instance.ActionRollback
	return recorded, undone
}
