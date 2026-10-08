package upgrade

import (
	"context"
	"os"
	"path/filepath"
	"runtime"
	"slices"
	"strings"
	"sync"
	"testing"

	"github.com/MaximeMichaud/KVS-install/cli/internal/instance"
)

// recorder is a reporter that keeps what the runner said. on, when set,
// sees every event as it comes; cut, when set, ends the goroutine of the
// run at the first event it matches, the way a kill ends kvsctl: nothing
// after it runs and nothing more is heard.
type recorder struct {
	mu        sync.Mutex
	events    []Event
	questions []string
	// asked is how many events had come when each question was asked.
	asked  []int
	answer bool
	on     func(Event)
	cut    func(Event) bool
	wasCut bool
}

func (r *recorder) Event(e Event) {
	r.mu.Lock()
	if r.wasCut {
		r.mu.Unlock()
		return
	}
	r.events = append(r.events, e)
	on, cut := r.on, r.cut != nil && r.cut(e)
	r.wasCut = cut
	r.mu.Unlock()
	if on != nil {
		on(e)
	}
	if cut {
		runtime.Goexit()
	}
}

func (r *recorder) Confirm(_ context.Context, question string) bool {
	r.mu.Lock()
	defer r.mu.Unlock()
	r.questions = append(r.questions, question)
	r.asked = append(r.asked, len(r.events))
	return r.answer
}

// logs are the free text lines, in order.
func (r *recorder) logs() []string {
	r.mu.Lock()
	defer r.mu.Unlock()
	var out []string
	for _, e := range r.events {
		if e.Kind == KindLog {
			out = append(out, e.Message)
		}
	}
	return out
}

// notices are the log lines marked for the operator, in order.
func (r *recorder) notices() []string {
	r.mu.Lock()
	defer r.mu.Unlock()
	var out []string
	for _, e := range r.events {
		if e.Kind == KindLog && e.Notice {
			out = append(out, e.Message)
		}
	}
	return out
}

// said reports whether a log line contains text.
func (r *recorder) said(text string) bool {
	return slices.ContainsFunc(r.logs(), func(line string) bool { return strings.Contains(line, text) })
}

// done is the error of the KindDone event, and whether there was one.
func (r *recorder) done() (error, bool) {
	r.mu.Lock()
	defer r.mu.Unlock()
	for _, e := range r.events {
		if e.Kind == KindDone {
			return e.Err, true
		}
	}
	return nil, false
}

// testInstance writes a minimal installation in a temp directory: the
// compose file Detect looks for, the .env, and whatever else is named.
func testInstance(t *testing.T, env string, extra ...string) *instance.Instance {
	t.Helper()
	dir := t.TempDir()
	docker := filepath.Join(dir, "docker")
	if err := os.MkdirAll(docker, 0o755); err != nil {
		t.Fatal(err)
	}
	files := append([]string{"docker-compose.yml"}, extra...)
	for _, name := range files {
		if err := os.WriteFile(filepath.Join(docker, name), []byte("services: {}\n"), 0o644); err != nil {
			t.Fatal(err)
		}
	}
	if err := os.WriteFile(filepath.Join(docker, ".env"), []byte(env), 0o600); err != nil {
		t.Fatal(err)
	}
	inst, err := instance.Detect(dir)
	if err != nil {
		t.Fatal(err)
	}
	return inst
}
