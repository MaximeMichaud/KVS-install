// Package ui shows an upgrade in the terminal: steps, one progress bar per
// image, the last log lines, and the questions, with bubbletea. Plain
// draws the same events as lines when there is no terminal.
package ui

import (
	"bufio"
	"context"
	"fmt"
	"io"
	"os"
	"strings"
	"sync/atomic"

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
	upgrade.StepRollbck: "Rolling back",
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

// Model is the bubbletea model of one upgrade or rollback.
type Model struct {
	title    string
	events   <-chan upgrade.Event
	answers  chan<- bool
	reporter *TerminalReporter
	cancel   context.CancelFunc
	spinner  spinner.Model
	steps    map[string]*stepState
	order    []string
	pending  []string
	images   []*imageState
	total    upgrade.Event
	logs     []string
	question string
	asking   bool
	done     bool
	err      error
	width    int
}

type eventMsg upgrade.Event

// TerminalReporter feeds the model from the runner's goroutine.
type TerminalReporter struct {
	events  chan upgrade.Event
	answers chan bool
	// detached is set once the screen is gone; events are dropped rather
	// than filling a buffer nobody reads any more, which would block the
	// runner in the middle of an upgrade.
	detached atomic.Bool
}

// NewTerminal builds a reporter and the model that displays it; steps are
// the steps the action will run, shown as pending until they start.
func NewTerminal(title string, steps []string, cancel context.CancelFunc) (*TerminalReporter, *Model) {
	// The answers channel holds one reply so the screen never blocks on a
	// Confirm that already gave up.
	rep := &TerminalReporter{events: make(chan upgrade.Event, 256), answers: make(chan bool, 1)}
	sp := spinner.New(spinner.WithSpinner(spinner.Dot))
	m := &Model{
		title:    title,
		events:   rep.events,
		answers:  rep.answers,
		reporter: rep,
		cancel:   cancel,
		spinner:  sp,
		steps:    map[string]*stepState{},
		pending:  steps,
		width:    80,
	}
	return rep, m
}

// Detach tells the reporter the screen has ended. The runner may still be
// finishing its step, and its events go nowhere from now on: the ones it
// already handed over are drained until it closes the stream, so a send
// that was in flight when the screen died never holds the upgrade.
func (r *TerminalReporter) Detach() {
	if r.detached.Swap(true) {
		return
	}
	go func() {
		for range r.events { //nolint:revive // draining on purpose
		}
	}()
}

// Event implements upgrade.Reporter. It never blocks once the screen is
// gone: the event is dropped instead.
func (r *TerminalReporter) Event(e upgrade.Event) {
	if !r.detached.Load() {
		r.events <- e
		return
	}
	select {
	case r.events <- e:
	default:
	}
}

// Confirm implements upgrade.Reporter; it blocks until the user answers
// or the context ends, and answers no when the screen is gone.
func (r *TerminalReporter) Confirm(ctx context.Context, question string) bool {
	if r.detached.Load() {
		return false
	}
	r.Event(upgrade.Event{Kind: upgrade.KindLog, Step: upgrade.StepConfirm, Message: "?" + question})
	select {
	case answer := <-r.answers:
		return answer
	case <-ctx.Done():
		return false
	}
}

// Close ends the event stream once the runner returned.
func (r *TerminalReporter) Close() { close(r.events) }

func waitEvent(ch <-chan upgrade.Event) tea.Cmd {
	return func() tea.Msg {
		e, ok := <-ch
		if !ok {
			return nil
		}
		return eventMsg(e)
	}
}

// Init starts the spinner and the event loop.
func (m *Model) Init() tea.Cmd {
	return tea.Batch(m.spinner.Tick, waitEvent(m.events))
}

// Update handles events and keys.
func (m *Model) Update(msg tea.Msg) (tea.Model, tea.Cmd) {
	switch msg := msg.(type) {
	case tea.WindowSizeMsg:
		m.width = msg.Width
		return m, nil
	case tea.KeyMsg:
		switch {
		case msg.Type == tea.KeyCtrlC:
			if m.done {
				return m.quit()
			}
			m.answer(false)
			m.cancel()
			m.logs = append(m.logs, "cancelling...")
			return m, nil
		case m.asking:
			switch strings.ToLower(msg.String()) {
			case "y", "enter":
				m.answer(true)
			case "n", "esc", "q":
				m.answer(false)
			}
			return m, nil
		case m.done:
			return m.quit()
		}
		return m, nil
	case spinner.TickMsg:
		var cmd tea.Cmd
		m.spinner, cmd = m.spinner.Update(msg)
		return m, cmd
	case eventMsg:
		m.apply(upgrade.Event(msg))
		if m.done {
			return m.quit()
		}
		return m, waitEvent(m.events)
	case nil:
		return m, nil
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
	case m.answers <- value:
	default:
	}
}

// quit ends the screen. A question still on screen is answered no, and
// the reporter is detached, so the runner never waits for a screen that
// is gone.
func (m *Model) quit() (tea.Model, tea.Cmd) {
	m.answer(false)
	if m.reporter != nil {
		m.reporter.Detach()
	}
	return m, tea.Quit
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
		s.status, s.detail = "failed", e.Message
	case upgrade.KindLog:
		if e.Step == upgrade.StepConfirm && strings.HasPrefix(e.Message, "?") {
			m.question, m.asking = e.Message[1:], true
			return
		}
		m.logs = append(m.logs, e.Message)
		if len(m.logs) > 6 {
			m.logs = m.logs[len(m.logs)-6:]
		}
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

// View draws the screen.
func (m *Model) View() string {
	var b strings.Builder
	b.WriteString(titleStyle.Render(m.title) + "\n\n")
	shown := map[string]bool{}
	names := append([]string{}, m.order...)
	for _, name := range m.pending {
		if _, ok := m.steps[name]; !ok && !m.done {
			names = append(names, name)
		}
	}
	for _, name := range names {
		if shown[name] {
			continue
		}
		shown[name] = true
		s := m.steps[name]
		icon, text := "○", dimStyle.Render(stepTitles[name])
		if s != nil {
			switch s.status {
			case "running":
				icon, text = m.spinner.View(), stepTitles[name]
			case "done":
				icon, text = okStyle.Render("✓"), stepTitles[name]
			case "skipped":
				icon, text = dimStyle.Render("–"), dimStyle.Render(stepTitles[name])
			case "failed":
				icon, text = failStyle.Render("✗"), failStyle.Render(stepTitles[name])
			}
		}
		line := fmt.Sprintf(" %s %s", icon, text)
		if s != nil && s.detail != "" {
			line += " " + dimStyle.Render(s.detail)
		}
		b.WriteString(line + "\n")
		if name == upgrade.StepPull && len(m.images) > 0 {
			m.renderImages(&b)
		}
		if name == upgrade.StepConfirm && m.asking {
			b.WriteString("   " + askStyle.Render(m.question+" [y/N]") + "\n")
		}
	}
	if len(m.logs) > 0 && !m.done {
		b.WriteString("\n")
		for _, l := range m.logs {
			b.WriteString(dimStyle.Render("   "+truncate(l, m.width-4)) + "\n")
		}
	}
	if m.done {
		b.WriteString("\n")
		if m.err != nil {
			b.WriteString(failStyle.Render(" ✗ "+firstLine(m.err.Error())) + "\n")
		} else {
			b.WriteString(okStyle.Render(" ✓ Done") + "\n")
		}
	}
	return b.String()
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

// Plain prints events as lines, for logs and automation.
type Plain struct {
	Out io.Writer
	In  io.Reader
	Yes bool
	// Quiet drops the image progress and the log lines, and keeps the
	// steps, the failures and the questions: what a cron job wants in a
	// mail.
	Quiet bool
	last  map[string]int
	total int
}

// NewPlain builds a line reporter.
func NewPlain(out io.Writer, in io.Reader, yes bool) *Plain {
	return &Plain{Out: out, In: in, Yes: yes, last: map[string]int{}}
}

// Event implements upgrade.Reporter.
func (p *Plain) Event(e upgrade.Event) {
	switch e.Kind {
	case upgrade.KindStepStart:
		fmt.Fprintf(p.Out, "==> %s: %s\n", stepTitles[e.Step], e.Message)
	case upgrade.KindStepDone:
		fmt.Fprintf(p.Out, "    done: %s\n", e.Message)
	case upgrade.KindStepFail:
		fmt.Fprintf(p.Out, "    FAILED: %s\n", e.Message)
	case upgrade.KindLog:
		if p.Quiet {
			return
		}
		fmt.Fprintf(p.Out, "    %s\n", e.Message)
	case upgrade.KindImage:
		if p.Quiet {
			return
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
				fmt.Fprintf(p.Out, "    %-40s %s\n", label, e.Message)
			}
			return
		case !seen && pr.Current == 0 && !pr.Done:
			p.last[label] = 0
			fmt.Fprintf(p.Out, "    %-40s %s to download\n", label, upgrade.HumanBytes(pr.Total))
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
		fmt.Fprintf(p.Out, "    %-40s %3d%%  %s / %s\n", label, pct, upgrade.HumanBytes(pr.Current), upgrade.HumanBytes(pr.Total))
	case upgrade.KindImages:
		fmt.Fprintf(p.Out, "    all images pulled (%s)\n", upgrade.HumanBytes(e.Total.Total))
	case upgrade.KindDone:
		if e.Err != nil {
			fmt.Fprintf(p.Out, "==> FAILED: %s\n", firstLine(e.Err.Error()))
		} else {
			fmt.Fprintln(p.Out, "==> Done")
		}
	}
}

// plainVersions writes the move of one image for a line printer, with an
// ASCII arrow.
func plainVersions(from, to string) string {
	if from == to || from == "" {
		return to
	}
	return from + " -> " + to
}

// Confirm implements upgrade.Reporter through stdin.
func (p *Plain) Confirm(ctx context.Context, question string) bool {
	if p.Yes {
		return true
	}
	fmt.Fprintf(p.Out, "%s [y/N] ", question)
	if p.In == nil {
		fmt.Fprintln(p.Out, "no terminal: pass --yes")
		return false
	}
	line, _ := bufio.NewReader(p.In).ReadString('\n')
	answer := strings.ToLower(strings.TrimSpace(line))
	return answer == "y" || answer == "yes"
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
