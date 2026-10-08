// Package ui shows an upgrade in the terminal: steps, one progress bar per
// image, the last log lines, and the questions, with bubbletea. Plain
// draws the same events as lines when there is no terminal.
package ui

import (
	"bufio"
	"context"
	"errors"
	"fmt"
	"io"
	"os"
	"slices"
	"strings"
	"sync"
	"unicode/utf8"

	"github.com/charmbracelet/bubbles/progress"
	"github.com/charmbracelet/bubbles/spinner"
	tea "github.com/charmbracelet/bubbletea"
	"github.com/charmbracelet/lipgloss"
	"golang.org/x/term"

	"github.com/MaximeMichaud/KVS-install/cli/internal/upgrade"
)

var (
	titleStyle = lipgloss.NewStyle().Bold(true)
	dimStyle   = lipgloss.NewStyle().Faint(true)
	okStyle    = lipgloss.NewStyle().Foreground(lipgloss.Color("2"))
	failStyle  = lipgloss.NewStyle().Foreground(lipgloss.Color("1"))
	askStyle   = lipgloss.NewStyle().Foreground(lipgloss.Color("3")).Bold(true)
)

var stepTitles = map[string]string{
	upgrade.StepCheck:   "Checking for updates",
	upgrade.StepConfirm: "Confirmation",
	upgrade.StepBackup:  "Backup",
	upgrade.StepPull:    "Pulling images",
	upgrade.StepApply:   "Applying release files",
	upgrade.StepRestart: "Restarting services",
	upgrade.StepVerify:  "Verifying",
	upgrade.StepRecord:  "Recording the run",
	upgrade.StepRollbck: "Rolling back",
	upgrade.StepRestore: "Restoring the database",
}

// StepTitle is the name the screen and the plain lines give a step.
func StepTitle(step string) string {
	if title, ok := stepTitles[step]; ok {
		return title
	}
	return step
}

type stepState struct {
	status string // pending, running, done, failed, skipped
	detail string
}

type imageState struct {
	key      string
	ref      string
	service  string
	versions string
	note     string
	progress upgrade.Event
	bar      progress.Model
}

// Model is the bubbletea model of one upgrade, rollback or recovery.
type Model struct {
	reporter *TerminalReporter
	// interrupt is what Ctrl-C does: the first one cancels the run, a
	// later one only says that the run finishes what it started. It
	// returns the line to show.
	interrupt func() string
	spinner   spinner.Model
	steps     map[string]*stepState
	order     []string
	pending   []string
	images    []*imageState
	total     upgrade.Event
	logs      []string
	// preface holds the lines the run logs before its first step after
	// the check: the notes of every release an upgrade installs, what
	// happens to the database, the services it leaves out. They are what
	// the question is answered on, so they go above the screen in full
	// once that step starts or the question comes, where they stay: the
	// window of the last log lines would show six of them, cut at the
	// width of the terminal.
	preface     []string
	prefaceDone bool
	// above waits to be printed above the screen, where a line is never
	// cut and stays in the scrollback: the title and the log of the run
	// first, then the preface.
	above    []string
	question string
	asking   bool
	// done is set by the event that ends the run, err is its outcome;
	// ended is set when the event stream closed, with or without it.
	done  bool
	err   error
	ended bool
	width int
}

// wakeMsg tells the screen that events wait in the queue, or that the
// stream closed.
type wakeMsg struct{}

// TerminalReporter feeds the model from the goroutines of the run. Events
// wait in a queue the screen empties each time it wakes up, so the run
// never waits for the screen: a terminal that stopped reading, over an SSH
// link that hangs, must not hold an upgrade or its rollback. Once the
// screen is gone (Detach), the events go to the fallback reporter instead,
// in the order they came.
type TerminalReporter struct {
	mu       sync.Mutex
	queue    []upgrade.Event
	closed   bool
	detached bool
	// wake holds one token: an event or the end of the stream is waiting.
	wake chan struct{}
	// gone is closed when the screen ends.
	gone chan struct{}
	// answers holds one reply, so the screen never blocks on a Confirm
	// that already gave up.
	answers chan bool
	// out keeps the lines of the fallback in order: the events left in the
	// queue when the screen went are handed over before the later ones.
	out      sync.Mutex
	fallback upgrade.Reporter
}

var _ upgrade.Reporter = (*TerminalReporter)(nil)

// NewTerminal builds a reporter and the model that displays it. steps are
// the steps the action will run, shown as pending until they start, and
// logPath the run log, printed under the title. interrupt is called on
// Ctrl-C and returns the line to show. fallback receives the events once
// the screen is gone; it may be nil, and they are then dropped.
func NewTerminal(title, logPath string, steps []string, interrupt func() string, fallback upgrade.Reporter) (*TerminalReporter, *Model) {
	rep := &TerminalReporter{
		wake:     make(chan struct{}, 1),
		gone:     make(chan struct{}),
		answers:  make(chan bool, 1),
		fallback: fallback,
	}
	sp := spinner.New(spinner.WithSpinner(spinner.Dot))
	m := &Model{
		reporter:  rep,
		interrupt: interrupt,
		spinner:   sp,
		steps:     map[string]*stepState{},
		pending:   steps,
		width:     80,
		above:     []string{titleStyle.Render(title)},
	}
	if logPath != "" {
		m.above = append(m.above, dimStyle.Render("log: "+logPath))
	}
	return rep, m
}

// Event implements upgrade.Reporter. It never blocks on the screen: the
// event joins the queue, or goes to the fallback once the screen is gone.
func (r *TerminalReporter) Event(e upgrade.Event) {
	r.mu.Lock()
	if !r.detached {
		r.queue = append(r.queue, e)
		r.mu.Unlock()
		r.signal()
		return
	}
	r.mu.Unlock()
	r.forward(e)
}

// forward hands an event to the fallback, one at a time.
func (r *TerminalReporter) forward(e upgrade.Event) {
	if r.fallback == nil {
		return
	}
	r.out.Lock()
	defer r.out.Unlock()
	r.fallback.Event(e)
}

func (r *TerminalReporter) signal() {
	select {
	case r.wake <- struct{}{}:
	default:
	}
}

// Confirm implements upgrade.Reporter. It blocks until the user answers,
// the context ends or the screen goes, and answers no in the last two
// cases: nobody is left to say yes.
func (r *TerminalReporter) Confirm(ctx context.Context, question string) bool {
	r.mu.Lock()
	detached := r.detached
	r.mu.Unlock()
	if detached {
		return false
	}
	r.Event(upgrade.Event{Kind: upgrade.KindLog, Step: upgrade.StepConfirm, Message: "?" + question})
	select {
	case answer := <-r.answers:
		return answer
	case <-ctx.Done():
		return false
	case <-r.gone:
		return false
	}
}

// Close ends the event stream once the action returned. The screen shows
// what is left in the queue and ends.
func (r *TerminalReporter) Close() {
	r.mu.Lock()
	r.closed = true
	r.mu.Unlock()
	r.signal()
}

// Detach tells the reporter the screen has ended, whatever the reason: the
// run is over, the terminal went away, or the screen failed. The events
// still in the queue and every later one go to the fallback, and a pending
// question is answered no. It can be called more than once.
func (r *TerminalReporter) Detach() {
	r.out.Lock()
	defer r.out.Unlock()
	r.mu.Lock()
	if r.detached {
		r.mu.Unlock()
		return
	}
	r.detached = true
	left := r.queue
	r.queue = nil
	r.mu.Unlock()
	close(r.gone)
	if r.fallback == nil {
		return
	}
	for _, e := range left {
		r.fallback.Event(e)
	}
}

// take empties the queue for the screen, and says whether the stream is
// closed.
func (r *TerminalReporter) take() ([]upgrade.Event, bool) {
	r.mu.Lock()
	defer r.mu.Unlock()
	events := r.queue
	r.queue = nil
	return events, r.closed
}

// waitWake waits for events, or for the end of the screen, in which case
// it brings nothing: the events are the fallback's from then on.
func (r *TerminalReporter) waitWake() tea.Cmd {
	return func() tea.Msg {
		select {
		case <-r.wake:
			return wakeMsg{}
		case <-r.gone:
			return nil
		}
	}
}

// Init prints the title and the log above the screen, and starts the
// spinner and the event loop.
func (m *Model) Init() tea.Cmd {
	return tea.Batch(m.spinner.Tick, m.printAbove(m.reporter.waitWake()))
}

// printAbove prints what waits above the screen, then runs next. The two
// run in sequence, so the lines of one wake are printed before the events
// of the next are even taken, and come out in the order the run gave them.
func (m *Model) printAbove(next tea.Cmd) tea.Cmd {
	if len(m.above) == 0 {
		return next
	}
	lines := strings.Join(m.above, "\n")
	m.above = nil
	return tea.Sequence(tea.Println(lines), next)
}

// Update handles events and keys.
func (m *Model) Update(msg tea.Msg) (tea.Model, tea.Cmd) {
	switch msg := msg.(type) {
	case tea.WindowSizeMsg:
		// A terminal that does not know its size, a serial console for
		// one, reports 0: the width stays the one assumed until a real
		// size comes, rather than a wrap at minWrap columns.
		if msg.Width > 0 {
			m.width = msg.Width
		}
		return m, nil
	case tea.KeyMsg:
		switch {
		case msg.Type == tea.KeyCtrlC:
			m.answer(false)
			if m.interrupt != nil {
				if line := m.interrupt(); line != "" {
					m.addLog(line)
				}
			}
			return m, nil
		case m.asking:
			// Only a y says yes. Enter gives the answer the capital N of
			// [y/N] names, and so does any other key, as any other reply
			// does in plain mode.
			m.answer(strings.ToLower(msg.String()) == "y")
		}
		return m, nil
	case spinner.TickMsg:
		var cmd tea.Cmd
		m.spinner, cmd = m.spinner.Update(msg)
		return m, cmd
	case wakeMsg:
		events, closed := m.reporter.take()
		for _, e := range events {
			m.apply(e)
		}
		if closed {
			m.ended = true
		}
		if m.done || m.ended {
			return m.quit()
		}
		return m, m.printAbove(m.reporter.waitWake())
	}
	return m, nil
}

// answer replies to a pending question without ever blocking: the reply
// waits in the buffered channel until Confirm reads it, and a Confirm
// that already gave up leaves it there.
func (m *Model) answer(value bool) {
	if !m.asking {
		return
	}
	m.asking = false
	select {
	case m.reporter.answers <- value:
	default:
	}
}

// quit ends the screen once the run is over. A question still on screen is
// answered no, and the reporter is detached, so what comes after goes to
// the fallback rather than to a screen that is gone. A preface the run
// never went past, a run refused before its first step, is printed first:
// the last screen keeps no log lines.
func (m *Model) quit() (tea.Model, tea.Cmd) {
	m.answer(false)
	m.reporter.Detach()
	m.endPreface()
	return m, m.printAbove(tea.Quit)
}

func (m *Model) addLog(line string) {
	m.logs = append(m.logs, line)
	if len(m.logs) > 6 {
		m.logs = m.logs[len(m.logs)-6:]
	}
}

// endPreface moves the lines logged before the first step after the check,
// or before the question, above the screen, and out of the window of the
// last log lines, which showed them until then.
func (m *Model) endPreface() {
	if m.prefaceDone {
		return
	}
	m.prefaceDone = true
	if len(m.preface) == 0 {
		return
	}
	for _, line := range m.preface {
		m.above = append(m.above, "   "+line)
	}
	m.logs = slices.DeleteFunc(m.logs, func(line string) bool { return slices.Contains(m.preface, line) })
}

func (m *Model) step(name string) *stepState {
	s := m.steps[name]
	if s == nil {
		s = &stepState{status: "pending"}
		m.steps[name] = s
		m.order = append(m.order, name)
	}
	return s
}

func (m *Model) apply(e upgrade.Event) {
	switch e.Kind {
	case upgrade.KindStepStart:
		if e.Step != upgrade.StepCheck {
			m.endPreface()
		}
		s := m.step(e.Step)
		s.status, s.detail = "running", e.Message
	case upgrade.KindStepDone:
		s := m.step(e.Step)
		s.status, s.detail = "done", e.Message
		if e.Step == upgrade.StepBackup && e.Message == "skipped" {
			s.status = "skipped"
		}
	case upgrade.KindStepFail:
		s := m.step(e.Step)
		s.status, s.detail = "failed", Clean(e.Message)
	case upgrade.KindLog:
		if e.Step == upgrade.StepConfirm && strings.HasPrefix(e.Message, "?") {
			// A question ends the preface even when no step started
			// before it: what it asks about is above it, in full.
			m.endPreface()
			m.question, m.asking = e.Message[1:], true
			return
		}
		if !m.prefaceDone {
			m.preface = append(m.preface, e.Message)
		}
		m.addLog(e.Message)
	case upgrade.KindImage:
		key := e.Service
		if key == "" {
			key = e.Image
		}
		var img *imageState
		for _, candidate := range m.images {
			if candidate.key == key {
				img = candidate
			}
		}
		if img == nil {
			img = &imageState{key: key, ref: e.Image, service: e.Service, bar: progress.New(progress.WithDefaultGradient(), progress.WithoutPercentage())}
			m.images = append(m.images, img)
		}
		if e.From != "" || e.To != "" {
			img.versions = versionsOf(e.From, e.To)
		}
		if e.Message != "" {
			img.note = e.Message
		}
		img.progress = e
		m.total = e
	case upgrade.KindImages:
		m.total = e
		for _, img := range m.images {
			img.progress.Progress.Done = true
			img.progress.Progress.Current = img.progress.Progress.Total
		}
	case upgrade.KindDone:
		m.done, m.err = true, e.Err
	}
}

// View draws the screen, under the title and the log printed above it.
// Bubble Tea cuts every line at the edge of the window, so what can be
// longer than a terminal, a question above all, is wrapped to its width.
func (m *Model) View() string {
	var b strings.Builder
	b.WriteString("\n")
	shown := map[string]bool{}
	names := append([]string{}, m.order...)
	over := m.done || m.ended
	for _, name := range m.pending {
		if _, ok := m.steps[name]; !ok && !over {
			names = append(names, name)
		}
	}
	for _, name := range names {
		if shown[name] {
			continue
		}
		shown[name] = true
		s := m.steps[name]
		icon, text := "○", dimStyle.Render(StepTitle(name))
		if s != nil {
			switch s.status {
			case "running":
				icon, text = m.spinner.View(), StepTitle(name)
			case "done":
				icon, text = okStyle.Render("✓"), StepTitle(name)
			case "skipped":
				icon, text = dimStyle.Render("–"), dimStyle.Render(StepTitle(name))
			case "failed":
				icon, text = failStyle.Render("✗"), failStyle.Render(StepTitle(name))
			}
		}
		line := fmt.Sprintf(" %s %s", icon, text)
		if s == nil || s.detail == "" {
			b.WriteString(line + "\n")
		} else {
			m.writeWrapped(&b, line+" ", s.detail, dimStyle)
		}
		if name == upgrade.StepPull && len(m.images) > 0 {
			m.renderImages(&b)
		}
		if name == upgrade.StepConfirm && m.asking {
			m.writeWrapped(&b, "   ", m.question+" [y/N]", askStyle)
		}
	}
	if len(m.logs) > 0 && !over {
		b.WriteString("\n")
		for _, l := range m.logs {
			b.WriteString(dimStyle.Render("   "+truncate(l, m.width-4)) + "\n")
		}
	}
	if m.done {
		b.WriteString("\n")
		if m.err != nil {
			m.writeWrapped(&b, failStyle.Render(" ✗ "), Clean(firstLine(m.err.Error())), failStyle)
		} else {
			b.WriteString(okStyle.Render(" ✓ Done") + "\n")
		}
	}
	return b.String()
}

// writeWrapped writes text after prefix, in style, wrapped to the width of
// the window; the lines after the first are indented by three columns,
// under the text of a step.
func (m *Model) writeWrapped(b *strings.Builder, prefix, text string, style lipgloss.Style) {
	const indent = 3
	for i, line := range wrap(text, m.width-lipgloss.Width(prefix), m.width-indent) {
		if i == 0 {
			b.WriteString(prefix)
		} else {
			b.WriteString(strings.Repeat(" ", indent))
		}
		b.WriteString(style.Render(line) + "\n")
	}
}

// minWrap is the narrowest line wrap makes: a window narrower than that
// is cut by the terminal anyway.
const minWrap = 10

// wrap breaks text into lines at spaces, the first one at most first
// columns wide and the others at most rest. A word longer than a line, a
// path or a URL, is cut where the line ends: past the edge of the window
// it would not be drawn at all.
func wrap(text string, first, rest int) []string {
	limit := max(first, minWrap)
	var lines []string
	line := ""
	push := func() {
		lines = append(lines, line)
		line, limit = "", max(rest, minWrap)
	}
	for _, word := range strings.Fields(text) {
		if line != "" {
			if lipgloss.Width(line)+1+lipgloss.Width(word) <= limit {
				line += " " + word
				continue
			}
			push()
		}
		for lipgloss.Width(word) > limit {
			line, word = cutWidth(word, limit)
			push()
		}
		line = word
	}
	return append(lines, line)
}

// cutWidth splits s after n columns, never in the middle of a character.
func cutWidth(s string, n int) (head, tail string) {
	used := 0
	for i, r := range s {
		w := lipgloss.Width(string(r))
		if used+w > n {
			if i == 0 {
				// A character wider than the line still goes on it.
				_, size := utf8.DecodeRuneInString(s)
				return s[:size], s[size:]
			}
			return s[:i], s[i:]
		}
		used += w
	}
	return s, ""
}

// renderImages lists every service of the release with the version it
// runs and the one it will run. Before the pull starts the lines carry the
// size to download; during it, one bar per image; an image that needs no
// download carries its note instead.
func (m *Model) renderImages(b *strings.Builder) {
	nameW, verW := 9, 13
	for _, img := range m.images {
		nameW = max(nameW, len(imageLabel(img)))
		verW = max(verW, len(img.versions))
	}
	nameW, verW = min(nameW, 14), min(verW, 34)
	width := m.width - (nameW + verW + 31)
	if width < 12 {
		width = 12
	}
	pulling := m.steps[upgrade.StepPull] != nil
	for _, img := range m.images {
		p := img.progress.Progress
		prefix := fmt.Sprintf("     %-*s  %-*s", nameW, truncate(imageLabel(img), nameW), verW, truncate(img.versions, verW))
		switch {
		case img.note != "":
			fmt.Fprintf(b, "%s  %s\n", prefix, dimStyle.Render(img.note))
		case !pulling:
			fmt.Fprintf(b, "%s  %s\n", prefix, dimStyle.Render(upgrade.HumanBytes(p.Total)+" to download"))
		default:
			var percent float64
			if p.Total > 0 {
				percent = float64(p.Current) / float64(p.Total)
			}
			if p.Done {
				percent = 1
			}
			img.bar.Width = width
			state := fmt.Sprintf("%3.0f%%  %s / %s", percent*100, upgrade.HumanBytes(p.Current), upgrade.HumanBytes(p.Total))
			if p.Done {
				state = okStyle.Render("✓") + "     " + upgrade.HumanBytes(p.Total)
			}
			fmt.Fprintf(b, "%s  %s  %s\n", prefix, img.bar.ViewAs(percent), state)
		}
	}
	if t := m.total.Total; t.Total > 0 {
		total := fmt.Sprintf("%s / %s", upgrade.HumanBytes(t.Current), upgrade.HumanBytes(t.Total))
		if !pulling {
			total = upgrade.HumanBytes(t.Total) + " to download"
		}
		fmt.Fprintf(b, "     %-*s  %-*s  %s\n", nameW, "total", verW, "", dimStyle.Render(total))
	}
}

// imageLabel is the service name of a row, or the image name when the
// event carried none.
func imageLabel(img *imageState) string {
	if img.service != "" {
		return img.service
	}
	return shortRef(img.ref)
}

// versionsOf writes the move of one image, "0.1.0 → 0.2.0", or the version
// alone when nothing moves.
func versionsOf(from, to string) string {
	if from == to || from == "" {
		return to
	}
	return from + " → " + to
}

func shortRef(ref string) string {
	name := ref
	if i := strings.LastIndex(name, "/"); i >= 0 {
		name = name[i+1:]
	}
	if i := strings.Index(name, "@"); i >= 0 {
		name = name[:i]
	}
	if i := strings.Index(name, ":"); i >= 0 {
		name = name[:i]
	}
	return name
}

// truncate cuts a line to n columns, counting runes: a log line full of
// accents or box drawing would otherwise lose its last character to a cut
// in the middle of a code point.
func truncate(s string, n int) string {
	if n < 4 {
		return s
	}
	runes := []rune(s)
	if len(runes) <= n {
		return s
	}
	return string(runes[:n-1]) + "…"
}

func firstLine(s string) string {
	if i := strings.IndexByte(s, '\n'); i >= 0 {
		return s[:i]
	}
	return s
}

// Clean drops the separator a failure leaves before a detail that is
// empty: the error of a docker command is written "<what>: <stderr>", and
// one that wrote nothing on stderr ends with ": ", or has it before what a
// caller added after a semicolon.
func Clean(msg string) string {
	msg = strings.ReplaceAll(msg, ": ;", ";")
	return strings.TrimRight(strings.TrimSuffix(strings.TrimRight(msg, " "), ":"), " ")
}

// Plain prints events as lines, for logs and automation. It is safe for
// concurrent use: a signal handler may report while the run does. A line
// that cannot be written is dropped: a terminal that went away or a pipe
// whose reader quit must never stop a run, and the run log keeps every
// line anyway.
type Plain struct {
	Out io.Writer
	// Err is where a question that cannot be asked is said, stderr unless
	// set: kvsctl asks only when its input and its output are both a
	// terminal, and an output sent to a file must not end with a question
	// nobody saw.
	Err io.Writer
	In  io.Reader
	Yes bool
	// Quiet drops the image progress, the log lines and the total of the
	// pull, and keeps the steps, the failures, the notices and the
	// questions: what a cron job wants in a mail. A run that asks keeps
	// what it logs before its first question, the services, the notes
	// and what happens to the database, and prints it before that
	// question: a question is never asked without what it is about.
	Quiet bool
	mu    sync.Mutex
	last  map[string]int
	// held are the lines Quiet keeps for the first question, and asked
	// is set once it is asked.
	held  []upgrade.Event
	asked bool
	// lines are the lines of In, read by one goroutine for the life of
	// the reporter. A question given up when its context ended leaves
	// the next line to the next question, rather than to a reader nobody
	// waits on any more.
	reading sync.Once
	lines   chan string
}

// ErrNoInput is the answer of Line when there is nothing to read the
// answer from.
var ErrNoInput = errors.New("no terminal to ask on")

var _ upgrade.Reporter = (*Plain)(nil)

// NewPlain builds a line reporter.
func NewPlain(out io.Writer, in io.Reader, yes bool) *Plain {
	return &Plain{Out: out, In: in, Yes: yes, last: map[string]int{}}
}

// printf writes one line, its error ignored on purpose (see Plain).
func (p *Plain) printf(format string, args ...any) {
	_, _ = fmt.Fprintf(p.Out, format, args...)
}

// Event implements upgrade.Reporter.
func (p *Plain) Event(e upgrade.Event) {
	p.mu.Lock()
	defer p.mu.Unlock()
	switch e.Kind {
	case upgrade.KindStepStart:
		if e.Step == upgrade.StepConfirm {
			p.release()
		}
		p.printf("==> %s: %s\n", StepTitle(e.Step), e.Message)
	case upgrade.KindStepDone:
		p.printf("    done: %s\n", e.Message)
	case upgrade.KindStepFail:
		p.printf("    FAILED: %s\n", Clean(e.Message))
	case upgrade.KindLog, upgrade.KindImage:
		if p.Quiet && !e.Notice {
			p.hold(e)
			return
		}
		p.line(e)
	case upgrade.KindImages:
		if p.Quiet {
			return
		}
		p.printf("    all images pulled (%s)\n", upgrade.HumanBytes(e.Total.Total))
	case upgrade.KindDone:
		// A failure is said once, by the last line of kvsctl on stderr,
		// which names the log when there is one to read and which the
		// scripts that run kvsctl read.
		if e.Err == nil {
			p.printf("==> Done\n")
		}
	}
}

// line prints a log line or the progress of an image.
func (p *Plain) line(e upgrade.Event) {
	if e.Kind == upgrade.KindImage {
		p.image(e)
		return
	}
	p.printf("    %s\n", e.Message)
}

// hold keeps a line Quiet drops for the first question of a run that asks
// one: the run asks it, unless --yes answers it or there is no terminal to
// read the answer from. Once the question is asked, Quiet drops the line.
func (p *Plain) hold(e upgrade.Event) {
	if p.In != nil && !p.Yes && !p.asked {
		p.held = append(p.held, e)
	}
}

// release prints the lines held for the question that comes, and ends the
// holding: what comes after the question, Quiet drops. The caller holds mu.
func (p *Plain) release() {
	for _, e := range p.held {
		p.line(e)
	}
	p.held, p.asked = nil, true
}

// Notice prints a line whatever Quiet says: what kvsctl does about a
// signal is for the operator to see.
func (p *Plain) Notice(line string) {
	p.mu.Lock()
	defer p.mu.Unlock()
	p.printf("    %s\n", line)
}

// image prints the progress of one image every ten percent.
func (p *Plain) image(e upgrade.Event) {
	if p.last == nil {
		p.last = map[string]int{}
	}
	label := e.Image
	if e.Service != "" {
		label = fmt.Sprintf("%-10s %s", e.Service, plainVersions(e.From, e.To))
	}
	pr := e.Progress
	_, seen := p.last[label]
	switch {
	case e.Message != "":
		if !seen {
			p.last[label] = 100
			p.printf("    %-40s %s\n", label, e.Message)
		}
		return
	case !seen && pr.Current == 0 && !pr.Done:
		p.last[label] = 0
		p.printf("    %-40s %s to download\n", label, upgrade.HumanBytes(pr.Total))
		return
	}
	pct := 0
	if pr.Total > 0 {
		pct = int(pr.Current * 100 / pr.Total)
	}
	if pr.Done {
		pct = 100
	}
	if last, ok := p.last[label]; ok && pct/10 == last/10 && !pr.Done {
		return
	}
	p.last[label] = pct
	p.printf("    %-40s %3d%%  %s / %s\n", label, pct, upgrade.HumanBytes(pr.Current), upgrade.HumanBytes(pr.Total))
}

// plainVersions writes the move of one image for a line printer, with an
// ASCII arrow.
func plainVersions(from, to string) string {
	if from == to || from == "" {
		return to
	}
	return from + " -> " + to
}

// Confirm implements upgrade.Reporter through In. A context that ends
// while it waits for the answer, the first Ctrl-C for instance, answers no
// at once. The line typed ahead of a question is kept for it. Without In
// the question is answered no at once, on Err, with how to answer yes:
// nobody reads Out for a question then, a file or a pipe.
func (p *Plain) Confirm(ctx context.Context, question string) bool {
	if p.Yes {
		return true
	}
	if p.In == nil {
		p.mu.Lock()
		defer p.mu.Unlock()
		out := p.Err
		if out == nil {
			out = os.Stderr
		}
		_, _ = fmt.Fprintf(out, "%s [y/N] no: kvsctl asks only when stdin and stdout are both a terminal; pass --yes to answer yes\n", question)
		return false
	}
	// A question asked without its step first still comes after what it
	// is about.
	p.mu.Lock()
	p.release()
	p.mu.Unlock()
	line, err := p.Line(ctx, question+" [y/N] ")
	if err != nil {
		return false
	}
	reply := strings.ToLower(strings.TrimSpace(line))
	return reply == "y" || reply == "yes"
}

// Line prints prompt and returns the next line of In, without its line
// end. It returns ErrNoInput without In, io.EOF once In has ended, and the
// error of ctx when ctx ends first.
func (p *Plain) Line(ctx context.Context, prompt string) (string, error) {
	p.mu.Lock()
	p.printf("%s", prompt)
	if p.In == nil {
		p.printf("\n")
		p.mu.Unlock()
		return "", ErrNoInput
	}
	p.reading.Do(p.startReading)
	p.mu.Unlock()
	select {
	case line, ok := <-p.lines:
		if !ok {
			p.mu.Lock()
			p.printf("\n")
			p.mu.Unlock()
			return "", io.EOF
		}
		return strings.TrimRight(line, "\r\n"), nil
	case <-ctx.Done():
		p.mu.Lock()
		p.printf("\n")
		p.mu.Unlock()
		return "", ctx.Err()
	}
}

// startReading reads In line by line until it ends. The read cannot be
// cancelled, so the goroutine lives as long as In does: a line read while
// no question waits is kept for the next one.
func (p *Plain) startReading() {
	p.lines = make(chan string)
	go func() {
		defer close(p.lines)
		r := bufio.NewReader(p.In)
		for {
			line, err := r.ReadString('\n')
			if line != "" {
				p.lines <- line
			}
			if err != nil {
				return
			}
		}
	}()
}

// IsTerminal reports whether f is an interactive terminal. A character
// device is not enough: /dev/null is one, and `kvsctl upgrade </dev/null`
// would open a screen waiting for a keypress that can never come.
func IsTerminal(f *os.File) bool {
	if f == nil {
		return false
	}
	return term.IsTerminal(int(f.Fd()))
}
