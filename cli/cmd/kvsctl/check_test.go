package main

import (
	"bytes"
	"context"
	"fmt"
	"os"
	"strings"
	"testing"

	"github.com/MaximeMichaud/KVS-install/cli/internal/instance"
	"github.com/MaximeMichaud/KVS-install/cli/internal/manifest"
	"github.com/MaximeMichaud/KVS-install/cli/internal/upgrade"
)

// useFlags sets the flags of every command check repeats, for the length
// of the test.
func useFlags(t *testing.T, root, manifestURL string, allowStale bool) {
	t.Helper()
	oldRoot, oldManifest, oldStale := flagRoot, flagManifest, flagAllowStale
	flagRoot, flagManifest, flagAllowStale = root, manifestURL, allowStale
	t.Cleanup(func() { flagRoot, flagManifest, flagAllowStale = oldRoot, oldManifest, oldStale })
}

// The upgrade check says to run is the one it checked: every flag that
// changes what the upgrade does comes along, written so that a shell reads
// each value back as it was given.
func TestUpgradeCommandRepeatsTheFlags(t *testing.T) {
	useFlags(t, "", "", false)
	if got := upgradeCommand("", "", false, false); got != "kvsctl upgrade" {
		t.Fatalf("without flags: %q", got)
	}
	useFlags(t, "/srv/my kvs", "https://example.com/rc/manifest.json", true)
	want := `kvsctl upgrade --root "/srv/my kvs" --manifest https://example.com/rc/manifest.json --allow-stale-manifest --version 1.1.0 --mariadb-series 12.3 --allow-local-changes --allow-unhealthy`
	if got := upgradeCommand("1.1.0", "12.3", true, true); got != want {
		t.Fatalf("upgradeCommand = %q, want %q", got, want)
	}
	for value, want := range map[string]string{
		"/opt/kvs":         "/opt/kvs",
		`/srv/a"b`:         `"/srv/a\"b"`,
		"/srv/$HOME`x`\\y": "\"/srv/\\$HOME\\`x\\`\\\\y\"",
		"/srv/it's":        `"/srv/it's"`,
	} {
		if got := shellWord(value); got != want {
			t.Errorf("shellWord(%q) = %s, want %s", value, got, want)
		}
	}
}

// While another kvsctl holds the lock, an upgrade would exit 6: the
// verdict names that run instead of saying to start one now.
func TestReadyLine(t *testing.T) {
	root := newRoot(t)
	inst := saveState(t, root, failedState())
	if got, want := readyLine(inst, "kvsctl upgrade --version 1.1.0"), "run 'kvsctl upgrade --version 1.1.0'"; got != want {
		t.Fatalf("readyLine = %q, want %q", got, want)
	}
	unlock, err := inst.Lock("backup")
	if err != nil {
		t.Fatal(err)
	}
	defer unlock()
	want := fmt.Sprintf("run 'kvsctl upgrade' once the kvsctl running now ends: another kvsctl is running (pid %d, backup, started just now)", os.Getpid())
	if got := readyLine(inst, "kvsctl upgrade"); got != want {
		t.Fatalf("with the lock held: %q, want %q", got, want)
	}
}

// The plan says how the stack is doing in the words that fit: a stack that
// is down needs starting, which down says in place of the health of each
// service. It names the upgrade that failed last, and leaves the verdict
// of a plan nothing blocks to check, which knows the flags it was given.
func TestPrintPlan(t *testing.T) {
	root := newRoot(t)
	inst := saveState(t, root, failedState())
	m := &manifest.Manifest{Releases: []manifest.Release{
		{Version: "1.1.0", Date: "2026-10-05T18:39:32Z", Notes: "nginx 1.29"},
		{Version: "1.0.0", Date: "2026-09-01"},
	}}
	plan := &upgrade.Plan{
		Current:        "1.0.0",
		Target:         &m.Releases[0],
		Manifest:       m,
		Releases:       m.Releases[:1],
		ActiveServices: []string{"mariadb", "nginx"},
		Unhealthy:      []string{"service mariadb has no container", "service nginx has no container"},
		TrackedFiles:   3,
	}
	down := noServices(inst, false)
	var out bytes.Buffer
	printPlan(&out, plan, inst, failedState(), down, "")
	text := out.String()
	for _, want := range []string{
		"Manifest     2 releases, latest stable 1.1.0 (2026-10-05)\n",
		"Target       1.1.0 (2026-10-05)\n",
		"Health       " + down + "\n",
		"Last upgrade to 1.1.0 failed on 2026-10-07 00:57 UTC and was rolled back: not healthy after 1s: kvs-nginx is unhealthy\n",
	} {
		if !strings.Contains(text, want) {
			t.Errorf("the plan lacks %q:\n%s", want, text)
		}
	}
	if strings.Contains(text, "has no container") || strings.Contains(text, "Ready") {
		t.Fatalf("the plan of a stack that is down:\n%s", text)
	}
	plan.Blockers = []string{"the stack is not healthy before the upgrade"}
	out.Reset()
	printPlan(&out, plan, inst, failedState(), "", "")
	if text := out.String(); !strings.Contains(text, "Blocked\n  - the stack is not healthy before the upgrade\n") || !strings.Contains(text, "Health       service mariadb has no container; service nginx has no container\n") {
		t.Fatalf("a blocked plan:\n%s", text)
	}
}

// The Download line counts the images the pull step counts: one the
// container of its service already runs, which the engine holds under
// another name than the release gives it, downloads nothing. What could
// not be measured follows, under the Disk label when nothing was.
func TestPrintPlanCountsWhatThePullDownloads(t *testing.T) {
	root := newRoot(t)
	state := &instance.State{Current: "1.0.0", Files: []string{"docker/docker-compose.yml"}}
	inst := saveState(t, root, state)
	plan := readyPlan()
	plan.Bytes = 2048
	plan.ImagesToPull = []upgrade.PlanImage{
		{Image: manifest.Image{Service: "nginx", Ref: "example/nginx:1.1.0"}, Bytes: 2048, Active: true},
		{Image: manifest.Image{Service: "php-fpm", Ref: "example/php:1.1.0"}, Active: true, Unchanged: true},
	}
	plan.DiskUnknown = []string{"the layers: unknown root", "a second copy of the database: unknown size"}
	var out bytes.Buffer
	printPlan(&out, plan, inst, state, "", "")
	want := "Download     2 kB over 1 image\n" +
		"Disk         not measured: the layers: unknown root\n" +
		"             not measured: a second copy of the database: unknown size\n"
	if text := out.String(); !strings.Contains(text, want) {
		t.Fatalf("the plan lacks\n%s\nin\n%s", want, text)
	}
}

// usePlan stands plan in for the plan check and upgrade make, for the
// length of the test, and returns the options of the runner it was asked
// for, which carry the flags of the command.
func usePlan(t *testing.T, plan *upgrade.Plan) *upgrade.Options {
	t.Helper()
	old := planUpgrade
	opts := &upgrade.Options{}
	planUpgrade = func(r *upgrade.Runner, _ context.Context, _ *instance.State) (*upgrade.Plan, error) {
		*opts = r.Opts
		return plan, nil
	}
	t.Cleanup(func() { planUpgrade = old })
	return opts
}

// readyPlan is a plan nothing blocks, from 1.0.0 to 1.1.0, in a manifest
// whose latest release, 1.2.0, upgrades from 1.1.0 only.
func readyPlan() *upgrade.Plan {
	m := &manifest.Manifest{Releases: []manifest.Release{
		{Version: "1.2.0", Date: "2026-10-05", Requires: manifest.Requires{MinFrom: "1.1.0"}},
		{Version: "1.1.0", Date: "2026-10-01", Notes: "nginx 1.29"},
		{Version: "1.0.0", Date: "2026-09-01"},
	}}
	return &upgrade.Plan{Current: "1.0.0", Target: &m.Releases[1], Manifest: m, Releases: m.Releases[1:2], TrackedFiles: 1}
}

// check ends a plan nothing blocks with the upgrade it checked, the flags
// it was given included, and while another kvsctl holds the lock, with
// that run to wait for. What the plan read of the manifest is kept for
// the reminder and status.
func TestCheckSaysTheUpgradeToRun(t *testing.T) {
	root := newRoot(t)
	useRoot(t, root)
	useStderr(t)
	inst := saveState(t, root, &instance.State{Current: "1.0.0", Files: []string{"docker/docker-compose.yml"}})
	opts := usePlan(t, readyPlan())
	const url = "https://example.com/rc/manifest.json"
	args := []string{"check", "--root", root, "--manifest", url, "--version", "1.1.0", "--allow-local-changes"}
	out, err := runKvsctl(t, args...)
	if err != nil {
		t.Fatalf("check: %v\n%s", err, out)
	}
	command := "kvsctl upgrade --root " + root + " --manifest " + url + " --version 1.1.0 --allow-local-changes"
	if want := "Ready        run '" + command + "'\n"; !strings.HasSuffix(out, want) {
		t.Errorf("check does not end with %q:\n%s", want, out)
	}
	if opts.Version != "1.1.0" || !opts.AllowLocalChanges || opts.AllowUnhealthy || opts.ManifestURL != url {
		t.Errorf("the plan was asked with %+v", *opts)
	}
	if known := loadLatestKnown(inst)[url]; known == nil || known.Version != "1.2.0" || known.MinFrom["1.2.0"] != "1.1.0" {
		t.Errorf("the read of check was not kept: %+v", known)
	}

	unlock, err := inst.Lock("upgrade")
	if err != nil {
		t.Fatal(err)
	}
	out, err = runKvsctl(t, args...)
	unlock()
	if err != nil {
		t.Fatalf("check: %v\n%s", err, out)
	}
	if want := fmt.Sprintf("Ready        run '%s' once the kvsctl running now ends: another kvsctl is running (pid %d, upgrade, started just now)\n", command, os.Getpid()); !strings.HasSuffix(out, want) {
		t.Errorf("with the lock held, check does not end with %q:\n%s", want, out)
	}
}

// A stack none of whose services runs is down, which check says in place
// of the health of each service, and it is blocked, so no upgrade is
// given to run.
func TestCheckSaysTheStackIsDown(t *testing.T) {
	root := newRoot(t, "docker/.env", "DOMAIN=example.com\nCOMPOSE_PROJECT_NAME=site\nSITE_PREFIX=site\n")
	useRoot(t, root)
	useStderr(t)
	inst := saveState(t, root, &instance.State{Current: "1.0.0", Files: []string{"docker/docker-compose.yml"}})
	plan := readyPlan()
	plan.ActiveServices = []string{"mariadb", "nginx"}
	plan.Unhealthy = []string{"service mariadb has no container", "service nginx has no container"}
	plan.Blockers = []string{"the stack is down"}
	usePlan(t, plan)
	fakeEngine(t, "site", func() []engineContainer { return nil })
	out, err := runKvsctl(t, "check", "--root", root)
	if err != nil {
		t.Fatalf("check: %v\n%s", err, out)
	}
	if want := "Health       " + noServices(inst, false) + "\n"; !strings.Contains(out, want) || strings.Contains(out, "has no container") || strings.Contains(out, "Ready") {
		t.Errorf("check of a stack that is down, want %q and no Ready:\n%s", want, out)
	}
}

// A stack that already runs the latest release with the images it pins has
// no upgrade to run: check says so, and gives no command.
func TestCheckOfAStackUpToDateGivesNoUpgrade(t *testing.T) {
	root := newRoot(t)
	useRoot(t, root)
	useStderr(t)
	saveState(t, root, &instance.State{Current: "1.2.0", Files: []string{"docker/docker-compose.yml"}})
	plan := readyPlan()
	plan.Current, plan.Target, plan.UpToDate = "1.2.0", &plan.Manifest.Releases[0], true
	usePlan(t, plan)
	out, err := runKvsctl(t, "check", "--root", root, "--manifest", "https://example.com/manifest.json")
	if err != nil {
		t.Fatalf("check: %v\n%s", err, out)
	}
	if !strings.Contains(out, "Target       1.2.0, already installed with the images it pins\n") || strings.Contains(out, "Ready") {
		t.Fatalf("check of a stack up to date:\n%s", out)
	}
}

// check warns about a signing key the manifest announces and this kvsctl
// does not carry: the day it signs, this kvsctl stops trusting the
// manifest, so update-cli has to run before then.
func TestCheckSaysTheAnnouncedKeys(t *testing.T) {
	root := newRoot(t)
	useRoot(t, root)
	useStderr(t)
	saveState(t, root, &instance.State{Current: "1.0.0", Files: []string{"docker/docker-compose.yml"}})
	plan := readyPlan()
	plan.Manifest.Keys = []manifest.Key{{ID: "k2027", ValidFrom: "2027-01-01"}}
	usePlan(t, plan)
	out, err := runKvsctl(t, "check", "--root", root, "--manifest", "https://example.com/manifest.json")
	if err != nil {
		t.Fatalf("check: %v\n%s", err, out)
	}
	if want := "Signing key  the manifest announces signing key k2027 from 2027-01-01, unknown to this kvsctl: run 'kvsctl update-cli' before then\n"; !strings.Contains(out, want) {
		t.Fatalf("check lacks %q:\n%s", want, out)
	}
}

// The Manifest line names the latest stable release, which an upgrade
// installs when no version is named, and a release candidate newer than
// it, which an upgrade installs only when it is; a list of candidates only
// names its newest.
func TestManifestSummary(t *testing.T) {
	m := &manifest.Manifest{Releases: []manifest.Release{
		{Version: "1.2.0-rc1", Date: "2026-10-09T08:00:00Z"},
		{Version: "1.1.0", Date: "2026-10-01"},
	}}
	if got, want := manifestSummary(m), "2 releases, latest stable 1.1.0 (2026-10-01), release candidate 1.2.0-rc1 (2026-10-09)"; got != want {
		t.Errorf("a candidate ahead: %q, want %q", got, want)
	}
	if got, want := manifestSummary(&manifest.Manifest{Releases: m.Releases[1:]}), "1 release, latest stable 1.1.0 (2026-10-01)"; got != want {
		t.Errorf("stable releases only: %q, want %q", got, want)
	}
	if got, want := manifestSummary(&manifest.Manifest{Releases: m.Releases[:1]}), "1 release, release candidates only, the newest 1.2.0-rc1 (2026-10-09)"; got != want {
		t.Errorf("candidates only: %q, want %q", got, want)
	}
}
