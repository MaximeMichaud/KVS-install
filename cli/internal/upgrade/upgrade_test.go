package upgrade

import (
	"context"
	"errors"
	"fmt"
	"net/http"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/MaximeMichaud/KVS-install/cli/internal/dockerx"
	"github.com/MaximeMichaud/KVS-install/cli/internal/instance"
	"github.com/MaximeMichaud/KVS-install/cli/internal/manifest"
)

// recorder is a reporter that keeps what the runner said.
type recorder struct {
	events []Event
	answer bool
}

func (r *recorder) Event(e Event) { r.events = append(r.events, e) }

func (r *recorder) Confirm(context.Context, string) bool { return r.answer }

// logs are the free text lines, in order.
func (r *recorder) logs() []string {
	var out []string
	for _, e := range r.events {
		if e.Kind == KindLog {
			out = append(out, e.Message)
		}
	}
	return out
}

// testInstance writes a minimal installation in a temp directory: the
// compose file Detect looks for, the .env, and whatever else is named.
func testInstance(t *testing.T, env string, extra ...string) *instance.Instance {
	t.Helper()
	dir := t.TempDir()
	docker := filepath.Join(dir, "docker")
	if err := os.MkdirAll(docker, 0o755); err != nil {
		t.Fatal(err)
	}
	files := append([]string{"docker-compose.yml"}, extra...)
	for _, name := range files {
		if err := os.WriteFile(filepath.Join(docker, name), []byte("services: {}\n"), 0o644); err != nil {
			t.Fatal(err)
		}
	}
	if err := os.WriteFile(filepath.Join(docker, ".env"), []byte(env), 0o600); err != nil {
		t.Fatal(err)
	}
	inst, err := instance.Detect(dir)
	if err != nil {
		t.Fatal(err)
	}
	return inst
}

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

func TestImageSeries(t *testing.T) {
	cases := map[string]string{
		"mariadb:11.8":                     "11.8",
		"mariadb:11.8.3":                   "11.8",
		"mariadb:11.8-ubi":                 "11.8",
		"docker.io/library/mariadb:12.0.1": "12.0",
		"mariadb:11":                       "11",
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

func TestWithoutMariaDB(t *testing.T) {
	states := []dockerx.ContainerState{
		{Name: "kvs-mariadb", Service: "mariadb"},
		{Name: "kvs-php", Service: "php-fpm"},
		{Name: "site-mariadb"},
	}
	left := withoutMariaDB(states)
	if len(left) != 1 || left[0].Name != "kvs-php" {
		t.Errorf("left = %v, want the php container only", left)
	}
}

func TestDowngradeMessage(t *testing.T) {
	plan := &Plan{Current: "0.2.0", Previous: "0.1.0", Target: &manifest.Release{Version: "0.1.0"}}
	want := "0.1.0 is older than the installed 0.2.0: use 'kvsctl rollback' (previous is 0.1.0)"
	if got := plan.DowngradeMessage(); got != want {
		t.Errorf("message = %q, want %q", got, want)
	}
	plan.Previous = ""
	if got := plan.DowngradeMessage(); !strings.Contains(got, "no previous version is recorded") {
		t.Errorf("without a previous version: %q", got)
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
}

func TestImageEnvKey(t *testing.T) {
	for service, want := range map[string]string{"php-fpm": "KVS_PHP_FPM_IMAGE", "cron": "KVS_CRON_IMAGE", "kvs-init": "KVS_KVS_INIT_IMAGE"} {
		if got := ImageEnvKey(service); got != want {
			t.Errorf("ImageEnvKey(%q) = %q, want %q", service, got, want)
		}
	}
}

// A release that publishes its PHP images per series gives an instance the
// shared images plus the ones of its series, and the .env values the
// release override reads; a series it does not publish is a blocker.
func TestPlanImagesPicksThePHPSeries(t *testing.T) {
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
	r := &Runner{Inst: testInstance(t, "DOMAIN=example.com\nPHP_VERSION=8.2\n"), Reporter: &recorder{}}
	plan := &Plan{Target: target}
	r.planImages(plan)
	if len(plan.Blockers) != 0 {
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
	other.planImages(blocked)
	if len(blocked.Blockers) != 1 || !strings.Contains(blocked.Blockers[0], "PHP 8.3") {
		t.Errorf("an unpublished series must block: %v", blocked.Blockers)
	}
	if len(blocked.Images) != 1 || blocked.ImageEnv != nil {
		t.Errorf("a blocked plan keeps the shared images only: %d images, env %v", len(blocked.Images), blocked.ImageEnv)
	}

	plain := &Plan{Target: &manifest.Release{Version: "26.9.0", Images: target.Images}}
	other.planImages(plain)
	if plain.PHPSeries != "" || len(plain.Images) != 1 || len(plain.Blockers) != 0 || plain.ImageEnv != nil {
		t.Errorf("a release without variants serves every series: %+v", plain)
	}
}

// The variant keys of the release being left go, the ones of the release
// arriving come, and nothing else in .env moves; a rollback runs the same
// function the other way round.
func TestSetImageEnvWritesAndDropsKeys(t *testing.T) {
	inst := testInstance(t, "DOMAIN=example.com\nKVS_CRON_IMAGE=r/cron:old@sha256:0\n")
	r := &Runner{Inst: inst, Reporter: &recorder{}}
	old := map[string]string{"KVS_CRON_IMAGE": "r/cron:old@sha256:0"}
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
	if err := r.setImageEnv(old, want); err != nil {
		t.Fatal(err)
	}
	env, _ = instance.ReadEnv(inst.EnvPath)
	if env["KVS_CRON_IMAGE"] != "r/cron:old@sha256:0" || env["KVS_PHP_FPM_IMAGE"] != "" {
		t.Errorf(".env after the rollback: %v", env)
	}
}

// MariaDB moves one series at a time: a release names the series its image
// upgrades from, and a stack on another one is blocked before the
// --allow-mariadb-upgrade question even comes up. An accepted series change
// is one way.
func TestPlanMariaDBHonoursTheFromRule(t *testing.T) {
	r := &Runner{Inst: testInstance(t, "DOMAIN=example.com\n"), Reporter: &recorder{}, Opts: Options{AllowMariaDBUpgrade: true}}
	target := &manifest.Release{Version: "26.9.0", Requires: manifest.Requires{MariaDBFrom: []string{"11.8"}}}
	images := []manifest.Image{{Service: "mariadb", Ref: "mariadb:12.0", Digest: "sha256:d"}}
	running := map[string]dockerx.ServiceImage{"mariadb": {Image: "mariadb:11.4"}}
	plan := &Plan{Target: target, Images: images}
	if err := r.planMariaDB(plan, running); err != nil {
		t.Fatal(err)
	}
	if len(plan.Blockers) != 1 || !strings.Contains(plan.Blockers[0], "one series at a time") || plan.MariaDBUpgrade {
		t.Errorf("11.4 to 12.0 must be blocked: %v (upgrade %v)", plan.Blockers, plan.MariaDBUpgrade)
	}
	running["mariadb"] = dockerx.ServiceImage{Image: "mariadb:11.8"}
	plan = &Plan{Target: target, Images: images}
	if err := r.planMariaDB(plan, running); err != nil {
		t.Fatal(err)
	}
	if len(plan.Blockers) != 0 || !plan.MariaDBUpgrade || !plan.OneWay || plan.Database != "migrates" || !r.Opts.RestoreDB {
		t.Errorf("11.8 to 12.0 accepted: blockers %v, upgrade %v, one way %v, database %q", plan.Blockers, plan.MariaDBUpgrade, plan.OneWay, plan.Database)
	}
}

// After a rollback the slots swap; running it again would reinstall the
// newer version around every safeguard, so it is refused and the upgrade
// command named instead.
func TestRollbackRefusesToGoForward(t *testing.T) {
	r := &Runner{Inst: testInstance(t, "DOMAIN=example.com\n"), Reporter: &recorder{}}
	err := r.Rollback(context.Background(), &instance.State{Current: "0.2.0", Previous: "0.5.0"})
	if err == nil || !strings.Contains(err.Error(), "kvsctl upgrade --version 0.5.0") {
		t.Errorf("a forward rollback was not refused: %v", err)
	}
	if msg := forwardRollback(&instance.State{Current: "0.5.0", Previous: "0.2.0"}); msg != "" {
		t.Errorf("a backward rollback was refused: %s", msg)
	}
	if msg := forwardRollback(&instance.State{Current: "lab", Previous: "0.2.0"}); msg != "" {
		t.Errorf("a version that does not parse must not decide: %s", msg)
	}
}

func TestImageVersion(t *testing.T) {
	cases := map[string]string{
		"":                        "none",
		"kvs-maximemichaud-nginx": "local build",
		"mariadb:11.8":            "11.8",
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
		{Image: manifest.Image{Service: "nginx", Ref: "r/nginx:0.2.0"}, Running: "kvs-x-nginx", Bytes: 70},
		{Image: manifest.Image{Service: "mariadb", Ref: "mariadb:11.8"}, Running: "mariadb:11.8", OnDisk: true, Unchanged: true},
		{Image: manifest.Image{Service: "kvs-init", Ref: "r/init:0.2.0"}, Running: "", OnDisk: true},
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
	}
	if strings.Join(got, "\n") != strings.Join(want, "\n") {
		t.Errorf("announced:\n%s\nwant:\n%s", strings.Join(got, "\n"), strings.Join(want, "\n"))
	}
}
