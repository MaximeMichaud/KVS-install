package ui

import (
	"bytes"
	"context"
	"errors"
	"io"
	"os"
	"reflect"
	"regexp"
	"strings"
	"sync"
	"testing"
	"time"

	tea "github.com/charmbracelet/bubbletea"
	"github.com/charmbracelet/lipgloss"

	"github.com/MaximeMichaud/KVS-install/cli/internal/dockerx"
	"github.com/MaximeMichaud/KVS-install/cli/internal/upgrade"
)

// recorder is a fallback reporter that keeps what it was given.
type recorder struct {
	mu     sync.Mutex
	events []upgrade.Event
}

func (r *recorder) Event(e upgrade.Event) {
	r.mu.Lock()
	defer r.mu.Unlock()
	r.events = append(r.events, e)
}

func (r *recorder) Confirm(context.Context, string) bool { return false }

func (r *recorder) messages() []string {
	r.mu.Lock()
	defer r.mu.Unlock()
	var out []string
	for _, e := range r.events {
		out = append(out, e.Message)
	}
	return out
}

func newScreen(fallback upgrade.Reporter) (*TerminalReporter, *Model) {
	return NewTerminal("title", "/opt/kvs/kvsctl/logs/run.log", upgrade.UpgradeSteps, func() string { return "" }, fallback)
}

// deliver hands the screen what waits in the queue, the way the program
// does when the wake token arrives.
func deliver(t *testing.T, rep *TerminalReporter, m *Model) tea.Cmd {
	t.Helper()
	select {
	case <-rep.wake:
	case <-time.After(2 * time.Second):
		t.Fatal("nothing woke the screen")
	}
	_, cmd := m.Update(wakeMsg{})
	return cmd
}

// isQuit reports whether cmd ends the program, once the lines it prints
// above the screen are out.
func isQuit(cmd tea.Cmd) bool {
	if cmd == nil {
		return false
	}
	msg := cmd()
	if _, ok := msg.(tea.QuitMsg); ok {
		return true
	}
	// A sequence, a type Bubble Tea keeps to itself, is a list of
	// commands run in order: it ends the program when its last one does.
	// A batch runs its commands in no order, so it never counts.
	if _, ok := msg.(tea.BatchMsg); ok {
		return false
	}
	v := reflect.ValueOf(msg)
	if !v.IsValid() || v.Kind() != reflect.Slice || v.Len() == 0 {
		return false
	}
	last, ok := v.Index(v.Len() - 1).Interface().(tea.Cmd)
	return ok && isQuit(last)
}

// TestConfirmAnswersNoWhenTheScreenQuits covers the hang an operator hit
// by pressing Ctrl-C at the confirmation: the model must answer the
// runner instead of leaving it waiting forever.
func TestConfirmAnswersNoWhenTheScreenQuits(t *testing.T) {
	for _, key := range []tea.KeyMsg{
		{Type: tea.KeyCtrlC},
		{Type: tea.KeyEsc},
		{Type: tea.KeyRunes, Runes: []rune("q")},
	} {
		interrupts := 0
		rep, m := NewTerminal("title", "", upgrade.UpgradeSteps, func() string { interrupts++; return "stopping" }, nil)
		answered := make(chan bool, 1)
		go func() { answered <- rep.Confirm(context.Background(), "Upgrade to 0.2.0?") }()
		deliver(t, rep, m)
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
		if want := key.Type == tea.KeyCtrlC; (interrupts == 1) != want {
			t.Fatalf("%s: %d interrupts", key, interrupts)
		}
	}
}

func TestConfirmAnswersYes(t *testing.T) {
	rep, m := newScreen(nil)
	answered := make(chan bool, 1)
	go func() { answered <- rep.Confirm(context.Background(), "Upgrade to 0.2.0?") }()
	deliver(t, rep, m)
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

func TestConfirmAnswersNoWhenTheContextEnds(t *testing.T) {
	rep, _ := newScreen(nil)
	ctx, cancel := context.WithCancel(context.Background())
	answered := make(chan bool, 1)
	go func() { answered <- rep.Confirm(ctx, "Upgrade?") }()
	cancel()
	select {
	case answer := <-answered:
		if answer {
			t.Fatal("answered yes")
		}
	case <-time.After(2 * time.Second):
		t.Fatal("Confirm outlived its context")
	}
}

// A question pending when the screen goes is answered no: nobody is left
// to say yes, and the run must not wait for a screen that is gone.
func TestConfirmAnswersNoWhenTheScreenGoes(t *testing.T) {
	rep, _ := newScreen(nil)
	answered := make(chan bool, 1)
	go func() { answered <- rep.Confirm(context.Background(), "Upgrade?") }()
	<-rep.wake
	rep.Detach()
	select {
	case answer := <-answered:
		if answer {
			t.Fatal("answered yes")
		}
	case <-time.After(2 * time.Second):
		t.Fatal("Confirm outlived the screen")
	}
	if rep.Confirm(context.Background(), "still there?") {
		t.Fatal("Confirm said yes without a screen")
	}
}

// TestClosedStreamEndsTheScreen is the screen that stayed up after the
// run: an action that returns without its final event, as a forward
// rollback refusal once did, must still end the program.
func TestClosedStreamEndsTheScreen(t *testing.T) {
	rep, m := newScreen(nil)
	rep.Event(upgrade.Event{Kind: upgrade.KindStepStart, Step: upgrade.StepCheck, Message: "reading the manifest"})
	rep.Close()
	if cmd := deliver(t, rep, m); !isQuit(cmd) {
		t.Fatal("the screen did not quit once the stream closed")
	}
	if !m.ended || m.done {
		t.Fatalf("ended %v, done %v", m.ended, m.done)
	}
	view := m.View()
	if strings.Contains(view, StepTitle(upgrade.StepVerify)) {
		t.Fatalf("an ended screen still lists the steps that never ran:\n%s", view)
	}
}

func TestDoneEndsTheScreen(t *testing.T) {
	rep, m := newScreen(nil)
	rep.Event(upgrade.Event{Kind: upgrade.KindDone, Err: errors.New("the upgrade is blocked")})
	if cmd := deliver(t, rep, m); !isQuit(cmd) {
		t.Fatal("the screen did not quit on the final event")
	}
	if view := m.View(); !strings.Contains(view, "the upgrade is blocked") {
		t.Fatalf("the outcome is not shown:\n%s", view)
	}
}

// The program itself ends when the action closes the stream, with no key
// pressed and no signal: the real loop, input disabled.
func TestProgramEndsWithTheAction(t *testing.T) {
	rep, m := newScreen(nil)
	program := tea.NewProgram(m, tea.WithInput(nil), tea.WithOutput(io.Discard), tea.WithoutSignalHandler())
	ended := make(chan error, 1)
	go func() {
		_, err := program.Run()
		ended <- err
	}()
	for i := 0; i < 50; i++ {
		rep.Event(upgrade.Event{Kind: upgrade.KindLog, Message: "a compose line"})
	}
	rep.Close()
	select {
	case err := <-ended:
		if err != nil {
			t.Fatalf("the program ended with %v", err)
		}
	case <-time.After(5 * time.Second):
		program.Kill()
		t.Fatal("the program outlived the action")
	}
}

// Ctrl-C twice: the first one cancels and the screen says so, the second
// shows what the interrupt function answers then, and neither ends the
// screen, which stays until the run is over.
func TestCtrlCTwice(t *testing.T) {
	lines := []string{"Ctrl-C: the upgrade stops, and what it already changed is rolled back", "rollback in progress: Ctrl-C does not interrupt it"}
	calls := 0
	_, m := NewTerminal("title", "", upgrade.UpgradeSteps, func() string {
		line := lines[calls]
		calls++
		return line
	}, nil)
	for i, want := range lines {
		if _, cmd := m.Update(tea.KeyMsg{Type: tea.KeyCtrlC}); isQuit(cmd) {
			t.Fatalf("Ctrl-C %d ended the screen", i+1)
		}
		if view := m.View(); !strings.Contains(view, want) {
			t.Fatalf("after Ctrl-C %d the screen lacks %q:\n%s", i+1, want, view)
		}
	}
	if calls != 2 {
		t.Fatalf("%d interrupts", calls)
	}
}

// Enter at a question answers no, as the capital N of [y/N] says and as
// plain mode does, and so does any key but y: only a y says yes, to an
// upgrade, a rollback that replays a backup, or a recovery.
func TestEnterAnswersNo(t *testing.T) {
	for _, key := range []tea.KeyMsg{
		{Type: tea.KeyEnter},
		{Type: tea.KeyRunes, Runes: []rune("x")},
		{Type: tea.KeySpace, Runes: []rune(" ")},
		{Type: tea.KeyRunes, Runes: []rune("y"), Paste: true},
	} {
		rep, m := newScreen(nil)
		answered := make(chan bool, 1)
		go func() { answered <- rep.Confirm(context.Background(), "Upgrade to 0.2.0?") }()
		deliver(t, rep, m)
		m.Update(key)
		select {
		case answer := <-answered:
			if answer {
				t.Fatalf("%q at a [y/N] question answered yes", key.String())
			}
		case <-time.After(2 * time.Second):
			t.Fatalf("%q: Confirm never returned", key.String())
		}
	}
}

// visibleWidth is the width a line of the view takes on the terminal.
func visibleWidth(line string) int { return lipgloss.Width(line) }

// A question longer than the window is wrapped to it, and so are a step
// detail and the error, instead of being cut at the edge by the renderer:
// the end of the rollback question, what happens to the data and [y/N],
// is what the answer is given on.
func TestLongLinesWrapToTheWindow(t *testing.T) {
	question := "Roll back to 1.0.0 and replay backup-1.0.0-20261007-005419.tar, taken 2026-10-07 00:54 UTC? What was written to the database since then is replaced; a backup of it is taken first"
	for _, width := range []int{80, 100, 40} {
		rep, m := newScreen(nil)
		m.Update(tea.WindowSizeMsg{Width: width, Height: 40})
		rep.Event(upgrade.Event{Kind: upgrade.KindStepStart, Step: upgrade.StepCheck, Message: "reading https://github.com/example/stack/releases/latest/download/manifest.json and its signature"})
		go rep.Confirm(context.Background(), question)
		deliver(t, rep, m)
		for !m.asking {
			deliver(t, rep, m)
		}
		view := m.View()
		for _, line := range strings.Split(view, "\n") {
			if w := visibleWidth(line); w > width {
				t.Fatalf("at %d columns a line is %d wide:\n%s", width, w, view)
			}
		}
		flat := strings.Join(strings.Fields(ansiRe.ReplaceAllString(view, "")), " ")
		for _, want := range []string{question + " [y/N]", "manifest.json and its signature"} {
			if !strings.Contains(flat, want) {
				t.Fatalf("at %d columns the screen lacks %q:\n%s", width, want, view)
			}
		}
		m.Update(tea.KeyMsg{Type: tea.KeyRunes, Runes: []rune("n")})
		rep.Event(upgrade.Event{Kind: upgrade.KindDone, Err: errors.New("rollback cancelled: " + question)})
		deliver(t, rep, m)
		view = m.View()
		for _, line := range strings.Split(view, "\n") {
			if w := visibleWidth(line); w > width {
				t.Fatalf("at %d columns the error is %d wide:\n%s", width, w, view)
			}
		}
		if flat := strings.Join(strings.Fields(ansiRe.ReplaceAllString(view, "")), " "); !strings.Contains(flat, "a backup of it is taken first") {
			t.Fatalf("at %d columns the error lost its end:\n%s", width, view)
		}
	}
}

var ansiRe = regexp.MustCompile(`\x1b\[[0-9;]*[A-Za-z]`)

// A terminal that does not know its size, a serial console for one,
// reports a width of 0: the screen keeps the width it assumed and draws
// the question on as few lines as at 80 columns, not one word in ten
// columns per line, until a real size comes.
func TestAnUnknownSizeKeepsTheAssumedWidth(t *testing.T) {
	const question = "Roll back to 1.0.0 and replay backup-1.0.0-20261007-005419.tar, taken 2026-10-07 00:54 UTC?"
	rep, m := newScreen(nil)
	m.Update(tea.WindowSizeMsg{Width: 0, Height: 0})
	go rep.Confirm(context.Background(), question)
	for !m.asking {
		deliver(t, rep, m)
	}
	whole := false
	for _, line := range strings.Split(ansiRe.ReplaceAllString(m.View(), ""), "\n") {
		if w := visibleWidth(line); w > 80 {
			t.Fatalf("a line is %d wide on a screen of no size:\n%s", w, m.View())
		}
		whole = whole || strings.Contains(line, "Roll back to 1.0.0 and replay")
	}
	if !whole {
		t.Fatalf("the question is wrapped to the width of no size:\n%s", m.View())
	}
	m.Update(tea.WindowSizeMsg{Width: 40, Height: 20})
	for _, line := range strings.Split(m.View(), "\n") {
		if w := visibleWidth(line); w > 40 {
			t.Fatalf("the size that came later is not used: a line is %d wide:\n%s", w, m.View())
		}
	}
	m.Update(tea.KeyMsg{Type: tea.KeyRunes, Runes: []rune("n")})
}

// A run refused before its first step after the check, a downgrade or a
// plan whose release vanished, ends the screen with the lines it logged
// above it: the last screen draws no log lines, so the preface must not
// stay in their window.
func TestAPrefaceTheRunNeverWentPastIsPrinted(t *testing.T) {
	rep, m := newScreen(nil)
	rep.Event(upgrade.Event{Kind: upgrade.KindStepStart, Step: upgrade.StepCheck, Message: "reading the manifest"})
	rep.Event(upgrade.Event{Kind: upgrade.KindStepDone, Step: upgrade.StepCheck, Message: "1.1.0 available"})
	rep.Event(upgrade.Event{Kind: upgrade.KindLog, Message: "1.1.0: notes of 1.1.0"})
	rep.Event(upgrade.Event{Kind: upgrade.KindLog, Message: "the database changes (1.1.0): a rollback replays the backup"})
	rep.Event(upgrade.Event{Kind: upgrade.KindDone, Err: errors.New("refused")})
	out, _, _ := runProgram(t, rep, m)
	waitOutput(t, out, "1.1.0: notes of 1.1.0")
	waitOutput(t, out, "the database changes (1.1.0): a rollback replays the backup")
}

func TestWrap(t *testing.T) {
	cases := []struct {
		text        string
		first, rest int
		want        []string
	}{
		{"one two three", 20, 20, []string{"one two three"}},
		{"one two three", 7, 7, []string{"one two", "three"}},
		{"aaaa bbbb cccc dddd eeee", 10, 14, []string{"aaaa bbbb", "cccc dddd eeee"}},
		// A word wider than the line is cut where the line ends.
		{"https://example.com/a/long/path/to/the/notes", 10, 20, []string{"https://ex", "ample.com/a/long/pat", "h/to/the/notes"}},
		// Columns, not bytes: an accent is one column, a CJK character two.
		{"ééééé ééééé", 5, 5, []string{"ééééé", "ééééé"}},
		// The arrow and the dot of the screen take three and two bytes for
		// one column each: the line fits its 21 columns whole.
		{"1.0.0 → 1.1.0 · nginx", 21, 21, []string{"1.0.0 → 1.1.0 · nginx"}},
		{"日本語の説明", 10, 10, []string{"日本語の説", "明"}},
		// Nothing gets narrower than minWrap.
		{"abcdefghijklmnop", 2, 2, []string{"abcdefghij", "klmnop"}},
		{"", 10, 10, []string{""}},
	}
	for _, c := range cases {
		if got := wrap(c.text, c.first, c.rest); strings.Join(got, "|") != strings.Join(c.want, "|") {
			t.Errorf("wrap(%q, %d, %d) = %q, want %q", c.text, c.first, c.rest, got, c.want)
		}
	}
}

// The notes of every release an upgrade installs, the ones it skips
// included, its highlights, the link to the changelog and what happens to
// the database are what the question is answered on. They go above the
// screen in full, in the order the run gave them, rather than through the
// window of the last six log lines, cut at the width of the terminal: once
// the confirmation starts, at a question no step announced, and with --yes
// once the backup starts.
func TestNotesGoAboveTheScreenInFull(t *testing.T) {
	notes := []string{
		"26.11.0: notes of 26.11.0",
		"26.12.0: notes of 26.12.0",
		"27.1.0: notes of 27.1.0",
		"27.2.0: notes of 27.2.0",
		"  - Nginx 1.29",
		"  - PHP images rebuilt",
		"release notes: https://github.com/example/stack/releases/tag/27.2.0 and the long tail of that line",
		"the database changes (27.2.0): a rollback replays the backup",
	}
	for _, c := range []struct {
		name string
		// step is the step that starts after the notes, "" for none;
		// ask is whether the run then asks.
		step string
		ask  bool
	}{
		{"after the confirmation starts", upgrade.StepConfirm, true},
		{"at a question alone", "", true},
		{"once the backup starts, with --yes", upgrade.StepBackup, false},
	} {
		t.Run(c.name, func(t *testing.T) {
			rep, m := newScreen(nil)
			rep.Event(upgrade.Event{Kind: upgrade.KindStepStart, Step: upgrade.StepCheck, Message: "reading the manifest"})
			rep.Event(upgrade.Event{Kind: upgrade.KindStepDone, Step: upgrade.StepCheck, Message: "27.2.0 available"})
			for _, line := range notes {
				rep.Event(upgrade.Event{Kind: upgrade.KindLog, Message: line})
			}
			if c.step != "" {
				rep.Event(upgrade.Event{Kind: upgrade.KindStepStart, Step: c.step, Message: "next"})
			}
			answered := make(chan bool, 1)
			if c.ask {
				go func() { answered <- rep.Confirm(context.Background(), "Upgrade?") }()
			}
			out, program, _ := runProgram(t, rep, m)
			// The window draws a line cut at the width, above the screen
			// it is printed whole.
			last := notes[6]
			if c.ask {
				last = "[y/N]"
			}
			waitOutput(t, out, last)
			text := out.String()
			at := 0
			for _, line := range notes {
				i := strings.Index(text[at:], line)
				if i < 0 {
					t.Fatalf("%q is not above the screen, in full and in order:\n%s", line, text)
				}
				at += i + len(line)
			}
			if !c.ask {
				// The backup runs: the program draws its spinner, and the
				// view is not read while it does.
				return
			}
			if strings.LastIndex(text, "[y/N]") < at {
				t.Fatalf("the notes come after the question:\n%s", text)
			}
			if view := m.View(); strings.Contains(view, "notes of 27.1.0") {
				t.Fatalf("the screen still draws the notes printed above it:\n%s", view)
			}
			program.Send(tea.KeyMsg{Type: tea.KeyRunes, Runes: []rune("n")})
			if <-answered {
				t.Fatal("answered yes")
			}
		})
	}
}

// Detach hands the events the screen never showed to the fallback, in
// order, and every later one after them.
func TestDetachForwardsInOrder(t *testing.T) {
	fallback := &recorder{}
	rep, _ := newScreen(fallback)
	rep.Event(upgrade.Event{Kind: upgrade.KindLog, Message: "one"})
	rep.Event(upgrade.Event{Kind: upgrade.KindLog, Message: "two"})
	rep.Detach()
	rep.Detach()
	rep.Event(upgrade.Event{Kind: upgrade.KindLog, Message: "three"})
	if got := strings.Join(fallback.messages(), ","); got != "one,two,three" {
		t.Fatalf("the fallback got %s", got)
	}
}

// TestEventNeverBlocks covers the upgrade that stalled behind a full event
// buffer when the screen stopped reading: the runner never waits for it.
func TestEventNeverBlocks(t *testing.T) {
	rep, _ := newScreen(nil)
	done := make(chan struct{})
	go func() {
		for i := 0; i < 10000; i++ {
			rep.Event(upgrade.Event{Kind: upgrade.KindLog, Message: "line"})
		}
		close(done)
	}()
	select {
	case <-done:
	case <-time.After(5 * time.Second):
		t.Fatal("Event blocked on a screen that does not read")
	}
}

// runProgram runs the screen of rep and m as the program kvsctl runs,
// with no terminal: its output, escapes included, goes to the buffer it
// returns, and ended is closed once the program is over.
func runProgram(t *testing.T, rep *TerminalReporter, m *Model) (out *screenOutput, program *tea.Program, ended chan error) {
	t.Helper()
	out = &screenOutput{}
	program = tea.NewProgram(m, tea.WithInput(nil), tea.WithOutput(out), tea.WithoutSignalHandler())
	ended = make(chan error, 1)
	go func() {
		_, err := program.Run()
		ended <- err
	}()
	t.Cleanup(func() {
		rep.Close()
		select {
		case <-ended:
		case <-time.After(5 * time.Second):
			program.Kill()
		}
	})
	return out, program, ended
}

// screenOutput is what a program wrote, read while it writes.
type screenOutput struct {
	mu  sync.Mutex
	buf bytes.Buffer
}

func (s *screenOutput) Write(p []byte) (int, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	return s.buf.Write(p)
}

func (s *screenOutput) String() string {
	s.mu.Lock()
	defer s.mu.Unlock()
	return s.buf.String()
}

// waitOutput waits until the output of the program holds want.
func waitOutput(t *testing.T, out *screenOutput, want string) {
	t.Helper()
	deadline := time.Now().Add(5 * time.Second)
	for !strings.Contains(out.String(), want) {
		if time.Now().After(deadline) {
			t.Fatalf("the screen never showed %q:\n%s", want, out.String())
		}
		time.Sleep(10 * time.Millisecond)
	}
}

// The title and the run log go above the screen, where the terminal keeps
// them, for an operator who wants to follow the log elsewhere or read it
// later.
func TestTitleAndLogAboveTheScreen(t *testing.T) {
	rep, m := newScreen(nil)
	out, _, _ := runProgram(t, rep, m)
	waitOutput(t, out, "log: /opt/kvs/kvsctl/logs/run.log")
	if text := out.String(); strings.Index(text, "title") > strings.Index(text, "log: ") {
		t.Fatalf("the log comes before the title:\n%s", text)
	}
	if view := m.View(); strings.Contains(view, "log: ") {
		t.Fatalf("the screen draws the log again:\n%s", view)
	}
}

func TestStepTitleOfRecord(t *testing.T) {
	if got := StepTitle(upgrade.StepRecord); got == upgrade.StepRecord {
		t.Fatalf("the record step has no title: %q", got)
	}
	if got := StepTitle("unknown"); got != "unknown" {
		t.Fatalf("an unknown step reads %q", got)
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
	p.Event(upgrade.Event{Kind: upgrade.KindImages, Total: dockerx.Progress{Current: 2, Total: 2, Done: true}})
	p.Event(upgrade.Event{Kind: upgrade.KindStepFail, Step: upgrade.StepVerify, Message: "GET / answered 500"})
	p.Notice("SIGINT: the rollback is running and is not interrupted")
	p.Event(upgrade.Event{Kind: upgrade.KindLog, Message: "nginx could not be started again: no space left on device; run 'docker compose start nginx' in /opt/kvs/docker", Notice: true})
	text := out.String()
	if strings.Contains(text, "a compose line") || strings.Contains(text, "ghcr.io") || strings.Contains(text, "all images pulled") {
		t.Fatalf("quiet printed logs or image progress:\n%s", text)
	}
	for _, want := range []string{"4 images", "GET / answered 500", "is not interrupted", "    nginx could not be started again: no space left on device; run 'docker compose start nginx' in /opt/kvs/docker\n"} {
		if !strings.Contains(text, want) {
			t.Fatalf("quiet dropped %q:\n%s", want, text)
		}
	}
}

// A quiet run that asks prints, before its question, what it logged until
// then: the services with their versions and what they download, the notes
// of every release it installs, and what happens to the database, in the
// order the run gave them, as a run that is not quiet does. After the
// question the lines are dropped again. A run that asks nothing, --yes or
// no terminal to read the answer from, prints none of them.
func TestPlainQuietShowsWhatItAsksAbout(t *testing.T) {
	before := []upgrade.Event{
		{Kind: upgrade.KindStepStart, Step: upgrade.StepCheck, Message: "manifest"},
		{Kind: upgrade.KindStepDone, Step: upgrade.StepCheck, Message: "1.3.0 available, manifest signature verified"},
		{Kind: upgrade.KindImage, Step: upgrade.StepPull, Image: "r/nginx:1.3.0", Service: "nginx", From: "1.0.0", To: "1.3.0", Progress: dockerx.Progress{Total: 2048}},
		{Kind: upgrade.KindLog, Message: "1.1.0: Nginx 1.29"},
		{Kind: upgrade.KindLog, Message: "1.2.0: PHP images rebuilt"},
		{Kind: upgrade.KindLog, Message: "the database changes (1.2.0): a rollback replays the backup"},
		{Kind: upgrade.KindStepStart, Step: upgrade.StepConfirm, Message: "Upgrade from 1.0.0 to 1.3.0?"},
	}
	held := []string{"nginx      1.0.0 -> 1.3.0", "1.1.0: Nginx 1.29", "1.2.0: PHP images rebuilt", "the database changes (1.2.0)"}
	run := func(in io.Reader, yes bool) string {
		var out, errOut bytes.Buffer
		p := NewPlain(&out, in, yes)
		p.Err, p.Quiet = &errOut, true
		for _, e := range before {
			p.Event(e)
		}
		p.Confirm(context.Background(), "example.com: upgrade from 1.0.0 to 1.3.0 (2 kB to download)?")
		p.Event(upgrade.Event{Kind: upgrade.KindLog, Message: "a compose line"})
		p.Event(upgrade.Event{Kind: upgrade.KindImage, Step: upgrade.StepPull, Image: "r/nginx:1.3.0", Service: "nginx", From: "1.0.0", To: "1.3.0", Progress: dockerx.Progress{Current: 2048, Total: 2048, Done: true}})
		// A later question has nothing of what came after the first.
		p.Confirm(context.Background(), "a second question?")
		return out.String()
	}
	text := run(strings.NewReader("n\nn\n"), false)
	at := 0
	for _, line := range append(held, "==> Confirmation: Upgrade from 1.0.0 to 1.3.0?", "[y/N]") {
		i := strings.Index(text[at:], line)
		if i < 0 {
			t.Fatalf("%q is not before the question, in order:\n%s", line, text)
		}
		at += i + len(line)
	}
	if strings.Contains(text, "a compose line") || strings.Contains(text, "100%") {
		t.Fatalf("the lines after the question are printed:\n%s", text)
	}
	// A run that asks nothing gets its confirmation step all the same,
	// which prints nothing it held: the step comes, the question does not.
	for name, text := range map[string]string{"--yes": run(strings.NewReader(""), true), "no terminal": run(nil, false)} {
		for _, line := range held {
			if strings.Contains(text, line) {
				t.Errorf("with %s, a quiet run printed %q:\n%s", name, line, text)
			}
		}
	}
	// A question asked without its step first still comes after what it
	// is about.
	before = before[:len(before)-1]
	text = run(strings.NewReader("n\nn\n"), false)
	at = 0
	for _, line := range append(held, "[y/N]") {
		i := strings.Index(text[at:], line)
		if i < 0 {
			t.Fatalf("%q is not before a question asked without its step, in order:\n%s", line, text)
		}
		at += i + len(line)
	}
	if strings.Contains(text, "a compose line") || strings.Contains(text, "100%") {
		t.Fatalf("the lines after a question asked without its step are printed:\n%s", text)
	}
}

// The error of a docker command that wrote nothing on stderr ends with
// the separator it left for it, or has it before what a caller added: a
// failure shows without it, on the screen and in plain lines, and any
// other text is left as it is.
func TestFailuresDropAnEmptyDetail(t *testing.T) {
	const raw = "docker exec kvs-mariadb: context canceled (signal: terminated): "
	const want = "docker exec kvs-mariadb: context canceled (signal: terminated)"
	for in, out := range map[string]string{
		raw: want,
		"backup of the live database: docker exec kvs-mariadb: exit status 1: ; still on 1.1.0": "backup of the live database: docker exec kvs-mariadb: exit status 1; still on 1.1.0",
		"compose up: exit status 1: no such service: php":                                       "compose up: exit status 1: no such service: php",
		"not healthy after 1s: kvs-nginx is unhealthy":                                          "not healthy after 1s: kvs-nginx is unhealthy",
	} {
		if got := Clean(in); got != out {
			t.Errorf("Clean(%q) = %q, want %q", in, got, out)
		}
	}

	rep, m := newScreen(nil)
	m.width = 200
	rep.Event(upgrade.Event{Kind: upgrade.KindStepFail, Step: upgrade.StepBackup, Message: raw})
	rep.Event(upgrade.Event{Kind: upgrade.KindDone, Err: errors.New("backup: " + raw)})
	deliver(t, rep, m)
	view := m.View()
	for _, line := range []string{"Backup " + want + "\n", " ✗ backup: " + want + "\n"} {
		if !strings.Contains(view, line) {
			t.Errorf("the screen lacks %q:\n%s", line, view)
		}
	}

	// Plain lines say the failure of the step; the failure of the run is
	// the last line of kvsctl, on stderr, and only there.
	var plain bytes.Buffer
	p := NewPlain(&plain, nil, true)
	p.Event(upgrade.Event{Kind: upgrade.KindStepFail, Step: upgrade.StepBackup, Message: raw})
	p.Event(upgrade.Event{Kind: upgrade.KindDone, Err: errors.New("backup: " + raw)})
	if got, lines := plain.String(), "    FAILED: "+want+"\n"; got != lines {
		t.Errorf("plain printed %q, want %q", got, lines)
	}
	plain.Reset()
	p.Event(upgrade.Event{Kind: upgrade.KindDone})
	if got := plain.String(); got != "==> Done\n" {
		t.Errorf("a run that worked ends with %q", got)
	}
}

// failingWriter is a terminal that went away.
type failingWriter struct{ calls int }

func (w *failingWriter) Write([]byte) (int, error) {
	w.calls++
	return 0, errors.New("write /dev/stdout: input/output error")
}

// A line that cannot be written is dropped and the run goes on: a closed
// SSH session must not stop an upgrade.
func TestPlainIgnoresWriteErrors(t *testing.T) {
	w := &failingWriter{}
	p := NewPlain(w, nil, false)
	p.Err = w
	p.Event(upgrade.Event{Kind: upgrade.KindStepStart, Step: upgrade.StepRestart, Message: "docker compose up"})
	p.Event(upgrade.Event{Kind: upgrade.KindDone})
	if p.Confirm(context.Background(), "Upgrade?") {
		t.Fatal("a reporter without input said yes")
	}
	if w.calls == 0 {
		t.Fatal("nothing was written")
	}
}

// Without a terminal to read the answer from, a question is answered no
// at once, on stderr, with what to pass to answer yes: the output, a file
// or a pipe, does not get a question nobody reads, and nothing waits.
func TestPlainAnswersNoWithoutATerminal(t *testing.T) {
	var out, errOut bytes.Buffer
	p := NewPlain(&out, nil, false)
	p.Err = &errOut
	answered := make(chan bool, 1)
	go func() { answered <- p.Confirm(context.Background(), "Roll back to 1.0.0?") }()
	select {
	case answer := <-answered:
		if answer {
			t.Fatal("answered yes without a terminal")
		}
	case <-time.After(2 * time.Second):
		t.Fatal("the question waited without a terminal")
	}
	if out.Len() != 0 {
		t.Fatalf("the question went to the output:\n%s", out.String())
	}
	want := "Roll back to 1.0.0? [y/N] no: kvsctl asks only when stdin and stdout are both a terminal; pass --yes to answer yes\n"
	if errOut.String() != want {
		t.Fatalf("stderr reads %q, want %q", errOut.String(), want)
	}
}

// A question given up when the context ended leaves the next line to the
// next question: the reader of the abandoned one must not swallow it.
func TestPlainConfirmHonoursTheContext(t *testing.T) {
	in, typed := io.Pipe()
	defer typed.Close()
	var out bytes.Buffer
	p := NewPlain(&syncWriter{w: &out}, in, false)
	ctx, cancel := context.WithCancel(context.Background())
	answered := make(chan bool, 1)
	go func() { answered <- p.Confirm(ctx, "Roll back?") }()
	time.Sleep(20 * time.Millisecond)
	cancel()
	select {
	case answer := <-answered:
		if answer {
			t.Fatal("a cancelled question answered yes")
		}
	case <-time.After(2 * time.Second):
		t.Fatal("Confirm outlived its context")
	}
	go func() { _, _ = io.WriteString(typed, "y\n") }()
	if !p.Confirm(context.Background(), "Restore?") {
		t.Fatal("the next question lost the line typed for it")
	}
}

func TestPlainLine(t *testing.T) {
	p := NewPlain(io.Discard, strings.NewReader("2\r\nlast"), false)
	for _, want := range []string{"2", "last"} {
		got, err := p.Line(context.Background(), "? ")
		if err != nil || got != want {
			t.Fatalf("Line = %q, %v; wanted %q", got, err, want)
		}
	}
	if _, err := p.Line(context.Background(), "? "); !errors.Is(err, io.EOF) {
		t.Fatalf("the end of the input reads %v", err)
	}
	if _, err := NewPlain(io.Discard, nil, false).Line(context.Background(), "? "); !errors.Is(err, ErrNoInput) {
		t.Fatalf("no input reads %v", err)
	}
}

// syncWriter serialises the writes the test and the reporter make.
type syncWriter struct {
	mu sync.Mutex
	w  io.Writer
}

func (s *syncWriter) Write(p []byte) (int, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	return s.w.Write(p)
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
	_, m := newScreen(nil)
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
