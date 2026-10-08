package upgrade

import (
	"bufio"
	"context"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"slices"
	"sort"
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

// Plan reads the manifest and decides what the upgrade would do. It changes
// nothing on the machine: check prints the plan, and upgrade runs it once
// no blocker is left.
func (r *Runner) Plan(ctx context.Context, state *instance.State) (*Plan, error) {
	if state == nil || state.Current == "" {
		return nil, errors.New("this stack has no recorded version: run 'kvsctl adopt' once, which finds the installed version itself, in docker/RELEASE or in the release tag of the checkout")
	}
	doc, err := manifest.FetchContext(ctx, r.Opts.ManifestURL)
	if err != nil {
		return nil, err
	}
	if err := doc.VerifyAny(r.Opts.PublicKeys); err != nil {
		return nil, err
	}
	m := doc.Manifest
	if err := CheckManifest(r.Inst, m, r.Opts.ManifestURL, r.Opts.AllowStaleManifest); err != nil {
		return nil, err
	}
	plan := &Plan{Current: state.Current, Previous: state.Previous, CurrentLabel: state.Label(state.Current), PreviousLabel: state.Label(state.Previous), Manifest: m}
	stable := m.LatestStable()
	switch {
	case r.Opts.Version != "":
		if plan.Target = m.Find(r.Opts.Version); plan.Target == nil {
			return nil, fmt.Errorf("version %s is not in the manifest", r.Opts.Version)
		}
	case (stable == nil || semver.Less(stable.Version, plan.Current)) && semver.IsPrerelease(plan.Current) && m.Find(plan.Current) != nil:
		// A stack that runs a release candidate newer than every stable
		// release stays on it: its upgrade without a version is the one
		// of the installed release, which has nothing to do unless its
		// images changed.
		plan.Target = m.Find(plan.Current)
	case stable == nil:
		return nil, fmt.Errorf("the manifest lists release candidates only (%s is the newest): name the one to install with --version", m.Latest().Version)
	default:
		// A release candidate is installed when its version is asked for,
		// never as the latest release.
		plan.Target, plan.latest = stable, true
	}
	if semver.Less(plan.Target.Version, plan.Current) {
		plan.Downgrade = true
		return plan, nil
	}
	if r.planKvsctl(plan, m) {
		return plan, nil
	}
	// An engine that does not answer, or answers a client it is too old
	// for, tells nothing of what follows, each refusal less clear than the
	// last, and what the plan would show without it would be guesses: the
	// plan stops at what to fix.
	if err := CheckEngine(ctx, r.Docker); err != nil {
		plan.Incomplete = true
		plan.Blockers = append(plan.Blockers, err.Error())
		return plan, nil
	}
	info, infoErr := r.Docker.Info(ctx)
	running, err := r.Docker.ServiceImages(ctx, r.Inst.ProjectName())
	if err != nil {
		plan.Incomplete = true
		plan.Blockers = append(plan.Blockers, fmt.Sprintf("the Docker engine could not list the containers of project %s (%s): start Docker, then run the command again", r.Inst.ProjectName(), firstLine(err.Error())))
		return plan, nil
	}
	variantsOK := r.planVariants(ctx, plan, running)
	if plan.Target.Version == plan.Current {
		// The installed release applied again is an upgrade only when it
		// would write other variant images than the ones the stack runs.
		if variantsOK && !plan.MariaDBUpgrade && sameImages(plan.ImageEnv, state.Images) {
			plan.UpToDate = true
			return plan, nil
		}
		plan.Reapply = true
	} else {
		plan.Releases = m.Between(plan.Current, plan.Target.Version)
		r.planJumps(plan, m)
	}
	r.planDatabase(plan)
	// A release that publishes its PHP images per series was matched to
	// the series of the site above; one that ships a single PHP binds an
	// encoded site to it.
	if php := plan.Target.Requires.PHP; len(plan.Target.Values(manifest.VariantPHP)) == 0 && php != "" && r.Inst.IonCube() && php != r.Inst.PHPVersion() {
		plan.Blockers = append(plan.Blockers, fmt.Sprintf("%s runs PHP %s and this site is IonCube encoded for PHP %s: a KVS archive encoded for PHP %s is needed first", plan.Target.Version, php, r.Inst.PHPVersion(), php))
	}
	if len(state.Files) == 0 {
		// Adopt and every upgrade record the files; a state without them
		// was written by hand, or by a kvsctl older than that record.
		fix := fmt.Sprintf("run 'kvsctl adopt --force --version %s' first", plan.Current)
		if state.Upgraded() {
			fix = fmt.Sprintf("kvsctl records them at every upgrade, so %s was changed by hand; each archive in %s holds the state file of its day", filepath.Join(r.Inst.StateDir(), "state.json"), r.Inst.BackupDir())
		}
		plan.Blockers = append(plan.Blockers, fmt.Sprintf("the state lists no release file of %s, so a failed upgrade could not put them back: %s", plan.installed(), fix))
	}
	r.planCompose(ctx, plan)
	if kvsMin := plan.Target.Requires.KVSMin; kvsMin != "" {
		if kvs := r.Inst.KVSVersion(); kvs != "" && semver.Less(kvs, kvsMin) {
			plan.Blockers = append(plan.Blockers, fmt.Sprintf("%s supports KVS %s and newer, this site runs KVS %s: update KVS from its admin panel first", plan.Target.Version, kvsMin, kvs))
		}
	}
	planEngine(plan, info, infoErr)
	r.planCheckout(plan, state)
	r.planLocalChanges(plan, state)
	coming := r.planBundle(ctx, plan, state)
	active := r.planHealth(ctx, plan, running)
	r.planImages(ctx, plan, running, active, coming)
	r.planDisk(ctx, plan)
	return plan, nil
}

// planKvsctl stops the plan when a release it installs needs a newer
// kvsctl than this one (requires.kvsctl_min): that release follows rules
// this build does not know, so nothing else it would say about it can be
// trusted. The strictest of the releases installed at once is the one
// named. It reports whether the plan stopped.
func (r *Runner) planKvsctl(plan *Plan, m *manifest.Manifest) bool {
	running := r.Opts.KvsctlVersion
	if running == "" {
		running = KvsctlVersion
	}
	if _, err := semver.Parse(running); err != nil {
		return false
	}
	var needed, by string
	// The target is named again for the installed release applied anew,
	// which Between leaves out.
	for _, rel := range append(m.Between(plan.Current, plan.Target.Version), *plan.Target) {
		if min := rel.Requires.KvsctlMin; min != "" && (needed == "" || semver.Less(needed, min)) {
			needed, by = min, rel.Version
		}
	}
	if needed == "" || !semver.Less(running, needed) {
		return false
	}
	plan.Incomplete = true
	plan.Blockers = append(plan.Blockers, fmt.Sprintf("%s needs kvsctl %s or newer, and this is kvsctl %s: run '%s' first", by, needed, running, updateCLICommand(r.Opts.ManifestURL, m, needed, by)))
	return true
}

// updateCLICommand is the update-cli that installs a kvsctl of needed or
// newer, which release by asks for. update-cli reads the default manifest
// and installs the kvsctl of its latest stable release unless it is told
// otherwise, and a release candidate may ask for its own kvsctl, which only
// its name installs: the command names the manifest read here, and by when
// no stable release ships a kvsctl new enough. A release never asks for a
// kvsctl newer than its own (kvsctl-release refuses to sign one), so the
// kvsctl of by is new enough.
func updateCLICommand(url string, m *manifest.Manifest, needed, by string) string {
	command := "kvsctl update-cli"
	if url != manifest.DefaultURL {
		command += " --manifest " + url
	}
	if stable := m.LatestStable(); (stable == nil || semver.Less(stable.Version, needed)) && !semver.Less(by, needed) {
		command += " --version " + by
	}
	return command
}

// planVariants picks the images this instance runs with the target: the
// ones every instance runs and, for each axis the release varies by, the
// images of the value this instance has, its PHP series and its MariaDB
// series. The variant images are also what .env carries for the release
// override. It reports whether every axis got a value; a blocker says why
// one did not, and the plan then lists the shared images alone.
func (r *Runner) planVariants(ctx context.Context, plan *Plan, running map[string]dockerx.ServiceImage) bool {
	target := plan.Target
	values := map[string]string{}
	ok := true
	if published := target.Values(manifest.VariantPHP); len(published) > 0 {
		series := r.Inst.PHPVersion()
		if slices.Contains(published, series) {
			values[manifest.VariantPHP] = series
		} else {
			ok = false
			plan.Blockers = append(plan.Blockers, fmt.Sprintf("%s publishes no image for PHP %s, the series this site runs (it publishes %s): wait for a release that does, or move the site to one of those series (PHP_VERSION in %s, with KVS files encoded for it when the site is IonCube encoded)", target.Version, series, strings.Join(published, ", "), r.Inst.EnvPath))
		}
	}
	if series, decided := r.planMariaDB(ctx, plan, running); !decided {
		ok = false
	} else if series != "" && len(target.Values(manifest.VariantMariaDB)) > 0 {
		values[manifest.VariantMariaDB] = series
	}
	plan.Images = append([]manifest.Image(nil), target.Images...)
	if !ok {
		return false
	}
	images, err := target.ImagesFor(values)
	if err != nil {
		plan.Blockers = append(plan.Blockers, err.Error())
		return false
	}
	plan.Images = images
	plan.PHPSeries = values[manifest.VariantPHP]
	env := map[string]string{}
	for axis, value := range values {
		for _, img := range target.Variants[axis][value] {
			env[ImageEnvKey(img.Service)] = img.Ref + "@" + img.Digest
		}
	}
	if len(env) > 0 {
		plan.ImageEnv = env
	}
	return true
}

// planMariaDB decides the MariaDB series of the upgrade. The server
// rewrites its data files in place for a new series and an older server
// cannot open them again, so a stack keeps the series it runs: a change
// happens only when asked for (MariaDBSeries), one published series at a
// time and never backwards, and the plan then becomes one way. Within a
// series, a server never goes back to an older build either. It returns
// the series to install, "" for a release that pins no MariaDB image, and
// whether the series could be decided at all.
func (r *Runner) planMariaDB(ctx context.Context, plan *Plan, running map[string]dockerx.ServiceImage) (string, bool) {
	published := mariadbSeries(plan.Target)
	if len(published) == 0 {
		if r.Opts.MariaDBSeries != "" {
			plan.Blockers = append(plan.Blockers, fmt.Sprintf("%s pins no MariaDB image of a known series, so --mariadb-series %s has nothing to move to: run without it", plan.Target.Version, r.Opts.MariaDBSeries))
			return "", false
		}
		return "", true
	}
	have, version, unknown := r.runningMariaDB(ctx, running)
	plan.RunningMariaDBSeries = have
	if have == "" {
		plan.Blockers = append(plan.Blockers, fmt.Sprintf("the MariaDB series of this stack is unknown (%s): set MARIADB_VERSION in %s to the series its server runs, 11.8 for instance", unknown, r.Inst.EnvPath))
		return "", false
	}
	want := have
	if asked := r.Opts.MariaDBSeries; asked != "" && asked != have {
		if refusal := seriesRefusal(plan, published, have, asked); refusal != "" {
			plan.Blockers = append(plan.Blockers, refusal)
			return "", false
		}
		want = asked
		plan.MariaDBUpgrade = true
	}
	if !slices.Contains(published, want) {
		plan.Blockers = append(plan.Blockers, unpublishedSeries(plan, published, have))
		return "", false
	}
	plan.MariaDBSeries = want
	if !plan.MariaDBUpgrade {
		patchGuard(plan, want, version)
	}
	return want, true
}

// StackMariaDB is the MariaDB series the stack runs, read the way a plan
// reads it, and the server version its image declares; both are empty when
// they cannot be told. running is what ServiceImages lists for the
// project. It is what status shows.
func (r *Runner) StackMariaDB(ctx context.Context, running map[string]dockerx.ServiceImage) (series, version string) {
	series, version, _ = r.runningMariaDB(ctx, running)
	return series, version
}

// runningMariaDB reads what the stack runs: the series of the image the
// mariadb container was created with, else the series of the server
// version that image declares, else the series MARIADB_VERSION names in
// .env. version is the exact server version the image declares, "" when it
// says none. unknown says where nothing was found.
func (r *Runner) runningMariaDB(ctx context.Context, running map[string]dockerx.ServiceImage) (series, version, unknown string) {
	container := r.mariadbContainer()
	svc, found := running[mariadbService]
	if found && svc.Container != "" {
		container = svc.Container
	}
	if v, err := r.Docker.MariaDBVersion(ctx, container); err == nil {
		version = v
	}
	if found {
		if s := imageSeries(svc.Image); s != "" {
			return s, version, ""
		}
	}
	if s := versionSeries(version); s != "" {
		return s, version, ""
	}
	if s := versionSeries(r.Inst.Env["MARIADB_VERSION"]); s != "" {
		return s, version, ""
	}
	unknown = "no mariadb container was found"
	if found {
		unknown = fmt.Sprintf("the mariadb container runs %s, whose tag and image name no series", svc.Image)
	}
	return "", version, unknown + ", and MARIADB_VERSION in .env names none either"
}

// seriesRefusal says why a requested series change cannot happen, "" when
// it can: the series is newer than the running one, the target publishes
// it, and it is the next one the target publishes.
func seriesRefusal(plan *Plan, published []string, have, asked string) string {
	switch {
	case manifest.LessSeries(asked, have):
		return fmt.Sprintf("MariaDB never goes back a series: this stack runs %s, and a %s server cannot open the data files %s wrote; run without --mariadb-series to keep %s", have, asked, have, have)
	case !slices.Contains(published, asked):
		return fmt.Sprintf("%s publishes no MariaDB %s image (it publishes %s): ask for one of those with --mariadb-series", plan.Target.Version, asked, strings.Join(published, ", "))
	}
	if next := nextSeries(published, have); next != asked {
		return fmt.Sprintf("MariaDB moves one series at a time: after %s the next series %s publishes is %s; run 'kvsctl upgrade --version %s --mariadb-series %s' first", have, plan.Target.Version, next, plan.Target.Version, next)
	}
	return ""
}

// unpublishedSeries is the blocker of a target that publishes no image of
// the series the stack runs, with the way out: the newest release that
// publishes it and the series after it, through which the stack moves on.
func unpublishedSeries(plan *Plan, published []string, have string) string {
	list := strings.Join(published, ", ")
	if version, next := wayOut(plan.Manifest, plan.Current, have); version != "" {
		return fmt.Sprintf("%s publishes no MariaDB %s image, the series this stack runs (it publishes %s): move MariaDB to %s first with 'kvsctl upgrade --version %s --mariadb-series %s', then upgrade again", plan.Target.Version, have, list, next, version, next)
	}
	if newest := published[len(published)-1]; manifest.LessSeries(newest, have) {
		return fmt.Sprintf("this stack runs MariaDB %s, newer than any series %s publishes (%s), and a server never goes back a series: wait for a release that publishes %s", have, plan.Target.Version, list, have)
	}
	return fmt.Sprintf("MariaDB %s is not supported by any release: none publishes it together with a newer series, so kvsctl cannot move this stack off it (%s publishes %s); migrate the database by hand to one of those series, as a dump replayed into a new server", have, plan.Target.Version, list)
}

// wayOut finds the newest release, not older than the installed version,
// that publishes the running series and a newer one, and that next series.
func wayOut(m *manifest.Manifest, current, have string) (version, next string) {
	for i := range m.Releases {
		rel := &m.Releases[i]
		if semver.Less(rel.Version, current) {
			continue
		}
		published := mariadbSeries(rel)
		if !slices.Contains(published, have) {
			continue
		}
		if n := nextSeries(published, have); n != "" {
			return rel.Version, n
		}
	}
	return "", ""
}

// patchGuard refuses a release whose MariaDB image is an older build of
// the series than the one the server runs: the official images set
// MARIADB_VERSION, so the server's build is known, and a server must not
// go back to an older build. An unknown version on either side decides
// nothing.
func patchGuard(plan *Plan, series, runningVersion string) {
	img := releaseMariaDBImage(plan.Target, series)
	if img == nil {
		return
	}
	pinned, have := patchVersion(ImageVersion(img.Ref)), patchVersion(runningVersion)
	if pinned == "" || have == "" || !lessPatch(pinned, have) {
		return
	}
	plan.Blockers = append(plan.Blockers, fmt.Sprintf("this stack runs MariaDB %s and %s pins %s: a server must not go back to an older build of its series; wait for a release that pins %s or newer", have, plan.Target.Version, pinned, have))
}

// mariadbSeries lists the MariaDB series a release publishes, oldest
// first: the values of its mariadb variant, or the series of its one
// mariadb image when it does not vary by MariaDB. A release that pins no
// MariaDB image, or one whose tag names no series, gives none.
func mariadbSeries(rel *manifest.Release) []string {
	if values := rel.Values(manifest.VariantMariaDB); len(values) > 0 {
		return values
	}
	for _, img := range rel.Images {
		if img.Service == mariadbService {
			if s := imageSeries(img.Ref); s != "" {
				return []string{s}
			}
		}
	}
	return nil
}

// releaseMariaDBImage is the image of the mariadb service a release pins
// for a series.
func releaseMariaDBImage(rel *manifest.Release, series string) *manifest.Image {
	for _, img := range rel.Variants[manifest.VariantMariaDB][series] {
		if img.Service == mariadbService {
			return &img
		}
	}
	for _, img := range rel.Images {
		if img.Service == mariadbService {
			return &img
		}
	}
	return nil
}

// nextSeries is the oldest of published (oldest first) newer than have.
func nextSeries(published []string, have string) string {
	for _, s := range published {
		if manifest.LessSeries(have, s) {
			return s
		}
	}
	return ""
}

// planJumps collects every mandatory stop between the installed version and
// the target (Stops), not only the first one, so the operator is told the
// whole chain instead of discovering it one refusal at a time.
func (r *Runner) planJumps(plan *Plan, m *manifest.Manifest) {
	minFrom := map[string]string{}
	for _, rel := range m.Releases {
		if rel.Requires.MinFrom != "" {
			minFrom[rel.Version] = rel.Requires.MinFrom
		}
	}
	plan.Stops = Stops(plan.Current, plan.Target.Version, minFrom)
	if len(plan.Stops) == 0 {
		return
	}
	chain := append([]string{plan.installed()}, plan.Stops...)
	chain = append(chain, plan.Target.Version)
	plan.Blockers = append(plan.Blockers, fmt.Sprintf("%s cannot be installed directly from %s: go through %s (kvsctl upgrade --version %s first)", plan.Target.Version, plan.installed(), strings.Join(chain, " -> "), plan.Stops[0]))
}

// Stops are the versions a stack on current installs first, in order, on
// its way to target. A release names in requires.min_from the oldest
// version that upgrades to it directly: going up from current, every
// release up to target that names one newer than the version reached so far
// is reached through that version. minFrom maps the version of each release
// that names one to it. The plan blocks an upgrade that skips a stop by this
// rule, and the update reminder names the first stop by it too, from what it
// kept of the manifest.
func Stops(current, target string, minFrom map[string]string) []string {
	var versions []string
	for v := range minFrom {
		if semver.Less(current, v) && !semver.Less(target, v) {
			versions = append(versions, v)
		}
	}
	slices.SortFunc(versions, func(a, b string) int {
		switch {
		case semver.Less(a, b):
			return -1
		case semver.Less(b, a):
			return 1
		}
		return strings.Compare(a, b)
	})
	var stops []string
	from := current
	for _, v := range versions {
		if min := minFrom[v]; min != "" && semver.Less(from, min) {
			stops = append(stops, min)
			from = min
		}
	}
	return stops
}

// planDatabase works out what the upgrade does to the database. Every
// release it installs counts, not only the target: a jump over a release
// that migrates the schema carries that migration in its files and images,
// so a rollback needs the backup all the same. A MariaDB series change
// rewrites the data files in place, which no restart of the previous image
// undoes. A one-way upgrade has the backup for its only way back, so it
// cannot skip it.
func (r *Runner) planDatabase(plan *Plan) {
	var oneWay []string
	for _, rel := range plan.Releases {
		if rel.Database == migrates {
			plan.Database = migrates
		}
		if rel.OneWay {
			plan.OneWay = true
			oneWay = append(oneWay, rel.Version)
		}
	}
	if plan.MariaDBUpgrade {
		plan.Database, plan.OneWay = migrates, true
	}
	if !plan.OneWay || !r.Opts.SkipBackup {
		return
	}
	reason := fmt.Sprintf("%s cannot be undone by restarting the previous images", strings.Join(oneWay, ", "))
	if plan.MariaDBUpgrade {
		reason = fmt.Sprintf("MariaDB moves from %s to %s and its data files are rewritten for good", plan.RunningMariaDBSeries, plan.MariaDBSeries)
	}
	plan.Blockers = append(plan.Blockers, fmt.Sprintf("--skip-backup cannot be used here: %s, so the backup is the only way back; run the upgrade without --skip-backup", reason))
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
		plan.Blockers = append(plan.Blockers, fmt.Sprintf("%s needs Docker Compose %s or newer and the installed one could not be read (%s): install the Docker Compose plugin %s or newer", plan.Target.Version, min, firstLine(err.Error()), min))
		return
	}
	plan.ComposeVersion = v
	if _, perr := semver.Parse(v); perr == nil && semver.Less(v, min) {
		plan.Blockers = append(plan.Blockers, fmt.Sprintf("%s needs Docker Compose %s or newer, this machine has %s: upgrade the Docker Compose plugin first", plan.Target.Version, min, v))
	}
}

// planEngine reads what the engine said of itself: where it keeps its
// images and what it runs on. The release images are built for linux/amd64
// only, so another machine cannot run them. Plan stops before it when the
// engine does not answer; an answer lost since then leaves the usual image
// directory to measure.
func planEngine(plan *Plan, info dockerx.EngineInfo, err error) {
	plan.DockerRoot = defaultDockerRoot
	if err != nil {
		return
	}
	plan.Architecture = info.Architecture
	if info.RootDir != "" {
		plan.DockerRoot = info.RootDir
	}
	if !info.AMD64() {
		plan.Blockers = append(plan.Blockers, fmt.Sprintf("the Docker engine runs on %s and the release images are built for x86_64 (linux/amd64) only: run the stack on an x86_64 machine to take releases", info.Architecture))
	}
}

// planCheckout keeps an upgrade from taking an adopted git checkout back in
// time (CheckoutAhead).
func (r *Runner) planCheckout(plan *Plan, state *instance.State) {
	if !CheckoutAhead(state, plan.Target.Commit, plan.Target.Date) {
		return
	}
	commit := state.AdoptedCommit
	if len(commit) > 12 {
		commit = commit[:12]
	}
	plan.Blockers = append(plan.Blockers, fmt.Sprintf("this stack is the git checkout of commit %s, made on %s, and %s was released on %s: installing it would take the files back to an older state; wait for a newer release", commit, state.AdoptedCommitDate.UTC().Format(commitTime), plan.Target.Version, releaseTime(plan.Target.Date)))
}

// CheckoutAhead reports whether the stack runs the git checkout it was
// adopted from and a release of commit, dated date, would take it back in
// time. Adopt records the commit of the checkout and its date; a release
// published before that commit would lay older files over it. A release is
// dated by the time of its own commit, so the two compare to the second (a
// date that names only a day covers the whole day), and a release cut from
// the very commit adopted is the same content. Once the stack runs release
// files, the check has nothing left to protect. The plan blocks such an
// upgrade by this rule, and the update reminder and status leave out such a
// release by it too.
func CheckoutAhead(state *instance.State, commit, date string) bool {
	if state.AdoptedCommit == "" || state.AdoptedCommitDate.IsZero() || state.Current != adoptedVersion(state) {
		return false
	}
	if commit != "" && commit == state.AdoptedCommit {
		return false
	}
	released, ok := releaseEnd(date)
	return ok && state.AdoptedCommitDate.After(released)
}

// commitTime is the form of the two times planCheckout compares: to the
// second, as it compares them.
const commitTime = "2006-01-02 15:04:05 UTC"

// releaseTime writes a release date the way commitTime writes the commit of
// the checkout next to it; a date that names only a day stays as it is.
func releaseTime(date string) string {
	if t, err := time.Parse(time.RFC3339, date); err == nil {
		return t.UTC().Format(commitTime)
	}
	return date
}

// adoptedVersion is the version the last adopt recorded, "" when the stack
// was never adopted.
func adoptedVersion(state *instance.State) string {
	for i := len(state.History) - 1; i >= 0; i-- {
		if state.History[i].Action == "adopt" {
			return state.History[i].Version
		}
	}
	return ""
}

// releaseEnd is the last moment a release date covers: the time itself
// for a full timestamp, the end of the day for a day.
func releaseEnd(date string) (time.Time, bool) {
	if t, err := time.Parse(time.RFC3339, date); err == nil {
		return t, true
	}
	if t, err := time.Parse("2006-01-02", date); err == nil {
		return t.Add(24 * time.Hour), true
	}
	return time.Time{}, false
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
		plan.Blockers = append(plan.Blockers, fmt.Sprintf("the release files of %s could not be checked (%v): pass --allow-local-changes to upgrade anyway", plan.installed(), err))
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
	plan.Blockers = append(plan.Blockers, fmt.Sprintf("%d %s since %s was installed (%s%s): the upgrade would overwrite them; copy them aside, or pass --allow-local-changes", len(changed), changedWord, plan.installed(), strings.Join(shown, ", "), suffix))
}

// planBundle reads the bundle of the target the way the run downloads it,
// held to the size and the sha256 the signed manifest gives, in one pass
// that writes nothing: the list of its files, and its compose file, which
// compose reads to tell the services of the target. What the operator
// keeps where the release lays a file or needs a directory blocks: the lay
// would refuse it once the backup is taken and the images pulled, and the
// run would roll back for it. A bundle that cannot be read blocks too. It
// returns the services compose runs here once the files of the target are
// laid (targetServices), nil when they could not be told.
func (r *Runner) planBundle(ctx context.Context, plan *Plan, state *instance.State) map[string]bool {
	const composeFile = "docker/docker-compose.yml"
	b := plan.Target.Bundle
	files, kept, err := release.ReadBundle(ctx, b.URL, b.SHA256, b.Size, 1<<20, composeFile)
	if err != nil {
		plan.Blockers = append(plan.Blockers, fmt.Sprintf("the bundle of %s could not be read (%s): run the command again once it can be downloaded", plan.Target.Version, firstLine(err.Error())))
		return nil
	}
	if problems := release.Conflicts(r.Inst.Root, files, state.Files); len(problems) > 0 {
		plan.Blockers = append(plan.Blockers, fmt.Sprintf("%s cannot lay its files: %s", plan.Target.Version, strings.Join(problems, "; ")))
	}
	compose, ok := kept[composeFile]
	if !ok {
		return nil
	}
	return r.targetServices(ctx, compose)
}

// targetServices lists the services compose runs here once the files of
// the target are laid. Compose itself reads compose, the compose file of
// the bundle, with the profiles that COMPOSE_PROFILES of this stack turns
// on, a setting an upgrade never changes. Each variable the file requires
// a value of gets a placeholder: the values decide nothing of the list,
// and no secret of the .env is passed on. It returns nil when compose
// could not tell.
func (r *Runner) targetServices(ctx context.Context, compose []byte) map[string]bool {
	env := map[string]string{}
	for _, key := range requiredVariables(compose) {
		// A placeholder compose takes for a number, a name or a path alike.
		env[key] = "1"
	}
	// Set last, it replaces a placeholder of the same name.
	env["COMPOSE_PROFILES"] = r.Inst.Env["COMPOSE_PROFILES"]
	services, err := dockerx.ServicesOf(ctx, compose, env)
	if err != nil {
		return nil
	}
	set := map[string]bool{}
	for _, s := range services {
		set[s] = true
	}
	return set
}

// requiredVariables lists, sorted and once each, the variables a compose
// file cannot do without (requiredRe).
func requiredVariables(compose []byte) []string {
	var names []string
	for _, m := range requiredRe.FindAllSubmatch(compose, -1) {
		names = append(names, string(m[1]))
	}
	slices.Sort(names)
	return slices.Compact(names)
}

// planHealth is the check before anything changes: which services compose
// runs here, and which of their containers are not healthy right now. An
// upgrade over a stack that is already failing cannot tell its own failure
// from the one it found, so it would roll back for nothing; the operator
// repairs the stack first, or accepts the failing services, which the
// verification then leaves out. MariaDB is never accepted that way: php-fpm
// and manticore wait for it to be healthy before compose starts them, so
// the restart of the upgrade, and every rollback after it, would leave them
// stopped. A stack none of whose services runs (running is what the engine
// listed) needs starting, not repairs. A container still starting is no
// problem: it gets its health window like any other. It returns the active
// services, nil when compose could not list them.
func (r *Runner) planHealth(ctx context.Context, plan *Plan, running map[string]dockerx.ServiceImage) map[string]bool {
	services, err := dockerx.ActiveServices(ctx, r.Inst.DockerDir)
	if err != nil {
		plan.Blockers = append(plan.Blockers, fmt.Sprintf("the services of the stack could not be listed (%s): fix the compose project in %s first", firstLine(err.Error()), r.Inst.DockerDir))
		return nil
	}
	plan.ActiveServices = services
	active := map[string]bool{}
	for _, s := range services {
		active[s] = true
	}
	unhealthy, failing, err := r.unhealthy(ctx, services)
	if err != nil {
		plan.Blockers = append(plan.Blockers, fmt.Sprintf("the containers of the stack could not be read (%s): start Docker, then run the command again", firstLine(err.Error())))
		return active
	}
	plan.Unhealthy = unhealthy
	if len(failing) == 0 {
		return active
	}
	if stackDown(services, running) {
		plan.Blockers = append(plan.Blockers, fmt.Sprintf("the stack is down: start it with 'docker compose up -d' in %s, then run 'kvsctl check' again", r.Inst.DockerDir))
		return active
	}
	if slices.Contains(failing, mariadbService) {
		plan.Blockers = append(plan.Blockers, fmt.Sprintf("the stack is not healthy before the upgrade: %s; repair MariaDB first: --allow-unhealthy cannot leave it out, because php-fpm and manticore wait for MariaDB to be healthy and compose would not start them", strings.Join(plan.Unhealthy, "; ")))
		return active
	}
	if r.Opts.AllowUnhealthy {
		plan.Ignored = failing
		return active
	}
	plan.Blockers = append(plan.Blockers, fmt.Sprintf("the stack is not healthy before the upgrade: %s; repair it first, or pass --allow-unhealthy", strings.Join(plan.Unhealthy, "; ")))
	return active
}

// stackDown reports whether none of the active services runs, the way
// 'docker compose stop' or 'down', or a reboot without restart policies,
// leaves a stack: each has no container, or one that exited, was only
// created or is dead. A container restarting or paused is a service that
// fails, not a stack that is down.
func stackDown(services []string, running map[string]dockerx.ServiceImage) bool {
	for _, s := range services {
		if strings.HasSuffix(s, "-init") {
			continue
		}
		switch svc, ok := running[s]; {
		case !ok, svc.State == "exited", svc.State == "created", svc.State == "dead":
		default:
			return false
		}
	}
	return true
}

// restartedLately is how far back the check before a change looks for a
// restart by the engine. A container in a crash loop reads as running, and
// healthy even, between two crashes, and the verification would then count
// its restarts against the release. A minute covers every loop that wait
// catches on its own (three restarts within its two minutes) whatever the
// moment of the check, and a container that crashed that recently is worth
// a second look anyway.
const restartedLately = time.Minute

// unhealthy reads which of the active services are not healthy right now:
// a container that is unhealthy, restarting or not running, one the engine
// restarted less than restartedLately ago, and a service with no
// container, which the run would give its first one and then blame for a
// reason older than the run. A container still starting is no problem: it
// gets its health window like any other. It returns what is wrong, one
// line each, and the services concerned, sorted.
func (r *Runner) unhealthy(ctx context.Context, services []string) (problems, failing []string, err error) {
	active := map[string]bool{}
	for _, s := range services {
		active[s] = true
	}
	states, err := r.Docker.Containers(ctx, r.Inst.ProjectName())
	if err != nil {
		return nil, nil, err
	}
	now := time.Now()
	bad := map[string]bool{}
	seen := map[string]bool{}
	for _, s := range states {
		if !judged(s) || !active[s.Service] {
			continue
		}
		seen[s.Service] = true
		if problem := preflightProblem(s, now); problem != "" {
			problems = append(problems, problem)
			bad[s.Service] = true
		}
	}
	for _, s := range services {
		if !seen[s] && !strings.HasSuffix(s, "-init") {
			problems = append(problems, "service "+s+" has no container")
			bad[s] = true
		}
	}
	for service := range bad {
		failing = append(failing, service)
	}
	sort.Strings(failing)
	return problems, failing, nil
}

// preflightProblem says what is wrong with one container before a change,
// "" when nothing is: running and healthy, without a health check, or
// still starting, and not restarted by the engine within restartedLately.
func preflightProblem(s dockerx.ContainerState, now time.Time) string {
	if s.State != "running" || (s.Health != "" && s.Health != "healthy" && s.Health != "starting") {
		return describeContainer(s)
	}
	if up := now.Sub(s.Started); s.Restarts > 0 && up < restartedLately {
		times := "once"
		if s.Restarts > 1 {
			times = fmt.Sprintf("%d times", s.Restarts)
		}
		ago := up.Round(time.Second).String() + " ago"
		if up < time.Second {
			ago = "less than a second ago"
		}
		return fmt.Sprintf("%s was restarted %s by the engine, the last time %s", s.Name, times, ago)
	}
	return ""
}

// planImages lists every image of the release with what the machine holds
// of it, and the ones to pull: those of the services compose runs here,
// now (active) or once the files of the target are laid (coming), which
// the engine does not hold at the release digest. The image of a service
// the target turns on, one it adds or one it takes out of a profile that
// is off, would otherwise be pulled by compose while the stack restarts,
// where a failed pull rolls the upgrade back; pulled with the others, it
// fails before anything changed. active is nil when compose could not list
// the services, and every image then counts; coming is nil when the
// services of the target could not be told, and the ones compose runs now
// count.
func (r *Runner) planImages(ctx context.Context, plan *Plan, running map[string]dockerx.ServiceImage, active, coming map[string]bool) {
	local, _ := r.Docker.LocalDiffIDs(ctx)
	for _, img := range plan.Images {
		item := PlanImage{Image: img, Active: active == nil || active[img.Service] || coming[img.Service]}
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
			if item.Active {
				plan.ImagesToPull = append(plan.ImagesToPull, item)
				plan.Bytes += item.Bytes
			}
		}
		if img.Service == mariadbService && item.Active && !item.Unchanged {
			plan.MariaDBImageChanges = true
		}
		plan.Services = append(plan.Services, item)
	}
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

// measure reads the free space of the filesystem under a path; the tests
// stand in for it to give paths filesystems and free space of their own.
var measure = diskspace.Measure

// planDisk measures what the upgrade writes, filesystem by filesystem: the
// images it pulls, the bundle and the files it unpacks and lays, the
// backup, and for a one-way upgrade the second copy of the database a
// rollback builds while the files of the new server stay in their volume.
// Directories on one filesystem share its free space, so their needs add
// up there. A size, a data directory or a filesystem that cannot be read
// is listed in DiskUnknown with the reason, never held against the
// machine: check prints it, and upgrade before it asks, for the operator
// to judge.
func (r *Runner) planDisk(ctx context.Context, plan *Plan) {
	type need struct {
		path  string
		bytes int64
		what  string
		// at is where the filesystem of path is measured, path itself
		// when empty.
		at string
		// images marks the need of the pulled layers.
		images bool
	}
	pulled := fmt.Sprintf("the images to pull (%s, counted twice for their unpacked layers)", humanBytes(plan.Bytes))
	var needs []need
	switch layers, at, err := layerSpace(plan.DockerRoot); {
	case layers != "":
		// The layers go to the filesystem of containerd, and the root of
		// the engine keeps the margin for what the engine writes itself.
		needs = append(needs,
			need{path: layers, at: at, bytes: plan.Bytes * 2, what: pulled + ", which containerd keeps", images: true},
			need{path: plan.DockerRoot, bytes: gib, what: "1 GiB for the engine"})
	default:
		if err != nil {
			plan.DiskUnknown = append(plan.DiskUnknown, fmt.Sprintf("%s: they are counted under %s", err, plan.DockerRoot))
		}
		needs = append(needs, need{path: plan.DockerRoot, bytes: plan.Bytes*2 + gib, what: pulled + " and 1 GiB for the engine", images: true})
	}
	needs = append(needs, need{path: r.Inst.StateDir(), bytes: plan.Target.Bundle.Size*3 + 200*mib, what: fmt.Sprintf("the bundle (%s) downloaded, unpacked and laid, and 200 MiB", humanBytes(plan.Target.Bundle.Size))})
	if !r.Opts.SkipBackup {
		plan.DumpEstimate, plan.DumpSource = r.estimateDump(ctx, plan)
		if plan.DumpEstimate > 0 {
			needs = append(needs, need{path: r.Inst.BackupDir(), bytes: plan.DumpEstimate, what: fmt.Sprintf("the backup (about %s, %s)", humanBytes(plan.DumpEstimate), plan.DumpSource)})
		}
	}
	if plan.OneWay {
		switch datadir, at, size, why := r.secondCopy(ctx, plan); {
		case why != "":
			plan.DiskUnknown = append(plan.DiskUnknown, "a second copy of the database, which a rollback of this one-way upgrade replays while the files of the new server stay in the volume: "+why)
		case size > 0:
			needs = append(needs, need{path: datadir, at: at, bytes: size * 6 / 5, what: fmt.Sprintf("a second copy of the database (%s and a fifth more), which a rollback replays while the files of the new server stay in the volume", humanBytes(size))})
		}
	}
	var groups []*DiskNeed
	byDevice := map[uint64]*DiskNeed{}
	var images *DiskNeed
	for _, n := range needs {
		at := n.path
		if n.at != "" {
			at = n.at
		}
		space, err := measure(at)
		if err != nil {
			plan.DiskUnknown = append(plan.DiskUnknown, fmt.Sprintf("%s: the filesystem of %s could not be read (%s)", n.what, n.path, firstLine(err.Error())))
			continue
		}
		g := byDevice[space.Device]
		if g == nil || space.Device == 0 {
			g = &DiskNeed{Free: space.Avail}
			if space.Device != 0 {
				byDevice[space.Device] = g
			}
			groups = append(groups, g)
		}
		g.Paths = append(g.Paths, n.path)
		g.Needed += n.bytes
		g.Parts = append(g.Parts, n.what)
		if n.images {
			images = g
		}
	}
	for _, g := range groups {
		plan.Disk = append(plan.Disk, *g)
		if g.Free < g.Needed {
			plan.Blockers = append(plan.Blockers, fmt.Sprintf("%s free on the filesystem of %s is not enough: %s need %s; free some space there ('kvsctl clean' removes what earlier upgrades left, old backups are in %s) and run 'kvsctl check' again", humanBytes(g.Free), strings.Join(g.Paths, " and "), strings.Join(g.Parts, ", "), humanBytes(g.Needed), r.Inst.BackupDir()))
		}
	}
	if images != nil {
		plan.DiskFree, plan.DiskNeeded = images.Free, images.Needed
	}
}

// secondCopy is what the rollback of a one-way upgrade writes: the data
// directory of MariaDB, which holds the second copy of the database while
// the files of the new server stay there, where its filesystem is measured
// (reachable), and what the tables take. why says what could not be read,
// "" when nothing failed.
func (r *Runner) secondCopy(ctx context.Context, plan *Plan) (datadir, at string, size int64, why string) {
	size, err := r.databaseSize(ctx, plan)
	if err != nil {
		return "", "", 0, fmt.Sprintf("the size of the database could not be read (%s)", firstLine(err.Error()))
	}
	if datadir, err = r.Docker.MountSource(ctx, r.mariadbContainer(), mariadbDataDir); err != nil {
		return "", "", 0, fmt.Sprintf("the data directory of MariaDB could not be found (%s)", firstLine(err.Error()))
	}
	if at, err = reachable(datadir); err != nil {
		return "", "", 0, fmt.Sprintf("the filesystem of %s could not be read (%s)", datadir, firstLine(err.Error()))
	}
	return datadir, at, size, ""
}

// announceDisk logs, before the question, what the plan could not measure
// on disk: the room whoever says yes takes on trust.
func (r *Runner) announceDisk(plan *Plan) {
	for _, u := range plan.DiskUnknown {
		r.log("not measured: " + u)
	}
	if plan.DumpEstimate == 0 && plan.DumpSource != "" {
		r.log("not measured: the room of the backup, whose size is " + plan.DumpSource)
	}
}

// mountInfo lists the mounts kvsctl sees; the tests hand in their own.
var mountInfo = "/proc/self/mountinfo"

// layerDir is where the engine keeps the layers of its images when that is
// outside its root, "" when it is inside or when no mount tells. With the
// containerd image store, the default of a fresh Docker 29, a pull lands in
// the snapshotter of containerd, under the root of containerd
// (/var/lib/containerd unless its configuration moves it), and the root of
// the engine only holds the mount points of the containers. The Engine API
// names neither of the two, the mounts of the running containers do: their
// mount point is under the root of the engine and their lower directories
// are the layers of their image.
func layerDir(root string) (string, error) {
	f, err := os.Open(mountInfo)
	if err != nil {
		return "", err
	}
	defer f.Close()
	inside := strings.TrimSuffix(root, "/") + "/"
	scanner := bufio.NewScanner(f)
	scanner.Buffer(make([]byte, 64<<10), 1<<20)
	for scanner.Scan() {
		// mount ID, parent ID, device, root, mount point, options, optional
		// fields, "-", filesystem type, source, filesystem options.
		fields := strings.Fields(scanner.Text())
		sep := slices.Index(fields, "-")
		if sep < 5 || sep+3 >= len(fields) || fields[sep+1] != "overlay" || !strings.HasPrefix(unescapeMount(fields[4]), inside) {
			continue
		}
		for _, option := range strings.Split(fields[sep+3], ",") {
			_, dirs, found := strings.Cut(option, "lowerdir=")
			if !found {
				_, dirs, found = strings.Cut(option, "lowerdir+=")
			}
			if !found {
				continue
			}
			first, _, _ := strings.Cut(dirs, ":")
			if first = unescapeMount(first); !strings.HasPrefix(first, "/") || strings.HasPrefix(first, inside) {
				break
			}
			// The directory of every snapshot, not one of them.
			if i := strings.Index(first, "/snapshots/"); i > 0 {
				first = first[:i]
			}
			return first, nil
		}
	}
	return "", scanner.Err()
}

// layerSpace is where the engine keeps the layers it pulls when that is
// outside its root (layerDir), with the path their filesystem is measured
// at (reachable). An error says why the layers are counted under the root
// of the engine instead.
func layerSpace(root string) (layers, at string, err error) {
	layers, err = layerDir(root)
	if layers == "" {
		if err != nil {
			err = fmt.Errorf("where the engine keeps the layers it pulls could not be read (%s)", firstLine(err.Error()))
		}
		return "", "", err
	}
	if at, err = reachable(layers); err != nil {
		return "", "", fmt.Errorf("the filesystem of %s, where containerd keeps the layers it pulls, could not be read (%s)", layers, firstLine(err.Error()))
	}
	return layers, at, nil
}

// reachable is the path the filesystem of path is measured at: path
// itself, or, when kvsctl cannot reach it, the mount point of its
// filesystem. The directories of the engine are root's alone (the root of
// containerd is 0700, /var/lib/docker 0710 and its volumes below it), and
// check runs as any user the engine answers. The error is the one path
// itself gave.
func reachable(path string) (string, error) {
	_, err := measure(path)
	if err == nil {
		return path, nil
	}
	if mount, mountErr := mountOf(path); mountErr == nil {
		if _, mountErr = measure(mount); mountErr == nil {
			return mount, nil
		}
	}
	return "", err
}

// mountOf is the mount point of the filesystem that holds path, from the
// mounts kvsctl sees: the deepest one path is under.
func mountOf(path string) (string, error) {
	f, err := os.Open(mountInfo)
	if err != nil {
		return "", err
	}
	defer f.Close()
	found := ""
	scanner := bufio.NewScanner(f)
	scanner.Buffer(make([]byte, 64<<10), 1<<20)
	for scanner.Scan() {
		fields := strings.Fields(scanner.Text())
		if len(fields) < 5 {
			continue
		}
		if point := unescapeMount(fields[4]); strings.HasPrefix(path+"/", strings.TrimSuffix(point, "/")+"/") && len(point) > len(found) {
			found = point
		}
	}
	if err := scanner.Err(); err != nil {
		return "", err
	}
	if found == "" {
		return "", fmt.Errorf("no mount holds %s", path)
	}
	return found, nil
}

// unescapeMount undoes the octal escapes mountinfo writes for a space, a
// tab, a new line, a backslash, a comma or an equals sign in a path.
func unescapeMount(s string) string {
	if !strings.Contains(s, `\`) {
		return s
	}
	var b strings.Builder
	for i := 0; i < len(s); i++ {
		if s[i] == '\\' && i+3 < len(s) && s[i+1] >= '0' && s[i+1] <= '3' && isOctal(s[i+2]) && isOctal(s[i+3]) {
			b.WriteByte((s[i+1]-'0')<<6 | (s[i+2]-'0')<<3 | (s[i+3] - '0'))
			i += 3
			continue
		}
		b.WriteByte(s[i])
	}
	return b.String()
}

func isOctal(c byte) bool { return c >= '0' && c <= '7' }

// estimateDump is what the backup is expected to take: half again the
// newest backup of this site, or, without one, half of what its tables
// take, which is about what zstd leaves of a dump.
func (r *Runner) estimateDump(ctx context.Context, plan *Plan) (int64, string) {
	if list, err := backup.List(r.Inst.BackupDir()); err == nil {
		for _, b := range list {
			if b.CompressedBytes > 0 && (b.Domain == "" || b.Domain == r.Inst.Domain()) {
				return b.CompressedBytes * 3 / 2, "half again the dump of " + b.Name
			}
		}
	}
	if size, err := r.databaseSize(ctx, plan); err == nil && size > 0 {
		return size / 2, "half the " + humanBytes(size) + " its tables take"
	}
	return 0, "unknown: no earlier backup, and the size of the tables could not be read"
}

// databaseSize reads once what the tables of the site take, and why the
// database could not tell.
func (r *Runner) databaseSize(ctx context.Context, plan *Plan) (int64, error) {
	if !plan.sizeRead {
		plan.sizeRead = true
		plan.DatabaseSize, plan.sizeErr = backup.DatabaseSize(ctx, r.mariadbContainer())
	}
	return plan.DatabaseSize, plan.sizeErr
}

// installed names the installed version the way the operator reads it.
func (p *Plan) installed() string { return labelOr(p.CurrentLabel, p.Current) }

// previous names the previous version the way the operator reads it.
func (p *Plan) previous() string { return labelOr(p.PreviousLabel, p.Previous) }

// labelOr is the label of a version, or the version itself for a plan
// built without labels.
func labelOr(label, version string) string {
	if label != "" {
		return label
	}
	return version
}

// DowngradeMessage says what to do about a target older than the installed
// version, which is a rollback and not an upgrade. A stack ahead of the
// latest stable release, on a release candidate the manifest does not list,
// has nothing to upgrade to. kvsctl never installs an older release:
// without a previous version to roll back to, what is left is the database.
func (p *Plan) DowngradeMessage() string {
	switch {
	case p.latest:
		return fmt.Sprintf("the installed %s is newer than %s, the latest stable release: there is nothing to upgrade to", p.installed(), p.Target.Version)
	case p.Previous == "":
		return fmt.Sprintf("%s is older than the installed %s, and kvsctl cannot install an older release on this stack: no previous version is recorded for a rollback; 'kvsctl restore' replays a backup of the database, and going back to %s means installing it anew", p.Target.Version, p.installed(), p.Target.Version)
	}
	return fmt.Sprintf("%s is older than the installed %s: use 'kvsctl rollback' (previous is %s)", p.Target.Version, p.installed(), p.previous())
}

// mariadbContainer is the name of the database container.
func (r *Runner) mariadbContainer() string { return r.Inst.ContainerPrefix() + "-mariadb" }
