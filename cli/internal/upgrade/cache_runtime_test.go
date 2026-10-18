package upgrade

import (
	"context"
	"encoding/json"
	"os"
	"testing"
	"time"

	"github.com/MaximeMichaud/KVS-install/cli/internal/dockerx"
	"github.com/MaximeMichaud/KVS-install/cli/internal/instance"
)

// tests/integration_cache.py supplies an isolated real Compose project.
// This runs kvsctl's actual helper path, including its Compose environment.
func TestCacheCommandRealDocker(t *testing.T) {
	dir := os.Getenv("KVSCTL_CACHE_RUNTIME_DIR")
	if dir == "" {
		t.Skip("run tests/integration_cache.py for real cache migration checks")
	}
	backend := os.Getenv("KVSCTL_CACHE_RUNTIME_BACKEND")
	r := &Runner{Inst: &instance.Instance{DockerDir: dir}, Reporter: &recorder{}}
	ctx := context.Background()
	check := func(want string) {
		t.Helper()
		out, err := r.cacheCommand(ctx, "inspect", "", "")
		if err != nil {
			t.Fatal(err)
		}
		var config cacheConfig
		if err := json.Unmarshal([]byte(out), &config); err != nil || !config.Supported || config.Host != want {
			t.Fatalf("cache setting: %s, %v", out, err)
		}
	}
	check("127.0.0.1")
	change, err := r.cacheChange(ctx, "direct", []string{backend})
	if err != nil || change == nil {
		t.Fatalf("prepare cache migration: %+v, %v", change, err)
	}
	if err := dockerx.Compose(ctx, dir, nil, "stop", backend); err != nil {
		t.Fatal(err)
	}
	// An unavailable backend must be detected before setup.php changes.
	if err := r.applyCache(ctx, change, false); err == nil {
		t.Fatal("the cache setting changed while its backend was stopped")
	}
	check("127.0.0.1")
	if err := dockerx.Compose(ctx, dir, nil, "start", backend); err != nil {
		t.Fatal(err)
	}
	deadline := time.Now().Add(15 * time.Second)
	for {
		err = r.applyCache(ctx, change, false)
		if err == nil || time.Now().After(deadline) {
			break
		}
		time.Sleep(100 * time.Millisecond)
	}
	if err != nil {
		t.Fatal(err)
	}
	check("cache")
	if err := r.applyCache(ctx, change, true); err != nil {
		t.Fatal(err)
	}
	check("127.0.0.1")
	if err := r.applyCache(ctx, change, false); err != nil {
		t.Fatal(err)
	}
	check("cache")
}
