package upgrade

import (
	"context"
	"errors"
	"fmt"
	"net/http"
	"slices"
	"strings"
	"testing"
	"time"

	"github.com/MaximeMichaud/KVS-install/cli/internal/dockerx"
)

// container is a container of the project as Containers reports it, with
// the health check timing of the fake: a window of 2 s + 30 s.
func container(service, state, health string, up time.Duration, now time.Time) dockerx.ContainerState {
	return dockerx.ContainerState{
		ID: "id-" + service, Name: "kvs-" + service, Service: service, State: state, Health: health,
		Started: now.Add(-up), HealthInterval: time.Second, HealthTimeout: time.Second, HealthRetries: 1,
	}
}

func TestJudge(t *testing.T) {
	now := time.Now()
	services := []string{"kvs-init", "mariadb", "nginx", "php-fpm"}
	cases := []struct {
		name                       string
		states                     []dockerx.ContainerState
		ignored                    []string
		problems, pending, leftout []string
		slowOnly                   bool
		crash                      bool
		// slow are the services the wait gives the database budget,
		// MariaDB alone when the case names none, and active the services
		// compose runs, services when it names none.
		slow, active []string
	}{
		{
			name:   "healthy, one without a health check, init exited",
			states: []dockerx.ContainerState{container("mariadb", "running", "healthy", time.Minute, now), container("nginx", "running", "", time.Minute, now), container("php-fpm", "running", "healthy", time.Minute, now), container("kvs-init", "exited", "", time.Minute, now)},
		},
		{
			name:    "starting within its window",
			states:  []dockerx.ContainerState{container("mariadb", "running", "healthy", time.Minute, now), container("nginx", "running", "healthy", time.Minute, now), container("php-fpm", "running", "starting", 10*time.Second, now)},
			pending: []string{"kvs-php-fpm is starting (its health check allows 33s)"},
		},
		{
			name:     "starting past its window",
			states:   []dockerx.ContainerState{container("mariadb", "running", "healthy", time.Minute, now), container("nginx", "running", "healthy", time.Minute, now), container("php-fpm", "running", "starting", 40*time.Second, now)},
			problems: []string{"kvs-php-fpm is still starting after the 33s its health check allows"},
		},
		{
			name:     "unhealthy, and a service without a container",
			states:   []dockerx.ContainerState{container("mariadb", "running", "healthy", time.Minute, now), container("nginx", "running", "unhealthy", time.Minute, now)},
			problems: []string{"kvs-nginx is unhealthy", "service php-fpm has no container"},
		},
		{
			name:     "MariaDB alone",
			states:   []dockerx.ContainerState{container("mariadb", "running", "unhealthy", time.Minute, now), container("nginx", "running", "healthy", time.Minute, now), container("php-fpm", "running", "healthy", time.Minute, now)},
			problems: []string{"kvs-mariadb is unhealthy"},
			slowOnly: true,
		},
		{
			name:     "Manticore rebuilding its indexes after a replay, MariaDB upgrading its tables",
			states:   []dockerx.ContainerState{container("mariadb", "running", "unhealthy", time.Minute, now), container("manticore", "running", "starting", time.Hour, now), container("nginx", "running", "healthy", time.Minute, now), container("php-fpm", "running", "healthy", time.Minute, now)},
			active:   []string{"kvs-init", "manticore", "mariadb", "nginx", "php-fpm"},
			slow:     []string{"manticore"},
			problems: []string{"kvs-mariadb is unhealthy", "kvs-manticore is still starting after the 33s its health check allows"},
			slowOnly: true,
		},
		{
			name:     "Manticore is slow only when the caller says so",
			states:   []dockerx.ContainerState{container("mariadb", "running", "healthy", time.Minute, now), container("manticore", "running", "starting", time.Hour, now), container("nginx", "running", "healthy", time.Minute, now), container("php-fpm", "running", "healthy", time.Minute, now)},
			active:   []string{"kvs-init", "manticore", "mariadb", "nginx", "php-fpm"},
			problems: []string{"kvs-manticore is still starting after the 33s its health check allows"},
		},
		{
			name:     "MariaDB without a container is not busy, it is missing",
			states:   []dockerx.ContainerState{container("nginx", "running", "healthy", time.Minute, now), container("php-fpm", "running", "healthy", time.Minute, now)},
			problems: []string{"service mariadb has no container"},
		},
		{
			name:    "a leftover and an ignored service",
			states:  []dockerx.ContainerState{container("mariadb", "running", "healthy", time.Minute, now), container("manticore", "exited", "", time.Minute, now), container("nginx", "running", "unhealthy", time.Minute, now), container("php-fpm", "running", "healthy", time.Minute, now)},
			ignored: []string{"nginx"},
			leftout: []string{"kvs-manticore"},
		},
		{
			name:     "a one-off container of compose run",
			states:   []dockerx.ContainerState{container("mariadb", "running", "healthy", time.Minute, now), {Name: "kvs-mariadb-run-1", Service: "mariadb", State: "exited", OneShot: true}, container("nginx", "running", "healthy", time.Minute, now), container("php-fpm", "running", "healthy", time.Minute, now)},
			problems: nil,
		},
	}
	for _, c := range cases {
		ignored := map[string]bool{}
		for _, s := range c.ignored {
			ignored[s] = true
		}
		slow := map[string]bool{mariadbService: true}
		for _, s := range c.slow {
			slow[s] = true
		}
		active := services
		if c.active != nil {
			active = c.active
		}
		v := judge(c.states, active, ignored, slow, map[string]int{}, now)
		if !slices.Equal(v.problems, c.problems) || !slices.Equal(v.pending, c.pending) || !slices.Equal(v.leftovers, c.leftout) || v.slowOnly != c.slowOnly || (v.crash != "") != c.crash {
			t.Errorf("%s: problems %q, pending %q, leftovers %q, slow only %v, crash %q", c.name, v.problems, v.pending, v.leftovers, v.slowOnly, v.crash)
		}
		if v.ready() != (len(c.problems) == 0 && len(c.pending) == 0) {
			t.Errorf("%s: ready = %v", c.name, v.ready())
		}
	}

	// Three restarts since the wait began, up for a moment: a crash loop.
	looping := container("php-fpm", "running", "", time.Second, now)
	looping.Restarts = 4
	v := judge([]dockerx.ContainerState{looping}, []string{"php-fpm"}, nil, nil, map[string]int{"kvs-php-fpm": 1}, now)
	if v.crash != "kvs-php-fpm keeps restarting (3 restarts since the wait began): read 'docker logs kvs-php-fpm'" {
		t.Errorf("crash = %q", v.crash)
	}
}

// A container still starting gets the window of its own health check,
// even past the health timeout.
func TestVerifyWaitsForAContainerWithinItsWindow(t *testing.T) {
	s := newStack(t, "", rel{version: "1.0.0"}, rel{version: "1.1.0"})
	s.f.behave(registry+"php:1.1.0-php8.1", behavior{ready: 1500 * time.Millisecond})
	start := time.Now()
	if err := s.upgrade(s.runner(func(o *Options) { o.HealthTimeout = 100 * time.Millisecond })); err != nil {
		t.Fatalf("upgrade: %v", err)
	}
	if !s.rep.said("kvs-php-fpm is starting (its health check allows 30s)") || time.Since(start) < 1500*time.Millisecond {
		t.Errorf("the verification did not wait for the container: %v", s.rep.logs())
	}
}

// An unhealthy container ends the wait at the health timeout.
func TestVerifyFailsAnUnhealthyServiceAtTheTimeout(t *testing.T) {
	s := newStack(t, "", rel{version: "1.0.0"}, rel{version: "1.1.0"})
	s.f.behave(registry+"php:1.1.0-php8.1", behavior{unhealthy: true})
	err := s.upgrade(s.runner(quick))
	if !errors.Is(err, ErrRolledBack) || !strings.Contains(err.Error(), "failed: not healthy after 300ms: kvs-php-fpm is unhealthy") {
		t.Fatalf("err = %v", err)
	}
	s.back("1.0.0")
}

// A crash loop ends the wait at once, long before the health timeout.
func TestVerifyEndsACrashLoopAtOnce(t *testing.T) {
	s := newStack(t, "", rel{version: "1.0.0"}, rel{version: "1.1.0"})
	s.f.behave(registry+"php:1.1.0-php8.1", behavior{crash: true})
	start := time.Now()
	err := s.upgrade(s.runner(func(o *Options) { o.HealthTimeout = time.Minute }))
	if !errors.Is(err, ErrRolledBack) || !strings.Contains(err.Error(), "kvs-php-fpm keeps restarting") {
		t.Fatalf("err = %v", err)
	}
	if elapsed := time.Since(start); elapsed > 30*time.Second {
		t.Errorf("the crash loop took %s to end the wait", elapsed)
	}
	s.back("1.0.0")
}

// The container of a service compose does not run here, from a profile
// that is off, is left out with a word in the log, and does not block the
// plan either.
func TestVerifyLeavesInactiveServicesOut(t *testing.T) {
	s := newStack(t, "", rel{version: "1.0.0"}, rel{version: "1.1.0"})
	s.f.with(func(f *fakeDocker) {
		img := f.registry[s.images["1.0.0"]["manticore"].Digest]
		f.containers["kvs-manticore"] = &fakeContainer{id: fmt.Sprintf("%064x", 999), name: "kvs-manticore", service: "manticore", ref: s.pin("1.0.0", "manticore"), image: img, started: time.Now(), stopped: true}
	})
	if err := s.upgrade(s.runner()); err != nil {
		t.Fatalf("upgrade: %v", err)
	}
	if !s.rep.said("kvs-manticore is left out: compose does not run its service here") {
		t.Error("the leftover was not named")
	}
}

// A container that runs another image than the one the release pins for
// its service, as compose run from a shell that exported the pin of the
// version left would leave it, fails the verification, which rolls the
// upgrade back: a healthy site on the images of the previous release is
// not the release installed. A service the verification leaves out, one
// accepted unhealthy before the run, is left out of that check too.
func TestVerifyChecksTheImagesTheContainersRun(t *testing.T) {
	for _, accepted := range []bool{false, true} {
		t.Run(fmt.Sprintf("accepted unhealthy %v", accepted), func(t *testing.T) {
			s := newStack(t, "", rel{version: "1.0.0"}, rel{version: "1.1.0"})
			var old *fakeImage
			s.f.with(func(f *fakeDocker) {
				old = f.containers[f.prefix+"-nginx"].image
				// compose up leaves nginx on the image of 1.0.0.
				f.hook = func(f *fakeDocker, req cliRequest) (cliResponse, bool) {
					if len(req.Args) < 2 || req.Args[0] != "compose" || req.Args[1] != "up" {
						return cliResponse{}, false
					}
					resp := f.compose(req, req.Args[1:])
					if c := f.containers[f.prefix+"-nginx"]; c != nil {
						c.image, c.ref = old, s.pin("1.0.0", "nginx")
					}
					return resp, true
				}
			})
			opts := []func(*Options){quick}
			if accepted {
				s.restartWith("nginx", behavior{unhealthy: true})
				opts = append(opts, func(o *Options) { o.AllowUnhealthy = true })
			}
			err := s.upgrade(s.runner(opts...))
			if accepted {
				if err != nil {
					t.Fatalf("upgrade with nginx accepted unhealthy: %v", err)
				}
				return
			}
			wrong := "the stack does not run the images 1.1.0 pins: kvs-nginx runs " + s.pin("1.0.0", "nginx")
			if !errors.Is(err, ErrRolledBack) || !strings.Contains(err.Error(), wrong) || !strings.Contains(err.Error(), "not the pinned "+s.pin("1.1.0", "nginx")) {
				t.Fatalf("err = %v", err)
			}
			s.back("1.0.0")
		})
	}
}

// An engine that does not answer while the images of the containers are
// read is waited for, as the verification waits for it: the upgrade it
// meets right after a healthy verification is not rolled back. One away
// for good fails the check once the health timeout is over.
func TestCheckPinsWaitsForAnEngineThatDoesNotAnswer(t *testing.T) {
	s := newStack(t, "", rel{version: "1.0.0"}, rel{version: "1.1.0"})
	short := s.runner(func(o *Options) { o.HealthTimeout = 100 * time.Millisecond })
	_, plan := s.plan(short)
	s.failEngine("/containers/json", 1000)
	err := short.checkPins(context.Background(), plan)
	if err == nil || !strings.HasPrefix(err.Error(), "the images the containers run could not be read after 100ms: the Docker engine did not answer: ") {
		t.Errorf("an engine away for good: %v", err)
	}
	s.failEngine("/containers/json", 0)

	r := s.runner(func(o *Options) { o.HealthTimeout = 5 * time.Second })
	s.rep.on = func(e Event) {
		if e.Kind == KindLog && strings.HasPrefix(e.Message, "GET /admin/ answered") {
			s.failEngine("/containers/json", 3)
		}
	}
	if err := s.upgrade(r); err != nil {
		t.Fatalf("upgrade: %v", err)
	}
	s.back("1.1.0")
	if !s.rep.said("waiting: the Docker engine did not answer: ") {
		t.Errorf("the wait on the engine was not logged: %v", s.rep.logs())
	}
}

// --allow-unhealthy accepts the services failing before the upgrade,
// and the verification leaves exactly those out.
func TestVerifyLeavesOutTheServicesAcceptedUnhealthy(t *testing.T) {
	s := newStack(t, "", rel{version: "1.0.0"}, rel{version: "1.1.0"})
	s.restartWith("nginx", behavior{unhealthy: true})
	s.f.behave(registry+"nginx:1.1.0", behavior{unhealthy: true})
	r := s.runner(quick, func(o *Options) { o.AllowUnhealthy = true })
	state, plan := s.plan(r)
	if len(plan.Blockers) != 0 || !slices.Equal(plan.Ignored, []string{"nginx"}) || !slices.Equal(plan.Unhealthy, []string{"kvs-nginx is unhealthy"}) {
		t.Fatalf("plan: blockers %v, ignored %v, unhealthy %v", plan.Blockers, plan.Ignored, plan.Unhealthy)
	}
	if err := r.Run(context.Background(), state, plan); err != nil {
		t.Fatalf("upgrade: %v", err)
	}
	if !s.rep.said("accepted as they are (--allow-unhealthy): kvs-nginx is unhealthy") || !s.rep.said("left out of the verification, unhealthy before the run: nginx") {
		t.Errorf("the accepted service was not named: %v", s.rep.logs())
	}

	// Another service failing is still a failure. The rollback that
	// follows judges the stack the same way: nginx, broken in both
	// versions, is left out of its verification too, and 1.0.0 is back.
	s2 := newStack(t, "", rel{version: "1.0.0"}, rel{version: "1.1.0"})
	s2.restartWith("nginx", behavior{unhealthy: true})
	s2.f.behave(registry+"nginx:1.0.0", behavior{unhealthy: true})
	s2.f.behave(registry+"nginx:1.1.0", behavior{unhealthy: true})
	s2.f.behave(registry+"php:1.1.0-php8.1", behavior{unhealthy: true})
	err := s2.upgrade(s2.runner(quick, func(o *Options) { o.AllowUnhealthy = true }))
	if !errors.Is(err, ErrRolledBack) || !strings.Contains(err.Error(), "kvs-php-fpm is unhealthy") || strings.Contains(err.Error(), "kvs-nginx") {
		t.Errorf("err = %v", err)
	}
	s2.back("1.0.0")
}

// The containers of a release can all be healthy while the site answers an
// error, nginx failing to reach PHP-FPM for one: the verification asks the
// site, and an upgrade whose site answers 502 is rolled back. The site of
// the version it returns to answers again, and the rollback passes.
func TestVerifyFailsASiteThatAnswersAnError(t *testing.T) {
	s := newStack(t, "", rel{version: "1.0.0"}, rel{version: "1.1.0"})
	s.rep.on = func(e Event) {
		switch {
		case e.Kind == KindStepStart && e.Step == StepVerify:
			s.site.Store(http.StatusBadGateway)
		case e.Kind == KindStepStart && e.Step == StepRollbck:
			s.site.Store(http.StatusOK)
		}
	}
	err := s.upgrade(s.runner(quick))
	if !errors.Is(err, ErrRolledBack) || !strings.HasPrefix(err.Error(), "upgrade to 1.1.0 failed: not healthy after 300ms: GET / answered 502 Bad Gateway; 1.0.0 is back and healthy") {
		t.Fatalf("err = %v", err)
	}
	s.back("1.0.0")
}

// When MariaDB is the only service not ready, the verification waits for
// it until the database budget, past the health timeout; anything else
// failing ends it at the timeout.
func TestVerifyGivesMariaDBAloneItsBudget(t *testing.T) {
	s := newStack(t, "", rel{version: "1.0.0"})
	r := s.runner(func(o *Options) { o.HealthTimeout = 100 * time.Millisecond })
	ctx := context.Background()

	s.restartWith("mariadb", behavior{sick: time.Second})
	if err := r.verify(ctx, nil, 10*time.Second); err != nil {
		t.Errorf("MariaDB busy for a while: %v", err)
	}
	if !s.rep.said("waiting: kvs-mariadb is unhealthy") {
		t.Errorf("the wait was not logged: %v", s.rep.logs())
	}

	s.restartWith("mariadb", behavior{sick: time.Minute})
	if err := r.verify(ctx, nil, 300*time.Millisecond); err == nil || err.Error() != "MariaDB is not ready after 300ms: kvs-mariadb is unhealthy" {
		t.Errorf("MariaDB past its budget: %v", err)
	}

	s.restartWith("nginx", behavior{unhealthy: true})
	start := time.Now()
	err := r.verify(ctx, nil, time.Minute)
	if err == nil || !strings.HasPrefix(err.Error(), "not healthy after 100ms: ") || time.Since(start) > 30*time.Second {
		t.Errorf("with nginx failing too: %v after %s", err, time.Since(start))
	}

	// A service the caller names slow gets the budget too, and the error
	// names it: Manticore building its indexes from a replayed database.
	s.restartWith("nginx", behavior{})
	s.restartWith("mariadb", behavior{})
	s.restartWith("php-fpm", behavior{sick: time.Minute})
	if err := r.verify(ctx, nil, 300*time.Millisecond, "php-fpm"); err == nil || err.Error() != "php-fpm is not ready after 300ms: kvs-php-fpm is unhealthy" {
		t.Errorf("a slow service past its budget: %v", err)
	}
	s.restartWith("php-fpm", behavior{sick: time.Second})
	if err := r.verify(ctx, nil, 10*time.Second, "php-fpm"); err != nil {
		t.Errorf("a slow service busy for a while: %v", err)
	}
}

// failEngine makes the Engine API answer n requests of path with a server
// error, the way a daemon that restarts in the middle of a wait does.
func (s *stack) failEngine(path string, n int) {
	s.f.with(func(f *fakeDocker) {
		f.apiFail = func(p string) bool {
			if n == 0 || p != path {
				return false
			}
			n--
			return true
		}
	})
}

// An engine that does not answer for a moment is waited for: a healthy
// upgrade whose verification meets a daemon restarting is not rolled
// back, and neither is the wait of MariaDB alone.
func TestVerifyWaitsForAnEngineThatDoesNotAnswer(t *testing.T) {
	s := newStack(t, "", rel{version: "1.0.0"}, rel{version: "1.1.0", database: migrates})
	s.f.behave(registry+"php:1.1.0-php8.1", behavior{migrate: "data-1 migrated by 1.1.0"})
	r := s.runner(func(o *Options) { o.HealthTimeout = 5 * time.Second })
	s.rep.on = func(e Event) {
		if e.Kind == KindStepStart && e.Step == StepVerify {
			s.failEngine("/containers/json", 3)
		}
	}
	if err := s.upgrade(r); err != nil {
		t.Fatalf("upgrade: %v", err)
	}
	s.back("1.1.0")
	if db, replays, _, _ := s.world(); db != "data-1 migrated by 1.1.0" || len(replays) != 0 {
		t.Errorf("database %q, replays %v", db, replays)
	}
	if !s.rep.said("waiting: the Docker engine did not answer: ") {
		t.Errorf("the wait on the engine was not logged: %v", s.rep.logs())
	}

	s.restartWith("mariadb", behavior{sick: 200 * time.Millisecond})
	s.failEngine("/containers/json", 2)
	if err := r.waitDatabase(context.Background(), 5*time.Second); err != nil {
		t.Errorf("MariaDB alone with the engine away a moment: %v", err)
	}
	s.failEngine("/containers/json", 1000)
	short := s.runner(func(o *Options) { o.HealthTimeout = 100 * time.Millisecond })
	err := short.verify(context.Background(), nil, time.Second)
	if err == nil || !strings.HasPrefix(err.Error(), "not healthy after 100ms: the Docker engine did not answer: ") {
		t.Errorf("an engine away for good: %v", err)
	}
}

// MariaDB alone is waited for through "unhealthy" until the budget, as a
// system table upgrade can outlast the retries of its health check; only a
// container that stopped or keeps restarting ends the wait early.
func TestWaitDatabase(t *testing.T) {
	s := newStack(t, "", rel{version: "1.0.0"})
	r := s.runner()
	ctx := context.Background()

	s.restartWith("mariadb", behavior{sick: 300 * time.Millisecond})
	if err := r.waitDatabase(ctx, 5*time.Second); err != nil {
		t.Errorf("MariaDB unhealthy for a while: %v", err)
	}
	if !s.rep.said("waiting for the database: kvs-mariadb is unhealthy") {
		t.Errorf("the wait was not logged: %v", s.rep.logs())
	}

	s.restartWith("mariadb", behavior{sick: time.Minute})
	if err := r.waitDatabase(ctx, 200*time.Millisecond); err == nil || err.Error() != "MariaDB is not ready after 200ms: kvs-mariadb is unhealthy" {
		t.Errorf("past the budget: %v", err)
	}

	for name, b := range map[string]behavior{"exited": {exits: true}, "crash loop": {crash: true}} {
		s.restartWith("mariadb", b)
		start := time.Now()
		err := r.waitDatabase(ctx, time.Minute)
		if err == nil || !strings.Contains(err.Error(), "read 'docker logs kvs-mariadb'") || time.Since(start) > 30*time.Second {
			t.Errorf("%s: %v after %s", name, err, time.Since(start))
		}
	}

	s.f.with(func(f *fakeDocker) { delete(f.containers, "kvs-mariadb") })
	if err := r.waitDatabase(ctx, time.Minute); err == nil || err.Error() != "compose project kvs has no mariadb container" {
		t.Errorf("without a container: %v", err)
	}
	short := s.runner(func(o *Options) { o.HealthTimeout = 100 * time.Millisecond })
	if err := short.verify(ctx, nil, time.Minute); err == nil || err.Error() != "not healthy after 100ms: service mariadb has no container" {
		t.Errorf("verify without a mariadb container: %v", err)
	}
	s.f.with(func(f *fakeDocker) { clear(f.containers) })
	if err := r.verify(ctx, nil, time.Second); err == nil || err.Error() != `no container of compose project "kvs" found: check COMPOSE_PROJECT_NAME in .env` {
		t.Errorf("verify without containers: %v", err)
	}
}

// 401 and 403 are a server that answers; a 5xx is not.
func TestHTTPCheck(t *testing.T) {
	s := newStack(t, "", rel{version: "1.0.0"})
	r := s.runner()
	ctx := context.Background()
	for _, code := range []int{http.StatusUnauthorized, http.StatusForbidden} {
		s.site.Store(int32(code))
		if err := r.httpCheck(ctx); err != nil {
			t.Errorf("%d: %v", code, err)
		}
		if !s.rep.said(fmt.Sprintf("GET /admin/ answered %d (protected)", code)) {
			t.Errorf("%d was not logged as protected: %v", code, s.rep.logs())
		}
	}
	s.site.Store(http.StatusBadGateway)
	if err := r.httpCheck(ctx); err == nil || err.Error() != "GET / answered 502 Bad Gateway" {
		t.Errorf("502: %v", err)
	}
}
