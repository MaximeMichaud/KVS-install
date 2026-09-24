package main

import (
	"strings"
	"testing"
	"time"

	"github.com/MaximeMichaud/KVS-install/cli/internal/instance"
)

func TestHistoryLines(t *testing.T) {
	entries := []instance.Entry{
		{Version: "0.1.0", Action: "adopt", Date: time.Date(2026, 9, 24, 3, 38, 4, 0, time.FixedZone("CEST", 2*3600))},
		{Version: "0.2.0", Action: "upgrade", Date: time.Date(2026, 9, 24, 4, 0, 0, 0, time.UTC), Note: "from 0.1.0"},
	}
	lines := historyLines(entries)
	if len(lines) != 2 {
		t.Fatalf("lines are %v", lines)
	}
	if !strings.HasPrefix(lines[0], "2026-09-24 01:38  adopt") {
		t.Fatalf("a local time was not printed in UTC: %q", lines[0])
	}
	if !strings.HasSuffix(lines[0], "0.1.0") {
		t.Fatalf("an empty note left trailing spaces: %q", lines[0])
	}
	if !strings.Contains(lines[1], "upgrade") || !strings.HasSuffix(lines[1], "from 0.1.0") {
		t.Fatalf("second line is %q", lines[1])
	}
}
