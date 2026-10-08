package dockerx

import (
	"context"
	"encoding/base64"
	"encoding/json"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"testing"

	"github.com/moby/moby/api/types/image"
)

var (
	digestA = "sha256:" + strings.Repeat("a", 64)
	digestB = "sha256:" + strings.Repeat("b", 64)
)

// pullsAs makes the fake answer a pull with a few progress lines and then
// hold the image under the repository at the digests listed.
func pullsAs(f *fakeEngine, repoDigests ...string) {
	f.setPulled(func(fromImage, tag string) ([]string, *image.InspectResponse) {
		lines := []string{
			`{"status":"Pulling from library/mariadb","id":"` + tag + `"}`,
			`{"status":"Pulling fs layer","progressDetail":{},"id":"l1"}`,
			`{"status":"Downloading","progressDetail":{"current":40,"total":100},"id":"l1"}`,
			`{"status":"Download complete","progressDetail":{},"id":"l1"}`,
			`{"status":"Pull complete","progressDetail":{},"id":"l1"}`,
			`{"status":"Digest: ` + tag + `"}`,
		}
		return lines, &image.InspectResponse{ID: "sha256:" + strings.Repeat("c", 64), RepoDigests: repoDigests}
	})
}

// noDockerConfig points the Docker CLI configuration at an empty directory,
// so a test never reads the configuration of the machine it runs on.
func noDockerConfig(t *testing.T) string {
	t.Helper()
	dir := t.TempDir()
	t.Setenv("DOCKER_CONFIG", dir)
	return dir
}

func writeDockerConfig(t *testing.T, cfg map[string]any) {
	t.Helper()
	data, err := json.Marshal(cfg)
	if err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(noDockerConfig(t), "config.json"), data, 0o600); err != nil {
		t.Fatal(err)
	}
}

// A release pins mariadb:11.8.9 at a digest. The pull asks the engine for
// the digest, never for the tag, which upstream may have moved since; the
// image is then tagged under the name the release gave it.
func TestPullByDigestThenTag(t *testing.T) {
	noDockerConfig(t)
	f, c := newFakeEngine(t)
	pullsAs(f, "mariadb@"+digestA)
	var reports []Progress
	if err := c.Pull(context.Background(), "mariadb:11.8.9", digestA, 0, func(p Progress) { reports = append(reports, p) }); err != nil {
		t.Fatal(err)
	}
	if len(f.pullRequests()) != 1 || f.pullRequests()[0].fromImage != "docker.io/library/mariadb" || f.pullRequests()[0].tag != digestA {
		t.Fatalf("the engine was asked for %+v, want docker.io/library/mariadb at the digest", f.pullRequests())
	}
	if f.pullRequests()[0].auth != nil {
		t.Errorf("no credentials are configured, the pull must be anonymous: %+v", f.pullRequests()[0].auth)
	}
	// The client sends the repository of the tag in its full form.
	if len(f.tags()) != 1 || f.tags()[0] != "mariadb@"+digestA+" -> docker.io/library/mariadb:11.8.9" {
		t.Errorf("tagged %v, want the pinned image tagged mariadb:11.8.9", f.tags())
	}
	last := reports[len(reports)-1]
	if !last.Done || last.Current != 100 || last.Total != 100 {
		t.Errorf("the last report is %+v, want the whole layer done", last)
	}
	for _, p := range reports[:len(reports)-1] {
		if p.Done {
			t.Errorf("only the last report is done: %+v", reports)
		}
	}
	// The engine now holds the digest, found under any tag of the
	// repository, and not another digest.
	for _, ref := range []string{"mariadb:11.8.9", "mariadb:11.8", "mariadb"} {
		if has, err := c.HasDigest(context.Background(), ref, digestA); err != nil || !has {
			t.Errorf("HasDigest(%s) = %v, %v", ref, has, err)
		}
	}
	if has, err := c.HasDigest(context.Background(), "mariadb:11.8.9", digestB); err != nil || has {
		t.Errorf("a digest the engine does not hold is false and no error: %v, %v", has, err)
	}
}

// A registry and a repository with a port and a path keep both; only the
// tag goes.
func TestPullKeepsTheRegistry(t *testing.T) {
	noDockerConfig(t)
	f, c := newFakeEngine(t)
	pullsAs(f, "localhost:5000/kvs/php@"+digestA)
	if err := c.Pull(context.Background(), "localhost:5000/kvs/php:8.3-26.10.0", digestA, 70, nil); err != nil {
		t.Fatal(err)
	}
	if f.pullRequests()[0].fromImage != "localhost:5000/kvs/php" || f.pullRequests()[0].tag != digestA {
		t.Errorf("pulled %+v", f.pullRequests()[0])
	}
	if f.tags()[0] != "localhost:5000/kvs/php@"+digestA+" -> localhost:5000/kvs/php:8.3-26.10.0" {
		t.Errorf("tagged %v", f.tags())
	}
}

func TestPullRefusesAnImageWithoutTheDigest(t *testing.T) {
	noDockerConfig(t)
	f, c := newFakeEngine(t)
	pullsAs(f, "mariadb@"+digestB)
	err := c.Pull(context.Background(), "mariadb:11.8.9", digestA, 0, nil)
	if err == nil || !strings.Contains(err.Error(), "does not carry the digest") {
		t.Fatalf("an image without the signed digest was accepted: %v", err)
	}
	if len(f.tags()) != 0 {
		t.Errorf("an image that failed its check must not be tagged: %v", f.tags())
	}
}

func TestPullReportsTheEngineError(t *testing.T) {
	noDockerConfig(t)
	f, c := newFakeEngine(t)
	f.setPulled(func(string, string) ([]string, *image.InspectResponse) {
		return []string{`{"status":"Pulling from library/mariadb"}`, `{"error":"toomanyrequests: rate limit"}`}, nil
	})
	err := c.Pull(context.Background(), "mariadb:11.8.9", digestA, 0, nil)
	if err == nil || !strings.Contains(err.Error(), "toomanyrequests") || !strings.Contains(err.Error(), "mariadb@"+digestA) {
		t.Fatalf("the error of the stream must name the image and say why: %v", err)
	}
}

func TestPullRefusesABadDigest(t *testing.T) {
	noDockerConfig(t)
	_, c := newFakeEngine(t)
	for _, digest := range []string{"", "sha256:abc", "md5:" + strings.Repeat("a", 64), "sha256:" + strings.Repeat("A", 64)} {
		if err := c.Pull(context.Background(), "mariadb:11.8.9", digest, 0, nil); err == nil {
			t.Errorf("digest %q was accepted", digest)
		}
	}
}

// The credentials of a "docker login" are in config.json, under the host
// for most registries and under the old index URL for Docker Hub.
func TestPullSendsTheSavedCredentials(t *testing.T) {
	auth := base64.StdEncoding.EncodeToString([]byte("kvs:aaaa"))
	cases := []struct {
		ref, saved, server string
	}{
		{"ghcr.io/kvs/php:8.3-26.10.0", "ghcr.io", "ghcr.io"},
		{"ghcr.io/kvs/php:8.3-26.10.0", "https://ghcr.io", "ghcr.io"},
		{"mariadb:11.8.9", dockerHub, dockerHub},
		{"docker.io/library/mariadb:11.8.9", dockerHub, dockerHub},
	}
	for _, tc := range cases {
		writeDockerConfig(t, map[string]any{"auths": map[string]any{tc.saved: map[string]string{"auth": auth}}})
		f, c := newFakeEngine(t)
		pullsAs(f, RefName(tc.ref)+"@"+digestA)
		if err := c.Pull(context.Background(), tc.ref, digestA, 0, nil); err != nil {
			t.Fatalf("%s: %v", tc.ref, err)
		}
		got := f.pullRequests()[0].auth
		if got == nil || got.Username != "kvs" || got.Password != "aaaa" || got.ServerAddress != tc.server { // pragma: allowlist secret
			t.Errorf("%s with credentials saved for %s sent %+v", tc.ref, tc.saved, got)
		}
	}
}

// Docker Hub credentials are not sent to another registry, and a host only
// matches its own entry.
func TestPullSendsNoCredentialsOfAnotherRegistry(t *testing.T) {
	auth := base64.StdEncoding.EncodeToString([]byte("kvs:aaaa"))
	writeDockerConfig(t, map[string]any{"auths": map[string]any{dockerHub: map[string]string{"auth": auth}, "registry.example.com": map[string]string{"auth": auth}}})
	f, c := newFakeEngine(t)
	pullsAs(f, "ghcr.io/kvs/php@"+digestA)
	if err := c.Pull(context.Background(), "ghcr.io/kvs/php:8.3", digestA, 0, nil); err != nil {
		t.Fatal(err)
	}
	if f.pullRequests()[0].auth != nil {
		t.Errorf("ghcr.io got the credentials of another registry: %+v", f.pullRequests()[0].auth)
	}
}

// fakeHelper installs docker-credential-<name> on PATH: it logs the server
// it was asked for and prints output, or fails with exit 1.
func fakeHelper(t *testing.T, name, output string, fail bool) string {
	t.Helper()
	dir := t.TempDir()
	log := filepath.Join(dir, "asked")
	exit := "0"
	if fail {
		exit = "1"
	}
	script := "#!/bin/sh\n" +
		"[ \"$1\" = get ] || exit 2\n" +
		"cat > '" + log + "'\n" +
		"printf '%s' '" + output + "'\n" +
		"exit " + exit + "\n"
	if err := os.WriteFile(filepath.Join(dir, "docker-credential-"+name), []byte(script), 0o755); err != nil {
		t.Fatal(err)
	}
	t.Setenv("PATH", dir+string(os.PathListSeparator)+os.Getenv("PATH"))
	return log
}

// A registry the configuration hands to a credential helper gets what the
// helper answers, and the helper is asked once per registry and run.
func TestPullAsksTheCredentialHelper(t *testing.T) {
	asked := fakeHelper(t, "kvstest", `{"ServerURL":"ghcr.io","Username":"helper-user","Secret":"aaaa"}`, false)
	writeDockerConfig(t, map[string]any{"credHelpers": map[string]string{"ghcr.io": "kvstest"}, "credsStore": "missing-store"})
	f, c := newFakeEngine(t)
	pullsAs(f, "ghcr.io/kvs/php@"+digestA, "ghcr.io/kvs/nginx@"+digestA)
	for _, ref := range []string{"ghcr.io/kvs/php:8.3", "ghcr.io/kvs/nginx:26.10.0"} {
		if err := c.Pull(context.Background(), ref, digestA, 0, nil); err != nil {
			t.Fatal(err)
		}
	}
	for _, pull := range f.pullRequests() {
		if pull.auth == nil || pull.auth.Username != "helper-user" || pull.auth.Password != "aaaa" || pull.auth.ServerAddress != "ghcr.io" { // pragma: allowlist secret
			t.Errorf("the pull of %s sent %+v", pull.fromImage, pull.auth)
		}
	}
	server, err := os.ReadFile(asked)
	if err != nil || string(server) != "ghcr.io" {
		t.Errorf("the helper was asked for %q (%v), want ghcr.io", server, err)
	}
	if len(c.auth) != 1 {
		t.Errorf("the credentials of one registry are read once per run: %v", c.auth)
	}
}

// Pulls that run at the same time share the credentials of their registry:
// the helper is asked once, and the cache is safe to fill from several
// goroutines.
func TestConcurrentPullsAskTheHelperOnce(t *testing.T) {
	dir := t.TempDir()
	log := filepath.Join(dir, "asked")
	script := "#!/bin/sh\n" +
		"[ \"$1\" = get ] || exit 2\n" +
		"printf '%s\\n' \"$(cat)\" >> '" + log + "'\n" +
		"printf '%s' '{\"ServerURL\":\"ghcr.io\",\"Username\":\"helper-user\",\"Secret\":\"aaaa\"}'\n"
	if err := os.WriteFile(filepath.Join(dir, "docker-credential-kvstest"), []byte(script), 0o755); err != nil {
		t.Fatal(err)
	}
	t.Setenv("PATH", dir+string(os.PathListSeparator)+os.Getenv("PATH"))
	writeDockerConfig(t, map[string]any{"credHelpers": map[string]string{"ghcr.io": "kvstest"}})
	f, c := newFakeEngine(t)
	pullsAs(f, "ghcr.io/kvs/service@"+digestA)
	errs := make(chan error, 8)
	for n := 0; n < 8; n++ {
		go func() {
			errs <- c.Pull(context.Background(), "ghcr.io/kvs/service:26.10."+strconv.Itoa(n), digestA, 0, nil)
		}()
	}
	for n := 0; n < 8; n++ {
		if err := <-errs; err != nil {
			t.Fatal(err)
		}
	}
	asked, err := os.ReadFile(log)
	if err != nil {
		t.Fatal(err)
	}
	if got := strings.Split(strings.TrimSpace(string(asked)), "\n"); len(got) != 1 || got[0] != "ghcr.io" {
		t.Errorf("the helper was asked %d times (%q), want once for ghcr.io", len(got), got)
	}
	for _, pull := range f.pullRequests() {
		if pull.auth == nil || pull.auth.Username != "helper-user" {
			t.Errorf("the pull of %s sent %+v", pull.fromImage, pull.auth)
		}
	}
}

// The default store serves Docker Hub under its index URL, and a helper
// that keeps an identity token hands it over as one.
func TestPullAsksTheDefaultStoreForDockerHub(t *testing.T) {
	asked := fakeHelper(t, "kvsstore", `{"ServerURL":"x","Username":"<token>","Secret":"aaaa"}`, false)
	writeDockerConfig(t, map[string]any{"credsStore": "kvsstore"})
	f, c := newFakeEngine(t)
	pullsAs(f, "mariadb@"+digestA)
	if err := c.Pull(context.Background(), "mariadb:11.8.9", digestA, 0, nil); err != nil {
		t.Fatal(err)
	}
	got := f.pullRequests()[0].auth
	if got == nil || got.IdentityToken != "aaaa" || got.Username != "" || got.ServerAddress != dockerHub {
		t.Errorf("sent %+v, want the identity token for Docker Hub", got)
	}
	if server, _ := os.ReadFile(asked); string(server) != dockerHub {
		t.Errorf("the store was asked for %q, want %s", server, dockerHub)
	}
}

// A helper that fails, or has nothing for the registry, leaves the pull
// anonymous; the failure is named should the pull fail.
func TestPullGoesAnonymousWhenTheHelperFails(t *testing.T) {
	fakeHelper(t, "kvsbroken", "the keyring is locked", true)
	writeDockerConfig(t, map[string]any{"credsStore": "kvsbroken"})
	f, c := newFakeEngine(t)
	pullsAs(f, "mariadb@"+digestA)
	if err := c.Pull(context.Background(), "mariadb:11.8.9", digestA, 0, nil); err != nil {
		t.Fatalf("a broken helper must not stop a pull of a public image: %v", err)
	}
	if f.pullRequests()[0].auth != nil {
		t.Errorf("sent %+v", f.pullRequests()[0].auth)
	}
	f.setPulled(nil)
	err := c.Pull(context.Background(), "mariadb:11.8.10", digestB, 0, nil)
	if err == nil || !strings.Contains(err.Error(), "pulled anonymously, docker-credential-kvsbroken get") || !strings.Contains(err.Error(), "the keyring is locked") {
		t.Errorf("a failed pull must say the helper failed: %v", err)
	}

	fakeHelper(t, "kvsempty", "credentials not found in native keychain", true)
	writeDockerConfig(t, map[string]any{"credsStore": "kvsempty"})
	f, c = newFakeEngine(t)
	if err := c.Pull(context.Background(), "mariadb:11.8.9", digestA, 0, nil); err == nil || strings.Contains(err.Error(), "anonymously") {
		t.Errorf("a store without credentials for the registry is no failure to report: %v", err)
	}
	if f.pullRequests()[0].auth != nil {
		t.Errorf("sent %+v", f.pullRequests()[0].auth)
	}
}

// A helper missing from PATH or a configuration that does not parse is the
// same as no credentials at all.
func TestPullWithAnUnusableConfiguration(t *testing.T) {
	dir := noDockerConfig(t)
	if err := os.WriteFile(filepath.Join(dir, "config.json"), []byte("{not json"), 0o600); err != nil {
		t.Fatal(err)
	}
	f, c := newFakeEngine(t)
	pullsAs(f, "mariadb@"+digestA)
	if err := c.Pull(context.Background(), "mariadb:11.8.9", digestA, 0, nil); err != nil {
		t.Fatal(err)
	}
	writeDockerConfig(t, map[string]any{"credHelpers": map[string]string{"ghcr.io": "kvs-not-installed"}})
	f, c = newFakeEngine(t)
	pullsAs(f, "ghcr.io/kvs/php@"+digestA)
	if err := c.Pull(context.Background(), "ghcr.io/kvs/php:8.3", digestA, 0, nil); err != nil {
		t.Fatal(err)
	}
	if f.pullRequests()[0].auth != nil {
		t.Errorf("sent %+v", f.pullRequests()[0].auth)
	}
}

// An auths entry of config.json written as username and password, which
// the Docker CLI reads, is used too; an entry that holds nothing says so in
// the message of a pull that fails.
func TestPullSendsTheUsernameAndPasswordOfConfigJSON(t *testing.T) {
	writeDockerConfig(t, map[string]any{"auths": map[string]any{
		"ghcr.io": map[string]string{"username": "kvs", "password": "aaaa"}, // pragma: allowlist secret
		dockerHub: map[string]string{"username": "hub", "password": "bbbb"}, // pragma: allowlist secret
	}})
	for ref, want := range map[string][3]string{
		"ghcr.io/kvs/php:8.3": {"kvs", "aaaa", "ghcr.io"},
		"mariadb:11.8.9":      {"hub", "bbbb", dockerHub},
	} {
		f, c := newFakeEngine(t)
		pullsAs(f, RefName(ref)+"@"+digestA)
		if err := c.Pull(context.Background(), ref, digestA, 0, nil); err != nil {
			t.Fatalf("%s: %v", ref, err)
		}
		got := f.pullRequests()[0].auth
		if got == nil || got.Username != want[0] || got.Password != want[1] || got.ServerAddress != want[2] { // pragma: allowlist secret
			t.Errorf("%s sent %+v, want %v", ref, got, want)
		}
	}
	writeDockerConfig(t, map[string]any{"auths": map[string]any{"ghcr.io": map[string]string{}}})
	_, c := newFakeEngine(t)
	err := c.Pull(context.Background(), "ghcr.io/kvs/php:8.3", digestA, 0, nil)
	if err == nil || !strings.Contains(err.Error(), "pulled anonymously, the ghcr.io entry of") || !strings.Contains(err.Error(), "holds no credentials") {
		t.Errorf("a failed pull with an empty entry: %v", err)
	}
}
