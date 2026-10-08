package instance

import (
	"encoding/json"
	"errors"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

func TestReadAndSetEnv(t *testing.T) {
	dir := t.TempDir()
	docker := filepath.Join(dir, "docker")
	if err := os.MkdirAll(docker, 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(docker, "docker-compose.yml"), []byte("services: {}\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	env := "# comment\nDOMAIN=example.com\nSITE_PREFIX=kvs-example\nCOMPOSE_PROJECT_NAME=kvs-example\nHTTPS_PORT=127.0.0.1:18443\nIONCUBE=YES\nQUOTED=\"a b\"\n"
	if err := os.WriteFile(filepath.Join(docker, ".env"), []byte(env), 0o600); err != nil {
		t.Fatal(err)
	}
	inst, err := Detect(dir)
	if err != nil {
		t.Fatal(err)
	}
	if inst.Domain() != "example.com" || inst.ProjectName() != "kvs-example" || inst.HTTPSPort() != "18443" || !inst.IonCube() || inst.Env["QUOTED"] != "a b" || inst.PHPVersion() != "8.1" {
		t.Errorf("parsed instance is wrong: %+v", inst.Env)
	}
	if !inst.ProjectNameKnown() {
		t.Error("COMPOSE_PROJECT_NAME names the project")
	}
	if err := inst.SetEnv("COMPOSE_FILE", "docker-compose.yml:docker-compose.release.yml"); err != nil {
		t.Fatal(err)
	}
	if err := inst.SetEnv("DOMAIN", "example.org"); err != nil {
		t.Fatal(err)
	}
	again, err := ReadEnv(inst.EnvPath)
	if err != nil {
		t.Fatal(err)
	}
	if again["COMPOSE_FILE"] != "docker-compose.yml:docker-compose.release.yml" || again["DOMAIN"] != "example.org" || again["SITE_PREFIX"] != "kvs-example" {
		t.Errorf("SetEnv result: %+v", again)
	}
	info, _ := os.Stat(inst.EnvPath)
	if info.Mode().Perm() != 0o600 {
		t.Errorf(".env mode changed to %o", info.Mode().Perm())
	}
	if s, err := inst.LoadState(); err != nil || s != nil {
		t.Errorf("a never adopted stack has no state: %v %v", s, err)
	}
	if err := inst.SaveState(&State{Current: "0.1.0"}); err != nil {
		t.Fatal(err)
	}
	s, err := inst.LoadState()
	if err != nil || s.Current != "0.1.0" {
		t.Errorf("state round trip: %+v %v", s, err)
	}
}

// newInstance builds a detectable stack at a temporary root, with env as
// its docker/.env.
func newInstance(t *testing.T, env string) *Instance {
	t.Helper()
	dir := t.TempDir()
	docker := filepath.Join(dir, "docker")
	if err := os.MkdirAll(docker, 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(docker, "docker-compose.yml"), []byte("services: {}\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(docker, ".env"), []byte(env), 0o600); err != nil {
		t.Fatal(err)
	}
	inst, err := Detect(dir)
	if err != nil {
		t.Fatal(err)
	}
	return inst
}

func TestPublishedEndpoint(t *testing.T) {
	cases := []struct {
		port, host, want string
	}{
		{"", "127.0.0.1", "443"},
		{"443", "127.0.0.1", "443"},
		{"8443", "127.0.0.1", "8443"},
		{"127.0.0.1:8443", "127.0.0.1", "8443"},
		{"192.0.2.4:8443", "192.0.2.4", "8443"},
		{"[::1]:8443", "::1", "8443"},
		{"[2001:db8::1]:443", "2001:db8::1", "443"},
		{"0.0.0.0:443", "127.0.0.1", "443"},
		{"[::]:8443", "127.0.0.1", "8443"},
		{"nonsense:", "127.0.0.1", "443"},
	}
	for _, c := range cases {
		inst := &Instance{Env: map[string]string{"HTTPS_PORT": c.port}}
		host, port := inst.PublishedEndpoint()
		if host != c.host || port != c.want {
			t.Errorf("HTTPS_PORT=%q gave %q %q, want %q %q", c.port, host, port, c.host, c.want)
		}
		if got := inst.HTTPSPort(); got != c.want {
			t.Errorf("HTTPS_PORT=%q gave port %q, want %q", c.port, got, c.want)
		}
	}
}

func TestSiteHost(t *testing.T) {
	cases := []struct{ useWWW, want string }{
		{"", "example.com"},
		{"false", "example.com"},
		{"true", "www.example.com"},
		{"TRUE", "www.example.com"},
	}
	for _, c := range cases {
		inst := &Instance{Env: map[string]string{"DOMAIN": "example.com", "USE_WWW": c.useWWW}}
		if got := inst.SiteHost(); got != c.want {
			t.Errorf("USE_WWW=%q gave %q, want %q", c.useWWW, got, c.want)
		}
	}
}

func TestDetectRefusesMultiSite(t *testing.T) {
	dir := t.TempDir()
	docker := filepath.Join(dir, "docker")
	if err := os.MkdirAll(docker, 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(docker, "docker-compose.yml"), []byte("services: {}\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(docker, ".env"), []byte("DOMAIN=example.com\nMODE=multi\n"), 0o600); err != nil {
		t.Fatal(err)
	}
	_, err := Detect(dir)
	if err == nil || !strings.Contains(err.Error(), "multi-site installations are not supported") {
		t.Fatalf("MODE=multi must be refused, got %v", err)
	}
	if err := os.WriteFile(filepath.Join(docker, ".env"), []byte("DOMAIN=example.com\nMODE=single\n"), 0o600); err != nil {
		t.Fatal(err)
	}
	if _, err := Detect(dir); err != nil {
		t.Fatalf("the single site layout must be read: %v", err)
	}
	sites := filepath.Join(docker, "multi-site", "sites", "other.example.com")
	if err := os.MkdirAll(sites, 0o755); err != nil {
		t.Fatal(err)
	}
	_, err = Detect(dir)
	if err == nil || !strings.Contains(err.Error(), "multi-site installations are not supported") {
		t.Fatalf("a registered site must be refused, got %v", err)
	}
}

func TestLock(t *testing.T) {
	inst := newInstance(t, "DOMAIN=example.com\n")
	release, err := inst.Lock("upgrade")
	if err != nil {
		t.Fatal(err)
	}
	second, err := inst.Lock("status")
	if err == nil {
		second()
		t.Fatal("a second kvsctl must not take the lock")
	}
	var held *LockedError
	if !errors.As(err, &held) {
		t.Fatalf("a held lock must be a *LockedError, got %T %v", err, err)
	}
	if held.PID != os.Getpid() || held.Command != "upgrade" || held.Since.IsZero() {
		t.Errorf("the lock names the wrong run: %+v", held)
	}
	if !strings.Contains(err.Error(), "another kvsctl is running (pid ") || !strings.Contains(err.Error(), "upgrade, started ") {
		t.Errorf("message = %q", err.Error())
	}
	release()
	release()
	third, err := inst.Lock("backup")
	if err != nil {
		t.Fatalf("the lock must be free once released: %v", err)
	}
	third()
}

// Holder names the run that holds the lock, and neither takes the lock nor
// writes anything: no state directory appears, and the record of the last
// run stays as it was.
func TestHolder(t *testing.T) {
	inst := newInstance(t, "DOMAIN=example.com\n")
	if held, err := inst.Holder(); err != nil || held != nil {
		t.Fatalf("a stack never locked: %+v, %v", held, err)
	}
	if _, err := os.Stat(inst.StateDir()); !errors.Is(err, os.ErrNotExist) {
		t.Fatalf("Holder created %s: %v", inst.StateDir(), err)
	}
	release, err := inst.Lock("backup")
	if err != nil {
		t.Fatal(err)
	}
	held, err := inst.Holder()
	if err != nil || held == nil || held.PID != os.Getpid() || held.Command != "backup" || held.Since.IsZero() {
		t.Fatalf("a held lock: %+v, %v", held, err)
	}
	release()
	record, err := os.ReadFile(inst.lockPath())
	if err != nil {
		t.Fatal(err)
	}
	if held, err := inst.Holder(); err != nil || held != nil {
		t.Fatalf("a lock let go: %+v, %v", held, err)
	}
	if after, _ := os.ReadFile(inst.lockPath()); string(after) != string(record) {
		t.Errorf("Holder wrote %q over %q", after, record)
	}
	next, err := inst.Lock("upgrade")
	if err != nil {
		t.Fatalf("the lock after Holder: %v", err)
	}
	next()
}

func TestUpdates(t *testing.T) {
	inst := newInstance(t, "DOMAIN=example.com\n")
	u, err := inst.LoadUpdates()
	if err != nil || u == nil || len(u.Manifests) != 0 {
		t.Fatalf("a stack that never checked has empty updates: %+v %v", u, err)
	}
	stable, candidate := "https://example.com/stable/manifest.json", "https://example.com/rc/manifest.json"
	checked := time.Now().Truncate(time.Second)
	*u.For(stable) = ManifestCheck{LastCheck: checked, LatestSeen: "0.4.0", ManifestUpdated: "2026-10-02T00:00:00Z"}
	u.For(candidate).LatestSeen = "0.5.0"
	u.Keys = []AnnouncedKey{{ID: "kvs-2026", ValidFrom: "2026-01-01"}}
	if err := inst.SaveUpdates(u); err != nil {
		t.Fatal(err)
	}
	again, err := inst.LoadUpdates()
	if err != nil {
		t.Fatal(err)
	}
	if got := again.For(stable); got.LatestSeen != "0.4.0" || got.ManifestUpdated != "2026-10-02T00:00:00Z" || !got.LastCheck.Equal(checked) {
		t.Errorf("record of the stable list after a round trip: %+v", got)
	}
	if got := again.For(candidate); got.LatestSeen != "0.5.0" {
		t.Errorf("each URL keeps its own record, the candidate has %+v", got)
	}
	if len(again.Keys) != 1 || again.Keys[0].ID != "kvs-2026" {
		t.Errorf("keys after a round trip: %+v", again.Keys)
	}
	if got := again.For("https://example.org/other.json"); *got != (ManifestCheck{}) {
		t.Errorf("a URL never read has an empty record, got %+v", got)
	}
	if _, err := os.Stat(filepath.Join(inst.StateDir(), "updates.json")); err != nil {
		t.Errorf("updates live next to the state, not inside it: %v", err)
	}
	state, err := inst.LoadState()
	if err != nil || state != nil {
		t.Errorf("a check must not write state.json: %+v %v", state, err)
	}
}

// The builds that kept a single record wrote it at the top of the file; it
// becomes the record of the list they read by default, and the next save
// writes it in its place.
func TestUpdatesReadsTheSingleRecordOfOlderBuilds(t *testing.T) {
	inst := newInstance(t, "DOMAIN=example.com\n")
	if err := os.MkdirAll(inst.StateDir(), 0o750); err != nil {
		t.Fatal(err)
	}
	old := `{"last_check": "2026-10-01T08:00:00Z", "latest_seen": "0.3.0", "manifest_updated": "2026-09-30T00:00:00Z", "keys": [{"id": "kvs-2026"}]}`
	if err := os.WriteFile(filepath.Join(inst.StateDir(), "updates.json"), []byte(old), 0o600); err != nil {
		t.Fatal(err)
	}
	u, err := inst.LoadUpdates()
	if err != nil {
		t.Fatal(err)
	}
	got := u.For(legacyManifestURL)
	if got.LatestSeen != "0.3.0" || got.ManifestUpdated != "2026-09-30T00:00:00Z" || !got.LastCheck.Equal(time.Date(2026, 10, 1, 8, 0, 0, 0, time.UTC)) {
		t.Errorf("the single record must become the default list's: %+v", got)
	}
	if len(u.Manifests) != 1 || len(u.Keys) != 1 {
		t.Errorf("records %v, keys %v", u.Manifests, u.Keys)
	}
	if err := inst.SaveUpdates(u); err != nil {
		t.Fatal(err)
	}
	data, err := os.ReadFile(filepath.Join(inst.StateDir(), "updates.json"))
	if err != nil {
		t.Fatal(err)
	}
	var top map[string]json.RawMessage
	if err := json.Unmarshal(data, &top); err != nil {
		t.Fatal(err)
	}
	_, single := top["latest_seen"]
	if single || !strings.Contains(string(top["manifests"]), legacyManifestURL) {
		t.Errorf("a save writes the record under its URL only:\n%s", data)
	}

	// A record the newer layout already holds for that URL wins over the
	// single one.
	both := `{"latest_seen": "0.3.0", "manifests": {"` + legacyManifestURL + `": {"latest_seen": "0.4.0"}}}`
	if err := os.WriteFile(filepath.Join(inst.StateDir(), "updates.json"), []byte(both), 0o600); err != nil {
		t.Fatal(err)
	}
	u, err = inst.LoadUpdates()
	if err != nil {
		t.Fatal(err)
	}
	if got := u.For(legacyManifestURL).LatestSeen; got != "0.4.0" {
		t.Errorf("latest seen = %s, want the per URL record's 0.4.0", got)
	}

	if err := os.WriteFile(filepath.Join(inst.StateDir(), "updates.json"), []byte("{"), 0o600); err != nil {
		t.Fatal(err)
	}
	if _, err := inst.LoadUpdates(); err == nil || !strings.Contains(err.Error(), "updates.json") {
		t.Errorf("a damaged file must be named, got %v", err)
	}
}

func TestMergeEnv(t *testing.T) {
	inst := newInstance(t, "DOMAIN=example.com\nCACHE_TTL=42\n")
	example := filepath.Join(t.TempDir(), ".env.example")
	body := "# The cache keeps an object this long.\n" +
		"# Seconds.\nCACHE_TTL=300\n\n" +
		"# What the release added.\nNEW_KEY=new value\n" +
		"ANOTHER_KEY=2\n\n" +
		"# MariaDB - the setup owns this one.\nMARIADB_PASSWORD=CHANGE_ME\n" // pragma: allowlist secret
	if err := os.WriteFile(example, []byte(body), 0o644); err != nil {
		t.Fatal(err)
	}
	added, err := inst.MergeEnv(example)
	if err != nil {
		t.Fatal(err)
	}
	if len(added) != 2 || added[0] != "NEW_KEY" || added[1] != "ANOTHER_KEY" {
		t.Fatalf("added = %v", added)
	}
	merged, err := os.ReadFile(inst.EnvPath)
	if err != nil {
		t.Fatal(err)
	}
	text := string(merged)
	if !strings.Contains(text, "# What the release added.\nNEW_KEY=new value\n") {
		t.Errorf("a new key comes with the comment block above it:\n%s", text)
	}
	if strings.Contains(text, "MARIADB_PASSWORD") { // pragma: allowlist secret
		t.Errorf("a key the setup owns must never be added:\n%s", text)
	}
	env, err := ReadEnv(inst.EnvPath)
	if err != nil {
		t.Fatal(err)
	}
	if env["CACHE_TTL"] != "42" || env["NEW_KEY"] != "new value" || env["ANOTHER_KEY"] != "2" || env["DOMAIN"] != "example.com" {
		t.Errorf("merged .env = %+v", env)
	}
	if inst.Env["NEW_KEY"] != "new value" {
		t.Errorf("the merge must be visible to the running command: %+v", inst.Env)
	}
	if added, err := inst.MergeEnv(example); err != nil || added != nil {
		t.Errorf("a second merge adds nothing: %v %v", added, err)
	}
}

func TestTrackedFilesWithoutReleasePaths(t *testing.T) {
	if _, err := exec.LookPath("git"); err != nil {
		t.Skip("git is not installed")
	}
	inst := newInstance(t, "DOMAIN=example.com\n")
	if out, err := exec.Command("git", "-C", inst.Root, "init", "-q").CombinedOutput(); err != nil {
		t.Skipf("no repository to read: %v: %s", err, out)
	}
	_, err := inst.TrackedFiles()
	if err == nil || !strings.Contains(err.Error(), "tracks none of the release paths") {
		t.Fatalf("a checkout tracking no release file must be refused, got %v", err)
	}
}

func TestUnsetEnv(t *testing.T) {
	inst := newInstance(t, "DOMAIN=example.com\nKVS_PHP_FPM_IMAGE=r/php@sha256:1\nUSE_WWW=true\n")
	if err := inst.UnsetEnv("KVS_PHP_FPM_IMAGE"); err != nil {
		t.Fatal(err)
	}
	env, err := ReadEnv(inst.EnvPath)
	if err != nil {
		t.Fatal(err)
	}
	if _, ok := env["KVS_PHP_FPM_IMAGE"]; ok {
		t.Error("the key is still in .env")
	}
	if env["DOMAIN"] != "example.com" || env["USE_WWW"] != "true" {
		t.Errorf("the other keys moved: %v", env)
	}
	if _, ok := inst.Env["KVS_PHP_FPM_IMAGE"]; ok {
		t.Error("the key is still in memory")
	}
	if err := inst.UnsetEnv("MISSING"); err != nil {
		t.Errorf("a key that is not there is not an error: %v", err)
	}
}
