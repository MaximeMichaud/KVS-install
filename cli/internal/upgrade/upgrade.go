// Package upgrade plans and runs a stack upgrade: signed manifest, checks,
// backup, image pulls, release files, restart, verification and rollback.
package upgrade

import (
	"context"
	"crypto/ed25519"
	"crypto/tls"
	"errors"
	"fmt"
	"maps"
	"net"
	"net/http"
	"net/url"
	"os"
	"os/exec"
	"path/filepath"
	"slices"
	"strings"
	"time"

	"github.com/MaximeMichaud/KVS-install/cli/internal/backup"
	"github.com/MaximeMichaud/KVS-install/cli/internal/diskspace"
	"github.com/MaximeMichaud/KVS-install/cli/internal/dockerx"
	"github.com/MaximeMichaud/KVS-install/cli/internal/instance"
	"github.com/MaximeMichaud/KVS-install/cli/internal/manifest"
	"github.com/MaximeMichaud/KVS-install/cli/internal/release"
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
	StepRollbck = "rollback"
)

// UpgradeSteps and RollbackSteps are the steps each action runs, in order,
// for the screen to show what is still to come.
var (
	UpgradeSteps  = []string{StepCheck, StepConfirm, StepBackup, StepPull, StepApply, StepRestart, StepVerify}
	RollbackSteps = []string{StepConfirm, StepApply, StepRestart, StepVerify}
)

// ReleaseOverride is the compose file a release bundle ships to pin its images.
const ReleaseOverride = "docker-compose.release.yml"

// OverrideFile is the operator's own compose file. Compose loads it next to
// docker-compose.yml on its own, but only while COMPOSE_FILE is unset, so
// every list kvsctl writes has to name it.
const OverrideFile = "docker-compose.override.yml"

// mariadbService is the compose service whose image carries the database.
const mariadbService = "mariadb"

// defaultDockerRoot is where the engine keeps its data when it cannot be
// asked.
const defaultDockerRoot = "/var/lib/docker"

const (
	mib = 1 << 20
	gib = 1 << 30
)

// The errors an upgrade ends with, wrapped so a caller can map them to an
// exit code (kvsctl does, for cron and CI):
//
//	ErrBlocked        the checks refused the release, nothing was touched
//	ErrRolledBack     the upgrade failed and the previous version is back
//	ErrRollbackFailed the upgrade failed and the rollback failed too
//	ErrStaleManifest  the manifest is older than one already seen
//
// They are always wrapped with %w (or through failure), so errors.Is finds
// them behind the sentence the operator reads.
var (
	ErrBlocked        = errors.New("the upgrade is blocked")
	ErrRolledBack     = errors.New("the upgrade failed and the previous version is back")
	ErrRollbackFailed = errors.New("the upgrade failed and the rollback failed too")
	ErrStaleManifest  = errors.New("the manifest is older than the one already seen")
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
// when the context ends before the user answers.
type Reporter interface {
	Event(Event)
	Confirm(ctx context.Context, question string) bool
}

// Options drive one upgrade.
type Options struct {
	// Version to install; empty means the latest.
	Version string
	// ManifestURL is where the signed release list lives.
	ManifestURL string
	// PublicKeys verify the manifest; one signature by any of them is
	// enough, which is how a key is rotated without a flag day.
	PublicKeys []ed25519.PublicKey
	// Yes skips the confirmation.
	Yes bool
	// SkipBackup skips the database and configuration backup.
	SkipBackup bool
	// RestoreDB replays the backup on a rollback even when the release
	// declared no database change.
	RestoreDB bool
	// KeepBackups is how many backups of the instance are kept; the one
	// taken by this run is never removed.
	KeepBackups int
	// HealthTimeout bounds the wait for the services after a restart.
	HealthTimeout time.Duration
	// DBTimeout bounds the wait when the only service still starting is
	// MariaDB upgrading its data files.
	DBTimeout time.Duration
	// AllowMariaDBUpgrade accepts a release that changes the MariaDB
	// series, which rewrites the data files for good.
	AllowMariaDBUpgrade bool
	// AllowLocalChanges accepts release files edited on the machine, which
	// the upgrade overwrites.
	AllowLocalChanges bool
	// AllowStaleManifest accepts a manifest older than one already seen.
	AllowStaleManifest bool
}

// Plan is what an upgrade would do.
type Plan struct {
	Current string
	// Previous is the version a rollback returns to.
	Previous string
	Target   *manifest.Release
	Manifest *manifest.Manifest
	// Blockers explain why the upgrade cannot run.
	Blockers []string
	// UpToDate is set when the target is the installed version.
	UpToDate bool
	// Downgrade is set when the target is older than the installed version.
	Downgrade bool
	// Images are the images this instance pulls: the ones every instance
	// runs plus the variant of its PHP series.
	Images []manifest.Image
	// PHPSeries is the series the variant images were chosen for, empty
	// when the release publishes one set of images.
	PHPSeries string
	// ImageEnv is what the release override reads from .env for the
	// variant services, KVS_<SERVICE>_IMAGE to ref@digest.
	ImageEnv map[string]string
	// OneWay is set when the release cannot be undone by restarting the
	// previous images: a rollback recreates the MariaDB data directory
	// and replays the backup.
	OneWay bool
	// ComposeVersion is the compose plugin found, read when the release
	// names a minimum.
	ComposeVersion string
	// Services lists every image of the release, in manifest order, with
	// what the machine runs today.
	Services []PlanImage
	// ImagesToPull lists the images the instance does not carry yet.
	ImagesToPull []PlanImage
	// Bytes is what the images to pull add up to.
	Bytes int64
	// Database is what the release does to the database: "migrates" means
	// a rollback needs the backup. A MariaDB series change forces it.
	Database string
	// MariaDBUpgrade is set when the release changes the MariaDB series,
	// which rewrites the data files in place.
	MariaDBUpgrade bool
	// Stops are the versions this instance must install first, in order.
	Stops []string
	// DockerRoot is where the engine keeps its images.
	DockerRoot string
	// DiskFree is what is free there, DiskNeeded what the pull asks for.
	DiskFree, DiskNeeded int64
	// TrackedFiles is how many release files the snapshot records.
	TrackedFiles int
	// LocalChanges are the release files that no longer match it.
	LocalChanges []string
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
}

// Runner performs upgrades and rollbacks of one instance.
type Runner struct {
	Inst     *instance.Instance
	Docker   *dockerx.Client
	Reporter Reporter
	Opts     Options
}

// CheckManifest refuses a manifest older than the newest one this instance
// has already seen: the signature covers the bytes, not their age, so a
// stale mirror or a replayed file would freeze a fleet on an old version
// for ever. A newer manifest is remembered, and so is the time of the
// check, which is what spaces the daily update reminder.
func CheckManifest(inst *instance.Instance, m *manifest.Manifest, allowStale bool) error {
	updates, err := inst.LoadUpdates()
	if err != nil {
		return err
	}
	if updates == nil {
		updates = &instance.Updates{}
	}
	latest := m.Latest().Version
	seen, seenOK := parseUpdated(updates.ManifestUpdated)
	updated, updatedOK := parseUpdated(m.Updated)
	older := seenOK && updatedOK && updated.Before(seen)
	lower := updates.LatestSeen != "" && semver.Less(latest, updates.LatestSeen)
	if (older || lower) && !allowStale {
		return &failure{
			msg:  fmt.Sprintf("manifest is older than the one seen on %s (latest %s): a stale mirror or a replayed file; pass --allow-stale-manifest to accept it", updates.ManifestUpdated, updates.LatestSeen),
			kind: ErrStaleManifest,
		}
	}
	if updatedOK && (!seenOK || updated.After(seen)) {
		updates.ManifestUpdated = m.Updated
	}
	if updates.LatestSeen == "" || semver.Less(updates.LatestSeen, latest) {
		updates.LatestSeen = latest
	}
	updates.LastCheck = time.Now()
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

// Plan reads the manifest and decides what the upgrade would do.
func (r *Runner) Plan(ctx context.Context, state *instance.State) (*Plan, error) {
	if state == nil || state.Current == "" {
		return nil, errors.New("this stack has no recorded version: run 'kvsctl adopt --version <installed version>' once")
	}
	doc, err := manifest.Fetch(r.Opts.ManifestURL)
	if err != nil {
		return nil, err
	}
	if err := doc.VerifyAny(r.Opts.PublicKeys); err != nil {
		return nil, err
	}
	m := doc.Manifest
	if err := CheckManifest(r.Inst, m, r.Opts.AllowStaleManifest); err != nil {
		return nil, err
	}
	plan := &Plan{Current: state.Current, Previous: state.Previous, Manifest: m}
	if r.Opts.Version == "" {
		plan.Target = m.Latest()
	} else {
		plan.Target = m.Find(r.Opts.Version)
		if plan.Target == nil {
			return nil, fmt.Errorf("version %s is not in the manifest", r.Opts.Version)
		}
	}
	plan.Database = plan.Target.Database
	switch {
	case plan.Target.Version == plan.Current:
		plan.UpToDate = true
		return plan, nil
	case semver.Less(plan.Target.Version, plan.Current):
		plan.Downgrade = true
		return plan, nil
	}
	r.planJumps(plan, m)
	r.planImages(plan)
	if php := plan.Target.Requires.PHP; plan.PHPSeries == "" && php != "" && r.Inst.IonCube() && php != r.Inst.PHPVersion() {
		plan.Blockers = append(plan.Blockers, fmt.Sprintf("%s runs PHP %s and this site is IonCube encoded for PHP %s: a KVS archive encoded for PHP %s is needed first", plan.Target.Version, php, r.Inst.PHPVersion(), php))
	}
	r.planCompose(ctx, plan)
	if kvsMin := plan.Target.Requires.KVSMin; kvsMin != "" {
		if kvs := r.Inst.KVSVersion(); kvs != "" && semver.Less(kvs, kvsMin) {
			plan.Blockers = append(plan.Blockers, fmt.Sprintf("%s supports KVS %s and newer, this site runs KVS %s", plan.Target.Version, kvsMin, kvs))
		}
	}
	running, _ := r.Docker.ServiceImages(ctx, r.Inst.ProjectName())
	local, _ := r.Docker.LocalDiffIDs(ctx)
	for _, img := range plan.Images {
		item := PlanImage{Image: img}
		if svc, ok := running[img.Service]; ok {
			item.Running = svc.Image
			for _, d := range svc.Digests {
				if strings.HasSuffix(d, "@"+img.Digest) {
					item.Unchanged = true
				}
			}
		}
		has, err := r.Docker.HasDigest(ctx, img.Ref, img.Digest)
		item.OnDisk = err == nil && has
		if !item.OnDisk {
			item.Bytes = missingBytes(img, local)
			plan.ImagesToPull = append(plan.ImagesToPull, item)
			plan.Bytes += item.Bytes
		}
		plan.Services = append(plan.Services, item)
	}
	if err := r.planMariaDB(plan, running); err != nil {
		return nil, err
	}
	if plan.Target.OneWay {
		if r.Opts.SkipBackup {
			return nil, fmt.Errorf("--skip-backup cannot be used with %s: it cannot be undone by restarting the previous images, only by replaying the backup", plan.Target.Version)
		}
		plan.OneWay = true
		r.Opts.RestoreDB = true
	}
	r.planLocalChanges(plan, state)
	r.planDisk(ctx, plan)
	return plan, nil
}

// planImages picks the images this instance pulls. A release that publishes
// its PHP images per series needs the series of the site, and refuses a
// series it has no image for; the variant images are also what .env has to
// carry for the release override.
func (r *Runner) planImages(plan *Plan) {
	target := plan.Target
	series := ""
	if len(target.Series()) > 0 {
		series = r.Inst.PHPVersion()
	}
	images, err := target.ImagesFor(series)
	if err != nil {
		plan.Blockers = append(plan.Blockers, err.Error())
		images = append([]manifest.Image(nil), target.Images...)
	} else if series != "" {
		plan.PHPSeries = series
		plan.ImageEnv = map[string]string{}
		for _, img := range target.Variants[manifest.VariantPHP][series] {
			plan.ImageEnv[ImageEnvKey(img.Service)] = img.Ref + "@" + img.Digest
		}
	}
	plan.Images = images
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

// ImageEnvKey is the .env key the release override reads for a variant
// service: KVS_PHP_FPM_IMAGE for php-fpm.
func ImageEnvKey(service string) string {
	return "KVS_" + strings.ToUpper(strings.NewReplacer("-", "_", ".", "_").Replace(service)) + "_IMAGE"
}

// planCompose checks the compose plugin against the minimum the release
// names: its override uses "build: !reset null", which an older compose
// reads as a build to run. A version that does not parse is shown, not
// held against the machine.
func (r *Runner) planCompose(ctx context.Context, plan *Plan) {
	min := plan.Target.Requires.ComposeMin
	if min == "" {
		return
	}
	v, err := dockerx.ComposeVersion(ctx)
	if err != nil {
		plan.Blockers = append(plan.Blockers, fmt.Sprintf("%s needs Docker Compose %s or newer and the installed one could not be read: %s", plan.Target.Version, min, firstLine(err.Error())))
		return
	}
	plan.ComposeVersion = v
	if _, perr := semver.Parse(v); perr == nil && semver.Less(v, min) {
		plan.Blockers = append(plan.Blockers, fmt.Sprintf("%s needs Docker Compose %s or newer, this machine has %s", plan.Target.Version, min, v))
	}
}

// planJumps collects every mandatory stop between the installed version and
// the target, not only the first one, so the operator is told the whole
// chain instead of discovering it one refusal at a time.
func (r *Runner) planJumps(plan *Plan, m *manifest.Manifest) {
	from := plan.Current
	for _, step := range m.Between(plan.Current, plan.Target.Version) {
		if min := step.Requires.MinFrom; min != "" && semver.Less(from, min) {
			plan.Stops = append(plan.Stops, min)
			from = min
		}
	}
	if len(plan.Stops) == 0 {
		return
	}
	chain := append([]string{plan.Current}, plan.Stops...)
	chain = append(chain, plan.Target.Version)
	plan.Blockers = append(plan.Blockers, fmt.Sprintf("%s cannot be installed directly from %s: go through %s (kvsctl upgrade --version %s first)", plan.Target.Version, plan.Current, strings.Join(chain, " -> "), plan.Stops[0]))
}

// planMariaDB refuses a release that moves MariaDB to another series: the
// server upgrades its data files in place and an older server cannot open
// them again, so the previous images are no way back. With the flag, the
// backup becomes mandatory and the rollback replays it.
func (r *Runner) planMariaDB(plan *Plan, running map[string]dockerx.ServiceImage) error {
	var want string
	for _, img := range plan.Images {
		if img.Service == mariadbService {
			want = imageSeries(img.Ref)
		}
	}
	if want == "" {
		return nil
	}
	have := imageSeries(running[mariadbService].Image)
	if have == "" || have == want {
		return nil
	}
	if from := plan.Target.Requires.MariaDBFrom; len(from) > 0 && !slices.Contains(from, have) {
		plan.Blockers = append(plan.Blockers, fmt.Sprintf("%s ships MariaDB %s, which upgrades the data files of MariaDB %s, and this stack runs %s: MariaDB moves one series at a time, install a release in between", plan.Target.Version, want, strings.Join(from, " or "), have))
		return nil
	}
	plan.MariaDBUpgrade = true
	if !r.Opts.AllowMariaDBUpgrade {
		plan.Blockers = append(plan.Blockers, fmt.Sprintf("%s runs MariaDB %s and this stack runs %s: the data files are upgraded in place and MariaDB %s cannot open them again, so the only way back is the backup; pass --allow-mariadb-upgrade to accept it", plan.Target.Version, want, have, have))
		return nil
	}
	if r.Opts.SkipBackup {
		return fmt.Errorf("--skip-backup cannot be used with --allow-mariadb-upgrade: the backup is the only way back from the MariaDB %s to %s upgrade", have, want)
	}
	// The data files are rewritten and the previous image cannot open them
	// again, so a rollback recreates the data directory and restores.
	r.Opts.RestoreDB = true
	plan.Database = "migrates"
	plan.OneWay = true
	return nil
}

// planLocalChanges compares the release files with the checksums taken when
// the version was installed: an upgrade overwrites them without a word
// otherwise, and a hand patched nginx template is exactly what an operator
// expects to keep.
func (r *Runner) planLocalChanges(plan *Plan, state *instance.State) {
	if len(state.Checksums) == 0 {
		return
	}
	plan.TrackedFiles = len(state.Checksums)
	changed, err := release.Verify(r.Inst.Root, state.Checksums)
	plan.LocalChanges = changed
	if r.Opts.AllowLocalChanges {
		return
	}
	if err != nil {
		plan.Blockers = append(plan.Blockers, fmt.Sprintf("the release files of %s could not be checked (%v): pass --allow-local-changes to upgrade anyway", plan.Current, err))
		return
	}
	if len(changed) == 0 {
		return
	}
	shown := changed
	suffix := ""
	if len(shown) > 5 {
		shown, suffix = shown[:5], fmt.Sprintf(" and %d more", len(changed)-5)
	}
	changedWord := "release files changed"
	if len(changed) == 1 {
		changedWord = "release file changed"
	}
	plan.Blockers = append(plan.Blockers, fmt.Sprintf("%d %s since %s was installed (%s%s): the upgrade would overwrite them; copy them aside, or pass --allow-local-changes", len(changed), changedWord, plan.Current, strings.Join(shown, ", "), suffix))
}

// planDisk measures what the pull needs. The factor covers the layers once
// compressed and once unpacked, plus room for the engine to work in.
func (r *Runner) planDisk(ctx context.Context, plan *Plan) {
	plan.DockerRoot = dockerRoot(ctx)
	plan.DiskNeeded = plan.Bytes*2 + gib
	if free, err := diskspace.Avail(plan.DockerRoot); err == nil {
		plan.DiskFree = free
		if free < plan.DiskNeeded {
			plan.Blockers = append(plan.Blockers, fmt.Sprintf("%s free on %s is not enough to pull %s of images: %s are needed", humanBytes(free), plan.DockerRoot, humanBytes(plan.Bytes), humanBytes(plan.DiskNeeded)))
		}
	}
	needed := plan.Target.Bundle.Size*3 + 200*mib
	if free, err := diskspace.Avail(r.Inst.StateDir()); err == nil && free < needed {
		plan.Blockers = append(plan.Blockers, fmt.Sprintf("%s free on %s is not enough for the bundle, the files it unpacks to and the backup: %s are needed", humanBytes(free), r.Inst.StateDir(), humanBytes(needed)))
	}
}

// dockerRoot is where the engine stores images. The engine answers it, and
// the usual place stands in when it cannot be reached: a wrong guess only
// measures the wrong filesystem, it never stops an upgrade by itself.
func dockerRoot(ctx context.Context) string {
	cmd := exec.CommandContext(ctx, "docker", "info", "--format", "{{.DockerRootDir}}")
	out, err := cmd.Output()
	if err == nil {
		if dir := strings.TrimSpace(string(out)); dir != "" {
			return dir
		}
	}
	return defaultDockerRoot
}

// imageSeries is the major.minor of an image tag, "" when the tag is not a
// version at all (mariadb:11.8.3 gives 11.8, mariadb:lts gives nothing).
// A tag with a single number gives that number, so 11 and 11.8 read as
// different series: a needless question beats a silent major upgrade.
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
	parts := strings.Split(strings.TrimPrefix(ref[colon+1:], "v"), ".")
	major := leadingNumber(parts[0])
	if major == "" {
		return ""
	}
	if len(parts) == 1 {
		return major
	}
	minor := leadingNumber(parts[1])
	if minor == "" {
		return major
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

// missingBytes is the download size of an image: the compressed size of
// the layers the engine does not hold, or the whole image when the manifest
// lists no layers or the engine could not be asked.
func missingBytes(img manifest.Image, local map[string]bool) int64 {
	if len(img.Layers) == 0 || local == nil {
		return img.Size
	}
	var n int64
	for _, l := range img.Layers {
		if !local[l.DiffID] {
			n += l.Size
		}
	}
	return n
}

// DowngradeMessage says what to do about a target older than the installed
// version, which is a rollback and not an upgrade.
func (p *Plan) DowngradeMessage() string {
	if p.Previous == "" {
		return fmt.Sprintf("%s is older than the installed %s: use 'kvsctl rollback' (no previous version is recorded)", p.Target.Version, p.Current)
	}
	return fmt.Sprintf("%s is older than the installed %s: use 'kvsctl rollback' (previous is %s)", p.Target.Version, p.Current, p.Previous)
}

// Run performs the planned upgrade.
func (r *Runner) Run(ctx context.Context, state *instance.State, plan *Plan) (err error) {
	if len(plan.Blockers) > 0 {
		return &failure{msg: "upgrade blocked: " + strings.Join(plan.Blockers, "; "), kind: ErrBlocked}
	}
	target := plan.Target
	// applied says release files were laid over the installation, restarted
	// that compose was asked to recreate the containers. They decide what a
	// rollback has to undo, and in particular whether the database may be
	// replayed over a site nothing ever touched.
	var applied, restarted bool
	defer func() {
		r.Reporter.Event(Event{Kind: KindDone, Err: err})
	}()
	r.start(StepCheck, "manifest")
	r.done(StepCheck, fmt.Sprintf("%s available, manifest signature verified", target.Version))
	r.announceImages(plan)
	if target.Notes != "" {
		r.log(target.Version + ": " + target.Notes)
	}
	for _, h := range target.Highlights {
		r.log("  - " + h)
	}
	if target.NotesURL != "" {
		r.log("release notes: " + target.NotesURL)
	}
	if plan.OneWay {
		r.log("this release is one way: a rollback recreates the MariaDB data directory and replays the backup")
	}

	if !r.Opts.Yes {
		r.start(StepConfirm, fmt.Sprintf("Upgrade %s from %s to %s?", r.Inst.Domain(), plan.Current, target.Version))
		if !r.Reporter.Confirm(ctx, fmt.Sprintf("Upgrade to %s (%s to download)?", target.Version, humanBytes(plan.Bytes))) {
			r.fail(StepConfirm, "cancelled")
			return errors.New("upgrade cancelled")
		}
		r.done(StepConfirm, "yes")
	}

	var backupPath string
	if r.Opts.SkipBackup {
		r.start(StepBackup, "skipped (--skip-backup)")
		r.done(StepBackup, "skipped")
	} else {
		r.start(StepBackup, "database and configuration")
		result, err := backup.Create(ctx, r.Inst.BackupDir(), plan.Current, r.Inst.ContainerPrefix()+"-mariadb", r.Inst.EnvPath, filepath.Join(r.Inst.StateDir(), "state.json"), func(msg string) { r.log(msg) })
		if err != nil {
			r.fail(StepBackup, err.Error())
			return fmt.Errorf("backup: %w", err)
		}
		backupPath = result.Path
		r.prune(backupPath)
		r.done(StepBackup, fmt.Sprintf("%s (%s, %s)", relPath(r.Inst.Root, result.Path), humanBytes(result.Size), result.Duration.Round(time.Second)))
	}

	if len(plan.ImagesToPull) == 0 {
		r.start(StepPull, "every image is already on this machine")
	} else {
		r.start(StepPull, fmt.Sprintf("%d images, %s to download", len(plan.ImagesToPull), humanBytes(plan.Bytes)))
	}
	if err := r.Pull(ctx, plan); err != nil {
		r.fail(StepPull, err.Error())
		return err
	}
	r.done(StepPull, fmt.Sprintf("%d images ready", len(plan.Images)))

	r.start(StepApply, fmt.Sprintf("release files of %s", target.Version))
	files, touched, err := r.apply(ctx, state, plan)
	applied = touched
	if err != nil {
		r.fail(StepApply, err.Error())
		return r.failed(state, plan, backupPath, applied, restarted, err)
	}
	r.done(StepApply, fmt.Sprintf("%d files", len(files)))

	r.start(StepRestart, "docker compose up")
	// A compose run that fails may still have recreated part of the
	// project, so the rollback restarts it either way.
	restarted = true
	if err := dockerx.Compose(ctx, r.Inst.DockerDir, r.log, "up", "-d"); err != nil {
		r.fail(StepRestart, firstLine(err.Error()))
		return r.failed(state, plan, backupPath, applied, restarted, err)
	}
	r.done(StepRestart, "services restarted")

	r.start(StepVerify, "containers, site, admin")
	if err := r.verify(ctx, r.dbBudget(plan)); err != nil {
		r.fail(StepVerify, err.Error())
		return r.failed(state, plan, backupPath, applied, restarted, err)
	}
	r.done(StepVerify, "healthy")

	state.PreviousFiles = state.Files
	state.Previous = plan.Current
	state.Files = files
	state.Current = target.Version
	state.PreviousImages = state.Images
	state.Images = plan.ImageEnv
	if state.ReleaseImages == nil {
		state.ReleaseImages = map[string][]string{}
	}
	state.ReleaseImages[target.Version] = pinsOf(plan.Images)
	// What a later rollback has to do with the database: what the release
	// declared, or "migrates" when MariaDB rewrote its data files.
	state.Database = plan.Database
	state.OneWay = plan.OneWay
	if sums, err := release.Checksums(r.Inst.Root, files); err != nil {
		r.log("the release files could not be checksummed, local changes will not be detected: " + err.Error())
		state.Checksums = nil
	} else {
		state.Checksums = sums
	}
	state.History = append(state.History, instance.Entry{Version: target.Version, Action: "upgrade", Date: time.Now(), Note: "from " + plan.Current})
	if err := r.Inst.SaveState(state); err != nil {
		return fmt.Errorf("%s is installed and the site is healthy, but the record in %s could not be written (%w): run 'kvsctl adopt --force --version %s' to repair it", target.Version, r.Inst.StateDir(), err, target.Version)
	}
	_ = r.Inst.SetEnv("KVS_STACK_VERSION", target.Version)
	return nil
}

// announceImages tells the reporter every service of the release with the
// version it runs and the one it will run, before the question is asked:
// the ones already on the machine get a note instead of a download.
func (r *Runner) announceImages(plan *Plan) {
	total := dockerx.Progress{Total: plan.Bytes}
	for _, item := range plan.Services {
		switch {
		case item.Unchanged:
			r.Reporter.Event(imageEvent(item, dockerx.Progress{Done: true}, total, "unchanged"))
		case item.OnDisk:
			r.Reporter.Event(imageEvent(item, dockerx.Progress{Done: true}, total, "already on this machine"))
		default:
			r.Reporter.Event(imageEvent(item, dockerx.Progress{Total: item.Bytes}, total, ""))
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

// prune keeps the last backups and removes the older ones, never the one
// this run just took.
func (r *Runner) prune(keepPath string) {
	keep := r.Opts.KeepBackups
	if keep <= 0 {
		keep = 5
	}
	removed, err := backup.Prune(r.Inst.BackupDir(), keep, keepPath)
	switch {
	case err != nil:
		r.log("the old backups could not be pruned: " + err.Error())
	case len(removed) > 0:
		names := make([]string, 0, len(removed))
		for _, p := range removed {
			names = append(names, filepath.Base(p))
		}
		r.log(fmt.Sprintf("removed %d backups over the %d kept: %s", len(removed), keep, strings.Join(names, ", ")))
	}
}

// dbBudget is how long the verification waits when MariaDB alone is still
// starting, which is what an upgrade of the data files looks like.
func (r *Runner) dbBudget(plan *Plan) time.Duration {
	if plan == nil || !plan.MariaDBUpgrade {
		return 0
	}
	if r.Opts.DBTimeout > 0 {
		return r.Opts.DBTimeout
	}
	return 30 * time.Minute
}

// Pull downloads the images the plan lists and checks each one carries the
// digest the manifest names. The site keeps running during this step.
func (r *Runner) Pull(ctx context.Context, plan *Plan) error {
	var total dockerx.Progress
	total.Total = plan.Bytes
	done := map[string]int64{}
	for _, img := range plan.ImagesToPull {
		ref := img.Ref
		if err := r.Docker.Pull(ctx, ref, img.Bytes, func(p dockerx.Progress) {
			done[ref] = p.Current
			total.Current = 0
			for _, n := range done {
				total.Current += n
			}
			r.Reporter.Event(imageEvent(img, p, total, ""))
		}); err != nil {
			return err
		}
		has, err := r.Docker.HasDigest(ctx, ref, img.Digest)
		if err != nil {
			return fmt.Errorf("inspect %s: %w", ref, err)
		}
		if !has {
			return fmt.Errorf("%s was pulled but does not carry the digest the manifest lists (%s)", ref, img.Digest)
		}
	}
	total.Current, total.Done = total.Total, true
	r.Reporter.Event(Event{Kind: KindImages, Step: StepPull, Total: total})
	return nil
}

// apply downloads the bundle, keeps the running files and lays the new
// ones. touched reports whether the installation was written to: a bundle
// that never arrived, a checksum that does not match or a disk that filled
// up while unpacking leave the machine exactly as it was, and a rollback
// then has nothing to undo.
func (r *Runner) apply(ctx context.Context, state *instance.State, plan *Plan) (files []string, touched bool, err error) {
	target := plan.Target
	archive := filepath.Join(r.Inst.StateDir(), "downloads", fmt.Sprintf("kvs-stack-%s.tar.gz", target.Version))
	r.log("downloading " + target.Bundle.URL)
	if err := release.Download(ctx, target.Bundle.URL, target.Bundle.SHA256, archive, nil); err != nil {
		return nil, false, err
	}
	newDir := filepath.Join(r.Inst.ReleasesDir(), target.Version)
	if err := os.RemoveAll(newDir); err != nil {
		return nil, false, err
	}
	files, err = release.Extract(archive, newDir)
	if err != nil {
		return nil, false, err
	}
	r.log(fmt.Sprintf("bundle verified, %d files", len(files)))
	if len(state.Files) > 0 {
		prevDir := filepath.Join(r.Inst.ReleasesDir(), plan.Current)
		if _, err := os.Stat(prevDir); err != nil {
			r.log("keeping the files of " + plan.Current + " for a rollback")
			if err := release.Snapshot(r.Inst.Root, prevDir, state.Files); err != nil {
				return nil, false, fmt.Errorf("keep %s: %w", plan.Current, err)
			}
		}
	}
	touched = true
	if err := release.Sync(newDir, r.Inst.Root, files, state.Files); err != nil {
		return nil, true, err
	}
	if err := r.setComposeFiles(files); err != nil {
		return nil, true, err
	}
	if err := r.mergeEnv(newDir); err != nil {
		return nil, true, err
	}
	if err := r.setImageEnv(plan.ImageEnv, state.Images); err != nil {
		return nil, true, err
	}
	return files, true, nil
}

// setImageEnv writes the variant images of the release into .env and drops
// the keys of the release being left that the new one does not set, so the
// override never reads a stale value.
func (r *Runner) setImageEnv(want, old map[string]string) error {
	for _, key := range slices.Sorted(maps.Keys(old)) {
		if _, ok := want[key]; ok {
			continue
		}
		if err := r.Inst.UnsetEnv(key); err != nil {
			return err
		}
		r.log("removed " + key + " from .env")
	}
	for _, key := range slices.Sorted(maps.Keys(want)) {
		if err := r.Inst.SetEnv(key, want[key]); err != nil {
			return err
		}
		r.log(key + "=" + want[key])
	}
	return nil
}

// recreateDatadir moves the MariaDB data files aside, inside their volume,
// so the previous image initialises a fresh directory and the dump is
// replayed into it. Nothing is deleted: the files stay in a dated folder of
// the volume until the operator removes them.
func (r *Runner) recreateDatadir(ctx context.Context) error {
	r.log("stopping mariadb: its data files were upgraded in place and the previous image cannot open them")
	if err := dockerx.Compose(ctx, r.Inst.DockerDir, r.log, "stop", mariadbService); err != nil {
		return err
	}
	kept := ".kvsctl-rollback-" + time.Now().Format("20060102-150405")
	script := fmt.Sprintf(`set -e; cd /var/lib/mysql; mkdir %q; for f in * .[!.]*; do [ -e "$f" ] || continue; [ "$f" = %q ] && continue; mv "$f" %q/; done`, kept, kept, kept)
	r.log("moving the data files to " + kept + " inside the mariadb-data volume")
	if err := dockerx.Compose(ctx, r.Inst.DockerDir, r.log, "run", "--rm", "--no-deps", "--entrypoint", "sh", mariadbService, "-c", script); err != nil {
		return fmt.Errorf("move the data files aside: %w", err)
	}
	return nil
}

// waitDatabase waits for the mariadb container to report healthy, which a
// recreated container takes seconds to reach and a fresh data directory
// longer, before a dump is replayed into it.
func (r *Runner) waitDatabase(ctx context.Context, budget time.Duration) error {
	deadline := time.Now().Add(budget)
	lastMsg := ""
	for {
		states, err := r.Docker.Containers(ctx, r.Inst.ProjectName())
		if err != nil {
			return err
		}
		var msg string
		db := dockerx.ByService(states, mariadbService)
		switch {
		case db == nil:
			msg = "no mariadb container yet"
		case db.State == "running" && (db.Health == "" || db.Health == "healthy"):
			return nil
		default:
			msg = strings.TrimSpace(fmt.Sprintf("%s is %s %s", db.Name, db.State, db.Health))
		}
		if time.Now().After(deadline) {
			return fmt.Errorf("mariadb is not ready after %s: %s", budget.Round(time.Second), msg)
		}
		if msg != lastMsg {
			lastMsg = msg
			r.log("waiting for the database: " + msg)
		}
		select {
		case <-ctx.Done():
			return ctx.Err()
		case <-time.After(3 * time.Second):
		}
	}
}

// restoreBudget is how long a rollback waits for MariaDB before replaying
// the dump: the upgrade budget when the data files are rewritten, a few
// minutes otherwise.
func (r *Runner) restoreBudget(plan *Plan) time.Duration {
	return max(r.dbBudget(plan), 5*time.Minute)
}

// mergeEnv adds the settings the release introduced to the live .env,
// without ever changing a value the operator set.
func (r *Runner) mergeEnv(newDir string) error {
	example := filepath.Join(newDir, "docker", ".env.example")
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

// setComposeFiles adds the release override to COMPOSE_FILE when the
// release ships one, and removes it when it does not, so every compose
// command run by hand or by the scripts uses the pinned images.
//
// An install with one site has no COMPOSE_FILE at all: setup.sh removes the
// key and compose then loads docker-compose.yml plus, when it exists, the
// operator's docker-compose.override.yml. Writing the key stops that
// pickup, so an empty value is seeded with both, exactly as setup.sh builds
// the list when it does write one.
func (r *Runner) setComposeFiles(files []string) error {
	ships := false
	for _, f := range files {
		if f == "docker/"+ReleaseOverride {
			ships = true
			break
		}
	}
	sep := r.Inst.Env["COMPOSE_PATH_SEPARATOR"]
	if sep == "" {
		sep = ":"
	}
	var parts []string
	if current := r.Inst.Env["COMPOSE_FILE"]; current == "" {
		parts = append(parts, "docker-compose.yml")
		if _, err := os.Stat(filepath.Join(r.Inst.DockerDir, OverrideFile)); err == nil {
			parts = append(parts, OverrideFile)
		}
	} else {
		for _, p := range strings.Split(current, sep) {
			if p != "" && p != ReleaseOverride {
				parts = append(parts, p)
			}
		}
	}
	if ships {
		parts = append(parts, ReleaseOverride)
	}
	value := strings.Join(parts, sep)
	if value == r.Inst.Env["COMPOSE_FILE"] {
		return nil
	}
	r.log("COMPOSE_FILE=" + value)
	return r.Inst.SetEnv("COMPOSE_FILE", value)
}

// Verify waits for every container of the project to be up and the site to
// answer, within the health timeout.
func (r *Runner) Verify(ctx context.Context) error { return r.verify(ctx, 0) }

// verify waits for the project to settle. dbBudget, when longer than the
// health timeout, is how long MariaDB alone may keep the wait going: an
// upgrade of the data files takes as long as the database is large, while
// anything else failing still ends at the health timeout.
func (r *Runner) verify(ctx context.Context, dbBudget time.Duration) error {
	timeout := r.Opts.HealthTimeout
	if timeout == 0 {
		timeout = 2 * time.Minute
	}
	start := time.Now()
	deadline := start.Add(timeout)
	dbDeadline := deadline
	if dbBudget > timeout {
		dbDeadline = start.Add(dbBudget)
	}
	var baseline map[string]int
	var last error
	var lastMsg string
	saidDB := false
	wait := func(err error) {
		last = err
		if msg := "waiting: " + firstLine(err.Error()); msg != lastMsg {
			lastMsg = msg
			r.log(msg)
		}
	}
	for {
		states, err := r.Docker.Containers(ctx, r.Inst.ProjectName())
		if err != nil {
			return err
		}
		if len(states) == 0 {
			return r.noContainers()
		}
		if baseline == nil {
			baseline = map[string]int{}
			for _, s := range states {
				baseline[s.Name] = s.Restarts
			}
		}
		problems, crashLoop := dockerx.Problems(states, baseline, time.Now())
		dbOnly := false
		switch {
		case crashLoop:
			return fmt.Errorf("a service keeps restarting: %s", strings.Join(problems, "; "))
		case len(problems) > 0:
			others, _ := dockerx.Problems(withoutMariaDB(states), baseline, time.Now())
			dbOnly = len(others) == 0
			wait(errors.New(strings.Join(problems, "; ")))
		default:
			err := r.httpCheck(ctx)
			if err == nil {
				return nil
			}
			wait(err)
		}
		now := time.Now()
		if now.After(deadline) {
			if !dbOnly || now.After(dbDeadline) {
				return last
			}
			if !saidDB {
				saidDB = true
				r.log("waiting for MariaDB (an upgrade of the data files can take a while)")
			}
		}
		select {
		case <-ctx.Done():
			return ctx.Err()
		case <-time.After(3 * time.Second):
		}
	}
}

// noContainers explains an empty project, which used to make the
// verification collapse into the single HTTP probe without a word.
func (r *Runner) noContainers() error {
	msg := fmt.Sprintf("no container of compose project %q found: check COMPOSE_PROJECT_NAME in .env", r.Inst.ProjectName())
	if !r.Inst.ProjectNameKnown() {
		msg += " (the file sets none, so this name was guessed)"
	}
	return errors.New(msg)
}

// withoutMariaDB is the project without its database container, to tell a
// database still starting from anything else being wrong.
func withoutMariaDB(states []dockerx.ContainerState) []dockerx.ContainerState {
	out := make([]dockerx.ContainerState, 0, len(states))
	for _, s := range states {
		if s.Service == mariadbService || strings.HasSuffix(s.Name, "-"+mariadbService) {
			continue
		}
		out = append(out, s)
	}
	return out
}

// httpCheck asks the site for / and /admin/ once, on the published
// endpoint and with the host name the site answers to (www included).
// Anything below 400 counts: a site that answers a redirect is a site that
// is up, and treating it as down used to roll back healthy upgrades.
func (r *Runner) httpCheck(ctx context.Context) error {
	host, port := r.Inst.PublishedEndpoint()
	site := r.Inst.SiteHost()
	transport := &http.Transport{
		TLSClientConfig: &tls.Config{InsecureSkipVerify: true, ServerName: site}, //nolint:gosec // local port, certificate checked elsewhere
		DialContext: func(ctx context.Context, network, addr string) (net.Conn, error) {
			return (&net.Dialer{Timeout: 5 * time.Second}).DialContext(ctx, network, net.JoinHostPort(host, port))
		},
	}
	client := &http.Client{Transport: transport, Timeout: 30 * time.Second, CheckRedirect: func(*http.Request, []*http.Request) error { return http.ErrUseLastResponse }}
	defer transport.CloseIdleConnections()
	for _, path := range []string{"/", "/admin/"} {
		req, err := http.NewRequestWithContext(ctx, http.MethodGet, "https://"+site+path, nil)
		if err != nil {
			return err
		}
		req.Header.Set("User-Agent", "kvsctl")
		resp, err := client.Do(req)
		if err != nil {
			return fmt.Errorf("GET %s: %w", path, err)
		}
		resp.Body.Close()
		if resp.StatusCode >= http.StatusBadRequest {
			return fmt.Errorf("GET %s answered %s", path, resp.Status)
		}
		r.log(fmt.Sprintf("GET %s answered %d%s", path, resp.StatusCode, statusNote(resp, site)))
	}
	return nil
}

// statusNote says why an answer is not a plain 200.
func statusNote(resp *http.Response, site string) string {
	if resp.StatusCode < http.StatusMultipleChoices {
		return ""
	}
	loc := resp.Header.Get("Location")
	if loc == "" {
		return " (" + strings.ToLower(http.StatusText(resp.StatusCode)) + ")"
	}
	if u, err := url.Parse(loc); err == nil && u.Host != "" {
		if strings.EqualFold(u.Host, "www."+site) {
			return " (www redirect)"
		}
		return " (redirect to " + u.Host + ")"
	}
	return " (redirect to " + loc + ")"
}

// failed rolls back after a failed step and builds the error the upgrade
// ends with: what failed, and whether the previous version is back.
func (r *Runner) failed(state *instance.State, plan *Plan, backupPath string, applied, restarted bool, cause error) error {
	if err := r.rollback(state, plan, backupPath, applied, restarted, cause); err != nil {
		return &failure{
			msg:   fmt.Sprintf("upgrade to %s failed: %s; the rollback to %s failed too: %s", plan.Target.Version, cause, plan.Current, err),
			cause: cause,
			kind:  ErrRollbackFailed,
		}
	}
	if !applied && !restarted {
		return &failure{
			msg:   fmt.Sprintf("upgrade to %s failed: %s; nothing was applied, the stack is still on %s", plan.Target.Version, cause, plan.Current),
			cause: cause,
			kind:  ErrRolledBack,
		}
	}
	return &failure{
		msg:   fmt.Sprintf("upgrade to %s failed: %s; %s is back and healthy", plan.Target.Version, cause, plan.Current),
		cause: cause,
		kind:  ErrRolledBack,
	}
}

// rollback undoes what the upgrade did, and only that: the files come back
// when they were laid, compose runs when anything was recreated, and the
// database is replayed only when the containers were restarted on a release
// that changes it. Every decision is logged, because an operator reading
// this later needs to know whether the dump was replayed.
func (r *Runner) rollback(state *instance.State, plan *Plan, backupPath string, applied, restarted bool, cause error) error {
	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Minute)
	defer cancel()
	r.start(StepRollbck, "back to "+plan.Current)
	if !applied && !restarted {
		r.done(StepRollbck, "nothing was applied, nothing to undo")
		return nil
	}
	if applied {
		prevDir := filepath.Join(r.Inst.ReleasesDir(), plan.Current)
		if len(state.Files) == 0 {
			err := fmt.Errorf("the state lists no release file for %s, so the files of %s cannot be taken back: put them back by hand from %s", plan.Current, plan.Target.Version, prevDir)
			r.fail(StepRollbck, err.Error())
			return err
		}
		if _, err := os.Stat(prevDir); err != nil {
			err = fmt.Errorf("the files of %s are not kept in %s, so they cannot be taken back: %w", plan.Current, prevDir, err)
			r.fail(StepRollbck, err.Error())
			return err
		}
		newFiles, _ := listFiles(filepath.Join(r.Inst.ReleasesDir(), plan.Target.Version))
		if err := release.Sync(prevDir, r.Inst.Root, state.Files, newFiles); err != nil {
			r.fail(StepRollbck, "files: "+err.Error())
			return fmt.Errorf("files: %w", err)
		}
		if err := r.setComposeFiles(state.Files); err != nil {
			r.fail(StepRollbck, "COMPOSE_FILE: "+err.Error())
			return fmt.Errorf("COMPOSE_FILE: %w", err)
		}
		if err := r.setImageEnv(state.Images, plan.ImageEnv); err != nil {
			r.fail(StepRollbck, ".env: "+err.Error())
			return fmt.Errorf(".env: %w", err)
		}
		r.log(fmt.Sprintf("%d files of %s are back", len(state.Files), plan.Current))
	} else {
		r.log("no release file was laid, the installation is untouched")
	}
	restore := restarted && backupPath != "" && (plan.Database == "migrates" || r.Opts.RestoreDB)
	if restore && plan.OneWay {
		if err := r.recreateDatadir(ctx); err != nil {
			r.fail(StepRollbck, "database: "+err.Error())
			return fmt.Errorf("database: %w", err)
		}
	}
	if err := dockerx.Compose(ctx, r.Inst.DockerDir, r.log, "up", "-d"); err != nil {
		r.fail(StepRollbck, firstLine(err.Error()))
		return err
	}
	switch {
	case !restarted:
		r.log("the containers were never recreated, the database is left alone")
	case backupPath == "":
		r.log("no backup was taken (--skip-backup), the database is left as it is")
	case restore:
		if err := r.waitDatabase(ctx, r.restoreBudget(plan)); err != nil {
			r.fail(StepRollbck, "database: "+err.Error())
			return fmt.Errorf("database: %w", err)
		}
		r.log("restoring the database from " + relPath(r.Inst.Root, backupPath))
		if err := backup.RestoreDatabase(ctx, backupPath, r.Inst.ContainerPrefix()+"-mariadb"); err != nil {
			r.fail(StepRollbck, "database: "+err.Error())
			return fmt.Errorf("database: %w", err)
		}
	default:
		r.log(fmt.Sprintf("%s does not change the database, it is left as it is", plan.Target.Version))
	}
	if err := r.verify(ctx, r.dbBudget(plan)); err != nil {
		r.fail(StepRollbck, "still failing: "+err.Error())
		return err
	}
	state.History = append(state.History, instance.Entry{Version: plan.Current, Action: "rollback", Date: time.Now(), Note: fmt.Sprintf("%s failed: %s", plan.Target.Version, firstLine(cause.Error()))})
	_ = r.Inst.SaveState(state)
	r.done(StepRollbck, plan.Current+" is back and healthy")
	return nil
}

// forwardRollback says why a rollback must not run when the previous
// version is newer than the installed one: after a rollback the two slots
// swap, and running it again would reinstall the newer version without a
// backup, without the blockers, and around the one-way rules. Going forward
// is an upgrade, which keeps the local files and images and is quick.
func forwardRollback(state *instance.State) string {
	if _, err := semver.Parse(state.Current); err != nil {
		return ""
	}
	if _, err := semver.Parse(state.Previous); err != nil {
		return ""
	}
	if !semver.Less(state.Current, state.Previous) {
		return ""
	}
	return fmt.Sprintf("the previous version %s is newer than the installed %s: a rollback only goes back; to install %s again run 'kvsctl upgrade --version %s'", state.Previous, state.Current, state.Previous, state.Previous)
}

// Rollback returns to the previous version by hand. A release that changed
// the database needs its backup replayed, so the backup is found before
// anything is touched and a missing one stops the command.
func (r *Runner) Rollback(ctx context.Context, state *instance.State) (err error) {
	if state == nil || state.Previous == "" {
		return errors.New("no previous version to return to")
	}
	if msg := forwardRollback(state); msg != "" {
		return errors.New(msg)
	}
	defer func() { r.Reporter.Event(Event{Kind: KindDone, Err: err}) }()
	prevDir := filepath.Join(r.Inst.ReleasesDir(), state.Previous)
	if _, err := os.Stat(prevDir); err != nil {
		return fmt.Errorf("the files of %s are not kept in %s", state.Previous, prevDir)
	}
	if len(state.PreviousFiles) == 0 {
		return fmt.Errorf("the state lists no release file for %s, so there is nothing to put back: restore %s by hand, then run 'kvsctl adopt --force --version %s'", state.Previous, prevDir, state.Previous)
	}
	var dumpPath string
	if state.Database == "migrates" || state.OneWay || r.Opts.RestoreDB {
		dumpPath, err = backup.Latest(r.Inst.BackupDir(), state.Previous)
		if err != nil {
			return err
		}
		if dumpPath == "" {
			return fmt.Errorf("%s changed the database and no backup of %s is kept in %s: the old code would run on the new schema, so take the database back by hand first", state.Current, state.Previous, r.Inst.BackupDir())
		}
	}
	if !r.Opts.Yes {
		question := fmt.Sprintf("Roll back to %s?", state.Previous)
		switch {
		case dumpPath != "" && state.OneWay:
			question = fmt.Sprintf("Roll back to %s, recreate the MariaDB data directory and replay %s?", state.Previous, filepath.Base(dumpPath))
		case dumpPath != "":
			question = fmt.Sprintf("Roll back to %s and replay %s?", state.Previous, filepath.Base(dumpPath))
		}
		r.start(StepConfirm, fmt.Sprintf("Roll %s back from %s to %s?", r.Inst.Domain(), state.Current, state.Previous))
		if !r.Reporter.Confirm(ctx, question) {
			r.fail(StepConfirm, "cancelled")
			return errors.New("rollback cancelled")
		}
		r.done(StepConfirm, "yes")
	}
	r.start(StepApply, "files of "+state.Previous)
	if err := release.Sync(prevDir, r.Inst.Root, state.PreviousFiles, state.Files); err != nil {
		r.fail(StepApply, err.Error())
		return err
	}
	if err := r.setComposeFiles(state.PreviousFiles); err != nil {
		r.fail(StepApply, err.Error())
		return err
	}
	if err := r.setImageEnv(state.PreviousImages, state.Images); err != nil {
		r.fail(StepApply, ".env: "+err.Error())
		return err
	}
	r.done(StepApply, fmt.Sprintf("%d files", len(state.PreviousFiles)))
	r.start(StepRestart, "docker compose up")
	if dumpPath != "" && state.OneWay {
		if err := r.recreateDatadir(ctx); err != nil {
			r.fail(StepRestart, "database: "+err.Error())
			return fmt.Errorf("database: %w", err)
		}
	}
	if err := dockerx.Compose(ctx, r.Inst.DockerDir, r.log, "up", "-d"); err != nil {
		r.fail(StepRestart, firstLine(err.Error()))
		return err
	}
	r.done(StepRestart, "services restarted")
	if dumpPath != "" {
		if err := r.waitDatabase(ctx, r.restoreBudget(nil)); err != nil {
			r.fail(StepRestart, "database: "+err.Error())
			return fmt.Errorf("database: %w", err)
		}
		r.log("restoring the database from " + relPath(r.Inst.Root, dumpPath))
		if err := backup.RestoreDatabase(ctx, dumpPath, r.Inst.ContainerPrefix()+"-mariadb"); err != nil {
			r.fail(StepRestart, "database: "+err.Error())
			return fmt.Errorf("database: %w", err)
		}
	}
	r.start(StepVerify, "containers, site, admin")
	if err := r.verify(ctx, 0); err != nil {
		r.fail(StepVerify, err.Error())
		return err
	}
	r.done(StepVerify, "healthy")
	state.Current, state.Previous = state.Previous, state.Current
	state.Files, state.PreviousFiles = state.PreviousFiles, state.Files
	state.Images, state.PreviousImages = state.PreviousImages, state.Images
	// What the version now running does to the database is only known from
	// the release it was installed from, which this state no longer names.
	state.Database = ""
	state.OneWay = false
	if sums, err := release.Checksums(r.Inst.Root, state.Files); err == nil {
		state.Checksums = sums
	} else {
		state.Checksums = nil
	}
	state.History = append(state.History, instance.Entry{Version: state.Current, Action: "rollback", Date: time.Now(), Note: "by hand from " + state.Previous})
	if err := r.Inst.SaveState(state); err != nil {
		return fmt.Errorf("%s is back and the site is healthy, but the record in %s could not be written (%w): run 'kvsctl adopt --force --version %s' to repair it", state.Current, r.Inst.StateDir(), err, state.Current)
	}
	_ = r.Inst.SetEnv("KVS_STACK_VERSION", state.Current)
	return nil
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

// event drops the message when there is nobody to show it: check and the
// tests build a runner without a screen.
func (r *Runner) event(e Event) {
	if r.Reporter != nil {
		r.Reporter.Event(e)
	}
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
