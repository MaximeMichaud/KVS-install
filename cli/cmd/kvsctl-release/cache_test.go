package main

import (
	"bytes"
	"fmt"
	"path/filepath"
	"strings"
	"testing"

	"github.com/MaximeMichaud/KVS-install/cli/internal/semver"
)

func TestCacheRoutingPreflightMatchesPublisher(t *testing.T) {
	registry := registryStub()
	defer registry.Close()
	run := newManifestRun(t, strings.TrimPrefix(registry.URL, "http://"))
	legacy := filepath.Join(run.dir, "legacy")
	if err := run.sign("26.9.0", legacy); err != nil {
		t.Fatal(err)
	}
	direct := filepath.Join(run.dir, "direct")
	if err := run.sign("26.10.0", direct, "--cache-routing", "direct", "--previous", filepath.Join(legacy, "manifest.json")); err != nil {
		t.Fatal(err)
	}
	later := filepath.Join(run.dir, "later")
	if err := run.sign("26.10.1", later, "--cache-routing", "direct", "--kvsctl-min", "26.10.1", "--previous", filepath.Join(direct, "manifest.json")); err != nil {
		t.Fatal(err)
	}
	candidate := filepath.Join(run.dir, "candidate")
	if err := run.sign("26.10.2-rc1", candidate, "--cache-routing", "direct", "--previous", filepath.Join(later, "manifest.json")); err != nil {
		t.Fatal(err)
	}
	for _, c := range []struct {
		name, version, policy, minimum, previous, want, refusal string
	}{
		{"first-default", "26.11.0", "direct", "", "", "26.11.0", ""},
		{"first-explicit", "26.11.0", "direct", "26.11.0", "", "26.11.0", ""},
		{"legacy-history", "26.11.0", "direct", "", legacy, "26.11.0", ""},
		{"inherited-default", "26.11.0", "direct", "", later, "26.10.0", ""},
		{"inherited-explicit", "26.11.0", "direct", "26.10.0", later, "26.10.0", ""},
		{"higher-minimum", "26.11.0", "direct", "26.11.0", later, "26.11.0", ""},
		{"candidate-default", "26.11.0-rc1", "direct", "", "", "26.11.0-rc1", ""},
		{"candidate-stable-minimum", "26.11.0-rc1", "direct", "26.11.0", "", "26.11.0-rc1", ""},
		{"candidate-inherited", "26.11.0-rc1", "direct", "", later, "26.10.0", ""},
		{"unchanged-default", "26.11.0", "", "", later, "none", ""},
		{"unchanged-explicit", "26.11.0", "", "26.9.0", later, "26.9.0", ""},
		{"first-too-old", "26.11.0", "direct", "26.10.0", "", "", "older than 26.11.0"},
		{"legacy-too-old", "26.11.0", "direct", "26.10.0", legacy, "", "older than 26.11.0"},
		{"inherited-too-old", "26.11.0", "direct", "26.9.0", later, "", "older than 26.10.0"},
		{"candidate-too-old", "26.11.0-rc1", "direct", "26.10.0", "", "", "older than 26.11.0-rc1"},
		{"minimum-too-new", "26.11.0", "direct", "26.12.0", later, "", "newer than the release"},
		{"unknown-policy", "26.11.0", "proxy", "", later, "", "must be empty or direct"},
		{"candidate-history", "26.11.0", "direct", "", candidate, "", `manifest of channel "candidate"`},
	} {
		t.Run(c.name, func(t *testing.T) {
			args := []string{"--cache-routing", c.policy, "--kvsctl-min", c.minimum}
			if c.previous != "" {
				args = append(args, "--previous", filepath.Join(c.previous, "manifest.json"))
			}
			var output bytes.Buffer
			preflightErr := checkCacheRouting(append([]string{"--version", c.version}, args...), &output)
			published := filepath.Join(run.dir, c.name)
			publishErr := run.sign(c.version, published, args...)
			if c.refusal != "" {
				if preflightErr == nil || !strings.Contains(preflightErr.Error(), c.refusal) {
					t.Fatalf("preflight must refuse before images are pushed, saying %q: %v", c.refusal, preflightErr)
				}
				if publishErr == nil || preflightErr.Error() != publishErr.Error() {
					t.Fatalf("preflight and publisher disagree: %v / %v", preflightErr, publishErr)
				}
				if output.Len() != 0 {
					t.Fatalf("a refused preflight printed a minimum: %q", output.String())
				}
				return
			}
			if preflightErr != nil || publishErr != nil {
				t.Fatalf("valid settings refused: preflight %v; publisher %v", preflightErr, publishErr)
			}
			if want := "kvsctl min: " + c.want + "\n"; output.String() != want {
				t.Fatalf("preflight output %q; want %q", output.String(), want)
			}
			minimum := kvsctlMins(t, published)[c.version]
			if minimum == "" {
				minimum = "none"
			}
			if minimum != c.want {
				t.Fatalf("signed minimum %q; preflight promised %q", minimum, c.want)
			}
		})
	}
}

func TestDirectCacheReleaseRequiresItsMigrationCLI(t *testing.T) {
	registry := registryStub()
	defer registry.Close()
	run := newManifestRun(t, strings.TrimPrefix(registry.URL, "http://"))
	first := filepath.Join(run.dir, "first")
	if err := run.sign("26.11.0", first, "--cache-routing", "direct"); err != nil {
		t.Fatal(err)
	}
	if got := kvsctlMins(t, first)["26.11.0"]; got != "26.11.0" {
		t.Fatalf("old binaries could install a release without its migration: %q", got)
	}
	second := filepath.Join(run.dir, "second")
	if err := run.sign("26.12.0", second, "--cache-routing", "direct", "--previous", filepath.Join(first, "manifest.json")); err != nil {
		t.Fatal(err)
	}
	if got := kvsctlMins(t, second)["26.12.0"]; got != "26.11.0" {
		t.Fatalf("the migration minimum was not inherited: %q", got)
	}
	if err := run.sign("26.12.0", second, "--cache-routing", "direct", "--kvsctl-min", "26.10.0"); err == nil {
		t.Fatal("an older CLI could bypass the migration")
	}
	if err := run.sign("26.12.0", second, "--cache-routing", "proxy"); err == nil {
		t.Fatal("unknown cache routing was signed")
	}
}

// The version of a release is written as given into docker/RELEASE, the
// override and the manifest, where semver.Parse reads a leading v and
// blanks around it too: every command that takes --version refuses any
// spelling but the one Version.String prints, before it reads anything
// else, so that a release never gets a second spelling in a manifest.
func TestReleaseVersionHasOneSpelling(t *testing.T) {
	dir := t.TempDir()
	for _, version := range []string{"v26.11.0", " 26.11.0", "26.11.0 ", "v26.11.0-rc1", "\t26.11.0-rc1"} {
		v, err := semver.Parse(version)
		if err != nil {
			t.Fatal(err)
		}
		want := fmt.Sprintf("--version %q is written %s: ", version, v)
		var out bytes.Buffer
		for name, err := range map[string]error{
			"bundle": bundle([]string{"--version", version, "--out", filepath.Join(dir, "b.tar.gz"), "--repo", filepath.Join(dir, "none")}),
			"manifest": manifestCmd([]string{"--key", filepath.Join(dir, "none.key"), "--out", dir, "--version", version,
				"--bundle-url", "file:///nowhere/b.tar.gz", "--bundle", filepath.Join(dir, "none.tar.gz")}),
			"check-cache-routing": checkCacheRouting([]string{"--version", version}, &out),
		} {
			if err == nil || !strings.HasPrefix(err.Error(), want) {
				t.Errorf("%s --version %q: %v, want it refused saying %q", name, version, err, want)
			}
		}
		if out.Len() != 0 {
			t.Errorf("check-cache-routing --version %q printed %q", version, out.String())
		}
	}
	for _, version := range []string{"26.11.0", "26.11.0-rc1"} {
		var out bytes.Buffer
		if err := checkCacheRouting([]string{"--version", version}, &out); err != nil || out.String() != "kvsctl min: none\n" {
			t.Errorf("check-cache-routing --version %s: %q, %v", version, out.String(), err)
		}
	}
}
