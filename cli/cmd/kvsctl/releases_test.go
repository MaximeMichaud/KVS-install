package main

import (
	"crypto/ed25519"
	"encoding/base64"
	"encoding/json"
	"strings"
	"testing"

	"github.com/MaximeMichaud/KVS-install/cli/internal/manifest"
)

func TestReleaseLines(t *testing.T) {
	m := &manifest.Manifest{Releases: []manifest.Release{
		{Version: "0.3.0", Date: "2026-09-20", Database: "migrates", Requires: manifest.Requires{PHP: "8.3", MinFrom: "0.2.0"}, Notes: "nginx 1.29"},
		{Version: "0.2.0", Date: "2026-09-12", Requires: manifest.Requires{PHP: "8.1"}},
	}}
	lines := releaseLines(m, "0.2.0")
	if len(lines) != 3 {
		t.Fatalf("lines are %v", lines)
	}
	if !strings.HasPrefix(lines[0], "  VERSION") {
		t.Fatalf("the titles do not come first: %q", lines[0])
	}
	if !strings.HasPrefix(lines[1], "  0.3.0") {
		t.Fatalf("the newest release is marked as installed: %q", lines[1])
	}
	for _, want := range []string{"2026-09-20", "8.3", "0.2.0", "migrates", "latest, nginx 1.29"} {
		if !strings.Contains(lines[1], want) {
			t.Fatalf("line %q lacks %q", lines[1], want)
		}
	}
	if !strings.HasPrefix(lines[2], "* 0.2.0") {
		t.Fatalf("the installed release is not marked: %q", lines[2])
	}
	if !strings.Contains(lines[2], " - ") {
		t.Fatalf("an unset field is not a dash: %q", lines[2])
	}
}

// columns reads the cells of line under the titles of header.
func columns(header, line string) []string {
	cells := make([]string, 0, len(releaseColumns))
	for j, title := range releaseColumns {
		from, to := strings.Index(header, title), len(line)
		if j+1 < len(releaseColumns) {
			to = strings.Index(header, releaseColumns[j+1])
		}
		cell := ""
		if from < len(line) {
			cell = strings.TrimSpace(line[from:min(to, len(line))])
		}
		cells = append(cells, cell)
	}
	return cells
}

// The columns line up with their titles whatever form the date takes and
// however wide a version or the PHP series of a release are. A release is
// dated by the time of its commit, which the table shows as its day in
// UTC. The latest release is the latest stable one, which upgrade installs
// when no version is named, not a release candidate newer than it.
func TestReleaseLinesLineUpWithTheHeader(t *testing.T) {
	m := &manifest.Manifest{Releases: []manifest.Release{
		{Version: "26.11.0-rc1", Date: "2026-10-05T18:39:32Z", Database: "migrates", Requires: manifest.Requires{PHP: "8.1", PHPSeries: []string{"8.4", "8.1", "8.3", "8.2"}, MinFrom: "26.10.0"}, Notes: "nginx 1.29"},
		{Version: "26.10.1", Date: "2026-10-02T23:30:00-02:00", Requires: manifest.Requires{PHP: "8.1"}},
		{Version: "26.10.0", Date: "2026-10-01", Requires: manifest.Requires{PHP: "8.1"}},
	}}
	want := [][]string{
		{"26.11.0-rc1", "2026-10-05", "8.1,8.2,8.3,8.4", "26.10.0", "migrates", "release candidate, nginx 1.29"},
		{"26.10.1", "2026-10-03", "8.1", "-", "-", "latest"},
		{"26.10.0", "2026-10-01", "8.1", "-", "-", ""},
	}
	lines := releaseLines(m, "")
	if len(lines) != len(want)+1 {
		t.Fatalf("lines are %v", lines)
	}
	header := lines[0]
	for i, line := range lines[1:] {
		if got := columns(header, line); strings.Join(got, "|") != strings.Join(want[i], "|") {
			t.Errorf("%s reads %q under the titles, want %q:\n%s\n%s", m.Releases[i].Version, got, want[i], header, line)
		}
	}
}

// The PHP column lists every series a release publishes, not the lowest
// one alone, which reads as the only one: from the images it varies by,
// else from its requirements, else the single PHP it ships.
func TestReleaseLinesListEveryPHPSeries(t *testing.T) {
	image := []manifest.Image{{Service: "php-fpm", Ref: "example/php", Digest: "sha256:0"}}
	m := &manifest.Manifest{Releases: []manifest.Release{
		{Version: "1.2.0", Date: "2026-10-03", Requires: manifest.Requires{PHP: "7.4"}, Variants: map[string]map[string][]manifest.Image{manifest.VariantPHP: {"8.3": image, "7.4": image, "8.1": image}}},
		{Version: "1.1.0", Date: "2026-10-02", Requires: manifest.Requires{PHP: "8.1", PHPSeries: []string{"8.10", "8.1", "8.4"}}},
		{Version: "1.0.0", Date: "2026-10-01", Requires: manifest.Requires{PHP: "8.1"}},
		{Version: "0.9.0", Date: "2026-09-01"},
	}}
	want := []string{"7.4,8.1,8.3", "8.1,8.4,8.10", "8.1", "-"}
	lines := releaseLines(m, "")
	for i, line := range lines[1:] {
		if got := columns(lines[0], line)[2]; got != want[i] {
			t.Errorf("%s shows PHP %q, want %q:\n%s\n%s", m.Releases[i].Version, got, want[i], lines[0], line)
		}
	}
}

// releases refuses a manifest of a channel kvsctl does not read, as check
// and upgrade refuse it, rather than list releases none of them installs.
func TestReleasesRefusesAChannelItDoesNotRead(t *testing.T) {
	root := t.TempDir()
	useRoot(t, root)
	useStderr(t)
	pub, priv, err := ed25519.GenerateKey(nil)
	if err != nil {
		t.Fatal(err)
	}
	t.Setenv(releaseKeyEnv, base64.StdEncoding.EncodeToString(pub))
	raw, err := json.Marshal(manifest.Manifest{Schema: manifest.Schema, Channel: "beta", Updated: "2026-10-01T08:00:00Z", Releases: []manifest.Release{testRelease("1.1.0", "2026-10-01", "")}})
	if err != nil {
		t.Fatal(err)
	}
	pointAtSignedRaw(t, string(raw), priv)
	out, err := runKvsctl(t, "releases", "--root", root, "--manifest", flagManifest)
	if err == nil || !strings.Contains(err.Error(), `is of channel "beta", which this kvsctl does not read`) || out != "" {
		t.Fatalf("releases of a channel kvsctl does not read: %v, printed %q", err, out)
	}
}
