package upgrade

import (
	"errors"
	"slices"
	"strings"
	"testing"
	"time"

	"github.com/MaximeMichaud/KVS-install/cli/internal/instance"
	"github.com/MaximeMichaud/KVS-install/cli/internal/manifest"
)

// datedManifest is a stable list dated updated whose newest release is
// latest.
func datedManifest(updated, latest string) *manifest.Manifest {
	return &manifest.Manifest{Channel: manifest.ChannelStable, Updated: updated, Releases: []manifest.Release{{Version: latest}}}
}

// candidateList is the list of a release candidate dated updated, its
// releases newest first.
func candidateList(updated string, versions ...string) *manifest.Manifest {
	m := &manifest.Manifest{Channel: manifest.ChannelCandidate, Updated: updated}
	for _, v := range versions {
		m.Releases = append(m.Releases, manifest.Release{Version: v})
	}
	return m
}

// record is what the instance remembers of url.
func record(t *testing.T, inst *instance.Instance, url string) instance.ManifestCheck {
	t.Helper()
	updates, err := inst.LoadUpdates()
	if err != nil {
		t.Fatal(err)
	}
	return *updates.For(url)
}

// A release candidate list read once through --manifest is newer than the
// stable one in date and in version; the stable list must not look stale
// after it, and a replayed copy of either is still refused.
func TestCheckManifestKeepsOneRecordPerURL(t *testing.T) {
	inst := testInstance(t, "DOMAIN=example.com\n")
	stable, candidate := "https://example.com/stable/manifest.json", "https://example.com/candidate/manifest.json"
	if err := CheckManifest(inst, datedManifest("2026-10-01T00:00:00Z", "26.10.0"), stable, false); err != nil {
		t.Fatal(err)
	}
	if err := CheckManifest(inst, datedManifest("2026-10-05T00:00:00Z", "26.11.0"), candidate, false); err != nil {
		t.Fatal(err)
	}
	if err := CheckManifest(inst, datedManifest("2026-10-02T00:00:00Z", "26.10.1"), stable, false); err != nil {
		t.Fatalf("the stable list was judged against the candidate one: %v", err)
	}
	updates, err := inst.LoadUpdates()
	if err != nil {
		t.Fatal(err)
	}
	if got := updates.For(stable); got.LatestSeen != "26.10.1" || got.ManifestUpdated != "2026-10-02T00:00:00Z" || got.LastCheck.IsZero() {
		t.Errorf("record of the stable list: %+v", got)
	}
	if got := updates.For(candidate); got.LatestSeen != "26.11.0" {
		t.Errorf("record of the candidate list: %+v", got)
	}

	if err := CheckManifest(inst, datedManifest("2026-10-01T00:00:00Z", "26.10.0"), stable, false); !errors.Is(err, ErrStaleManifest) {
		t.Errorf("a replayed copy of the stable list must be refused, got %v", err)
	}
	if err := CheckManifest(inst, datedManifest("2026-10-04T00:00:00Z", "26.11.0"), candidate, false); !errors.Is(err, ErrStaleManifest) {
		t.Errorf("an older copy of the candidate list must be refused, got %v", err)
	}
	if err := CheckManifest(inst, datedManifest("2026-10-01T00:00:00Z", "26.10.0"), stable, true); err != nil {
		t.Errorf("--allow-stale-manifest accepts it: %v", err)
	}
}

// A release candidate in a list is never what the list is judged by: the
// next list, without it or with it gone stable, is not stale for it, and
// the reminder never names it. A list whose newest release is a candidate,
// signed before candidates named their channel, is the list of a candidate.
func TestCheckManifestIgnoresCandidates(t *testing.T) {
	inst := testInstance(t, "DOMAIN=example.com\n")
	url := "https://example.com/manifest.json"
	withCandidate := &manifest.Manifest{Channel: manifest.ChannelStable, Updated: "2026-10-05T00:00:00Z", Releases: []manifest.Release{{Version: "26.11.0-rc1"}, {Version: "26.10.0"}}}
	if err := CheckManifest(inst, withCandidate, url, false); err != nil {
		t.Fatal(err)
	}
	if got := record(t, inst, url); got.LatestSeen != "26.10.0" || got.ManifestUpdated != "" {
		t.Errorf("record %+v, want the latest stable release and no date", got)
	}
	if err := CheckManifest(inst, datedManifest("2026-10-01T00:00:00Z", "26.10.0"), url, false); err != nil {
		t.Errorf("a list without the candidate, signed before it, was judged against it: %v", err)
	}
	candidates := &manifest.Manifest{Channel: manifest.ChannelStable, Updated: "2026-10-07T00:00:00Z", Releases: []manifest.Release{{Version: "26.11.0-rc1"}}}
	if err := CheckManifest(inst, candidates, url, false); err != nil {
		t.Errorf("a list of candidates only: %v", err)
	}
	if got := record(t, inst, url); got.LatestSeen != "26.10.0" || got.ManifestUpdated != "2026-10-01T00:00:00Z" {
		t.Errorf("a list of candidates only changed the record: %+v", got)
	}
}

// The channel is checked before anything is remembered: the list of a
// candidate at the default URL, which serves the stable list alone, is
// refused there and leaves no record that would make the stable list look
// stale when it comes back.
func TestCheckManifestChecksTheChannel(t *testing.T) {
	inst := testInstance(t, "DOMAIN=example.com\n")
	err := CheckManifest(inst, candidateList("2026-10-05T00:00:00Z", "26.11.0-rc1", "26.10.0"), manifest.DefaultURL, false)
	if err == nil || !strings.Contains(err.Error(), "is the one of a release candidate (channel candidate), and that URL serves stable releases only") {
		t.Fatalf("the list of a candidate at the default URL: %v", err)
	}
	stamped := &manifest.Manifest{Channel: manifest.ChannelStable, Updated: "2026-10-05T00:00:00Z", Releases: []manifest.Release{{Version: "26.11.0-rc1"}, {Version: "26.10.0"}}}
	if err := CheckManifest(inst, stamped, manifest.DefaultURL, true); err == nil || !strings.Contains(err.Error(), "names the release candidate 26.11.0-rc1 as its newest release") {
		t.Errorf("a stable list whose newest release is a candidate, with --allow-stale-manifest: %v", err)
	}
	nightly := datedManifest("2026-10-05T00:00:00Z", "26.10.0")
	nightly.Channel = "nightly"
	if err := CheckManifest(inst, nightly, "https://mirror.example.com/manifest.json", false); err == nil || !strings.Contains(err.Error(), `is of channel "nightly"`) {
		t.Errorf("an unknown channel: %v", err)
	}
	if updates, err := inst.LoadUpdates(); err != nil || len(updates.Manifests) != 0 {
		t.Errorf("a refused list was remembered: %+v, %v", updates, err)
	}
	if err := CheckManifest(inst, datedManifest("2026-10-01T00:00:00Z", "26.10.0"), manifest.DefaultURL, false); err != nil {
		t.Errorf("the stable list after them: %v", err)
	}
}

// A URL the operator names may serve the list of a candidate, signed after
// the stable list a mirror serves again later: its date is neither
// compared nor kept, while the stable lists keep theirs. Its latest stable
// release is held to the newest one seen, and may raise it.
func TestCheckManifestLeavesTheDateOfACandidateListOut(t *testing.T) {
	inst := testInstance(t, "DOMAIN=example.com\n")
	url := "https://mirror.example.com/manifest.json"
	stable := datedManifest("2026-10-01T00:00:00Z", "26.10.0")
	for _, step := range []struct {
		what  string
		m     *manifest.Manifest
		stale bool
	}{
		{"the stable list", stable, false},
		{"the list of a candidate, signed before a new signature of that list", candidateList("2026-09-28T00:00:00Z", "26.11.0-rc1", "26.10.0"), false},
		{"the list of a candidate, signed after it", candidateList("2026-10-05T00:00:00Z", "26.11.0-rc1", "26.10.0"), false},
		{"the stable list again", stable, false},
		{"an older stable list", datedManifest("2026-09-30T00:00:00Z", "26.10.0"), true},
		{"the list of an older candidate", candidateList("2026-10-06T00:00:00Z", "26.10.0-rc1", "26.9.0"), true},
		{"the list of a candidate with a newer stable release", candidateList("2026-10-20T00:00:00Z", "26.11.0-rc2", "26.10.1"), false},
		{"the stable list without that release", stable, true},
	} {
		err := CheckManifest(inst, step.m, url, false)
		if step.stale != errors.Is(err, ErrStaleManifest) || !step.stale && err != nil {
			t.Errorf("%s: %v, want stale %v", step.what, err, step.stale)
		}
	}
	if got := record(t, inst, url); got.LatestSeen != "26.10.1" || got.ManifestUpdated != "2026-10-01T00:00:00Z" {
		t.Errorf("record %+v, want 26.10.1 seen and the date of the stable list", got)
	}
}

// A kvsctl before this one remembered the newest release of a list, a
// candidate included, with the date of that list; the record starts again
// rather than refuse that same list for ever, and a list held to a version
// seen in candidate lists only names the time it was read.
func TestCheckManifestStartsAgainFromARecordOfACandidate(t *testing.T) {
	inst := testInstance(t, "DOMAIN=example.com\n")
	url := "https://example.com/download/26.11.0-rc1/manifest.json"
	updates := &instance.Updates{}
	old := updates.For(url)
	old.LatestSeen, old.ManifestUpdated = "26.11.0-rc1", "2026-10-05T00:00:00Z"
	if err := inst.SaveUpdates(updates); err != nil {
		t.Fatal(err)
	}
	list := candidateList("2026-10-05T00:00:00Z", "26.11.0-rc1", "26.10.0")
	for i := range 2 {
		if err := CheckManifest(inst, list, url, false); err != nil {
			t.Fatalf("read %d of the list the record was made of: %v", i+1, err)
		}
	}
	if got := record(t, inst, url); got.LatestSeen != "26.10.0" || got.ManifestUpdated != "" {
		t.Errorf("record %+v, want 26.10.0 seen and no date", got)
	}
	if err := CheckManifest(inst, datedManifest("2026-10-01T00:00:00Z", "26.10.0"), url, false); err != nil {
		t.Errorf("the stable list: %v", err)
	}

	mirror := "https://mirror.example.com/manifest.json"
	if err := CheckManifest(inst, candidateList("2026-10-20T00:00:00Z", "26.11.0-rc2", "26.10.1"), mirror, false); err != nil {
		t.Fatal(err)
	}
	read := record(t, inst, mirror).LastCheck.UTC().Format(time.RFC3339)
	err := CheckManifest(inst, candidateList("2026-10-21T00:00:00Z", "26.11.0-rc3", "26.10.0"), mirror, false)
	if want := "manifest is older than the one seen on " + read + " (latest 26.10.1)"; err == nil || !strings.HasPrefix(err.Error(), want) {
		t.Errorf("a lower list after candidate lists alone: %v, want %q", err, want)
	}
}

// The keys a manifest announces are kept, so status can warn before one
// this build does not know starts signing; the next list replaces them.
func TestCheckManifestRecordsTheAnnouncedKeys(t *testing.T) {
	inst := testInstance(t, "DOMAIN=example.com\n")
	url := "https://example.com/manifest.json"
	m := datedManifest("2026-10-01T00:00:00Z", "26.10.0")
	m.Keys = []manifest.Key{{ID: "r2", Pub: "unused", ValidFrom: "2026-11-01"}, {ID: "r3"}}
	if err := CheckManifest(inst, m, url, false); err != nil {
		t.Fatal(err)
	}
	updates, err := inst.LoadUpdates()
	if err != nil {
		t.Fatal(err)
	}
	if want := []instance.AnnouncedKey{{ID: "r2", ValidFrom: "2026-11-01"}, {ID: "r3"}}; !slices.Equal(updates.Keys, want) {
		t.Errorf("announced keys %+v, want %+v", updates.Keys, want)
	}
	if err := CheckManifest(inst, datedManifest("2026-10-02T00:00:00Z", "26.10.0"), url, false); err != nil {
		t.Fatal(err)
	}
	if updates, err := inst.LoadUpdates(); err != nil || len(updates.Keys) != 0 {
		t.Errorf("keys the next list no longer announces: %+v, %v", updates, err)
	}
}
