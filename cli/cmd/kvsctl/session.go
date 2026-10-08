package main

import (
	"context"
	"fmt"
	"io"
	"os"
	"os/signal"
	"slices"
	"strings"
	"sync"
	"syscall"

	tea "github.com/charmbracelet/bubbletea"

	"github.com/MaximeMichaud/KVS-install/cli/internal/instance"
	"github.com/MaximeMichaud/KVS-install/cli/internal/runlog"
	"github.com/MaximeMichaud/KVS-install/cli/internal/ui"
	"github.com/MaximeMichaud/KVS-install/cli/internal/upgrade"
)

// guard owns the signals of a command that changes the stack, for its whole
// run. The first SIGINT or SIGTERM, or Ctrl-C on the screen, cancels the
// operation, which stops it, or rolls back what it already changed. A
// later one, and any that comes while a rollback runs, is logged and
// changes nothing: a rollback cut short would leave the stack between two
// versions. SIGHUP, a terminal or an SSH session that went away, detaches
// the screen and the run carries on to its end; its log says how it went.
// SIGPIPE is taken too, so a write to a pipe whose reader quit fails with
// an error the writers ignore instead of killing kvsctl.
type guard struct {
	ctx    context.Context
	cancel context.CancelFunc
	sigs   chan os.Signal
	loop   chan struct{}
	// stopping is what the first interrupt does to the command, said to
	// the operator.
	stopping string
	// protects maps the steps whose start puts the run out of reach of an
	// interrupt to what then runs: "rollback", "recovery".
	protects map[string]string

	mu        sync.Mutex
	cancelled bool
	// running names what runs uninterruptibly, empty until then.
	running  string
	hungUp   bool
	finished bool
	// stoppingUntouched, when set, is what the first interrupt does to a
	// run that has not begun to change the stack: an upgrade being
	// planned, backing up, pulling or staging its release stops with
	// nothing to roll back. changing is set once the run asked to begin
	// its first change and was told yes (begin): stopping holds from then
	// on.
	stoppingUntouched string
	changing          bool
	// log and report are where the guard says what it does: report shows
	// a line the way the run shows its own, and the log keeps it.
	log    *runlog.Logger
	report func(string)
	// detach ends the screen when the terminal goes away.
	detach func()
}

// newGuard takes the signals until the run is over. stopping says what
// the first interrupt does to the command, protects which steps a later
// interrupt never reaches.
func newGuard(stopping string, protects map[string]string) *guard {
	g := &guard{sigs: make(chan os.Signal, 8), loop: make(chan struct{}), stopping: stopping, protects: protects}
	g.ctx, g.cancel = context.WithCancel(context.Background())
	signal.Notify(g.sigs, syscall.SIGINT, syscall.SIGTERM, syscall.SIGHUP, syscall.SIGPIPE)
	go g.handle()
	return g
}

func (g *guard) handle() {
	defer close(g.loop)
	for sig := range g.sigs {
		switch sig {
		case syscall.SIGPIPE:
			// The write that raised it fails with EPIPE, which every
			// writer of kvsctl ignores.
		case syscall.SIGHUP:
			g.hangup()
		case syscall.SIGTERM:
			if line, _ := g.interrupt("SIGTERM"); line != "" {
				g.say(line)
			}
		default:
			if line, _ := g.interrupt("SIGINT"); line != "" {
				g.say(line)
			}
		}
	}
}

// stop gives every signal back and ends the guard, for the tests: a
// command gives SIGINT, SIGTERM and SIGHUP back when its run is over, and
// keeps SIGPIPE until it exits.
func (g *guard) stop() {
	signal.Stop(g.sigs)
	close(g.sigs)
	<-g.loop
	g.cancel()
}

// attach names the log of the run and the way to show a line, once the
// run has them.
func (g *guard) attach(log *runlog.Logger, report func(string)) {
	g.mu.Lock()
	defer g.mu.Unlock()
	g.log, g.report = log, report
}

// beforeChange has the first interrupt say stopping instead of what newGuard
// was given, until the run begins to change the stack (begin).
func (g *guard) beforeChange(stopping string) {
	g.mu.Lock()
	defer g.mu.Unlock()
	g.stoppingUntouched = stopping
}

// begin answers a run about to make its first change, an upgrade about to
// write its journal: yes until the first interrupt, and no from then on,
// which stops the run with nothing changed. The interrupt takes the same
// lock to decide what it says, so a run told yes is one the interrupt says
// it rolls back, and a run told no one it says changed nothing.
func (g *guard) begin() bool {
	g.mu.Lock()
	defer g.mu.Unlock()
	if g.cancelled {
		return false
	}
	g.changing = true
	return true
}

// screen names how to end the screen when the terminal goes away, nil once
// it is gone.
func (g *guard) screen(detach func()) {
	g.mu.Lock()
	defer g.mu.Unlock()
	g.detach = detach
}

// finish marks the run over, its result written: a signal that comes
// after it changes nothing in the run. SIGINT, SIGTERM and SIGHUP go back
// to what they do to any program, so what kvsctl does after its run, the
// reminder that a newer stable release exists, ends at the first Ctrl-C
// instead of waiting for a manifest server that does not answer. SIGPIPE
// stays taken: a write to an output nobody reads still must not kill
// kvsctl.
func (g *guard) finish() {
	g.mu.Lock()
	g.finished = true
	g.mu.Unlock()
	signal.Reset(syscall.SIGINT, syscall.SIGTERM, syscall.SIGHUP)
}

// observe follows the steps of the run: the start of a protected one puts
// it out of reach of an interrupt.
func (g *guard) observe(e upgrade.Event) {
	if e.Kind != upgrade.KindStepStart {
		return
	}
	if what, ok := g.protects[e.Step]; ok {
		g.protect(what)
	}
}

// protect puts the run out of reach of an interrupt from now on, for what
// a command runs without engine steps, a restore's replay for instance.
func (g *guard) protect(what string) {
	g.mu.Lock()
	defer g.mu.Unlock()
	if g.running == "" {
		g.running = what
	}
}

// interrupt is a SIGINT, a SIGTERM or Ctrl-C, named by source. The first
// one cancels the operation. It returns the line that says what happens,
// empty when the run is already over, and what runs out of reach of the
// interrupt, if anything.
func (g *guard) interrupt(source string) (line, running string) {
	g.mu.Lock()
	switch {
	case g.finished:
		g.mu.Unlock()
		return "", ""
	case g.running != "":
		g.mu.Unlock()
		return fmt.Sprintf("%s: the %s is running and is not interrupted", source, g.running), g.running
	case g.cancelled:
		g.mu.Unlock()
		return fmt.Sprintf("%s: kvsctl is already stopping, at the first point where the stack is left as it was", source), ""
	}
	g.cancelled = true
	// A run that has not begun to change the stack is told no when it asks
	// (begin), so it stops before its first change: the line says so.
	stopping := g.stopping
	if g.stoppingUntouched != "" && !g.changing {
		stopping = g.stoppingUntouched
	}
	g.mu.Unlock()
	g.cancel()
	return fmt.Sprintf("%s: %s", source, stopping), ""
}

// screenInterrupt is Ctrl-C on the screen, which returns the line the
// screen shows. The log gets the line directly: the screen must not wait
// on its own event queue.
func (g *guard) screenInterrupt() string {
	line, running := g.interrupt("Ctrl-C")
	if line == "" {
		return ""
	}
	g.mu.Lock()
	log := g.log
	g.mu.Unlock()
	if log != nil {
		log.Printf("%s", line)
	}
	if running != "" {
		return running + " in progress: Ctrl-C does not interrupt it"
	}
	return line
}

// hangup is a SIGHUP: the terminal is gone, the run is not.
func (g *guard) hangup() {
	g.mu.Lock()
	if g.finished || g.hungUp {
		g.mu.Unlock()
		return
	}
	g.hungUp = true
	detach, log := g.detach, g.log
	g.mu.Unlock()
	line := "the terminal went away, kvsctl carries on"
	if log != nil {
		line += "; log: " + log.Path()
	}
	if detach != nil {
		detach()
	}
	g.say(line)
}

// wasHungUp reports whether the terminal went away.
func (g *guard) wasHungUp() bool {
	g.mu.Lock()
	defer g.mu.Unlock()
	return g.hungUp
}

// say shows a line the way the run shows its own, or on stderr before the
// run has a log.
func (g *guard) say(line string) {
	g.mu.Lock()
	report := g.report
	g.mu.Unlock()
	if report != nil {
		report(line)
		return
	}
	_, _ = fmt.Fprintln(os.Stderr, "kvsctl:", line)
}

// watcher hands every event of the run to the guard on its way to the
// screen, so the guard knows when a rollback starts, and lets the guard
// answer whether the run begins to change the stack.
type watcher struct {
	guard *guard
	next  upgrade.Reporter
}

// The watcher stays a Gate: without it the run goes by its context alone,
// and the line of an interrupt can then say the opposite of what it does.
var _ upgrade.Gate = (*watcher)(nil)

func (w *watcher) Event(e upgrade.Event) {
	w.guard.observe(e)
	w.next.Event(e)
}

func (w *watcher) Confirm(ctx context.Context, question string) bool {
	return w.next.Confirm(ctx, question)
}

func (w *watcher) Begin() bool { return w.guard.begin() }

// session is one run of a command that changes the stack: the lock of the
// installation, the run log, and the guard of its signals.
type session struct {
	command string
	inst    *instance.Instance
	guard   *guard
	log     *runlog.Logger
	unlock  func()
	// logUnsaid is set when --quiet left out the line that names the log:
	// the error of the run names it instead.
	logUnsaid bool
}

// sessionOptions say what a command needs of its session.
type sessionOptions struct {
	// recovering is set for recover alone, the command that finishes the
	// run a journal names and so runs while the journal is there.
	recovering bool
	// screen is set for a command that shows its run on the interactive
	// screen when it has a terminal: the screen names the log under its
	// title, where a command printing lines prints it first.
	screen bool
}

// takeLock takes the lock of an installation for a command; the tests
// replace it to change the installation the moment before the lock is
// taken.
var takeLock = (*instance.Instance).Lock

// openSession finds the installation, takes its lock, then reads the
// installation, its .env included, and the journal, and opens the run log,
// in that order. Nothing the run acts on is read before the lock is held:
// a run that changed .env and let go of the lock between the search and
// the lock would otherwise leave this one with the settings from before
// it. A run that cannot have the lock, or that a journal refuses, writes no
// log of its own. A log the 30 newest would push out is kept while a
// journal names it: it is how the interrupted run is understood, however
// many runs of recover follow it.
func openSession(command string, g *guard, opts sessionOptions) (*session, error) {
	found, err := instance.Detect(flagRoot)
	if err != nil {
		return nil, err
	}
	unlock, err := takeLock(found, command)
	if err != nil {
		return nil, err
	}
	inst, err := instance.Detect(found.Root)
	if err != nil {
		unlock()
		return nil, err
	}
	j, err := inst.LoadJournal()
	if err == nil && j != nil && !opts.recovering {
		err = interrupted(inst, j)
	}
	if err != nil {
		unlock()
		return nil, err
	}
	var keep []string
	if j != nil && j.Log != "" {
		keep = append(keep, j.Log)
	}
	log, err := runlog.Open(inst.StateDir(), command, keep...)
	if err != nil {
		unlock()
		return nil, fmt.Errorf("the log of this run cannot be created in %s (%w): nothing was changed", runlog.Dir(inst.StateDir()), err)
	}
	s := &session{command: command, inst: inst, guard: g, log: log, unlock: unlock}
	log.Printf("kvsctl %s, pid %d: %s", Version, os.Getpid(), strings.Join(os.Args, " "))
	if notice := releaseKeyNotice(); notice != "" {
		log.Printf("%s", notice)
	}
	g.attach(log, s.say)
	switch {
	case opts.screen && screenWanted():
	case flagQuiet:
		s.logUnsaid = true
	default:
		s.say("log: " + log.Path())
	}
	return s, nil
}

// screenWanted reports whether a command with a screen shows it: a terminal
// to draw on and to read the keys from, and neither --plain nor --quiet.
// The screen shows the last log lines of the run, which --quiet leaves to
// the log: its lines show the steps alone.
func screenWanted() bool {
	return !flagPlain && !flagQuiet && interactive()
}

// stdout is where the commands without a screen print; the tests read it.
var stdout io.Writer = os.Stdout

// say prints a line of a command without a screen and keeps it in the log:
// what the command did, a warning, the reason it stops. A line that cannot
// be printed is dropped: the log has it.
func (s *session) say(line string) {
	s.log.Printf("%s", line)
	_, _ = fmt.Fprintln(stdout, line)
}

// sayf is say with a format.
func (s *session) sayf(format string, args ...any) { s.say(fmt.Sprintf(format, args...)) }

// detail is say for a line --quiet leaves to the log: the progress of a
// long operation, a listing, a command that finds nothing to do.
func (s *session) detail(line string) {
	if !flagQuiet {
		s.say(line)
		return
	}
	s.log.Printf("%s", line)
}

// detailf is detail with a format.
func (s *session) detailf(format string, args ...any) { s.detail(fmt.Sprintf(format, args...)) }

// ctx is the context of the operation, which the first interrupt cancels.
func (s *session) ctx() context.Context { return s.guard.ctx }

// finish ends the run: the result goes to the log, the log to the disk,
// and the lock is released. The error of a run that changed the stack and
// did not end where it should, exit codes 4, 5 and 8, names the log, and
// so does any error of a run --quiet did not name the log for.
func (s *session) finish(err error) error {
	code := exitCode(err)
	if err != nil {
		if s.logUnsaid {
			err = namedLog(err, s.log.Path())
		} else {
			err = withLog(err, code, s.log.Path())
		}
		s.log.Printf("exit %d: %s", code, err.Error())
	} else {
		s.log.Printf("exit 0")
	}
	s.guard.finish()
	if cerr := s.log.Close(); cerr != nil {
		_, _ = fmt.Fprintf(os.Stderr, "kvsctl: the log of this run is incomplete: %v\n", cerr)
	}
	s.unlock()
	return err
}

// loggedError is the error of a run that left something to read: its
// message ends with the log, and it is still the error it wraps.
type loggedError struct {
	err  error
	path string
}

func (e *loggedError) Error() string { return ui.Clean(e.err.Error()) + "; log: " + e.path }
func (e *loggedError) Unwrap() error { return e.err }

// withLog names the log in the error of exit codes 4, 5 and 8, unless the
// message already does.
func withLog(err error, code int, path string) error {
	switch code {
	case exitRolledBack, exitRollbackFailed, exitNotRecorded:
		return namedLog(err, path)
	}
	return err
}

// namedLog ends the message of err with the log, unless it names it
// already.
func namedLog(err error, path string) error {
	if path == "" || strings.Contains(err.Error(), path) {
		return err
	}
	return &loggedError{err: err, path: path}
}

// interrupted is the refusal of a command while the journal of an
// interrupted run is there. The state only names the versions the way the
// operator reads them: a state that cannot be read leaves them as the
// journal records them, and the refusal stands either way.
func interrupted(inst *instance.Instance, j *instance.Journal) error {
	state, _ := inst.LoadState()
	return interruptedRun(state, j)
}

// interruptedRun is the refusal for a journal, with its log when it names
// one.
func interruptedRun(state *instance.State, j *instance.Journal) error {
	if j.Log != "" {
		return fmt.Errorf("%w (its log: %s)", j.Interrupted(state), j.Log)
	}
	return j.Interrupted(state)
}

// refuseInterrupted refuses a command that takes no lock, check for
// instance, while a run is interrupted. A journal whose run still holds
// the lock is a run in progress, which is said as such.
func refuseInterrupted(inst *instance.Instance) error {
	j, live, err := runState(inst)
	switch {
	case err != nil:
		return err
	case j == nil:
		return nil
	case live != nil:
		return live
	}
	return interrupted(inst, j)
}

// runState reads the journal of an interrupted run, nil when there is
// none, and the run another kvsctl has in progress, nil when none holds
// the lock. Neither read takes the lock or writes anything.
func runState(inst *instance.Instance) (*instance.Journal, *instance.LockedError, error) {
	j, err := inst.LoadJournal()
	if err != nil {
		return nil, nil, err
	}
	live, err := inst.Holder()
	if err != nil {
		return nil, nil, err
	}
	return j, live, nil
}

// runScreen runs an action of the runner behind the interactive screen, or
// with plain lines when there is no terminal, or --plain or --quiet was
// given. Either way every event goes to the run log first. The screen is
// not tied to the operation: it ends when the action has ended, and when
// the terminal goes away or the screen fails, the action goes on and its
// lines go to stdout, where a write that fails is dropped. A question is
// read from the terminal only when stdout is one too, as restore and clean
// read theirs: with the output sent to a file, the operator would wait on
// a question written into that file.
func (s *session) runScreen(runner *upgrade.Runner, title string, steps []string, action func(context.Context) error) error {
	runner.Opts.LogPath = s.log.Path()
	steps = screenSteps(steps, flagYes)
	if !screenWanted() {
		var in io.Reader
		if interactive() {
			in = os.Stdin
		}
		plain := ui.NewPlain(stdout, in, flagYes)
		plain.Err, plain.Quiet = stderr, flagQuiet
		runner.Reporter = &watcher{guard: s.guard, next: runlog.NewReporter(s.log, plain)}
		s.guard.attach(s.log, func(line string) {
			s.log.Printf("%s", line)
			plain.Notice(line)
		})
		// --quiet keeps the steps alone: the question, when there is one,
		// names the site and the versions itself.
		if !flagQuiet {
			_, _ = fmt.Fprintln(stdout, title)
		}
		return action(s.ctx())
	}
	fallback := ui.NewPlain(os.Stdout, nil, flagYes)
	term, model := ui.NewTerminal(title, s.log.Path(), steps, s.guard.screenInterrupt, fallback)
	chain := &watcher{guard: s.guard, next: runlog.NewReporter(s.log, term)}
	runner.Reporter = chain
	program := tea.NewProgram(model, tea.WithoutSignalHandler())
	s.guard.attach(s.log, func(line string) { chain.Event(upgrade.Event{Kind: upgrade.KindLog, Message: line}) })
	s.guard.screen(func() {
		program.Kill()
		term.Detach()
	})
	result := make(chan error, 1)
	go func() {
		err := action(s.ctx())
		term.Close()
		result <- err
	}()
	_, screenErr := program.Run()
	s.guard.screen(nil)
	// Whatever ended the screen, the events still to come go to stdout.
	term.Detach()
	if screenErr != nil && !s.guard.wasHungUp() {
		s.guard.say(fmt.Sprintf("the screen stopped (%v); the run goes on and its lines follow", screenErr))
	}
	return <-result
}

// screenSteps are the steps the screen lists as still to come: with --yes
// the run asks nothing, so the confirmation never comes.
func screenSteps(steps []string, yes bool) []string {
	if !yes {
		return steps
	}
	return slices.DeleteFunc(slices.Clone(steps), func(step string) bool { return step == upgrade.StepConfirm })
}
