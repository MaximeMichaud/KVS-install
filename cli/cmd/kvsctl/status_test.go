package main

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"net"
	"net/http"
	"net/http/httptest"
	"os"
	"os/exec"
	"os/signal"
	"path/filepath"
	"regexp"
	"slices"
	"strings"
	"sync/atomic"
	"syscall"
	"testing"
	"time"

	"github.com/MaximeMichaud/KVS-install/cli/internal/dockerx"
	"github.com/MaximeMichaud/KVS-install/cli/internal/instance"
	"github.com/MaximeMichaud/KVS-install/cli/internal/manifest"
	"github.com/MaximeMichaud/KVS-install/cli/internal/runlog"
	"github.com/MaximeMichaud/KVS-install/cli/internal/upgrade"
)

// failedAt is when the upgrade of failedState failed.
var failedAt = time.Date(2026, 10, 7, 0, 57, 0, 0, time.UTC)

// failedState is a stack an upgrade to 1.1.0 failed on, rolled back to
// 1.0.0.
func failedState() *instance.State {
	return &instance.State{Current: "1.0.0", History: []instance.Entry{
		{Version: "1.0.0", Action: "adopt", Date: failedAt.Add(-24 * time.Hour)},
		{Version: "1.0.0", Action: instance.ActionRollback, Date: failedAt, Note: "1.1.0 failed: not healthy after 1s: kvs-nginx is unhealthy"},
	}}
}

// The Updates line of status says whether a newer release exists and what
// to run about it: 'kvsctl check', whose plan alone knows whether 'kvsctl
// upgrade' would install it, unless what status sees comes first; nothing
// to install for a checkout newer than the release. The commands it names
// carry the installation and the manifest status was given. A read of the
// manifest that failed says so.
func TestUpdatesLine(t *testing.T) {
	root := newRoot(t)
	useRoot(t, root)
	inst := saveState(t, root, &instance.State{Current: "1.0.0"})
	check := "kvsctl check --root " + root
	latest := latestKnown{Version: "1.1.0", Date: "2026-10-01T12:00:00Z", Commit: strings.Repeat("a", 40)}
	behind := &instance.State{Current: "1.0.0"}
	checkout := &instance.State{
		Current:           instance.Unreleased,
		AdoptedCommit:     strings.Repeat("b", 40),
		AdoptedCommitDate: time.Date(2026, 10, 1, 12, 0, 1, 0, time.UTC),
		History:           []instance.Entry{{Version: instance.Unreleased, Action: "adopt", Date: failedAt}},
	}
	cases := []struct {
		name  string
		state *instance.State
		err   error
		want  string
	}{
		{"behind", behind, nil, "1.1.0 available, run '" + check + "'"},
		{"up to date", &instance.State{Current: "1.1.0"}, nil, "up to date"},
		{"failed read", behind, errors.New("manifest: Get \"https://example.com\": EOF\nmore"), "could not check (manifest: Get \"https://example.com\": EOF)"},
		{"checkout ahead", checkout, nil, "none newer than this checkout: 1.1.0 was released on 2026-10-01 12:00:00 UTC, before its commit bbbbbbbbbbbb of 2026-10-01 12:00:01 UTC"},
		{"failed upgrade", failedState(), nil, "1.1.0 available, run '" + check + "' once the cause is fixed"},
		{"cancelled upgrade", undoneState("1.1.0 failed: docker compose up -d: context canceled (signal: terminated)"), nil, "1.1.0 available, run '" + check + "'"},
		{"interrupted upgrade", undoneState("1.1.0 failed: interrupted during verify"), nil, "1.1.0 available, run '" + check + "'"},
	}
	for _, c := range cases {
		if got := updatesLine(inst, c.state, latest, c.err, ""); got != c.want {
			t.Errorf("%s: %q, want %q", c.name, got, c.want)
		}
	}
	// The checkout of the release itself is not ahead of it, whatever the
	// dates say.
	same := *checkout
	same.AdoptedCommit = latest.Commit
	if got, want := updatesLine(inst, &same, latest, nil, ""), "1.1.0 available, run '"+check+"'"; got != want {
		t.Errorf("the checkout of the release: %q, want %q", got, want)
	}
	// A stack that is down has to start first, and one whose containers
	// run under another project name has to find them again: the plan
	// would find it unhealthy.
	if got, want := updatesLine(inst, behind, latest, nil, "start the stack"), "1.1.0 available, start the stack, then run '"+check+"'"; got != want {
		t.Errorf("a stack that is down: %q, want %q", got, want)
	}
	if got, want := updatesLine(inst, behind, latest, nil, "check COMPOSE_PROJECT_NAME in .env"), "1.1.0 available, check COMPOSE_PROJECT_NAME in .env, then run '"+check+"'"; got != want {
		t.Errorf("containers under another project: %q, want %q", got, want)
	}

	// A release the stack cannot upgrade to directly is reached through
	// the stop the plan would name.
	stopped := latest
	stopped.MinFrom = map[string]string{"1.1.0": "1.0.1"}
	if got, want := updatesLine(inst, behind, stopped, nil, ""), "1.1.0 available, run '"+check+" --version 1.0.1' first"; got != want {
		t.Errorf("a release behind a stop: %q, want %q", got, want)
	}
	if got, want := updatesLine(inst, behind, stopped, nil, "start the stack"), "1.1.0 available, start the stack, then run '"+check+" --version 1.0.1'"; got != want {
		t.Errorf("a release behind a stop, the stack down: %q, want %q", got, want)
	}

	interruptedJournal(t, root)
	if got, want := updatesLine(inst, behind, latest, nil, "start the stack"), "1.1.0 available, run 'kvsctl recover --root "+root+"' first"; got != want {
		t.Errorf("with a journal: %q, want %q", got, want)
	}
	if err := inst.RemoveJournal(); err != nil {
		t.Fatal(err)
	}
	unlock, err := inst.Lock("upgrade")
	if err != nil {
		t.Fatal(err)
	}
	defer unlock()
	if got, want := updatesLine(inst, behind, latest, nil, ""), "1.1.0 available, run '"+check+"' once the kvsctl running now ends"; got != want {
		t.Errorf("with the lock held: %q, want %q", got, want)
	}

	// The kvsctl that took the lock was killed, and a docker command it
	// started holds the lock: that command is what to wait for.
	dead := exec.Command("true")
	if err := dead.Run(); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(inst.StateDir(), "lock"), fmt.Appendf(nil, "{\"pid\":%d,\"command\":\"upgrade\"}\n", dead.Process.Pid), 0o600); err != nil {
		t.Fatal(err)
	}
	if got, want := updatesLine(inst, behind, latest, nil, ""), "1.1.0 available, run '"+check+"' once the docker command that holds the lock ends"; got != want {
		t.Errorf("with an orphaned lock: %q, want %q", got, want)
	}
	if got, want := readyLine(inst, "kvsctl upgrade"), "run 'kvsctl upgrade' once the docker command that holds the lock ends: the kvsctl run that holds the lock has ended"; !strings.HasPrefix(got, want) {
		t.Errorf("the verdict of check with an orphaned lock: %q, want it to start with %q", got, want)
	}
}

// undoneState is a stack an upgrade to 1.1.0 was rolled back on, back on
// 1.0.0, with note as the history entry of the rollback.
func undoneState(note string) *instance.State {
	return &instance.State{Current: "1.0.0", History: []instance.Entry{
		{Version: "1.0.0", Action: "adopt", Date: failedAt.Add(-24 * time.Hour)},
		{Version: "1.0.0", Action: instance.ActionRollback, Date: failedAt, Note: note},
	}}
}

// Only the entry the automatic rollback writes, and only as the newest
// one, is an upgrade to report; its cause tells a failure, which leaves
// something to fix, from a run that was cancelled, or that a crash cut
// short and recover rolled back.
func TestLastUndone(t *testing.T) {
	failed, ok := lastUndone(failedState())
	if !ok || failed.to != "1.1.0" || failed.cause != "not healthy after 1s: kvs-nginx is unhealthy" || !failed.at.Equal(failedAt) || !failed.failed() {
		t.Fatalf("lastUndone = %+v, %v", failed, ok)
	}
	for note, how := range map[string]string{
		"1.1.0 failed: docker compose up -d: context canceled (signal: terminated)":                                          "was cancelled",
		"1.1.0 failed: pull nginx: context canceled":                                                                         "was cancelled",
		"1.1.0 failed: interrupted during verify":                                                                            "was interrupted",
		"1.1.0 failed: not healthy after 1s: kvs-nginx is unhealthy; its rollback failed first (x), and recover finished it": "failed",
	} {
		last, ok := lastUndone(undoneState(note))
		if !ok || last.how != how || last.failed() != (how == "failed") {
			t.Errorf("%q reads %+v, %v, want %q", note, last, ok, how)
		}
	}
	// The entry kvsctl writes now says how the run ended in a field, which
	// is what counts: an engine whose words name a cancel did not cancel
	// the run, which failed.
	undid := func(outcome, cause, note string) *instance.State {
		state := undoneState(note)
		state.History[1].Undid = &instance.Undone{Action: instance.ActionUpgrade, To: "1.1.0", Outcome: outcome, Cause: cause}
		return state
	}
	for _, c := range []struct{ outcome, cause, note, how string }{
		{instance.OutcomeFailed, "docker compose up -d: exit status 1: Error response from daemon: context canceled", "1.1.0 failed: docker compose up -d: exit status 1: Error response from daemon: context canceled", "failed"},
		{instance.OutcomeFailed, "not healthy after 1s: kvs-nginx is unhealthy", "1.1.0 failed: not healthy after 1s: kvs-nginx is unhealthy; its rollback failed first (x), and recover finished it", "failed"},
		{instance.OutcomeCancelled, "context canceled", "1.1.0 was cancelled: context canceled", "was cancelled"},
		{instance.OutcomeInterrupted, "interrupted during verify", "1.1.0 was interrupted during verify", "was interrupted"},
	} {
		last, ok := lastUndone(undid(c.outcome, c.cause, c.note))
		if !ok || last.to != "1.1.0" || last.cause != c.cause || last.how != c.how || last.failed() != (c.how == "failed") {
			t.Errorf("%s with %q reads %+v, %v, want %q", c.outcome, c.cause, last, ok, c.how)
		}
	}
	if last, ok := lastUndone(undid(instance.OutcomeFailed, "docker exec kvs-php-fpm: exit status 1: ", "1.1.0 failed: docker exec kvs-php-fpm: exit status 1: ")); !ok || last.cause != "docker exec kvs-php-fpm: exit status 1" {
		t.Errorf("a cause ending with a separator reads %+v, %v", last, ok)
	}
	manual := undid(instance.OutcomeFailed, "not healthy after 1s", "the rollback to 0.9.0 failed: not healthy after 1s")
	manual.History[1].Undid.Action, manual.History[1].Undid.To = instance.ActionRollback, "0.9.0"
	if last, ok := lastUndone(manual); ok {
		t.Errorf("an undone manual rollback reads as an upgrade rolled back: %+v", last)
	}
	later := failedState()
	later.Current = "1.1.0"
	later.History = append(later.History, instance.Entry{Version: "1.1.0", Action: instance.ActionUpgrade, Date: failedAt.Add(time.Hour)})
	for name, state := range map[string]*instance.State{
		"an upgrade that worked since": later,
		"a rollback by hand":           {Current: "1.0.0", History: []instance.Entry{{Version: "1.0.0", Action: instance.ActionRollback, Note: "by hand from 1.1.0"}}},
		"a rollback that did not end":  {Current: "1.0.0", History: []instance.Entry{{Version: "1.0.0", Action: instance.ActionRollback, Note: "the rollback to 1.0.0 did not finish: compose up failed: exit 1"}}},
		"no history":                   {Current: "1.0.0"},
		"no state":                     nil,
		"a stack on another version":   {Current: "1.2.0", History: []instance.Entry{{Version: "1.0.0", Action: instance.ActionRollback, Note: "1.1.0 failed: not healthy after 1s"}}},
	} {
		if last, ok := lastUndone(state); ok {
			t.Errorf("%s reads as an upgrade rolled back: %+v", name, last)
		}
	}
}

// The failure names the log of its run, the newest upgrade or recover that
// started before it ended, so the operator reads why without searching.
func TestFailureNamesItsLog(t *testing.T) {
	root := newRoot(t)
	inst := saveState(t, root, failedState())
	dir := runlog.Dir(inst.StateDir())
	if err := os.MkdirAll(dir, 0o700); err != nil {
		t.Fatal(err)
	}
	for _, name := range []string{"20261006-120000-upgrade.log", "20261007-005400-upgrade.log", "20261007-005500-backup.log", "20261007-010000-upgrade.log"} {
		if err := os.WriteFile(filepath.Join(dir, name), nil, 0o600); err != nil {
			t.Fatal(err)
		}
	}
	failed, _ := lastUndone(failedState())
	want := "to 1.1.0 failed on 2026-10-07 00:57 UTC and was rolled back: not healthy after 1s: kvs-nginx is unhealthy (log: " + filepath.Join(dir, "20261007-005400-upgrade.log") + ")"
	if got := failed.withLog(inst); got != want {
		t.Fatalf("withLog = %q, want %q", got, want)
	}
	cancelled, _ := lastUndone(undoneState("1.1.0 failed: docker compose up -d: context canceled (signal: terminated)"))
	want = "to 1.1.0 was cancelled on 2026-10-07 00:57 UTC and was rolled back: docker compose up -d: context canceled (signal: terminated) (log: " + filepath.Join(dir, "20261007-005400-upgrade.log") + ")"
	if got := cancelled.withLog(inst); got != want {
		t.Fatalf("a cancelled upgrade: %q, want %q", got, want)
	}
	// The note keeps the first line of the failure, which ends with a
	// separator when a docker command wrote nothing on stderr.
	silent, _ := lastUndone(undoneState("1.1.0 failed: docker exec kvs-php-fpm: exit status 1: "))
	want = "to 1.1.0 failed on 2026-10-07 00:57 UTC and was rolled back: docker exec kvs-php-fpm: exit status 1 (log: " + filepath.Join(dir, "20261007-005400-upgrade.log") + ")"
	if got := silent.withLog(inst); got != want {
		t.Fatalf("a docker command silent on stderr: %q, want %q", got, want)
	}
	if got, want := silent.String(), "the last upgrade to 1.1.0 failed on 2026-10-07 00:57 UTC and was rolled back (docker exec kvs-php-fpm: exit status 1)"; got != want {
		t.Fatalf("the reminder's reason: %q, want %q", got, want)
	}
	if err := os.RemoveAll(dir); err != nil {
		t.Fatal(err)
	}
	if got := failed.withLog(inst); strings.Contains(got, "log:") {
		t.Fatalf("a log no longer kept is named: %q", got)
	}
}

// A stack with no container at all is down, which .env is not the cause
// of; one whose containers carry another project name is.
func TestNoServices(t *testing.T) {
	inst, err := instance.Detect(newRoot(t, "docker/.env", "DOMAIN=example.com\nCOMPOSE_PROJECT_NAME=site\nSITE_PREFIX=site\n"))
	if err != nil {
		t.Fatal(err)
	}
	if got := noServices(inst, false); strings.Contains(got, "COMPOSE_PROJECT_NAME") || !strings.Contains(got, "'docker compose up -d' in "+inst.DockerDir) {
		t.Fatalf("a stack that is down: %q", got)
	}
	if got := noServices(inst, true); !strings.Contains(got, "site-mariadb exists: check COMPOSE_PROJECT_NAME in "+inst.EnvPath) {
		t.Fatalf("containers under another project: %q", got)
	}
}

// engineContainer is a container the fake engine holds, of the compose
// project it serves when it has a service.
type engineContainer struct {
	name, service, image, state, health string
}

// engineImage is an image the fake engine holds: its tags and the digests
// it was pulled by, "repo@sha256:...".
type engineImage struct {
	tags, digests []string
}

// fakeEngine is a Docker engine on a unix socket DOCKER_HOST names, and a
// client of it. It answers info, lists the containers of project, those
// containers returns that have a service, and inspects any of them by
// name; it lists images, inspects them by tag or digest and removes them,
// though it keeps listing them; anything else is not found. containers is
// read at every request, so a test changes what the engine holds between
// two commands.
func fakeEngine(t *testing.T, project string, containers func() []engineContainer, images ...engineImage) *dockerx.Client {
	t.Helper()
	// A unix socket path is short, so the socket gets a directory of its
	// own under the temporary directory.
	dir, err := os.MkdirTemp("", "kvsctl")
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = os.RemoveAll(dir) })
	sock := filepath.Join(dir, "docker.sock")
	listener, err := net.Listen("unix", sock)
	if err != nil {
		t.Fatal(err)
	}
	inspect := regexp.MustCompile(`^/v[0-9.]+/containers/([^/]+)/json$`)
	inspectImage := regexp.MustCompile(`^/v[0-9.]+/images/(.+)/json$`)
	removeImage := regexp.MustCompile(`^/v[0-9.]+/images/(.+)$`)
	labels := func(c engineContainer) map[string]string {
		if c.service == "" {
			return map[string]string{}
		}
		return map[string]string{"com.docker.compose.project": project, "com.docker.compose.service": c.service}
	}
	srv := &http.Server{Handler: http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path == "/_ping" {
			w.Header().Set("API-Version", "1.47")
			return
		}
		w.Header().Set("Content-Type", "application/json")
		reply := func(v any) { _ = json.NewEncoder(w).Encode(v) }
		switch {
		case strings.HasSuffix(r.URL.Path, "/info"):
			reply(map[string]any{"Architecture": "x86_64", "OSType": "linux", "DockerRootDir": "/var/lib/docker", "ServerVersion": "27.3.1"})
			return
		case strings.HasSuffix(r.URL.Path, "/containers/json"):
			list := []map[string]any{}
			for _, c := range containers() {
				if c.service != "" {
					list = append(list, map[string]any{"Id": c.name, "Names": []string{"/" + c.name}, "Image": c.image, "Labels": labels(c), "State": c.state})
				}
			}
			reply(list)
			return
		case strings.HasSuffix(r.URL.Path, "/images/json"):
			list := []map[string]any{}
			for i, img := range images {
				list = append(list, map[string]any{"Id": fmt.Sprintf("sha256:%064d", i), "RepoTags": img.tags, "RepoDigests": img.digests})
			}
			reply(list)
			return
		}
		if m := removeImage.FindStringSubmatch(r.URL.Path); m != nil && r.Method == http.MethodDelete {
			for _, img := range images {
				if slices.Contains(img.tags, m[1]) || slices.Contains(img.digests, m[1]) {
					reply([]map[string]string{{"Untagged": m[1]}})
					return
				}
			}
		}
		if m := inspectImage.FindStringSubmatch(r.URL.Path); m != nil {
			for i, img := range images {
				if slices.Contains(img.tags, m[1]) || slices.Contains(img.digests, m[1]) {
					reply(map[string]any{"Id": fmt.Sprintf("sha256:%064d", i), "RepoTags": img.tags, "RepoDigests": img.digests})
					return
				}
			}
		}
		if m := inspect.FindStringSubmatch(r.URL.Path); m != nil {
			for _, c := range containers() {
				if c.name != m[1] {
					continue
				}
				state := map[string]any{"Status": c.state, "Running": c.state == "running", "StartedAt": "2026-10-07T00:00:00Z"}
				if c.health != "" {
					state["Health"] = map[string]any{"Status": c.health}
				}
				reply(map[string]any{"Id": c.name, "Name": "/" + c.name, "Image": "sha256:" + strings.Repeat("0", 64), "Config": map[string]any{"Image": c.image, "Labels": labels(c)}, "State": state})
				return
			}
		}
		w.WriteHeader(http.StatusNotFound)
		reply(map[string]string{"message": "not found"})
	})}
	go func() { _ = srv.Serve(listener) }()
	t.Cleanup(func() { _ = srv.Close() })
	t.Setenv("DOCKER_HOST", "unix://"+sock)
	t.Setenv("DOCKER_API_VERSION", "")
	t.Setenv("DOCKER_TLS_VERIFY", "")
	t.Setenv("DOCKER_CERT_PATH", "")
	docker, err := dockerx.New()
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = docker.Close() })
	return docker
}

// stackDown tells a stack that is down, which starting repairs, from one
// whose containers run under another project name, which .env has to find
// again, by the database container the stack names; first, what the
// Updates line puts before the upgrade, follows.
func TestStackDown(t *testing.T) {
	inst, err := instance.Detect(newRoot(t, "docker/.env", "DOMAIN=example.com\nCOMPOSE_PROJECT_NAME=site\nSITE_PREFIX=site\n"))
	if err != nil {
		t.Fatal(err)
	}
	var elsewhere atomic.Bool
	docker := fakeEngine(t, "site", func() []engineContainer {
		if elsewhere.Load() {
			return []engineContainer{{name: "site-mariadb", image: "mariadb:11.8", state: "running"}}
		}
		return nil
	})
	ctx := context.Background()
	if text, first := stackDown(ctx, docker, inst, nil); text != noServices(inst, false) || first != "start the stack" {
		t.Errorf("a stack with no container: %q, %q", text, first)
	}
	elsewhere.Store(true)
	if text, first := stackDown(ctx, docker, inst, nil); text != noServices(inst, true) || first != "check COMPOSE_PROJECT_NAME in .env" {
		t.Errorf("containers under another project: %q, %q", text, first)
	}
	stopped := map[string]dockerx.ServiceImage{"mariadb": {State: "exited"}, "nginx": {State: "exited"}}
	if text, first := stackDown(ctx, docker, inst, stopped); !strings.Contains(text, "no service runs: start the stack with 'docker compose up -d' in "+inst.DockerDir) || first != "start the stack" {
		t.Errorf("a stack whose containers stopped: %q, %q", text, first)
	}
	stopped["nginx"] = dockerx.ServiceImage{State: "running"}
	if text, first := stackDown(ctx, docker, inst, stopped); text != "" || first != "" {
		t.Errorf("a stack with a service running: %q, %q", text, first)
	}
}

// keepFlags puts back, once the test ends, the flags of kvsctl, which a
// run of rootCmd sets.
func keepFlags(t *testing.T) {
	t.Helper()
	root, manifest, yes, plain, quiet, stale := flagRoot, flagManifest, flagYes, flagPlain, flagQuiet, flagAllowStale
	t.Cleanup(func() {
		flagRoot, flagManifest, flagYes, flagPlain, flagQuiet, flagAllowStale = root, manifest, yes, plain, quiet, stale
	})
}

// runKvsctl runs kvsctl with args, as main does, and returns what it
// printed and its error. The flags it sets are put back after the test.
func runKvsctl(t *testing.T, args ...string) (string, error) {
	t.Helper()
	keepFlags(t)
	old := stdout
	out := &lockedBuffer{b: &bytes.Buffer{}}
	stdout = out
	defer func() { stdout = old }()
	cmd := rootCmd()
	cmd.SetArgs(args)
	err := cmd.Execute()
	return out.String(), err
}

// status says what the stack needs before an upgrade from what it reads
// itself: a stack whose services all stopped has to start, and the last
// upgrade failed and was rolled back. Its Updates line puts the start
// first, and with the stack up, the cause of the failure.
func TestStatusSaysWhatComesBeforeTheUpgrade(t *testing.T) {
	root := newRoot(t, "docker/.env", "DOMAIN=example.com\nCOMPOSE_PROJECT_NAME=site\nSITE_PREFIX=site\n")
	useRoot(t, root)
	inst := saveState(t, root, failedState())
	const url = "https://example.com/manifest.json"
	saveLatestKnown(inst, map[string]*latestKnown{url: {Read: time.Now(), Version: "1.1.0", Date: "2026-10-01"}})
	var state atomic.Value
	state.Store("exited")
	fakeEngine(t, "site", func() []engineContainer {
		s := state.Load().(string)
		return []engineContainer{
			{name: "site-mariadb", service: "mariadb", image: "mariadb:11.8", state: s},
			{name: "site-nginx", service: "nginx", image: "nginx:1.29", state: s},
		}
	})
	check := "kvsctl check --root " + root + " --manifest " + url
	out, err := runKvsctl(t, "status", "--root", root, "--manifest", url)
	if err != nil {
		t.Fatalf("status: %v\n%s", err, out)
	}
	for _, want := range []string{
		"Stopped      no service runs: start the stack with 'docker compose up -d' in " + inst.DockerDir + "\n",
		"Last upgrade to 1.1.0 failed on 2026-10-07 00:57 UTC and was rolled back: not healthy after 1s: kvs-nginx is unhealthy\n",
		"Updates      1.1.0 available, start the stack, then run '" + check + "'\n",
	} {
		if !strings.Contains(out, want) {
			t.Errorf("status lacks %q:\n%s", want, out)
		}
	}
	state.Store("running")
	out, err = runKvsctl(t, "status", "--root", root, "--manifest", url)
	if err != nil {
		t.Fatalf("status: %v\n%s", err, out)
	}
	if want := "Updates      1.1.0 available, run '" + check + "' once the cause is fixed\n"; !strings.Contains(out, want) || strings.Contains(out, "Stopped") {
		t.Errorf("status of the stack up lacks %q, or says it stopped:\n%s", want, out)
	}
}

func TestAllStopped(t *testing.T) {
	stopped := map[string]dockerx.ServiceImage{
		"mariadb":  {State: "exited"},
		"nginx":    {State: "created"},
		"kvs-init": {State: "exited"},
	}
	if !allStopped(stopped) {
		t.Fatal("a stack whose containers all stopped is not stopped")
	}
	stopped["php-fpm"] = dockerx.ServiceImage{State: "restarting"}
	if allStopped(stopped) {
		t.Fatal("a stack with a service restarting reads as stopped")
	}
}

// noComposeCLI puts a docker CLI on PATH that fails every command, for the
// length of the test: the services compose runs are then unknown, which
// counts every container, and no test depends on the docker CLI of the
// machine.
func noComposeCLI(t *testing.T) {
	t.Helper()
	bin := t.TempDir()
	if err := os.WriteFile(filepath.Join(bin, "docker"), []byte("#!/bin/sh\necho 'no docker here' >&2\nexit 1\n"), 0o755); err != nil {
		t.Fatal(err)
	}
	t.Setenv("PATH", bin+string(os.PathListSeparator)+os.Getenv("PATH"))
}

// rollbackState is a stack upgraded from 1.0.0 to 1.1.0, whose nginx image
// changed between the two.
func rollbackState() *instance.State {
	return &instance.State{
		Current:  "1.1.0",
		Previous: "1.0.0",
		Files:    []string{"docker/docker-compose.yml"},
		ReleaseImages: map[string][]string{
			"1.0.0": {"example/nginx:1.0.0@sha256:" + strings.Repeat("1", 64)},
			"1.1.0": {"example/nginx:1.1.0@sha256:" + strings.Repeat("2", 64)},
		},
	}
}

// status says when a rollback would have to pull the images of the
// previous version first, the engine no longer holding them: while the
// registry cannot be reached, that rollback is refused. Once the engine
// holds them, nothing is said. check says nothing of them, up to date or
// not: its plan is an upgrade, whose rollback returns to the installed
// version, and a second Rollback line would read as part of it.
func TestStatusNamesTheImagesARollbackPulls(t *testing.T) {
	root := newRoot(t, "docker/.env", "DOMAIN=example.com\nCOMPOSE_PROJECT_NAME=site\nSITE_PREFIX=site\n")
	useRoot(t, root)
	useStderr(t)
	noComposeCLI(t)
	saveState(t, root, rollbackState())
	const url = "https://example.com/manifest.json"
	inst, err := instance.Detect(root)
	if err != nil {
		t.Fatal(err)
	}
	saveLatestKnown(inst, map[string]*latestKnown{url: {Read: time.Now(), Version: "1.1.0"}})
	running := func() []engineContainer {
		return []engineContainer{{name: "site-nginx", service: "nginx", image: "example/nginx:1.1.0", state: "running"}}
	}
	fakeEngine(t, "site", running)
	const want = "Rollback     the images of 1.0.0 are not on this machine (1): a rollback pulls them first, and is refused while the registry cannot be reached\n"
	out, err := runKvsctl(t, "status", "--root", root, "--manifest", url)
	if err != nil || !strings.Contains(out, want) {
		t.Fatalf("status (%v) lacks %q:\n%s", err, want, out)
	}
	m := &manifest.Manifest{Releases: []manifest.Release{{Version: "1.2.0", Date: "2026-10-05"}, {Version: "1.1.0", Date: "2026-10-01"}, {Version: "1.0.0", Date: "2026-09-01"}}}
	plans := map[string]*upgrade.Plan{
		"up to date": {Current: "1.1.0", Previous: "1.0.0", Target: &m.Releases[1], Manifest: m, UpToDate: true},
		"one way":    {Current: "1.1.0", Previous: "1.0.0", Target: &m.Releases[0], Manifest: m, Releases: m.Releases[:1], OneWay: true, Database: "migrates", TrackedFiles: 1},
	}
	for name, plan := range plans {
		usePlan(t, plan)
		out, err = runKvsctl(t, "check", "--root", root, "--manifest", url)
		if err != nil || strings.Contains(out, "the images of 1.0.0") {
			t.Errorf("check of a plan %s (%v) names the images of 1.0.0:\n%s", name, err, out)
		}
	}

	fakeEngine(t, "site", running, engineImage{tags: []string{"example/nginx:1.0.0"}, digests: []string{"example/nginx@sha256:" + strings.Repeat("1", 64)}})
	out, err = runKvsctl(t, "status", "--root", root, "--manifest", url)
	if err != nil || strings.Contains(out, "\nRollback ") {
		t.Errorf("status with the images on the machine (%v):\n%s", err, out)
	}
}

// status and check say which engine they read when it is not the one
// Docker listens on by default, a rootless one or another docker context:
// what they show is that engine's.
func TestStatusNamesAnEngineThatIsNotTheDefault(t *testing.T) {
	root := newRoot(t, "docker/.env", "DOMAIN=example.com\nCOMPOSE_PROJECT_NAME=site\nSITE_PREFIX=site\n")
	useRoot(t, root)
	useStderr(t)
	fakeEngine(t, "site", func() []engineContainer {
		return []engineContainer{{name: "site-nginx", service: "nginx", image: "nginx:1.29", state: "running"}}
	})
	want := "Engine       " + os.Getenv("DOCKER_HOST") + "\n"
	out, err := runKvsctl(t, "status", "--root", root, "--manifest", "https://example.com/manifest.json")
	if err != nil || !strings.Contains(out, want) {
		t.Fatalf("status (%v) lacks %q:\n%s", err, want, out)
	}
	saveState(t, root, &instance.State{Current: "1.0.0", Files: []string{"docker/docker-compose.yml"}})
	plan := readyPlan()
	plan.Architecture = "x86_64"
	usePlan(t, plan)
	out, err = runKvsctl(t, "check", "--root", root, "--manifest", "https://example.com/manifest.json")
	if want := "Engine       runs on x86_64 at " + os.Getenv("DOCKER_HOST") + "\n"; err != nil || !strings.Contains(out, want) {
		t.Fatalf("check (%v) lacks %q:\n%s", err, want, out)
	}
}

// A Ctrl-C while status reads the manifest stops the read at once, and
// status exits 1: a script that reads its output learns it was cut short.
// The read is not remembered as a failure of the server.
func TestStatusInterruptedDuringItsRead(t *testing.T) {
	root := newRoot(t, "docker/.env", "DOMAIN=example.com\nCOMPOSE_PROJECT_NAME=site\nSITE_PREFIX=site\n")
	useRoot(t, root)
	useStderr(t)
	inst := saveState(t, root, &instance.State{Current: "1.0.0"})
	fakeEngine(t, "site", func() []engineContainer {
		return []engineContainer{{name: "site-nginx", service: "nginx", image: "nginx:1.29", state: "running"}}
	})
	asked := make(chan struct{}, 1)
	server := httptest.NewServer(http.HandlerFunc(func(_ http.ResponseWriter, r *http.Request) {
		select {
		case asked <- struct{}{}:
		default:
		}
		<-r.Context().Done()
	}))
	t.Cleanup(server.Close)
	go func() {
		<-asked
		_ = syscall.Kill(os.Getpid(), syscall.SIGINT)
	}()
	start := time.Now()
	out, err := runKvsctl(t, "status", "--root", root, "--manifest", server.URL+"/manifest.json")
	if err == nil || err.Error() != "interrupted" || time.Since(start) > 10*time.Second {
		t.Fatalf("status cut by a Ctrl-C: %v after %s\n%s", err, time.Since(start), out)
	}
	if want := "Updates      could not check (the read of the manifest was interrupted)\n"; !strings.Contains(out, want) {
		t.Fatalf("status lacks %q:\n%s", want, out)
	}
	if known := loadLatestKnown(inst)[server.URL+"/manifest.json"]; known != nil && !known.Failed.IsZero() {
		t.Fatalf("the interrupted read is remembered as a failure: %+v", known)
	}
}

// childEnv names, in the environment of a test binary inChild started, the
// test it runs.
const childEnv = "KVSCTL_TEST_CHILD"

// inChild runs the test that calls it again, alone, in a test process of
// its own, and fails it with the output of that run when that run fails;
// it reports whether this is that process. A test of what a process
// remembers for its life, manifest.Fetch failing every read once an
// interrupt ended one, needs a process no other test has touched.
func inChild(t *testing.T) bool {
	t.Helper()
	if os.Getenv(childEnv) == t.Name() {
		return true
	}
	cmd := exec.Command(os.Args[0], "-test.run=^"+regexp.QuoteMeta(t.Name())+"$", "-test.count=1", "-test.v")
	cmd.Env = append(os.Environ(), childEnv+"="+t.Name())
	if out, err := cmd.CombinedOutput(); err != nil {
		t.Fatalf("%s in a process of its own: %v\n%s", t.Name(), err, out)
	}
	return false
}

// interruptAt is the stdout of a kvsctl run that interrupts it once, as it
// writes a line that starts with prefix: the Ctrl-C then comes at a point
// of the run the test chooses. The write returns once the signal reached
// the handlers kvsctl registered, so a handler registered after it never
// sees it.
type interruptAt struct {
	lockedBuffer
	prefix string
	sent   atomic.Bool
}

func (w *interruptAt) Write(p []byte) (int, error) {
	n, err := w.lockedBuffer.Write(p)
	if !bytes.HasPrefix(p, []byte(w.prefix)) || w.sent.Swap(true) {
		return n, err
	}
	seen := make(chan os.Signal, 1)
	signal.Notify(seen, syscall.SIGINT)
	defer signal.Stop(seen)
	if kerr := syscall.Kill(os.Getpid(), syscall.SIGINT); kerr == nil {
		select {
		case <-seen:
		case <-time.After(5 * time.Second):
		}
	}
	return n, err
}

// A Ctrl-C that comes before status reads the manifest ends that read as
// soon as it starts, rather than leaving it to wait for a server that does
// not answer: the read takes the context of status, which the Ctrl-C
// cancelled, and not a handler of its own, which a signal gone by never
// reaches.
func TestStatusStopsAtACtrlCBeforeItsRead(t *testing.T) {
	if !inChild(t) {
		return
	}
	root := newRoot(t, "docker/.env", "DOMAIN=example.com\nCOMPOSE_PROJECT_NAME=site\nSITE_PREFIX=site\n")
	useRoot(t, root)
	useStderr(t)
	saveState(t, root, &instance.State{Current: "1.0.0"})
	fakeEngine(t, "site", func() []engineContainer {
		return []engineContainer{{name: "site-nginx", service: "nginx", image: "nginx:1.29", state: "running"}}
	})
	unblock := make(chan struct{})
	server := httptest.NewServer(http.HandlerFunc(func(_ http.ResponseWriter, r *http.Request) {
		select {
		case <-r.Context().Done():
		case <-unblock:
		}
	}))
	t.Cleanup(server.Close)
	t.Cleanup(func() { close(unblock) })
	oldWait := statusWait
	statusWait = 3 * time.Second
	t.Cleanup(func() { statusWait = oldWait })
	keepFlags(t)
	// status prints its MariaDB line once it has read the engine, and
	// before it reads the manifest.
	out := &interruptAt{lockedBuffer: lockedBuffer{b: &bytes.Buffer{}}, prefix: "MariaDB "}
	oldOut := stdout
	stdout = out
	t.Cleanup(func() { stdout = oldOut })
	cmd := rootCmd()
	cmd.SetArgs([]string{"status", "--root", root, "--manifest", server.URL + "/manifest.json"})
	start := time.Now()
	err := cmd.Execute()
	took := time.Since(start)
	if !out.sent.Load() {
		t.Fatalf("status printed no MariaDB line:\n%s", out.String())
	}
	if err == nil || err.Error() != "interrupted" || took > statusWait/2 {
		t.Fatalf("status with a Ctrl-C before its read: %v after %s\n%s", err, took, out.String())
	}
	if want := "Updates      could not check (the read of the manifest was interrupted)\n"; !strings.Contains(out.String(), want) {
		t.Fatalf("status lacks %q:\n%s", want, out.String())
	}
}
