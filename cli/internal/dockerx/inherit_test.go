package dockerx

import (
	"context"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

// Every docker child inherits the files Inherit names, until they are
// forgotten.
func TestDockerChildrenInheritTheHeldFiles(t *testing.T) {
	log := installFakeDocker(t, "lines")
	held, err := os.Create(filepath.Join(t.TempDir(), "lock"))
	if err != nil {
		t.Fatal(err)
	}
	defer held.Close()
	forget := Inherit(held)
	if _, err := ComposeStarted(context.Background(), t.TempDir(), nil, "ps"); err != nil {
		t.Fatal(err)
	}
	if got := logged(readLog(t, log), "fd3"); got != held.Name() {
		t.Errorf("the docker child holds %q as its fourth descriptor, want %q", got, held.Name())
	}
	forget()
	forget()
	if err := os.Remove(log); err != nil {
		t.Fatal(err)
	}
	if _, err := ComposeStarted(context.Background(), t.TempDir(), nil, "ps"); err != nil {
		t.Fatal(err)
	}
	if got := logged(readLog(t, log), "fd3"); got != "none" {
		t.Errorf("a forgotten file still reached the child: %q", got)
	}
}

// A credential helper is no docker command: it never gets the files Inherit
// names, so an agent it leaves running cannot keep the lock held.
func TestCredentialHelpersDoNotInheritTheHeldFiles(t *testing.T) {
	dir := t.TempDir()
	seen := filepath.Join(dir, "fd3")
	script := "#!/bin/sh\n" +
		"if [ -e /proc/$$/fd/3 ]; then readlink /proc/$$/fd/3 > '" + seen + "'; else echo none > '" + seen + "'; fi\n" +
		"cat >/dev/null\n" +
		`printf '%s' '{"ServerURL":"ghcr.io","Username":"helper-user","Secret":"aaaa"}'` + "\n" // pragma: allowlist secret
	if err := os.WriteFile(filepath.Join(dir, "docker-credential-kvsfd"), []byte(script), 0o755); err != nil {
		t.Fatal(err)
	}
	t.Setenv("PATH", dir+string(os.PathListSeparator)+os.Getenv("PATH"))
	writeDockerConfig(t, map[string]any{"credHelpers": map[string]string{"ghcr.io": "kvsfd"}})
	held, err := os.Create(filepath.Join(t.TempDir(), "lock"))
	if err != nil {
		t.Fatal(err)
	}
	defer held.Close()
	forget := Inherit(held)
	defer forget()
	f, c := newFakeEngine(t)
	pullsAs(f, "ghcr.io/kvs/php@"+digestA)
	if err := c.Pull(context.Background(), "ghcr.io/kvs/php:8.3", digestA, 0, nil); err != nil {
		t.Fatal(err)
	}
	if got := f.pullRequests()[0].auth; got == nil || got.Username != "helper-user" {
		t.Fatalf("the helper was not asked: %+v", got)
	}
	data, err := os.ReadFile(seen)
	if err != nil {
		t.Fatal(err)
	}
	if got := strings.TrimSpace(string(data)); got != "none" {
		t.Errorf("the credential helper holds %q as its fourth descriptor, want none", got)
	}
}
