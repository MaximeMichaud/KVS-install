package main

import (
	"encoding/json"
	"os"
	"path/filepath"
	"reflect"
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

// The note of a rollback keeps the first line of the failure, which ends
// with a separator when a docker command wrote nothing on stderr; the line
// drops it.
func TestHistoryLinesDropAnEmptyDetail(t *testing.T) {
	lines := historyLines([]instance.Entry{{Version: "1.0.0", Action: instance.ActionRollback, Date: time.Date(2026, 10, 7, 0, 57, 0, 0, time.UTC), Note: "1.1.0 failed: docker exec kvs-php-fpm: exit status 1: "}})
	if want := "2026-10-07 00:57  rollback    1.0.0       1.1.0 failed: docker exec kvs-php-fpm: exit status 1"; len(lines) != 1 || lines[0] != want {
		t.Fatalf("lines are %q, want %q", lines, want)
	}
}

// The history as kvsctl/state.json keeps it, written by hand since its
// keys are what every build reads back: the first two entries are those of
// a build before the rollback entries carried "undid", which said how the
// run it undid ended in its note alone, "failed" whatever ended it; the
// last three are those of this build, one per way a run ends. kvsctl
// history prints the note of each, which says how the run ended and why;
// --json gives the same entries, "undid" on the last three only; and the
// last upgrade status and check show is read from an entry of either kind.
func TestHistoryReadsTheEntriesOfEveryBuild(t *testing.T) {
	root := newRoot(t)
	const state = `{
  "current": "1.0.0",
  "history": [
    {"version": "1.0.0", "action": "adopt", "date": "2026-09-24T03:38:04Z"},
    {"version": "1.0.0", "action": "rollback", "date": "2026-09-30T10:00:00Z", "note": "1.1.0 failed: interrupted during apply"},
    {"version": "1.0.0", "action": "rollback", "date": "2026-10-07T00:57:00Z", "note": "1.1.0 failed: not healthy after 1s: kvs-nginx is unhealthy",
     "undid": {"action": "upgrade", "to": "1.1.0", "outcome": "failed", "cause": "not healthy after 1s: kvs-nginx is unhealthy"}},
    {"version": "1.0.0", "action": "rollback", "date": "2026-10-07T01:10:00Z", "note": "1.1.0 was cancelled: context canceled",
     "undid": {"action": "upgrade", "to": "1.1.0", "outcome": "cancelled", "cause": "context canceled"}},
    {"version": "1.0.0", "action": "rollback", "date": "2026-10-07T01:20:00Z", "note": "1.1.0 was interrupted during apply",
     "undid": {"action": "upgrade", "to": "1.1.0", "outcome": "interrupted", "cause": "interrupted during apply"}}
  ]
}`
	path := filepath.Join(root, "kvsctl", "state.json")
	if err := os.MkdirAll(filepath.Dir(path), 0o750); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(path, []byte(state), 0o600); err != nil {
		t.Fatal(err)
	}
	// A manifest that cannot be read leaves the reminder out.
	missing := "file://" + filepath.Join(root, "missing.json")

	out, err := runKvsctl(t, "history", "--root", root, "--manifest", missing)
	if err != nil {
		t.Fatal(err)
	}
	want := `2026-09-24 03:38  adopt       1.0.0
2026-09-30 10:00  rollback    1.0.0       1.1.0 failed: interrupted during apply
2026-10-07 00:57  rollback    1.0.0       1.1.0 failed: not healthy after 1s: kvs-nginx is unhealthy
2026-10-07 01:10  rollback    1.0.0       1.1.0 was cancelled: context canceled
2026-10-07 01:20  rollback    1.0.0       1.1.0 was interrupted during apply
`
	if out != want {
		t.Errorf("history printed:\n%s\nwant:\n%s", out, want)
	}

	out, err = runKvsctl(t, "history", "--json", "--root", root, "--manifest", missing)
	if err != nil {
		t.Fatal(err)
	}
	var entries []map[string]json.RawMessage
	if err := json.Unmarshal([]byte(out), &entries); err != nil || len(entries) != 5 {
		t.Fatalf("history --json printed %d entries (%v):\n%s", len(entries), err, out)
	}
	undid := []map[string]string{
		nil,
		nil,
		{"action": "upgrade", "to": "1.1.0", "outcome": "failed", "cause": "not healthy after 1s: kvs-nginx is unhealthy"},
		{"action": "upgrade", "to": "1.1.0", "outcome": "cancelled", "cause": "context canceled"},
		{"action": "upgrade", "to": "1.1.0", "outcome": "interrupted", "cause": "interrupted during apply"},
	}
	for i, entry := range entries {
		var note string
		if err := json.Unmarshal(entry["note"], &note); i > 0 && (err != nil || note == "") {
			t.Errorf("entry %d of history --json has no note: %s", i, out)
		}
		raw, ok := entry["undid"]
		if ok != (undid[i] != nil) {
			t.Errorf("entry %d of history --json has undid %v, want %v: %s", i, ok, undid[i] != nil, out)
		}
		if !ok || undid[i] == nil {
			continue
		}
		var got map[string]string
		if err := json.Unmarshal(raw, &got); err != nil || !reflect.DeepEqual(got, undid[i]) {
			t.Errorf("entry %d of history --json has undid %s, want %v", i, raw, undid[i])
		}
	}

	inst, err := instance.Detect(root)
	if err != nil {
		t.Fatal(err)
	}
	read, err := inst.LoadState()
	if err != nil {
		t.Fatal(err)
	}
	for _, c := range []struct {
		entries         int
		how, cause, day string
	}{
		{2, "was interrupted", "interrupted during apply", "2026-09-30"},
		{3, "failed", "not healthy after 1s: kvs-nginx is unhealthy", "2026-10-07"},
		{4, "was cancelled", "context canceled", "2026-10-07"},
		{5, "was interrupted", "interrupted during apply", "2026-10-07"},
	} {
		state := *read
		state.History = read.History[:c.entries]
		last, ok := lastUndone(&state)
		if !ok || last.to != "1.1.0" || last.how != c.how || last.cause != c.cause || last.at.UTC().Format(time.DateOnly) != c.day {
			t.Errorf("the last upgrade of the first %d entries is %+v (%v), want to 1.1.0 %s on %s: %s", c.entries, last, ok, c.how, c.day, c.cause)
		}
	}
}
