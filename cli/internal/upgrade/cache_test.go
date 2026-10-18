package upgrade

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"slices"
	"strings"
	"sync/atomic"
	"testing"
)

// cacheRoute models only the one-off PHP helper. The helper itself is also
// exercised against real PHP and both cache engines by the Docker tests.
func cacheRoute(s *stack, initial string) *atomic.Value {
	if err := s.runner().Inst.SetEnv("COMPOSE_PROFILES", "memcached"); err != nil {
		s.t.Fatal(err)
	}
	s.f.with(func(f *fakeDocker) {
		f.held = append(f.held, &fakeImage{id: digestOf("id memcached:1.6"), repo: "memcached", digest: digestOf("memcached:1.6"), tags: []string{"1.6"}})
		if resp := f.up(s.runner().Inst.DockerDir, nil, ""); resp.Code != 0 {
			s.t.Fatalf("start cache fixture: %s", resp.Stderr)
		}
	})
	host := new(atomic.Value)
	host.Store(initial)
	s.f.hook = func(_ *fakeDocker, req cliRequest) (cliResponse, bool) {
		if !strings.Contains(strings.Join(req.Args, " "), "KVSCTL_CACHE_ROUTING") {
			return cliResponse{}, false
		}
		args := req.Args
		mode, before, after := args[len(args)-3], args[len(args)-2], args[len(args)-1]
		if mode == "inspect" {
			data, _ := json.Marshal(map[string]any{"host": host.Load(), "port": 11211, "supported": true})
			return cliResponse{Stdout: string(data)}, true
		}
		if host.Load() == before {
			host.Store(after)
		}
		return cliResponse{Stdout: "{}"}, true
	}
	return host
}

func runCacheUpgrade(s *stack, r *Runner) error {
	state, plan := s.plan(r)
	if err := json.Unmarshal([]byte(`{"cache_routing":"direct"}`), plan.Target); err != nil {
		s.t.Fatal(err)
	}
	return r.Run(context.Background(), state, plan)
}

func TestUpgradeMigratesLoopbackCacheAndRollbackRestoresIt(t *testing.T) {
	s := newStack(t, "", rel{version: "1.0.0"}, rel{version: "1.1.0"})
	host := cacheRoute(s, "127.0.0.1")
	if err := runCacheUpgrade(s, s.runner()); err != nil {
		t.Fatal(err)
	}
	if host.Load() != "cache" {
		t.Fatalf("upgrade left cache traffic through the relay: host=%q", host.Load())
	}
	if err := s.rollback(s.runner()); err != nil {
		t.Fatal(err)
	}
	if host.Load() != "127.0.0.1" {
		t.Fatalf("rollback did not restore the previous cache route: %q", host.Load())
	}
	if err := runCacheUpgrade(s, s.runner()); err != nil {
		t.Fatal(err)
	}
	if host.Load() != "cache" {
		t.Fatalf("return to direct release lost its cache route: %q", host.Load())
	}
}

func TestFailedCacheUpgradeRestoresLoopback(t *testing.T) {
	s := newStack(t, "", rel{version: "1.0.0"}, rel{version: "1.1.0"})
	host := cacheRoute(s, "localhost")
	s.f.behave(s.images["1.1.0"]["php-fpm@8.1"].Ref, behavior{unhealthy: true})
	err := runCacheUpgrade(s, s.runner(quick))
	if !errors.Is(err, ErrRolledBack) {
		t.Fatalf("upgrade: %v", err)
	}
	if host.Load() != "localhost" {
		t.Fatalf("failed upgrade changed the old cache route: %q", host.Load())
	}
}

func TestCacheUpgradePreservesDisabledAndCustomTargets(t *testing.T) {
	for _, initial := range []string{"", "remote-cache", "cache"} {
		t.Run(initial, func(t *testing.T) {
			s := newStack(t, "", rel{version: "1.0.0"}, rel{version: "1.1.0"})
			host := cacheRoute(s, initial)
			if err := runCacheUpgrade(s, s.runner()); err != nil {
				t.Fatal(err)
			}
			if host.Load() != initial {
				t.Fatalf("operator cache target replaced: %q", host.Load())
			}
		})
	}
}

func TestRecoverRestoresCacheAfterInterruptedUpgrade(t *testing.T) {
	s := newStack(t, "", rel{version: "1.0.0"}, rel{version: "1.1.0"})
	host := cacheRoute(s, "127.0.0.1")
	s.rep.cut = isStep(KindStepDone, StepApply)
	cutRun(t, s.rep, func() { _ = runCacheUpgrade(s, s.runner()) })
	if host.Load() != "cache" || s.journal().CacheChange == nil {
		t.Fatal("the cut did not leave a journaled cache migration")
	}
	s.fresh()
	if err := s.recover(s.runner()); err != nil {
		t.Fatal(err)
	}
	if host.Load() != "127.0.0.1" {
		t.Fatalf("recover left the interrupted cache route: %q", host.Load())
	}
}

func TestRecoverRestoresDirectCacheWhileRollbackServicesAreStopped(t *testing.T) {
	php, err := exec.LookPath("php")
	if err != nil {
		t.Skip("PHP is needed to exercise the real cache undo helper")
	}
	if err := exec.Command(php, "-n", "-r", `exit(function_exists('token_get_all') && function_exists('ctype_digit') && function_exists('fsync') ? 0 : 1);`).Run(); err != nil {
		t.Skip("PHP needs tokenizer, ctype and fsync without extensions for the native cache undo check")
	}
	s := newStack(t, "", rel{version: "1.0.0"}, rel{version: "1.1.0", database: migrates})
	host := cacheRoute(s, "127.0.0.1")
	setup := filepath.Join(t.TempDir(), "setup.php")
	helper := strings.Replace(cacheConfigPHP, "$path = '/var/www/kvs/admin/include/setup.php';", "$path = getenv('KVSCTL_TEST_SETUP');", 1)
	if helper == cacheConfigPHP {
		t.Fatal("the cache helper fixture did not replace the setup.php path")
	}
	runPHP := func(mode, before, after string) ([]byte, error) {
		// No extensions are loaded: undo must restore a journaled route
		// without trying to contact the cache that rollback stopped.
		cmd := exec.Command(php, "-n", "-r", strings.TrimPrefix(helper, "<?php\n"), "--", mode, before, after)
		cmd.Env = append(os.Environ(), "KVSCTL_TEST_SETUP="+setup, "KVS_MEMCACHE_HOST=cache", "KVS_MEMCACHE_PORT=11211")
		return cmd.CombinedOutput()
	}
	modeled := s.f.hook
	var undos atomic.Int32
	s.f.hook = func(f *fakeDocker, req cliRequest) (cliResponse, bool) {
		args := req.Args
		if !strings.Contains(strings.Join(args, " "), "KVSCTL_CACHE_ROUTING") || args[len(args)-3] != "undo" {
			return modeled(f, req)
		}
		source := fmt.Sprintf("<?php\n$config['memcache_server'] = '%s';\n$config['memcache_port'] = 11211;\n", host.Load())
		if err := os.WriteFile(setup, []byte(source), 0600); err != nil {
			return cliResponse{Code: 1, Stderr: err.Error()}, true
		}
		if out, err := runPHP("undo", args[len(args)-2], args[len(args)-1]); err != nil {
			return cliResponse{Code: 1, Stderr: fmt.Sprintf("%s: %v", out, err)}, true
		}
		out, err := runPHP("inspect", "", "")
		if err != nil {
			return cliResponse{Code: 1, Stderr: fmt.Sprintf("%s: %v", out, err)}, true
		}
		var config cacheConfig
		if err := json.Unmarshal(out, &config); err != nil {
			return cliResponse{Code: 1, Stderr: err.Error()}, true
		}
		host.Store(config.Host)
		undos.Add(1)
		return cliResponse{Stdout: "{}"}, true
	}
	if err := runCacheUpgrade(s, s.runner()); err != nil {
		t.Fatal(err)
	}
	s.fresh()
	s.rep.cut = isStep(KindStepDone, StepApply)
	cutRun(t, s.rep, func() { _ = s.rollback(s.runner()) })
	if host.Load() != "127.0.0.1" || !slices.Contains(s.stopped(), "memcached") {
		t.Fatalf("rollback did not restore loopback with its cache stopped: host=%v, stopped=%v", host.Load(), s.stopped())
	}
	s.fresh()
	if err := s.recover(s.runner()); err != nil {
		t.Fatal(err)
	}
	if host.Load() != "cache" || len(s.stopped()) != 0 || undos.Load() != 2 {
		t.Fatalf("recover did not restore the route and services: host=%v, stopped=%v, native undos=%d", host.Load(), s.stopped(), undos.Load())
	}
	if s.journal() != nil {
		t.Fatal("successful recovery left its journal behind")
	}
}

func TestCacheMigrationSurvivesSameReleaseReapply(t *testing.T) {
	s := newStack(t, "", rel{version: "1.0.0"}, rel{version: "1.1.0", php: []string{"8.1", "8.2"}})
	host := cacheRoute(s, "127.0.0.1")
	if err := runCacheUpgrade(s, s.runner()); err != nil {
		t.Fatal(err)
	}
	s.setEnv("PHP_VERSION", "8.2")
	if err := runCacheUpgrade(s, s.runner()); err != nil {
		t.Fatal(err)
	}
	if err := s.rollback(s.runner()); err != nil {
		t.Fatal(err)
	}
	if host.Load() != "127.0.0.1" {
		t.Fatalf("reapply lost the original cache route: %q", host.Load())
	}
}

func TestKvsctlCacheMigrationFromSignedRelease(t *testing.T) {
	s := newStack(t, "", rel{version: "1.0.0"}, rel{version: "1.1.0"})
	host := cacheRoute(s, "127.0.0.1")
	s.release("1.1.0").CacheRouting = "direct"
	s.writeManifest()
	for _, command := range []string{"upgrade", "rollback"} {
		run := s.kvsctl(pipes, command, "--yes", "--plain")
		if code := run.wait(); code != 0 {
			t.Fatalf("kvsctl %s failed: %s", command, run.output())
		}
		want := "cache"
		if command == "rollback" {
			want = "127.0.0.1"
		}
		if host.Load() != want {
			t.Fatalf("kvsctl %s left cache host %q, want %q", command, host.Load(), want)
		}
	}
}

func TestReleaseWithoutCacheMigrationLeavesLoopbackUntouched(t *testing.T) {
	s := newStack(t, "", rel{version: "1.0.0"}, rel{version: "1.1.0"})
	host := cacheRoute(s, "127.0.0.1")
	if err := s.upgrade(s.runner()); err != nil {
		t.Fatal(err)
	}
	if host.Load() != "127.0.0.1" {
		t.Fatal("an older release unexpectedly changed the application's cache host")
	}
}

func TestCacheRollbackPreservesLaterOperatorChoice(t *testing.T) {
	s := newStack(t, "", rel{version: "1.0.0"}, rel{version: "1.1.0"})
	host := cacheRoute(s, "127.0.0.1")
	if err := runCacheUpgrade(s, s.runner()); err != nil {
		t.Fatal(err)
	}
	host.Store("operator-cache")
	if err := s.rollback(s.runner()); err != nil {
		t.Fatal(err)
	}
	if host.Load() != "operator-cache" {
		t.Fatal("rollback overwrote the operator's new cache host")
	}
}
