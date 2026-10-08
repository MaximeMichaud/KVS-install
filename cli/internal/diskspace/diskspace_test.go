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
	// What other processes write moves the free space between two readings,
	// so the answer is only checked to be one: the device, which does not
	// move, tells that it is the filesystem of the parent
	// (TestMeasureNamesTheDevice).
	missing, err := Avail(filepath.Join(dir, "kvsctl", "releases"))
	if err != nil {
		t.Fatal(err)
	}
	if missing <= 0 {
		t.Errorf("free space under a missing directory = %d, want more than zero", missing)
	}
	if _, err := Avail(""); err == nil {
		t.Error("an empty path is not a filesystem")
	}
}

func TestMeasure(t *testing.T) {
	space, err := Measure(t.TempDir())
	if err != nil {
		t.Fatal(err)
	}
	if space.Size <= 0 || space.Avail <= 0 || space.Avail > space.Size {
		t.Errorf("space %+v: the filesystem has a size and what is free fits in it", space)
	}
	if _, err := Measure(""); err == nil {
		t.Error("an empty path is not a filesystem")
	}
}

// Two paths of one filesystem name the same device, a path that does not
// exist yet included: the needs of an upgrade on them add up.
func TestMeasureNamesTheDevice(t *testing.T) {
	dir := t.TempDir()
	space, err := Measure(dir)
	if err != nil {
		t.Fatal(err)
	}
	if space.Device == 0 {
		t.Fatalf("no device for %s: %+v", dir, space)
	}
	missing, err := Measure(filepath.Join(dir, "backups", "not-yet"))
	if err != nil {
		t.Fatal(err)
	}
	if missing.Device != space.Device {
		t.Errorf("device of a missing directory = %d, want the %d of its parent", missing.Device, space.Device)
	}
}
