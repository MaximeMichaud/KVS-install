package runlog

import (
	"context"
	"errors"
	"slices"
	"strings"
	"testing"
	"time"

	"github.com/MaximeMichaud/KVS-install/cli/internal/dockerx"
	"github.com/MaximeMichaud/KVS-install/cli/internal/upgrade"
)

// screen stands for the reporter that shows a run.
type screen struct {
	events []upgrade.Event
	answer bool
	asked  []string
}

func (s *screen) Event(e upgrade.Event) { s.events = append(s.events, e) }

func (s *screen) Confirm(_ context.Context, question string) bool {
	s.asked = append(s.asked, question)
	return s.answer
}

// logLines is the log without its timestamps.
func logLines(t *testing.T, l *Logger) []string {
	t.Helper()
	var out []string
	for _, line := range strings.Split(strings.TrimSuffix(readLog(t, l.Path()), "\n"), "\n") {
		_, text, _ := strings.Cut(line, " ")
		out = append(out, text)
	}
	return out
}

func TestReporterLogsEveryEventThenForwardsIt(t *testing.T) {
	setClock(t, time.Date(2026, 10, 6, 12, 3, 9, 0, time.UTC))
	l, err := Open(t.TempDir(), "upgrade")
	if err != nil {
		t.Fatal(err)
	}
	next := &screen{}
	r := NewReporter(l, next)
	image := func(current int64, done bool) upgrade.Event {
		return upgrade.Event{Kind: upgrade.KindImage, Image: "mariadb:11.8.3", Service: "mariadb", From: "11.4.8", To: "11.8.3", Progress: dockerx.Progress{Current: current, Total: 1000, Done: done}}
	}
	events := []upgrade.Event{
		{Kind: upgrade.KindStepStart, Step: upgrade.StepPull, Message: "3 images"},
		{Kind: upgrade.KindImage, Image: "kvs-php:8.3", Service: "php-fpm", From: "8.3", To: "8.3", Message: "already on this machine"},
		image(0, false),
		image(50, false),
		image(150, false),
		image(190, false),
		image(1000, true),
		{Kind: upgrade.KindImages, Total: dockerx.Progress{Total: 1000, Done: true}},
		{Kind: upgrade.KindStepDone, Step: upgrade.StepPull, Message: "pulled"},
		{Kind: upgrade.KindLog, Message: "COMPOSE_FILE=docker-compose.yml:docker-compose.release.yml"},
		{Kind: upgrade.KindStepFail, Step: upgrade.StepVerify, Message: "kvs-nginx is unhealthy"},
		{Kind: upgrade.KindDone, Err: errors.New("upgrade to 26.10.1 failed: kvs-nginx is unhealthy\nlog: /opt/kvs/kvsctl/logs/20261006-120309-upgrade.log")},
	}
	for _, e := range events {
		r.Event(e)
	}
	if err := l.Close(); err != nil {
		t.Fatal(err)
	}
	if len(next.events) != len(events) {
		t.Fatalf("the screen got %d events, want all %d", len(next.events), len(events))
	}
	want := []string{
		"[pull] start: 3 images",
		"php-fpm kvs-php:8.3: already on this machine",
		"mariadb mariadb:11.8.3 (11.4.8 -> 11.8.3): 0%, 0 B of 1 kB",
		"mariadb mariadb:11.8.3 (11.4.8 -> 11.8.3): 10%, 150 B of 1 kB",
		"mariadb mariadb:11.8.3 (11.4.8 -> 11.8.3): pulled, 1 kB",
		"all images pulled (1 kB)",
		"[pull] done: pulled",
		"COMPOSE_FILE=docker-compose.yml:docker-compose.release.yml",
		"[verify] FAILED: kvs-nginx is unhealthy",
		"FAILED: upgrade to 26.10.1 failed: kvs-nginx is unhealthy",
		"log: /opt/kvs/kvsctl/logs/20261006-120309-upgrade.log",
	}
	if got := logLines(t, l); !slices.Equal(got, want) {
		t.Errorf("log:\n%s\nwant:\n%s", strings.Join(got, "\n"), strings.Join(want, "\n"))
	}
}

func TestReporterLogsTheQuestionAndTheAnswer(t *testing.T) {
	l, err := Open(t.TempDir(), "rollback")
	if err != nil {
		t.Fatal(err)
	}
	yes := &screen{answer: true}
	if !NewReporter(l, yes).Confirm(context.Background(), "Roll back to 26.10.0?") {
		t.Error("the screen said yes")
	}
	if len(yes.asked) != 1 {
		t.Errorf("the screen was asked %d times", len(yes.asked))
	}
	if NewReporter(l, nil).Confirm(context.Background(), "Upgrade to 26.10.1?") {
		t.Error("nobody can answer a run nobody watches, which is a no")
	}
	cancelled, cancel := context.WithCancel(context.Background())
	cancel()
	if NewReporter(l, &screen{}).Confirm(cancelled, "Upgrade to 26.10.1?") {
		t.Error("a cancelled question is a no")
	}
	if err := l.Close(); err != nil {
		t.Fatal(err)
	}
	want := []string{
		"question: Roll back to 26.10.0?",
		"answer: yes",
		"question: Upgrade to 26.10.1?",
		"answer: no",
		"question: Upgrade to 26.10.1?",
		"answer: none, the run was cancelled while it waited",
	}
	if got := logLines(t, l); !slices.Equal(got, want) {
		t.Errorf("log:\n%s\nwant:\n%s", strings.Join(got, "\n"), strings.Join(want, "\n"))
	}
}

func TestReporterTellsOnceThatTheLogFailed(t *testing.T) {
	l, err := Open(t.TempDir(), "upgrade")
	if err != nil {
		t.Fatal(err)
	}
	defer l.Close()
	l.w = &failingWriter{}
	next := &screen{}
	r := NewReporter(l, next)
	for _, msg := range []string{"one", "two", "three"} {
		r.Event(upgrade.Event{Kind: upgrade.KindLog, Message: msg})
	}
	var forwarded, told []string
	for _, e := range next.events {
		if strings.Contains(e.Message, "run log can no longer be written") {
			told = append(told, e.Message)
			continue
		}
		forwarded = append(forwarded, e.Message)
	}
	if !slices.Equal(forwarded, []string{"one", "two", "three"}) {
		t.Errorf("the run's own events = %v, want every one", forwarded)
	}
	if len(told) != 1 || !strings.Contains(told[0], "no space left on device") {
		t.Errorf("the failure must be told once, with its cause: %q", told)
	}
}
