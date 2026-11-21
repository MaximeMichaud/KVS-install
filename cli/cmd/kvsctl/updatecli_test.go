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
	"os/exec"
	"path/filepath"
	"strconv"
	"strings"
	"syscall"
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

	t.Run("cancellation during the version check", func(t *testing.T) {
		current := readFile(t, self)
		marker := filepath.Join(t.TempDir(), "checking")
		t.Setenv("KVSCTL_TEST_VERSION_MARKER", marker)
		build := fakeBuild(t, "printf ready > \"$KVSCTL_TEST_VERSION_MARKER\"\nexec sleep 30")
		ctx, cancel := context.WithCancel(context.Background())
		done := make(chan error, 1)
		stopped := make(chan struct{})
		go func() {
			defer close(stopped)
			done <- replaceBinary(ctx, self, build, "26.12.0")
		}()
		t.Cleanup(func() {
			cancel()
			<-stopped
		})
		waitFor(t, "candidate version command", func() bool {
			_, err := os.Stat(marker)
			return err == nil
		})
		cancel()
		select {
		case err := <-done:
			if !errors.Is(err, context.Canceled) || !strings.Contains(err.Error(), "interrupted") || strings.Contains(err.Error(), "no answer in") {
				t.Errorf("an operator cancellation was not reported as an interruption: %v", err)
			}
		case <-time.After(5 * time.Second):
			t.Fatal("the candidate version command did not stop after cancellation")
		}
		if got := readFile(t, self); got != current {
			t.Errorf("cancellation changed the current binary: %q", got)
		}
		if got := readFile(t, self+".previous"); got != running {
			t.Errorf("cancellation changed the previous binary: %q", got)
		}
		if _, err := os.Stat(self + ".new"); !os.IsNotExist(err) {
			t.Errorf("cancellation left the downloaded candidate behind: %v", err)
		}
	})

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

func TestUpdateCLIRefusesExplicitDowngrade(t *testing.T) {
	rel := testRelease("1.2.0", "2026-09-01", "")
	rel.CLI = map[string]manifest.Asset{cliPlatform(): fakeBuild(t, "exit 1")}
	useFlags(t, t.TempDir(), signedManifest(t, rel), false)
	old := Version
	t.Cleanup(func() { Version = old })
	for _, tc := range []struct {
		current, target string
		refuse          bool
	}{
		{"1.3.0", "1.2.0", true},
		{"1.3.0", "", false},
		{"1.2.0", "1.2.0", false},
		{"v1.2.0", "1.2.0", false},
	} {
		Version = tc.current
		if tc.current == "v1.2.0" {
			msg, outdated := cliState("1.2.0")
			if outdated || !strings.Contains(msg, "is the build of release 1.2.0") {
				t.Errorf("equal versions: %s", msg)
			}
		}
		cmd := updateCLICmd()
		if err := cmd.Flags().Set("version", tc.target); err != nil {
			t.Fatal(err)
		}
		err := cmd.RunE(cmd, nil)
		if tc.refuse {
			if err == nil || !strings.Contains(err.Error(), "refusing to downgrade kvsctl from 1.3.0 to 1.2.0") {
				t.Errorf("explicit downgrade: %v", err)
			}
		} else if err != nil {
			t.Errorf("current %s, target %q: %v", tc.current, tc.target, err)
		}
	}
}

func TestUpdateCLIUsesStateWithBrokenEnv(t *testing.T) {
	root := newRoot(t)
	t.Setenv("KVS_INSTALL_DIR", root)
	inst := saveState(t, root, failedState())
	rel := testRelease("1.0.0", "2026-10-01", "")
	rel.CLI = map[string]manifest.Asset{cliPlatform(): fakeBuild(t, "exit 1")}
	url := signedManifest(t, rel)
	useFlags(t, "", url, false)
	old := Version
	Version = rel.Version
	t.Cleanup(func() { Version = old })
	updates := &instance.Updates{}
	updates.For(url).LatestSeen = "2.0.0"
	if err := inst.SaveUpdates(updates); err != nil {
		t.Fatal(err)
	}
	interruptedJournal(t, root)
	if err := os.WriteFile(inst.EnvPath, []byte("DOMAIN=\"unfinished\n"), 0o600); err != nil {
		t.Fatal(err)
	}
	cmd := updateCLICmd()
	if err := cmd.RunE(cmd, nil); err == nil || !strings.Contains(err.Error(), "recover") {
		t.Errorf("journal with broken .env: %v", err)
	}
	if err := inst.RemoveJournal(); err != nil {
		t.Fatal(err)
	}
	if err := os.Remove(inst.EnvPath); err != nil {
		t.Fatal(err)
	}
	if err := cmd.RunE(cmd, nil); err == nil || !strings.Contains(err.Error(), "latest 2.0.0") {
		t.Errorf("manifest floor with missing .env: %v", err)
	}
	compose := filepath.Join(root, "docker", "docker-compose.yml")
	if err := os.Remove(compose); err != nil {
		t.Fatal(err)
	}
	if err := os.Symlink("missing.yml", compose); err != nil {
		t.Fatal(err)
	}
	if err := cmd.RunE(cmd, nil); !errors.Is(err, os.ErrNotExist) {
		t.Errorf("dangling compose link: %v", err)
	}
	flagRoot = t.TempDir()
	docker := filepath.Join(flagRoot, "docker")
	if err := os.Symlink("missing", docker); err != nil {
		t.Fatal(err)
	}
	if err := cmd.RunE(cmd, nil); !errors.Is(err, os.ErrNotExist) || errors.Is(err, instance.ErrNoStack) {
		t.Errorf("dangling parent link: %v", err)
	}
	if err := os.Mkdir(filepath.Join(flagRoot, "missing"), 0o700); err != nil {
		t.Fatal(err)
	}
	if err := cmd.RunE(cmd, nil); err != nil {
		t.Errorf("absent file below a valid directory link: %v", err)
	}
	if err := os.Symlink(".", filepath.Join(docker, "docker-compose.yml")); err != nil {
		t.Fatal(err)
	}
	if err := cmd.RunE(cmd, nil); err == nil || !strings.Contains(err.Error(), "not a regular file") {
		t.Errorf("compose resolves to directory: %v", err)
	}
	compose = filepath.Join(docker, "docker-compose.yml")
	if err := os.Remove(compose); err != nil {
		t.Fatal(err)
	}
	if err := os.Mkdir(compose, 0o700); err != nil {
		t.Fatal(err)
	}
	if err := cmd.RunE(cmd, nil); err == nil || !strings.Contains(err.Error(), "not a regular file") {
		t.Errorf("directory at compose path: %v", err)
	}
	flagRoot = filepath.Join(t.TempDir(), "empty")
	if err := cmd.RunE(cmd, nil); err != nil {
		t.Errorf("without a stack: %v", err)
	}
	if err := os.WriteFile(flagRoot, nil, 0o600); err != nil {
		t.Fatal(err)
	}
	if err := cmd.RunE(cmd, nil); err == nil || !errors.Is(err, syscall.ENOTDIR) {
		t.Errorf("unusable root: %v", err)
	}
}

// documentedInstallKey finds the independently authenticated key the example
// uses among the release build's keys, including during a rotation.
func documentedInstallKey(t *testing.T, script, specs string) string {
	t.Helper()
	keys, err := manifest.ParseKeys(strings.Split(specs, ","))
	if err != nil {
		t.Fatal(err)
	}
	for _, key := range keys {
		encoded := base64.StdEncoding.EncodeToString(key)
		if strings.Contains(script, "\nkey = "+strconv.Quote(encoded)+" ") {
			return encoded
		}
	}
	t.Fatal("the documented key is absent from the embedded release keys")
	return ""
}

func TestDocumentedFirstInstall(t *testing.T) {
	readme := readFile(t, "../../README.md")
	_, section, ok := strings.Cut(readme, "## Installing kvsctl\n")
	if !ok {
		t.Fatal("missing installation instructions")
	}
	section, _, _ = strings.Cut(section, "\n## ")
	_, block, ok := strings.Cut(section, "```sh\n")
	script, _, end := strings.Cut(block, "```")
	if !ok || !end {
		t.Fatal("missing installation commands")
	}

	const invocation = "sh kvsctl-install.sh"
	if !strings.Contains(section, "`"+invocation+"`") || !strings.HasPrefix(script, "#!/bin/sh\n") {
		t.Fatal("missing instructions to save and invoke the script with sh")
	}
	callers := map[string]string{"sh": "sh"}
	for _, shell := range []string{"bash", "zsh", "fish"} {
		if exe, err := exec.LookPath(shell); err == nil {
			callers[shell] = exe
		}
	}
	realInstall, err := exec.LookPath("install")
	if err != nil {
		t.Fatal(err)
	}
	// The documented block has only the utilities available to a fresh server.
	tools := t.TempDir()
	for _, name := range []string{"sh", "mktemp", "rm", "cp", "python3", "openssl", "sha256sum", "chmod", "cat", "timeout", "mv"} {
		exe, err := exec.LookPath(name)
		if err != nil {
			t.Fatal(err)
		}
		if err := os.Symlink(exe, filepath.Join(tools, name)); err != nil {
			t.Fatal(err)
		}
	}
	// Limit only the final copy, after the signature and version checks.
	wrapper := `#!/usr/bin/env python3
import os, resource, signal, sys
with open(os.environ["KVSCTL_COPY_LOG"], "w") as log:
    print(os.path.abspath(sys.argv[-1]), file=log)
if os.environ.get("KVSCTL_LIMIT_INSTALL") == "1":
    signal.signal(signal.SIGXFSZ, signal.SIG_IGN)
    resource.setrlimit(resource.RLIMIT_FSIZE, (40, 40))
os.execv(os.environ["KVSCTL_REAL_INSTALL"], sys.argv)
`
	if err := os.WriteFile(filepath.Join(tools, "install"), []byte(wrapper), 0755); err != nil {
		t.Fatal(err)
	}
	t.Setenv("KVSCTL_REAL_INSTALL", realInstall)
	t.Setenv("PATH", tools)
	t.Setenv("TMPDIR", t.TempDir())
	rel := testRelease("1.2.0", "2026-10-01", "")
	build := fakeBuild(t, "echo 'kvsctl 1.2.0 (linux/amd64)'")
	binary := strings.TrimPrefix(build.URL, "file://")
	original := readFile(t, binary)
	build.URL = "https://downloads.example.invalid/kvsctl-linux-amd64"
	rel.CLI = map[string]manifest.Asset{"linux-amd64": build}
	url := signedManifest(t, rel)
	documented := documentedInstallKey(t, script, ReleasePublicKey)
	newKey := func() (string, ed25519.PrivateKey) {
		t.Helper()
		pub, priv, err := ed25519.GenerateKey(nil)
		if err != nil {
			t.Fatal(err)
		}
		return base64.StdEncoding.EncodeToString(pub), priv
	}
	oldKey, oldPrivate := newKey()
	nextKey, nextPrivate := newKey()
	// Keep this check active between rotations, in either key order.
	for _, specs := range []string{ReleasePublicKey + "," + nextKey, nextKey + "," + ReleasePublicKey} {
		if got := documentedInstallKey(t, script, specs); got != documented {
			t.Fatalf("documented key changed during rotation: %s", got)
		}
	}
	if strings.Count(script, "/usr/local/bin/kvsctl") != 1 {
		t.Fatal("expected one install destination")
	}
	script = strings.Replace(script, "/usr/local/bin/kvsctl", `"$KVSCTL_TEST_INSTALL"`, 1)
	manifestPath := strings.TrimPrefix(url, "file://")
	raw := readFile(t, manifestPath)
	untrusted := readFile(t, manifestPath+".sig") // signed by the unrelated lab key
	sign := func(private ed25519.PrivateKey, body string) string {
		t.Helper()
		data, err := json.Marshal(manifest.Signature{Alg: manifest.AlgEd25519, Sig: base64.StdEncoding.EncodeToString(ed25519.Sign(private, []byte(body)))})
		if err != nil {
			t.Fatal(err)
		}
		return string(data)
	}
	sig := sign(oldPrivate, raw)
	rotation := "[" + sig + "," + sign(nextPrivate, raw) + "]"
	candidate := strings.Replace(raw, `"channel":"stable"`, `"channel":"candidate"`, 1)
	wrongVersion := strings.Replace(raw, `"version":"1.2.0"`, `"version":"2.0.0"`, 1)
	for _, tc := range []struct{ name, key, signature, manifest, asset, wantError string }{
		{"write error", oldKey, sig, raw, original, "File too large"},
		{"single signature", oldKey, sig, raw, original, ""},
		{"rotation old key", oldKey, rotation, raw, original, ""},
		{"rotation new key", nextKey, rotation, raw, original, ""},
		{"wrong version", oldKey, sign(oldPrivate, wrongVersion), wrongVersion, original, "unexpected binary version"},
		{"candidate list", oldKey, sign(oldPrivate, candidate), candidate, original, "expected a stable release"},
		{"untrusted signer", oldKey, untrusted, raw, original, "signature verification failed"},
		{"changed manifest", oldKey, sig, raw + "\n", original, "signature verification failed"},
		{"changed binary", oldKey, sig, raw, original + ": > \"$KVSCTL_TEST_PROBE\"\n", "FAILED"},
	} {
		block := strings.Replace(script, documented, tc.key, 1)
		for shell, exe := range callers {
			contexts := map[string]string{"standalone": invocation}
			if shell != "fish" {
				contexts["if"] = "if " + invocation + "; then exit 0; else exit 1; fi"
				contexts["or"] = invocation + " || exit 1"
			}
			for context, command := range contexts {
				t.Run(tc.name+"/"+shell+"/"+context, func(t *testing.T) {
					dir := t.TempDir()
					destination := filepath.Join(dir, "installed")
					copyLog := filepath.Join(dir, "install-target")
					t.Setenv("KVSCTL_COPY_LOG", copyLog)
					t.Setenv("KVSCTL_TEST_INSTALL", destination)
					if tc.name == "write error" {
						t.Setenv("KVSCTL_LIMIT_INSTALL", "1")
						t.Setenv("LC_ALL", "C")
					}
					if err := os.WriteFile(filepath.Join(dir, "kvsctl-install.sh"), []byte(block), 0600); err != nil {
						t.Fatal(err)
					}
					probe := filepath.Join(dir, "probe-ran")
					t.Setenv("KVSCTL_TEST_PROBE", probe)
					if err := os.WriteFile(destination, []byte("previous install"), 0o755); err != nil {
						t.Fatal(err)
					}
					for name, data := range map[string]string{
						"manifest.json": tc.manifest, "manifest.json.sig": tc.signature, "kvsctl-linux-amd64": tc.asset,
						"SHA256SUMS": fmt.Sprintf("%x  kvsctl-linux-amd64\n", sha256.Sum256([]byte(tc.asset))),
					} {
						if err := os.WriteFile(filepath.Join(dir, name), []byte(data), 0o600); err != nil {
							t.Fatal(err)
						}
					}
					cmd := exec.Command(exe, "-c", command)
					cmd.Dir = dir
					out, err := cmd.CombinedOutput()
					if tc.wantError == "" || tc.name == "write error" {
						copied := strings.TrimSuffix(readFile(t, copyLog), "\n")
						if copied == destination || filepath.Dir(copied) != filepath.Dir(destination) {
							t.Errorf("copy went to %q, want a temporary beside %q", copied, destination)
						}
					}
					leftovers, globErr := filepath.Glob(filepath.Join(dir, ".kvsctl.*"))
					if globErr != nil || len(leftovers) != 0 {
						t.Fatalf("temporary files: %v, %v", leftovers, globErr)
					}
					if tc.wantError == "" {
						if err != nil || readFile(t, destination) != original {
							t.Fatalf("valid install: %v, %s", err, out)
						}
						return
					}
					if err == nil || !strings.Contains(string(out), tc.wantError) {
						t.Errorf("expected %q: %v, %s", tc.wantError, err, out)
					}
					if got := readFile(t, destination); got != "previous install" {
						t.Error("destination changed after failed verification")
					}
					if _, err := os.Stat(probe); !os.IsNotExist(err) {
						t.Errorf("unverified asset ran: %v", err)
					}
				})
			}
		}
	}
}
