package main

import (
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
	if len(lines) != 2 {
		t.Fatalf("lines are %v", lines)
	}
	if !strings.HasPrefix(lines[0], "  0.3.0") {
		t.Fatalf("the newest release is marked as installed: %q", lines[0])
	}
	for _, want := range []string{"2026-09-20", "8.3", "0.2.0", "migrates", "latest, nginx 1.29"} {
		if !strings.Contains(lines[0], want) {
			t.Fatalf("line %q lacks %q", lines[0], want)
		}
	}
	if !strings.HasPrefix(lines[1], "* 0.2.0") {
		t.Fatalf("the installed release is not marked: %q", lines[1])
	}
	if !strings.Contains(lines[1], " - ") {
		t.Fatalf("an unset field is not a dash: %q", lines[1])
	}
}
