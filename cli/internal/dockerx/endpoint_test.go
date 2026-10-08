package dockerx

import (
	"context"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

// writeContext writes a docker context to the configuration directory dir
// the way "docker context create" does.
func writeContext(t *testing.T, dir, name string, endpoint map[string]any, tls bool) {
	t.Helper()
	sum := sha256.Sum256([]byte(name))
	id := hex.EncodeToString(sum[:])
	meta := filepath.Join(dir, "contexts", "meta", id)
	if err := os.MkdirAll(meta, 0o755); err != nil {
		t.Fatal(err)
	}
	data, err := json.Marshal(map[string]any{"Name": name, "Metadata": map[string]any{}, "Endpoints": map[string]any{"docker": endpoint}})
	if err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(meta, "meta.json"), data, 0o644); err != nil {
		t.Fatal(err)
	}
	if tls {
		if err := os.MkdirAll(filepath.Join(dir, "contexts", "tls", id, "docker"), 0o700); err != nil {
			t.Fatal(err)
		}
	}
}

// The API client reaches the engine the docker CLI uses: DOCKER_HOST, else
// the context DOCKER_CONTEXT names, else the currentContext of config.json,
// else the default socket; a context kvsctl cannot follow is refused.
func TestNewFollowsTheDockerContext(t *testing.T) {
	f, _ := newFakeEngine(t)
	sock := os.Getenv("DOCKER_HOST")
	dir := noDockerConfig(t)
	writeContext(t, dir, "rootless", map[string]any{"Host": sock, "SkipTLSVerify": false}, false)
	writeContext(t, dir, "remote", map[string]any{"Host": "ssh://root@192.0.2.10"}, false)
	writeContext(t, dir, "secure", map[string]any{"Host": "tcp://192.0.2.10:2376"}, true)
	writeContext(t, dir, "nohost", map[string]any{}, false)
	if err := os.WriteFile(filepath.Join(dir, "config.json"), []byte(`{"currentContext":"rootless"}`), 0o600); err != nil {
		t.Fatal(err)
	}

	// DOCKER_HOST wins over any context.
	t.Setenv("DOCKER_CONTEXT", "remote")
	c, err := New()
	if err != nil || c.Endpoint() != sock {
		t.Fatalf("with DOCKER_HOST: %v, %v", err, c)
	}
	c.Close()
	t.Setenv("DOCKER_HOST", "")

	// The currentContext of config.json, then DOCKER_CONTEXT over it.
	for _, name := range []string{"", "rootless"} {
		t.Setenv("DOCKER_CONTEXT", name)
		c, err := New()
		if err != nil {
			t.Fatalf("context %q: %v", name, err)
		}
		if want := sock + ", from the docker context rootless"; c.Endpoint() != want {
			t.Fatalf("context %q: Endpoint = %q, want %q", name, c.Endpoint(), want)
		}
		before := len(f.apiVersions())
		if _, err := c.Containers(context.Background(), "kvs-example"); err != nil {
			t.Fatalf("context %q: %v", name, err)
		}
		if len(f.apiVersions()) == before {
			t.Errorf("context %q: the request did not reach the engine of the context", name)
		}
		c.Close()
	}

	// The default context is the default socket.
	t.Setenv("DOCKER_CONTEXT", "default")
	c, err = New()
	if err != nil || !strings.HasPrefix(c.Endpoint(), "unix:///var/run/docker.sock") {
		t.Fatalf("the default context: %v, %v", err, c)
	}
	c.Close()

	for name, want := range map[string]string{
		"remote":  `the docker context "remote" (DOCKER_CONTEXT) reaches its engine through ssh, which kvsctl does not do`,
		"secure":  `the docker context "secure" (DOCKER_CONTEXT) reaches its engine over TLS, which kvsctl does not read from a context`,
		"nohost":  `the docker context "nohost" (DOCKER_CONTEXT) names no engine`,
		"missing": `the docker context "missing" (DOCKER_CONTEXT) does not exist`,
	} {
		t.Setenv("DOCKER_CONTEXT", name)
		if _, err := New(); err == nil || !strings.Contains(err.Error(), want) || !strings.Contains(err.Error(), "set DOCKER_HOST") {
			t.Errorf("context %s: %v, want %q", name, err, want)
		}
	}
	t.Setenv("DOCKER_CONTEXT", "")
	if err := os.WriteFile(filepath.Join(dir, "config.json"), []byte(`{"currentContext":"remote"}`), 0o600); err != nil {
		t.Fatal(err)
	}
	if _, err := New(); err == nil || !strings.Contains(err.Error(), `(the currentContext of `+filepath.Join(dir, "config.json")+`)`) {
		t.Errorf("a currentContext kvsctl cannot follow: %v", err)
	}
}
