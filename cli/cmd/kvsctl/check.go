package main

import (
	"context"
	"errors"
	"fmt"
	"io"
	"strings"

	"github.com/spf13/cobra"

	"github.com/MaximeMichaud/KVS-install/cli/internal/instance"
	"github.com/MaximeMichaud/KVS-install/cli/internal/manifest"
	"github.com/MaximeMichaud/KVS-install/cli/internal/upgrade"
)

func checkCmd() *cobra.Command {
	var version, mariadbSeries string
	var allowLocal, allowUnhealthy bool
	cmd := &cobra.Command{
		Use:   "check",
		Short: "Read the release manifest and say what an upgrade would do",
		Long: "Read the signed release manifest and say what 'kvsctl upgrade' would do\n" +
			"with the same flags: the releases it installs and their notes, the images\n" +
			"it pulls, the disk it needs, what happens to the database, and what\n" +
			"blocks it. When nothing does, it ends with the upgrade to run, those\n" +
			"flags included. It downloads the bundle of the release it would install\n" +
			"and reads it without keeping a copy: the files it lays and the services\n" +
			"it runs. The stack is not touched.",
		Args: cobra.NoArgs,
		RunE: func(cmd *cobra.Command, args []string) error {
			ctx, cancel := signalContext()
			defer cancel()
			inst, err := instance.Detect(flagRoot)
			if err != nil {
				return err
			}
			if err := refuseInterrupted(inst); err != nil {
				return err
			}
			state, err := inst.LoadState()
			if err != nil {
				return err
			}
			runner, err := planRunner(inst, version)
			if err != nil {
				return err
			}
			defer runner.Docker.Close()
			runner.Opts.MariaDBSeries, runner.Opts.AllowLocalChanges = mariadbSeries, allowLocal
			runner.Opts.AllowUnhealthy = allowUnhealthy
			plan, err := planUpgrade(runner, ctx, state)
			if ctx.Err() != nil {
				return errors.New("interrupted")
			}
			if err != nil {
				return err
			}
			rememberManifest(inst, plan.Manifest)
			printPlan(stdout, plan, inst, state, planDown(ctx, runner, plan), engineName(runner.Docker))
			if !plan.UpToDate && !plan.Downgrade && len(plan.Blockers) == 0 {
				_, _ = fmt.Fprintf(stdout, "%-12s %s\n", "Ready", readyLine(inst, upgradeCommand(version, mariadbSeries, allowLocal, allowUnhealthy)))
			}
			return nil
		},
	}
	cmd.Flags().StringVar(&version, "version", "", "release to look at (default the latest stable release, or the release candidate the stack runs when the manifest lists it and no stable release is newer; any other release candidate only when named)")
	cmd.Flags().StringVar(&mariadbSeries, "mariadb-series", "", "show what the upgrade would do with MariaDB moved to that series")
	cmd.Flags().BoolVar(&allowLocal, "allow-local-changes", false, "show what the upgrade would do with the locally edited release files overwritten")
	cmd.Flags().BoolVar(&allowUnhealthy, "allow-unhealthy", false, "show what the upgrade would do with the services unhealthy now left out of its verification")
	return cmd
}

// printPlan says what the upgrade would do: the releases it installs, the
// image each service runs today against the one the release pins, what
// that costs in downloads and disk, what happens to the database, and what
// blocks it. down replaces the health of the services when none of them
// runs, "" otherwise. engine names the engine the plan read when it is not
// the default one (engineName). The verdict of a plan nothing blocks is
// the caller's: check says how to run it. The images a manual rollback to
// the version before the installed one would pull are for status to name:
// the rollback of this upgrade returns to the installed version.
func printPlan(w io.Writer, plan *upgrade.Plan, inst *instance.Instance, state *instance.State, down, engine string) {
	line := func(label, format string, args ...any) {
		_, _ = fmt.Fprintf(w, "%-12s %s\n", label, fmt.Sprintf(format, args...))
	}
	line("Site", "%s (%s)", inst.Domain(), inst.Root)
	installed := state.Label(plan.Current)
	if kvs := inst.KVSVersion(); kvs != "" {
		installed += fmt.Sprintf("  KVS %s, PHP %s, IonCube %s", kvs, inst.PHPVersion(), yesNo(inst.IonCube()))
	}
	line("Installed", "%s", installed)
	line("Manifest", "%s", manifestSummary(plan.Manifest))
	switch {
	case plan.UpToDate:
		line("Target", "%s, already installed with the images it pins", plan.Target.Version)
		printManifestKeys(w, plan.Manifest)
		return
	case plan.Downgrade:
		line("Target", "%s", plan.DowngradeMessage())
		return
	case plan.Reapply:
		line("Target", "%s, to %s", plan.Target.Version, plan.Action())
	default:
		line("Target", "%s (%s)", plan.Target.Version, releaseDay(plan.Target.Date))
	}
	if plan.Incomplete {
		// The plan stopped before it read the stack: anything else it
		// would print is unknown, not empty.
		printBlockers(w, plan.Blockers)
		return
	}
	printNotes(w, plan.Releases)
	if len(plan.Services) > 0 {
		_, _ = fmt.Fprintln(w)
		printServices(w, plan.Services)
		_, _ = fmt.Fprintln(w)
	}
	// The images counted are those the pull step counts: an image the
	// container of its service already runs downloads nothing.
	downloads := len(plan.Downloads())
	line("Download", "%s over %d %s", upgrade.HumanBytes(plan.Bytes), downloads, plural(downloads, "image", "images"))
	for i, d := range plan.Disk {
		label := ""
		if i == 0 {
			label = "Disk"
		}
		line(label, "%s: %s free, %s needed", strings.Join(d.Paths, " and "), upgrade.HumanBytes(d.Free), upgrade.HumanBytes(d.Needed))
		for _, part := range d.Parts {
			line("", "  %s", part)
		}
	}
	for i, u := range plan.DiskUnknown {
		label := ""
		if i == 0 && len(plan.Disk) == 0 {
			label = "Disk"
		}
		line(label, "not measured: %s", u)
	}
	if plan.DumpEstimate == 0 && plan.DumpSource != "" {
		line("Backup", "size %s", plan.DumpSource)
	}
	if series := plan.Target.Series(); len(series) > 0 {
		line("PHP", "release publishes PHP %s, site runs %s", strings.Join(series, ", "), inst.PHPVersion())
	} else if php := plan.Target.Requires.PHP; php != "" {
		if inst.IonCube() {
			line("PHP", "release ships %s, site is encoded for %s", php, inst.PHPVersion())
		} else {
			line("PHP", "release ships %s, site runs %s", php, inst.PHPVersion())
		}
	}
	if kvsMin := plan.Target.Requires.KVSMin; kvsMin != "" {
		site := inst.KVSVersion()
		if site == "" {
			site = "an unknown version"
		}
		line("KVS", "release supports %s and newer, site runs %s", kvsMin, site)
	}
	if min := plan.Target.Requires.ComposeMin; min != "" {
		have := plan.ComposeVersion
		if have == "" {
			have = "an unknown version"
		}
		line("Compose", "release needs Docker Compose %s or newer, this machine has %s", min, have)
	}
	if text := mariadbSummary(plan); text != "" {
		line("MariaDB", "%s", text)
	}
	if plan.Architecture != "" {
		at := ""
		if engine != "" {
			at = " at " + engine
		}
		line("Engine", "runs on %s%s", plan.Architecture, at)
	}
	line("Database", "%s", databaseSummary(plan))
	if plan.OneWay {
		line("Rollback", "one way: a rollback recreates the MariaDB data directory and replays the backup")
	}
	if down != "" {
		line("Health", "%s", down)
	} else if text := healthSummary(plan); text != "" {
		line("Health", "%s", text)
	}
	line("Local files", "%s", localFilesSummary(plan, state))
	printManifestKeys(w, plan.Manifest)
	if last, ok := lastUndone(state); ok {
		line("Last upgrade", "%s", last.withLog(inst))
	}
	if len(plan.Blockers) > 0 {
		printBlockers(w, plan.Blockers)
	}
}

// manifestSummary is the Manifest line of the plan: the latest stable
// release, the default target, and a release candidate newer than it,
// which an upgrade installs only when it is named.
func manifestSummary(m *manifest.Manifest) string {
	newest := m.Latest()
	stable := m.LatestStable()
	count := fmt.Sprintf("%d %s", len(m.Releases), plural(len(m.Releases), "release", "releases"))
	if stable == nil {
		return fmt.Sprintf("%s, release candidates only, the newest %s (%s)", count, newest.Version, releaseDay(newest.Date))
	}
	text := fmt.Sprintf("%s, latest stable %s (%s)", count, stable.Version, releaseDay(stable.Date))
	if newest != stable {
		text += fmt.Sprintf(", release candidate %s (%s)", newest.Version, releaseDay(newest.Date))
	}
	return text
}

// planDown says what is wrong with a stack none of whose services runs,
// for the Health line of the plan, "" when one runs: a stack that is only
// stopped needs starting, not repairs or --allow-unhealthy.
func planDown(ctx context.Context, runner *upgrade.Runner, plan *upgrade.Plan) string {
	if len(plan.Unhealthy) == 0 {
		return ""
	}
	services, err := runner.Docker.ServiceImages(ctx, runner.Inst.ProjectName())
	if err != nil {
		return ""
	}
	text, _ := stackDown(ctx, runner.Docker, runner.Inst, services)
	return text
}

// readyLine is the verdict of a plan nothing blocks: the command that runs
// it, once what holds the lock now has let go of it.
func readyLine(inst *instance.Instance, command string) string {
	if live, err := inst.Holder(); err == nil && live != nil {
		return fmt.Sprintf("run '%s' %s: %s", command, onceUnlocked(live), live.Error())
	}
	return fmt.Sprintf("run '%s'", command)
}

// onceUnlocked says when a command can take the lock live holds: once the
// kvsctl running now ends, or once the docker command of a kvsctl that
// ended does.
func onceUnlocked(live *instance.LockedError) string {
	if live.Orphaned {
		return "once the docker command that holds the lock ends"
	}
	return "once the kvsctl running now ends"
}

// upgradeCommand is the upgrade check describes: 'kvsctl upgrade' with
// every flag check was given that changes what it does, the installation
// and the manifest included. Without them, the upgrade run would be
// another one than the one checked.
func upgradeCommand(version, mariadbSeries string, allowLocal, allowUnhealthy bool) string {
	var args []string
	valued := func(flag, value string) {
		if value != "" {
			args = append(args, flag, shellWord(value))
		}
	}
	set := func(flag string, on bool) {
		if on {
			args = append(args, flag)
		}
	}
	valued("--version", version)
	valued("--mariadb-series", mariadbSeries)
	set("--allow-local-changes", allowLocal)
	set("--allow-unhealthy", allowUnhealthy)
	return kvsctlCommand("upgrade", true, args...)
}

// shellWord writes value the way a shell reads it back as one word: as it
// is when it holds nothing a shell reads otherwise, in double quotes
// otherwise, since the command is quoted with single ones.
func shellWord(value string) string {
	if strings.Trim(value, "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789@%+=:,./_-") == "" {
		return value
	}
	var b strings.Builder
	b.WriteByte('"')
	for _, r := range value {
		if strings.ContainsRune(`"\$`+"`", r) {
			b.WriteByte('\\')
		}
		b.WriteRune(r)
	}
	b.WriteByte('"')
	return b.String()
}

// printBlockers lists what keeps the upgrade from running, each with what
// to do about it.
func printBlockers(w io.Writer, blockers []string) {
	_, _ = fmt.Fprintln(w, "Blocked")
	for _, b := range blockers {
		_, _ = fmt.Fprintln(w, "  -", b)
	}
}

// printNotes shows the notes of every release the upgrade installs, oldest
// first: a jump carries what each skipped release says.
func printNotes(w io.Writer, releases []manifest.Release) {
	label := "Notes"
	for _, rel := range releases {
		text := rel.Notes
		if len(releases) > 1 {
			text = strings.TrimSpace(fmt.Sprintf("%s (%s) %s", rel.Version, releaseDay(rel.Date), rel.Notes))
		}
		if text != "" {
			_, _ = fmt.Fprintf(w, "%-12s %s\n", label, text)
			label = ""
		}
		for _, h := range rel.Highlights {
			_, _ = fmt.Fprintf(w, "%-12s - %s\n", label, h)
			label = ""
		}
	}
	label = "Changelog"
	for _, rel := range releases {
		if rel.NotesURL != "" {
			_, _ = fmt.Fprintf(w, "%-12s %s\n", label, rel.NotesURL)
			label = ""
		}
	}
}

// printManifestKeys warns about the signing keys the manifest announces
// and this kvsctl does not carry.
func printManifestKeys(w io.Writer, m *manifest.Manifest) {
	if len(m.Keys) == 0 {
		return
	}
	announced := make([]instance.AnnouncedKey, 0, len(m.Keys))
	for _, k := range m.Keys {
		announced = append(announced, instance.AnnouncedKey{ID: k.ID, ValidFrom: k.ValidFrom})
	}
	printAnnouncedKeys(w, announced)
}

// printServices is the table of the release: one line per service, what it
// runs now, what the release pins, and what is left to download.
func printServices(w io.Writer, services []upgrade.PlanImage) {
	nameW, runW, relW := len("Service"), len("Running"), len("Release")
	for _, s := range services {
		nameW = max(nameW, len(s.Service))
		runW = max(runW, len(displayRef(s.Running)))
		relW = max(relW, len(s.Ref))
	}
	_, _ = fmt.Fprintf(w, "%-*s  %-*s  %-*s  %s\n", nameW, "Service", runW, "Running", relW, "Release", "Download")
	for _, s := range services {
		_, _ = fmt.Fprintf(w, "%-*s  %-*s  %-*s  %s\n", nameW, s.Service, runW, displayRef(s.Running), relW, s.Ref, downloadCell(s))
	}
}

func displayRef(ref string) string {
	if ref == "" {
		return "-"
	}
	return ref
}

// downloadCell is what a service costs: nothing when its container already
// runs the release image or the engine holds it, nothing either for a
// service compose does not run here (its image is pinned, and pulled the
// day it is turned on), the bytes otherwise.
func downloadCell(s upgrade.PlanImage) string {
	switch {
	case s.Unchanged:
		return "unchanged"
	case s.OnDisk:
		return "on disk"
	case !s.Active:
		return "not used here"
	default:
		return upgrade.HumanBytes(s.Bytes)
	}
}

// mariadbSummary says what the upgrade does with the MariaDB series: keep
// it, or move it to the series asked for. A newer series the release
// publishes is named, with the flag that moves to it.
func mariadbSummary(plan *upgrade.Plan) string {
	have := plan.RunningMariaDBSeries
	if have == "" {
		return ""
	}
	if plan.MariaDBUpgrade {
		return fmt.Sprintf("moves from %s to %s: the data files are upgraded in place, and only the backup goes back", have, plan.MariaDBSeries)
	}
	text := "keeps " + have
	if plan.MariaDBImageChanges {
		text += ", with the image the release pins"
	}
	for _, s := range plan.Target.Values(manifest.VariantMariaDB) {
		if manifest.LessSeries(have, s) {
			text += fmt.Sprintf(" (the release also publishes %s: --mariadb-series %s moves to it)", s, s)
			break
		}
	}
	return text
}

func databaseSummary(plan *upgrade.Plan) string {
	if plan.MariaDBUpgrade {
		return "MariaDB changes series: the data files are upgraded in place and only the backup goes back"
	}
	if plan.Database == "migrates" {
		return "this release changes it; a rollback restores the backup"
	}
	return "unchanged, a rollback keeps the data"
}

// healthSummary says how the active services are doing before anything
// changes, and which ones the verification would leave out.
func healthSummary(plan *upgrade.Plan) string {
	if len(plan.ActiveServices) == 0 {
		return ""
	}
	if len(plan.Unhealthy) == 0 {
		return fmt.Sprintf("%d active %s, none unhealthy or stopped", len(plan.ActiveServices), plural(len(plan.ActiveServices), "service", "services"))
	}
	text := strings.Join(plan.Unhealthy, "; ")
	if len(plan.Ignored) > 0 {
		text += fmt.Sprintf("; left out of the verification (--allow-unhealthy): %s", strings.Join(plan.Ignored, ", "))
	}
	return text
}

// localFilesSummary says whether the release files still match what was
// recorded when the installed version was laid down.
func localFilesSummary(plan *upgrade.Plan, state *instance.State) string {
	label := state.Label(plan.Current)
	if plan.TrackedFiles == 0 {
		return fmt.Sprintf("not checked: no checksum is recorded for %s", label)
	}
	if len(plan.LocalChanges) == 0 {
		matches := "files match"
		if plan.TrackedFiles == 1 {
			matches = "file matches"
		}
		return fmt.Sprintf("%d release %s the record of %s", plan.TrackedFiles, matches, label)
	}
	shown := plan.LocalChanges
	suffix := ""
	if len(shown) > 5 {
		shown, suffix = shown[:5], fmt.Sprintf(" and %d more", len(plan.LocalChanges)-5)
	}
	return fmt.Sprintf("%d of %d changed since %s: %s%s", len(plan.LocalChanges), plan.TrackedFiles, label, strings.Join(shown, ", "), suffix)
}
