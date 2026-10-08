package upgrade

import (
	"context"
	"crypto/tls"
	"errors"
	"fmt"
	"io"
	"net"
	"net/http"
	"net/url"
	"slices"
	"strings"
	"time"

	"github.com/MaximeMichaud/KVS-install/cli/internal/dockerx"
)

// pollInterval is how often a wait looks at the containers again. The
// tests shorten it.
var pollInterval = 3 * time.Second

// defaultHealthTimeout is the wait for the services when the options name
// none.
const defaultHealthTimeout = 2 * time.Minute

// verify waits for the stack to be up and the site to answer. Only the
// containers of the services compose runs here are judged, minus the ones
// ignored (accepted as unhealthy before the run), and Docker's own health
// state decides: a container still starting gets the window its health
// check declares, which may be longer than the health timeout (a search
// index built at start), while a container that is unhealthy or not
// running ends the wait at the health timeout, and one that keeps
// restarting ends it at once. When MariaDB and the slow services are the
// only ones not ready, the wait goes on until dbBudget: a new server
// upgrades its system tables before it answers, and Manticore rebuilds its
// indexes from a replayed database before it does. An engine that does not
// answer is waited for like a container that is not ready: a daemon that
// restarts in the middle must not roll back a healthy run.
func (r *Runner) verify(ctx context.Context, ignored []string, dbBudget time.Duration, slow ...string) error {
	return r.verifyServices(ctx, nil, ignored, dbBudget, slow...)
}

// verifyServices is verify on the services named, nil for the ones compose
// runs here: a restore that put back the .env of an archive judges the
// services its containers run for, which that .env may change only at the
// next 'docker compose up -d'.
func (r *Runner) verifyServices(ctx context.Context, services, ignored []string, dbBudget time.Duration, slow ...string) error {
	timeout := r.Opts.HealthTimeout
	if timeout <= 0 {
		timeout = defaultHealthTimeout
	}
	skip := map[string]bool{}
	for _, s := range ignored {
		skip[s] = true
	}
	if len(ignored) > 0 {
		r.log("left out of the verification, unhealthy before the run: " + strings.Join(ignored, ", "))
	}
	patient := map[string]bool{mariadbService: true}
	for _, s := range slow {
		patient[s] = true
	}
	start := time.Now()
	deadline := start.Add(timeout)
	dbDeadline := start.Add(max(dbBudget, timeout))
	listed := services != nil
	var baseline map[string]int
	told := map[string]bool{}
	lastMsg := ""
	var last verdict
	for {
		var v verdict
		now := time.Now()
		answered := true
		if !listed {
			list, err := dockerx.ActiveServices(ctx, r.Inst.DockerDir)
			if err != nil {
				answered = false
				v = verdict{problems: []string{"the services of the stack could not be listed: " + firstLine(err.Error())}}
			} else {
				services, listed = list, true
			}
		}
		if answered {
			states, err := r.Docker.Containers(ctx, r.Inst.ProjectName())
			switch {
			case err != nil:
				answered = false
				v = verdict{problems: []string{"the Docker engine did not answer: " + firstLine(err.Error())}}
			case len(states) == 0:
				return r.noContainers()
			default:
				if baseline == nil {
					baseline = map[string]int{}
					for _, s := range states {
						baseline[s.Name] = s.Restarts
					}
				}
				v = judge(states, services, skip, patient, baseline, now)
			}
		}
		if !answered {
			// What the last look found still holds, the database budget of
			// a wait on the slow services included.
			v.slowOnly, v.slow = last.slowOnly, last.slow
		} else {
			last = v
		}
		for _, name := range v.leftovers {
			if !told[name] {
				told[name] = true
				r.log(name + " is left out: compose does not run its service here")
			}
		}
		if v.crash != "" {
			return errors.New(v.crash)
		}
		if answered && v.ready() {
			err := r.httpCheck(ctx)
			if err == nil {
				return nil
			}
			v.problems = append(v.problems, firstLine(err.Error()))
			v.slowOnly = false
		}
		if msg := "waiting: " + strings.Join(append(append([]string(nil), v.problems...), v.pending...), "; "); msg != lastMsg {
			lastMsg = msg
			r.log(msg)
		}
		if now.After(deadline) && len(v.problems) > 0 {
			if !v.slowOnly {
				return fmt.Errorf("not healthy after %s: %s", shortDuration(timeout), strings.Join(v.problems, "; "))
			}
			if now.After(dbDeadline) {
				return fmt.Errorf("%s after %s: %s", notReady(v.slow), shortDuration(dbBudget), strings.Join(v.problems, "; "))
			}
		}
		if err := sleep(ctx, pollInterval); err != nil {
			return err
		}
	}
}

// checkPins makes sure the containers of the active services run the
// images the run pinned for them, compared by image ID (dockerx.Unpinned):
// a container left on another image, by a compose run from a shell that
// exported the pin of the version before for instance, can be healthy,
// and a site that answers on it is not the release installed. The services
// accepted unhealthy, which the verification leaves out, are left out here
// too, and so are the one-off containers of compose run. An engine that
// does not answer is waited for within the health timeout, as the
// verification waits for it.
func (r *Runner) checkPins(ctx context.Context, plan *Plan) error {
	services, err := dockerx.ActiveServices(ctx, r.Inst.DockerDir)
	if err != nil {
		return fmt.Errorf("the services of the stack could not be listed: %w", err)
	}
	pins := map[string]string{}
	for _, img := range plan.Images {
		if slices.Contains(services, img.Service) && !slices.Contains(plan.Ignored, img.Service) {
			pins[img.Service] = img.Ref + "@" + img.Digest
		}
	}
	timeout := r.Opts.HealthTimeout
	if timeout <= 0 {
		timeout = defaultHealthTimeout
	}
	deadline := time.Now().Add(timeout)
	for {
		wrong, err := r.Docker.Unpinned(ctx, r.Inst.ProjectName(), pins)
		switch {
		case err == nil && len(wrong) == 0:
			return nil
		case err == nil:
			return fmt.Errorf("the stack does not run the images %s pins: %s", plan.Target.Version, strings.Join(wrong, "; "))
		case time.Now().After(deadline):
			return fmt.Errorf("the images the containers run could not be read after %s: the Docker engine did not answer: %s", shortDuration(timeout), firstLine(err.Error()))
		}
		r.log("waiting: the Docker engine did not answer: " + firstLine(err.Error()))
		if err := sleep(ctx, pollInterval); err != nil {
			return err
		}
	}
}

// notReady names the slow services a wait gave up on: "MariaDB is not
// ready" for the database alone.
func notReady(services []string) string {
	switch {
	case len(services) == 0, len(services) == 1 && services[0] == mariadbService:
		return "MariaDB is not ready"
	case len(services) == 1:
		return services[0] + " is not ready"
	}
	return strings.Join(services, " and ") + " are not ready"
}

// verdict is what one look at the containers found.
type verdict struct {
	// problems end the wait at the health timeout: a container unhealthy,
	// not running, restarted moments ago, starting for longer than its
	// health check allows, or a service without a container.
	problems []string
	// pending are containers still starting within their own window.
	pending []string
	// slowOnly is set when everything wrong or pending is a container of
	// a slow service, MariaDB, which a new server keeps busy for a while,
	// or one the caller named; slow lists them.
	slowOnly bool
	slow     []string
	// crash names a container that keeps restarting, which ends the wait.
	crash string
	// leftovers are containers of services compose does not run here.
	leftovers []string
}

func (v verdict) ready() bool {
	return len(v.problems) == 0 && len(v.pending) == 0 && v.crash == ""
}

// judge looks at the containers of the project once. services are the
// active services, sorted; ignored the services left out; slow the ones a
// wait gives the database budget; baseline the restart counts when the
// wait began.
func judge(states []dockerx.ContainerState, services []string, ignored, slow map[string]bool, baseline map[string]int, now time.Time) verdict {
	var v verdict
	active := map[string]bool{}
	for _, s := range services {
		active[s] = true
	}
	seen := map[string]bool{}
	onlySlow := true
	for _, s := range states {
		if !judged(s) {
			continue
		}
		if !active[s.Service] {
			v.leftovers = append(v.leftovers, s.Name)
			continue
		}
		seen[s.Service] = true
		if ignored[s.Service] {
			continue
		}
		problems, crash := dockerx.Problems([]dockerx.ContainerState{s}, baseline, now)
		if crash {
			v.crash = fmt.Sprintf("%s keeps restarting (%d restarts since the wait began): read 'docker logs %s'", s.Name, s.Restarts-baseline[s.Name], s.Name)
		}
		if len(problems) == 0 {
			continue
		}
		if slow[s.Service] {
			if !slices.Contains(v.slow, s.Service) {
				v.slow = append(v.slow, s.Service)
			}
		} else {
			onlySlow = false
		}
		if s.State == "running" && s.Health == "starting" {
			window := s.HealthWindow()
			if now.Before(s.Started.Add(window)) {
				v.pending = append(v.pending, fmt.Sprintf("%s is starting (its health check allows %s)", s.Name, window.Round(time.Second)))
				continue
			}
			v.problems = append(v.problems, fmt.Sprintf("%s is still starting after the %s its health check allows", s.Name, window.Round(time.Second)))
			continue
		}
		v.problems = append(v.problems, problems...)
	}
	// A missing container is not one that is busy: nothing creates it
	// while the wait goes on, so it never earns the database budget.
	for _, s := range services {
		if seen[s] || ignored[s] || strings.HasSuffix(s, "-init") {
			continue
		}
		v.problems = append(v.problems, "service "+s+" has no container")
		onlySlow = false
	}
	v.slowOnly = onlySlow && (len(v.problems) > 0 || len(v.pending) > 0)
	slices.Sort(v.slow)
	return v
}

// judged reports whether a container is part of what the verification
// looks at: one-off containers of compose run and the init services, which
// exit once their work is done, are not.
func judged(s dockerx.ContainerState) bool {
	return !s.OneShot && !strings.HasSuffix(s.Service, "-init")
}

// describeContainer says what is wrong with a container, the way the
// check before an upgrade reports it.
func describeContainer(s dockerx.ContainerState) string {
	switch {
	case s.State == "running":
		return fmt.Sprintf("%s is %s", s.Name, s.Health)
	case s.State == "exited" || s.State == "dead":
		return fmt.Sprintf("%s is %s (exit %d)", s.Name, s.State, s.Exit)
	default:
		return fmt.Sprintf("%s is %s", s.Name, s.State)
	}
}

// waitDatabase waits for MariaDB alone to report healthy: its first start
// on a new image upgrades its system tables, and a fresh data directory is
// initialised, before anything may use it. Docker may call it unhealthy in
// between, when that work outlasts the retries of its health check, so the
// wait goes on until budget, an engine that does not answer included; only
// a container that stopped or keeps restarting ends it before.
func (r *Runner) waitDatabase(ctx context.Context, budget time.Duration) error {
	deadline := time.Now().Add(budget)
	var baseline map[string]int
	lastMsg := ""
	for {
		var msg string
		states, err := r.Docker.Containers(ctx, r.Inst.ProjectName())
		now := time.Now()
		if err != nil {
			msg = "the Docker engine did not answer: " + firstLine(err.Error())
		} else {
			db := dockerx.ByService(states, mariadbService)
			if db == nil {
				return fmt.Errorf("compose project %s has no mariadb container", r.Inst.ProjectName())
			}
			if baseline == nil {
				baseline = map[string]int{db.Name: db.Restarts}
			}
			if _, crash := dockerx.Problems([]dockerx.ContainerState{*db}, baseline, now); crash {
				return fmt.Errorf("%s keeps restarting (%d restarts since the wait began): read 'docker logs %s'", db.Name, db.Restarts-baseline[db.Name], db.Name)
			}
			switch db.State {
			case "running":
				if db.Health == "" || db.Health == "healthy" {
					return nil
				}
				msg = db.Name + " is " + db.Health
			case "restarting", "created":
				msg = db.Name + " is " + db.State
			default:
				return fmt.Errorf("%s is %s (exit %d): read 'docker logs %s'", db.Name, db.State, db.Exit, db.Name)
			}
		}
		if now.After(deadline) {
			return fmt.Errorf("MariaDB is not ready after %s: %s", shortDuration(budget), msg)
		}
		if msg != lastMsg {
			lastMsg = msg
			r.log("waiting for the database: " + msg)
		}
		if err := sleep(ctx, pollInterval); err != nil {
			return err
		}
	}
}

// shortDuration is d as a message shows it: to the second, or as it is
// below a second, which only a very short flag asks for.
func shortDuration(d time.Duration) time.Duration {
	if d < time.Second {
		return d
	}
	return d.Round(time.Second)
}

// sleep waits d, or less when ctx ends first.
func sleep(ctx context.Context, d time.Duration) error {
	t := time.NewTimer(d)
	defer t.Stop()
	select {
	case <-ctx.Done():
		return context.Cause(ctx)
	case <-t.C:
		return nil
	}
}

// noContainers explains an empty project, which used to make the
// verification collapse into the single HTTP probe without a word.
func (r *Runner) noContainers() error {
	msg := fmt.Sprintf("no container of compose project %q found: check COMPOSE_PROJECT_NAME in .env", r.Inst.ProjectName())
	if !r.Inst.ProjectNameKnown() {
		msg += " (the file sets none, so this name was guessed)"
	}
	return errors.New(msg)
}

// httpCheck asks the site for / and /admin/ once, on the published
// endpoint and with the host name the site answers to (www included).
// Anything below 400 counts: a site that answers a redirect is a site that
// is up, and treating it as down used to roll back healthy upgrades. 401
// and 403 count too: basic auth or an allowlist in front of the admin is a
// server that answers, and the probe has no credentials to give.
func (r *Runner) httpCheck(ctx context.Context) error {
	host, port := r.Inst.PublishedEndpoint()
	site := r.Inst.SiteHost()
	transport := &http.Transport{
		TLSClientConfig: &tls.Config{InsecureSkipVerify: true, ServerName: site}, //nolint:gosec // local port, certificate checked elsewhere
		DialContext: func(ctx context.Context, network, addr string) (net.Conn, error) {
			return (&net.Dialer{Timeout: 5 * time.Second}).DialContext(ctx, network, net.JoinHostPort(host, port))
		},
	}
	client := &http.Client{Transport: transport, Timeout: 30 * time.Second, CheckRedirect: func(*http.Request, []*http.Request) error { return http.ErrUseLastResponse }}
	defer transport.CloseIdleConnections()
	for _, path := range []string{"/", "/admin/"} {
		req, err := http.NewRequestWithContext(ctx, http.MethodGet, "https://"+site+path, nil)
		if err != nil {
			return err
		}
		req.Header.Set("User-Agent", "kvsctl")
		resp, err := client.Do(req)
		if err != nil {
			return fmt.Errorf("GET %s: %w", path, err)
		}
		_, _ = io.Copy(io.Discard, io.LimitReader(resp.Body, 64<<10))
		resp.Body.Close()
		protected := resp.StatusCode == http.StatusUnauthorized || resp.StatusCode == http.StatusForbidden
		if resp.StatusCode >= http.StatusBadRequest && !protected {
			return fmt.Errorf("GET %s answered %s", path, resp.Status)
		}
		r.log(fmt.Sprintf("GET %s answered %d%s", path, resp.StatusCode, statusNote(resp, site)))
	}
	return nil
}

// statusNote says why an answer is not a plain 200.
func statusNote(resp *http.Response, site string) string {
	switch {
	case resp.StatusCode < http.StatusMultipleChoices:
		return ""
	case resp.StatusCode == http.StatusUnauthorized || resp.StatusCode == http.StatusForbidden:
		return " (protected)"
	}
	loc := resp.Header.Get("Location")
	if loc == "" {
		return " (" + strings.ToLower(http.StatusText(resp.StatusCode)) + ")"
	}
	if u, err := url.Parse(loc); err == nil && u.Host != "" {
		if strings.EqualFold(u.Host, "www."+site) {
			return " (www redirect)"
		}
		return " (redirect to " + u.Host + ")"
	}
	return " (redirect to " + loc + ")"
}
