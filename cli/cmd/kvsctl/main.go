// kvsctl installs, checks, upgrades and rolls back the KVS Docker stack.
package main

import (
	"context"
	"crypto/ed25519"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"os"
	"os/signal"
	"path/filepath"
	"runtime"
	"slices"
	"strings"
	"sync"
	"syscall"
	"time"

	"github.com/spf13/cobra"

	"github.com/MaximeMichaud/KVS-install/cli/internal/backup"
	"github.com/MaximeMichaud/KVS-install/cli/internal/dockerx"
	"github.com/MaximeMichaud/KVS-install/cli/internal/instance"
	"github.com/MaximeMichaud/KVS-install/cli/internal/manifest"
	"github.com/MaximeMichaud/KVS-install/cli/internal/semver"
	"github.com/MaximeMichaud/KVS-install/cli/internal/ui"
	"github.com/MaximeMichaud/KVS-install/cli/internal/upgrade"
)

// Version is set by the build (-ldflags "-X main.Version=...").
var Version = "dev"

// DefaultManifestURL is the signed release list; the lab and tests point
// KVSCTL_MANIFEST_URL or --manifest elsewhere. It is the URL the manifest
// package serves stable releases only from.
const DefaultManifestURL = manifest.DefaultURL

// ReleasePublicKey lists the keys that verify the manifest (Ed25519, base64
// of the raw key, "id=base64" or the key alone, comma separated). One valid
// signature by any of them is enough, so a new key ships in kvsctl before
// it signs. KVSCTL_RELEASE_KEY replaces the whole list for a lab that signs
// with its own key.
var ReleasePublicKey = "KZYznVR68TMpw0wm0G3ASwQkJ6xyj0pQAO7oR4RStjs=" // pragma: allowlist secret

// Exit codes, so a cron job or a CI step can tell what happened without
// reading the output. exitCodes below says the same to the operator.
const (
	exitError          = 1
	exitUsage          = 2
	exitBlocked        = 3
	exitRolledBack     = 4
	exitRollbackFailed = 5
	exitLocked         = 6
	exitStaleManifest  = 7
	exitNotRecorded    = 8
)

// exitCodes ends the help of every command.
const exitCodes = `
Exit codes:
  0  done
  1  an error or a refusal, which may come after part of the change of a
     backup, a clean or an adopt, or after a restore whose database is
     replayed and whose stack is not healthy
  2  the command line is wrong
  3  the upgrade is blocked and nothing was touched ('kvsctl check' says why)
  4  the upgrade failed and the previous version is back and healthy
  5  a rollback failed (the automatic one, or a manual one part way), or a
     restore stopped part way: the stack is in an unknown state, read the log
  6  another kvsctl holds the lock of the installation
  7  the manifest is older than the one already seen
  8  the change succeeded but could not be recorded: run 'kvsctl recover'
`

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
	upgrade.KvsctlVersion = Version
	root := rootCmd()
	if err := root.Execute(); err != nil {
		os.Exit(fail(os.Stderr, err))
	}
}

// fail says on w why the command failed, its last line, and returns the
// exit code. The error of a docker command that wrote nothing on stderr
// leaves a separator before nothing, which goes.
func fail(w io.Writer, err error) int {
	_, _ = fmt.Fprintln(w, "kvsctl:", ui.Clean(err.Error()))
	return exitCode(err)
}

func rootCmd() *cobra.Command {
	root := &cobra.Command{
		Use:   "kvsctl",
		Short: "Upgrade, check and roll back a KVS Docker stack installed by kvs-install",
		Long: "kvsctl upgrades a single-site KVS Docker stack from the signed releases of\n" +
			"github.com/MaximeMichaud/KVS-install: it backs up the database, pulls the\n" +
			"images of the release, lays its files, restarts the stack, checks the\n" +
			"containers and the site, and rolls back by itself when the new version does\n" +
			"not come up. It runs as root on the server of the stack.",
		SilenceUsage:  true,
		SilenceErrors: true,
	}
	root.PersistentFlags().StringVar(&flagRoot, "root", "", "installation directory (default /opt/kvs or $KVS_INSTALL_DIR)")
	root.PersistentFlags().StringVar(&flagManifest, "manifest", "", "release manifest URL (default $KVSCTL_MANIFEST_URL or the project releases)")
	root.PersistentFlags().BoolVarP(&flagYes, "yes", "y", false, "answer yes to every question; without it, a question is answered no unless stdin and stdout are both a terminal")
	root.PersistentFlags().BoolVar(&flagPlain, "plain", false, "print lines instead of the interactive screen")
	root.PersistentFlags().BoolVar(&flagQuiet, "quiet", false, "skip the reminder that a newer stable release exists, and name the log of a run only when it fails; upgrade, rollback and recover then print lines instead of the screen, only their steps, their failures, their questions, each question after what it asks about, and what the operator must act on (services that could not be started again, a .env taken from an archive), and nothing at all for an upgrade with nothing to do; backup, clean, adopt and update-cli print nothing unless they fail or ask, a question after what it asks about, and clean --dry-run its list; restore prints its warnings, its question, what became of .env and its result line; the notice that KVSCTL_RELEASE_KEY replaces the release keys is printed all the same; the other commands print what they print without it")
	root.PersistentFlags().BoolVar(&flagAllowStale, "allow-stale-manifest", false, "accept a manifest older than the newest one already seen (a stale mirror, a replayed file)")
	root.SetFlagErrorFunc(func(_ *cobra.Command, err error) error { return usageError{err} })
	root.SetUsageTemplate(root.UsageTemplate() + exitCodes)
	root.PersistentPostRunE = func(cmd *cobra.Command, _ []string) error {
		remind(cmd)
		return nil
	}
	root.AddCommand(versionCmd(), statusCmd(), checkCmd(), upgradeCmd(), rollbackCmd(), recoverCmd(), backupCmd(), adoptCmd(), updateCLICmd())
	for _, cmd := range extraCommands {
		root.AddCommand(cmd())
	}
	return root
}

// usageError marks a command line kvsctl could not parse, which exits 2.
type usageError struct{ err error }

func (u usageError) Error() string { return u.err.Error() }
func (u usageError) Unwrap() error { return u.err }

// codedError is an error whose exit code the command decided itself: a
// restore that stopped part way leaves the database in an unknown state,
// which is exit 5 like a failed rollback.
type codedError struct {
	code int
	err  error
}

func (c *codedError) Error() string { return c.err.Error() }
func (c *codedError) Unwrap() error { return c.err }

// exitCode maps the errors the commands return to the codes above.
func exitCode(err error) int {
	var locked *instance.LockedError
	var usage usageError
	var coded *codedError
	switch {
	case err == nil:
		return 0
	case errors.As(err, &coded):
		return coded.code
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
	case errors.Is(err, upgrade.ErrNotRecorded):
		return exitNotRecorded
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
	for _, prefix := range []string{"unknown command", "unknown flag", "unknown shorthand flag", "required flag(s)", "invalid argument", "accepts ", "flag needs an argument"} {
		if strings.HasPrefix(msg, prefix) {
			return true
		}
	}
	return false
}

// remind tells the operator, on stderr, that a newer stable release
// exists, and what to run about it. The commands that say it themselves
// are skipped: status has its Updates line, and check its verdict. The
// manifest is read at most once a day, a read that failed is not tried
// again for an hour, and none holds the command longer than reminderWait:
// the reminder is never the command's problem, so a failure is said only
// when this kvsctl cannot read the manifest any more.
func remind(cmd *cobra.Command) {
	if flagQuiet {
		return
	}
	switch cmd.Name() {
	case "upgrade", "update-cli", "version", "help", "completion", "recover", "status", "check":
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
	// The run is over and the guard gave the signals back: manifest.Fetch
	// ends kvsctl at a Ctrl-C, rather than the reminder holding it.
	latest, err := latestRelease(inst, reminderWait, manifest.Fetch)
	if err != nil {
		if strings.Contains(err.Error(), "'kvsctl update-cli'") {
			_, _ = fmt.Fprintln(stderr, "kvsctl: "+firstLine(err.Error()))
		}
		return
	}
	if line := reminder(inst, state, latest); line != "" {
		_, _ = fmt.Fprintln(stderr, line)
	}
}

// reminder is what remind says about latest, "" when the stack runs it or
// a newer one, or when it is older than the git checkout the stack runs,
// which no upgrade takes back.
func reminder(inst *instance.Instance, state *instance.State, latest latestKnown) string {
	if latest.Version == "" || !semver.Less(state.Current, latest.Version) || checkoutAhead(state, latest) {
		return ""
	}
	step, why := upgradeStep(inst, state, latest, "")
	if why == "" {
		return fmt.Sprintf("%s is available, %s", latest.Version, step)
	}
	return fmt.Sprintf("%s is available, %s: %s", latest.Version, step, why)
}

// upgradeStep is what to do about latest, a release newer than the stack.
// Whether 'kvsctl upgrade' would install it is for its plan to say, which
// reads the manifest, the engine, the disk and the release files at the
// moment it runs: the step is 'kvsctl check', which makes that plan and
// ends with the upgrade to run, unless what this kvsctl sees from here has
// to come first. why says what stands in the way, for a line that stands
// alone; status shows the run in progress or interrupted and the last
// upgrade above its Updates line already. first is what a stack none of
// whose services runs needs before anything else: only status, which reads
// the containers, knows of it.
func upgradeStep(inst *instance.Instance, state *instance.State, latest latestKnown, first string) (step, why string) {
	// A release the stack cannot upgrade to directly is reached through
	// the stop the plan names, which is the one to check.
	check, target := kvsctlCommand("check", true), latest.Version
	if stop := firstStop(state.Current, latest); stop != "" {
		check, target = kvsctlCommand("check", true, "--version", shellWord(stop)), stop
	}
	j, live, err := runState(inst)
	switch {
	case err == nil && live != nil:
		return fmt.Sprintf("run '%s' %s", check, onceUnlocked(live)), live.Error()
	case err == nil && j != nil:
		return fmt.Sprintf("run '%s' first", kvsctlCommand("recover", false)), "a run was interrupted"
	case first != "":
		return fmt.Sprintf("%s, then run '%s'", first, check), ""
	}
	if last, ok := lastUndone(state); ok && last.failed() && last.to == target {
		return fmt.Sprintf("run '%s' once the cause is fixed", check), last.String()
	}
	if target != latest.Version {
		return fmt.Sprintf("run '%s' first", check), fmt.Sprintf("%s cannot be installed directly from %s", latest.Version, state.Label(state.Current))
	}
	return fmt.Sprintf("run '%s'", check), ""
}

// kvsctlCommand writes a kvsctl command for the operator to run, with the
// flags this run was given that name the installation and, when manifest
// is set, the release list: without them the command would look at
// another installation, or read another list. args follow, written for a
// shell already.
func kvsctlCommand(sub string, manifest bool, args ...string) string {
	words := []string{"kvsctl", sub}
	if flagRoot != "" {
		words = append(words, "--root", shellWord(flagRoot))
	}
	if manifest {
		if flagManifest != "" {
			words = append(words, "--manifest", shellWord(flagManifest))
		}
		if flagAllowStale {
			words = append(words, "--allow-stale-manifest")
		}
	}
	return strings.Join(append(words, args...), " ")
}

// firstStop is the release a stack on current has to install before
// latest, "" when none: the first of the stops the plan of that upgrade
// names (upgrade.Stops), which block the upgrade that skips them.
func firstStop(current string, latest latestKnown) string {
	if stops := upgrade.Stops(current, latest.Version, latest.MinFrom); len(stops) > 0 {
		return stops[0]
	}
	return ""
}

// reminderWait bounds the manifest read of the reminder, and statusWait
// the one of status, whose Updates line is part of what it was run for.
// Past the wait the read goes on behind and is dropped, and the process
// ends without it.
var (
	reminderWait = 5 * time.Second
	statusWait   = 15 * time.Second
)

// knownFor is how long a read of the manifest answers for the newest
// release, and failureFor how long a read that failed is not tried again.
const (
	knownFor   = 24 * time.Hour
	failureFor = time.Hour
)

// latestKnown is what kvsctl last learned of the newest release of one
// manifest URL, kept in kvsctl/update-check.json.
type latestKnown struct {
	// Read is when the manifest was last read and checked; Version, Date
	// and Commit are the newest release it listed, the date and the
	// commit being what tells a release from the checkout a stack was
	// adopted from.
	Read    time.Time `json:"read,omitzero"`
	Version string    `json:"version,omitempty"`
	Date    string    `json:"date,omitempty"`
	Commit  string    `json:"commit,omitempty"`
	// MinFrom is the oldest version each release that names one upgrades
	// from, which tells the releases a stack has to install on its way.
	MinFrom map[string]string `json:"min_from,omitempty"`
	// Failed is when a read last failed, Error why, and Build the kvsctl
	// that failed it (thisBuild).
	Failed time.Time `json:"failed,omitzero"`
	Error  string    `json:"error,omitempty"`
	Build  string    `json:"build,omitempty"`
}

// updateCheckFile keeps a latestKnown per manifest URL.
const updateCheckFile = "update-check.json"

// thisBuild names this kvsctl for the failures it remembers: its version
// and the manifest schema it reads. Another build reads the manifest
// again, the one update-cli installed above all, which may read what this
// one failed to.
func thisBuild() string { return fmt.Sprintf("%s, schema %d", Version, manifest.Schema) }

// manifestReader reads the signed manifest at a URL: manifest.Fetch, or
// FetchContext with the context of the command.
type manifestReader func(url string) (*manifest.Document, error)

// latestRelease is the latest stable release of the manifest: what a read
// of the last day found, or what read finds now, waiting at most wait. A
// read that failed is remembered for an hour and answers in its place for
// this build, so a manifest server that does not answer costs one wait and
// not one per command. A read an interrupt cut short says nothing of the
// server, and is not remembered.
func latestRelease(inst *instance.Instance, wait time.Duration, read manifestReader) (latestKnown, error) {
	url := manifestURL()
	known := loadLatestKnown(inst)
	seen := known[url]
	if seen == nil {
		seen = &latestKnown{}
		known[url] = seen
	}
	now := time.Now()
	switch {
	// A release candidate kept by a kvsctl older than this rule is no
	// answer: upgrade installs one only when it is named.
	case !semver.IsPrerelease(seen.Version) && within(now, seen.Read, knownFor):
		return *seen, nil
	case within(now, seen.Failed, failureFor) && seen.Build == thisBuild():
		return latestKnown{}, &earlierFailure{at: seen.Failed, msg: seen.Error}
	}
	m, err := readManifest(url, wait, read)
	if errors.Is(err, manifest.ErrInterrupted) {
		return latestKnown{}, err
	}
	if err == nil {
		err = upgrade.CheckManifest(inst, m, url, flagAllowStale)
	}
	if err != nil {
		seen.Failed, seen.Error, seen.Build = now, firstLine(err.Error()), thisBuild()
		saveLatestKnown(inst, known)
		return latestKnown{}, err
	}
	seen.record(m, now)
	saveLatestKnown(inst, known)
	return *seen, nil
}

// within reports whether at lies in the span of length d that ends at now.
// A moment after now, which a clock set back leaves behind, is not in it:
// it would otherwise hold until the clock passed it again.
func within(now, at time.Time, d time.Duration) bool {
	age := now.Sub(at)
	return !at.IsZero() && age >= 0 && age < d
}

// earlierFailure is a read of the manifest that failed within the hour,
// answered in place of a new one.
type earlierFailure struct {
	at  time.Time
	msg string
}

func (e *earlierFailure) Error() string { return e.msg }

// record keeps the latest stable release of m, read at now: a release
// candidate is installed only when it is named, so it is no news. A list
// older than one already read, a stale mirror --allow-stale-manifest let
// through, does not take the latest release back, and a list of release
// candidates only names none.
func (k *latestKnown) record(m *manifest.Manifest, now time.Time) {
	k.Read, k.Failed, k.Error, k.Build = now, time.Time{}, "", ""
	if semver.IsPrerelease(k.Version) {
		// Kept by a kvsctl older than this rule.
		k.Version, k.Date, k.Commit, k.MinFrom = "", "", "", nil
	}
	latest := m.LatestStable()
	if latest == nil || (k.Version != "" && semver.Less(latest.Version, k.Version)) {
		return
	}
	k.Version, k.Date, k.Commit, k.MinFrom = latest.Version, latest.Date, latest.Commit, nil
	for _, r := range m.Releases {
		if r.Requires.MinFrom == "" {
			continue
		}
		if k.MinFrom == nil {
			k.MinFrom = map[string]string{}
		}
		k.MinFrom[r.Version] = r.Requires.MinFrom
	}
}

// rememberManifest keeps what a plan read of the manifest, for the
// reminder and status of the day after check or upgrade.
func rememberManifest(inst *instance.Instance, m *manifest.Manifest) {
	if m == nil || len(m.Releases) == 0 {
		return
	}
	known := loadLatestKnown(inst)
	seen := known[manifestURL()]
	if seen == nil {
		seen = &latestKnown{}
		known[manifestURL()] = seen
	}
	seen.record(m, time.Now())
	saveLatestKnown(inst, known)
}

// readManifest reads the manifest at url with read and checks its
// signature, and gives up after wait.
func readManifest(url string, wait time.Duration, read manifestReader) (*manifest.Manifest, error) {
	keys, err := publicKeys()
	if err != nil {
		return nil, err
	}
	type result struct {
		m   *manifest.Manifest
		err error
	}
	done := make(chan result, 1)
	go func() {
		doc, err := read(url)
		if err == nil {
			err = doc.VerifyAny(keys)
		}
		if err != nil {
			done <- result{err: err}
			return
		}
		done <- result{m: doc.Manifest}
	}()
	timer := time.NewTimer(wait)
	defer timer.Stop()
	select {
	case r := <-done:
		return r.m, r.err
	case <-timer.C:
		return nil, fmt.Errorf("the manifest at %s did not answer within %s", url, wait)
	}
}

// loadLatestKnown reads kvsctl/update-check.json. A file that is missing
// or cannot be read costs a read of the manifest, nothing more.
func loadLatestKnown(inst *instance.Instance) map[string]*latestKnown {
	known := map[string]*latestKnown{}
	data, err := os.ReadFile(filepath.Join(inst.StateDir(), updateCheckFile))
	if err != nil || json.Unmarshal(data, &known) != nil || known == nil {
		return map[string]*latestKnown{}
	}
	return known
}

// saveLatestKnown writes kvsctl/update-check.json whole or not at all; a
// write that fails is dropped, and the next command reads the manifest
// again.
func saveLatestKnown(inst *instance.Instance, known map[string]*latestKnown) {
	data, err := json.MarshalIndent(known, "", "  ")
	if err != nil {
		return
	}
	dir := inst.StateDir()
	f, err := os.CreateTemp(dir, "."+updateCheckFile+".kvsctl*")
	if err != nil {
		return
	}
	_, err = f.Write(data)
	if cerr := f.Close(); err == nil {
		err = cerr
	}
	if err == nil {
		err = os.Rename(f.Name(), filepath.Join(dir, updateCheckFile))
	}
	if err != nil {
		_ = os.Remove(f.Name())
	}
}

// checkoutAhead reports whether the stack runs the git checkout it was
// adopted from and latest was released before that commit: the rule the
// plan blocks such an upgrade by (upgrade.CheckoutAhead).
func checkoutAhead(state *instance.State, latest latestKnown) bool {
	return upgrade.CheckoutAhead(state, latest.Commit, latest.Date)
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

// releaseKeyEnv names the variable that replaces the keys a manifest is
// checked against, for a lab that signs its own manifests.
const releaseKeyEnv = "KVSCTL_RELEASE_KEY"

// stderr is where kvsctl says what is not the output of a command; the
// tests read it.
var stderr io.Writer = os.Stderr

// releaseKeyNotice is what kvsctl says whenever KVSCTL_RELEASE_KEY is set,
// "" otherwise: a manifest is then trusted on keys the build does not
// carry, which an operator must never learn by surprise.
func releaseKeyNotice() string {
	if os.Getenv(releaseKeyEnv) == "" {
		return ""
	}
	return "release keys from " + releaseKeyEnv + ", not the ones this build embeds"
}

// keyNoticeOnce says the notice once per run, the first time the keys are
// read, on stderr; a session also writes it to its log.
var keyNoticeOnce = new(sync.Once)

// publicKeys are the keys a manifest is checked against: the ones this
// build embeds, or the ones KVSCTL_RELEASE_KEY lists instead, which is
// said on stderr.
func publicKeys() ([]ed25519.PublicKey, error) {
	encoded := ReleasePublicKey
	if notice := releaseKeyNotice(); notice != "" {
		encoded = os.Getenv(releaseKeyEnv)
		keyNoticeOnce.Do(func() { _, _ = fmt.Fprintln(stderr, "kvsctl: "+notice) })
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
func printAnnouncedKeys(w io.Writer, keys []instance.AnnouncedKey) {
	known := knownKeyIDs()
	for _, key := range keys {
		if known[key.ID] {
			continue
		}
		from := ""
		if key.ValidFrom != "" {
			from = " from " + key.ValidFrom
		}
		_, _ = fmt.Fprintf(w, "%-12s the manifest announces signing key %s%s, unknown to this kvsctl: run 'kvsctl update-cli' before then\n", "Signing key", key.ID, from)
	}
}

// signalContext is the context of a command that changes nothing: the
// first Ctrl-C stops it.
func signalContext() (context.Context, context.CancelFunc) {
	return signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
}

func versionCmd() *cobra.Command {
	var check bool
	cmd := &cobra.Command{
		Use:   "version",
		Short: "Print the kvsctl version",
		Args:  cobra.NoArgs,
		RunE: func(cmd *cobra.Command, args []string) error {
			_, _ = fmt.Fprintf(stdout, "kvsctl %s (%s/%s)\n", Version, runtime.GOOS, runtime.GOARCH)
			if !check {
				return nil
			}
			// The manifest is read as update-cli reads it, which is what
			// would replace this binary: any later schema, the channel of
			// its URL checked, and a release candidate only when named,
			// which this command never does.
			ctx, cancel := signalContext()
			defer cancel()
			m, err := cliManifest(ctx)
			if ctx.Err() != nil {
				return errors.New("interrupted")
			}
			if err != nil {
				return err
			}
			if m.LatestStable() == nil {
				_, _ = fmt.Fprintf(stdout, "the manifest lists release candidates only (%s is the newest): no stable release ships a kvsctl to compare with\n", m.Latest().Version)
				return nil
			}
			latest, err := cliRelease(m, "")
			if err != nil {
				return err
			}
			if _, err := cliAsset(latest); err != nil {
				_, _ = fmt.Fprintln(stdout, err.Error())
				return nil
			}
			msg, outdated := cliState(latest.Version)
			if outdated {
				msg += ", run 'kvsctl update-cli'"
			}
			_, _ = fmt.Fprintln(stdout, msg)
			return nil
		},
	}
	cmd.Flags().BoolVar(&check, "check", false, "say whether the latest stable release ships a newer kvsctl")
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

// shortCommit is the abbreviation of a commit kvsctl prints.
func shortCommit(commit string) string {
	if len(commit) > 12 {
		return commit[:12]
	}
	return commit
}

// newRunner builds the runner of a command, connected to the engine. It
// reads no key: only the commands that read the manifest need them, and a
// rollback or a recovery must never depend on a release key.
func newRunner(inst *instance.Instance, version string) (*upgrade.Runner, error) {
	docker, err := dockerx.New()
	if err != nil {
		return nil, err
	}
	return &upgrade.Runner{
		Inst:   inst,
		Docker: docker,
		Opts: upgrade.Options{
			Version:            version,
			ManifestURL:        manifestURL(),
			Yes:                flagYes,
			AllowStaleManifest: flagAllowStale,
		},
	}, nil
}

// engineReady asks the engine what it is before a command changes the
// stack, as upgrade.CheckEngine does. An interrupt that cuts the request
// short is no engine that does not answer: the command ends on interrupted,
// which says what the run left, and the log keeps the error of the request.
func (s *session) engineReady(docker *dockerx.Client, interrupted string) error {
	err := upgrade.CheckEngine(s.ctx(), docker)
	switch {
	case err == nil:
		return nil
	case s.ctx().Err() != nil:
		s.log.Printf("cancelled: %s", err)
		return errors.New(interrupted)
	}
	return fmt.Errorf("%w; nothing was changed", err)
}

// planRunner is the runner of a command that plans an upgrade, check and
// upgrade: newRunner with the keys the manifest is checked against.
func planRunner(inst *instance.Instance, version string) (*upgrade.Runner, error) {
	keys, err := publicKeys()
	if err != nil {
		return nil, err
	}
	runner, err := newRunner(inst, version)
	if err != nil {
		return nil, err
	}
	runner.Opts.PublicKeys = keys
	return runner, nil
}

// planUpgrade makes the plan of check and upgrade; the tests stand in for
// the manifest and the engine it reads.
var planUpgrade = (*upgrade.Runner).Plan

// timeouts are the waits of a run that restarts the stack.
type timeouts struct {
	health, db time.Duration
}

func (t *timeouts) flags(cmd *cobra.Command) {
	cmd.Flags().DurationVar(&t.health, "health-timeout", 2*time.Minute, "how long the services may stay unhealthy or stopped after the restart; a service still starting gets the window its health check declares")
	cmd.Flags().DurationVar(&t.db, "db-timeout", 0, "how long MariaDB alone may take to be ready (default 30m when its series changes, 10m otherwise)")
}

func (t *timeouts) set(o *upgrade.Options) {
	o.HealthTimeout, o.DBTimeout = t.health, t.db
}

func upgradeCmd() *cobra.Command {
	var version, mariadbSeries string
	var skipBackup, restoreDB, allowLocal, allowUnhealthy bool
	var waits timeouts
	var keep int
	cmd := &cobra.Command{
		Use:   "upgrade",
		Short: "Upgrade the stack to the latest stable release, or to --version",
		Long: "Upgrade the stack to the latest stable release, or to --version: back up\n" +
			"the database, pull the images, lay the release files, restart, verify,\n" +
			"and roll back by itself when the new version does not come up. The first\n" +
			"Ctrl-C stops the upgrade and rolls back what it changed; a rollback\n" +
			"is never interrupted, and a terminal that goes away does not stop it.",
		Args: cobra.NoArgs,
		RunE: func(cmd *cobra.Command, args []string) error {
			g := newGuard("the upgrade stops, and what it already changed is rolled back", map[string]string{upgrade.StepRollbck: "rollback"})
			s, err := openSession("upgrade", g, sessionOptions{screen: true})
			if err != nil {
				return err
			}
			// Until its journal is written the run has changed nothing:
			// the plan, the backup, the pull and the staging of the
			// release leave the stack as it was. The run asks the guard
			// before it writes that journal, so the guard says so until
			// the run has begun its first change, and not after.
			g.beforeChange("the upgrade stops, and nothing was changed")
			return s.finish(func() error {
				state, err := s.inst.LoadState()
				if err != nil {
					return err
				}
				runner, err := planRunner(s.inst, version)
				if err != nil {
					return err
				}
				defer runner.Docker.Close()
				runner.Opts.SkipBackup, runner.Opts.RestoreDB = skipBackup, restoreDB
				runner.Opts.MariaDBSeries, runner.Opts.AllowLocalChanges = mariadbSeries, allowLocal
				runner.Opts.AllowUnhealthy, runner.Opts.KeepBackups = allowUnhealthy, keep
				waits.set(&runner.Opts)
				// The plan reads the manifest and the stack, which a server
				// slow to answer can make long: the operator is told what
				// the wait is for.
				s.detailf("Planning the upgrade: reading the manifest at %s", manifestURL())
				plan, err := planUpgrade(runner, s.ctx(), state)
				if s.ctx().Err() != nil {
					// An interrupted plan reads as Docker errors and blockers
					// that are not the stack's.
					return errors.New("upgrade interrupted while it was being planned, nothing was changed")
				}
				if err != nil {
					return err
				}
				rememberManifest(s.inst, plan.Manifest)
				switch {
				case plan.Downgrade && version == "":
					// The stack runs a release newer than the latest
					// stable one, a candidate the manifest no longer
					// lists: nothing to do, as for a stack up to date.
					s.detail(plan.DowngradeMessage())
					return nil
				case plan.Downgrade:
					return errors.New(plan.DowngradeMessage())
				case plan.UpToDate:
					// Nothing to do is nothing to say for --quiet: a cron
					// job mails only what needs a look.
					s.detailf("Already on %s, with the images it pins.", state.Label(plan.Current))
					return nil
				case len(plan.Blockers) > 0:
					if flagQuiet {
						printBlockers(s.writer(), plan.Blockers)
					} else {
						printPlan(s.writer(), plan, s.inst, state, planDown(s.ctx(), runner, plan), engineName(runner.Docker))
					}
					return upgrade.ErrBlocked
				}
				title := fmt.Sprintf("KVS stack · %s · %s", s.inst.Domain(), plan.Action())
				return s.runScreen(runner, title, upgrade.UpgradeSteps, func(ctx context.Context) error {
					return runner.Run(ctx, state, plan)
				})
			}())
		},
	}
	cmd.Flags().StringVar(&version, "version", "", "release to install (default the latest stable release, or the release candidate the stack runs when the manifest lists it and no stable release is newer; any other release candidate only when named)")
	cmd.Flags().BoolVar(&skipBackup, "skip-backup", false, "do not back up the database and the configuration first; a failed upgrade then cannot restore the database (refused when the upgrade is one way)")
	cmd.Flags().BoolVar(&restoreDB, "restore-db", false, "replay the backup on a rollback even if the releases change nothing in the database")
	cmd.Flags().StringVar(&mariadbSeries, "mariadb-series", "", "move MariaDB to that series, the next one the release publishes after the one the stack runs: the data files are upgraded in place, the previous server cannot read them again, and a rollback replays the backup")
	cmd.Flags().BoolVar(&allowUnhealthy, "allow-unhealthy", false, "upgrade a stack whose services are not all healthy now, leaving those services out of the verification")
	cmd.Flags().BoolVar(&allowLocal, "allow-local-changes", false, "overwrite release files that were edited on this machine since the installed version was laid down")
	cmd.Flags().IntVar(&keep, "keep", 5, keepHelp)
	waits.flags(cmd)
	return cmd
}

// keepHelp is the --keep of upgrade and backup, which prune by one rule.
const keepHelp = "how many backups to keep in backups/, the newest; the one this run takes and the one a rollback would replay are never removed, and 0 keeps only those"

func rollbackCmd() *cobra.Command {
	var restoreDB, noBackup, allowUnhealthy bool
	var waits timeouts
	cmd := &cobra.Command{
		Use:   "rollback",
		Short: "Return to the previous stack version",
		Long: "Return to the previous stack version, whose release files kvsctl keeps on\n" +
			"the machine; the images of that version the engine no longer holds are\n" +
			"pulled before anything changes. When the installed release changed the\n" +
			"database, or with --restore-db, the archive the upgrade took is replayed\n" +
			"(the newest backup of the previous version when the state names none),\n" +
			"after a backup of the live database unless --no-backup. The services that\n" +
			"write stay stopped while the live database is backed up and the archive\n" +
			"replayed, so the site is down meanwhile. A MariaDB that runs unhealthy or\n" +
			"keeps restarting refuses a rollback that keeps MariaDB as it is,\n" +
			"--allow-unhealthy or not. A rollback that puts back another MariaDB image\n" +
			"or series, or a one-way one, starts MariaDB alone first and goes on,\n" +
			"unless it must back up the live database first: then repair MariaDB, or\n" +
			"pass --no-backup. Once its first change is made, a rollback is never\n" +
			"interrupted.",
		Args: cobra.NoArgs,
		RunE: func(cmd *cobra.Command, args []string) error {
			protected := map[string]string{upgrade.StepApply: "rollback", upgrade.StepRestart: "rollback", upgrade.StepVerify: "rollback"}
			g := newGuard("the rollback stops, unless it has begun changing the stack: it then runs to its end", protected)
			s, err := openSession("rollback", g, sessionOptions{screen: true})
			if err != nil {
				return err
			}
			return s.finish(func() error {
				state, err := s.inst.LoadState()
				if err != nil {
					return err
				}
				if state == nil || state.Previous == "" {
					return errors.New("no previous version to return to")
				}
				runner, err := newRunner(s.inst, "")
				if err != nil {
					return err
				}
				defer runner.Docker.Close()
				if err := s.engineReady(runner.Docker, fmt.Sprintf("rollback interrupted, nothing was changed, the stack is still on %s", state.Label(state.Current))); err != nil {
					return err
				}
				runner.Opts.RestoreDB, runner.Opts.NoBackup, runner.Opts.AllowUnhealthy = restoreDB, noBackup, allowUnhealthy
				waits.set(&runner.Opts)
				title := fmt.Sprintf("KVS stack · %s · rollback %s → %s", s.inst.Domain(), state.Label(state.Current), state.Label(state.Previous))
				return s.runScreen(runner, title, upgrade.RollbackSteps, func(ctx context.Context) error {
					return runner.Rollback(ctx, state)
				})
			}())
		},
	}
	cmd.Flags().BoolVar(&restoreDB, "restore-db", false, "replay the archive of the upgrade even if the installed release changed nothing in the database")
	cmd.Flags().BoolVar(&noBackup, "no-backup", false, "do not back up the live database before the replay: what was written since the archive is then lost")
	cmd.Flags().BoolVar(&allowUnhealthy, "allow-unhealthy", false, "leave out of the verification the services that are unhealthy, restarting or stopped when the rollback begins")
	waits.flags(cmd)
	return cmd
}

func recoverCmd() *cobra.Command {
	var waits timeouts
	cmd := &cobra.Command{
		Use:   "recover",
		Short: "Finish or undo an upgrade, a rollback or a restore that did not end",
		Long: "Finish or undo the run kvsctl/journal.json names: an upgrade, a rollback\n" +
			"or a restore cut short by a power cut, a kill or a crash, or one whose\n" +
			"rollback or record failed. An upgrade or a rollback that passed its\n" +
			"verification is recorded; any other is rolled back to the version it\n" +
			"started from. A restore is finished: its archive is replayed again when\n" +
			"the replay was cut. A run whose rollback failed is told as failed, with\n" +
			"when and why: recover runs that rollback again once the cause is fixed.\n" +
			"While the journal is there, every command but status, version, history,\n" +
			"logs, releases and recover refuses to run.",
		Args: cobra.NoArgs,
		RunE: func(cmd *cobra.Command, args []string) error {
			protected := map[string]string{upgrade.StepRecord: "recovery", upgrade.StepRollbck: "recovery", upgrade.StepRestore: "recovery"}
			g := newGuard("recover stops, unless it has begun changing the stack: it then runs to its end", protected)
			s, err := openSession("recover", g, sessionOptions{recovering: true, screen: true})
			if err != nil {
				return err
			}
			return s.finish(func() error {
				state, err := s.inst.LoadState()
				if err != nil {
					return err
				}
				j, err := s.inst.LoadJournal()
				if err != nil {
					return err
				}
				if j == nil {
					return errors.New("nothing to recover: no run was interrupted")
				}
				runner, err := newRunner(s.inst, "")
				if err != nil {
					return err
				}
				defer runner.Docker.Close()
				// A run that passed its verification is only recorded,
				// which needs no engine; any other is rolled back.
				if j.Phase != instance.PhaseRecord {
					if err := s.engineReady(runner.Docker, "recover interrupted, nothing was changed"); err != nil {
						return err
					}
				}
				waits.set(&runner.Opts)
				title := fmt.Sprintf("KVS stack · %s · recover: %s", s.inst.Domain(), recoverTitle(j, state))
				return s.runScreen(runner, title, upgrade.RecoverSteps(j), func(ctx context.Context) error {
					return runner.Recover(ctx, state)
				})
			}())
		},
	}
	waits.flags(cmd)
	return cmd
}

// recoverTitle names the run recover finishes, in one line: the failure of
// a run that failed, which can be long, is the first line of the run below
// the title, which keeps when it failed.
func recoverTitle(j *instance.Journal, state *instance.State) string {
	what := j.Describe(state)
	if j.Failed.IsZero() {
		return what
	}
	if i := strings.Index(what, " UTC: "); i >= 0 {
		return what[:i+len(" UTC")]
	}
	return what
}

func backupCmd() *cobra.Command {
	var keep int
	cmd := &cobra.Command{
		Use:   "backup",
		Short: "Dump the database and keep the configuration in backups/",
		Args:  cobra.NoArgs,
		RunE: func(cmd *cobra.Command, args []string) error {
			g := newGuard("the backup stops, and an unfinished archive is removed", nil)
			s, err := openSession("backup", g, sessionOptions{})
			if err != nil {
				return err
			}
			return s.finish(runBackup(s, keep))
		},
	}
	cmd.Flags().IntVar(&keep, "keep", 5, keepHelp)
	return cmd
}

// createBackup takes the archive of a backup, and pruneBackups removes the
// older ones; the tests stand in for the database and the directory.
var (
	createBackup = backup.Create
	pruneBackups = backup.Prune
)

// runBackup takes a backup, then keeps the keep newest archives and the
// one a rollback would replay. What it does, its archive included, is the
// progress --quiet leaves to the log: a backup that worked has nothing to
// tell a cron mail. One that stopped part way says what it left.
func runBackup(s *session, keep int) error {
	state, err := s.inst.LoadState()
	if err != nil {
		return err
	}
	version, rollbackArchive := "unknown", ""
	if state != nil {
		version, rollbackArchive = state.Current, state.UpgradeBackup
	}
	result, err := createBackup(s.ctx(), s.inst.BackupDir(), version, s.inst.ContainerPrefix()+"-mariadb", s.inst.EnvPath, filepath.Join(s.inst.StateDir(), "state.json"), s.detail, backup.WithKVSVersion(s.inst.KVSVersion()))
	switch {
	case err != nil && s.ctx().Err() != nil && errors.Is(err, context.Canceled):
		// The error is the one of the dump the interrupt cut short,
		// which says nothing of the outcome, and the unfinished archive
		// is gone: the log keeps the error.
		s.log.Printf("%s", err)
		return errors.New("backup interrupted, no archive was kept")
	case err != nil:
		// Any other failure says what it left, an archive written whose
		// directory could not be flushed included, interrupt or not.
		return err
	case s.ctx().Err() != nil:
		// The interrupt came once the archive was complete, which stays;
		// the stop it asked for leaves the older archives alone.
		return fmt.Errorf("backup interrupted once %s was written: the archive is kept, and the older backups were not pruned", result.Path)
	}
	s.detailf("%s (%s, %s)", result.Path, upgrade.HumanBytes(result.Size), result.Duration.Round(time.Second))
	// The archive a manual rollback of the installed version replays
	// stays whatever its age.
	removed, err := pruneBackups(s.inst.BackupDir(), keep, result.Path, rollbackArchive)
	for _, p := range removed {
		s.detailf("removed %s", filepath.Base(p))
	}
	if err != nil {
		// Exit 1 after a change: the message says what is on the disk
		// now, which --quiet printed nothing of.
		gone := ""
		if len(removed) > 0 {
			gone = fmt.Sprintf(" after %d of them %s removed", len(removed), plural(len(removed), "was", "were"))
		}
		return fmt.Errorf("%s is written, but removing the older backups failed%s: %w", result.Path, gone, err)
	}
	return nil
}

// writer is where a session prints a block of lines: stdout, and the log
// line by line.
func (s *session) writer() io.Writer { return &lineSink{say: s.say} }

// lineSink hands every complete line written to it to say; the block
// printers of kvsctl only write whole lines.
type lineSink struct {
	say  func(string)
	part []byte
}

func (l *lineSink) Write(p []byte) (int, error) {
	l.part = append(l.part, p...)
	for {
		i := slices.Index(l.part, '\n')
		if i < 0 {
			return len(p), nil
		}
		l.say(string(l.part[:i]))
		l.part = l.part[i+1:]
	}
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
