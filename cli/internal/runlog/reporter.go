package runlog

import (
	"context"
	"fmt"
	"sync"

	"github.com/MaximeMichaud/KVS-install/cli/internal/upgrade"
)

// Reporter writes every event and question of a run to the log, then hands
// it to the reporter that shows it. The engine keeps talking to one
// upgrade.Reporter, and the log holds what the screen showed, the lines a
// screen leaves out included.
type Reporter struct {
	log  *Logger
	next upgrade.Reporter
	mu   sync.Mutex
	// images is the progress last logged per image, in tens of percent,
	// so a pull leaves a dozen lines and not one per chunk.
	images map[string]int64
}

var _ upgrade.Reporter = (*Reporter)(nil)

// NewReporter logs to log and forwards to next, which may be nil for a run
// nobody watches.
func NewReporter(log *Logger, next upgrade.Reporter) *Reporter {
	return &Reporter{log: log, next: next, images: map[string]int64{}}
}

// Event implements upgrade.Reporter. The event is in the log before the
// screen gets it. When the log can no longer be written, the next reporter
// is told once, and the run goes on.
func (r *Reporter) Event(e upgrade.Event) {
	if line, ok := r.line(e); ok {
		r.log.Printf("%s", line)
	}
	if r.next == nil {
		return
	}
	r.next.Event(e)
	if err := r.log.failure(); err != nil {
		r.next.Event(upgrade.Event{Kind: upgrade.KindLog, Message: fmt.Sprintf("the run log can no longer be written, the run goes on without it: %v", err)})
	}
}

// Confirm implements upgrade.Reporter: the question and the answer go to
// the log, the answer comes from the next reporter. Without one nobody can
// answer, which is a no.
func (r *Reporter) Confirm(ctx context.Context, question string) bool {
	r.log.Printf("question: %s", question)
	answer := false
	if r.next != nil {
		answer = r.next.Confirm(ctx, question)
	}
	switch {
	case answer:
		r.log.Printf("answer: yes")
	case ctx.Err() != nil:
		r.log.Printf("answer: none, the run was cancelled while it waited")
	default:
		r.log.Printf("answer: no")
	}
	return answer
}

// line is the log line of an event, false for an image progress that
// moved less than ten percent since the last one logged.
func (r *Reporter) line(e upgrade.Event) (string, bool) {
	switch e.Kind {
	case upgrade.KindStepStart:
		return fmt.Sprintf("[%s] start: %s", e.Step, e.Message), true
	case upgrade.KindStepDone:
		return fmt.Sprintf("[%s] done: %s", e.Step, e.Message), true
	case upgrade.KindStepFail:
		return fmt.Sprintf("[%s] FAILED: %s", e.Step, e.Message), true
	case upgrade.KindLog:
		return e.Message, true
	case upgrade.KindImage:
		return r.imageLine(e)
	case upgrade.KindImages:
		return fmt.Sprintf("all images pulled (%s)", upgrade.HumanBytes(e.Total.Total)), true
	case upgrade.KindDone:
		if e.Err != nil {
			return "FAILED: " + e.Err.Error(), true
		}
		return "done", true
	default:
		return fmt.Sprintf("event %d [%s]: %s", e.Kind, e.Step, e.Message), true
	}
}

func (r *Reporter) imageLine(e upgrade.Event) (string, bool) {
	label := e.Image
	if e.Service != "" {
		label = e.Service + " " + e.Image
		if e.From != "" && e.From != e.To {
			label += " (" + e.From + " -> " + e.To + ")"
		}
	}
	if e.Message != "" {
		return label + ": " + e.Message, true
	}
	p := e.Progress
	step := int64(0)
	if p.Total > 0 {
		step = p.Current * 10 / p.Total
	}
	if p.Done {
		step = 10
	}
	r.mu.Lock()
	last, seen := r.images[label]
	if seen && step <= last {
		r.mu.Unlock()
		return "", false
	}
	r.images[label] = step
	r.mu.Unlock()
	if p.Done {
		return fmt.Sprintf("%s: pulled, %s", label, upgrade.HumanBytes(p.Total)), true
	}
	return fmt.Sprintf("%s: %d%%, %s of %s", label, step*10, upgrade.HumanBytes(p.Current), upgrade.HumanBytes(p.Total)), true
}
