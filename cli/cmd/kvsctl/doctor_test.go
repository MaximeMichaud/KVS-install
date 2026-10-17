package main

import (
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"sync/atomic"
	"testing"

	"github.com/MaximeMichaud/KVS-install/cli/internal/doctor"
)

func TestDoctorNeverRunsTheUpdateReminder(t *testing.T) {
	var requests atomic.Int32
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) { requests.Add(1); w.WriteHeader(500) }))
	defer server.Close()
	root := newRoot(t, "kvsctl/state.json", `{"current":"1.0.0"}`)
	t.Setenv("KVSCTL_RELEASE_KEY", "invalid-key-must-not-be-read")
	t.Setenv("KVSCTL_MANIFEST_URL", server.URL+"/manifest.json")
	for _, args := range [][]string{{"--only", "config.env", "--json"}, {"--list-checks"}, {"--only", "state", "--json"}} {
		out, err := runKvsctl(t, append([]string{"doctor", "--root", root}, args...)...)
		if err != nil {
			t.Fatalf("%v: %v\n%s", args, err, out)
		}
	}
	if requests.Load() != 0 {
		t.Fatalf("doctor fetched the manifest %d times", requests.Load())
	}
	if _, err := os.Stat(filepath.Join(root, "kvsctl", "update-check.json")); !os.IsNotExist(err) {
		t.Fatalf("doctor created an update cache: %v", err)
	}
	if _, err := os.Stat(filepath.Join(root, "kvsctl", "logs")); !os.IsNotExist(err) {
		t.Fatalf("doctor created run logs: %v", err)
	}
}

func TestDoctorJSONExitCodesAndUsage(t *testing.T) {
	root := newRoot(t)
	for _, tc := range []struct {
		name string
		args []string
		code int
	}{{"warning", nil, 0}, {"strict", []string{"--strict"}, 1}} {
		t.Run(tc.name, func(t *testing.T) {
			args := append([]string{"doctor", "--root", root, "--only", "state.record", "--json"}, tc.args...)
			out, err := runKvsctl(t, args...)
			var report doctor.Report
			if json.Unmarshal([]byte(out), &report) != nil || report.SchemaVersion != 1 || report.ExitCode != tc.code || exitCode(err) != tc.code {
				t.Fatalf("error %v, output %s", err, out)
			}
		})
	}
	for _, args := range [][]string{{"--only", "unknown"}, {"--only", "network"}, {"--timeout", "0s"}, {"--timeout", "-1s"}, {"extra"}} {
		out, err := runKvsctl(t, append([]string{"doctor", "--root", root}, args...)...)
		if exitCode(err) != 2 {
			t.Fatalf("%v: %v, output %s", args, err, out)
		}
	}
	if err := os.WriteFile(filepath.Join(root, "docker", ".env"), []byte("DOMAIN=example.test\nPASSWORD=\"fixture-secret-do-not-print\n"), 0o600); err != nil {
		t.Fatal(err)
	}
	out, err := runKvsctl(t, "doctor", "--root", root, "--only", "config.env", "--json")
	var report doctor.Report
	if exitCode(err) != 1 || json.Unmarshal([]byte(out), &report) != nil || strings.Contains(out, "fixture-secret-do-not-print") {
		t.Fatalf("%v: %s", err, out)
	}
}

func TestDoctorQuietAndExamples(t *testing.T) {
	root := newRoot(t)
	out, err := runKvsctl(t, "doctor", "--root", root, "--only", "config.env", "--quiet")
	if err != nil || out != "" {
		t.Fatalf("quiet successful doctor: %v %q", err, out)
	}
	out, err = runKvsctl(t, "doctor", "--root", root, "--only", "state.record", "--quiet")
	if err != nil || !strings.Contains(out, "[WARN]") || strings.Contains(out, "[OK") || !strings.Contains(out, "Next: kvsctl adopt") {
		t.Fatalf("quiet warning: %v %q", err, out)
	}
	if doctorCmd().Example == "" {
		t.Fatal("doctor help lacks examples")
	}
}
