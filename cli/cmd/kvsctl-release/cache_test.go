package main

import (
	"path/filepath"
	"strings"
	"testing"
)

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
