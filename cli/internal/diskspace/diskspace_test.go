package diskspace

import (
	"path/filepath"
	"testing"
)

func TestAvail(t *testing.T) {
	dir := t.TempDir()
	free, err := Avail(dir)
	if err != nil {
		t.Fatal(err)
	}
	if free <= 0 {
		t.Errorf("free space of %s = %d, want more than zero", dir, free)
	}
	// A directory an upgrade has not created yet is measured on its parent.
	missing, err := Avail(filepath.Join(dir, "kvsctl", "releases"))
	if err != nil {
		t.Fatal(err)
	}
	if missing != free {
		t.Errorf("free space under a missing directory = %d, want the %d of its parent", missing, free)
	}
	if _, err := Avail(""); err == nil {
		t.Error("an empty path is not a filesystem")
	}
}
