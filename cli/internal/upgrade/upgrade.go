// Package upgrade plans and runs a stack upgrade: signed manifest, checks,
// backup, image pulls, release files, restart, verification and rollback.
//
// Every run that changes the stack, an upgrade or a manual rollback, keeps
// a journal (kvsctl/journal.json) from its first change until it is
// recorded in the state or rolled back. A run cut short by a power cut, a
// kill or a crash leaves it behind, and Recover finishes or undoes that run
// from what it says.
package upgrade

import (
	"context"
	"crypto/ed25519"
	"errors"
	"fmt"
	"maps"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"time"

	"github.com/MaximeMichaud/KVS-install/cli/internal/dockerx"
	"github.com/MaximeMichaud/KVS-install/cli/internal/instance"
	"github.com/MaximeMichaud/KVS-install/cli/internal/manifest"
	"github.com/MaximeMichaud/KVS-install/cli/internal/semver"
)

// Step names, in the order an upgrade runs them.
const (
	StepCheck   = "check"
	StepConfirm = "confirm"
	StepBackup  = "backup"
	StepPull    = "pull"
	StepApply   = "apply"
	StepRestart = "restart"
	StepVerify  = "verify"
	StepRecord  = "record"
	StepRollbck = "rollback"
	// StepRestore replays an archive over the database, the step of a
	// restore and of the recover that finishes one.
	StepRestore = "restore"
)

// UpgradeSteps and RollbackSteps are the steps each action runs, in order,
// for the screen to show what is still to come. A manual rollback backs up
// the live database before it replays an older dump.
var (
	UpgradeSteps  = []string{StepCheck, StepConfirm, StepBackup, StepPull, StepApply, StepRestart, StepVerify}
	RollbackSteps = []string{StepConfirm, StepBackup, StepApply, StepRestart, StepVerify}
)

// RecoverSteps are the steps Recover runs for the run a journal names: a
// restore is finished and its stack verified, a run that passed its
// verification is recorded, and any other is rolled back.
func RecoverSteps(j *instance.Journal) []string {
	switch {
	case j != nil && j.Action == instance.ActionRestore:
		return []string{StepConfirm, StepRestore, StepVerify}
	case j != nil && j.Phase == instance.PhaseRecord:
		return []string{StepConfirm, StepRecord}
	}
	return []string{StepConfirm, StepRollbck}
}

// ReleaseOverride is the compose file a release bundle ships to pin its images.
const ReleaseOverride = "docker-compose.release.yml"

// OverrideFile is the operator's own compose file. Compose loads it next to
// docker-compose.yml on its own, but only while COMPOSE_FILE is unset, so
// every list kvsctl writes has to name it.
const OverrideFile = "docker-compose.override.yml"

// mariadbService is the compose service whose image carries the database.
const mariadbService = "mariadb"

// mariadbDataDir is where the mariadb container keeps its data files.
const mariadbDataDir = "/var/lib/mysql"

// defaultDockerRoot is where the engine keeps its data when it cannot be
// asked.
const defaultDockerRoot = "/var/lib/docker"

// migrates is what a release declares in "database" when it changes the
// schema, which makes a rollback replay the backup.
const migrates = "migrates"

const (
	mib = 1 << 20
	gib = 1 << 30
)

// The errors a run ends with, wrapped so a caller can map them to an exit
// code (kvsctl does, for cron and CI):
//
//	ErrBlocked        the checks refused the release, nothing was touched
//	ErrRolledBack     the upgrade failed and the previous version is back
//	ErrRollbackFailed a rollback failed: the automatic one after a failed
//	                  upgrade, or a manual one part way through; the stack
//	                  is in a state nobody checked
//	ErrStaleManifest  the manifest is older than one already seen
//	ErrNotRecorded    the change succeeded but the state could not be
//	                  written; kvsctl recover records it
//
// They are always wrapped with %w (or through failure), so errors.Is finds
// them behind the sentence the operator reads.
var (
	ErrBlocked        = errors.New("the upgrade is blocked")
	ErrRolledBack     = errors.New("the upgrade failed and the previous version is back")
	ErrRollbackFailed = errors.New("the rollback failed and the stack is in an unknown state")
	ErrStaleManifest  = errors.New("the manifest is older than the one already seen")
	ErrNotRecorded    = errors.New("the change succeeded but could not be recorded")
)

// failure carries the sentence the operator reads, the cause and the
// sentinel that gives the exit code, without repeating the sentinel in the
// message.
type failure struct {
	msg   string
	cause error
	kind  error
}

func (f *failure) Error() string { return f.msg }

// Unwrap exposes both the cause and the sentinel to errors.Is.
func (f *failure) Unwrap() []error {
	if f.cause == nil {
		return []error{f.kind}
	}
	return []error{f.cause, f.kind}
}

// Kind of an event.
type Kind int

// Event kinds.
const (
	KindStepStart Kind = iota
	KindStepDone
	KindStepFail
	KindLog
	KindImage
	KindImages
	KindDone
)

// Event is what the runner tells the reporter.
type Event struct {
	Kind    Kind
	Step    string
	Message string
	// Notice is set on a log line the operator must read even where the
	// progress of the run is left out, under --quiet: what a restore did
	// to .env and what is left to do for the containers to read it, and
	// the services a run stopped that did not start again.
	Notice bool
	// Image events: one image's progress, with the service it belongs
	// to and the versions: the tag the container runs today (From) and
	// the one the release pins (To). Message carries a note instead of a
	// bar for an image that needs no download.
	Image    string
	Service  string
	From     string
	To       string
	Progress dockerx.Progress
	// Images events: the sum over every image.
	Total dockerx.Progress
	// Done events: the outcome.
	Err error
}

// Reporter shows events and asks the questions. Confirm returns false
// when the context ends before the user answers. Event may be called from
// another goroutine than the one running the action (the progress of a
// dump replay), never from two at once.
type Reporter interface {
	Event(Event)
	Confirm(ctx context.Context, question string) bool
}

// Gate is a Reporter that owns the interrupt of the operation, and so
// decides whether a run begins to change the stack: an upgrade asks Begin
// right before it writes its journal, its first change, and stops there
// with nothing changed when the answer is no. Begin says no once the
// operation is interrupted; the interrupt and the answer are one decision,
// so what the Gate says an interrupt does is what the run does. A Reporter
// that is no Gate leaves it to the context.
type Gate interface {
	Begin() bool
}

// KvsctlVersion is the version of the running kvsctl, which the plan holds
// against the kvsctl_min of the releases it installs; package main sets it
// from its build. Options.KvsctlVersion takes its place when set.
var KvsctlVersion string

// Options drive one upgrade, rollback or recovery.
type Options struct {
	// Version to install; empty means the latest stable release, or the
	// release candidate the stack runs when the manifest lists it and no
	// stable release is newer.
	Version string
	// ManifestURL is where the signed release list lives.
	ManifestURL string
	// PublicKeys verify the manifest; one signature by any of them is
	// enough, which is how a key is rotated without a flag day.
	PublicKeys []ed25519.PublicKey
	// Yes skips the confirmation.
	Yes bool
	// SkipBackup skips the database and configuration backup of an
	// upgrade. It is refused when the upgrade is one way.
	SkipBackup bool
	// NoBackup skips the backup a manual rollback takes of the live
	// database before it replays an older dump over it.
	NoBackup bool
	// RestoreDB replays the backup on a rollback even when the release
	// declared no database change.
	RestoreDB bool
	// KeepBackups is how many backups of the instance are kept; the one
	// taken by this run, and the one a manual rollback of the installed
	// version would replay, are never removed.
	KeepBackups int
	// HealthTimeout bounds the wait for the services after a restart.
	HealthTimeout time.Duration
	// DBTimeout bounds the waits on MariaDB alone: its first start on a
	// new image, which upgrades its system tables, and a verification in
	// which the database is the only service not ready. Zero means 30
	// minutes for a MariaDB series change and 10 minutes otherwise.
	DBTimeout time.Duration
	// MariaDBSeries asks to move MariaDB to that series, the next one the
	// target release publishes after the running one. Empty keeps the
	// series the stack runs.
	MariaDBSeries string
	// AllowUnhealthy accepts a stack whose services are not all healthy
	// when the upgrade or the manual rollback begins; its verification then
	// leaves exactly those services out.
	AllowUnhealthy bool
	// AllowLocalChanges accepts release files edited on the machine, which
	// the upgrade overwrites.
	AllowLocalChanges bool
	// AllowStaleManifest accepts a manifest older than one already seen.
	AllowStaleManifest bool
	// LogPath is the log the caller writes the events of the run to. The
	// journal records it, and the messages of a failed run name it.
	LogPath string
	// KvsctlVersion is the version of the running kvsctl, which a release
	// that names a newer kvsctl_min holds back until update-cli has run;
	// empty means the package KvsctlVersion. A version that is not a
	// release one, a dev build, is never held back.
	KvsctlVersion string
}

// Plan is what an upgrade would do.
type Plan struct {
	Current string
	// Previous is the version a rollback returns to.
	Previous string
	Target   *manifest.Release
	Manifest *manifest.Manifest
	// CurrentLabel and PreviousLabel are how the operator reads Current
	// and Previous: the version itself, or the unreleased checkout an
	// adopt recorded as 0.0.0.
	CurrentLabel, PreviousLabel string
	// Blockers explain why the upgrade cannot run, each with what to do.
	Blockers []string
	// Incomplete is set when a blocker stopped the plan before it read the
	// stack: an engine that does not answer or is too old for kvsctl, or a
	// release that needs a newer kvsctl. Only the blockers say anything,
	// the rest of the plan is empty.
	Incomplete bool
	// UpToDate is set when the target is the installed version and the
	// stack already runs the images it would write.
	UpToDate bool
	// Downgrade is set when the target is older than the installed version.
	Downgrade bool
	// Reapply is set when the target is the installed version and the
	// variant images it writes differ from the recorded ones (another PHP
	// series in .env, or a MariaDB series change): the release is applied
	// again with them.
	Reapply bool
	// Releases are the releases the upgrade installs at once, newer than
	// the installed version up to the target, oldest first. The notes of
	// each are shown, and what any of them declares about the database
	// holds for the whole upgrade.
	Releases []manifest.Release
	// Images are the images this instance runs with the target: the ones
	// every instance runs plus the variants of its PHP and MariaDB series.
	Images []manifest.Image
	// PHPSeries is the PHP series the variant images were chosen for,
	// empty when the release publishes one set of images.
	PHPSeries string
	// MariaDBSeries is the MariaDB series the plan installs, and
	// RunningMariaDBSeries the one the stack runs today; they differ only
	// for a series change. Both are empty for a release that pins no
	// MariaDB image.
	MariaDBSeries, RunningMariaDBSeries string
	// ImageEnv is what the release override reads from .env for the
	// variant services, KVS_<SERVICE>_IMAGE to ref@digest.
	ImageEnv map[string]string
	// OneWay is set when the upgrade cannot be undone by restarting the
	// previous images: a rollback recreates the MariaDB data directory
	// and replays the backup.
	OneWay bool
	// ComposeVersion is the compose plugin found, read when the release
	// names a minimum.
	ComposeVersion string
	// Services lists every image of the release, in manifest order, with
	// what the machine runs today.
	Services []PlanImage
	// ImagesToPull lists the images of the active services the instance
	// does not carry yet.
	ImagesToPull []PlanImage
	// Bytes is what the images to pull add up to.
	Bytes int64
	// Database is what the upgrade does to the database: "migrates" means
	// a rollback needs the backup. A MariaDB series change forces it.
	Database string
	// MariaDBUpgrade is set when the upgrade moves MariaDB to another
	// series, which rewrites the data files in place.
	MariaDBUpgrade bool
	// MariaDBImageChanges is set when the mariadb container gets another
	// image (series or patch): the restart then brings MariaDB up alone and
	// waits for it before the rest, so a long upgrade of its system tables
	// never trips the health dependencies of the other services.
	MariaDBImageChanges bool
	// Stops are the versions this instance must install first, in order.
	Stops []string
	// ActiveServices are the services compose runs here, from the files
	// COMPOSE_FILE names and the profiles COMPOSE_PROFILES turns on.
	ActiveServices []string
	// Unhealthy describes what was wrong with the active services when the
	// plan was made: containers not healthy or not running, and services
	// without a container.
	Unhealthy []string
	// Ignored are the services the verification leaves out: the unhealthy
	// ones, accepted with AllowUnhealthy.
	Ignored []string
	// Architecture is the machine the engine runs on, as it reports it.
	Architecture string
	// DockerRoot is the root directory of the engine, where it keeps its
	// images unless the containerd image store keeps their layers under
	// the root of containerd (planDisk reads which).
	DockerRoot string
	// DiskFree is what is free where the pulled layers land, DiskNeeded
	// what the upgrade asks of that filesystem.
	DiskFree, DiskNeeded int64
	// Disk lists every filesystem the upgrade writes to, with what it
	// needs there and what is free.
	Disk []DiskNeed
	// DiskUnknown says, one line each, what could not be measured and why:
	// a need whose filesystem could not be read, where the engine keeps
	// the layers it pulls, or the second copy of the database a one-way
	// rollback writes. It blocks nothing, but the Disk list is short of
	// it: check prints it after the Disk lines, and upgrade before it
	// asks.
	DiskUnknown []string
	// DumpEstimate is the expected size of the backup, zero when it could
	// not be estimated; DumpSource says what it was taken from.
	DumpEstimate int64
	DumpSource   string
	// DatabaseSize is what the tables of the site take, zero when it was
	// not read.
	DatabaseSize int64
	// TrackedFiles is how many release files the snapshot records.
	TrackedFiles int
	// LocalChanges are the release files that no longer match it.
	LocalChanges []string

	// sizeRead is set once DatabaseSize was asked for, and sizeErr is why
	// it could not be read.
	sizeRead bool
	sizeErr  error
	// latest is set when the target is the latest stable release, the
	// default one, rather than a version the operator named.
	latest bool
}

// PlanImage is one image of a release with what the machine holds of it.
type PlanImage struct {
	manifest.Image
	// Bytes is the download size: the layers the engine does not hold.
	Bytes int64
	// Running is the image the container of that service runs now, empty
	// when the service has no container.
	Running string
	// OnDisk is set when the engine already holds the release digest.
	OnDisk bool
	// Unchanged is set when the running container already carries it, so
	// the upgrade does not touch that service.
	Unchanged bool
	// Active is set when compose runs the service here, now or once the
	// files of the target are laid. The image of an inactive service is
	// not pulled: the override pins it by digest, so compose pulls the
	// signed image itself the day the service is turned on.
	Active bool
}

// Downloads are the images of ImagesToPull a pull shows and counts: all
// but the ones the container of their service already runs, which the
// engine holds under another name than the release gives them. Those are
// pulled by their digest all the same, and download no layer.
func (p *Plan) Downloads() []PlanImage {
	var out []PlanImage
	for _, img := range p.ImagesToPull {
		if !img.Unchanged {
			out = append(out, img)
		}
	}
	return out
}

// DiskNeed is what an upgrade needs on one filesystem.
type DiskNeed struct {
	// Paths are the directories measured on that filesystem.
	Paths []string
	// Free is what the filesystem still takes, Needed what the upgrade
	// writes there.
	Free, Needed int64
	// Parts says what Needed is made of.
	Parts []string
}

// Runner performs upgrades and rollbacks of one instance.
type Runner struct {
	Inst     *instance.Instance
	Docker   *dockerx.Client
	Reporter Reporter
	Opts     Options
}

// CheckManifest refuses a manifest of a channel its url does not serve
// (Manifest.CheckChannel), and one older than the newest this instance has
// already read from the same url: the signature covers the bytes, not
// their age, so a stale mirror or a replayed file would freeze a fleet on
// an old version for ever. A newer manifest is remembered, and so is the
// time of the check, which is what spaces the daily update reminder. Each
// url keeps its own record, so a release candidate list read once through
// --manifest never makes the stable one look stale. The record follows the
// stable releases. The version compared and remembered is the latest
// stable release, since a candidate is installed only by name. The list of
// a candidate is held to that version and may raise it, but its date is
// neither compared nor kept: it is signed after the stable list it extends,
// which a mirror may serve again after it.
func CheckManifest(inst *instance.Instance, m *manifest.Manifest, url string, allowStale bool) error {
	if err := m.CheckChannel(url); err != nil {
		return err
	}
	updates, err := inst.LoadUpdates()
	if err != nil {
		return err
	}
	if updates == nil {
		updates = &instance.Updates{}
	}
	record := updates.For(url)
	if semver.IsPrerelease(record.LatestSeen) {
		// A kvsctl before this one remembered the newest release, a
		// candidate included, with the date of its list: neither says
		// anything of the stable lists, and the record starts again.
		record.LatestSeen, record.ManifestUpdated = "", ""
	}
	latest := ""
	if rel := m.LatestStable(); rel != nil {
		latest = rel.Version
	}
	dated := !m.Candidate()
	seen, seenOK := parseUpdated(record.ManifestUpdated)
	updated, updatedOK := parseUpdated(m.Updated)
	older := dated && seenOK && updatedOK && updated.Before(seen)
	lower := latest != "" && record.LatestSeen != "" && semver.Less(latest, record.LatestSeen)
	if (older || lower) && !allowStale {
		when := record.ManifestUpdated
		if when == "" {
			// Only candidate lists were read there: the time of that read.
			when = record.LastCheck.UTC().Format(time.RFC3339)
		}
		return &failure{
			msg:  fmt.Sprintf("manifest is older than the one seen on %s (latest %s): a stale mirror or a replayed file; pass --allow-stale-manifest to accept it", when, record.LatestSeen),
			kind: ErrStaleManifest,
		}
	}
	if dated && updatedOK && (!seenOK || updated.After(seen)) {
		record.ManifestUpdated = m.Updated
	}
	if latest != "" && (record.LatestSeen == "" || semver.Less(record.LatestSeen, latest)) {
		record.LatestSeen = latest
	}
	record.LastCheck = time.Now()
	updates.Keys = nil
	for _, k := range m.Keys {
		updates.Keys = append(updates.Keys, instance.AnnouncedKey{ID: k.ID, ValidFrom: k.ValidFrom})
	}
	return inst.SaveUpdates(updates)
}

func parseUpdated(s string) (time.Time, bool) {
	if s == "" {
		return time.Time{}, false
	}
	t, err := time.Parse(time.RFC3339, s)
	if err != nil {
		return time.Time{}, false
	}
	return t, true
}

// ImageEnvKey is the .env key the release override reads for a variant
// service: KVS_PHP_FPM_IMAGE for php-fpm, KVS_MARIADB_IMAGE for mariadb.
func ImageEnvKey(service string) string {
	return "KVS_" + strings.ToUpper(strings.NewReplacer("-", "_", ".", "_").Replace(service)) + "_IMAGE"
}

// pinsOf names every image of a release the way the engine pulls it,
// ref@digest, which is what clean removes once the version is dropped.
func pinsOf(images []manifest.Image) []string {
	pins := make([]string, 0, len(images))
	for _, img := range images {
		pins = append(pins, img.Ref+"@"+img.Digest)
	}
	return pins
}

// ImageVersion is the version an image reference shows: its tag, "latest"
// when a registry image has none, "local build" for an image compose built
// on the machine (no registry, no tag), "none" for an empty reference.
func ImageVersion(ref string) string {
	if ref == "" {
		return "none"
	}
	if i := strings.IndexByte(ref, '@'); i >= 0 {
		ref = ref[:i]
	}
	slash := strings.LastIndexByte(ref, '/')
	colon := strings.LastIndexByte(ref, ':')
	switch {
	case colon > slash:
		return ref[colon+1:]
	case slash < 0:
		return "local build"
	default:
		return "latest"
	}
}

// imageSeries is the major.minor of an image tag, "" when the tag does not
// start with one (mariadb:11.8.3 gives 11.8, mariadb:lts and mariadb:11
// give nothing). A tag that names a major version alone floats over its
// series, so it says nothing precise enough to choose an image by; the
// version the image declares decides instead.
func imageSeries(ref string) string {
	if ref == "" {
		return ""
	}
	if i := strings.IndexByte(ref, '@'); i >= 0 {
		ref = ref[:i]
	}
	colon := strings.LastIndexByte(ref, ':')
	if colon < 0 || colon < strings.LastIndexByte(ref, '/') {
		return ""
	}
	return versionSeries(strings.TrimPrefix(ref[colon+1:], "v"))
}

// versionSeries is the major.minor a version starts with: 11.8.9 and
// 11.8-ubi give 11.8, 11 and lts give "".
func versionSeries(v string) string {
	parts := strings.SplitN(v, ".", 3)
	if len(parts) < 2 {
		return ""
	}
	major, minor := leadingNumber(parts[0]), leadingNumber(parts[1])
	if major == "" || major != parts[0] || minor == "" {
		return ""
	}
	return major + "." + minor
}

func leadingNumber(s string) string {
	for i := 0; i < len(s); i++ {
		if s[i] < '0' || s[i] > '9' {
			return s[:i]
		}
	}
	return s
}

// patchVersion reads major.minor.patch out of an image tag or a server
// version (11.8.9, 11.8.9-ubi9), "" when it carries no patch number, which
// is the case of a tag that floats over a series (11.8).
func patchVersion(v string) string {
	if i := strings.IndexAny(v, "-+~_"); i >= 0 {
		v = v[:i]
	}
	parts := strings.Split(v, ".")
	if len(parts) != 3 {
		return ""
	}
	for _, p := range parts {
		if p == "" || leadingNumber(p) != p {
			return ""
		}
	}
	return v
}

// lessPatch compares two versions patchVersion accepted, number by number.
func lessPatch(a, b string) bool {
	pa, pb := strings.Split(a, "."), strings.Split(b, ".")
	for i := 0; i < len(pa) && i < len(pb); i++ {
		na, _ := strconv.Atoi(pa[i])
		nb, _ := strconv.Atoi(pb[i])
		if na != nb {
			return na < nb
		}
	}
	return false
}

// sameImages compares the variant images of two sets of .env values; a
// missing map is an empty one. The other settings a run records, the
// MariaDB series a series change writes, follow the images.
func sameImages(a, b map[string]string) bool {
	return maps.Equal(imageKeys(a), imageKeys(b))
}

// copyImages is a copy of a variant env map, nil for an empty one.
func copyImages(m map[string]string) map[string]string {
	if len(m) == 0 {
		return nil
	}
	return maps.Clone(m)
}

func (r *Runner) start(step, msg string) {
	r.event(Event{Kind: KindStepStart, Step: step, Message: msg})
}
func (r *Runner) done(step, msg string) {
	r.event(Event{Kind: KindStepDone, Step: step, Message: msg})
}
func (r *Runner) fail(step, msg string) {
	r.event(Event{Kind: KindStepFail, Step: step, Message: msg})
}
func (r *Runner) log(msg string) { r.event(Event{Kind: KindLog, Message: msg}) }

// notice is log for a line the operator must read even where the progress
// of the run is left out.
func (r *Runner) notice(msg string) { r.event(Event{Kind: KindLog, Message: msg, Notice: true}) }

// failStep marks step failed on err. A step the first Ctrl-C or a SIGTERM
// cut short failed for no reason of its own: its line says it was
// cancelled, and the error of the command the cancel stopped goes to a
// line of the run before it.
func (r *Runner) failStep(step string, err error) {
	if errors.Is(err, context.Canceled) {
		r.log("cancelled: " + errLine(err))
		r.fail(step, "cancelled")
		return
	}
	r.fail(step, errLine(err))
}

// interrupted reports whether err ended a part of the run that is no step
// of its own because the run was cancelled, the stop of the services that
// write for instance. The error of the command the cancel stopped then
// goes to a line of the run, as failStep puts it, and the caller says in
// plain words that the run was interrupted.
func (r *Runner) interrupted(ctx context.Context, err error) bool {
	if ctx.Err() == nil {
		return false
	}
	r.log("cancelled: " + errLine(err))
	return true
}

// event drops the message when there is nobody to show it: check and the
// tests build a runner without a screen.
func (r *Runner) event(e Event) {
	if r.Reporter != nil {
		r.Reporter.Event(e)
	}
}

// logNote is the end of the message of a failed run: where its log is.
func (r *Runner) logNote() string {
	if r.Opts.LogPath == "" {
		return ""
	}
	return "; log: " + r.Opts.LogPath
}

func listFiles(dir string) ([]string, error) {
	var files []string
	err := filepath.Walk(dir, func(path string, info os.FileInfo, err error) error {
		if err != nil {
			return err
		}
		if info.Mode().IsRegular() {
			rel, _ := filepath.Rel(dir, path)
			files = append(files, filepath.ToSlash(rel))
		}
		return nil
	})
	return files, err
}

func relPath(root, path string) string {
	if rel, err := filepath.Rel(root, path); err == nil && !strings.HasPrefix(rel, "..") {
		return rel
	}
	return path
}

func firstLine(s string) string {
	if i := strings.IndexByte(s, '\n'); i >= 0 {
		return s[:i]
	}
	return s
}

// humanBytes formats a size for the screen.
func humanBytes(n int64) string {
	const unit = 1000
	switch {
	case n >= unit*unit*unit:
		return fmt.Sprintf("%.2f GB", float64(n)/(unit*unit*unit))
	case n >= unit*unit:
		return fmt.Sprintf("%.0f MB", float64(n)/(unit*unit))
	case n >= unit:
		return fmt.Sprintf("%.0f kB", float64(n)/unit)
	default:
		return fmt.Sprintf("%d B", n)
	}
}

// HumanBytes is humanBytes for the UI.
func HumanBytes(n int64) string { return humanBytes(n) }
