package main

import (
	"bytes"
	"context"
	"crypto/ed25519"
	"crypto/sha256"
	"encoding/base64"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/MaximeMichaud/KVS-install/cli/internal/instance"
	"github.com/MaximeMichaud/KVS-install/cli/internal/manifest"
)

// fakeBuild is a kvsctl build of a release: a script whose version command
// prints what the build would, published beside its sha256 the way a
// manifest lists it.
func fakeBuild(t *testing.T, script string) manifest.Asset {
	t.Helper()
	path := filepath.Join(t.TempDir(), "kvsctl-linux-amd64")
	data := []byte("#!/bin/sh\n" + script + "\n")
	if err := os.WriteFile(path, data, 0o644); err != nil {
		t.Fatal(err)
	}
	sum := sha256.Sum256(data)
	return manifest.Asset{URL: "file://" + path, SHA256: hex.EncodeToString(sum[:]), Size: int64(len(data))}
}

func readFile(t *testing.T, path string) string {
	t.Helper()
	data, err := os.ReadFile(path)
	if err != nil {
		t.Fatal(err)
	}
	return string(data)
}

// update-cli puts the build of a release in place of the running binary
// once it ran and named that release, and keeps the binary it replaced as
// <path>.previous. A build that does not match its sum, names another
// version, fails or does not answer leaves the binary as it was.
func TestReplaceBinary(t *testing.T) {
	ctx := context.Background()
	self := filepath.Join(t.TempDir(), "kvsctl")
	const running = "#!/bin/sh\necho 'kvsctl 26.10.0 (linux/amd64)'\n"
	if err := os.WriteFile(self, []byte(running), 0o755); err != nil {
		t.Fatal(err)
	}
	build := fakeBuild(t, "echo 'kvsctl 26.11.0 (linux/amd64)'")
	if err := replaceBinary(ctx, self, build, "26.11.0"); err != nil {
		t.Fatal(err)
	}
	if got := readFile(t, self); !strings.Contains(got, "kvsctl 26.11.0") {
		t.Fatalf("the binary was not replaced: %q", got)
	}
	if got := readFile(t, self+".previous"); got != running {
		t.Fatalf("the previous binary is %q", got)
	}
	if info, err := os.Stat(self); err != nil || info.Mode().Perm() != 0o755 {
		t.Fatalf("the new binary: %v, %v", info.Mode(), err)
	}
	if _, err := os.Stat(self + ".new"); !os.IsNotExist(err) {
		t.Fatalf("the download was left behind: %v", err)
	}

	old := versionTimeout
	versionTimeout = 300 * time.Millisecond
	t.Cleanup(func() { versionTimeout = old })
	wrongSum := fakeBuild(t, "echo 'kvsctl 26.12.0 (linux/amd64)'")
	wrongSum.SHA256 = strings.Repeat("a", 64)
	oversized := fakeBuild(t, "echo 'kvsctl 26.12.0 (linux/amd64)'")
	oversized.Size = 10
	for _, c := range []struct {
		name  string
		build manifest.Asset
		want  string
	}{
		{"another version", fakeBuild(t, "echo 'kvsctl 26.11.1 (linux/amd64)'"), `says "kvsctl 26.11.1 (linux/amd64)", not kvsctl 26.12.0`},
		{"a wrong sum", wrongSum, "checksum mismatch"},
		{"past its signed size", oversized, "goes past the 10 bytes the signed manifest gives"},
		{"a failure", fakeBuild(t, "echo 'exec format error' >&2; exit 1"), "did not run its version command"},
		{"no answer", fakeBuild(t, "exec sleep 30"), "no answer in 300ms"},
	} {
		err := replaceBinary(ctx, self, c.build, "26.12.0")
		if err == nil || !strings.Contains(err.Error(), c.want) || !strings.Contains(err.Error(), self+" is unchanged") {
			t.Errorf("%s: %v", c.name, err)
		}
		if got := readFile(t, self); !strings.Contains(got, "kvsctl 26.11.0") {
			t.Errorf("%s: the binary changed: %q", c.name, got)
		}
		if got := readFile(t, self+".previous"); got != running {
			t.Errorf("%s: the previous binary changed: %q", c.name, got)
		}
	}
}

// A build that is not a release is always replaced, a release by a newer
// one only.
func TestCLIState(t *testing.T) {
	old := Version
	t.Cleanup(func() { Version = old })
	for _, c := range []struct {
		running, release string
		outdated         bool
	}{
		{"dev", "26.11.0", true},
		{"26.10.0", "26.11.0", true},
		{"26.11.0", "26.11.0", false},
		{"26.12.0", "26.11.0", false},
	} {
		Version = c.running
		if _, outdated := cliState(c.release); outdated != c.outdated {
			t.Errorf("%s against %s: outdated %v", c.running, c.release, outdated)
		}
	}
}

// The build of this platform is the one a release ships for it; a release
// without one says what it ships.
func TestCLIAsset(t *testing.T) {
	rel := &manifest.Release{Version: "26.11.0", CLI: map[string]manifest.Asset{cliPlatform(): {URL: "https://example.com/kvsctl"}}}
	if asset, err := cliAsset(rel); err != nil || asset.URL != "https://example.com/kvsctl" {
		t.Fatalf("%+v, %v", asset, err)
	}
	rel.CLI = map[string]manifest.Asset{"plan9-mips": {}}
	if _, err := cliAsset(rel); err == nil || !strings.Contains(err.Error(), "ships kvsctl for plan9-mips only") {
		t.Fatalf("another platform: %v", err)
	}
	rel.CLI = nil
	if _, err := cliAsset(rel); err == nil || !strings.Contains(err.Error(), "ships no kvsctl build") {
		t.Fatalf("no build: %v", err)
	}
}

// The default manifest of kvsctl is the one the manifest package judges
// the channel of: the URL that serves the stable releases alone.
func TestDefaultManifestURL(t *testing.T) {
	if DefaultManifestURL != manifest.DefaultURL {
		t.Errorf("kvsctl reads %s by default, the manifest package knows %s as the default", DefaultManifestURL, manifest.DefaultURL)
	}
}

// update-cli installs the build of the latest stable release, or of the
// release named, a release candidate included.
func TestCLIRelease(t *testing.T) {
	m := &manifest.Manifest{Releases: []manifest.Release{{Version: "26.11.0-rc1"}, {Version: "26.10.1"}, {Version: "26.10.0"}}}
	for _, c := range []struct{ asked, want, err string }{
		{"", "26.10.1", ""},
		{"26.11.0-rc1", "26.11.0-rc1", ""},
		{"26.10.0", "26.10.0", ""},
		{"26.9.0", "", "version 26.9.0 is not in the manifest"},
	} {
		rel, err := cliRelease(m, c.asked)
		switch {
		case c.err != "" && (err == nil || err.Error() != c.err):
			t.Errorf("%q: %v, want %q", c.asked, err, c.err)
		case c.err == "" && (err != nil || rel.Version != c.want):
			t.Errorf("%q: %+v, %v; want %s", c.asked, rel, err, c.want)
		}
	}
	m.Releases = m.Releases[:1]
	if _, err := cliRelease(m, ""); err == nil || err.Error() != "the manifest lists release candidates only (26.11.0-rc1 is the newest): name the one whose kvsctl to install with --version" {
		t.Errorf("candidates only: %v", err)
	}
}

// pointAtSignedRaw writes raw as a manifest signed by priv and points kvsctl
// at it for the rest of the test.
func pointAtSignedRaw(t *testing.T, raw string, priv ed25519.PrivateKey) {
	t.Helper()
	path := filepath.Join(t.TempDir(), "manifest.json")
	pub := priv.Public().(ed25519.PublicKey)
	sig, err := json.Marshal([]manifest.Signature{{KeyID: manifest.KeyID(pub), Alg: manifest.AlgEd25519, Sig: base64.StdEncoding.EncodeToString(ed25519.Sign(priv, []byte(raw)))}})
	if err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(path, []byte(raw), 0o644); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(path+".sig", sig, 0o644); err != nil {
		t.Fatal(err)
	}
	old := flagManifest
	flagManifest = "file://" + path
	t.Cleanup(func() { flagManifest = old })
}

// update-cli trusts a manifest on the keys of kvsctl alone, reads it
// whatever its schema, and takes the manifest of a release candidate from
// a URL the operator names; a channel it does not know is refused.
func TestCLIManifest(t *testing.T) {
	useStderr(t)
	pub, priv, err := ed25519.GenerateKey(nil)
	if err != nil {
		t.Fatal(err)
	}
	t.Setenv(releaseKeyEnv, base64.StdEncoding.EncodeToString(pub))
	const later = `{"schema":3,"channel":"%s","updated":"2027-03-01T08:00:00Z","releases":[{"version":"27.4.0-rc1","cli":{"linux-amd64":{"url":"https://example.com/b","sha256":"00"}},"images":"elsewhere"},{"version":"27.3.0"}]}`
	pointAtSignedRaw(t, fmt.Sprintf(later, "candidate"), priv)
	m, err := cliManifest(context.Background())
	if err != nil {
		t.Fatal(err)
	}
	if rel, err := cliRelease(m, ""); err != nil || rel.Version != "27.3.0" {
		t.Errorf("default release %+v, %v", rel, err)
	}
	pointAtSignedRaw(t, fmt.Sprintf(later, "nightly"), priv)
	if _, err := cliManifest(context.Background()); err == nil || !strings.Contains(err.Error(), `is of channel "nightly"`) {
		t.Errorf("an unknown channel: %v", err)
	}
	_, stranger, err := ed25519.GenerateKey(nil)
	if err != nil {
		t.Fatal(err)
	}
	pointAtSignedRaw(t, fmt.Sprintf(later, "stable"), stranger)
	if _, err := cliManifest(context.Background()); err == nil || !strings.Contains(err.Error(), "manifest signature does not match any release key this kvsctl knows") {
		t.Errorf("a manifest signed by another key: %v", err)
	}
}

// update-cli reads the manifest for as long as its context lasts, so the
// Ctrl-C of the operator ends a read the server never answers.
// manifest.Fetch would end at the signal alone, never with the context.
func TestCLIManifestEndsWithItsContext(t *testing.T) {
	useStderr(t)
	t.Setenv(releaseKeyEnv, "")
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
	old := flagManifest
	flagManifest = server.URL + "/manifest.json"
	t.Cleanup(func() { flagManifest = old })
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	done := make(chan error, 1)
	go func() {
		_, err := cliManifest(ctx)
		done <- err
	}()
	select {
	case <-asked:
	case err := <-done:
		t.Fatalf("update-cli ended (%v) before it read the manifest", err)
	case <-time.After(10 * time.Second):
		t.Fatal("update-cli did not read the manifest")
	}
	cancel()
	select {
	case err := <-done:
		if !errors.Is(err, context.Canceled) {
			t.Errorf("update-cli ended with %v, want the end of its context", err)
		}
	case <-time.After(5 * time.Second):
		t.Fatal("update-cli still reads the manifest 5 seconds after its context ended")
	}
}

// The keys a manifest announces that this build does not carry are named
// with the day they sign from; the ones it carries are not.
func TestPrintAnnouncedKeys(t *testing.T) {
	useStderr(t)
	pub, _, err := ed25519.GenerateKey(nil)
	if err != nil {
		t.Fatal(err)
	}
	t.Setenv(releaseKeyEnv, base64.StdEncoding.EncodeToString(pub))
	var out bytes.Buffer
	printAnnouncedKeys(&out, []instance.AnnouncedKey{{ID: manifest.KeyID(pub), ValidFrom: "2026-11-01"}, {ID: "r9", ValidFrom: "2026-12-01"}, {ID: "r8"}})
	want := "Signing key  the manifest announces signing key r9 from 2026-12-01, unknown to this kvsctl: run 'kvsctl update-cli' before then\n" +
		"Signing key  the manifest announces signing key r8, unknown to this kvsctl: run 'kvsctl update-cli' before then\n"
	if out.String() != want {
		t.Errorf("printed %q, want %q", out.String(), want)
	}
}
