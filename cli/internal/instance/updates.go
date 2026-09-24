package instance

import (
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"time"
)

// Updates is what the daily manifest check remembers. It is kept out of the
// state so a status run, which only reads the manifest, never rewrites what
// an upgrade wrote to state.json.
type Updates struct {
	// LastCheck is when the manifest was last read.
	LastCheck time.Time `json:"last_check,omitempty"`
	// LatestSeen is the newest version that check found.
	LatestSeen string `json:"latest_seen,omitempty"`
	// ManifestUpdated is the date the manifest itself carries, which a
	// later manifest never moves back.
	ManifestUpdated string `json:"manifest_updated,omitempty"`
	// Keys are the signing keys the manifest announces, so a status run
	// can warn before a key this build does not know starts signing.
	Keys []AnnouncedKey `json:"keys,omitempty"`
}

// AnnouncedKey is a signing key the manifest announces ahead of its use.
type AnnouncedKey struct {
	ID        string `json:"id"`
	ValidFrom string `json:"valid_from,omitempty"`
}

func (i *Instance) updatesPath() string { return filepath.Join(i.StateDir(), "updates.json") }

// LoadUpdates reads what the last check saw; a missing file is a stack that
// has never checked, not an error.
func (i *Instance) LoadUpdates() (*Updates, error) {
	data, err := os.ReadFile(i.updatesPath())
	if errors.Is(err, os.ErrNotExist) {
		return &Updates{}, nil
	}
	if err != nil {
		return nil, err
	}
	var u Updates
	if err := json.Unmarshal(data, &u); err != nil {
		return nil, fmt.Errorf("%s: %w", i.updatesPath(), err)
	}
	return &u, nil
}

// SaveUpdates writes what the check saw, atomically.
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
