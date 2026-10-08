package instance

import (
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"time"
)

// Updates is what the manifest checks remember. It is kept out of the state
// so a status run, which only reads the manifest, never rewrites what an
// upgrade wrote to state.json.
type Updates struct {
	// Manifests holds one record per manifest URL: a release candidate
	// list read once through --manifest never makes the stable list look
	// stale, nor the other way round.
	Manifests map[string]*ManifestCheck `json:"manifests,omitempty"`
	// Keys are the signing keys the manifest read last announces, so a
	// status run can warn before a key this build does not know starts
	// signing. Every list is signed by the keys of the same project, so
	// they are not kept per URL.
	Keys []AnnouncedKey `json:"keys,omitempty"`
}

// ManifestCheck is what the checks of one manifest URL saw
// (upgrade.CheckManifest).
type ManifestCheck struct {
	// LastCheck is when a list was last read there.
	LastCheck time.Time `json:"last_check,omitzero"`
	// LatestSeen is the newest stable release the lists read there named,
	// the list of a release candidate included: a candidate is installed
	// only by name, and is never remembered. A record that holds one was
	// written by an older kvsctl, and the next check starts it again.
	LatestSeen string `json:"latest_seen,omitempty"`
	// ManifestUpdated is the date of the newest stable list read there,
	// which a later copy of the same list never moves back. The list of a
	// release candidate leaves it: it is signed after the stable list it
	// extends, which a mirror may serve again after it.
	ManifestUpdated string `json:"manifest_updated,omitempty"`
}

// AnnouncedKey is a signing key the manifest announces ahead of its use.
type AnnouncedKey struct {
	ID        string `json:"id"`
	ValidFrom string `json:"valid_from,omitempty"`
}

// For is the record of a manifest URL, created empty the first time that
// URL is asked for, so a check fills it in place before SaveUpdates.
func (u *Updates) For(url string) *ManifestCheck {
	if u.Manifests == nil {
		u.Manifests = map[string]*ManifestCheck{}
	}
	check := u.Manifests[url]
	if check == nil {
		check = &ManifestCheck{}
		u.Manifests[url] = check
	}
	return check
}

// legacyManifestURL is the list the builds that kept a single record read
// by default. A file they wrote has its record taken as this URL's.
const legacyManifestURL = "https://github.com/MaximeMichaud/KVS-install/releases/latest/download/manifest.json"

// updatesFile is updates.json as a load reads it: the records per URL, and
// the single record of the builds before them, which a save drops.
type updatesFile struct {
	Updates
	LastCheck       time.Time `json:"last_check"`
	LatestSeen      string    `json:"latest_seen"`
	ManifestUpdated string    `json:"manifest_updated"`
}

func (i *Instance) updatesPath() string { return filepath.Join(i.StateDir(), "updates.json") }

// LoadUpdates reads what the last checks saw; a missing file is a stack that
// has never checked, not an error.
func (i *Instance) LoadUpdates() (*Updates, error) {
	data, err := os.ReadFile(i.updatesPath())
	if errors.Is(err, os.ErrNotExist) {
		return &Updates{}, nil
	}
	if err != nil {
		return nil, err
	}
	var f updatesFile
	if err := json.Unmarshal(data, &f); err != nil {
		return nil, fmt.Errorf("%s: %w", i.updatesPath(), err)
	}
	u := f.Updates
	legacy := !f.LastCheck.IsZero() || f.LatestSeen != "" || f.ManifestUpdated != ""
	if _, kept := u.Manifests[legacyManifestURL]; legacy && !kept {
		*u.For(legacyManifestURL) = ManifestCheck{LastCheck: f.LastCheck, LatestSeen: f.LatestSeen, ManifestUpdated: f.ManifestUpdated}
	}
	return &u, nil
}

// SaveUpdates writes what the checks saw, atomically.
func (i *Instance) SaveUpdates(u *Updates) error {
	if err := os.MkdirAll(i.StateDir(), 0o750); err != nil {
		return err
	}
	data, err := json.MarshalIndent(u, "", "  ")
	if err != nil {
		return err
	}
	return writeAtomic(i.updatesPath(), data, 0o600)
}
