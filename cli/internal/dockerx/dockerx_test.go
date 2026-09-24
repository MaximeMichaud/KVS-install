package dockerx

import (
	"os"
	"strings"
	"testing"
	"time"
)

func TestProblems(t *testing.T) {
	now := time.Now()
	states := []ContainerState{
		{Name: "kvs-php", Service: "php-fpm", State: "restarting", Exit: 1, Restarts: 4, Started: now.Add(-time.Second)},
		{Name: "kvs-mariadb", Service: "mariadb", State: "running", Health: "starting", Started: now.Add(-time.Hour)},
		{Name: "kvs-nginx", Service: "nginx", State: "running", Restarts: 1, Started: now.Add(-2 * time.Second)},
		{Name: "kvs-cron", Service: "cron", State: "running", Restarts: 7, Started: now.Add(-time.Hour)},
		{Name: "kvs-init", Service: "kvs-init", State: "exited", Exit: 0},
		{Name: "kvs-run-1", Service: "phpmyadmin-init", State: "exited", OneShot: true},
	}
	baseline := map[string]int{"kvs-php": 1, "kvs-cron": 7}
	problems, crashLoop := Problems(states, baseline, now)
	if len(problems) != 3 || !strings.Contains(problems[0], "kvs-php is restarting (exit 1)") || !strings.Contains(problems[1], "kvs-mariadb is starting") || !strings.Contains(problems[2], "kvs-nginx restarted 1 times") {
		t.Errorf("Problems = %v", problems)
	}
	if !crashLoop {
		t.Error("php restarted three times since the baseline: that is a crash loop")
	}
	// Once php stays up, nginx has settled and MariaDB passes its check,
	// the old restart counts mean nothing.
	states[0] = ContainerState{Name: "kvs-php", Service: "php-fpm", State: "running", Restarts: 4, Started: now.Add(-time.Minute)}
	states[1].Health = "healthy"
	states[2].Started = now.Add(-time.Minute)
	problems, crashLoop = Problems(states, baseline, now)
	if len(problems) != 0 || crashLoop {
		t.Errorf("settled project: %v %v", problems, crashLoop)
	}
	if found := ByService(states, "mariadb"); found == nil || found.Name != "kvs-mariadb" {
		t.Errorf("ByService(mariadb) = %+v", found)
	}
	if found := ByService(states, "manticore"); found != nil {
		t.Errorf("a service the project does not run has no container: %+v", found)
	}
}

func TestComposeEnv(t *testing.T) {
	t.Setenv("COMPOSE_FILE", "docker-compose.yml")
	t.Setenv("COMPOSE_PROFILES", "memcached")
	t.Setenv("COMPOSE_PROJECT_NAME", "kvs-old")
	t.Setenv("COMPOSE_PATH_SEPARATOR", ",")
	t.Setenv("KVS_INSTALL_DIR", "/opt/kvs")
	env := composeEnv()
	seen := map[string]string{}
	for _, entry := range env {
		key, value, _ := strings.Cut(entry, "=")
		seen[key] = value
	}
	for _, key := range []string{"COMPOSE_FILE", "COMPOSE_PROFILES", "COMPOSE_PROJECT_NAME", "COMPOSE_PATH_SEPARATOR"} {
		if _, ok := seen[key]; ok {
			t.Errorf("%s must come from the .env of the project, not from the shell", key)
		}
	}
	if seen["KVS_INSTALL_DIR"] != "/opt/kvs" {
		t.Error("the rest of the environment must reach docker compose")
	}
	if seen["COMPOSE_PROGRESS"] != "plain" {
		t.Error("compose must print plain progress")
	}
	if len(env) != len(os.Environ())-4+1 {
		t.Errorf("composeEnv dropped %d entries, want 4", len(os.Environ())-len(env)+1)
	}
}
