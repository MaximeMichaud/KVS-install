package main

import (
	"context"
	"errors"
	"fmt"
	"io"
	"path/filepath"
	"sort"
	"strings"
	"time"

	"github.com/spf13/cobra"

	"github.com/MaximeMichaud/KVS-install/cli/internal/dockerx"
	"github.com/MaximeMichaud/KVS-install/cli/internal/instance"
	"github.com/MaximeMichaud/KVS-install/cli/internal/manifest"
	"github.com/MaximeMichaud/KVS-install/cli/internal/runlog"
	"github.com/MaximeMichaud/KVS-install/cli/internal/semver"
	"github.com/MaximeMichaud/KVS-install/cli/internal/ui"
	"github.com/MaximeMichaud/KVS-install/cli/internal/upgrade"
)

func statusCmd() *cobra.Command {
	return &cobra.Command{
		Use:   "status",
		Short: "Show the installed stack, its services and any newer stable release",
		Long: "Show the installed stack: first the run another kvsctl has in progress,\n" +
			"or a run that was interrupted, then the site, the stack version, the\n" +
			"MariaDB series, the services and how they are doing, the last upgrade\n" +
			"when it failed, was cancelled or was interrupted and was rolled back,\n" +
			"and whether a newer stable release exists, with what to run about it:\n" +
			"'kvsctl check', which says whether 'kvsctl upgrade' can install it, or\n" +
			"what has to come first; a release candidate is never announced. It runs\n" +
			"while another kvsctl holds the lock, and changes nothing on the stack.",
		Args: cobra.NoArgs,
		RunE: func(cmd *cobra.Command, args []string) error {
			ctx, cancel := signalContext()
			defer cancel()
			inst, err := instance.Detect(flagRoot)
			if err != nil {
				return err
			}
			j, live, err := runState(inst)
			if err != nil {
				return err
			}
			// The state names the versions of the run. A state that cannot
			// be read still lets the run show first, as recorded, and its
			// error comes right after.
			state, stateErr := inst.LoadState()
			printRun(stdout, state, j, live)
			if stateErr != nil {
				return stateErr
			}
			line := func(label, format string, args ...any) {
				_, _ = fmt.Fprintf(stdout, "%-12s %s\n", label, fmt.Sprintf(format, args...))
			}
			line("Site", "%s (%s)", inst.Domain(), inst.Root)
			if kvs := inst.KVSVersion(); kvs != "" {
				line("KVS", "%s, PHP %s, IonCube %s", kvs, inst.PHPVersion(), yesNo(inst.IonCube()))
			}
			line("Stack", "%s", stackLine(state))
			docker, err := dockerx.New()
			if err != nil {
				return err
			}
			defer docker.Close()
			if err := upgrade.CheckEngine(ctx, docker); err != nil {
				return err
			}
			// What follows is the engine's, which is said when it is not
			// the default one.
			if engine := engineName(docker); engine != "" {
				line("Engine", "%s", engine)
			}
			services, err := docker.ServiceImages(ctx, inst.ProjectName())
			if err != nil {
				return err
			}
			runner := &upgrade.Runner{Inst: inst, Docker: docker}
			if series, version := runner.StackMariaDB(ctx, services); series != "" {
				if version != "" && version != series {
					series += " (server " + version + ")"
				}
				line("MariaDB", "%s", series)
			} else {
				line("MariaDB", "series unknown: no mariadb container names one, and MARIADB_VERSION in %s names none", inst.EnvPath)
			}
			if warning := overrideWarning(inst); warning != "" {
				line("Override", "%s", warning)
			}
			// What the engine cannot say is left out: the line warns, and
			// the rollback itself checks again before its first change.
			if missing, err := runner.MissingRollbackImages(ctx, state); err == nil && len(missing) > 0 {
				line("Rollback", "%s", rollbackImagesLine(state, missing))
			}
			_, _ = fmt.Fprintln(stdout)
			down, first := stackDown(ctx, docker, inst, services)
			switch {
			case len(services) == 0:
				line("Services", "%s", down)
			case down != "":
				printRunning(stdout, services)
				line("Stopped", "%s", down)
			default:
				printRunning(stdout, services)
			}
			_, _ = fmt.Fprintln(stdout)
			if state != nil {
				if last, ok := lastUndone(state); ok {
					line("Last upgrade", "%s", last.withLog(inst))
				}
				// The read takes the context of status, which its Ctrl-C
				// cancels whenever it comes, before the read too.
				latest, err := latestRelease(inst, statusWait, func(url string) (*manifest.Document, error) {
					doc, err := manifest.FetchContext(ctx, url)
					if err != nil && ctx.Err() != nil {
						return nil, manifest.ErrInterrupted
					}
					return doc, err
				})
				line("Updates", "%s", updatesLine(inst, state, latest, err, first))
				if updates, err := inst.LoadUpdates(); err == nil && updates != nil {
					printAnnouncedKeys(stdout, updates.Keys)
				}
				if errors.Is(err, manifest.ErrInterrupted) {
					// The output stops short of what status says, which a
					// script reads in the exit code.
					return errors.New("interrupted")
				}
			}
			return nil
		},
	}
}

// defaultEngine is where Docker listens unless DOCKER_HOST or a docker
// context says otherwise.
const defaultEngine = "unix:///var/run/docker.sock"

// engineName is where the engine docker talks to listens, "" for the
// default one: a rootless engine or another docker context is named, since
// what status and check show is that engine's.
func engineName(docker *dockerx.Client) string {
	if endpoint := docker.Endpoint(); endpoint != defaultEngine {
		return endpoint
	}
	return ""
}

// rollbackImagesLine says that a rollback to the previous version has
// images to pull first, missing.
func rollbackImagesLine(state *instance.State, missing []string) string {
	return fmt.Sprintf("the images of %s are not on this machine (%d): a rollback pulls them first, and is refused while the registry cannot be reached", state.Label(state.Previous), len(missing))
}

// printRun puts a run that did not finish at the top of status: one still
// going in another kvsctl, with the phase its journal names once it has
// changed the stack, or one that was interrupted and waits for recover.
// The state names the versions the way the operator reads them.
func printRun(w io.Writer, state *instance.State, j *instance.Journal, live *instance.LockedError) {
	switch {
	case live != nil && live.Orphaned && j != nil:
		_, _ = fmt.Fprintf(w, "%-12s %s: %s from %s to %s, stopped at its %s phase\n", "Locked", live.Error(), j.Action, state.Label(j.From), state.Label(j.To), j.Phase)
	case live != nil && j != nil:
		_, _ = fmt.Fprintf(w, "%-12s %s: %s from %s to %s, now at its %s phase\n", "Running", live.Error(), j.Action, state.Label(j.From), state.Label(j.To), j.Phase)
	case live != nil && live.Orphaned:
		// The run is over; a docker command it started holds the lock.
		_, _ = fmt.Fprintf(w, "%-12s %s\n", "Locked", live.Error())
	case live != nil:
		_, _ = fmt.Fprintf(w, "%-12s %s\n", "Running", live.Error())
	case j != nil && !j.Failed.IsZero():
		// A run that failed is no interruption: its cause comes first.
		_, _ = fmt.Fprintf(w, "%-12s %s\n", "Failed", interruptedRun(state, j).Error())
	case j != nil:
		_, _ = fmt.Fprintf(w, "%-12s %s\n", "Interrupted", interruptedRun(state, j).Error())
	}
}

// stackLine is the version kvsctl recorded, the one a rollback returns to,
// or how to record it.
func stackLine(state *instance.State) string {
	if state == nil {
		return "not recorded yet: run 'kvsctl adopt'"
	}
	text := state.Label(state.Current)
	if state.Previous != "" {
		text += fmt.Sprintf(" (previous %s)", state.Label(state.Previous))
	}
	return text
}

// overrideWarning says when the operator's compose override exists and
// COMPOSE_FILE does not load it: the override compose itself loads without
// COMPOSE_FILE, under whichever of its names. A list that leaves it out
// makes compose ignore it, which is what a list written by hand, or by a
// kvsctl older than the override, does. kvsctl puts it in the list
// whenever it writes it, unless the list names an override already, by
// another name: that one is the operator's choice, and only the operator
// can add the other.
func overrideWarning(inst *instance.Instance) string {
	name := upgrade.DefaultOverride(inst.DockerDir)
	if name == "" {
		return ""
	}
	current := inst.Env["COMPOSE_FILE"]
	if current == "" {
		return ""
	}
	sep := inst.Env["COMPOSE_PATH_SEPARATOR"]
	if sep == "" {
		sep = ":"
	}
	other := ""
	for _, entry := range strings.Split(current, sep) {
		if filepath.Base(entry) == name {
			return ""
		}
		if other == "" && upgrade.IsOverride(entry) {
			other = entry
		}
	}
	path := filepath.Join(inst.DockerDir, name)
	if other != "" {
		return fmt.Sprintf("%s exists, and COMPOSE_FILE in %s loads another override, %s, and not this one, so compose ignores it: upgrades and rollbacks keep that list as it is, so add it to COMPOSE_FILE by hand", path, inst.EnvPath, other)
	}
	return fmt.Sprintf("%s exists, and COMPOSE_FILE in %s does not load it, so compose ignores it: the next upgrade or rollback adds it, or add it to COMPOSE_FILE by hand", path, inst.EnvPath)
}

// printRunning is the table of the services for status, which knows the
// containers but not the manifest: the image each service runs and how it
// is doing.
func printRunning(w io.Writer, services map[string]dockerx.ServiceImage) {
	names := make([]string, 0, len(services))
	nameW, runW := len("Service"), len("Running")
	for name, svc := range services {
		if strings.HasSuffix(name, "-init") {
			continue
		}
		names = append(names, name)
		nameW = max(nameW, len(name))
		runW = max(runW, len(displayRef(svc.Image)))
	}
	sort.Strings(names)
	_, _ = fmt.Fprintf(w, "%-*s  %-*s  %s\n", nameW, "Service", runW, "Running", "State")
	for _, name := range names {
		svc := services[name]
		state := svc.State
		if svc.Health != "" {
			state += ", " + svc.Health
		}
		_, _ = fmt.Fprintf(w, "%-*s  %-*s  %s\n", nameW, name, runW, displayRef(svc.Image), state)
	}
}

// stackDown says what is wrong with a stack none of whose services runs,
// "" when one does, from the containers of its project: services, as
// ServiceImages lists them. first is what has to be done before an
// upgrade, which would find every service unhealthy.
func stackDown(ctx context.Context, docker *dockerx.Client, inst *instance.Instance, services map[string]dockerx.ServiceImage) (text, first string) {
	switch {
	case len(services) == 0:
		if _, err := docker.Container(ctx, inst.ContainerPrefix()+"-mariadb"); err == nil {
			return noServices(inst, true), "check COMPOSE_PROJECT_NAME in .env"
		}
		return noServices(inst, false), "start the stack"
	case allStopped(services):
		return fmt.Sprintf("no service runs: start the stack with 'docker compose up -d' in %s", inst.DockerDir), "start the stack"
	}
	return "", ""
}

// noServices says why a project has no container. Either the containers
// the stack names exist under another compose project, as a
// COMPOSE_PROJECT_NAME changed in .env leaves them, or there are none, as
// 'docker compose down' leaves the stack, and .env is not to blame.
func noServices(inst *instance.Instance, elsewhere bool) string {
	if elsewhere {
		return fmt.Sprintf("no container of compose project %q found, though %s-mariadb exists: check COMPOSE_PROJECT_NAME in %s", inst.ProjectName(), inst.ContainerPrefix(), inst.EnvPath)
	}
	return fmt.Sprintf("the stack is down, no container of compose project %q exists: start it with 'docker compose up -d' in %s", inst.ProjectName(), inst.DockerDir)
}

// allStopped reports whether no service of the project runs, as a reboot
// without restart policies or 'docker compose stop' leaves a stack: its
// containers are there, and starting them is the whole repair.
func allStopped(services map[string]dockerx.ServiceImage) bool {
	for name, svc := range services {
		if strings.HasSuffix(name, "-init") {
			continue
		}
		switch svc.State {
		case "exited", "created", "dead":
		default:
			return false
		}
	}
	return true
}

// undoneUpgrade is an upgrade that did not end on its release and was
// rolled back, as the history keeps it.
type undoneUpgrade struct {
	to, cause string
	at        time.Time
	// how says why: "failed", which leaves a cause to fix before the
	// upgrade runs again, or "was cancelled" or "was interrupted", which
	// leave none.
	how string
}

// lastUndone is the upgrade the newest entry of the history says was
// rolled back; whatever kvsctl did to the stack since, an upgrade that
// worked included, leaves none. The entry is the one the automatic
// rollback, or recover, writes: the version it returned to, and the run it
// undid with how that run ended and why. The cause is the first line of
// the error, which ends with a separator when a docker command wrote
// nothing on stderr; that separator goes.
func lastUndone(state *instance.State) (undoneUpgrade, bool) {
	if state == nil || len(state.History) == 0 {
		return undoneUpgrade{}, false
	}
	e := state.History[len(state.History)-1]
	if e.Action != instance.ActionRollback || e.Version != state.Current {
		return undoneUpgrade{}, false
	}
	if u := e.Undid; u != nil {
		if u.Action != instance.ActionUpgrade || u.To == "" {
			return undoneUpgrade{}, false
		}
		how := "failed"
		switch u.Outcome {
		case instance.OutcomeCancelled:
			how = "was cancelled"
		case instance.OutcomeInterrupted:
			how = "was interrupted"
		}
		return undoneUpgrade{to: u.To, cause: ui.Clean(u.Cause), at: e.Date, how: how}, true
	}
	return noteUndone(e)
}

// noteUndone reads the entry an older kvsctl wrote, which says how the run
// ended in its note alone: "<version> failed: <cause>", whatever ended the
// run. The cause tells which: a run the first Ctrl-C or a SIGTERM
// cancelled ends with the error of the step it cut short, which the
// context names; recover, rolling back a run a crash or a kill cut short,
// gives "interrupted during <phase>".
func noteUndone(e instance.Entry) (undoneUpgrade, bool) {
	to, cause, ok := strings.Cut(e.Note, " failed: ")
	if !ok || to == "" || strings.ContainsRune(to, ' ') {
		return undoneUpgrade{}, false
	}
	how := "failed"
	switch {
	case strings.Contains(cause, context.Canceled.Error()):
		how = "was cancelled"
	case strings.HasPrefix(cause, "interrupted during "):
		how = "was interrupted"
	}
	return undoneUpgrade{to: to, cause: ui.Clean(cause), at: e.Date, how: how}, true
}

// failed reports whether the upgrade failed by itself, which leaves a
// cause to fix before it runs again.
func (u undoneUpgrade) failed() bool { return u.how == "failed" }

// String says the upgrade in a line of its own.
func (u undoneUpgrade) String() string {
	return fmt.Sprintf("the last upgrade to %s %s on %s and was rolled back (%s)", u.to, u.how, u.at.UTC().Format("2006-01-02 15:04 UTC"), u.cause)
}

// withLog says the upgrade after the label "Last upgrade", with the log of
// its run when kvsctl still keeps it.
func (u undoneUpgrade) withLog(inst *instance.Instance) string {
	text := fmt.Sprintf("to %s %s on %s and was rolled back: %s", u.to, u.how, u.at.UTC().Format("2006-01-02 15:04 UTC"), u.cause)
	if log := runLogBefore(inst, u.at); log != "" {
		text += " (log: " + log + ")"
	}
	return text
}

// runLogBefore is the log of the run that wrote a history entry dated at:
// the newest upgrade or recover log started before it, since the lock that
// run held kept any other from starting in between. It is "" when the logs
// no longer hold it.
func runLogBefore(inst *instance.Instance, at time.Time) string {
	logs, err := runlog.List(inst.StateDir())
	if err != nil {
		return ""
	}
	for _, path := range logs {
		name := filepath.Base(path)
		if len(name) < len("20060102-150405-") {
			continue
		}
		start, err := time.Parse("20060102-150405", name[:15])
		if err != nil || start.After(at) {
			continue
		}
		switch strings.TrimSuffix(name[16:], ".log") {
		case "upgrade", "recover":
			return path
		}
	}
	return ""
}

// updatesLine is the Updates line of status: whether a newer stable
// release exists, and what to do about it. What stands in the way of an
// upgrade, a run in progress or interrupted, a failure, a stack that is
// down, is on its own line above; first is what stackDown says to do
// about the last.
func updatesLine(inst *instance.Instance, state *instance.State, latest latestKnown, err error, first string) string {
	var earlier *earlierFailure
	switch {
	case errors.As(err, &earlier):
		return fmt.Sprintf("could not check at %s UTC (%s); 'kvsctl check' reads the manifest now", earlier.at.UTC().Format("15:04"), earlier.msg)
	case err != nil:
		return fmt.Sprintf("could not check (%s)", firstLine(err.Error()))
	case latest.Version == "" || !semver.Less(state.Current, latest.Version):
		return "up to date"
	case checkoutAhead(state, latest):
		return fmt.Sprintf("none newer than this checkout: %s was released on %s, before its commit %s of %s", latest.Version, releaseMoment(latest.Date), shortCommit(state.AdoptedCommit), state.AdoptedCommitDate.UTC().Format(momentLayout))
	}
	step, _ := upgradeStep(inst, state, latest, first)
	return fmt.Sprintf("%s available, %s", latest.Version, step)
}

// momentLayout writes the two times the guard of an adopted checkout
// compares, to the second, as it compares them.
const momentLayout = "2006-01-02 15:04:05 UTC"

// releaseMoment writes a release date the way momentLayout writes the
// commit of the checkout next to it; a date that names only a day stays as
// it is.
func releaseMoment(date string) string {
	if t, err := time.Parse(time.RFC3339, date); err == nil {
		return t.UTC().Format(momentLayout)
	}
	return date
}
