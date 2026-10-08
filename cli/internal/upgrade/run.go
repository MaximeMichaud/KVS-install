package upgrade

import (
	"context"
	"errors"
	"fmt"
	"maps"
	"os"
	"path/filepath"
	"slices"
	"strings"
	"time"

	"github.com/MaximeMichaud/KVS-install/cli/internal/backup"
	"github.com/MaximeMichaud/KVS-install/cli/internal/dockerx"
	"github.com/MaximeMichaud/KVS-install/cli/internal/instance"
	"github.com/MaximeMichaud/KVS-install/cli/internal/manifest"
	"github.com/MaximeMichaud/KVS-install/cli/internal/release"
)

// mariadbVersionKey is the .env setting that names the MariaDB series of
// the stack. setup.sh reads it to tell an upgrade of the data volume from a
// downgrade, so a series change writes it with the image.
const mariadbVersionKey = "MARIADB_VERSION"

// composeFileKey is COMPOSE_FILE among the settings the state records for
// a version: the list that version ran with, "" for none, which leaves
// compose to its default files.
const composeFileKey = "COMPOSE_FILE"

// phpKeys are the .env settings that name the PHP series of the site. A run
// records them with the images: a re-apply to another series is asked for
// by changing them, and its rollback puts them back.
var phpKeys = []string{"PHP_VERSION", "KVS_PHP_VERSION"}

// Run performs the planned upgrade. It ends with a KindDone event whatever
// happens, refusals included, so a screen showing the run always closes.
//
// Nothing is changed until the journal is written: a failure or an
// interrupt before that (the backup, a pull, the download of the bundle)
// leaves the stack as it was. From the journal on, a failure rolls back
// what really happened, and the journal follows each phase, so a run cut
// short is finished or undone by Recover.
func (r *Runner) Run(ctx context.Context, state *instance.State, plan *Plan) (err error) {
	defer func() { r.event(Event{Kind: KindDone, Err: err}) }()
	switch {
	case len(plan.Blockers) > 0:
		return &failure{msg: "upgrade blocked: " + strings.Join(plan.Blockers, "; "), kind: ErrBlocked}
	case plan.Downgrade:
		return errors.New(plan.DowngradeMessage())
	case plan.UpToDate:
		return fmt.Errorf("%s is already installed with the images it pins", plan.Current)
	}
	if err := r.noJournal(state); err != nil {
		return err
	}
	target := plan.Target
	r.start(StepCheck, "manifest")
	r.done(StepCheck, fmt.Sprintf("%s available, manifest signature verified", target.Version))
	r.announceImages(plan)
	r.announceReleases(plan)
	r.announceDisk(plan)
	if !r.Opts.Yes {
		r.start(StepConfirm, capitalize(plan.action())+"?")
		question := fmt.Sprintf("%s: %s (%s to download)?", r.Inst.Domain(), plan.action(), humanBytes(plan.Bytes))
		if !r.Reporter.Confirm(ctx, question) {
			r.fail(StepConfirm, "cancelled")
			return errors.New("upgrade cancelled, nothing was changed")
		}
		r.done(StepConfirm, "yes")
	}
	backupPath, err := r.backupBefore(ctx, state, plan)
	if err != nil {
		return err
	}
	switch downloads := len(plan.Downloads()); downloads {
	case 0:
		r.start(StepPull, "every image is already on this machine")
	case 1:
		r.start(StepPull, fmt.Sprintf("1 image, %s to download", humanBytes(plan.Bytes)))
	default:
		r.start(StepPull, fmt.Sprintf("%d images, %s to download", downloads, humanBytes(plan.Bytes)))
	}
	if err := r.pull(ctx, plan); err != nil {
		r.failStep(StepPull, err)
		return r.untouched(plan, err)
	}
	r.done(StepPull, "images ready")
	return r.change(ctx, state, plan, backupPath)
}

// change is the part of Run that changes the installation: it lays the
// release, restarts the stack and verifies it, under the journal, then
// records the new version.
func (r *Runner) change(ctx context.Context, state *instance.State, plan *Plan, backupPath string) error {
	target := plan.Target
	r.start(StepApply, "release files of "+target.Version)
	dir, files, err := r.stage(ctx, state, plan)
	if err != nil {
		r.failStep(StepApply, err)
		return r.untouched(plan, err)
	}
	want := variantEnv(plan)
	before, after := r.runSettings(state, plan, want)
	services, containers := r.composeView(ctx)
	j := &instance.Journal{
		Action:            instance.ActionUpgrade,
		From:              plan.Current,
		To:                target.Version,
		Phase:             instance.PhaseApply,
		Log:               r.Opts.LogPath,
		Backup:            backupPath,
		Applied:           true,
		MariaDB:           r.mariadbMark(ctx),
		OneWay:            plan.OneWay,
		Database:          plan.Database,
		RestoreDB:         r.Opts.RestoreDB,
		Files:             files,
		ImagesBefore:      before,
		ImagesAfter:       after,
		ComposeFileBefore: r.Inst.Env[composeFileKey],
		Pins:              pinsOf(plan.Images),
		Ignored:           plan.Ignored,
		Services:          services,
		Containers:        containers,
	}
	// The journal is the first change. An interrupt that came before it,
	// while the release was staged for instance, stops the run here:
	// nothing of the installation has changed yet, so there is nothing to
	// lay and roll back. Whoever owns the interrupt answers (begin), so
	// what it said the interrupt does is what the run does.
	if !r.begin(ctx) {
		r.fail(StepApply, "cancelled")
		r.dropStaged(plan)
		return r.untouched(plan, context.Canceled)
	}
	if err := r.Inst.SaveJournal(j); err != nil {
		r.fail(StepApply, "journal: "+err.Error())
		return r.untouched(plan, fmt.Errorf("the journal could not be written: %w", err))
	}
	fail := func(step string, cause error) error {
		r.failStep(step, cause)
		return r.failed(ctx, state, j, cause)
	}
	if err := r.lay(dir, files, state, want); err != nil {
		var conflict *release.ConflictError
		if errors.As(err, &conflict) {
			return r.notLaid(plan, err)
		}
		return fail(StepApply, err)
	}
	r.done(StepApply, fmt.Sprintf("%d files", len(files)))

	r.start(StepRestart, "docker compose up")
	budget := r.dbBudget(plan.MariaDBUpgrade)
	if err := r.restart(ctx, j, plan.MariaDBImageChanges, budget); err != nil {
		return fail(StepRestart, err)
	}
	r.done(StepRestart, "services restarted")

	r.start(StepVerify, "containers, site, admin")
	if err := r.verify(ctx, plan.Ignored, budget); err != nil {
		return fail(StepVerify, err)
	}
	if err := r.checkPins(ctx, plan); err != nil {
		return fail(StepVerify, err)
	}
	j.Phase = instance.PhaseRecord
	journaled := true
	if err := r.Inst.SaveJournal(j); err != nil {
		journaled = false
		r.log("the journal could not be updated: " + err.Error())
	}
	r.done(StepVerify, "healthy")
	return r.record(state, j, journaled)
}

// backupBefore takes the backup of the database and the configuration an
// upgrade starts with, and keeps the newest ones.
func (r *Runner) backupBefore(ctx context.Context, state *instance.State, plan *Plan) (string, error) {
	if r.Opts.SkipBackup {
		r.start(StepBackup, "skipped (--skip-backup)")
		r.done(StepBackup, "skipped")
		return "", nil
	}
	r.start(StepBackup, "database and configuration")
	result, err := backup.Create(ctx, r.Inst.BackupDir(), plan.Current, r.mariadbContainer(), r.Inst.EnvPath, r.statePath(), r.log, backup.WithKVSVersion(r.Inst.KVSVersion()))
	if err != nil {
		r.failStep(StepBackup, err)
		return "", r.untouched(plan, fmt.Errorf("backup: %w", err))
	}
	// The archive a manual rollback of the installed version replays stays
	// too: this upgrade may still fail and leave that version in place.
	r.prune(result.Path, state.UpgradeBackup)
	r.done(StepBackup, fmt.Sprintf("%s (%s, %s)", relPath(r.Inst.Root, result.Path), humanBytes(result.Size), result.Duration.Round(time.Second)))
	return result.Path, nil
}

// notLaid ends a run whose release files cannot take their place: Sync
// found what stands in their way before it changed anything, so there is
// nothing to roll back, and laying the files of the installed version back
// would only meet the same obstacle. The journal goes, and the error says
// what to fix.
func (r *Runner) notLaid(plan *Plan, err error) error {
	r.fail(StepApply, errLine(err))
	r.dropJournal()
	r.dropStaged(plan)
	return r.untouched(plan, err)
}

// dropStaged removes the files a re-apply staged, for a run that ends
// before its first change: a re-apply leaves no staged release behind.
func (r *Runner) dropStaged(plan *Plan) {
	if !plan.Reapply {
		return
	}
	if err := os.RemoveAll(r.stagingDir(plan.Target.Version)); err != nil {
		r.log("the staged files of the re-apply could not be removed: " + err.Error())
	}
}

// begin reports whether the run may make its first change: no once the
// operation is interrupted. A reporter that is a Gate answers, and its yes
// stands even when the interrupt comes right after it: the interrupt then
// says that what the run changes is rolled back, and it is.
func (r *Runner) begin(ctx context.Context) bool {
	if g, ok := r.Reporter.(Gate); ok {
		return g.Begin()
	}
	return ctx.Err() == nil
}

// untouched is the error of a run that failed before its first change.
func (r *Runner) untouched(plan *Plan, cause error) error {
	if errors.Is(cause, context.Canceled) {
		return fmt.Errorf("upgrade to %s cancelled: nothing was changed, the stack is still on %s", plan.Target.Version, plan.installed())
	}
	return fmt.Errorf("upgrade to %s failed: %w; nothing was changed, the stack is still on %s", plan.Target.Version, cause, plan.installed())
}

// stage downloads and unpacks the bundle, and keeps the files of the
// running version for a rollback; nothing of the installation changes yet.
// A re-apply unpacks into a directory of its own: the release directory of
// the installed version holds the files a rollback of it lays back.
func (r *Runner) stage(ctx context.Context, state *instance.State, plan *Plan) (dir string, files []string, err error) {
	target := plan.Target
	archive := filepath.Join(r.Inst.StateDir(), "downloads", fmt.Sprintf("kvs-stack-%s.tar.gz", target.Version))
	r.log("downloading " + target.Bundle.URL)
	// The download stops at the size the signed manifest gives, or at the
	// bound DownloadSized keeps when it gives none: a replaced asset must
	// not fill the disk the backups share before its checksum refuses it.
	if err := release.DownloadSized(ctx, target.Bundle.URL, target.Bundle.SHA256, target.Bundle.Size, archive, nil); err != nil {
		return "", nil, fmt.Errorf("the bundle of %s: %w", target.Version, err)
	}
	dir = r.releaseDir(target.Version)
	if plan.Reapply {
		dir = r.stagingDir(target.Version)
	}
	if err := os.RemoveAll(dir); err != nil {
		return "", nil, err
	}
	if files, err = release.Extract(archive, dir); err != nil {
		return "", nil, err
	}
	r.log(fmt.Sprintf("bundle verified, %d files", len(files)))
	if err := r.keepFiles(plan.Current, state.Files, "keeping the files of "+plan.installed()+" for a rollback"); err != nil {
		return "", nil, fmt.Errorf("keep the files of %s: %w", plan.installed(), err)
	}
	return dir, files, nil
}

// lay puts the staged release over the installation: its files, the
// compose file list, the settings its .env.example adds and the variant
// settings.
func (r *Runner) lay(dir string, files []string, state *instance.State, want map[string]string) error {
	if err := release.Sync(dir, r.Inst.Root, files, state.Files); err != nil {
		return fmt.Errorf("lay the release files: %w", err)
	}
	if err := r.setComposeFiles(files); err != nil {
		return fmt.Errorf("COMPOSE_FILE: %w", err)
	}
	if err := r.mergeEnv(dir); err != nil {
		return err
	}
	if err := r.setImageEnv(want, state.Images); err != nil {
		return fmt.Errorf(".env: %w", err)
	}
	return nil
}

// restart brings the stack up on the laid files. Compose reads the project
// first, which touches no container, so an error in the files or the .env
// fails before anything moved. The journal then records compose as
// started, right before it starts: a run killed in between is treated as
// one whose containers may have changed, which is the safe side. The
// containers of the services the release dropped go first, so none of
// them keeps running the code of the version left. When the mariadb image
// changes, MariaDB comes up alone first and the other services once it is
// healthy: a long upgrade of its system tables would otherwise trip the
// health dependencies of the services that need it.
func (r *Runner) restart(ctx context.Context, j *instance.Journal, mariadbFirst bool, budget time.Duration) error {
	if err := context.Cause(ctx); err != nil {
		return err
	}
	if err := dockerx.ComposeConfigCheck(ctx, r.Inst.DockerDir); err != nil {
		return fmt.Errorf("compose cannot read the project, no container was touched: %w", err)
	}
	mark := r.mariadbMark(ctx)
	j.Phase, j.ComposeStarted, j.MariaDB = instance.PhaseRestart, true, mark
	if err := r.Inst.SaveJournal(j); err != nil {
		j.ComposeStarted = false
		return fmt.Errorf("the journal could not be updated, compose was not started: %w", err)
	}
	removed, err := r.removeLeftovers(ctx, j, false)
	if err != nil {
		return err
	}
	started, err := r.composeUp(ctx, mariadbFirst, budget)
	j.ComposeStarted = started || removed
	if err != nil {
		return err
	}
	j.MariaDBRecreated = r.mariadbChanged(ctx, mark)
	if j.MariaDBRecreated {
		r.log("the mariadb container was recreated")
	} else {
		r.log("the mariadb container was left as it was")
	}
	j.Phase = instance.PhaseVerify
	if err := r.Inst.SaveJournal(j); err != nil {
		r.log("the journal could not be updated, the run goes on: " + err.Error())
	}
	return nil
}

// composeUp runs docker compose up -d, MariaDB alone first when
// mariadbFirst is set, and waits for it within budget before the rest.
// started reports whether compose ran at all.
func (r *Runner) composeUp(ctx context.Context, mariadbFirst bool, budget time.Duration) (started bool, err error) {
	if mariadbFirst {
		r.log(fmt.Sprintf("starting MariaDB alone first, the other services follow once it is healthy; MariaDB has %s to be ready (--db-timeout)", shortDuration(budget)))
		started, err = dockerx.ComposeStarted(ctx, r.Inst.DockerDir, r.log, "up", "-d", mariadbService)
		if err == nil {
			err = r.waitDatabase(ctx, budget)
		}
		if err != nil {
			return started, err
		}
	}
	all, err := dockerx.ComposeStarted(ctx, r.Inst.DockerDir, r.log, "up", "-d")
	return started || all, err
}

// mariadbMark is the mariadb container as it is now, the life a later look
// compares with. No container gives an empty mark.
func (r *Runner) mariadbMark(ctx context.Context) instance.ContainerMark {
	c, err := r.Docker.Container(ctx, r.mariadbContainer())
	if err != nil {
		return instance.ContainerMark{}
	}
	return instance.ContainerMark{ID: c.ID, Started: c.Started}
}

// mariadbChanged reports whether the mariadb container is another one than
// mark: compose recreates the container whenever its image changes, so a
// new ID is a new server that may have opened the data files. The same
// container started again, as a host reboot does, runs the same image and
// counts as unchanged: its data files must not be moved. A container that
// cannot be inspected counts as changed, which makes a rollback assume the
// worst.
func (r *Runner) mariadbChanged(ctx context.Context, mark instance.ContainerMark) bool {
	c, err := r.Docker.Container(ctx, r.mariadbContainer())
	if err != nil {
		return true
	}
	return c.ID != mark.ID
}

// dbBudget is how long MariaDB alone may take to be ready: --db-timeout,
// or 30 minutes when its series changes, which upgrades its system tables,
// and 10 minutes otherwise.
func (r *Runner) dbBudget(seriesChange bool) time.Duration {
	switch {
	case r.Opts.DBTimeout > 0:
		return r.Opts.DBTimeout
	case seriesChange:
		return 30 * time.Minute
	default:
		return 10 * time.Minute
	}
}

// record writes a run that passed its verification into the state, at the
// end of Run or from Recover, and removes its journal. journaled says the
// journal on disk is in the record phase, which is what lets recover finish
// the job when the state cannot be written.
func (r *Runner) record(state *instance.State, j *instance.Journal, journaled bool) error {
	if j.Action == instance.ActionRollback {
		return r.recordRollback(state, j, journaled)
	}
	reapply := j.From == j.To
	// A re-apply over the checkout adopt recorded lays the files of the
	// release where the checkout was: the checkout is the way back, and
	// its files move out of the way of the release ones.
	overCheckout := reapply && !sameFiles(state.Files, j.Files)
	if reapply {
		if overCheckout {
			if err := r.keepCheckout(j.To, state.Files); err != nil {
				return r.notRecorded(state, j, journaled, err)
			}
		}
		if err := r.promote(j.To); err != nil {
			return r.notRecorded(state, j, journaled, err)
		}
	}
	if state.ReleaseImages == nil {
		state.ReleaseImages = map[string][]string{}
	}
	pins := j.Pins
	if reapply {
		// The images of the variants the version ran before stay its own
		// until the version is dropped, which is when clean removes them.
		pins = union(state.ReleaseImages[j.To], j.Pins)
	}
	state.ReleaseImages[j.To] = pins
	// The settings the run wrote, and what .env held for each of them
	// before: a manual rollback puts those back, MARIADB_VERSION of a
	// series change, the PHP series and COMPOSE_FILE included.
	before := withComposeFile(j.ImagesBefore, j.ComposeFileBefore)
	if reapply && state.Previous != "" && !overCheckout {
		// The version before the re-applied one stays the way back, its
		// files and images kept and left to clean. A setting the record of
		// the installed version holds and the way back does not is one the
		// version before ran without, which a rollback removes: it stays
		// out, the image pins of a release laid over a checkout above all.
		// A setting the re-apply wrote that neither record holds, the
		// MariaDB series of a series change, had until the re-apply the
		// value the version before ran with, which the way back takes;
		// COMPOSE_FILE stays unknown when it was not recorded.
		for key, value := range before {
			_, back := state.PreviousImages[key]
			_, written := state.Images[key]
			if back || written || key == composeFileKey {
				continue
			}
			if state.PreviousImages == nil {
				state.PreviousImages = map[string]string{}
			}
			state.PreviousImages[key] = value
		}
		// The way back needs what either change needs: a dump replayed
		// when one of them changes the database. The archive stays the one
		// taken before the version before was left, unless that version
		// would have needed none: the newest archive then fits it.
		if state.Database != migrates && !state.OneWay && j.Backup != "" {
			state.UpgradeBackup = j.Backup
		}
		if j.Database == migrates {
			state.Database = migrates
		}
		state.OneWay = state.OneWay || j.OneWay
	} else {
		state.Previous, state.PreviousFiles = j.From, state.Files
		state.PreviousImages = before
		// What a later rollback has to do with the database: what the
		// releases installed declared, or "migrates" when MariaDB rewrote
		// its data files, and the exact archive to replay.
		state.Database, state.OneWay = j.Database, j.OneWay
		state.UpgradeBackup = j.Backup
	}
	state.Current, state.Files = j.To, j.Files
	state.Images = withComposeFile(j.ImagesAfter, r.Inst.Env[composeFileKey])
	if sums, err := release.Checksums(r.Inst.Root, j.Files); err != nil {
		r.log("the release files could not be checksummed, local changes will not be detected: " + err.Error())
		state.Checksums = nil
	} else {
		state.Checksums = sums
	}
	note := "from " + j.From
	switch {
	case overCheckout:
		note = "applied over the checkout adopt recorded"
	case reapply:
		note = "applied again with other images"
	}
	state.History = append(state.History, instance.Entry{Version: j.To, Action: instance.ActionUpgrade, Date: j.Started, Note: note})
	if err := r.Inst.SaveState(state); err != nil {
		return r.notRecorded(state, j, journaled, err)
	}
	r.finish(j.To)
	r.dropCheckouts(state)
	return nil
}

// notRecorded is the error of a run that changed the stack for good but
// whose record could not be written: exit 8, and recover writes it.
func (r *Runner) notRecorded(state *instance.State, j *instance.Journal, journaled bool, err error) error {
	what := fmt.Sprintf("%s is installed and the site is healthy", state.Label(j.To))
	if j.Action == instance.ActionRollback {
		what = fmt.Sprintf("%s is back and the site is healthy", state.Label(j.To))
	}
	next := "run 'kvsctl recover' to record it"
	if !journaled {
		next = "the journal could not be updated either, so 'kvsctl recover' will take the run for one cut short during its verification and roll it back"
	}
	return &failure{
		msg:   fmt.Sprintf("%s, but its record in %s could not be written (%v): %s%s", what, r.Inst.StateDir(), err, next, r.logNote()),
		cause: err,
		kind:  ErrNotRecorded,
	}
}

// finish closes a run whose end is in the state: .env names the version
// installed, and the journal goes.
func (r *Runner) finish(version string) {
	if err := r.Inst.SetEnv("KVS_STACK_VERSION", version); err != nil {
		r.log("KVS_STACK_VERSION could not be written to .env: " + err.Error())
	}
	if err := r.Inst.RemoveJournal(); err != nil {
		r.log("the journal could not be removed; 'kvsctl recover' sees the run is recorded and removes it: " + err.Error())
	}
}

// noJournal refuses to start a run while the journal of an interrupted one
// is there: what it says that run did would be lost.
func (r *Runner) noJournal(state *instance.State) error {
	j, err := r.Inst.LoadJournal()
	if err != nil {
		return err
	}
	if j != nil {
		return j.Interrupted(state)
	}
	return nil
}

// announceReleases logs what the operator should know before saying yes:
// the notes of every release the upgrade installs, skipped ones included,
// the highlights of the target, and what any of them does to the database.
func (r *Runner) announceReleases(plan *Plan) {
	var migrating []string
	for _, rel := range plan.Releases {
		if rel.Notes != "" {
			r.log(rel.Version + ": " + rel.Notes)
		}
		if rel.Database == migrates {
			migrating = append(migrating, rel.Version)
		}
	}
	for _, h := range plan.Target.Highlights {
		r.log("  - " + h)
	}
	if plan.Target.NotesURL != "" {
		r.log("release notes: " + plan.Target.NotesURL)
	}
	if plan.MariaDBUpgrade {
		migrating = append(migrating, fmt.Sprintf("MariaDB %s to %s", plan.RunningMariaDBSeries, plan.MariaDBSeries))
	}
	if len(migrating) > 0 {
		r.log("the database changes (" + strings.Join(migrating, ", ") + "): a rollback replays the backup")
	}
	if plan.OneWay {
		r.log("this upgrade is one way: a rollback recreates the MariaDB data directory and replays the backup")
	}
	if len(plan.Ignored) > 0 {
		r.log("accepted as they are (--allow-unhealthy): " + strings.Join(plan.Unhealthy, "; "))
	}
}

// announceImages tells the reporter every service of the release with the
// version it runs and the one it will run, before the question is asked:
// the ones already on the machine get a note instead of a download.
func (r *Runner) announceImages(plan *Plan) {
	total := dockerx.Progress{Total: plan.Bytes}
	for _, item := range plan.Services {
		switch {
		case item.Unchanged:
			r.event(imageEvent(item, dockerx.Progress{Done: true}, total, "unchanged"))
		case item.OnDisk:
			r.event(imageEvent(item, dockerx.Progress{Done: true}, total, "already on this machine"))
		case !item.Active:
			r.event(imageEvent(item, dockerx.Progress{Done: true}, total, "not pulled, the service is not active"))
		default:
			r.event(imageEvent(item, dockerx.Progress{Total: item.Bytes}, total, ""))
		}
	}
}

// imageEvent is the progress event of one image of the plan, named by its
// service and its versions.
func imageEvent(item PlanImage, p, total dockerx.Progress, note string) Event {
	return Event{
		Kind:     KindImage,
		Step:     StepPull,
		Message:  note,
		Image:    item.Ref,
		Service:  item.Service,
		From:     ImageVersion(item.Running),
		To:       ImageVersion(item.Ref),
		Progress: p,
		Total:    total,
	}
}

// pull downloads the images of the active services the engine does not
// hold, each by its digest. The site keeps running meanwhile. An image the
// container of its service already runs, which the engine holds under
// another name, is pulled too, so compose finds it under the name the
// release gives it, but it has no layer to download and nothing to show.
func (r *Runner) pull(ctx context.Context, plan *Plan) error {
	total := dockerx.Progress{Total: plan.Bytes}
	done := map[string]int64{}
	for _, img := range plan.ImagesToPull {
		if img.Unchanged {
			r.log(fmt.Sprintf("%s runs this image already, as %s: pulled by its digest as %s, it downloads no layer", img.Service, img.Running, img.Ref))
			if err := r.Docker.Pull(ctx, img.Ref, img.Digest, img.Bytes, nil); err != nil {
				return err
			}
			continue
		}
		key := img.Ref + "@" + img.Digest
		err := r.Docker.Pull(ctx, img.Ref, img.Digest, img.Bytes, func(p dockerx.Progress) {
			done[key] = p.Current
			total.Current = 0
			for _, n := range done {
				total.Current += n
			}
			r.event(imageEvent(img, p, total, ""))
		})
		if err != nil {
			return err
		}
	}
	total.Current, total.Done = total.Total, true
	r.event(Event{Kind: KindImages, Step: StepPull, Total: total})
	return nil
}

// prune keeps the KeepBackups newest backups, the one this run took among
// them, and every archive named in keep whatever its age, and removes the
// others: the rule of kvsctl backup --keep, so the flag means the same in
// both commands. 0 or below keeps only the archives named.
func (r *Runner) prune(keep ...string) {
	n := max(r.Opts.KeepBackups, 0)
	removed, err := backup.Prune(r.Inst.BackupDir(), n, keep...)
	switch {
	case err != nil:
		r.log("the old backups could not be pruned: " + err.Error())
	case len(removed) > 0:
		names := make([]string, 0, len(removed))
		for _, p := range removed {
			names = append(names, filepath.Base(p))
		}
		r.log(fmt.Sprintf("removed %d older backups (--keep %d; this one and the one a rollback replays always stay): %s", len(removed), n, strings.Join(names, ", ")))
	}
}

// variantEnv is what a run writes to .env: the variant images and, on a
// MariaDB series change, the series itself.
func variantEnv(plan *Plan) map[string]string {
	env := copyImages(plan.ImageEnv)
	if plan.MariaDBUpgrade {
		if env == nil {
			env = map[string]string{}
		}
		env[mariadbVersionKey] = plan.MariaDBSeries
	}
	return env
}

// envBefore reads what .env holds now for every key of the maps given,
// which is what a rollback puts back. A key .env does not hold is left out,
// and a rollback then removes it. COMPOSE_FILE has a record of its own.
func (r *Runner) envBefore(sets ...map[string]string) map[string]string {
	out := map[string]string{}
	for _, set := range sets {
		for key := range set {
			if value, ok := r.Inst.Env[key]; ok && key != composeFileKey {
				out[key] = value
			}
		}
	}
	return copyImages(out)
}

// runSettings are the settings an upgrade records in its journal: after,
// what it writes to .env (the variant images, the series of a MariaDB
// series change) and the PHP series it installs; before, what each of them
// was before the run, which a rollback puts back. The variant settings are
// read from .env. The PHP series is the one the stack runs, which .env no
// longer says when the operator changed it to ask for the run: the one the
// state recorded, else the series of the images the installed release
// publishes for it, else what .env says.
func (r *Runner) runSettings(state *instance.State, plan *Plan, want map[string]string) (before, after map[string]string) {
	before = r.envBefore(want, imageKeys(state.Images))
	if before == nil {
		before = map[string]string{}
	}
	after = maps.Clone(want)
	if after == nil {
		after = map[string]string{}
	}
	installed := installedPHP(state, plan)
	for _, key := range phpKeys {
		value, ok := r.Inst.Env[key]
		if !ok {
			continue
		}
		after[key] = value
		switch ran, recorded := state.Images[key]; {
		case recorded:
			before[key] = ran
		case installed != "":
			before[key] = installed
		default:
			before[key] = value
		}
	}
	return copyImages(before), copyImages(after)
}

// installedPHP is the PHP series of the images the state records for the
// installed release, as its manifest entry publishes them; "" when the
// manifest does not tell, for a checkout or a release gone from it.
func installedPHP(state *instance.State, plan *Plan) string {
	if plan.Manifest == nil || len(state.Images) == 0 {
		return ""
	}
	rel := plan.Manifest.Find(plan.Current)
	if rel == nil {
		return ""
	}
	for _, series := range slices.Sorted(maps.Keys(rel.Variants[manifest.VariantPHP])) {
		images := rel.Variants[manifest.VariantPHP][series]
		match := len(images) > 0
		for _, img := range images {
			if state.Images[ImageEnvKey(img.Service)] != img.Ref+"@"+img.Digest {
				match = false
			}
		}
		if match {
			return series
		}
	}
	return ""
}

// withComposeFile is a copy of a set of settings with the COMPOSE_FILE a
// version ran with, "" for none.
func withComposeFile(settings map[string]string, composeFile string) map[string]string {
	out := maps.Clone(settings)
	if out == nil {
		out = map[string]string{}
	}
	out[composeFileKey] = composeFile
	return out
}

// composeView is the stack as compose runs it when a run begins: the active
// services and the container of each service, by ID. Either is nil when it
// cannot be read, which leaves out what it serves. A read an interrupt cut
// short is no fault of the stack and goes unsaid: the run then stops before
// its journal, which the view is for, and says why.
func (r *Runner) composeView(ctx context.Context) ([]string, map[string]string) {
	services, err := dockerx.ActiveServices(ctx, r.Inst.DockerDir)
	if err != nil {
		if ctx.Err() == nil {
			r.log("the services of the stack could not be listed: " + firstLine(err.Error()))
		}
		services = nil
	}
	containers, err := r.serviceContainers(ctx)
	if err != nil && ctx.Err() == nil {
		r.log("the containers of the stack could not be read: " + firstLine(err.Error()))
	}
	return services, containers
}

// removeLeftovers stops and removes the containers of the services compose
// no longer runs that the run answers for. A run that lays the files of
// another version removes the ones of the services it began with that
// those files drop. undo, which lays back the files a run began with,
// removes the ones of the services that run added: neither running nor
// with a container when it began. The container of any other service
// compose does not run, a profile turned off by hand for instance, is left
// alone, and so are the one-off containers of compose run, which
// --remove-orphans would remove with them. It reports whether it removed
// any.
func (r *Runner) removeLeftovers(ctx context.Context, j *instance.Journal, undo bool) (bool, error) {
	if j.Services == nil {
		return false, nil
	}
	active, err := dockerx.ActiveServices(ctx, r.Inst.DockerDir)
	if err != nil {
		return false, fmt.Errorf("the services of the stack could not be listed: %w", err)
	}
	containers, err := r.serviceContainers(ctx)
	if err != nil {
		return false, fmt.Errorf("the containers of the stack could not be read: %w", err)
	}
	var gone []string
	for service := range containers {
		if slices.Contains(active, service) {
			continue
		}
		began := slices.Contains(j.Services, service)
		_, had := j.Containers[service]
		if (undo && !began && !had) || (!undo && began) {
			gone = append(gone, service)
		}
	}
	if len(gone) == 0 {
		return false, nil
	}
	slices.Sort(gone)
	why := "the files laid no longer run them"
	if undo {
		why = "the run undone added them"
	}
	r.log(fmt.Sprintf("removing the containers of %s: %s", strings.Join(gone, ", "), why))
	if err := dockerx.Compose(ctx, r.Inst.DockerDir, r.log, append([]string{"rm", "--stop", "--force"}, gone...)...); err != nil {
		return true, err
	}
	return true, nil
}

// serviceContainers maps every service that has a container to its ID, one
// off containers of compose run aside.
func (r *Runner) serviceContainers(ctx context.Context) (map[string]string, error) {
	states, err := r.Docker.Containers(ctx, r.Inst.ProjectName())
	if err != nil {
		return nil, err
	}
	out := map[string]string{}
	for _, s := range states {
		if !s.OneShot && s.Service != "" {
			out[s.Service] = s.ID
		}
	}
	return out, nil
}

// setImageEnv writes the variant settings of the release into .env and
// drops the image keys of the release being left that the new one does
// not set, so the override never reads a stale value.
func (r *Runner) setImageEnv(want, old map[string]string) error {
	for _, key := range slices.Sorted(maps.Keys(old)) {
		if _, ok := want[key]; ok || !isImageKey(key) {
			continue
		}
		if _, ok := r.Inst.Env[key]; !ok {
			continue
		}
		if err := r.Inst.UnsetEnv(key); err != nil {
			return err
		}
		r.log("removed " + key + " from .env")
	}
	for _, key := range slices.Sorted(maps.Keys(want)) {
		if value, ok := r.Inst.Env[key]; ok && value == want[key] {
			continue
		}
		if err := r.Inst.SetEnv(key, want[key]); err != nil {
			return err
		}
		r.log(key + "=" + want[key])
	}
	return nil
}

// restoreEnv puts .env back the way before holds it, for every key of
// before and after: the value it had, or no line at all for a key that was
// not there.
func (r *Runner) restoreEnv(before, after map[string]string) error {
	keys := map[string]bool{}
	for key := range before {
		keys[key] = true
	}
	for key := range after {
		keys[key] = true
	}
	// COMPOSE_FILE has its own way back, setComposeFile.
	delete(keys, composeFileKey)
	for _, key := range slices.Sorted(maps.Keys(keys)) {
		value, had := before[key]
		current, has := r.Inst.Env[key]
		switch {
		case had && (!has || current != value):
			if err := r.Inst.SetEnv(key, value); err != nil {
				return err
			}
			r.log(key + "=" + value)
		case !had && has:
			if err := r.Inst.UnsetEnv(key); err != nil {
				return err
			}
			r.log("removed " + key + " from .env")
		}
	}
	return nil
}

// isImageKey reports whether a .env key carries a variant image,
// KVS_<SERVICE>_IMAGE.
func isImageKey(key string) bool {
	return strings.HasPrefix(key, "KVS_") && strings.HasSuffix(key, "_IMAGE")
}

// imageKeys keeps the variant images of a set of .env values, what the
// state records as the images of a version.
func imageKeys(env map[string]string) map[string]string {
	out := map[string]string{}
	for key, value := range env {
		if isImageKey(key) {
			out[key] = value
		}
	}
	return copyImages(out)
}

// mergeEnv adds the settings the release introduced to the live .env,
// without ever changing a value the operator set.
func (r *Runner) mergeEnv(dir string) error {
	example := filepath.Join(dir, "docker", ".env.example")
	if _, err := os.Stat(example); err != nil {
		return nil
	}
	added, err := r.Inst.MergeEnv(example)
	if err != nil {
		return fmt.Errorf(".env merge: %w", err)
	}
	if len(added) == 0 {
		r.log("no new settings")
		return nil
	}
	r.log(fmt.Sprintf("added %d new settings: %s", len(added), strings.Join(added, ", ")))
	return nil
}

// setComposeFiles writes the compose file list of a release into
// COMPOSE_FILE: the release override last when the release ships one, and
// the operator's override before it whenever it exists, even when it was
// created after kvsctl first wrote the list.
//
// An install with one site has no COMPOSE_FILE at all: setup.sh removes the
// key, and compose then loads docker-compose.yml plus, when it exists, the
// operator's override. Writing the key stops that pickup, which is why
// every list kvsctl writes names the override itself.
func (r *Runner) setComposeFiles(files []string) error {
	value := r.composeFilesFor(files)
	if value == r.Inst.Env[composeFileKey] {
		return nil
	}
	r.log("COMPOSE_FILE=" + value)
	return r.Inst.SetEnv(composeFileKey, value)
}

// composeFilesFor is the list setComposeFiles writes for files.
func (r *Runner) composeFilesFor(files []string) string {
	ships := slices.Contains(files, "docker/"+ReleaseOverride)
	sep := r.composeSeparator()
	var parts []string
	if current := r.Inst.Env[composeFileKey]; current == "" {
		parts = append(parts, "docker-compose.yml")
	} else {
		for _, p := range strings.Split(current, sep) {
			if p != "" && p != ReleaseOverride {
				parts = append(parts, p)
			}
		}
	}
	if override := DefaultOverride(r.Inst.DockerDir); override != "" && !slices.ContainsFunc(parts, IsOverride) {
		parts = append(parts, override)
	}
	if ships {
		parts = append(parts, ReleaseOverride)
	}
	return strings.Join(parts, sep)
}

// withOverride is a COMPOSE_FILE a version ran with, as a rollback writes
// it back: with the operator's override, when one exists that it does not
// name, before the release override, so that an override created since
// keeps being loaded. No list stays no list: compose then finds the
// override itself.
func (r *Runner) withOverride(value string) string {
	override := DefaultOverride(r.Inst.DockerDir)
	if value == "" || override == "" {
		return value
	}
	sep := r.composeSeparator()
	parts := strings.Split(value, sep)
	if slices.ContainsFunc(parts, IsOverride) {
		return value
	}
	if i := slices.Index(parts, ReleaseOverride); i >= 0 {
		parts = slices.Insert(parts, i, override)
	} else {
		parts = append(parts, override)
	}
	return strings.Join(parts, sep)
}

// composeSeparator is what separates the files of COMPOSE_FILE.
func (r *Runner) composeSeparator() string {
	if sep := r.Inst.Env["COMPOSE_PATH_SEPARATOR"]; sep != "" {
		return sep
	}
	return ":"
}

// overrideFiles are the names of the operator's override compose loads next
// to docker-compose.yml while COMPOSE_FILE is unset, in the order it looks
// for them: it loads the first one it finds, and only that one.
var overrideFiles = []string{"compose.override.yml", "compose.override.yaml", "docker-compose.override.yml", "docker-compose.override.yaml"}

// DefaultOverride is the operator's override compose loads in dir while
// COMPOSE_FILE is unset, "" when there is none.
func DefaultOverride(dir string) string {
	for _, name := range overrideFiles {
		if info, err := os.Stat(filepath.Join(dir, name)); err == nil && !info.IsDir() {
			return name
		}
	}
	return ""
}

// IsOverride reports whether an entry of COMPOSE_FILE names an override of
// the operator, by any name compose gives one and by any path. A list that
// names one is the operator's choice: kvsctl adds no other override to it.
func IsOverride(entry string) bool {
	return slices.Contains(overrideFiles, filepath.Base(entry))
}

// setComposeFile puts COMPOSE_FILE back to value, removing the key when
// value is empty: exactly what .env held before a run.
func (r *Runner) setComposeFile(value string) error {
	current, has := r.Inst.Env["COMPOSE_FILE"]
	switch {
	case value == "" && has:
		r.log("removed COMPOSE_FILE from .env")
		return r.Inst.UnsetEnv("COMPOSE_FILE")
	case value != "" && current != value:
		r.log("COMPOSE_FILE=" + value)
		return r.Inst.SetEnv("COMPOSE_FILE", value)
	}
	return nil
}

// releaseDir keeps the files of one version, what a rollback lays back.
func (r *Runner) releaseDir(version string) string {
	return filepath.Join(r.Inst.ReleasesDir(), version)
}

// checkoutDir keeps the files of the checkout adopt recorded at a version,
// once a release of that same version took its release directory.
func (r *Runner) checkoutDir(version string) string {
	return filepath.Join(r.Inst.StateDir(), "checkout", version)
}

// keptDir is the directory that keeps the files of a version of the state,
// files being the list the state records for it: its release directory or,
// when that holds the release laid over the checkout adopt recorded at the
// same version, the checkout directory. A version whose files are kept in
// neither gets its release directory.
func (r *Runner) keptDir(version string, files []string) string {
	rel := r.releaseDir(version)
	if holds(rel, files) {
		return rel
	}
	if co := r.checkoutDir(version); holds(co, files) {
		return co
	}
	return rel
}

// keepFiles makes sure the installed files of a version are kept for a
// rollback, and keeps them in its release directory, or in the checkout
// directory when the release directory holds other files of the version.
func (r *Runner) keepFiles(version string, files []string, why string) error {
	dir := r.keptDir(version, files)
	if holds(dir, files) {
		return nil
	}
	switch _, err := os.Stat(dir); {
	case err == nil:
		dir = r.checkoutDir(version)
		if err := os.RemoveAll(dir); err != nil {
			return err
		}
	case !errors.Is(err, os.ErrNotExist):
		return err
	}
	r.log(why)
	return release.Snapshot(r.Inst.Root, dir, files)
}

// keepCheckout moves the files of the checkout adopt recorded out of the
// release directory of their version, before the release re-applied over
// them takes it: they are what a rollback returns to. It can run again:
// once they moved, there is nothing left to do.
func (r *Runner) keepCheckout(version string, files []string) error {
	rel, co := r.releaseDir(version), r.checkoutDir(version)
	if !holds(rel, files) {
		return nil
	}
	if err := os.RemoveAll(co); err != nil {
		return err
	}
	if err := os.MkdirAll(filepath.Dir(co), 0o750); err != nil {
		return err
	}
	if err := os.Rename(rel, co); err != nil {
		return err
	}
	for _, dir := range []string{filepath.Dir(rel), filepath.Dir(co)} {
		if err := syncDir(dir); err != nil {
			return err
		}
	}
	return nil
}

// dropCheckouts removes the checkout directories no version of the state
// is kept in any more, once a run replaced it in both slots.
func (r *Runner) dropCheckouts(state *instance.State) {
	parent := filepath.Dir(r.checkoutDir("x"))
	entries, err := os.ReadDir(parent)
	if err != nil {
		return
	}
	for _, e := range entries {
		version := e.Name()
		if r.keptDir(state.Current, state.Files) == filepath.Join(parent, version) || r.keptDir(state.Previous, state.PreviousFiles) == filepath.Join(parent, version) {
			continue
		}
		if err := os.RemoveAll(filepath.Join(parent, version)); err != nil {
			r.log("the files of a checkout no version uses any more could not be removed: " + err.Error())
		}
	}
}

// holds reports whether dir holds exactly files, relative to it: the files
// a version of the state lists, which tells the checkout adopt recorded
// from the release of the same version.
func holds(dir string, files []string) bool {
	if len(files) == 0 {
		return false
	}
	found, err := listFiles(dir)
	return err == nil && sameFiles(found, files)
}

// sameFiles reports whether two lists of release files name the same files.
func sameFiles(a, b []string) bool {
	return slices.Equal(slices.Sorted(slices.Values(a)), slices.Sorted(slices.Values(b)))
}

// stagingDir is where a re-apply unpacks the release it applies again,
// until it is recorded.
func (r *Runner) stagingDir(version string) string {
	return filepath.Join(r.Inst.StateDir(), "staging", version)
}

// promote moves the files a re-apply staged into the release directory of
// their version, once the re-apply passed its verification. It can run
// again after a crash: once the files moved, there is nothing left to do.
func (r *Runner) promote(version string) error {
	staged, dest := r.stagingDir(version), r.releaseDir(version)
	if _, err := os.Stat(staged); errors.Is(err, os.ErrNotExist) {
		return nil
	} else if err != nil {
		return err
	}
	if err := os.RemoveAll(dest); err != nil {
		return err
	}
	if err := os.Rename(staged, dest); err != nil {
		return err
	}
	// Both directories reach the disk before the state names the files:
	// a rename lost in a power cut would leave the release directory
	// empty behind a record that says it holds them.
	for _, dir := range []string{filepath.Dir(staged), filepath.Dir(dest)} {
		if err := syncDir(dir); err != nil {
			return err
		}
	}
	return nil
}

// syncDir flushes a directory, so the names it holds survive a power cut.
func syncDir(dir string) error {
	f, err := os.Open(dir)
	if err != nil {
		return err
	}
	defer f.Close()
	return f.Sync()
}

// statePath is the state file, which a backup archives.
func (r *Runner) statePath() string { return filepath.Join(r.Inst.StateDir(), "state.json") }

// union is a followed by the entries of b it lacks.
func union(a, b []string) []string {
	out := append([]string(nil), a...)
	for _, s := range b {
		if !slices.Contains(out, s) {
			out = append(out, s)
		}
	}
	return out
}

// Action names what the plan does, for the title of the screen: "upgrade
// from 26.10.0 to 26.11.0", or the installed release applied again.
func (p *Plan) Action() string { return p.action() }

// action names what the plan does, for the screen and the question.
func (p *Plan) action() string {
	switch {
	case p.Reapply:
		return fmt.Sprintf("apply %s again with %s", p.Target.Version, p.variantText())
	case p.MariaDBUpgrade:
		return fmt.Sprintf("upgrade from %s to %s and move MariaDB from %s to %s", p.installed(), p.Target.Version, p.RunningMariaDBSeries, p.MariaDBSeries)
	default:
		return fmt.Sprintf("upgrade from %s to %s", p.installed(), p.Target.Version)
	}
}

// variantText says which variants a re-apply installs.
func (p *Plan) variantText() string {
	var parts []string
	if p.PHPSeries != "" {
		parts = append(parts, "the images of PHP "+p.PHPSeries)
	}
	if p.MariaDBUpgrade {
		parts = append(parts, fmt.Sprintf("MariaDB moved from %s to %s", p.RunningMariaDBSeries, p.MariaDBSeries))
	}
	if len(parts) == 0 {
		return "the images it pins"
	}
	return strings.Join(parts, " and ")
}

func capitalize(s string) string {
	if s == "" {
		return s
	}
	return strings.ToUpper(s[:1]) + s[1:]
}
