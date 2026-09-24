package ui

import (
	"bytes"
	"context"
	"os"
	"strings"
	"testing"
	"time"

	tea "github.com/charmbracelet/bubbletea"

	"github.com/MaximeMichaud/KVS-install/cli/internal/dockerx"
	"github.com/MaximeMichaud/KVS-install/cli/internal/upgrade"
)

// TestConfirmAnswersNoWhenTheScreenQuits covers the hang an operator hit
// by pressing Ctrl-C at the confirmation: the model must answer the
// runner instead of leaving it on the channel forever.
func TestConfirmAnswersNoWhenTheScreenQuits(t *testing.T) {
	for _, key := range []tea.KeyMsg{
		{Type: tea.KeyCtrlC},
		{Type: tea.KeyEsc},
		{Type: tea.KeyRunes, Runes: []rune("q")},
	} {
		cancelled := false
		rep, m := NewTerminal("title", upgrade.UpgradeSteps, func() { cancelled = true })
		answered := make(chan bool, 1)
		go func() { answered <- rep.Confirm(context.Background(), "Upgrade to 0.2.0?") }()
		select {
		case e := <-rep.events:
			m.Update(eventMsg(e))
		case <-time.After(2 * time.Second):
			t.Fatal("the question never reached the screen")
		}
		if !m.asking {
			t.Fatalf("%s: the screen is not asking", key)
		}
		m.Update(key)
		select {
		case answer := <-answered:
			if answer {
				t.Fatalf("%s: answered yes", key)
			}
		case <-time.After(2 * time.Second):
			t.Fatalf("%s: Confirm never returned", key)
		}
		if m.asking {
			t.Fatalf("%s: the screen is still asking", key)
		}
		if key.Type == tea.KeyCtrlC && !cancelled {
			t.Fatal("Ctrl-C did not cancel the context")
		}
	}
}

func TestConfirmAnswersYes(t *testing.T) {
	rep, m := NewTerminal("title", upgrade.UpgradeSteps, func() {})
	answered := make(chan bool, 1)
	go func() { answered <- rep.Confirm(context.Background(), "Upgrade to 0.2.0?") }()
	m.Update(eventMsg(<-rep.events))
	m.Update(tea.KeyMsg{Type: tea.KeyRunes, Runes: []rune("y")})
	select {
	case answer := <-answered:
		if !answer {
			t.Fatal("answered no")
		}
	case <-time.After(2 * time.Second):
		t.Fatal("Confirm never returned")
	}
}

// TestEventNeverBlocksAfterDetach covers the upgrade that stalled behind
// a full event buffer once the screen was gone: past 256 events the
// runner used to block inside the compose output scanner.
func TestEventNeverBlocksAfterDetach(t *testing.T) {
	rep, _ := NewTerminal("title", upgrade.UpgradeSteps, func() {})
	rep.Detach()
	done := make(chan struct{})
	go func() {
		for i := 0; i < 1000; i++ {
			rep.Event(upgrade.Event{Kind: upgrade.KindLog, Message: "line"})
		}
		close(done)
	}()
	select {
	case <-done:
	case <-time.After(5 * time.Second):
		t.Fatal("Event blocked after the screen ended")
	}
	if rep.Confirm(context.Background(), "still there?") {
		t.Fatal("Confirm said yes without a screen")
	}
}

// TestDetachFreesASendInFlight covers the runner already blocked on a
// full buffer when the screen dies: it must be let go, not left holding
// the compose output scanner.
func TestDetachFreesASendInFlight(t *testing.T) {
	rep, _ := NewTerminal("title", upgrade.UpgradeSteps, func() {})
	for i := 0; i < cap(rep.events); i++ {
		rep.Event(upgrade.Event{Kind: upgrade.KindLog, Message: "filling the buffer"})
	}
	blocked := make(chan struct{})
	go func() {
		rep.Event(upgrade.Event{Kind: upgrade.KindLog, Message: "one too many"})
		close(blocked)
	}()
	select {
	case <-blocked:
		t.Fatal("the buffer was not full, the test proves nothing")
	case <-time.After(100 * time.Millisecond):
	}
	rep.Detach()
	select {
	case <-blocked:
	case <-time.After(5 * time.Second):
		t.Fatal("a send in flight stayed blocked after the screen ended")
	}
}

func TestTruncateCountsRunes(t *testing.T) {
	cases := []struct {
		in    string
		width int
		want  string
	}{
		{"short", 5, "short"},
		{"ééééé", 5, "ééééé"},
		{"ééééééééé", 4, "ééé…"},
		{"abcdefghij", 4, "abc…"},
	}
	for _, c := range cases {
		if got := truncate(c.in, c.width); got != c.want {
			t.Fatalf("truncate(%q, %d) = %q, wanted %q", c.in, c.width, got, c.want)
		}
	}
	if got := truncate("ééééé", 3); got != "ééééé" {
		t.Fatalf("a width under four must not cut: %q", got)
	}
}

func TestPlainQuiet(t *testing.T) {
	var out bytes.Buffer
	p := NewPlain(&out, nil, true)
	p.Quiet = true
	p.Event(upgrade.Event{Kind: upgrade.KindStepStart, Step: upgrade.StepPull, Message: "4 images"})
	p.Event(upgrade.Event{Kind: upgrade.KindLog, Message: "a compose line"})
	p.Event(upgrade.Event{Kind: upgrade.KindImage, Image: "ghcr.io/x/php:1", Progress: dockerx.Progress{Current: 1, Total: 2}})
	p.Event(upgrade.Event{Kind: upgrade.KindStepFail, Step: upgrade.StepVerify, Message: "GET / answered 500"})
	text := out.String()
	if strings.Contains(text, "a compose line") || strings.Contains(text, "ghcr.io") {
		t.Fatalf("quiet printed logs or image progress:\n%s", text)
	}
	if !strings.Contains(text, "4 images") || !strings.Contains(text, "GET / answered 500") {
		t.Fatalf("quiet dropped a step or a failure:\n%s", text)
	}
}

func TestIsTerminalRefusesDevNull(t *testing.T) {
	f, err := os.Open(os.DevNull)
	if err != nil {
		t.Skip("no /dev/null")
	}
	defer f.Close()
	if IsTerminal(f) {
		t.Fatal("/dev/null passes for a terminal")
	}
	if IsTerminal(nil) {
		t.Fatal("a nil file passes for a terminal")
	}
}

// The screen names every service with the version it runs and the one it
// will run, with the size before the pull and a bar during it; an image
// that needs no download shows its note.
func TestImagesShowTheVersions(t *testing.T) {
	_, m := NewTerminal("KVS stack", upgrade.UpgradeSteps, func() {})
	m.width = 100
	m.apply(upgrade.Event{Kind: upgrade.KindStepDone, Step: upgrade.StepCheck, Message: "0.2.0 available"})
	m.apply(upgrade.Event{Kind: upgrade.KindImage, Step: upgrade.StepPull, Image: "r/nginx:0.2.0", Service: "nginx", From: "local build", To: "0.2.0", Progress: dockerx.Progress{Total: 70 << 20}, Total: dockerx.Progress{Total: 70 << 20}})
	m.apply(upgrade.Event{Kind: upgrade.KindImage, Step: upgrade.StepPull, Image: "mariadb:11.8", Service: "mariadb", From: "11.8", To: "11.8", Message: "unchanged", Progress: dockerx.Progress{Done: true}, Total: dockerx.Progress{Total: 70 << 20}})
	view := m.View()
	for _, want := range []string{"nginx", "local build → 0.2.0", "73 MB to download", "mariadb", "11.8", "unchanged"} {
		if !strings.Contains(view, want) {
			t.Errorf("before the pull the screen lacks %q:\n%s", want, view)
		}
	}
	if strings.Contains(view, "0%") {
		t.Errorf("a bar was drawn before the pull started:\n%s", view)
	}
	m.apply(upgrade.Event{Kind: upgrade.KindStepStart, Step: upgrade.StepPull, Message: "1 image"})
	m.apply(upgrade.Event{Kind: upgrade.KindImage, Step: upgrade.StepPull, Image: "r/nginx:0.2.0", Service: "nginx", From: "local build", To: "0.2.0", Progress: dockerx.Progress{Current: 35 << 20, Total: 70 << 20}, Total: dockerx.Progress{Current: 35 << 20, Total: 70 << 20}})
	view = m.View()
	if !strings.Contains(view, "50%") || !strings.Contains(view, "local build → 0.2.0") || strings.Contains(view, "to download") {
		t.Errorf("during the pull the screen shows:\n%s", view)
	}
	if len(m.images) != 2 {
		t.Errorf("rows are keyed by service, got %d rows", len(m.images))
	}
}

func TestPlainImagesShowTheVersions(t *testing.T) {
	var out bytes.Buffer
	p := NewPlain(&out, nil, true)
	p.Event(upgrade.Event{Kind: upgrade.KindImage, Image: "r/nginx:0.2.0", Service: "nginx", From: "local build", To: "0.2.0", Progress: dockerx.Progress{Total: 70 << 20}})
	p.Event(upgrade.Event{Kind: upgrade.KindImage, Image: "mariadb:11.8", Service: "mariadb", From: "11.8", To: "11.8", Message: "unchanged", Progress: dockerx.Progress{Done: true}})
	p.Event(upgrade.Event{Kind: upgrade.KindImage, Image: "r/nginx:0.2.0", Service: "nginx", From: "local build", To: "0.2.0", Progress: dockerx.Progress{Current: 35 << 20, Total: 70 << 20}})
	p.Event(upgrade.Event{Kind: upgrade.KindImage, Image: "r/nginx:0.2.0", Service: "nginx", From: "local build", To: "0.2.0", Progress: dockerx.Progress{Current: 70 << 20, Total: 70 << 20, Done: true}})
	text := out.String()
	for _, want := range []string{"nginx      local build -> 0.2.0", "73 MB to download", "mariadb    11.8", "unchanged", " 50%", "100%"} {
		if !strings.Contains(text, want) {
			t.Errorf("plain output lacks %q:\n%s", want, text)
		}
	}
}
