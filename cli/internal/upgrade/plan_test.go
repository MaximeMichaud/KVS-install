package upgrade

import (
	"archive/tar"
	"bytes"
	"compress/gzip"
	"context"
	"crypto/ed25519"
	"crypto/sha256"
	"encoding/base64"
	"encoding/hex"
	"encoding/json"
	"errors"
	"maps"
	"net"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"regexp"
	"slices"
	"strings"
	"testing"
	"time"

	"github.com/MaximeMichaud/KVS-install/cli/internal/backup"
	"github.com/MaximeMichaud/KVS-install/cli/internal/diskspace"
	"github.com/MaximeMichaud/KVS-install/cli/internal/dockerx"
	"github.com/MaximeMichaud/KVS-install/cli/internal/instance"
	"github.com/MaximeMichaud/KVS-install/cli/internal/manifest"
	"github.com/MaximeMichaud/KVS-install/cli/internal/semver"
)

// planWith plans with r on the state on disk as change leaves it.
func (s *stack) planWith(r *Runner, change func(*instance.State)) *Plan {
	s.t.Helper()
	state, err := r.Inst.LoadState()
	if err != nil {
		s.t.Fatal(err)
	}
	change(state)
	plan, err := r.Plan(context.Background(), state)
	if err != nil {
		s.t.Fatal(err)
	}
	return plan
}

// blocked checks that exactly one blocker was found, and that it says
// want.
func blocked(t *testing.T, plan *Plan, want string) {
	t.Helper()
	if len(plan.Blockers) != 1 || !strings.Contains(plan.Blockers[0], want) {
		t.Errorf("blockers %q, want one saying %q", plan.Blockers, want)
	}
}

// The MariaDB series of a release, by default 11.8 and 12.3.
var (
	threeSeries = map[string]string{"11.4": "11.4.13", "11.8": "11.8.9", "12.3": "12.3.3"}
	oldSeries   = map[string]string{"11.4": "11.4.13", "11.8": "11.8.9"}
)

// By default the stack keeps the MariaDB series it runs, and the image of
// that series is what .env gets.
func TestPlanKeepsTheMariaDBSeries(t *testing.T) {
	s := newStack(t, "11.8", rel{version: "1.0.0"}, rel{version: "1.1.0"})
	for _, asked := range []string{"", "11.8"} {
		_, plan := s.plan(s.runner(series(asked)))
		if len(plan.Blockers) != 0 || plan.MariaDBSeries != "11.8" || plan.RunningMariaDBSeries != "11.8" || plan.MariaDBUpgrade || plan.OneWay || plan.MariaDBImageChanges {
			t.Errorf("asked %q: %+v", asked, plan)
		}
		if got := plan.ImageEnv["KVS_MARIADB_IMAGE"]; got != s.pin("1.1.0", "mariadb@11.8") {
			t.Errorf("asked %q: KVS_MARIADB_IMAGE = %s", asked, got)
		}
	}
}

// A series change is refused unless it goes to the next series the
// target publishes, and never backwards; the refusal says what to run.
func TestPlanRefusesAnyOtherSeriesChange(t *testing.T) {
	s := newStack(t, "11.4", rel{version: "1.0.0", mariadb: threeSeries}, rel{version: "1.1.0", mariadb: threeSeries})
	_, plan := s.plan(s.runner(series("12.3")))
	blocked(t, plan, "MariaDB moves one series at a time: after 11.4 the next series 1.1.0 publishes is 11.8; run 'kvsctl upgrade --version 1.1.0 --mariadb-series 11.8' first")

	_, plan = s.plan(s.runner(series("11.8")))
	if len(plan.Blockers) != 0 || !plan.MariaDBUpgrade || plan.MariaDBSeries != "11.8" {
		t.Errorf("the next series was refused: %v", plan.Blockers)
	}

	s = newStack(t, "11.8", rel{version: "1.0.0", mariadb: threeSeries}, rel{version: "1.1.0", mariadb: threeSeries})
	_, plan = s.plan(s.runner(series("11.4")))
	blocked(t, plan, "MariaDB never goes back a series: this stack runs 11.8")
	_, plan = s.plan(s.runner(series("12.0")))
	blocked(t, plan, "1.1.0 publishes no MariaDB 12.0 image (it publishes 11.4, 11.8, 12.3)")
	_, plan = s.plan(s.runner(series("12.3"), func(o *Options) { o.SkipBackup = true }))
	blocked(t, plan, "--skip-backup cannot be used here: MariaDB moves from 11.8 to 12.3 and its data files are rewritten for good")
}

// A target that no longer publishes the running series blocks with the
// way out when a release offers one, and says there is none otherwise.
func TestPlanUnpublishedSeries(t *testing.T) {
	cases := []struct {
		name             string
		running          string
		installed, after map[string]string
		want             string
	}{
		{"way out", "11.4", oldSeries, map[string]string{"11.8": "11.8.9", "12.3": "12.3.3"},
			"1.1.0 publishes no MariaDB 11.4 image, the series this stack runs (it publishes 11.8, 12.3): move MariaDB to 11.8 first with 'kvsctl upgrade --version 1.0.0 --mariadb-series 11.8', then upgrade again"},
		{"no way out", "11.4", map[string]string{"11.4": "11.4.13"}, map[string]string{"11.8": "11.8.9", "12.3": "12.3.3"},
			"MariaDB 11.4 is not supported by any release: none publishes it together with a newer series"},
		{"newer than any", "12.3", map[string]string{"12.3": "12.3.3"}, oldSeries,
			"this stack runs MariaDB 12.3, newer than any series 1.1.0 publishes (11.4, 11.8), and a server never goes back a series: wait for a release that publishes 12.3"},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			s := newStack(t, c.running, rel{version: "1.0.0", mariadb: c.installed}, rel{version: "1.1.0", mariadb: c.after})
			_, plan := s.plan(s.runner())
			blocked(t, plan, c.want)
		})
	}
}

// Within a series a server never goes back to an older build; a newer
// build is a plain upgrade that brings MariaDB up alone first.
func TestPlanPatchGuard(t *testing.T) {
	s := newStack(t, "11.8", rel{version: "1.0.0", mariadb: map[string]string{"11.8": "11.8.10"}}, rel{version: "1.1.0"})
	_, plan := s.plan(s.runner())
	blocked(t, plan, "this stack runs MariaDB 11.8.10 and 1.1.0 pins 11.8.9: a server must not go back to an older build of its series; wait for a release that pins 11.8.10 or newer")

	s = newStack(t, "11.8", rel{version: "1.0.0"}, rel{version: "1.1.0", mariadb: map[string]string{"11.8": "11.8.10"}})
	r := s.runner()
	state, plan := s.plan(r)
	if len(plan.Blockers) != 0 || !plan.MariaDBImageChanges || plan.MariaDBUpgrade || plan.OneWay {
		t.Fatalf("a newer build: %+v", plan)
	}
	if err := r.Run(context.Background(), state, plan); err != nil {
		t.Fatalf("upgrade: %v", err)
	}
	s.back("1.1.0")
	if s.ran("compose up -d mariadb") < 0 {
		t.Error("MariaDB was not brought up alone on its new build")
	}
	if env := s.env(); env["MARIADB_VERSION"] != "11.8" {
		t.Errorf("MARIADB_VERSION = %q", env["MARIADB_VERSION"])
	}
}

// A series nothing tells blocks; a release that pins no MariaDB image
// has nothing to move to.
func TestPlanUnknownSeries(t *testing.T) {
	s := newStack(t, "11.8", rel{version: "1.0.0"}, rel{version: "1.1.0"})
	s.f.with(func(f *fakeDocker) {
		img := &fakeImage{id: digestOf("id mariadb:lts"), repo: "mariadb", digest: digestOf("mariadb:lts"), tags: []string{"lts"}}
		f.held = append(f.held, img)
		c := f.containers["kvs-mariadb"]
		c.ref, c.image = "mariadb:lts", img
	})
	inst, err := instance.Detect(s.root)
	if err != nil {
		t.Fatal(err)
	}
	if err := inst.UnsetEnv("MARIADB_VERSION"); err != nil {
		t.Fatal(err)
	}
	_, plan := s.plan(s.runner())
	blocked(t, plan, "the MariaDB series of this stack is unknown (the mariadb container runs mariadb:lts, whose tag and image name no series, and MARIADB_VERSION in .env names none either)")

	s = newStack(t, "11.8", rel{version: "1.0.0"}, rel{version: "1.1.0", mariadb: map[string]string{}})
	_, plan = s.plan(s.runner(series("12.3")))
	blocked(t, plan, "1.1.0 pins no MariaDB image of a known series, so --mariadb-series 12.3 has nothing to move to")
}

// The plan refuses a stack that is failing before the upgrade, a service
// without a container included; a container still starting is fine.
func TestPlanChecksTheHealthFirst(t *testing.T) {
	s := newStack(t, "", rel{version: "1.0.0"}, rel{version: "1.1.0"})
	s.restartWith("nginx", behavior{ready: time.Minute})
	_, plan := s.plan(s.runner())
	if len(plan.Blockers) != 0 || len(plan.Unhealthy) != 0 {
		t.Errorf("a container starting blocked: %v", plan.Blockers)
	}
	if !slices.Equal(plan.ActiveServices, []string{"mariadb", "nginx", "php-fpm"}) {
		t.Errorf("active services: %v", plan.ActiveServices)
	}

	s.restartWith("nginx", behavior{unhealthy: true})
	_, plan = s.plan(s.runner())
	blocked(t, plan, "the stack is not healthy before the upgrade: kvs-nginx is unhealthy; repair it first, or pass --allow-unhealthy")

	s.restartWith("nginx", behavior{})
	s.f.with(func(f *fakeDocker) { delete(f.containers, "kvs-php-fpm") })
	_, plan = s.plan(s.runner())
	blocked(t, plan, "service php-fpm has no container")
}

// Only the images of the active services are pulled; the others are
// listed, marked inactive.
func TestPlanPullsOnlyWhatTheActiveServicesRun(t *testing.T) {
	s := newStack(t, "", rel{version: "1.0.0"}, rel{version: "1.1.0"})
	_, plan := s.plan(s.runner())
	var pulled, inactive []string
	for _, item := range plan.ImagesToPull {
		pulled = append(pulled, item.Service)
	}
	for _, item := range plan.Services {
		if !item.Active {
			inactive = append(inactive, item.Service)
		}
	}
	slices.Sort(pulled)
	slices.Sort(inactive)
	if !slices.Equal(pulled, []string{"nginx", "php-fpm"}) || !slices.Equal(inactive, []string{"kvs-init", "manticore"}) || len(plan.Services) != 5 {
		t.Errorf("pulled %v, inactive %v, %d services", pulled, inactive, len(plan.Services))
	}
	if plan.Bytes != 2000 {
		t.Errorf("bytes to pull: %d", plan.Bytes)
	}
}

// The image of a service the release adds is pulled with the others,
// before anything changes: compose would pull it while the stack restarts
// otherwise, where a pull that fails rolls the upgrade back. A service the
// installed release has, whose profile is off here, is still left alone.
func TestPlanPullsTheImagesOfTheServicesTheReleaseAdds(t *testing.T) {
	s := newStack(t, "", rel{version: "1.0.0"}, rel{version: "1.1.0", extra: []string{"worker"}})
	_, plan := s.plan(s.runner())
	if pulled := pulledServices(plan); !slices.Equal(pulled, []string{"nginx", "php-fpm", "worker"}) {
		t.Errorf("pulled %v, want nginx, php-fpm and worker", pulled)
	}
	if err := s.upgrade(s.runner()); err != nil {
		t.Fatalf("upgrade: %v", err)
	}
	if s.running("worker") != s.pin("1.1.0", "worker") {
		t.Errorf("worker runs %q, want the image of 1.1.0", s.running("worker"))
	}

	s = newStack(t, "", rel{version: "1.0.0"}, rel{version: "1.1.0", extra: []string{"worker"}})
	s.f.with(func(f *fakeDocker) { delete(f.registry, s.images["1.1.0"]["worker"].Digest) })
	err := s.upgrade(s.runner())
	if err == nil || errors.Is(err, ErrRolledBack) || !strings.Contains(err.Error(), "nothing was changed, the stack is still on 1.0.0") {
		t.Fatalf("an image of an added service that cannot be pulled: %v", err)
	}
	s.back("1.0.0")
	if s.count("compose up") != 0 {
		t.Error("compose started")
	}
}

// pulledServices are the services whose images a plan pulls, sorted.
func pulledServices(plan *Plan) []string {
	var pulled []string
	for _, item := range plan.ImagesToPull {
		pulled = append(pulled, item.Service)
	}
	slices.Sort(pulled)
	return pulled
}

// recompose publishes the bundle of v again, its compose file holding to
// where it held from.
func (s *stack) recompose(v, from, to string) {
	s.t.Helper()
	compose := s.files(v, s.images[v])["docker/docker-compose.yml"]
	changed := strings.Replace(compose, from, to, 1)
	if changed == compose {
		s.t.Fatalf("the compose file of %s holds no %q", v, from)
	}
	s.rebundle(v, map[string]string{"docker/docker-compose.yml": changed})
}

// A service the release adds under a profile this stack does not turn on
// is one compose does not run, so its image is not pulled: the upgrade
// goes through even when the registry no longer serves it. Once the
// profile is on, the image is pulled before anything changes, as the
// others are.
func TestPlanLeavesTheImageOfAServiceWhoseProfileIsOff(t *testing.T) {
	s := newStack(t, "", rel{version: "1.0.0"}, rel{version: "1.1.0", extra: []string{"worker"}})
	s.recompose("1.1.0", "worker kvs-worker\n", "worker kvs-worker optional\n")
	_, plan := s.plan(s.runner())
	if pulled := pulledServices(plan); !slices.Equal(pulled, []string{"nginx", "php-fpm"}) {
		t.Errorf("profile off: pulled %v, want nginx and php-fpm", pulled)
	}
	if i := slices.IndexFunc(plan.Services, func(item PlanImage) bool { return item.Service == "worker" }); i < 0 || plan.Services[i].Active {
		t.Error("profile off: worker is missing from the services, or counted as one compose runs here")
	}
	s.f.with(func(f *fakeDocker) { delete(f.registry, s.images["1.1.0"]["worker"].Digest) })
	if err := s.upgrade(s.runner()); err != nil {
		t.Fatalf("profile off, the image of worker gone from the registry: %v", err)
	}
	if got := s.state().Current; got != "1.1.0" || s.running("worker") != "" {
		t.Errorf("profile off: the state records %s, worker runs %q", got, s.running("worker"))
	}

	s = newStack(t, "", rel{version: "1.0.0"}, rel{version: "1.1.0", extra: []string{"worker"}})
	s.recompose("1.1.0", "worker kvs-worker\n", "worker kvs-worker optional\n")
	s.setEnv("COMPOSE_PROFILES", "optional")
	_, plan = s.plan(s.runner())
	if pulled := pulledServices(plan); !slices.Equal(pulled, []string{"nginx", "php-fpm", "worker"}) {
		t.Errorf("profile on: pulled %v, want nginx, php-fpm and worker", pulled)
	}
	if err := s.upgrade(s.runner()); err != nil {
		t.Fatalf("profile on: %v", err)
	}
	if s.running("worker") != s.pin("1.1.0", "worker") {
		t.Errorf("profile on: worker runs %q, want the image of 1.1.0", s.running("worker"))
	}
}

// The first upgrade of an adopted checkout, a version no release names,
// pulls the image of a service the target adds before anything changes,
// as every upgrade does: the services come from the compose file of the
// target, not from what the manifest lists for the installed version.
func TestPlanPullsWhatTheTargetAddsToAnAdoptedCheckout(t *testing.T) {
	s := newStack(t, "", rel{version: "1.0.0"}, rel{version: "1.1.0", extra: []string{"worker"}})
	label := s.adoptUnreleased()
	_, plan := s.plan(s.runner())
	if pulled := pulledServices(plan); !slices.Equal(pulled, []string{"nginx", "php-fpm", "worker"}) {
		t.Errorf("pulled %v, want nginx, php-fpm and worker", pulled)
	}
	s.f.with(func(f *fakeDocker) { delete(f.registry, s.images["1.1.0"]["worker"].Digest) })
	err := s.upgrade(s.runner())
	if err == nil || errors.Is(err, ErrRolledBack) || !strings.HasSuffix(err.Error(), "nothing was changed, the stack is still on "+label) {
		t.Fatalf("the image of worker gone from the registry: %v", err)
	}
	if s.count("compose up") != 0 || s.journal() != nil {
		t.Error("compose started, or a journal was left")
	}
}

// A service of this stack whose profile is off, which the target runs
// without a profile, gets its image pulled before anything changes too.
func TestPlanPullsTheImageOfAServiceTheTargetTurnsOn(t *testing.T) {
	s := newStack(t, "", rel{version: "1.0.0"}, rel{version: "1.1.0"})
	s.recompose("1.1.0", "manticore kvs-manticore manticore needs:mariadb\n", "manticore kvs-manticore needs:mariadb\n")
	_, plan := s.plan(s.runner())
	if pulled := pulledServices(plan); !slices.Equal(pulled, []string{"manticore", "nginx", "php-fpm"}) {
		t.Errorf("pulled %v, want manticore, nginx and php-fpm", pulled)
	}
	s.f.with(func(f *fakeDocker) { delete(f.registry, s.images["1.1.0"]["manticore"].Digest) })
	if err := s.upgrade(s.runner()); err == nil || errors.Is(err, ErrRolledBack) || !strings.HasSuffix(err.Error(), "nothing was changed, the stack is still on 1.0.0") {
		t.Fatalf("the image of manticore gone from the registry: %v", err)
	}
}

// Compose reads the compose file of the target from the bundle, given on
// its stdin, with the profiles of the stack and a placeholder for each
// variable the file requires: never a value of the .env of the stack, nor
// one a shell exported. Nothing is written for it, so a TMPDIR kvsctl
// cannot write in changes nothing.
func TestPlanReadsTheTargetWithoutTheValuesOfTheStack(t *testing.T) {
	s := newStack(t, "", rel{version: "1.0.0"}, rel{version: "1.1.0", extra: []string{"worker"}})
	s.recompose("1.1.0", "worker kvs-worker\n", "worker kvs-worker:${WORKER_TAG:?set-it-in-env}\n")
	s.setEnv("WORKER_TAG", "operator-value")
	s.setEnv("COMPOSE_PROFILES", "dragonfly")
	t.Setenv("WORKER_TAG", "exported-value")
	t.Setenv("COMPOSE_FILE", "exported.yml")
	t.Setenv("COMPOSE_PROFILES", "exported")
	t.Setenv("TMPDIR", filepath.Join(t.TempDir(), "missing"))
	var read []cliRequest
	s.f.with(func(f *fakeDocker) {
		f.hook = func(_ *fakeDocker, req cliRequest) (cliResponse, bool) {
			if slices.Contains(req.Args, "--services") && req.Dir != filepath.Join(s.root, "docker") {
				read = append(read, req)
			}
			return cliResponse{}, false
		}
	})
	_, plan := s.plan(s.runner())
	s.f.with(func(f *fakeDocker) { f.hook = nil })
	if len(read) != 1 {
		t.Fatalf("the target was read %d times outside the project, want once", len(read))
	}
	env := map[string]string{}
	for _, entry := range read[0].Env {
		key, value, _ := strings.Cut(entry, "=")
		env[key] = value
	}
	if args := strings.Join(read[0].Args, " "); args != "compose --project-name kvsctl-plan --file /dev/stdin --env-file /dev/null config --services" || read[0].Dir != "/" {
		t.Errorf("the target was read with docker %s in %s", args, read[0].Dir)
	}
	if !strings.Contains(string(read[0].Stdin), "worker kvs-worker:${WORKER_TAG:?set-it-in-env}\n") {
		t.Errorf("compose read %q, want the compose file of 1.1.0", read[0].Stdin)
	}
	if _, set := env["COMPOSE_FILE"]; set || env["WORKER_TAG"] != "1" || env["COMPOSE_PROFILES"] != "dragonfly" {
		t.Errorf("compose read the target with COMPOSE_FILE %q, WORKER_TAG %q and COMPOSE_PROFILES %q; want no COMPOSE_FILE, the placeholder 1 and the profiles of the stack", env["COMPOSE_FILE"], env["WORKER_TAG"], env["COMPOSE_PROFILES"])
	}
	if pulled := pulledServices(plan); len(plan.Blockers) != 0 || !slices.Equal(pulled, []string{"nginx", "php-fpm", "worker"}) {
		t.Errorf("blockers %q, pulled %v; want none, and nginx, php-fpm and worker", plan.Blockers, pulled)
	}
}

// When compose cannot read the services of the target, the plan counts the
// ones compose runs now, and blocks nothing for it.
func TestPlanCountsWhatRunsNowWhenTheTargetCannotBeRead(t *testing.T) {
	s := newStack(t, "", rel{version: "1.0.0"}, rel{version: "1.1.0", extra: []string{"worker"}})
	s.f.with(func(f *fakeDocker) {
		f.hook = func(_ *fakeDocker, req cliRequest) (cliResponse, bool) {
			if !slices.Contains(req.Args, "--services") || req.Dir == filepath.Join(s.root, "docker") {
				return cliResponse{}, false
			}
			return cliResponse{Stderr: "yaml: line 3: mapping values are not allowed in this context\n", Code: 15}, true
		}
	})
	_, plan := s.plan(s.runner())
	if pulled := pulledServices(plan); len(plan.Blockers) != 0 || !slices.Equal(pulled, []string{"nginx", "php-fpm"}) {
		t.Errorf("blockers %q, pulled %v; want none, and nginx and php-fpm", plan.Blockers, pulled)
	}
}

// An adopted checkout newer than the release would go back in time;
// the same commit, or a commit of the release day, does not.
func TestPlanAdoptedCheckout(t *testing.T) {
	s := newStack(t, "", rel{version: "1.0.0"}, rel{version: "1.1.0", date: "2026-10-01", commit: commit("1.1.0")})
	r := s.runner()
	adopted := func(id string, at time.Time) func(*instance.State) {
		return func(state *instance.State) { state.AdoptedCommit, state.AdoptedCommitDate = id, at }
	}
	later := time.Date(2026, 10, 3, 10, 0, 0, 0, time.UTC)
	blocked(t, s.planWith(r, adopted(commit("checkout"), later)),
		"this stack is the git checkout of commit "+commit("checkout")[:12]+", made on 2026-10-03 10:00:00 UTC, and 1.1.0 was released on 2026-10-01: installing it would take the files back to an older state; wait for a newer release")
	for name, change := range map[string]func(*instance.State){
		"same commit": adopted(commit("1.1.0"), later),
		"release day": adopted(commit("checkout"), time.Date(2026, 10, 1, 20, 0, 0, 0, time.UTC)),
		"already upgraded": func(state *instance.State) {
			adopted(commit("checkout"), later)(state)
			state.History = append(state.History, instance.Entry{Version: "1.0.0", Action: instance.ActionUpgrade, Date: later})
			state.Current = "1.0.0"
			state.History[0].Version = "0.9.0"
		},
	} {
		if plan := s.planWith(r, change); len(plan.Blockers) != 0 {
			t.Errorf("%s: %v", name, plan.Blockers)
		}
	}
}

// A release dated by its commit compares to the second: a checkout
// committed later that day would go back in time, one committed before
// would not, and the blocker shows both times alike, in UTC.
func TestPlanAdoptedCheckoutAgainstTheReleaseCommit(t *testing.T) {
	s := newStack(t, "", rel{version: "1.0.0"}, rel{version: "1.1.0", date: "2026-10-01T12:00:00+02:00", commit: commit("1.1.0")})
	r := s.runner()
	adopted := func(at time.Time) func(*instance.State) {
		return func(state *instance.State) { state.AdoptedCommit, state.AdoptedCommitDate = commit("checkout"), at }
	}
	blocked(t, s.planWith(r, adopted(time.Date(2026, 10, 1, 10, 0, 1, 0, time.UTC))),
		"this stack is the git checkout of commit "+commit("checkout")[:12]+", made on 2026-10-01 10:00:01 UTC, and 1.1.0 was released on 2026-10-01 10:00:00 UTC: installing it would take the files back to an older state; wait for a newer release")
	for _, at := range []time.Time{time.Date(2026, 10, 1, 10, 0, 0, 0, time.UTC), time.Date(2026, 10, 1, 9, 59, 59, 0, time.UTC)} {
		if plan := s.planWith(r, adopted(at)); len(plan.Blockers) != 0 {
			t.Errorf("a checkout committed at %s: %v", at, plan.Blockers)
		}
	}
}

// The stops on the way to a target, which the plan blocks on and the
// update reminder names the first of: each release up to the target whose
// min_from is newer than the version reached so far, in order. 1.3.0 names
// a version the stop before it already reached.
func TestStops(t *testing.T) {
	minFrom := map[string]string{"0.9.0": "0.8.0", "1.2.0": "1.1.0", "1.3.0": "1.1.0", "1.4.0": "1.3.0", "1.5.0": "1.4.0", "1.6.0": ""}
	for _, c := range []struct {
		current, target string
		want            []string
	}{
		{"0.5.0", "1.4.0", []string{"0.8.0", "1.1.0", "1.3.0"}},
		{"1.0.0", "1.4.0", []string{"1.1.0", "1.3.0"}},
		{"1.2.0", "1.4.0", []string{"1.3.0"}},
		{"1.3.0", "1.6.0", []string{"1.4.0"}},
		{"1.4.0", "1.6.0", nil},
		{"0.5.0", "1.1.0", []string{"0.8.0"}},
	} {
		if got := Stops(c.current, c.target, minFrom); !slices.Equal(got, c.want) {
			t.Errorf("from %s to %s: stops %q, want %q", c.current, c.target, got, c.want)
		}
	}
}

// The release images are built for x86_64 only.
func TestPlanRefusesAnotherArchitecture(t *testing.T) {
	s := newStack(t, "", rel{version: "1.0.0"}, rel{version: "1.1.0"})
	s.f.with(func(f *fakeDocker) { f.arch = "aarch64" })
	_, plan := s.plan(s.runner())
	blocked(t, plan, "the Docker engine runs on aarch64 and the release images are built for x86_64 (linux/amd64) only")
}

// A stack whose state lists no release file cannot be rolled back, so the
// upgrade waits for an adopt.
func TestPlanNeedsTheReleaseFiles(t *testing.T) {
	s := newStack(t, "", rel{version: "1.0.0"}, rel{version: "1.1.0"})
	plan := s.planWith(s.runner(), func(state *instance.State) { state.Files, state.Checksums = nil, nil })
	blocked(t, plan, "run 'kvsctl adopt --force --version 1.0.0' first")
}

// The plan reads the bundle of the target, held to the size and the
// sha256 the signed manifest gives, and names what the operator keeps
// where the release lays a file or needs a directory: the lay would refuse
// it otherwise, once the backup is taken and the images pulled, and the
// run would roll back for it. A bundle it cannot read blocks as well.
func TestPlanNamesWhatKeepsTheReleaseFilesOut(t *testing.T) {
	s := newStack(t, "", rel{version: "1.0.0"}, rel{version: "1.1.0"})
	custom := filepath.Join(s.root, "docker", "custom")
	if err := os.WriteFile(custom, []byte("operator\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	s.rebundle("1.1.0", map[string]string{"docker/custom/extra.conf": "release\n"})
	if err := s.upgrade(s.runner()); !errors.Is(err, ErrBlocked) || !strings.Contains(err.Error(), "1.1.0 cannot lay its files: "+custom+" is a file, where the release needs a directory for docker/custom/extra.conf: move it away") {
		t.Fatalf("an operator file where the release needs a directory: %v", err)
	}
	if list, _ := os.ReadDir(filepath.Join(s.root, "backups")); len(list) != 0 || s.journal() != nil || s.count("compose up") != 0 {
		t.Errorf("a blocked upgrade took a backup, left a journal or started compose: %q", s.f.commands())
	}
	if slices.ContainsFunc(s.rep.events, func(e Event) bool { return e.Step == StepBackup || e.Step == StepPull || e.Step == StepApply }) {
		t.Error("a blocked upgrade went on to the backup, the pulls or the lay")
	}
	s.back("1.0.0")
	if err := os.Remove(custom); err != nil {
		t.Fatal(err)
	}

	notes := filepath.Join(s.root, "docker", "only-1.1.0.txt", "notes")
	if err := os.MkdirAll(filepath.Dir(notes), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(notes, []byte("operator\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	_, plan := s.plan(s.runner())
	blocked(t, plan, "1.1.0 cannot lay its files: "+filepath.Dir(notes)+" is a directory, where the release lays a file, and it holds "+notes+", which the release does not ship: move it away")
	if err := os.RemoveAll(filepath.Dir(notes)); err != nil {
		t.Fatal(err)
	}
	if _, plan := s.plan(s.runner()); len(plan.Blockers) != 0 {
		t.Errorf("nothing in the way: %q", plan.Blockers)
	}

	bundle := strings.TrimPrefix(s.release("1.1.0").Bundle.URL, "file://")
	data, err := os.ReadFile(bundle)
	if err != nil {
		t.Fatal(err)
	}
	data[len(data)/2] ^= 0xff
	if err := os.WriteFile(bundle, data, 0o644); err != nil {
		t.Fatal(err)
	}
	_, plan = s.plan(s.runner())
	blocked(t, plan, "the bundle of 1.1.0 could not be read (")
	if !strings.HasSuffix(plan.Blockers[0], "): run the command again once it can be downloaded") {
		t.Errorf("blocker %q", plan.Blockers[0])
	}
}

// rebundle publishes the bundle of version v again, with extra files beside
// the ones it ships, and signs its new sha256 and size into the manifest.
func (s *stack) rebundle(v string, extra map[string]string) {
	s.t.Helper()
	files := s.files(v, s.images[v])
	maps.Copy(files, extra)
	var buf bytes.Buffer
	gz := gzip.NewWriter(&buf)
	tw := tar.NewWriter(gz)
	for _, name := range slices.Sorted(maps.Keys(files)) {
		if err := tw.WriteHeader(&tar.Header{Name: name, Mode: 0o644, Size: int64(len(files[name])), Typeflag: tar.TypeReg}); err != nil {
			s.t.Fatal(err)
		}
		if _, err := tw.Write([]byte(files[name])); err != nil {
			s.t.Fatal(err)
		}
	}
	if err := tw.Close(); err != nil {
		s.t.Fatal(err)
	}
	if err := gz.Close(); err != nil {
		s.t.Fatal(err)
	}
	bundle := filepath.Join(s.dir, "kvs-stack-"+v+".tar.gz")
	if err := os.WriteFile(bundle, buf.Bytes(), 0o644); err != nil {
		s.t.Fatal(err)
	}
	sum := sha256.Sum256(buf.Bytes())
	s.release(v).Bundle = manifest.Asset{URL: "file://" + bundle, SHA256: hex.EncodeToString(sum[:]), Size: int64(buf.Len())}
	s.writeManifest()
}

// What an upgrade writes is added up per filesystem, and a one-way
// upgrade also counts a second copy of the database in its volume.
func TestPlanDiskAddsUpPerFilesystem(t *testing.T) {
	s := newStack(t, "11.8", rel{version: "1.0.0"}, rel{version: "1.1.0"})
	_, plan := s.plan(s.runner())
	if len(plan.Disk) != 1 || len(plan.Disk[0].Paths) != 3 {
		t.Fatalf("disk: %+v", plan.Disk)
	}
	if plan.DumpEstimate != 1048576/2 || !strings.Contains(plan.DumpSource, "half the") {
		t.Errorf("dump estimate %d (%s)", plan.DumpEstimate, plan.DumpSource)
	}
	want := plan.Bytes*2 + gib + plan.Target.Bundle.Size*3 + 200*mib + plan.DumpEstimate
	if plan.Disk[0].Needed != want || plan.DiskNeeded != want {
		t.Errorf("needed %d (%d), want %d", plan.Disk[0].Needed, plan.DiskNeeded, want)
	}

	_, oneWay := s.plan(s.runner(series("12.3")))
	if len(oneWay.Disk) != 1 || len(oneWay.Disk[0].Paths) != 4 || oneWay.DatabaseSize != 1048576 {
		t.Fatalf("one way disk: %+v, database %d", oneWay.Disk, oneWay.DatabaseSize)
	}
	if got, want := oneWay.Disk[0].Needed, oneWay.Bytes*2+gib+oneWay.Target.Bundle.Size*3+200*mib+oneWay.DumpEstimate+1048576*6/5; got != want {
		t.Errorf("one way needed %d, want %d", got, want)
	}
}

// release is the entry of version in the list the stack publishes, for a
// test to change before writeManifest or republish signs the list again.
func (s *stack) release(version string) *manifest.Release {
	s.t.Helper()
	for i := range s.releases {
		if s.releases[i].Version == version {
			return &s.releases[i]
		}
	}
	s.t.Fatalf("the stack publishes no release %s", version)
	return nil
}

// republish signs the list of releases again as change leaves the manifest.
func (s *stack) republish(change func(m *manifest.Manifest)) {
	s.t.Helper()
	m := manifest.Manifest{Schema: manifest.Schema, Channel: manifest.ChannelStable, Updated: time.Now().UTC().Format(time.RFC3339), Releases: s.releases}
	change(&m)
	raw, err := json.Marshal(m)
	if err != nil {
		s.t.Fatal(err)
	}
	s.sign(raw, s.priv)
}

// sign writes raw as the manifest of the stack, with its signature by priv.
func (s *stack) sign(raw []byte, priv ed25519.PrivateKey) {
	s.t.Helper()
	pub := priv.Public().(ed25519.PublicKey)
	sig, err := json.Marshal([]manifest.Signature{{KeyID: manifest.KeyID(pub), Alg: manifest.AlgEd25519, Sig: base64.StdEncoding.EncodeToString(ed25519.Sign(priv, raw))}})
	if err != nil {
		s.t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(s.dir, "manifest.json"), raw, 0o644); err != nil {
		s.t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(s.dir, "manifest.json.sig"), sig, 0o644); err != nil {
		s.t.Fatal(err)
	}
}

// measuring makes planDisk measure with fn for the rest of the test.
func measuring(t *testing.T, fn func(path string) (diskspace.Space, error)) {
	t.Helper()
	old := measure
	measure = fn
	t.Cleanup(func() { measure = old })
}

// mounts makes layerDir read text as the mounts of the machine for the
// rest of the test.
func mounts(t *testing.T, text string) {
	t.Helper()
	path := filepath.Join(t.TempDir(), "mountinfo")
	if err := os.WriteFile(path, []byte(text), 0o644); err != nil {
		t.Fatal(err)
	}
	old := mountInfo
	mountInfo = path
	t.Cleanup(func() { mountInfo = old })
}

// allowUnhealthy accepts the services unhealthy before the run.
func allowUnhealthy(o *Options) { o.AllowUnhealthy = true }

// A stack kvsctl never recorded is sent to adopt, which finds the version
// itself: a version typed from memory would be the wrong one.
func TestPlanWithoutAStateSendsToAdopt(t *testing.T) {
	s := newStack(t, "", rel{version: "1.0.0"}, rel{version: "1.1.0"})
	r := s.runner()
	for _, state := range []*instance.State{nil, {}} {
		_, err := r.Plan(context.Background(), state)
		if err == nil || !strings.Contains(err.Error(), "this stack has no recorded version: run 'kvsctl adopt' once, which finds the installed version itself") || strings.Contains(err.Error(), "--version") {
			t.Errorf("state %+v: %v", state, err)
		}
	}
}

// A manifest signed by a key this kvsctl does not trust is refused before
// anything is read from it.
func TestPlanRefusesAForeignSignature(t *testing.T) {
	s := newStack(t, "", rel{version: "1.0.0"}, rel{version: "1.1.0"})
	pub, priv, err := ed25519.GenerateKey(nil)
	if err != nil {
		t.Fatal(err)
	}
	raw, err := os.ReadFile(filepath.Join(s.dir, "manifest.json"))
	if err != nil {
		t.Fatal(err)
	}
	s.sign(raw, priv)
	state := s.state()
	plan, err := s.runner().Plan(context.Background(), state)
	if want := "manifest signature does not match any release key this kvsctl knows (signed by " + manifest.KeyID(pub) + ")"; err == nil || err.Error() != want {
		t.Errorf("a manifest signed by another key: %v, plan %+v; want %q", err, plan, want)
	}
}

// Plan reads the manifest for as long as the context of the command lasts,
// so the Ctrl-C that ends check or upgrade ends a read the server never
// answers. manifest.Fetch would end at the signal alone, never with the
// context.
func TestPlanEndsWithItsContext(t *testing.T) {
	s := newStack(t, "", rel{version: "1.0.0"}, rel{version: "1.1.0"})
	asked := make(chan struct{}, 1)
	release := make(chan struct{})
	server := httptest.NewServer(http.HandlerFunc(func(_ http.ResponseWriter, req *http.Request) {
		select {
		case asked <- struct{}{}:
		default:
		}
		select {
		case <-req.Context().Done():
		case <-release:
		}
	}))
	t.Cleanup(func() {
		close(release)
		server.Close()
	})
	r := s.runner()
	r.Opts.ManifestURL = server.URL + "/manifest.json"
	state := s.state()
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	done := make(chan error, 1)
	go func() {
		_, err := r.Plan(ctx, state)
		done <- err
	}()
	select {
	case <-asked:
	case err := <-done:
		t.Fatalf("Plan ended (%v) before it read the manifest", err)
	case <-time.After(10 * time.Second):
		t.Fatal("Plan did not read the manifest")
	}
	cancel()
	select {
	case err := <-done:
		if !errors.Is(err, context.Canceled) {
			t.Errorf("Plan ended with %v, want the end of its context", err)
		}
	case <-time.After(5 * time.Second):
		t.Fatal("Plan still reads the manifest 5 seconds after its context ended")
	}
}

// --allow-unhealthy never accepts MariaDB: php-fpm and manticore wait for
// it to be healthy, so compose would leave them stopped, and the rollback
// would wait for it in vain. Another service is still accepted.
func TestPlanNeverAcceptsAnUnhealthyMariaDB(t *testing.T) {
	s := newStack(t, "", rel{version: "1.0.0"}, rel{version: "1.1.0"})
	s.restartWith("mariadb", behavior{unhealthy: true})
	for _, allow := range []bool{false, true} {
		_, plan := s.plan(s.runner(func(o *Options) { o.AllowUnhealthy = allow }))
		blocked(t, plan, "the stack is not healthy before the upgrade: kvs-mariadb is unhealthy; repair MariaDB first: --allow-unhealthy cannot leave it out, because php-fpm and manticore wait for MariaDB to be healthy and compose would not start them")
		if len(plan.Ignored) != 0 {
			t.Errorf("--allow-unhealthy %v: ignored %v", allow, plan.Ignored)
		}
	}
	s.restartWith("mariadb", behavior{})
	s.restartWith("nginx", behavior{unhealthy: true})
	_, plan := s.plan(s.runner(allowUnhealthy))
	if len(plan.Blockers) != 0 || !slices.Equal(plan.Ignored, []string{"nginx"}) {
		t.Errorf("an unhealthy nginx accepted: blockers %v, ignored %v", plan.Blockers, plan.Ignored)
	}
}

// A stack none of whose services runs, stopped or taken down, needs
// starting, which neither a repair of MariaDB nor --allow-unhealthy is;
// one service stopped is a service that fails.
func TestPlanSendsAStackThatIsDownToStart(t *testing.T) {
	s := newStack(t, "", rel{version: "1.0.0"}, rel{version: "1.1.0"})
	down := []string{"the stack is down: start it with 'docker compose up -d' in " + s.runner().Inst.DockerDir + ", then run 'kvsctl check' again"}
	stop := func(service string) {
		s.f.with(func(f *fakeDocker) {
			for _, c := range f.containers {
				c.stopped = service == "" || c.service == service
			}
		})
	}
	stop("")
	for _, allow := range []bool{false, true} {
		_, plan := s.plan(s.runner(func(o *Options) { o.AllowUnhealthy = allow }))
		if !slices.Equal(plan.Blockers, down) || len(plan.Ignored) != 0 {
			t.Errorf("every container stopped, --allow-unhealthy %v: blockers %q, ignored %v", allow, plan.Blockers, plan.Ignored)
		}
	}
	stop("nginx")
	_, plan := s.plan(s.runner())
	blocked(t, plan, "the stack is not healthy before the upgrade: kvs-nginx is exited (exit 0); repair it first, or pass --allow-unhealthy")
	s.f.with(func(f *fakeDocker) { f.containers = map[string]*fakeContainer{} })
	if _, plan := s.plan(s.runner()); !slices.Equal(plan.Blockers, down) {
		t.Errorf("no container left: blockers %q", plan.Blockers)
	}
}

// Which states make a stack down: no service with a container that runs,
// restarts or is paused, the services that only initialise the others
// left aside.
func TestStackDown(t *testing.T) {
	services := []string{"kvs-init", "mariadb", "nginx"}
	for _, c := range []struct {
		name    string
		running map[string]dockerx.ServiceImage
		want    bool
	}{
		{"no container", nil, true},
		{"stopped", map[string]dockerx.ServiceImage{"mariadb": {State: "exited"}, "nginx": {State: "created"}}, true},
		{"dead and gone", map[string]dockerx.ServiceImage{"mariadb": {State: "dead"}}, true},
		{"only the init service runs", map[string]dockerx.ServiceImage{"kvs-init": {State: "running"}, "mariadb": {State: "exited"}}, true},
		{"one runs", map[string]dockerx.ServiceImage{"mariadb": {State: "running"}, "nginx": {State: "exited"}}, false},
		{"one restarts", map[string]dockerx.ServiceImage{"mariadb": {State: "exited"}, "nginx": {State: "restarting"}}, false},
		{"one is paused", map[string]dockerx.ServiceImage{"mariadb": {State: "paused"}, "nginx": {State: "exited"}}, false},
	} {
		if got := stackDown(services, c.running); got != c.want {
			t.Errorf("%s: %v, want %v", c.name, got, c.want)
		}
	}
}

// The room the rollback of a one-way plan needs is one need among the
// others: when the size of the database, its data directory or the
// filesystem of its volume cannot be read, the plan says what it could not
// measure and why, and blocks nothing; upgrade says it before it asks.
func TestPlanSaysWhenTheRoomOfTheRollbackIsUnknown(t *testing.T) {
	s := newStack(t, "11.8", rel{version: "1.0.0"}, rel{version: "1.1.0"})
	mounts(t, "")
	const unknown = "a second copy of the database, which a rollback of this one-way upgrade replays while the files of the new server stay in the volume: "
	unmeasured := func(plan *Plan, why string) {
		t.Helper()
		if len(plan.Blockers) != 0 || len(plan.DiskUnknown) != 1 || !strings.HasPrefix(plan.DiskUnknown[0], unknown+why) {
			t.Errorf("blockers %q, unknown %q; want none, and %q", plan.Blockers, plan.DiskUnknown, unknown+why)
		}
	}

	var volume string
	s.f.with(func(f *fakeDocker) { volume, f.volume = f.volume, "" })
	_, plan := s.plan(s.runner(series("12.3")))
	unmeasured(plan, "the data directory of MariaDB could not be found (nothing of the host is mounted at /var/lib/mysql in kvs-mariadb)")
	if _, plan := s.plan(s.runner()); len(plan.Blockers) != 0 || len(plan.DiskUnknown) != 0 {
		t.Errorf("a plan that is not one way needs no second copy: blockers %q, unknown %q", plan.Blockers, plan.DiskUnknown)
	}
	s.f.with(func(f *fakeDocker) { f.volume = volume })

	s.f.with(func(f *fakeDocker) {
		f.hook = func(_ *fakeDocker, req cliRequest) (cliResponse, bool) {
			if req.Args[0] == "exec" && strings.Contains(req.Args[len(req.Args)-1], "information_schema") {
				return cliResponse{Stderr: "ERROR 1045 (28000): Access denied\n", Code: 1}, true
			}
			return cliResponse{}, false
		}
	})
	r := s.runner(series("12.3"), func(o *Options) { o.Yes = false })
	state, plan := s.plan(r)
	unmeasured(plan, "the size of the database could not be read (")
	s.rep.answer = false
	if err := r.Run(context.Background(), state, plan); err == nil || err.Error() != "upgrade cancelled, nothing was changed" {
		t.Fatalf("a declined upgrade: %v", err)
	}
	if len(s.rep.asked) != 1 {
		t.Fatalf("questions %q", s.rep.questions)
	}
	for _, line := range []string{"not measured: " + unknown + "the size of the database could not be read (", "not measured: the room of the backup, whose size is unknown: no earlier backup"} {
		at := slices.IndexFunc(s.rep.events, func(e Event) bool { return e.Kind == KindLog && strings.HasPrefix(e.Message, line) })
		if at < 0 || at > s.rep.asked[0] {
			t.Errorf("%q was not said before the question (event %d, question after %d)", line, at, s.rep.asked[0])
		}
	}
	s.f.with(func(f *fakeDocker) { f.hook = nil })

	statfs := errors.New("statfs: permission denied")
	measuring(t, func(path string) (diskspace.Space, error) {
		if path == volume {
			return diskspace.Space{}, statfs
		}
		return diskspace.Measure(path)
	})
	_, plan = s.plan(s.runner(series("12.3")))
	unmeasured(plan, "the filesystem of "+volume+" could not be read (statfs: permission denied)")

	inst := s.runner().Inst
	measuring(t, func(path string) (diskspace.Space, error) {
		if path == inst.StateDir() {
			return diskspace.Space{}, statfs
		}
		return diskspace.Measure(path)
	})
	_, plan = s.plan(s.runner(series("12.3")))
	if len(plan.Blockers) != 0 || len(plan.DiskUnknown) != 1 || !strings.HasPrefix(plan.DiskUnknown[0], "the bundle (") || !strings.HasSuffix(plan.DiskUnknown[0], ": the filesystem of "+inst.StateDir()+" could not be read (statfs: permission denied)") {
		t.Errorf("an unmeasured bundle: blockers %v, unknown %q", plan.Blockers, plan.DiskUnknown)
	}
}

// The volume of MariaDB is under the root of the engine (0710), out of
// reach of the member of the docker group check may run as: the room of
// the second copy a one-way rollback writes is measured at the mount of
// its filesystem, the way the layers are, and holds the upgrade when it
// falls short.
func TestPlanDiskReachesTheVolumeThroughItsMount(t *testing.T) {
	s := newStack(t, "11.8", rel{version: "1.0.0"}, rel{version: "1.1.0"})
	var volume string
	s.f.with(func(f *fakeDocker) { volume = f.volume })
	disk := filepath.Dir(volume)
	mounts(t, "22 1 8:1 / / rw,relatime - ext4 /dev/sda1 rw\n"+
		"95 22 8:17 / "+disk+" rw,relatime - ext4 /dev/sdb1 rw\n")
	var free int64 = 999
	measuring(t, func(path string) (diskspace.Space, error) {
		switch path {
		case volume:
			return diskspace.Space{}, errors.New("statfs " + path + ": permission denied")
		case disk:
			return diskspace.Space{Avail: free, Device: 2}, nil
		}
		return diskspace.Space{Avail: 1 << 40, Device: 1}, nil
	})
	const size = 1048576 // what the tables of the fake take
	_, plan := s.plan(s.runner(series("12.3")))
	if len(plan.DiskUnknown) != 0 || len(plan.Disk) != 2 || !slices.Equal(plan.Disk[1].Paths, []string{volume}) || plan.Disk[1].Free != free || plan.Disk[1].Needed != size*6/5 {
		t.Fatalf("disk %+v, unknown %q", plan.Disk, plan.DiskUnknown)
	}
	blocked(t, plan, "999 B free on the filesystem of "+volume+" is not enough: a second copy of the database ("+humanBytes(size)+" and a fifth more), which a rollback replays while the files of the new server stay in the volume need "+humanBytes(size*6/5))
	free = 1 << 30
	if _, plan := s.plan(s.runner(series("12.3"))); len(plan.Blockers) != 0 || len(plan.Disk) != 2 {
		t.Errorf("room enough: blockers %q, disk %+v", plan.Blockers, plan.Disk)
	}
}

// A container that the engine restarted moments ago reads as running, and
// healthy even, between two crashes: the check before a change counts it
// as failing, which --allow-unhealthy accepts, instead of letting the
// verification blame the release for it.
func TestPlanFlagsAContainerThatKeepsRestarting(t *testing.T) {
	s := newStack(t, "", rel{version: "1.0.0"}, rel{version: "1.1.0"})
	s.restartWith("nginx", behavior{crash: true})
	time.Sleep(3 * crashPeriod)
	_, plan := s.plan(s.runner())
	// The fake restarts it every 25 ms; a loaded machine may still take a
	// second between the read and the check, and TestPreflightProblem pins
	// the wording of the time.
	if len(plan.Blockers) != 1 || !regexp.MustCompile(`^the stack is not healthy before the upgrade: kvs-nginx was restarted (once|\d+ times) by the engine, the last time (less than a second|\d+s) ago; repair it first, or pass --allow-unhealthy$`).MatchString(plan.Blockers[0]) {
		t.Errorf("a crash loop: blockers %q", plan.Blockers)
	}
	_, plan = s.plan(s.runner(allowUnhealthy))
	if len(plan.Blockers) != 0 || !slices.Equal(plan.Ignored, []string{"nginx"}) {
		t.Errorf("a crash loop accepted: blockers %v, ignored %v", plan.Blockers, plan.Ignored)
	}
}

// What the check before a change holds against one container.
func TestPreflightProblem(t *testing.T) {
	now := time.Date(2026, 10, 7, 12, 0, 0, 0, time.UTC)
	for _, c := range []struct {
		name string
		s    dockerx.ContainerState
		want string
	}{
		{"healthy", dockerx.ContainerState{Name: "kvs-nginx", State: "running", Health: "healthy", Started: now.Add(-time.Hour)}, ""},
		{"no health check", dockerx.ContainerState{Name: "kvs-nginx", State: "running", Started: now.Add(-time.Hour)}, ""},
		{"starting", dockerx.ContainerState{Name: "kvs-nginx", State: "running", Health: "starting", Started: now.Add(-time.Second)}, ""},
		{"restarted long ago", dockerx.ContainerState{Name: "kvs-nginx", State: "running", Health: "healthy", Restarts: 4, Started: now.Add(-restartedLately)}, ""},
		{"restarted lately", dockerx.ContainerState{Name: "kvs-nginx", State: "running", Health: "healthy", Restarts: 2, Started: now.Add(-5 * time.Second)}, "kvs-nginx was restarted 2 times by the engine, the last time 5s ago"},
		{"restarted once", dockerx.ContainerState{Name: "kvs-nginx", State: "running", Health: "starting", Restarts: 1, Started: now.Add(-300 * time.Millisecond)}, "kvs-nginx was restarted once by the engine, the last time less than a second ago"},
		{"unhealthy", dockerx.ContainerState{Name: "kvs-nginx", State: "running", Health: "unhealthy", Started: now.Add(-time.Hour)}, describeContainer(dockerx.ContainerState{Name: "kvs-nginx", State: "running", Health: "unhealthy"})},
		{"restarting", dockerx.ContainerState{Name: "kvs-nginx", State: "restarting", Restarts: 9, Started: now.Add(-time.Second)}, describeContainer(dockerx.ContainerState{Name: "kvs-nginx", State: "restarting", Restarts: 9})},
	} {
		if got := preflightProblem(c.s, now); got != c.want {
			t.Errorf("%s: %q, want %q", c.name, got, c.want)
		}
	}
}

// An engine that does not answer stops the plan at one blocker: what the
// plan would show without it would be guesses.
func TestPlanStopsWhenTheEngineDoesNotAnswer(t *testing.T) {
	s := newStack(t, "", rel{version: "1.0.0"}, rel{version: "1.1.0"})
	s.f.with(func(f *fakeDocker) {
		f.refusal = "Cannot connect to the Docker daemon at unix:///var/run/docker.sock. Is the docker daemon running?"
	})
	_, plan := s.plan(s.runner())
	if !plan.Incomplete || len(plan.Services) != 0 || len(plan.Disk) != 0 || plan.ActiveServices != nil || plan.Bytes != 0 {
		t.Errorf("the plan says more than the engine told: %+v", plan)
	}
	blocked(t, plan, "kvsctl cannot talk to the Docker engine (")
	if !strings.Contains(plan.Blockers[0], "Cannot connect to the Docker daemon") || !strings.HasSuffix(plan.Blockers[0], "start Docker if it is stopped, then run the command again") {
		t.Errorf("the blocker: %q", plan.Blockers[0])
	}
}

// refuseListing puts a server before the fake engine that refuses the
// list of the containers alone, and returns a client of it: an engine that
// answers who it is and nothing about the stack.
func (s *stack) refuseListing(msg string) *dockerx.Client {
	t := s.t
	t.Helper()
	dir, err := os.MkdirTemp("", "kvsctl")
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { os.RemoveAll(dir) })
	sock := filepath.Join(dir, "docker.sock")
	listener, err := net.Listen("unix", sock)
	if err != nil {
		t.Fatal(err)
	}
	listing := regexp.MustCompile(`^(/v[0-9.]+)?/containers/json$`)
	srv := &http.Server{Handler: http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if listing.MatchString(r.URL.Path) {
			w.Header().Set("Content-Type", "application/json")
			w.WriteHeader(http.StatusInternalServerError)
			_ = json.NewEncoder(w).Encode(map[string]string{"message": msg})
			return
		}
		s.f.ServeHTTP(w, r)
	})}
	go func() { _ = srv.Serve(listener) }()
	t.Cleanup(func() { srv.Close() })
	t.Setenv("DOCKER_HOST", "unix://"+sock)
	client, err := dockerx.New()
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { client.Close() })
	return client
}

// An engine that cannot list the containers of the stack stops the plan
// the same way, at one blocker.
func TestPlanStopsWhenTheContainersCannotBeListed(t *testing.T) {
	s := newStack(t, "", rel{version: "1.0.0"}, rel{version: "1.1.0"})
	r := s.runner()
	r.Docker = s.refuseListing("the store of the containers is locked")
	_, plan := s.plan(r)
	if !plan.Incomplete || len(plan.Disk) != 0 || plan.ActiveServices != nil {
		t.Errorf("the plan says more than the engine told: %+v", plan)
	}
	blocked(t, plan, "the Docker engine could not list the containers of project kvs (")
	if !strings.Contains(plan.Blockers[0], "the store of the containers is locked") {
		t.Errorf("the blocker does not say why: %q", plan.Blockers[0])
	}
}

// A release can ask for a newer kvsctl than the one running, with the
// format unchanged: the plan stops there and sends to update-cli. Every
// release the upgrade installs counts, the strictest is named wherever it
// sits, and a build that is not a release is never held back.
func TestPlanStopsAtAReleaseThatNeedsANewerKvsctl(t *testing.T) {
	s := newStack(t, "", rel{version: "1.0.0"}, rel{version: "1.1.0"}, rel{version: "1.2.0"}, rel{version: "1.3.0"})
	s.release("1.1.0").Requires.KvsctlMin = "2.0.0"
	s.release("1.2.0").Requires.KvsctlMin = "3.0.0"
	s.release("1.3.0").Requires.KvsctlMin = "2.5.0"
	s.writeManifest()
	update := "run 'kvsctl update-cli --manifest file://" + filepath.Join(s.dir, "manifest.json") + "' first"
	running := func(v string) func(*Options) { return func(o *Options) { o.KvsctlVersion = v } }
	target := func(v string) func(*Options) { return func(o *Options) { o.Version = v } }
	_, plan := s.plan(s.runner(running("2.7.0")))
	if !plan.Incomplete || len(plan.Services) != 0 {
		t.Errorf("the plan went on: %+v", plan)
	}
	blocked(t, plan, "1.2.0 needs kvsctl 3.0.0 or newer, and this is kvsctl 2.7.0: "+update)
	for _, v := range []string{"3.0.0", "3.1.0", "dev", ""} {
		if _, plan := s.plan(s.runner(running(v))); plan.Incomplete || len(plan.Blockers) != 0 {
			t.Errorf("kvsctl %q: blockers %v", v, plan.Blockers)
		}
	}
	_, plan = s.plan(s.runner(running("1.5.0"), target("1.1.0")))
	blocked(t, plan, "1.1.0 needs kvsctl 2.0.0 or newer, and this is kvsctl 1.5.0: "+update)
	if _, plan := s.plan(s.runner(running("2.7.0"), target("1.1.0"))); len(plan.Blockers) != 0 {
		t.Errorf("a target below the release that needs a newer kvsctl: %v", plan.Blockers)
	}
	s.release("1.2.0").Requires.KvsctlMin = ""
	s.writeManifest()
	_, plan = s.plan(s.runner(running("2.4.0")))
	blocked(t, plan, "1.3.0 needs kvsctl 2.5.0 or newer, and this is kvsctl 2.4.0: "+update)
	// The installed release applied again counts as well.
	s.release("1.0.0").Requires.KvsctlMin = "9.0.0"
	s.writeManifest()
	_, plan = s.plan(s.runner(running("3.0.0"), target("1.0.0")))
	blocked(t, plan, "1.0.0 needs kvsctl 9.0.0 or newer, and this is kvsctl 3.0.0: "+update)
	// Without the option the plan takes the version package main sets from
	// its build; the option, when set, takes its place.
	t.Cleanup(func() { KvsctlVersion = "" })
	KvsctlVersion = "2.4.0"
	_, plan = s.plan(s.runner())
	blocked(t, plan, "1.3.0 needs kvsctl 2.5.0 or newer, and this is kvsctl 2.4.0: "+update)
	if _, plan := s.plan(s.runner(running("2.5.0"))); len(plan.Blockers) != 0 {
		t.Errorf("the version of the options: blockers %v", plan.Blockers)
	}
}

// update-cli reads the default manifest and installs the kvsctl of its
// latest stable release unless it is told otherwise, and a release
// candidate may ask for its own kvsctl: the command the plan sends to names
// the manifest the plan read, and the candidate when no stable release
// ships a kvsctl new enough, or the operator would go round in circles.
func TestPlanSendsToTheKvsctlThatServesACandidate(t *testing.T) {
	s := newStack(t, "", rel{version: "1.0.0"}, rel{version: "1.1.0"}, rel{version: "1.2.0-rc1"})
	update := "kvsctl update-cli --manifest file://" + filepath.Join(s.dir, "manifest.json")
	candidate := func(running string) func(*Options) {
		return func(o *Options) { o.KvsctlVersion, o.Version = running, "1.2.0-rc1" }
	}
	s.release("1.2.0-rc1").Requires.KvsctlMin = "1.2.0-rc1"
	s.writeManifest()
	_, plan := s.plan(s.runner(candidate("1.1.0")))
	blocked(t, plan, "1.2.0-rc1 needs kvsctl 1.2.0-rc1 or newer, and this is kvsctl 1.1.0: run '"+update+" --version 1.2.0-rc1' first")
	if _, plan := s.plan(s.runner(candidate("1.2.0-rc1"))); len(plan.Blockers) != 0 {
		t.Errorf("the kvsctl of the candidate: %v", plan.Blockers)
	}
	s.release("1.2.0-rc1").Requires.KvsctlMin = "1.1.0"
	s.writeManifest()
	_, plan = s.plan(s.runner(candidate("1.0.0")))
	blocked(t, plan, "1.2.0-rc1 needs kvsctl 1.1.0 or newer, and this is kvsctl 1.0.0: run '"+update+"' first")
}

// The update-cli a plan sends to: plain on the default manifest when its
// latest stable release ships a kvsctl new enough, with the manifest the
// plan read otherwise, and with the release that asks when only its own
// kvsctl is new enough.
func TestUpdateCLICommand(t *testing.T) {
	m := &manifest.Manifest{Releases: []manifest.Release{{Version: "1.2.0-rc1"}, {Version: "1.1.0"}, {Version: "1.0.0"}}}
	candidates := &manifest.Manifest{Releases: []manifest.Release{{Version: "1.0.0-rc2"}, {Version: "1.0.0-rc1"}}}
	const lab = "file:///srv/lab/manifest.json"
	for _, c := range []struct {
		url        string
		m          *manifest.Manifest
		needed, by string
		want       string
	}{
		{manifest.DefaultURL, m, "1.1.0", "1.2.0-rc1", "kvsctl update-cli"},
		{manifest.DefaultURL, m, "1.2.0-rc1", "1.2.0-rc1", "kvsctl update-cli --version 1.2.0-rc1"},
		{lab, m, "1.0.0", "1.1.0", "kvsctl update-cli --manifest " + lab},
		{lab, m, "1.2.0-rc1", "1.2.0-rc1", "kvsctl update-cli --manifest " + lab + " --version 1.2.0-rc1"},
		{lab, candidates, "1.0.0-rc1", "1.0.0-rc2", "kvsctl update-cli --manifest " + lab + " --version 1.0.0-rc2"},
		// A release that asks for a kvsctl newer than its own, which
		// kvsctl-release does not sign: its name would not help.
		{manifest.DefaultURL, m, "9.0.0", "1.1.0", "kvsctl update-cli"},
	} {
		if got := updateCLICommand(c.url, c.m, c.needed, c.by); got != c.want {
			t.Errorf("%s needs %s from %s: %q, want %q", c.by, c.needed, c.url, got, c.want)
		}
	}
}

// The default target is the latest stable release: a release candidate is
// installed when it is named, and the manifest of a candidate is read from
// a URL the operator gives. A channel this build does not know is refused.
func TestPlanTakesACandidateOnlyByName(t *testing.T) {
	s := newStack(t, "", rel{version: "1.0.0"}, rel{version: "1.1.0"}, rel{version: "1.2.0-rc1"})
	if _, plan := s.plan(s.runner()); plan.Target.Version != "1.1.0" || len(plan.Blockers) != 0 {
		t.Errorf("default target %s, blockers %v", plan.Target.Version, plan.Blockers)
	}
	if _, plan := s.plan(s.runner(func(o *Options) { o.Version = "1.2.0-rc1" })); plan.Target.Version != "1.2.0-rc1" || len(plan.Blockers) != 0 {
		t.Errorf("named candidate: target %s, blockers %v", plan.Target.Version, plan.Blockers)
	}
	s.republish(func(m *manifest.Manifest) { m.Channel = manifest.ChannelCandidate })
	if _, plan := s.plan(s.runner()); plan.Target.Version != "1.1.0" {
		t.Errorf("the manifest of a candidate: default target %s", plan.Target.Version)
	}
	s.republish(func(m *manifest.Manifest) { m.Channel = "nightly" })
	if _, err := s.runner().Plan(context.Background(), s.state()); err == nil || !strings.Contains(err.Error(), `is of channel "nightly", which this kvsctl does not read`) {
		t.Errorf("an unknown channel: %v", err)
	}

	s = newStack(t, "", rel{version: "0.9.0"}, rel{version: "1.0.0-rc1"}, rel{version: "1.0.0-rc2"})
	s.republish(func(m *manifest.Manifest) { m.Releases = m.Releases[1:] })
	if _, err := s.runner().Plan(context.Background(), s.state()); err == nil || err.Error() != "the manifest lists release candidates only (1.0.0-rc2 is the newest): name the one to install with --version" {
		t.Errorf("candidates only: %v", err)
	}
	if _, plan := s.plan(s.runner(func(o *Options) { o.Version = "1.0.0-rc2" })); plan.Target.Version != "1.0.0-rc2" {
		t.Errorf("candidates only, one named: target %s", plan.Target.Version)
	}
	s = newStack(t, "", rel{version: "1.0.0-rc1"}, rel{version: "1.0.0-rc2"})
	if _, plan := s.plan(s.runner()); plan.Target.Version != "1.0.0-rc1" || !plan.UpToDate {
		t.Errorf("candidates only, one of them installed: target %s, up to date %v", plan.Target.Version, plan.UpToDate)
	}
}

// A stack that runs a release candidate newer than every stable release
// stays on it: the upgrade without a version, which a cron job runs, is
// the one of the installed release and has nothing to do, a newer
// candidate included. A list that does not carry it has nothing to
// upgrade to, and the stable release that follows the candidate is the
// next upgrade.
func TestPlanKeepsAStackOnItsCandidate(t *testing.T) {
	s := newStack(t, "", rel{version: "1.2.0-rc1"}, rel{version: "1.1.0"}, rel{version: "1.2.0-rc2"})
	for _, channel := range []string{manifest.ChannelStable, manifest.ChannelCandidate} {
		s.republish(func(m *manifest.Manifest) { m.Channel = channel })
		if _, plan := s.plan(s.runner()); plan.Target.Version != "1.2.0-rc1" || !plan.UpToDate || plan.Downgrade || len(plan.Blockers) != 0 {
			t.Errorf("channel %s: target %s, up to date %v, downgrade %v, blockers %v", channel, plan.Target.Version, plan.UpToDate, plan.Downgrade, plan.Blockers)
		}
	}
	if _, plan := s.plan(s.runner(func(o *Options) { o.Version = "1.2.0-rc2" })); plan.Target.Version != "1.2.0-rc2" || plan.UpToDate {
		t.Errorf("the newer candidate named: target %s, up to date %v", plan.Target.Version, plan.UpToDate)
	}
	s.republish(func(m *manifest.Manifest) {
		m.Releases = slices.DeleteFunc(slices.Clone(m.Releases), func(r manifest.Release) bool { return semver.IsPrerelease(r.Version) })
	})
	if _, plan := s.plan(s.runner()); !plan.Downgrade || plan.DowngradeMessage() != "the installed 1.2.0-rc1 is newer than 1.1.0, the latest stable release: there is nothing to upgrade to" {
		t.Errorf("a list without the candidate: downgrade %v, %q", plan.Downgrade, plan.DowngradeMessage())
	}
	s.addRelease(rel{version: "1.2.0"})
	s.writeManifest()
	if _, plan := s.plan(s.runner()); plan.Target.Version != "1.2.0" || plan.UpToDate || plan.Downgrade {
		t.Errorf("the stable release of the candidate: target %s, up to date %v, downgrade %v", plan.Target.Version, plan.UpToDate, plan.Downgrade)
	}
}

// The guards of the plan that need a release of their own: the Docker
// Compose the release needs, the PHP an encoded site is bound to, the room
// on disk, the size of the backup and the release files edited here.
func TestPlanGuards(t *testing.T) {
	t.Run("compose", func(t *testing.T) {
		s := newStack(t, "", rel{version: "1.0.0"}, rel{version: "1.1.0"})
		s.release("1.1.0").Requires.ComposeMin = "2.30.0"
		s.writeManifest()
		_, plan := s.plan(s.runner())
		blocked(t, plan, "1.1.0 needs Docker Compose 2.30.0 or newer, this machine has 2.29.7: upgrade the Docker Compose plugin first")
		s.release("1.1.0").Requires.ComposeMin = "2.24.0"
		s.writeManifest()
		if _, plan := s.plan(s.runner()); len(plan.Blockers) != 0 || plan.ComposeVersion != "2.29.7" {
			t.Errorf("a Compose new enough: blockers %v, version %q", plan.Blockers, plan.ComposeVersion)
		}
	})
	t.Run("ioncube", func(t *testing.T) {
		s := newStack(t, "", rel{version: "1.0.0"}, rel{version: "1.1.0"})
		target := s.release("1.1.0")
		target.Images = append(target.Images, target.Variants[manifest.VariantPHP]["8.1"]...)
		delete(target.Variants, manifest.VariantPHP)
		target.Requires.PHP = "8.3"
		s.writeManifest()
		s.setEnv("IONCUBE", "YES")
		_, plan := s.plan(s.runner())
		blocked(t, plan, "1.1.0 runs PHP 8.3 and this site is IonCube encoded for PHP 8.1: a KVS archive encoded for PHP 8.3 is needed first")
		s.setEnv("IONCUBE", "NO")
		if _, plan := s.plan(s.runner()); len(plan.Blockers) != 0 {
			t.Errorf("a site that is not encoded: %v", plan.Blockers)
		}
	})
	t.Run("disk", func(t *testing.T) {
		s := newStack(t, "", rel{version: "1.0.0"}, rel{version: "1.1.0"})
		measuring(t, func(string) (diskspace.Space, error) { return diskspace.Space{Avail: 1 << 20, Device: 7}, nil })
		_, plan := s.plan(s.runner())
		if len(plan.Disk) != 1 {
			t.Fatalf("disk %+v", plan.Disk)
		}
		blocked(t, plan, "1 MB free on the filesystem of "+plan.DockerRoot+" and ")
		if !strings.Contains(plan.Blockers[0], " is not enough: the images to pull (2 kB, counted twice for their unpacked layers) and 1 GiB for the engine, the bundle (") {
			t.Errorf("the blocker does not say what is needed: %q", plan.Blockers[0])
		}
	})
	t.Run("backup estimate", func(t *testing.T) {
		s := newStack(t, "", rel{version: "1.0.0"}, rel{version: "1.1.0"})
		s.backupNow("1.0.0")
		list, err := backup.List(s.runner().Inst.BackupDir())
		if err != nil || len(list) != 1 || list[0].CompressedBytes <= 0 {
			t.Fatalf("backups %+v, %v", list, err)
		}
		_, plan := s.plan(s.runner())
		if plan.DumpEstimate != list[0].CompressedBytes*3/2 || plan.DumpSource != "half again the dump of "+list[0].Name {
			t.Errorf("estimate %d (%s), want half again %d", plan.DumpEstimate, plan.DumpSource, list[0].CompressedBytes)
		}
	})
	t.Run("local changes", func(t *testing.T) {
		s := newStack(t, "", rel{version: "1.0.0"}, rel{version: "1.1.0"})
		if err := os.WriteFile(filepath.Join(s.root, "README.md"), []byte("edited here\n"), 0o644); err != nil {
			t.Fatal(err)
		}
		_, plan := s.plan(s.runner())
		blocked(t, plan, "README.md")
		_, plan = s.plan(s.runner(func(o *Options) { o.AllowLocalChanges = true }))
		if len(plan.Blockers) != 0 || !slices.Equal(plan.LocalChanges, []string{"README.md"}) {
			t.Errorf("--allow-local-changes: blockers %v, changes %v", plan.Blockers, plan.LocalChanges)
		}
	})
}

// The KVS minimum of a release is read against the version.php of the
// site, in each way it is written; a version that cannot be read blocks
// nothing.
func TestPlanKVSMinimum(t *testing.T) {
	s := newStack(t, "", rel{version: "1.0.0"}, rel{version: "1.1.0"})
	s.release("1.1.0").Requires.KVSMin = "7.0.0"
	s.writeManifest()
	web := t.TempDir()
	versionPHP := filepath.Join(web, "admin", "include", "version.php")
	if err := os.MkdirAll(filepath.Dir(versionPHP), 0o755); err != nil {
		t.Fatal(err)
	}
	planWith := func(content string) *Plan {
		t.Helper()
		if content == "" {
			_ = os.Remove(versionPHP)
		} else if err := os.WriteFile(versionPHP, []byte(content), 0o644); err != nil {
			t.Fatal(err)
		}
		r := s.runner()
		r.Inst.WebRoot = web
		_, plan := s.plan(r)
		return plan
	}
	for _, layout := range []string{
		"<?php\n$config['project_version'] = \"6.4.0\";\n",
		"<?php\n$config[\"project_version\"]='6.4.0';\n",
		"<?php\n$config['project_version']   =   '6.4.0' ;\n",
	} {
		blocked(t, planWith(layout), "1.1.0 supports KVS 7.0.0 and newer, this site runs KVS 6.4.0: update KVS from its admin panel first")
	}
	for _, content := range []string{"<?php\n$config['project_version'] = \"7.0.0\";\n", "<?php\n// no version\n", ""} {
		if plan := planWith(content); len(plan.Blockers) != 0 {
			t.Errorf("version.php %q: %v", content, plan.Blockers)
		}
	}
}

// With the containerd image store, the pulled layers land under the root
// of containerd, which the mounts of the running containers name: the plan
// measures that filesystem for them, and the root of the engine for its
// own margin.
func TestPlanDiskCountsTheLayersWhereContainerdKeepsThem(t *testing.T) {
	s := newStack(t, "", rel{version: "1.0.0"}, rel{version: "1.1.0"})
	var root string
	s.f.with(func(f *fakeDocker) { root = f.root })
	store := filepath.Join(t.TempDir(), "io.containerd.snapshotter.v1.overlayfs")
	mounts(t, "36 25 0:32 / /proc rw,nosuid - proc proc rw\n"+
		"1290 31 0:345 / "+root+"/rootfs/overlayfs/0123abcd rw,relatime shared:620 - overlay overlay rw,lowerdir="+store+"/snapshots/12/fs:"+store+"/snapshots/11/fs,upperdir="+store+"/snapshots/13/fs,workdir="+store+"/snapshots/13/work\n")
	var free int64 = 999
	measuring(t, func(path string) (diskspace.Space, error) {
		if strings.HasPrefix(path, store) {
			return diskspace.Space{Avail: free, Device: 2}, nil
		}
		return diskspace.Space{Avail: 1 << 40, Device: 1}, nil
	})
	_, plan := s.plan(s.runner())
	if len(plan.Disk) != 2 || !slices.Equal(plan.Disk[0].Paths, []string{store}) || plan.Disk[0].Needed != plan.Bytes*2 || plan.Disk[1].Paths[0] != root {
		t.Fatalf("disk %+v", plan.Disk)
	}
	if plan.DiskFree != free || plan.DiskNeeded != plan.Bytes*2 {
		t.Errorf("the filesystem of the images: %d free, %d needed", plan.DiskFree, plan.DiskNeeded)
	}
	blocked(t, plan, "999 B free on the filesystem of "+store+" is not enough: the images to pull (2 kB, counted twice for their unpacked layers), which containerd keeps need 4 kB")
	free = 1 << 30
	if _, plan := s.plan(s.runner()); len(plan.Blockers) != 0 || len(plan.Disk) != 2 {
		t.Errorf("room enough: blockers %v, disk %+v", plan.Blockers, plan.Disk)
	}
}

// The root of containerd is root's alone (0700), and check reads as any
// user the engine answers: the layers are measured through the mount point
// of their filesystem, or, when that cannot be read either, counted under
// the root of the engine with the reason in DiskUnknown.
func TestPlanDiskReachesTheLayersThroughTheirMount(t *testing.T) {
	s := newStack(t, "", rel{version: "1.0.0"}, rel{version: "1.1.0"})
	var root string
	s.f.with(func(f *fakeDocker) { root = f.root })
	disk := t.TempDir()
	store := filepath.Join(disk, "containerd", "io.containerd.snapshotter.v1.overlayfs")
	mounts(t, "22 1 8:1 / / rw,relatime - ext4 /dev/sda1 rw\n"+
		"95 22 8:17 / "+disk+" rw,relatime - ext4 /dev/sdb1 rw\n"+
		"1290 95 0:345 / "+root+"/rootfs/overlayfs/0123abcd rw,relatime - overlay overlay rw,lowerdir="+store+"/snapshots/12/fs,upperdir="+store+"/snapshots/13/fs\n")
	denied := map[string]bool{store: true}
	var free int64 = 999
	measuring(t, func(path string) (diskspace.Space, error) {
		switch {
		case denied[path]:
			return diskspace.Space{}, errors.New("statfs " + path + ": permission denied")
		case path == disk:
			return diskspace.Space{Avail: free, Device: 2}, nil
		}
		return diskspace.Space{Avail: 1 << 40, Device: 1}, nil
	})
	_, plan := s.plan(s.runner())
	if len(plan.DiskUnknown) != 0 || len(plan.Disk) != 2 || !slices.Equal(plan.Disk[0].Paths, []string{store}) || plan.DiskFree != free || plan.DiskNeeded != plan.Bytes*2 {
		t.Fatalf("disk %+v, unknown %q", plan.Disk, plan.DiskUnknown)
	}
	blocked(t, plan, "999 B free on the filesystem of "+store+" is not enough: the images to pull (2 kB, counted twice for their unpacked layers), which containerd keeps need 4 kB")

	denied[disk] = true
	_, plan = s.plan(s.runner())
	want := "the filesystem of " + store + ", where containerd keeps the layers it pulls, could not be read (statfs " + store + ": permission denied): they are counted under " + root
	if !slices.Equal(plan.DiskUnknown, []string{want}) {
		t.Errorf("unknown %q, want %q", plan.DiskUnknown, want)
	}
	if len(plan.Disk) != 1 || plan.Disk[0].Paths[0] != root || plan.Disk[0].Parts[0] != "the images to pull (2 kB, counted twice for their unpacked layers) and 1 GiB for the engine" || len(plan.Blockers) != 0 {
		t.Errorf("disk %+v, blockers %q", plan.Disk, plan.Blockers)
	}
}

// mountOf is the deepest mount a path is under, whatever text the paths
// share, mounts stacked on one point included.
func TestMountOf(t *testing.T) {
	mounts(t, "22 1 8:1 / / rw - ext4 /dev/sda1 rw\n"+
		"23 22 8:2 / /var rw - ext4 /dev/sda2 rw\n"+
		"24 23 8:3 / /var/lib/container rw - ext4 /dev/sda3 rw\n"+
		"25 23 8:4 / /var/lib/containerd rw - ext4 /dev/sda4 rw\n"+
		"26 25 8:5 / /var/lib/containerd rw - xfs /dev/sdb1 rw\n"+
		`27 22 8:6 / /srv/disk\040two rw - ext4 /dev/sdc1 rw`+"\n"+
		"28 22 0:40 / /proc rw - proc proc rw\n")
	for path, want := range map[string]string{
		"/var/lib/containerd/io.containerd.snapshotter.v1.overlayfs": "/var/lib/containerd",
		"/var/lib/containerd":           "/var/lib/containerd",
		"/var/lib/containers/storage":   "/var",
		"/srv/disk two/containerd":      "/srv/disk two",
		"/srv/disk/containerd":          "/",
		"/opt/containerd/snapshots/fs1": "/",
	} {
		if got, err := mountOf(path); err != nil || got != want {
			t.Errorf("%s: %q, %v; want %q", path, got, err, want)
		}
	}
	mounts(t, "28 22 0:40 / /proc rw - proc proc rw\n")
	if _, err := mountOf("/var/lib/containerd"); err == nil {
		t.Error("a path no mount holds must say so")
	}
}

// layerDir reads where the engine keeps the layers of its images from the
// overlay mounts under its root: outside it with the containerd image
// store, inside it with overlay2, unknown without a container running.
func TestLayerDir(t *testing.T) {
	const store = "/var/lib/containerd/io.containerd.snapshotter.v1.overlayfs"
	for _, c := range []struct {
		name, root, mounts, want string
	}{
		{"containerd", "/var/lib/docker",
			"1290 31 0:345 / /var/lib/docker/rootfs/overlayfs/0123 rw,relatime - overlay overlay rw,lowerdir=" + store + "/snapshots/12/fs:" + store + "/snapshots/11/fs,upperdir=" + store + "/snapshots/13/fs\n",
			store},
		{"options of the new mount API", "/var/lib/docker",
			"1290 31 0:345 / /var/lib/docker/rootfs/overlayfs/0123 rw,relatime - overlay overlay rw,lowerdir+=" + store + "/snapshots/12/fs,lowerdir+=" + store + "/snapshots/11/fs,upperdir=" + store + "/snapshots/13/fs\n",
			store},
		{"a root with a space", "/srv/docker data",
			`1290 31 0:345 / /srv/docker\040data/rootfs/overlayfs/0123 rw,relatime - overlay overlay rw,lowerdir=/srv/containerd\040data/snapshots/12/fs,upperdir=/srv/containerd\040data/snapshots/13/fs` + "\n",
			"/srv/containerd data"},
		{"overlay2", "/var/lib/docker",
			"1290 31 0:345 / /var/lib/docker/overlay2/abc/merged rw,relatime - overlay overlay rw,lowerdir=/var/lib/docker/overlay2/l/ABC:/var/lib/docker/overlay2/l/DEF,upperdir=/var/lib/docker/overlay2/abc/diff\n",
			""},
		{"another root", "/var/lib/docker",
			"1290 31 0:345 / /var/lib/docker2/rootfs/overlayfs/0123 rw - overlay overlay rw,lowerdir=" + store + "/snapshots/12/fs\n",
			""},
		{"no container", "/var/lib/docker", "36 25 0:32 / /proc rw,nosuid - proc proc rw\n", ""},
	} {
		mounts(t, c.mounts)
		if got, err := layerDir(c.root); err != nil || got != c.want {
			t.Errorf("%s: %q, %v; want %q", c.name, got, err, c.want)
		}
	}
	mountInfo = filepath.Join(t.TempDir(), "missing")
	if _, err := layerDir("/var/lib/docker"); err == nil {
		t.Error("mounts that cannot be read must say so")
	}
}
