package upgrade

import (
	"context"
	"errors"
	"fmt"
	"net/http"
	"os"
	"path/filepath"
	"slices"
	"strings"
	"testing"

	"github.com/MaximeMichaud/KVS-install/cli/internal/instance"
	"github.com/MaximeMichaud/KVS-install/cli/internal/manifest"
)

func TestSetComposeFilesKeepsTheListItFound(t *testing.T) {
	inst := testInstance(t, "DOMAIN=example.com\nCOMPOSE_FILE=docker-compose.yml:docker-compose.caddy.yml\n")
	r := &Runner{Inst: inst, Reporter: &recorder{}}
	if err := r.setComposeFiles([]string{"docker/docker-compose.yml", "docker/" + ReleaseOverride}); err != nil {
		t.Fatal(err)
	}
	if got := inst.Env["COMPOSE_FILE"]; got != "docker-compose.yml:docker-compose.caddy.yml:"+ReleaseOverride {
		t.Errorf("COMPOSE_FILE = %q", got)
	}
	if err := r.setComposeFiles([]string{"docker/docker-compose.yml"}); err != nil {
		t.Fatal(err)
	}
	if got := inst.Env["COMPOSE_FILE"]; got != "docker-compose.yml:docker-compose.caddy.yml" {
		t.Errorf("COMPOSE_FILE after a release without override = %q", got)
	}
}

// An install with one site has no COMPOSE_FILE at all, and compose then
// loads the operator's override on its own. Writing the key must not drop
// it: that override is where the bind mounts and the sidecars live.
func TestSetComposeFilesSeedsTheOverride(t *testing.T) {
	rep := &recorder{}
	inst := testInstance(t, "DOMAIN=example.com\n", OverrideFile)
	r := &Runner{Inst: inst, Reporter: rep}
	if err := r.setComposeFiles([]string{"docker/docker-compose.yml", "docker/" + ReleaseOverride}); err != nil {
		t.Fatal(err)
	}
	want := "docker-compose.yml:" + OverrideFile + ":" + ReleaseOverride
	if got := inst.Env["COMPOSE_FILE"]; got != want {
		t.Errorf("COMPOSE_FILE = %q, want %q", got, want)
	}
	if again, err := instance.ReadEnv(inst.EnvPath); err != nil || again["COMPOSE_FILE"] != want {
		t.Errorf(".env holds %q (%v)", again["COMPOSE_FILE"], err)
	}
	if logs := rep.logs(); len(logs) != 1 || !strings.Contains(logs[0], want) {
		t.Errorf("the resulting list was not logged: %v", logs)
	}
}

// An override created after kvsctl first wrote COMPOSE_FILE used to be
// ignored for good: compose only picks it up by itself while the key is
// unset. Every write now puts it in, before the release override.
func TestSetComposeFilesAddsAnOverrideCreatedLater(t *testing.T) {
	inst := testInstance(t, "DOMAIN=example.com\nCOMPOSE_FILE=docker-compose.yml:"+ReleaseOverride+"\n", OverrideFile)
	r := &Runner{Inst: inst, Reporter: &recorder{}}
	if err := r.setComposeFiles([]string{"docker/" + ReleaseOverride}); err != nil {
		t.Fatal(err)
	}
	if got, want := inst.Env["COMPOSE_FILE"], "docker-compose.yml:"+OverrideFile+":"+ReleaseOverride; got != want {
		t.Errorf("COMPOSE_FILE = %q, want %q", got, want)
	}

	// Named by another path, it is there already and stays where it is.
	listed := testInstance(t, "DOMAIN=example.com\nCOMPOSE_FILE=./"+OverrideFile+":docker-compose.yml\n", OverrideFile)
	r = &Runner{Inst: listed, Reporter: &recorder{}}
	if err := r.setComposeFiles([]string{"docker/" + ReleaseOverride}); err != nil {
		t.Fatal(err)
	}
	if got, want := listed.Env["COMPOSE_FILE"], "./"+OverrideFile+":docker-compose.yml:"+ReleaseOverride; got != want {
		t.Errorf("COMPOSE_FILE = %q, want %q", got, want)
	}
}

// Compose loads the operator's override by any of four names while
// COMPOSE_FILE is unset, the first it finds in its own order and only that
// one: the list kvsctl writes names that one, an entry naming any of them
// by any path counts as the override, and a rollback that puts back a list
// a version ran with adds the one created since.
func TestSetComposeFilesSeedsAnOverrideByAnyName(t *testing.T) {
	for _, name := range []string{"compose.override.yml", "compose.override.yaml", "docker-compose.override.yml", "docker-compose.override.yaml"} {
		inst := testInstance(t, "DOMAIN=example.com\n", name)
		r := &Runner{Inst: inst, Reporter: &recorder{}}
		if err := r.setComposeFiles([]string{"docker/docker-compose.yml", "docker/" + ReleaseOverride}); err != nil {
			t.Fatal(err)
		}
		if got, want := inst.Env["COMPOSE_FILE"], "docker-compose.yml:"+name+":"+ReleaseOverride; got != want {
			t.Errorf("%s: COMPOSE_FILE = %q, want %q", name, got, want)
		}
		listed := testInstance(t, "DOMAIN=example.com\nCOMPOSE_FILE=docker-compose.yml:./"+name+"\n", name)
		r = &Runner{Inst: listed, Reporter: &recorder{}}
		if err := r.setComposeFiles([]string{"docker/" + ReleaseOverride}); err != nil {
			t.Fatal(err)
		}
		if got, want := listed.Env["COMPOSE_FILE"], "docker-compose.yml:./"+name+":"+ReleaseOverride; got != want {
			t.Errorf("%s listed: COMPOSE_FILE = %q, want %q", name, got, want)
		}
		if got, want := r.withOverride("docker-compose.yml:./"+name), "docker-compose.yml:./"+name; got != want {
			t.Errorf("%s: a list that names the override already became %q", name, got)
		}
		if got, want := r.withOverride("docker-compose.yml:"+ReleaseOverride), "docker-compose.yml:"+name+":"+ReleaseOverride; got != want {
			t.Errorf("%s: the list a rollback writes is %q, want %q", name, got, want)
		}
	}
	several := testInstance(t, "DOMAIN=example.com\n", "docker-compose.override.yaml", "compose.override.yaml", "docker-compose.override.yml")
	if got := DefaultOverride(several.DockerDir); got != "compose.override.yaml" {
		t.Errorf("with several overrides DefaultOverride = %q, want the one compose loads", got)
	}
	// A list that names an override by another name than the one compose
	// would load is the operator's choice: no run adds the other, which
	// status says is for the operator to add by hand.
	chosen := testInstance(t, "DOMAIN=example.com\nCOMPOSE_FILE=docker-compose.yml:docker-compose.override.yml\n", "compose.override.yaml", "docker-compose.override.yml")
	r := &Runner{Inst: chosen, Reporter: &recorder{}}
	if err := r.setComposeFiles([]string{"docker/" + ReleaseOverride}); err != nil {
		t.Fatal(err)
	}
	if got, want := chosen.Env["COMPOSE_FILE"], "docker-compose.yml:docker-compose.override.yml:"+ReleaseOverride; got != want {
		t.Errorf("another override listed: COMPOSE_FILE = %q, want %q", got, want)
	}
	if got, want := r.withOverride("docker-compose.yml:docker-compose.override.yml"), "docker-compose.yml:docker-compose.override.yml"; got != want {
		t.Errorf("another override listed: the list a rollback writes is %q, want %q", got, want)
	}
	if got := DefaultOverride(t.TempDir()); got != "" {
		t.Errorf("without one DefaultOverride = %q", got)
	}
}

func TestSetComposeFilesWithoutAnOverrideOnDisk(t *testing.T) {
	inst := testInstance(t, "DOMAIN=example.com\n")
	r := &Runner{Inst: inst, Reporter: &recorder{}}
	if err := r.setComposeFiles([]string{"docker/docker-compose.yml", "docker/" + ReleaseOverride}); err != nil {
		t.Fatal(err)
	}
	if got, want := inst.Env["COMPOSE_FILE"], "docker-compose.yml:"+ReleaseOverride; got != want {
		t.Errorf("COMPOSE_FILE = %q, want %q", got, want)
	}
}

func TestSetComposeFilesHonoursThePathSeparator(t *testing.T) {
	inst := testInstance(t, "DOMAIN=example.com\nCOMPOSE_PATH_SEPARATOR=,\nCOMPOSE_FILE=docker-compose.yml,docker-compose.multi.yml\n")
	r := &Runner{Inst: inst, Reporter: &recorder{}}
	if err := r.setComposeFiles([]string{"docker/" + ReleaseOverride}); err != nil {
		t.Fatal(err)
	}
	if got, want := inst.Env["COMPOSE_FILE"], "docker-compose.yml,docker-compose.multi.yml,"+ReleaseOverride; got != want {
		t.Errorf("COMPOSE_FILE = %q, want %q", got, want)
	}
}

// A rollback puts COMPOSE_FILE back exactly: the list it held, or no key
// at all when .env set none.
func TestSetComposeFilePutsTheValueBack(t *testing.T) {
	inst := testInstance(t, "DOMAIN=example.com\nCOMPOSE_FILE=docker-compose.yml:"+ReleaseOverride+"\n")
	r := &Runner{Inst: inst, Reporter: &recorder{}}
	if err := r.setComposeFile(""); err != nil {
		t.Fatal(err)
	}
	if env, _ := instance.ReadEnv(inst.EnvPath); env["COMPOSE_FILE"] != "" || strings.Contains(fmt.Sprint(env), "COMPOSE_FILE") {
		t.Errorf("COMPOSE_FILE is still in .env: %v", env)
	}
	if err := r.setComposeFile("docker-compose.yml"); err != nil {
		t.Fatal(err)
	}
	if env, _ := instance.ReadEnv(inst.EnvPath); env["COMPOSE_FILE"] != "docker-compose.yml" {
		t.Errorf("COMPOSE_FILE = %q", env["COMPOSE_FILE"])
	}
}

// --keep N of an upgrade keeps the N newest archives, the one the upgrade
// takes among them, as kvsctl backup --keep does, and the archive a
// manual rollback of the installed version replays whatever its age: 0
// keeps those alone, and below 0 reads as 0.
func TestUpgradeKeepsTheNewestBackupsAsBackupDoes(t *testing.T) {
	for _, keep := range []int{-1, 0, 1, 2} {
		s := newStack(t, "", rel{version: "1.0.0"}, rel{version: "1.1.0"})
		var older []string
		for range 4 {
			older = append(older, s.backupNow("1.0.0"))
		}
		if err := s.upgrade(s.runner(func(o *Options) { o.KeepBackups = keep })); err != nil {
			t.Fatalf("--keep %d: upgrade: %v", keep, err)
		}
		want := []string{s.state().UpgradeBackup}
		if keep > 1 {
			want = append(want, older[len(older)-keep+1:]...)
		}
		slices.Sort(want)
		left, _ := filepath.Glob(filepath.Join(s.root, "backups", "backup-*.tar"))
		if !slices.Equal(left, want) {
			t.Errorf("--keep %d left %v, want %v", keep, left, want)
		}
		removed := fmt.Sprintf("removed %d older backups (--keep %d; this one and the one a rollback replays always stay): ", len(older)+1-len(want), max(keep, 0))
		if !s.rep.said(removed) {
			t.Errorf("--keep %d: the log lacks %q: %v", keep, removed, s.rep.logs())
		}
	}
}

func TestMissingBytes(t *testing.T) {
	img := manifest.Image{Size: 100, Layers: []manifest.Layer{{DiffID: "a", Size: 60}, {DiffID: "b", Size: 40}}}
	if missingBytes(img, nil) != 100 || missingBytes(manifest.Image{Size: 7}, map[string]bool{}) != 7 {
		t.Error("without layers or without the engine the whole image counts")
	}
	if got := missingBytes(img, map[string]bool{"a": true}); got != 40 {
		t.Errorf("missing bytes = %d, want 40", got)
	}
}

func TestHumanBytes(t *testing.T) {
	if humanBytes(245_000_000) != "245 MB" || humanBytes(999) != "999 B" || humanBytes(1_500_000_000) != "1.50 GB" {
		t.Error("humanBytes formats wrongly")
	}
}

// A tag names a series only when it carries major.minor: mariadb:11 floats
// over the 11 series, and the version the image declares decides instead.
func TestImageSeries(t *testing.T) {
	cases := map[string]string{
		"mariadb:11.8":                     "11.8",
		"mariadb:11.8.3":                   "11.8",
		"mariadb:11.8-ubi":                 "11.8",
		"docker.io/library/mariadb:12.0.1": "12.0",
		"mariadb:11":                       "",
		"mariadb:lts":                      "",
		"localhost:5000/mariadb":           "",
		"mariadb:11.8@sha256:abc":          "11.8",
		"":                                 "",
	}
	for ref, want := range cases {
		if got := imageSeries(ref); got != want {
			t.Errorf("imageSeries(%q) = %q, want %q", ref, got, want)
		}
	}
}

func TestPatchVersions(t *testing.T) {
	for in, want := range map[string]string{"11.8.9": "11.8.9", "11.8.9-ubi9": "11.8.9", "11.8": "", "lts": "", "11.8.x": ""} {
		if got := patchVersion(in); got != want {
			t.Errorf("patchVersion(%q) = %q, want %q", in, got, want)
		}
	}
	if !lessPatch("11.8.9", "11.8.10") || lessPatch("11.8.10", "11.8.9") || lessPatch("11.8.9", "11.8.9") {
		t.Error("patch versions compare as text, not as numbers")
	}
}

// A chain of releases that each require the previous one is announced whole,
// not one refusal at a time.
func TestPlanJumpsCollectsEveryStop(t *testing.T) {
	m := &manifest.Manifest{Releases: []manifest.Release{
		{Version: "0.4.0", Requires: manifest.Requires{MinFrom: "0.3.0"}},
		{Version: "0.3.0", Requires: manifest.Requires{MinFrom: "0.2.0"}},
		{Version: "0.2.0"},
		{Version: "0.1.0"},
	}}
	plan := &Plan{Current: "0.1.0", Target: &m.Releases[0]}
	(&Runner{}).planJumps(plan, m)
	if len(plan.Stops) != 2 || plan.Stops[0] != "0.2.0" || plan.Stops[1] != "0.3.0" {
		t.Fatalf("stops = %v, want 0.2.0 then 0.3.0", plan.Stops)
	}
	if len(plan.Blockers) != 1 || !strings.Contains(plan.Blockers[0], "0.1.0 -> 0.2.0 -> 0.3.0 -> 0.4.0") {
		t.Errorf("the chain is not in the blocker: %v", plan.Blockers)
	}
}

func TestPlanJumpsStaysQuietWhenTheStepIsAllowed(t *testing.T) {
	m := &manifest.Manifest{Releases: []manifest.Release{
		{Version: "0.3.0", Requires: manifest.Requires{MinFrom: "0.2.0"}},
		{Version: "0.2.0"},
	}}
	plan := &Plan{Current: "0.2.0", Target: &m.Releases[0]}
	(&Runner{}).planJumps(plan, m)
	if len(plan.Stops) != 0 || len(plan.Blockers) != 0 {
		t.Errorf("an allowed step blocked: %v %v", plan.Stops, plan.Blockers)
	}
}

// A target older than the installed version is a rollback when there is
// one to return to; without one, the message says what is left instead of
// pointing at a rollback that would refuse. A stack ahead of the latest
// stable release has nothing to upgrade to.
func TestDowngradeMessage(t *testing.T) {
	plan := &Plan{Current: "0.2.0", Previous: "0.1.0", Target: &manifest.Release{Version: "0.1.0"}}
	want := "0.1.0 is older than the installed 0.2.0: use 'kvsctl rollback' (previous is 0.1.0)"
	if got := plan.DowngradeMessage(); got != want {
		t.Errorf("message = %q, want %q", got, want)
	}
	plan.Previous = ""
	want = "0.1.0 is older than the installed 0.2.0, and kvsctl cannot install an older release on this stack: no previous version is recorded for a rollback; 'kvsctl restore' replays a backup of the database, and going back to 0.1.0 means installing it anew"
	if got := plan.DowngradeMessage(); got != want {
		t.Errorf("without a previous version: %q, want %q", got, want)
	}
	plan = &Plan{Current: "0.3.0-rc1", Previous: "0.1.0", Target: &manifest.Release{Version: "0.2.0"}, latest: true}
	want = "the installed 0.3.0-rc1 is newer than 0.2.0, the latest stable release: there is nothing to upgrade to"
	if got := plan.DowngradeMessage(); got != want {
		t.Errorf("a stack on a candidate: %q, want %q", got, want)
	}
}

// The stops of an upgrade to an older release than the newest are those
// of the releases up to it, never of the ones above.
func TestPlanJumpsStopsAtTheTarget(t *testing.T) {
	m := &manifest.Manifest{Releases: []manifest.Release{
		{Version: "0.4.0", Requires: manifest.Requires{MinFrom: "0.3.0"}},
		{Version: "0.3.0", Requires: manifest.Requires{MinFrom: "0.2.0"}},
		{Version: "0.2.0"},
		{Version: "0.1.0"},
	}}
	plan := &Plan{Current: "0.1.0", Target: &m.Releases[2]}
	(&Runner{}).planJumps(plan, m)
	if len(plan.Stops) != 0 || len(plan.Blockers) != 0 {
		t.Errorf("an upgrade to 0.2.0 took the stops of the releases above it: %v %v", plan.Stops, plan.Blockers)
	}
}

// The sentinel behind a failure is what gives kvsctl its exit code, and the
// cause must stay readable through it.
func TestFailureCarriesBothTheCauseAndTheSentinel(t *testing.T) {
	cause := errors.New("php-fpm is restarting")
	err := &failure{msg: "upgrade to 0.3.0 failed: php-fpm is restarting; 0.2.0 is back and healthy", cause: cause, kind: ErrRolledBack}
	if !errors.Is(err, ErrRolledBack) || !errors.Is(err, cause) {
		t.Error("errors.Is does not find the sentinel or the cause")
	}
	if errors.Is(err, ErrRollbackFailed) {
		t.Error("a rolled back upgrade is not a failed rollback")
	}
	blocked := &failure{msg: "upgrade blocked: disk", kind: ErrBlocked}
	if !errors.Is(blocked, ErrBlocked) || blocked.Error() != "upgrade blocked: disk" {
		t.Error("a blocker loses its sentinel or its message")
	}
}

func TestStatusNote(t *testing.T) {
	resp := &http.Response{StatusCode: http.StatusMovedPermanently, Header: http.Header{}}
	resp.Header.Set("Location", "https://www.example.com/")
	if got := statusNote(resp, "example.com"); got != " (www redirect)" {
		t.Errorf("note = %q", got)
	}
	resp.Header.Set("Location", "https://other.example.org/")
	if got := statusNote(resp, "example.com"); got != " (redirect to other.example.org)" {
		t.Errorf("note = %q", got)
	}
	if got := statusNote(&http.Response{StatusCode: http.StatusOK, Header: http.Header{}}, "example.com"); got != "" {
		t.Errorf("a 200 needs no note: %q", got)
	}
	for _, code := range []int{http.StatusUnauthorized, http.StatusForbidden} {
		if got := statusNote(&http.Response{StatusCode: code, Header: http.Header{}}, "example.com"); got != " (protected)" {
			t.Errorf("%d: note = %q", code, got)
		}
	}
}

func TestImageEnvKey(t *testing.T) {
	for service, want := range map[string]string{"php-fpm": "KVS_PHP_FPM_IMAGE", "cron": "KVS_CRON_IMAGE", "kvs-init": "KVS_KVS_INIT_IMAGE", "mariadb": "KVS_MARIADB_IMAGE"} {
		if got := ImageEnvKey(service); got != want {
			t.Errorf("ImageEnvKey(%q) = %q, want %q", service, got, want)
		}
	}
}

// A release that publishes its PHP images per series gives an instance the
// shared images plus the ones of its series, and the .env values the
// release override reads; a series it does not publish is a blocker.
func TestPlanVariantsPicksThePHPSeries(t *testing.T) {
	target := &manifest.Release{
		Version: "26.9.0",
		Images:  []manifest.Image{{Service: "nginx", Ref: "r/nginx:26.9.0", Digest: "sha256:aa"}},
		Variants: map[string]map[string][]manifest.Image{manifest.VariantPHP: {
			"8.1": {{Service: "php-fpm", Ref: "r/php:26.9.0-php8.1", Digest: "sha256:b1"}},
			"8.2": {
				{Service: "php-fpm", Ref: "r/php:26.9.0-php8.2", Digest: "sha256:b2"},
				{Service: "cron", Ref: "r/cron:26.9.0-php8.2", Digest: "sha256:c2"},
			},
		}},
	}
	ctx := context.Background()
	r := &Runner{Inst: testInstance(t, "DOMAIN=example.com\nPHP_VERSION=8.2\n"), Reporter: &recorder{}}
	plan := &Plan{Target: target}
	if !r.planVariants(ctx, plan, nil) || len(plan.Blockers) != 0 {
		t.Fatalf("blocked: %v", plan.Blockers)
	}
	if plan.PHPSeries != "8.2" || len(plan.Images) != 3 {
		t.Errorf("series %q, %d images", plan.PHPSeries, len(plan.Images))
	}
	if got := plan.ImageEnv["KVS_PHP_FPM_IMAGE"]; got != "r/php:26.9.0-php8.2@sha256:b2" {
		t.Errorf("KVS_PHP_FPM_IMAGE = %q", got)
	}
	if got := plan.ImageEnv["KVS_CRON_IMAGE"]; got != "r/cron:26.9.0-php8.2@sha256:c2" {
		t.Errorf("KVS_CRON_IMAGE = %q", got)
	}

	other := &Runner{Inst: testInstance(t, "DOMAIN=example.com\nPHP_VERSION=8.3\n"), Reporter: &recorder{}}
	blocked := &Plan{Target: target}
	if other.planVariants(ctx, blocked, nil) {
		t.Error("an unpublished series was accepted")
	}
	if len(blocked.Blockers) != 1 || !strings.Contains(blocked.Blockers[0], "PHP 8.3") || !strings.Contains(blocked.Blockers[0], "8.1, 8.2") {
		t.Errorf("an unpublished series must block and name the published ones: %v", blocked.Blockers)
	}
	if len(blocked.Images) != 1 || blocked.ImageEnv != nil {
		t.Errorf("a blocked plan keeps the shared images only: %d images, env %v", len(blocked.Images), blocked.ImageEnv)
	}

	plain := &Plan{Target: &manifest.Release{Version: "26.9.0", Images: target.Images}}
	if !other.planVariants(ctx, plain, nil) || plain.PHPSeries != "" || len(plain.Images) != 1 || len(plain.Blockers) != 0 || plain.ImageEnv != nil {
		t.Errorf("a release without variants serves every series: %+v", plain)
	}
}

// The variant keys of the release being left go, the ones of the release
// arriving come, and nothing else in .env moves.
func TestSetImageEnvWritesAndDropsKeys(t *testing.T) {
	inst := testInstance(t, "DOMAIN=example.com\nMARIADB_VERSION=11.8\nKVS_CRON_IMAGE=r/cron:old@sha256:0\n")
	r := &Runner{Inst: inst, Reporter: &recorder{}}
	old := map[string]string{"KVS_CRON_IMAGE": "r/cron:old@sha256:0", "MARIADB_VERSION": "11.8"}
	want := map[string]string{"KVS_PHP_FPM_IMAGE": "r/php:new@sha256:1"}
	if err := r.setImageEnv(want, old); err != nil {
		t.Fatal(err)
	}
	env, err := instance.ReadEnv(inst.EnvPath)
	if err != nil {
		t.Fatal(err)
	}
	if _, ok := env["KVS_CRON_IMAGE"]; ok {
		t.Error("the key of the release being left is still in .env")
	}
	if env["KVS_PHP_FPM_IMAGE"] != "r/php:new@sha256:1" || env["DOMAIN"] != "example.com" {
		t.Errorf(".env after the upgrade: %v", env)
	}
	if env["MARIADB_VERSION"] != "11.8" {
		t.Errorf("an upgrade dropped MARIADB_VERSION, which setup.sh needs: %v", env)
	}
}

// A rollback puts back exactly what .env held: the value of each key, and
// no line for a key that was not there.
func TestRestoreEnvPutsBackWhatWasThere(t *testing.T) {
	inst := testInstance(t, "DOMAIN=example.com\nMARIADB_VERSION=12.3\nKVS_PHP_FPM_IMAGE=r/php:new@sha256:1\nKVS_MARIADB_IMAGE=mariadb:12.3.3@sha256:2\n")
	r := &Runner{Inst: inst, Reporter: &recorder{}}
	before := map[string]string{"MARIADB_VERSION": "11.8", "KVS_MARIADB_IMAGE": "mariadb:11.8.9@sha256:3"}
	after := map[string]string{"MARIADB_VERSION": "12.3", "KVS_MARIADB_IMAGE": "mariadb:12.3.3@sha256:2", "KVS_PHP_FPM_IMAGE": "r/php:new@sha256:1"}
	if err := r.restoreEnv(before, after); err != nil {
		t.Fatal(err)
	}
	env, _ := instance.ReadEnv(inst.EnvPath)
	if env["MARIADB_VERSION"] != "11.8" || env["KVS_MARIADB_IMAGE"] != "mariadb:11.8.9@sha256:3" {
		t.Errorf("the values of before are not back: %v", env)
	}
	if _, ok := env["KVS_PHP_FPM_IMAGE"]; ok {
		t.Errorf("a key that was not there before is still in .env: %v", env)
	}
}

// After a rollback the slots swap; running it again would reinstall the
// newer version around every safeguard, so it is refused, the upgrade
// command named instead, and the screen still told the run is over.
func TestRollbackRefusesToGoForward(t *testing.T) {
	rep := &recorder{}
	r := &Runner{Inst: testInstance(t, "DOMAIN=example.com\n"), Reporter: rep}
	err := r.Rollback(context.Background(), &instance.State{Current: "0.2.0", Previous: "0.5.0"})
	if err == nil || !strings.Contains(err.Error(), "kvsctl upgrade --version 0.5.0") {
		t.Errorf("a forward rollback was not refused: %v", err)
	}
	if done, ok := rep.done(); !ok || done == nil {
		t.Errorf("the refusal did not end the screen: %v %v", done, ok)
	}
	if msg := forwardRollback(&instance.State{Current: "0.5.0", Previous: "0.2.0"}); msg != "" {
		t.Errorf("a backward rollback was refused: %s", msg)
	}
	if msg := forwardRollback(&instance.State{Current: "lab", Previous: "0.2.0"}); msg != "" {
		t.Errorf("a version that does not parse must not decide: %s", msg)
	}
}

// A state that lists no release files cannot tell a rollback what to put
// back: it is refused before anything changes.
func TestRollbackNeedsTheFileLists(t *testing.T) {
	r := &Runner{Inst: testInstance(t, "DOMAIN=example.com\n"), Reporter: &recorder{}}
	if err := os.MkdirAll(r.releaseDir("0.1.0"), 0o755); err != nil {
		t.Fatal(err)
	}
	err := r.Rollback(context.Background(), &instance.State{Current: "0.2.0", Previous: "0.1.0", Files: []string{"docker/docker-compose.yml"}})
	if err == nil || !strings.Contains(err.Error(), "a rollback cannot tell which files to put back; nothing was changed") {
		t.Errorf("err = %v", err)
	}
}

// A rollback never moves MariaDB to a newer series either: after a manual
// rollback of a series change applied to the same version, the previous
// images are the newer series, and only an upgrade moves there, backup
// first.
func TestRollbackRefusesToMoveMariaDBForward(t *testing.T) {
	state := &instance.State{
		Current:        "26.10.0",
		Previous:       "26.10.0",
		Images:         map[string]string{"KVS_MARIADB_IMAGE": "mariadb:11.8.9@sha256:1"},
		PreviousImages: map[string]string{"KVS_MARIADB_IMAGE": "mariadb:12.3.3@sha256:2", "MARIADB_VERSION": "12.3"},
	}
	msg := forwardRollback(state)
	if !strings.Contains(msg, "never moves MariaDB to a newer series") || !strings.Contains(msg, "--mariadb-series 12.3") {
		t.Errorf("message = %q", msg)
	}
	state.Images, state.PreviousImages = state.PreviousImages, state.Images
	if msg := forwardRollback(state); msg != "" {
		t.Errorf("going back a series is what a rollback does: %s", msg)
	}
}

func TestImageVersion(t *testing.T) {
	cases := map[string]string{
		"":                  "none",
		"kvs-example-nginx": "local build",
		"mariadb:11.8":      "11.8",
		"127.0.0.1:5000/kvs-install/php:0.2.0@sha256:ab": "0.2.0",
		"ghcr.io/x/kvs-install/php:26.11.0-php8.1":       "26.11.0-php8.1",
		"127.0.0.1:5000/kvs-install/nginx":               "latest",
	}
	for ref, want := range cases {
		if got := ImageVersion(ref); got != want {
			t.Errorf("ImageVersion(%q) = %q, want %q", ref, got, want)
		}
	}
}

// The reporter hears every service of the release with its versions
// before the question: the ones to pull with their size, the others with
// a note, so the screen shows the plan and not only the downloads.
func TestAnnounceImagesNamesEveryService(t *testing.T) {
	rep := &recorder{}
	r := &Runner{Inst: testInstance(t, "DOMAIN=example.com\n"), Reporter: rep}
	plan := &Plan{Bytes: 70, Services: []PlanImage{
		{Image: manifest.Image{Service: "nginx", Ref: "r/nginx:0.2.0"}, Running: "kvs-x-nginx", Bytes: 70, Active: true},
		{Image: manifest.Image{Service: "mariadb", Ref: "mariadb:11.8"}, Running: "mariadb:11.8", OnDisk: true, Unchanged: true, Active: true},
		{Image: manifest.Image{Service: "kvs-init", Ref: "r/init:0.2.0"}, Running: "", OnDisk: true},
		{Image: manifest.Image{Service: "manticore", Ref: "r/manticore:0.2.0"}, Bytes: 30},
	}}
	r.announceImages(plan)
	var got []string
	for _, e := range rep.events {
		if e.Kind == KindImage {
			got = append(got, fmt.Sprintf("%s %s>%s %d %v %q", e.Service, e.From, e.To, e.Progress.Total, e.Progress.Done, e.Message))
		}
	}
	want := []string{
		`nginx local build>0.2.0 70 false ""`,
		`mariadb 11.8>11.8 0 true "unchanged"`,
		`kvs-init none>0.2.0 0 true "already on this machine"`,
		`manticore none>0.2.0 0 true "not pulled, the service is not active"`,
	}
	if strings.Join(got, "\n") != strings.Join(want, "\n") {
		t.Errorf("announced:\n%s\nwant:\n%s", strings.Join(got, "\n"), strings.Join(want, "\n"))
	}
}

// What a rollback does with the database, case by case: what the run
// really did decides what is undone.
func TestRestorePlan(t *testing.T) {
	archive := "/opt/kvs/backups/backup-1.0.0-20261001-120000.tar"
	cases := []struct {
		name          string
		j             instance.Journal
		recreated     bool
		restore, move bool
		because       string
	}{
		{"no backup", instance.Journal{To: "1.1.0", OneWay: true, Database: migrates, ComposeStarted: true}, true, false, false, "no backup"},
		{"compose never started", instance.Journal{To: "1.1.0", Backup: archive, Database: migrates}, false, false, false, "compose never started"},
		{"one way, mariadb recreated", instance.Journal{To: "1.1.0", Backup: archive, OneWay: true, Database: migrates, ComposeStarted: true}, true, true, true, "moved aside"},
		{"one way, mariadb left alone", instance.Journal{To: "1.1.0", Backup: archive, OneWay: true, ComposeStarted: true}, false, false, false, "does not change"},
		{"migrates, compose started", instance.Journal{To: "1.1.0", Backup: archive, Database: migrates, ComposeStarted: true}, false, true, false, "changes the database"},
		{"restore-db", instance.Journal{To: "1.1.0", Backup: archive, RestoreDB: true, ComposeStarted: true}, false, true, false, "--restore-db"},
		{"plain release", instance.Journal{To: "1.1.0", Backup: archive, ComposeStarted: true}, true, false, false, "does not change"},
		{"manual rollback that replayed", instance.Journal{Action: instance.ActionRollback, To: "1.0.0", Backup: archive, Database: migrates, ComposeStarted: true}, false, true, false, "replayed an older dump"},
	}
	for _, c := range cases {
		restore, move, why := restorePlan(nil, &c.j, c.recreated)
		if restore != c.restore || move != c.move || !strings.Contains(why, c.because) {
			t.Errorf("%s: restore %v move %v (%q), want %v %v (%q)", c.name, restore, move, why, c.restore, c.move, c.because)
		}
	}
	// The log names the unreleased checkout an adopt recorded by its commit.
	adopted := &instance.State{AdoptedCommit: strings.Repeat("a", 40)}
	back := &instance.Journal{Action: instance.ActionRollback, To: instance.Unreleased, Backup: archive, ComposeStarted: true}
	if _, _, why := restorePlan(adopted, back, false); why != "unreleased checkout aaaaaaaaaaaa does not change the database, it is left as it is" {
		t.Errorf("a rollback to the checkout logs %q", why)
	}
}

// The re-apply of a release keeps its new files apart until it is
// recorded, then moves them in; doing that twice, which a crash between
// the two leads to, changes nothing.
func TestPromoteIsIdempotent(t *testing.T) {
	inst := testInstance(t, "DOMAIN=example.com\n")
	r := &Runner{Inst: inst, Reporter: &recorder{}}
	if err := os.MkdirAll(filepath.Join(r.releaseDir("1.0.0"), "docker"), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(r.releaseDir("1.0.0"), "old.txt"), []byte("old"), 0o644); err != nil {
		t.Fatal(err)
	}
	if err := os.MkdirAll(r.stagingDir("1.0.0"), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(r.stagingDir("1.0.0"), "new.txt"), []byte("new"), 0o644); err != nil {
		t.Fatal(err)
	}
	for range 2 {
		if err := r.promote("1.0.0"); err != nil {
			t.Fatal(err)
		}
	}
	if _, err := os.Stat(filepath.Join(r.releaseDir("1.0.0"), "new.txt")); err != nil {
		t.Errorf("the staged files are not in the release directory: %v", err)
	}
	if _, err := os.Stat(filepath.Join(r.releaseDir("1.0.0"), "old.txt")); err == nil {
		t.Error("the files the re-apply replaced are still there")
	}
	if _, err := os.Stat(r.stagingDir("1.0.0")); err == nil {
		t.Error("the staging directory is still there")
	}
}
