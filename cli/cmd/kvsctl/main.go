// kvsctl installs, checks, upgrades and rolls back the KVS Docker stack.
package main

import (
	"context"
	"crypto/ed25519"
	"crypto/sha256"
	"encoding/hex"
	"errors"
	"fmt"
	"io"
	"net/http"
	"os"
	"os/signal"
	"path/filepath"
	"runtime"
	"sort"
	"strings"
	"syscall"
	"time"

	tea "github.com/charmbracelet/bubbletea"
	"github.com/spf13/cobra"

	"github.com/MaximeMichaud/KVS-install/cli/internal/backup"
	"github.com/MaximeMichaud/KVS-install/cli/internal/dockerx"
	"github.com/MaximeMichaud/KVS-install/cli/internal/instance"
	"github.com/MaximeMichaud/KVS-install/cli/internal/manifest"
	"github.com/MaximeMichaud/KVS-install/cli/internal/release"
	"github.com/MaximeMichaud/KVS-install/cli/internal/semver"
	"github.com/MaximeMichaud/KVS-install/cli/internal/ui"
	"github.com/MaximeMichaud/KVS-install/cli/internal/upgrade"
)

// Version is set by the build (-ldflags "-X main.Version=...").
var Version = "dev"

// DefaultManifestURL is the signed release list; the lab and tests point
// KVSCTL_MANIFEST_URL or --manifest elsewhere.
const DefaultManifestURL = "https://github.com/MaximeMichaud/KVS-install/releases/latest/download/manifest.json"

// ReleasePublicKey lists the keys that verify the manifest (Ed25519, base64
// of the raw key, "id=base64" or the key alone, comma separated). One valid
// signature by any of them is enough, so a new key ships in kvsctl before
// it signs. KVSCTL_RELEASE_KEY replaces the whole list for a lab that signs
// with its own key.
var ReleasePublicKey = "KZYznVR68TMpw0wm0G3ASwQkJ6xyj0pQAO7oR4RStjs=" // pragma: allowlist secret

// Exit codes, so a cron job or a CI step can tell what happened without
// reading the output:
//
//	0 the command did what it was asked
//	1 an error
//	2 the command line is wrong
//	3 the upgrade is blocked, nothing was touched
//	4 the upgrade failed and the previous version is back
//	5 the upgrade failed and the rollback failed too
//	6 another kvsctl holds the lock
//	7 the manifest is older than the one already seen
const (
	exitError          = 1
	exitUsage          = 2
	exitBlocked        = 3
	exitRolledBack     = 4
	exitRollbackFailed = 5
	exitLocked         = 6
	exitStaleManifest  = 7
)

var (
	flagRoot       string
	flagManifest   string
	flagYes        bool
	flagPlain      bool
	flagQuiet      bool
	flagAllowStale bool
)

func main() {
	backup.ToolVersion = Version
	root := &cobra.Command{
		Use:           "kvsctl",
		Short:         "Manage a KVS Docker stack installed by kvs-install",
		SilenceUsage:  true,
		SilenceErrors: true,
	}
	root.PersistentFlags().StringVar(&flagRoot, "root", "", "installation directory (default /opt/kvs or $KVS_INSTALL_DIR)")
	root.PersistentFlags().StringVar(&flagManifest, "manifest", "", "release manifest URL (default $KVSCTL_MANIFEST_URL or the project releases)")
	root.PersistentFlags().BoolVarP(&flagYes, "yes", "y", false, "answer yes to every question")
	root.PersistentFlags().BoolVar(&flagPlain, "plain", false, "print lines instead of the interactive screen")
	root.PersistentFlags().BoolVar(&flagQuiet, "quiet", false, "print only the steps, the failures and the questions, and skip the reminder that a newer release exists")
	root.PersistentFlags().BoolVar(&flagAllowStale, "allow-stale-manifest", false, "accept a manifest older than the newest one already seen (a stale mirror, a replayed file)")
	root.SetFlagErrorFunc(func(_ *cobra.Command, err error) error { return usageError{err} })
	root.PersistentPostRunE = func(cmd *cobra.Command, _ []string) error {
		remind(cmd)
		return nil
	}
	root.AddCommand(versionCmd(), statusCmd(), checkCmd(), upgradeCmd(), rollbackCmd(), backupCmd(), adoptCmd(), updateCLICmd())
	root.AddCommand(extraCommands...)
	if err := root.Execute(); err != nil {
		fmt.Fprintln(os.Stderr, "kvsctl:", err)
		os.Exit(exitCode(err))
	}
}

// usageError marks a command line kvsctl could not parse, which exits 2.
type usageError struct{ err error }

func (u usageError) Error() string { return u.err.Error() }
func (u usageError) Unwrap() error { return u.err }

// exitCode maps the errors the commands return to the codes above.
func exitCode(err error) int {
	var locked *instance.LockedError
	var usage usageError
	switch {
	case err == nil:
		return 0
	case errors.As(err, &usage), isUsageText(err):
		return exitUsage
	case errors.As(err, &locked):
		return exitLocked
	case errors.Is(err, upgrade.ErrStaleManifest):
		return exitStaleManifest
	case errors.Is(err, upgrade.ErrRollbackFailed):
		return exitRollbackFailed
	case errors.Is(err, upgrade.ErrRolledBack):
		return exitRolledBack
	case errors.Is(err, upgrade.ErrBlocked):
		return exitBlocked
	default:
		return exitError
	}
}

// isUsageText catches the command line errors cobra builds itself, which
// carry no type of their own.
func isUsageText(err error) bool {
	msg := err.Error()
	for _, prefix := range []string{"unknown command", "unknown flag", "unknown shorthand flag", "required flag(s)", "invalid argument", "accepts "} {
		if strings.HasPrefix(msg, prefix) {
			return true
		}
	}
	return false
}

// remind tells the operator, on stderr, that a newer release exists. The
// manifest is read at most once a day (the answer is kept in the updates
// file), the commands that would say it themselves are skipped, and a
// failure is never the command's problem.
func remind(cmd *cobra.Command) {
	if flagQuiet {
		return
	}
	switch cmd.Name() {
	case "upgrade", "update-cli", "version", "help", "completion":
		return
	}
	if parent := cmd.Parent(); parent != nil && parent.Name() == "completion" {
		return
	}
	inst, err := instance.Detect(flagRoot)
	if err != nil {
		return
	}
	state, err := inst.LoadState()
	if err != nil || state == nil {
		return
	}
	latest, err := latestVersion(inst)
	if err != nil || latest == "" {
		return
	}
	if semver.Less(state.Current, latest) {
		fmt.Fprintf(os.Stderr, "%s is available, run 'kvsctl upgrade'\n", latest)
	}
}

func manifestURL() string {
	if flagManifest != "" {
		return flagManifest
	}
	if env := os.Getenv("KVSCTL_MANIFEST_URL"); env != "" {
		return env
	}
	return DefaultManifestURL
}

func publicKeys() ([]ed25519.PublicKey, error) {
	encoded := ReleasePublicKey
	if env := os.Getenv("KVSCTL_RELEASE_KEY"); env != "" {
		encoded = env
	}
	var specs []string
	for _, spec := range strings.Split(encoded, ",") {
		if spec = strings.TrimSpace(spec); spec != "" {
			specs = append(specs, spec)
		}
	}
	keys, err := manifest.ParseKeys(specs)
	if err != nil {
		return nil, fmt.Errorf("release public key: %w", err)
	}
	if len(keys) == 0 {
		return nil, errors.New("no release public key is configured")
	}
	return keys, nil
}

// knownKeyIDs are the ids of the keys this build trusts.
func knownKeyIDs() map[string]bool {
	ids := map[string]bool{}
	keys, err := publicKeys()
	if err != nil {
		return ids
	}
	for _, key := range keys {
		ids[manifest.KeyID(key)] = true
	}
	return ids
}

// printAnnouncedKeys warns about a signing key the manifest announces and
// this build does not carry: the day it signs, this kvsctl stops trusting
// the manifest, so update-cli has to run first.
func printAnnouncedKeys(keys []instance.AnnouncedKey) {
	known := knownKeyIDs()
	for _, key := range keys {
		if known[key.ID] {
			continue
		}
		from := ""
		if key.ValidFrom != "" {
			from = " from " + key.ValidFrom
		}
		fmt.Printf("%-12s the manifest announces signing key %s%s, unknown to this kvsctl: run 'kvsctl update-cli' before then\n", "Signing key", key.ID, from)
	}
}

func signalContext() (context.Context, context.CancelFunc) {
	return signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
}

// fetchManifest reads the release list and checks its signature.
func fetchManifest() (*manifest.Manifest, error) {
	keys, err := publicKeys()
	if err != nil {
		return nil, err
	}
	doc, err := manifest.Fetch(manifestURL())
	if err != nil {
		return nil, err
	}
	if err := doc.VerifyAny(keys); err != nil {
		return nil, err
	}
	return doc.Manifest, nil
}

func versionCmd() *cobra.Command {
	var check bool
	cmd := &cobra.Command{
		Use:   "version",
		Short: "Print the kvsctl version",
		RunE: func(cmd *cobra.Command, args []string) error {
			fmt.Printf("kvsctl %s (%s/%s)\n", Version, runtime.GOOS, runtime.GOARCH)
			if !check {
				return nil
			}
			m, err := fetchManifest()
			if err != nil {
				return err
			}
			latest := m.Latest()
			if _, ok := latest.CLI[runtime.GOOS+"-"+runtime.GOARCH]; !ok {
				fmt.Printf("release %s ships no kvsctl for %s/%s\n", latest.Version, runtime.GOOS, runtime.GOARCH)
				return nil
			}
			msg, outdated := cliState(latest.Version)
			if outdated {
				msg += ", run 'kvsctl update-cli'"
			}
			fmt.Println(msg)
			return nil
		},
	}
	cmd.Flags().BoolVar(&check, "check", false, "say whether the manifest ships a newer kvsctl")
	return cmd
}

// cliState compares this binary with the build a release ships. A version
// that is not a release version, like the dev build, is always replaced:
// there is no way to tell which of the two is newer.
func cliState(releaseVersion string) (msg string, outdated bool) {
	switch {
	case Version == releaseVersion:
		return fmt.Sprintf("kvsctl %s is the build of release %s", Version, releaseVersion), false
	case !isRelease(Version):
		return fmt.Sprintf("kvsctl %s is not a release build, release %s ships one", Version, releaseVersion), true
	case semver.Less(Version, releaseVersion):
		return fmt.Sprintf("release %s ships a newer kvsctl than %s", releaseVersion, Version), true
	default:
		return fmt.Sprintf("kvsctl %s is newer than the build of release %s", Version, releaseVersion), false
	}
}

func isRelease(v string) bool {
	_, err := semver.Parse(v)
	return err == nil
}

func statusCmd() *cobra.Command {
	return &cobra.Command{
		Use:   "status",
		Short: "Show the installed stack, its services and whether an update exists",
		RunE: func(cmd *cobra.Command, args []string) error {
			ctx, cancel := signalContext()
			defer cancel()
			inst, err := instance.Detect(flagRoot)
			if err != nil {
				return err
			}
			state, err := inst.LoadState()
			if err != nil {
				return err
			}
			fmt.Printf("%-12s %s (%s)\n", "Site", inst.Domain(), inst.Root)
			if kvs := inst.KVSVersion(); kvs != "" {
				fmt.Printf("%-12s %s, PHP %s, IonCube %s\n", "KVS", kvs, inst.PHPVersion(), yesNo(inst.IonCube()))
			}
			if state == nil {
				fmt.Printf("%-12s not adopted yet (kvsctl adopt --version <installed version>)\n", "Stack")
			} else {
				line := state.Current
				if state.Previous != "" {
					line += fmt.Sprintf(" (previous %s)", state.Previous)
				}
				fmt.Printf("%-12s %s\n", "Stack", line)
			}
			docker, err := dockerx.New()
			if err != nil {
				return err
			}
			defer docker.Close()
			services, err := docker.ServiceImages(ctx, inst.ProjectName())
			if err != nil {
				return err
			}
			fmt.Println()
			if len(services) == 0 {
				fmt.Printf("%-12s no container of compose project %q found: check COMPOSE_PROJECT_NAME in .env\n", "Services", inst.ProjectName())
			} else {
				printRunning(services)
			}
			fmt.Println()
			if state != nil {
				latest, err := latestVersion(inst)
				switch {
				case err != nil:
					fmt.Printf("%-12s could not check (%s)\n", "Updates", firstLine(err.Error()))
				case latest != "" && semver.Less(state.Current, latest):
					fmt.Printf("%-12s %s available, run 'kvsctl upgrade'\n", "Updates", latest)
				default:
					fmt.Printf("%-12s up to date\n", "Updates")
				}
				if updates, err := inst.LoadUpdates(); err == nil && updates != nil {
					printAnnouncedKeys(updates.Keys)
				}
			}
			return nil
		},
	}
}

// latestVersion reads the manifest at most once a day and remembers the
// answer in the updates file, which no command but this one writes.
func latestVersion(inst *instance.Instance) (string, error) {
	updates, err := inst.LoadUpdates()
	if err != nil {
		return "", err
	}
	if updates != nil && updates.LatestSeen != "" && time.Since(updates.LastCheck) < 24*time.Hour {
		return updates.LatestSeen, nil
	}
	m, err := fetchManifest()
	if err != nil {
		return "", err
	}
	if err := upgrade.CheckManifest(inst, m, flagAllowStale); err != nil {
		return "", err
	}
	return m.Latest().Version, nil
}

func checkCmd() *cobra.Command {
	var version string
	var allowMariaDB, allowLocal bool
	cmd := &cobra.Command{
		Use:   "check",
		Short: "Read the release manifest and say what an upgrade would do",
		RunE: func(cmd *cobra.Command, args []string) error {
			ctx, cancel := signalContext()
			defer cancel()
			runner, state, err := newRunner(version, nil)
			if err != nil {
				return err
			}
			defer runner.Docker.Close()
			runner.Opts.AllowMariaDBUpgrade, runner.Opts.AllowLocalChanges = allowMariaDB, allowLocal
			plan, err := runner.Plan(ctx, state)
			if err != nil {
				return err
			}
			printPlan(plan, runner.Inst)
			return nil
		},
	}
	cmd.Flags().StringVar(&version, "version", "", "release to look at (default the latest)")
	cmd.Flags().BoolVar(&allowMariaDB, "allow-mariadb-upgrade", false, "show what the upgrade would do with a MariaDB series change accepted")
	cmd.Flags().BoolVar(&allowLocal, "allow-local-changes", false, "show what the upgrade would do with the locally edited release files overwritten")
	return cmd
}

// printPlan says what the upgrade would do, service by service: the image
// each container runs today, the image the release pins, and what that
// costs to download.
func printPlan(plan *upgrade.Plan, inst *instance.Instance) {
	fmt.Printf("%-12s %s (%s)\n", "Site", inst.Domain(), inst.Root)
	installed := plan.Current
	if kvs := inst.KVSVersion(); kvs != "" {
		installed += fmt.Sprintf("  KVS %s, PHP %s, IonCube %s", kvs, inst.PHPVersion(), yesNo(inst.IonCube()))
	}
	fmt.Printf("%-12s %s\n", "Installed", installed)
	fmt.Printf("%-12s %d releases, latest %s (%s)\n", "Manifest", len(plan.Manifest.Releases), plan.Manifest.Latest().Version, plan.Manifest.Latest().Date)
	if plan.UpToDate {
		fmt.Printf("%-12s %s, already installed\n", "Target", plan.Target.Version)
		return
	}
	if plan.Downgrade {
		fmt.Printf("%-12s %s\n", "Target", plan.DowngradeMessage())
		return
	}
	fmt.Printf("%-12s %s (%s)\n", "Target", plan.Target.Version, plan.Target.Date)
	if plan.Target.Notes != "" {
		fmt.Printf("%-12s %s\n", "Notes", plan.Target.Notes)
	}
	for n, h := range plan.Target.Highlights {
		label := ""
		if n == 0 && plan.Target.Notes == "" {
			label = "Notes"
		}
		fmt.Printf("%-12s - %s\n", label, h)
	}
	if plan.Target.NotesURL != "" {
		fmt.Printf("%-12s %s\n", "Changelog", plan.Target.NotesURL)
	}
	if len(plan.Services) > 0 {
		fmt.Println()
		printServices(plan.Services)
		fmt.Println()
	}
	fmt.Printf("%-12s %s\n", "Download", downloadSummary(plan))
	if series := plan.Target.Series(); len(series) > 0 {
		fmt.Printf("%-12s release publishes PHP %s, site runs %s\n", "PHP", strings.Join(series, ", "), inst.PHPVersion())
	} else if php := plan.Target.Requires.PHP; php != "" {
		if inst.IonCube() {
			fmt.Printf("%-12s release ships %s, site is encoded for %s\n", "PHP", php, inst.PHPVersion())
		} else {
			fmt.Printf("%-12s release ships %s, site runs %s\n", "PHP", php, inst.PHPVersion())
		}
	}
	if kvsMin := plan.Target.Requires.KVSMin; kvsMin != "" {
		site := inst.KVSVersion()
		if site == "" {
			site = "an unknown version"
		}
		fmt.Printf("%-12s release supports %s and newer, site runs %s\n", "KVS", kvsMin, site)
	}
	if min := plan.Target.Requires.ComposeMin; min != "" {
		have := plan.ComposeVersion
		if have == "" {
			have = "an unknown version"
		}
		fmt.Printf("%-12s release needs Docker Compose %s or newer, this machine has %s\n", "Compose", min, have)
	}
	fmt.Printf("%-12s %s\n", "Database", databaseSummary(plan))
	if plan.OneWay {
		fmt.Printf("%-12s one way: a rollback recreates the MariaDB data directory and replays the backup\n", "Rollback")
	}
	fmt.Printf("%-12s %s\n", "Local files", localFilesSummary(plan))
	if keys := plan.Manifest.Keys; len(keys) > 0 {
		announced := make([]instance.AnnouncedKey, 0, len(keys))
		for _, k := range keys {
			announced = append(announced, instance.AnnouncedKey{ID: k.ID, ValidFrom: k.ValidFrom})
		}
		printAnnouncedKeys(announced)
	}
	if len(plan.Blockers) > 0 {
		fmt.Println("Blocked")
		for _, b := range plan.Blockers {
			fmt.Println("  -", b)
		}
		return
	}
	fmt.Printf("%-12s run 'kvsctl upgrade'\n", "Ready")
}

// printServices is the table of the release: one line per service, what it
// runs now, what the release pins, and what is left to download.
func printServices(services []upgrade.PlanImage) {
	nameW, runW, relW := len("Service"), len("Running"), len("Release")
	for _, s := range services {
		nameW = max(nameW, len(s.Service))
		runW = max(runW, len(displayRef(s.Running)))
		relW = max(relW, len(s.Ref))
	}
	fmt.Printf("%-*s  %-*s  %-*s  %s\n", nameW, "Service", runW, "Running", relW, "Release", "Download")
	for _, s := range services {
		fmt.Printf("%-*s  %-*s  %-*s  %s\n", nameW, s.Service, runW, displayRef(s.Running), relW, s.Ref, downloadCell(s))
	}
}

// printRunning is the same table for status, which knows the containers but
// not the manifest: the image each service runs and how it is doing.
func printRunning(services map[string]dockerx.ServiceImage) {
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
	fmt.Printf("%-*s  %-*s  %s\n", nameW, "Service", runW, "Running", "State")
	for _, name := range names {
		svc := services[name]
		state := svc.State
		if svc.Health != "" {
			state += ", " + svc.Health
		}
		fmt.Printf("%-*s  %-*s  %s\n", nameW, name, runW, displayRef(svc.Image), state)
	}
}

func displayRef(ref string) string {
	if ref == "" {
		return "-"
	}
	return ref
}

// downloadCell is what a service costs: nothing when its container already
// runs the release image, nothing when the engine holds it, the bytes
// otherwise.
func downloadCell(s upgrade.PlanImage) string {
	switch {
	case s.Unchanged:
		return "unchanged"
	case s.OnDisk:
		return "on disk"
	default:
		return upgrade.HumanBytes(s.Bytes)
	}
}

func downloadSummary(plan *upgrade.Plan) string {
	line := fmt.Sprintf("%s over %d images", upgrade.HumanBytes(plan.Bytes), len(plan.ImagesToPull))
	if plan.DiskFree > 0 {
		line = fmt.Sprintf("%-28s free on %s: %s (%s needed)", line, plan.DockerRoot, upgrade.HumanBytes(plan.DiskFree), upgrade.HumanBytes(plan.DiskNeeded))
	}
	return line
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

func localFilesSummary(plan *upgrade.Plan) string {
	if plan.TrackedFiles == 0 {
		return fmt.Sprintf("not checked: no checksum was recorded for %s (run 'kvsctl adopt --force --version %s' to record them)", plan.Current, plan.Current)
	}
	if len(plan.LocalChanges) == 0 {
		matches := "files match"
		if plan.TrackedFiles == 1 {
			matches = "file matches"
		}
		return fmt.Sprintf("%d release %s the %s snapshot", plan.TrackedFiles, matches, plan.Current)
	}
	shown := plan.LocalChanges
	suffix := ""
	if len(shown) > 5 {
		shown, suffix = shown[:5], fmt.Sprintf(" and %d more", len(plan.LocalChanges)-5)
	}
	return fmt.Sprintf("%d of %d changed since %s: %s%s", len(plan.LocalChanges), plan.TrackedFiles, plan.Current, strings.Join(shown, ", "), suffix)
}

func newRunner(version string, reporter upgrade.Reporter) (*upgrade.Runner, *instance.State, error) {
	inst, err := instance.Detect(flagRoot)
	if err != nil {
		return nil, nil, err
	}
	state, err := inst.LoadState()
	if err != nil {
		return nil, nil, err
	}
	keys, err := publicKeys()
	if err != nil {
		return nil, nil, err
	}
	docker, err := dockerx.New()
	if err != nil {
		return nil, nil, err
	}
	runner := &upgrade.Runner{
		Inst:     inst,
		Docker:   docker,
		Reporter: reporter,
		Opts: upgrade.Options{
			Version:            version,
			ManifestURL:        manifestURL(),
			PublicKeys:         keys,
			Yes:                flagYes,
			AllowStaleManifest: flagAllowStale,
		},
	}
	return runner, state, nil
}

func upgradeCmd() *cobra.Command {
	var version string
	var skipBackup, restoreDB, allowMariaDB, allowLocal bool
	var timeout, dbTimeout time.Duration
	var keep int
	cmd := &cobra.Command{
		Use:   "upgrade",
		Short: "Upgrade the stack to the latest release, or to --version",
		RunE: func(cmd *cobra.Command, args []string) error {
			ctx, cancel := signalContext()
			defer cancel()
			runner, state, err := newRunner(version, nil)
			if err != nil {
				return err
			}
			defer runner.Docker.Close()
			unlock, err := runner.Inst.Lock("upgrade")
			if err != nil {
				return err
			}
			defer unlock()
			runner.Opts.SkipBackup, runner.Opts.RestoreDB = skipBackup, restoreDB
			runner.Opts.AllowMariaDBUpgrade, runner.Opts.AllowLocalChanges = allowMariaDB, allowLocal
			runner.Opts.HealthTimeout, runner.Opts.DBTimeout, runner.Opts.KeepBackups = timeout, dbTimeout, keep
			plan, err := runner.Plan(ctx, state)
			if err != nil {
				return err
			}
			if plan.Downgrade {
				return errors.New(plan.DowngradeMessage())
			}
			if plan.UpToDate {
				fmt.Printf("Already on %s.\n", plan.Current)
				return nil
			}
			if len(plan.Blockers) > 0 {
				printPlan(plan, runner.Inst)
				return upgrade.ErrBlocked
			}
			title := fmt.Sprintf("KVS stack · %s · %s → %s", runner.Inst.Domain(), plan.Current, plan.Target.Version)
			return runScreen(ctx, cancel, runner, title, upgrade.UpgradeSteps, func(ctx context.Context) error {
				return runner.Run(ctx, state, plan)
			})
		},
	}
	cmd.Flags().StringVar(&version, "version", "", "release to install (default the latest)")
	cmd.Flags().BoolVar(&skipBackup, "skip-backup", false, "do not back up the database and the configuration first; a failed upgrade then cannot restore the database")
	cmd.Flags().BoolVar(&restoreDB, "restore-db", false, "restore the database backup on a rollback even if the release changed nothing there")
	cmd.Flags().BoolVar(&allowMariaDB, "allow-mariadb-upgrade", false, "accept a release that moves MariaDB to another series: the data files are upgraded in place, the previous server cannot read them again, and only the backup goes back")
	cmd.Flags().BoolVar(&allowLocal, "allow-local-changes", false, "overwrite release files that were edited on this machine since the installed version was laid down")
	cmd.Flags().IntVar(&keep, "keep", 5, "how many backups to keep in backups/; the one taken by this run is never removed")
	cmd.Flags().DurationVar(&timeout, "health-timeout", 2*time.Minute, "how long to wait for the services after the restart")
	cmd.Flags().DurationVar(&dbTimeout, "db-timeout", 30*time.Minute, "how long to wait when MariaDB alone is still starting, which is what an upgrade of its data files looks like")
	return cmd
}

func rollbackCmd() *cobra.Command {
	var restoreDB bool
	cmd := &cobra.Command{
		Use:   "rollback",
		Short: "Return to the previous stack version",
		RunE: func(cmd *cobra.Command, args []string) error {
			ctx, cancel := signalContext()
			defer cancel()
			runner, state, err := newRunner("", nil)
			if err != nil {
				return err
			}
			defer runner.Docker.Close()
			unlock, err := runner.Inst.Lock("rollback")
			if err != nil {
				return err
			}
			defer unlock()
			runner.Opts.RestoreDB = restoreDB
			if state == nil || state.Previous == "" {
				return errors.New("no previous version to return to")
			}
			title := fmt.Sprintf("KVS stack · %s · rollback %s → %s", runner.Inst.Domain(), state.Current, state.Previous)
			return runScreen(ctx, cancel, runner, title, upgrade.RollbackSteps, func(ctx context.Context) error {
				return runner.Rollback(ctx, state)
			})
		},
	}
	cmd.Flags().BoolVar(&restoreDB, "restore-db", false, "replay the newest backup of the previous version even if that release changed nothing in the database")
	return cmd
}

// runScreen runs the action behind the interactive screen, or with plain
// lines when there is no terminal or --plain was given.
func runScreen(ctx context.Context, cancel context.CancelFunc, runner *upgrade.Runner, title string, steps []string, action func(context.Context) error) error {
	if flagPlain || !ui.IsTerminal(os.Stdout) || !ui.IsTerminal(os.Stdin) {
		var in io.Reader
		if ui.IsTerminal(os.Stdin) {
			in = os.Stdin
		}
		plain := ui.NewPlain(os.Stdout, in, flagYes)
		plain.Quiet = flagQuiet
		runner.Reporter = plain
		fmt.Println(title)
		return action(ctx)
	}
	reporter, model := ui.NewTerminal(title, steps, cancel)
	runner.Reporter = reporter
	program := tea.NewProgram(model, tea.WithContext(ctx))
	result := make(chan error, 1)
	go func() {
		err := action(ctx)
		reporter.Close()
		result <- err
	}()
	_, runErr := program.Run()
	// The screen is gone: what the action still reports goes to the
	// terminal as plain lines instead of a channel nobody reads.
	reporter.Detach()
	if runErr != nil && !errors.Is(runErr, tea.ErrProgramKilled) && !errors.Is(runErr, context.Canceled) {
		// The screen died. Stop the action and wait for it: exiting here
		// would kill the process with an upgrade half applied.
		cancel()
		<-result
		return runErr
	}
	return <-result
}

func backupCmd() *cobra.Command {
	var keep int
	cmd := &cobra.Command{
		Use:   "backup",
		Short: "Dump the database and keep the configuration in backups/",
		RunE: func(cmd *cobra.Command, args []string) error {
			ctx, cancel := signalContext()
			defer cancel()
			inst, err := instance.Detect(flagRoot)
			if err != nil {
				return err
			}
			unlock, err := inst.Lock("backup")
			if err != nil {
				return err
			}
			defer unlock()
			state, err := inst.LoadState()
			if err != nil {
				return err
			}
			version := "unknown"
			if state != nil {
				version = state.Current
			}
			result, err := backup.Create(ctx, inst.BackupDir(), version, inst.ContainerPrefix()+"-mariadb", inst.EnvPath, filepath.Join(inst.StateDir(), "state.json"), func(msg string) { fmt.Println(msg) })
			if err != nil {
				return err
			}
			fmt.Printf("%s (%s, %s)\n", result.Path, upgrade.HumanBytes(result.Size), result.Duration.Round(time.Second))
			removed, err := backup.Prune(inst.BackupDir(), keep, result.Path)
			if err != nil {
				return err
			}
			for _, p := range removed {
				fmt.Printf("removed %s\n", filepath.Base(p))
			}
			return nil
		},
	}
	cmd.Flags().IntVar(&keep, "keep", 5, "how many backups to keep in backups/; the one taken by this run is never removed")
	return cmd
}

func adoptCmd() *cobra.Command {
	var version string
	var force bool
	cmd := &cobra.Command{
		Use:   "adopt",
		Short: "Record the version of a stack installed before kvsctl existed",
		RunE: func(cmd *cobra.Command, args []string) error {
			if _, err := semver.Parse(version); err != nil {
				return err
			}
			inst, err := instance.Detect(flagRoot)
			if err != nil {
				return err
			}
			unlock, err := inst.Lock("adopt")
			if err != nil {
				return err
			}
			defer unlock()
			state, err := inst.LoadState()
			if err != nil {
				return err
			}
			if state != nil && !force {
				return fmt.Errorf("this stack is already recorded as %s (use --force to change it)", state.Current)
			}
			files, err := inst.TrackedFiles()
			if err != nil {
				return err
			}
			if err := release.Snapshot(inst.Root, filepath.Join(inst.ReleasesDir(), version), files); err != nil {
				return err
			}
			sums, err := release.Checksums(inst.Root, files)
			if err != nil {
				return err
			}
			newState := &instance.State{Current: version, Files: files, Checksums: sums}
			if state != nil {
				// A repaired record keeps the way back: the previous
				// version, its files and what it did to the database.
				newState.Previous, newState.PreviousFiles = state.Previous, state.PreviousFiles
				newState.Database, newState.History = state.Database, state.History
			}
			newState.History = append(newState.History, instance.Entry{Version: version, Action: "adopt", Date: time.Now()})
			if err := inst.SaveState(newState); err != nil {
				return err
			}
			if err := inst.SetEnv("KVS_STACK_VERSION", version); err != nil {
				return err
			}
			fmt.Printf("%s recorded as stack %s (%d release files kept for rollbacks)\n", inst.Domain(), version, len(files))
			return nil
		},
	}
	cmd.Flags().StringVar(&version, "version", "", "the installed stack version (required)")
	cmd.Flags().BoolVar(&force, "force", false, "replace an existing record, keeping the previous version it points at")
	_ = cmd.MarkFlagRequired("version")
	return cmd
}

func updateCLICmd() *cobra.Command {
	return &cobra.Command{
		Use:   "update-cli",
		Short: "Replace this binary with the one the latest release ships",
		RunE: func(cmd *cobra.Command, args []string) error {
			ctx, cancel := signalContext()
			defer cancel()
			m, err := fetchManifest()
			if err != nil {
				return err
			}
			// A replayed manifest would hand out an older binary, so the
			// same freshness rule as an upgrade applies when this machine
			// holds an installation to compare against.
			if inst, derr := instance.Detect(flagRoot); derr == nil {
				if err := upgrade.CheckManifest(inst, m, flagAllowStale); err != nil {
					return err
				}
			}
			latest := m.Latest()
			asset, ok := latest.CLI[runtime.GOOS+"-"+runtime.GOARCH]
			if !ok {
				return fmt.Errorf("release %s ships no kvsctl for %s/%s", latest.Version, runtime.GOOS, runtime.GOARCH)
			}
			msg, outdated := cliState(latest.Version)
			if !outdated {
				fmt.Println(msg + ", nothing to do")
				return nil
			}
			self, err := os.Executable()
			if err != nil {
				return err
			}
			resolved, err := filepath.EvalSymlinks(self)
			if err != nil {
				return fmt.Errorf("%s: %w", self, err)
			}
			self = resolved
			tmp := self + ".new"
			if err := download(ctx, asset.URL, asset.SHA256, tmp); err != nil {
				return err
			}
			if err := os.Chmod(tmp, 0o755); err != nil {
				return err
			}
			if err := os.Rename(tmp, self); err != nil {
				os.Remove(tmp)
				return err
			}
			fmt.Printf("%s: %s replaced by the build of release %s\n", self, Version, latest.Version)
			return nil
		},
	}
}

func download(ctx context.Context, url, sha, dest string) error {
	if strings.HasPrefix(url, "file://") {
		return release.Download(ctx, url, sha, dest, nil)
	}
	client := &http.Client{Timeout: 5 * time.Minute}
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, url, nil)
	if err != nil {
		return err
	}
	resp, err := client.Do(req)
	if err != nil {
		return err
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		return fmt.Errorf("%s answered %s", url, resp.Status)
	}
	out, err := os.OpenFile(dest, os.O_CREATE|os.O_WRONLY|os.O_TRUNC, 0o755)
	if err != nil {
		return err
	}
	hash := sha256.New()
	if _, err := io.Copy(io.MultiWriter(out, hash), resp.Body); err != nil {
		out.Close()
		return err
	}
	if err := out.Close(); err != nil {
		return err
	}
	if got := hex.EncodeToString(hash.Sum(nil)); got != strings.ToLower(sha) {
		os.Remove(dest)
		return fmt.Errorf("kvsctl checksum mismatch: manifest says %s, download is %s", sha, got)
	}
	return nil
}

func yesNo(b bool) string {
	if b {
		return "yes"
	}
	return "no"
}

func firstLine(s string) string {
	if i := strings.IndexByte(s, '\n'); i >= 0 {
		return s[:i]
	}
	return s
}
