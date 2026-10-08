package upgrade

import (
	"context"
	"errors"
	"strings"
	"testing"
)

// The refusal of an engine older than the client, in its two wordings,
// becomes what to install; a refusal for another reason is left alone.
func TestTooOldEngine(t *testing.T) {
	cases := []struct {
		err  error
		want string
	}{
		{errors.New("Error response from daemon: client version 1.56 is too new. Maximum supported API version is 1.39"), "speaks API 1.39"},
		{errors.New("Error response from daemon: client is newer than server (client API version: 1.56, server API version: 1.24)"), "speaks API 1.24"},
		{errors.New("Error response from daemon: client version 1.99 is too new. Maximum supported API version is 1.47"), ""},
		{errors.New("Cannot connect to the Docker daemon at unix:///var/run/docker.sock. Is the docker daemon running?"), ""},
		{nil, ""},
	}
	for _, c := range cases {
		got := tooOldEngine(c.err)
		switch {
		case c.want == "" && got != nil:
			t.Errorf("%v: %v", c.err, got)
		case c.want != "" && (got == nil || !strings.Contains(got.Error(), c.want) || !strings.Contains(got.Error(), "kvsctl needs API "+MinEngineAPI) || !strings.Contains(got.Error(), "19.03")):
			t.Errorf("%v: %v, want %q", c.err, got, c.want)
		}
	}
	for _, c := range []struct {
		a, b string
		less bool
	}{{"1.9", "1.40", true}, {"1.39", "1.40", true}, {"1.40", "1.40", false}, {"1.47", "1.40", false}, {"2.0", "1.40", false}} {
		if got := lessAPI(c.a, c.b); got != c.less {
			t.Errorf("lessAPI(%s, %s) = %v", c.a, c.b, got)
		}
	}
}

// An engine too old for kvsctl stops the plan with what is needed, and
// nothing else: every other blocker would only repeat its refusal.
func TestPlanStopsAtAnEngineTooOld(t *testing.T) {
	s := newStack(t, "", rel{version: "1.0.0"}, rel{version: "1.1.0"})
	s.f.with(func(f *fakeDocker) {
		f.refusal = "client version 1.47 is too new. Maximum supported API version is 1.39"
	})
	_, plan := s.plan(s.runner())
	if !plan.Incomplete || len(plan.Blockers) != 1 || !strings.Contains(plan.Blockers[0], "speaks API 1.39") {
		t.Fatalf("incomplete %v, blockers %q", plan.Incomplete, plan.Blockers)
	}
	if err := CheckEngine(context.Background(), s.docker); err == nil || !strings.Contains(err.Error(), "upgrade Docker") {
		t.Fatalf("CheckEngine: %v", err)
	}
	s.f.with(func(f *fakeDocker) { f.refusal = "" })
	if err := CheckEngine(context.Background(), s.docker); err != nil {
		t.Fatalf("CheckEngine on an engine that answers: %v", err)
	}
	if _, plan := s.plan(s.runner()); plan.Incomplete || len(plan.Blockers) != 0 {
		t.Fatalf("incomplete %v, blockers %q", plan.Incomplete, plan.Blockers)
	}
}
