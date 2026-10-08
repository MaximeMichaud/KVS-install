package dockerx

import (
	"os"
	"path/filepath"
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
	dir := t.TempDir()
	if err := os.WriteFile(filepath.Join(dir, ".env"), []byte("DOMAIN=example.com\nexport KVS_PHP_FPM_IMAGE=r/php@sha256:1\nFROM_SHELL\n"), 0o600); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(dir, ".env.example"), []byte("NEW_SETTING=1\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	for key, value := range map[string]string{
		"COMPOSE_FILE": "docker-compose.yml", "COMPOSE_PROFILES": "memcached", "COMPOSE_PROJECT_NAME": "kvs-old",
		"COMPOSE_PATH_SEPARATOR": ",", "COMPOSE_ENV_FILES": "/elsewhere/.env", "COMPOSE_DISABLE_ENV_FILE": "1",
		"DOMAIN": "old.example", "KVS_PHP_FPM_IMAGE": "r/php@sha256:0", "KVS_CRON_IMAGE": "r/cron@sha256:0",
		"MARIADB_VERSION": "10.11", "NEW_SETTING": "from the shell", "FROM_SHELL": "kept",
		"KVS_INSTALL_DIR": "/opt/kvs", "PWD": "/somewhere/else",
	} {
		t.Setenv(key, value)
	}
	seen := map[string]string{}
	for _, entry := range composeEnv(dir) {
		key, value, _ := strings.Cut(entry, "=")
		if _, dup := seen[key]; dup {
			t.Errorf("%s is set twice", key)
		}
		seen[key] = value
	}
	for _, key := range []string{"COMPOSE_FILE", "COMPOSE_PROFILES", "COMPOSE_PROJECT_NAME", "COMPOSE_PATH_SEPARATOR",
		"COMPOSE_ENV_FILES", "COMPOSE_DISABLE_ENV_FILE", "DOMAIN", "KVS_PHP_FPM_IMAGE", "KVS_CRON_IMAGE", "MARIADB_VERSION", "NEW_SETTING"} {
		if value, ok := seen[key]; ok {
			t.Errorf("%s=%s reached compose from the shell: the project owns it", key, value)
		}
	}
	if seen["FROM_SHELL"] != "kept" || seen["KVS_INSTALL_DIR"] != "/opt/kvs" || seen["PATH"] == "" {
		t.Error("the rest of the environment must reach docker compose")
	}
	if got := seen["PWD"]; got != dir {
		t.Errorf("PWD = %q, want the project directory %q", got, dir)
	}
	if seen["COMPOSE_PROGRESS"] != "plain" {
		t.Error("compose must print plain progress")
	}
	// A command on no project only loses the keys kvsctl owns.
	seen = map[string]string{}
	for _, entry := range composeEnv("") {
		key, value, _ := strings.Cut(entry, "=")
		seen[key] = value
	}
	if image, ok := seen["KVS_CRON_IMAGE"]; ok || seen["DOMAIN"] != "old.example" || seen["PWD"] != "/somewhere/else" {
		// Only the keys of the test: the rest of the environment may
		// hold credentials.
		t.Errorf("composeEnv without a project: KVS_CRON_IMAGE=%q (set %v), DOMAIN=%q, PWD=%q", image, ok, seen["DOMAIN"], seen["PWD"])
	}
}
