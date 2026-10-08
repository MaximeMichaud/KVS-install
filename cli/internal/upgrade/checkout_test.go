package upgrade

import (
	"context"
	"errors"
	"maps"
	"os"
	"path/filepath"
	"slices"
	"sort"
	"strings"
	"testing"
	"time"

	"github.com/MaximeMichaud/KVS-install/cli/internal/instance"
	"github.com/MaximeMichaud/KVS-install/cli/internal/release"
)

// checkoutReadme is what README.md holds in the checkout of the tests: an
// edit made on the machine, which only the files adopt kept hold.
const checkoutReadme = "KVS stack, git checkout, edited on this machine\n"

// asCheckout turns the installed stack into what kvs-install.sh leaves and
// adopt records for its git checkout: no release override and no
// docker/RELEASE (git tracks neither), no COMPOSE_FILE (setup.sh removes it
// on a stack of one site), no KVS_*_IMAGE keys, the images built on the
// machine and MariaDB by its series tag, a README edited on the machine,
// the files kept in the release directory of the version, and a state
// without variant images.
func (s *stack) asCheckout() {
	s.t.Helper()
	inst, err := instance.Detect(s.root)
	if err != nil {
		s.t.Fatal(err)
	}
	for _, name := range []string{"docker/" + ReleaseOverride, "docker/RELEASE"} {
		if err := os.Remove(filepath.Join(s.root, name)); err != nil {
			s.t.Fatal(err)
		}
	}
	if err := os.WriteFile(filepath.Join(s.root, "README.md"), []byte(checkoutReadme), 0o644); err != nil {
		s.t.Fatal(err)
	}
	for _, key := range []string{"COMPOSE_FILE", "KVS_PHP_FPM_IMAGE", "KVS_MARIADB_IMAGE"} {
		if err := inst.UnsetEnv(key); err != nil {
			s.t.Fatal(err)
		}
	}
	s.f.with(func(f *fakeDocker) {
		for _, img := range []*fakeImage{
			{id: digestOf("id kvs-nginx"), repo: "kvs-nginx", digest: digestOf("kvs-nginx"), tags: []string{"latest"}},
			{id: digestOf("id kvs-php"), repo: "kvs-php", digest: digestOf("kvs-php"), tags: []string{"latest"}},
			{id: digestOf("id mariadb:11.8"), repo: "mariadb", digest: digestOf("mariadb:11.8"), tags: []string{"11.8"}, series: "11.8", env: []string{"MARIADB_VERSION=1:11.8.9+maria~ubu2404"}},
		} {
			f.held = append(f.held, img)
		}
		if resp := f.up(inst.DockerDir, nil); resp.Code != 0 {
			s.t.Fatalf("the checkout does not start: %s", resp.Stderr)
		}
	})
	state := s.state()
	var files []string
	for _, f := range state.Files {
		if f != "docker/"+ReleaseOverride && f != "docker/RELEASE" {
			files = append(files, f)
		}
	}
	sort.Strings(files)
	if err := release.Snapshot(s.root, filepath.Join(inst.ReleasesDir(), state.Current), files); err != nil {
		s.t.Fatal(err)
	}
	sums, err := release.Checksums(s.root, files)
	if err != nil {
		s.t.Fatal(err)
	}
	state.Files, state.Checksums = files, sums
	state.Images, state.PreviousImages, state.ReleaseImages = nil, nil, nil
	state.AdoptedCommit, state.AdoptedCommitDate = commit("checkout"), time.Date(2026, 9, 20, 10, 0, 0, 0, time.UTC)
	if err := inst.SaveState(state); err != nil {
		s.t.Fatal(err)
	}
}

// onCheckout checks that the stack runs the checkout again: its files, its
// edited README, no release file, a .env without COMPOSE_FILE and without
// image keys, the images built on the machine, and no journal.
func (s *stack) onCheckout(version string) {
	s.t.Helper()
	env := s.env()
	for _, key := range []string{"COMPOSE_FILE", "KVS_PHP_FPM_IMAGE", "KVS_MARIADB_IMAGE"} {
		if value, ok := env[key]; ok {
			s.t.Errorf(".env keeps %s=%q on the checkout", key, value)
		}
	}
	for _, name := range []string{"docker/" + ReleaseOverride, "docker/RELEASE"} {
		if s.file(name) != "" {
			s.t.Errorf("%s is still there", name)
		}
	}
	if got := s.file("README.md"); got != checkoutReadme {
		s.t.Errorf("README.md holds %q, not the checkout's", got)
	}
	for service, want := range map[string]string{"nginx": "kvs-nginx", "php-fpm": "kvs-php", "mariadb": "mariadb:11.8"} {
		if got := s.running(service); got != want {
			s.t.Errorf("%s runs %s, want %s", service, got, want)
		}
	}
	if state := s.state(); state.Current != version {
		s.t.Errorf("the state records %s, want %s", state.Current, version)
	}
	if j := s.journal(); j != nil {
		s.t.Errorf("the journal is still there: %+v", j)
	}
}

// A stack installed from main when its last commit is the newest release
// is adopted at that release, and its first upgrade applies the same
// release again with the release images. Its rollback returns to the
// checkout: its own files, edits included, no COMPOSE_FILE, no image keys,
// the images built on the machine. The release files stay kept too.
func TestCheckoutAtTheNewestTagReappliedThenRolledBack(t *testing.T) {
	s := newStack(t, "11.8", rel{version: "1.0.0"})
	s.asCheckout()
	allow := func(o *Options) { o.AllowLocalChanges = true }
	r := s.runner(allow)
	state, plan := s.plan(r)
	if !plan.Reapply || plan.action() != "apply 1.0.0 again with the images of PHP 8.1" || len(plan.Blockers) != 0 {
		t.Fatalf("plan: reapply %v, %q, blockers %v", plan.Reapply, plan.action(), plan.Blockers)
	}
	checkout := slices.Clone(state.Files)
	if err := r.Run(context.Background(), state, plan); err != nil {
		t.Fatalf("re-apply: %v", err)
	}
	s.back("1.0.0")
	after := s.state()
	if after.Previous != "1.0.0" || !slices.Equal(after.PreviousFiles, checkout) || after.PreviousImages[composeFileKey] != "" || after.PreviousImages["KVS_PHP_FPM_IMAGE"] != "" {
		t.Errorf("after the re-apply: previous %s, files %v, images %v", after.Previous, after.PreviousFiles, after.PreviousImages)
	}
	if last := after.History[len(after.History)-1]; last.Note != "applied over the checkout adopt recorded" {
		t.Errorf("history ends with %+v", last)
	}
	if got := r.keptDir("1.0.0", checkout); got != r.checkoutDir("1.0.0") {
		t.Errorf("the checkout is kept in %s", got)
	}
	if data, err := os.ReadFile(filepath.Join(r.checkoutDir("1.0.0"), "README.md")); err != nil || string(data) != checkoutReadme {
		t.Errorf("the kept checkout README: %q, %v", data, err)
	}

	s.fresh()
	if err := s.rollback(s.runner(allow)); err != nil {
		t.Fatalf("rollback: %v", err)
	}
	s.onCheckout("1.0.0")
	back := s.state()
	if !slices.Equal(back.Files, checkout) || back.Previous != "1.0.0" || !slices.Contains(back.PreviousFiles, "docker/RELEASE") {
		t.Errorf("after the rollback: files %v, previous %s with %v", back.Files, back.Previous, back.PreviousFiles)
	}
	if _, err := os.Stat(filepath.Join(r.releaseDir("1.0.0"), "docker", "RELEASE")); err != nil {
		t.Errorf("the release files are no longer kept: %v", err)
	}
}

// The checkout adopted at an older release, upgraded, then rolled back by
// hand: COMPOSE_FILE goes back to unset, as the checkout ran, and an
// override created since is loaded the way compose loads it then.
func TestCheckoutUpgradedThenRolledBackByHand(t *testing.T) {
	s := newStack(t, "11.8", rel{version: "1.0.0"}, rel{version: "1.1.0"})
	s.asCheckout()
	allow := func(o *Options) { o.AllowLocalChanges = true }
	if err := s.upgrade(s.runner(allow)); err != nil {
		t.Fatalf("upgrade: %v", err)
	}
	if env := s.env(); env["COMPOSE_FILE"] != "docker-compose.yml:"+ReleaseOverride || env["KVS_PHP_FPM_IMAGE"] != s.pin("1.1.0", "php-fpm@8.1") {
		t.Fatalf(".env after the first upgrade: %v", env)
	}
	// The operator adds a service of their own in an override, under the
	// name the Compose documentation uses.
	if err := os.WriteFile(filepath.Join(s.root, "docker", "compose.override.yaml"), []byte("sidecar kvs-sidecar\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	s.f.with(func(f *fakeDocker) {
		f.held = append(f.held, &fakeImage{id: digestOf("id kvs-sidecar"), repo: "kvs-sidecar", digest: digestOf("kvs-sidecar"), tags: []string{"latest"}})
	})
	s.fresh()
	if err := s.rollback(s.runner(allow)); err != nil {
		t.Fatalf("rollback: %v", err)
	}
	s.onCheckout("1.0.0")
	if got := s.running("sidecar"); got != "kvs-sidecar" {
		t.Errorf("the override created since is not loaded: sidecar runs %q", got)
	}
}

// reapplyOnPHP83 applies the installed release again with the images of PHP
// 8.3, the way an operator asks for it: PHP_VERSION changed in .env.
func (s *stack) reapplyOnPHP83(set ...func(*Options)) {
	s.t.Helper()
	s.setEnv("PHP_VERSION", "8.3")
	r := s.runner(set...)
	state, plan := s.plan(r)
	if !plan.Reapply || plan.PHPSeries != "8.3" {
		s.t.Fatalf("plan: re-apply %v, PHP %s, blockers %v", plan.Reapply, plan.PHPSeries, plan.Blockers)
	}
	if err := r.Run(context.Background(), state, plan); err != nil {
		s.t.Fatalf("re-apply: %v", err)
	}
}

// A checkout upgraded, then the release applied again with the images of
// another PHP series: the way back stays the checkout as the upgrade
// recorded it, with no image key, since the checkout pinned none. The
// manual rollback lays it back with a .env that names no image, as the
// checkout ran.
func TestCheckoutUpgradedReappliedThenRolledBack(t *testing.T) {
	s := newStack(t, "11.8", rel{version: "1.0.0"}, rel{version: "1.1.0", php: []string{"8.1", "8.3"}})
	s.asCheckout()
	allow := func(o *Options) { o.AllowLocalChanges = true }
	if err := s.upgrade(s.runner(allow)); err != nil {
		t.Fatalf("upgrade: %v", err)
	}
	upgraded := s.state()
	s.reapplyOnPHP83(allow)
	if after := s.state(); after.Previous != "1.0.0" || !maps.Equal(after.PreviousImages, upgraded.PreviousImages) {
		t.Errorf("the way back after the re-apply: %s with %v, want %s with %v as the upgrade recorded it", after.Previous, after.PreviousImages, upgraded.Previous, upgraded.PreviousImages)
	}
	s.fresh()
	if err := s.rollback(s.runner(allow)); err != nil {
		t.Fatalf("rollback: %v", err)
	}
	s.onCheckout("1.0.0")
	if got := s.env()["PHP_VERSION"]; got != "8.1" {
		t.Errorf("PHP_VERSION=%s after the rollback to the checkout, which ran 8.1", got)
	}
}

// The same, once a prune took the images of the release no container runs
// and the registry no longer serves them: the checkout runs images built on
// the machine, so its rollback needs no image of a release, and the
// registry out of reach does not refuse it.
func TestCheckoutRollbackAfterAReapplyNeedsNoReleaseImage(t *testing.T) {
	s := newStack(t, "11.8", rel{version: "1.0.0"}, rel{version: "1.1.0", php: []string{"8.1", "8.3"}})
	s.asCheckout()
	allow := func(o *Options) { o.AllowLocalChanges = true }
	if err := s.upgrade(s.runner(allow)); err != nil {
		t.Fatalf("upgrade: %v", err)
	}
	s.reapplyOnPHP83(allow)
	s.prune("1.1.0", false)
	s.fresh()
	if err := s.rollback(s.runner(allow)); err != nil {
		t.Fatalf("the rollback to the checkout: %v", err)
	}
	s.onCheckout("1.0.0")
}

// The first upgrade of a checkout fails: the rollback puts .env back as the
// checkout had it, without COMPOSE_FILE and without the image keys, lays
// its files back without the release ones, and compose runs the images
// built on the machine again.
func TestCheckoutFirstUpgradeFailing(t *testing.T) {
	s := newStack(t, "11.8", rel{version: "1.0.0"}, rel{version: "1.1.0"})
	s.asCheckout()
	s.f.behave(registry+"php:1.1.0-php8.1", behavior{unhealthy: true})
	err := s.upgrade(s.runner(quick, func(o *Options) { o.AllowLocalChanges = true }))
	if !errors.Is(err, ErrRolledBack) {
		t.Fatalf("err = %v", err)
	}
	s.onCheckout("1.0.0")
}

// The first upgrade of a checkout cut at each phase is undone by recover,
// back to the checkout.
func TestCheckoutFirstUpgradeCutThenRecovered(t *testing.T) {
	for _, cut := range []struct {
		name string
		at   func(Event) bool
		// fails is an upgrade that fails, cut in its own rollback.
		fails bool
	}{
		{"once the files are laid", isStep(KindStepDone, StepApply), false},
		{"while compose starts", isStep(KindStepStart, StepRestart), false},
		{"during the verification", isStep(KindStepStart, StepVerify), false},
		{"during its own rollback", isLog("does not change the database"), true},
	} {
		t.Run(cut.name, func(t *testing.T) {
			s := newStack(t, "11.8", rel{version: "1.0.0"}, rel{version: "1.1.0"})
			s.asCheckout()
			allow := func(o *Options) { o.AllowLocalChanges = true }
			if cut.fails {
				s.f.behave(registry+"php:1.1.0-php8.1", behavior{unhealthy: true})
			}
			s.cutUpgrade(s.runner(quick, allow), cut.at)
			if s.journal() == nil {
				t.Fatal("the cut run left no journal")
			}
			s.fresh()
			if err := s.recover(s.runner(quick, allow)); err != nil {
				t.Fatalf("recover: %v", err)
			}
			s.onCheckout("1.0.0")
		})
	}
}

// A rollback that would leave COMPOSE_FILE and .env compose cannot read
// together is refused before its first change: a state written before the
// settings of each version were recorded may lack them.
func TestRollbackRefusesSettingsComposeCannotRead(t *testing.T) {
	s := newStack(t, "11.8", rel{version: "1.0.0"}, rel{version: "1.1.0"})
	if err := s.upgrade(s.runner()); err != nil {
		t.Fatalf("upgrade: %v", err)
	}
	inst, err := instance.Detect(s.root)
	if err != nil {
		t.Fatal(err)
	}
	state := s.state()
	delete(state.PreviousImages, "KVS_MARIADB_IMAGE")
	if err := inst.SaveState(state); err != nil {
		t.Fatal(err)
	}
	envBefore := s.file("docker/.env")
	s.fresh()
	err = s.rollback(s.runner())
	if err == nil || !strings.Contains(err.Error(), "no value for KVS_MARIADB_IMAGE, which "+ReleaseOverride+" requires") || !strings.HasSuffix(err.Error(), "nothing was changed, the stack is still on 1.1.0") {
		t.Fatalf("err = %v", err)
	}
	if errors.Is(err, ErrRollbackFailed) {
		t.Error("a refusal exits as a failed rollback")
	}
	if s.file("docker/.env") != envBefore || s.file("docker/RELEASE") != "1.1.0\n" || s.journal() != nil {
		t.Error("the refused rollback changed the installation")
	}
}
