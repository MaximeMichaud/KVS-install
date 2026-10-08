package dockerx

import (
	"context"
	"encoding/json"
	"os"
	"os/exec"
	"path/filepath"
	"slices"
	"strings"
	"testing"

	"github.com/MaximeMichaud/KVS-install/cli/internal/dotenv"
)

// A shell that sourced an older .env exports every key of it. The compose
// children of kvsctl never take from it a setting the project .env or the
// .env.example of its release gives, nor one kvsctl owns, such as the image
// pins; a key the .env leaves to the environment still comes from it.
func TestComposeTakesTheSettingsFromTheProject(t *testing.T) {
	log := installFakeDocker(t, "lines")
	dir := t.TempDir()
	env := "DOMAIN=example.com\nKVS_PHP_FPM_IMAGE=registry.example/php:1.1.0@" + digestA + "\nFROM_SHELL\n"
	if err := os.WriteFile(filepath.Join(dir, ".env"), []byte(env), 0o600); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(dir, ".env.example"), []byte("NEW_SETTING=1\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	for key, value := range map[string]string{
		"DOMAIN": "old.example", "KVS_PHP_FPM_IMAGE": "registry.example/php:1.0.0@" + digestB,
		"KVS_CRON_IMAGE": "registry.example/cron:1.0.0@" + digestB, "MARIADB_VERSION": "10.11",
		"NEW_SETTING": "from the shell", "COMPOSE_ENV_FILES": "/elsewhere/.env", "COMPOSE_DISABLE_ENV_FILE": "1",
		"FROM_SHELL": "kept",
	} {
		t.Setenv(key, value)
	}
	if _, err := ComposeStarted(context.Background(), dir, nil, "up", "-d"); err != nil {
		t.Fatal(err)
	}
	text := readLog(t, log)
	for _, key := range []string{"DOMAIN", "KVS_PHP_FPM_IMAGE", "KVS_CRON_IMAGE", "MARIADB_VERSION", "NEW_SETTING", "COMPOSE_ENV_FILES", "COMPOSE_DISABLE_ENV_FILE"} {
		if got := logged(text, key); got != "unset" {
			t.Errorf("%s=%s reached compose from the shell", key, got)
		}
	}
	if got := logged(text, "FROM_SHELL"); got != "kept" {
		t.Errorf("FROM_SHELL = %q: a key the .env leaves to the environment must reach compose", got)
	}
}

// An installation reached through a link keeps that name in compose, as in
// the shell of the scripts: PWD names the directory kvsctl was given.
func TestComposeRunsUnderTheNameOfTheProjectDirectory(t *testing.T) {
	log := installFakeDocker(t, "lines")
	real := t.TempDir()
	link := filepath.Join(t.TempDir(), "kvs")
	if err := os.Symlink(real, link); err != nil {
		t.Fatal(err)
	}
	if _, err := ComposeStarted(context.Background(), link, nil, "up", "-d"); err != nil {
		t.Fatal(err)
	}
	text := readLog(t, log)
	if got := logged(text, "PWD"); got != link {
		t.Errorf("compose ran with PWD %q, want the name it was given, %q", got, link)
	}
	if resolved, _ := filepath.EvalSymlinks(real); logged(text, "dir") != resolved {
		t.Errorf("compose ran in %q, want %q", logged(text, "dir"), resolved)
	}
	if _, err := composeConfig(context.Background(), link, "config", "--quiet"); err != nil {
		t.Fatal(err)
	}
	if got := logged(strings.SplitAfterN(readLog(t, log), "args=compose config", 2)[1], "PWD"); got != link {
		t.Errorf("compose config ran with PWD %q, want %q", got, link)
	}
}

// The real docker compose, on a project whose .env pins an image, with an
// older pin and an older domain exported: compose resolves what kvsctl
// reads from the .env, through the environment kvsctl gives it. It runs
// "docker compose config", which needs no engine, and only when
// KVSCTL_COMPOSE_PARITY=1, since it needs the compose plugin.
func TestComposeResolvesWhatKvsctlReads(t *testing.T) {
	if os.Getenv("KVSCTL_COMPOSE_PARITY") != "1" {
		t.Skip("set KVSCTL_COMPOSE_PARITY=1 to compare with docker compose")
	}
	if _, err := exec.LookPath("docker"); err != nil {
		t.Skip("docker is not installed")
	}
	real := t.TempDir()
	dir := filepath.Join(t.TempDir(), "kvs")
	if err := os.Symlink(real, dir); err != nil {
		t.Fatal(err)
	}
	compose := "name: kvsctltest-files-parity\nservices:\n  php-fpm:\n    image: \"${KVS_PHP_FPM_IMAGE:?set}\"\n    environment:\n      - SITE=${DOMAIN}\n      - WEB=${WEB_ROOT}\n    volumes:\n      - ./conf:/conf\n"
	env := "export DOMAIN=example.com # the site\n" +
		"KVS_PHP_FPM_IMAGE=registry.example/php:1.1.0@" + digestA + "\n" +
		"WEB_ROOT=/var/www/${DOMAIN}\n" +
		"FROM_SHELL\n"
	for name, content := range map[string]string{"docker-compose.yml": compose, ".env": env, ".env.example": "NEW_SETTING=1\n"} {
		if err := os.WriteFile(filepath.Join(real, name), []byte(content), 0o644); err != nil {
			t.Fatal(err)
		}
	}
	t.Setenv("DOMAIN", "old.example")
	t.Setenv("KVS_PHP_FPM_IMAGE", "registry.example/php:1.0.0@"+digestB)
	t.Setenv("FROM_SHELL", "kept")
	images, err := composeConfig(context.Background(), dir, "config", "--images")
	if err != nil {
		t.Fatal(err)
	}
	data, _ := os.ReadFile(filepath.Join(real, ".env"))
	example, _ := os.ReadFile(filepath.Join(real, ".env.example"))
	read, err := dotenv.Parse(data, dotenv.Lookup(os.Environ(), data, example))
	if err != nil {
		t.Fatal(err)
	}
	if got := strings.TrimSpace(images); got != read["KVS_PHP_FPM_IMAGE"] {
		t.Errorf("compose runs %q, kvsctl reads %q", got, read["KVS_PHP_FPM_IMAGE"])
	}
	out, err := composeConfig(context.Background(), dir, "config", "--format=json")
	if err != nil {
		t.Fatal(err)
	}
	var project struct {
		Services map[string]struct {
			Environment map[string]string `json:"environment"`
			Volumes     []struct {
				Source string `json:"source"`
			} `json:"volumes"`
		} `json:"services"`
	}
	if err := json.Unmarshal([]byte(out), &project); err != nil {
		t.Fatal(err)
	}
	php := project.Services["php-fpm"]
	if php.Environment["SITE"] != read["DOMAIN"] || php.Environment["WEB"] != read["WEB_ROOT"] || read["DOMAIN"] != "example.com" {
		t.Errorf("compose reads SITE=%q WEB=%q, kvsctl reads DOMAIN=%q WEB_ROOT=%q", php.Environment["SITE"], php.Environment["WEB"], read["DOMAIN"], read["WEB_ROOT"])
	}
	if len(php.Volumes) != 1 || php.Volumes[0].Source != filepath.Join(dir, "conf") {
		t.Errorf("compose mounts %+v, want %s: the name the installation was reached by", php.Volumes, filepath.Join(dir, "conf"))
	}
}

// ServicesOf has the real docker compose read a compose file given whole
// on its stdin: the services the profiles it is given turn on, the
// variables the file requires taken from the settings it is given,
// whatever a shell exported. Gated like TestComposeResolvesWhatKvsctlReads.
func TestServicesOfReadsTheFileItIsGiven(t *testing.T) {
	if os.Getenv("KVSCTL_COMPOSE_PARITY") != "1" {
		t.Skip("set KVSCTL_COMPOSE_PARITY=1 to compare with docker compose")
	}
	if _, err := exec.LookPath("docker"); err != nil {
		t.Skip("docker is not installed")
	}
	compose := []byte("services:\n  web:\n    image: \"web:${TAG:?set it}\"\n  cache:\n    image: cache\n    profiles: [cache]\n  search:\n    image: search\n    profiles: [search]\n")
	for key, value := range map[string]string{"COMPOSE_FILE": "elsewhere.yml", "COMPOSE_PROFILES": "search", "COMPOSE_PROJECT_NAME": "other", "TAG": ""} {
		t.Setenv(key, value)
	}
	services, err := ServicesOf(context.Background(), compose, map[string]string{"TAG": "1", "COMPOSE_PROFILES": "cache"})
	if err != nil || !slices.Equal(services, []string{"cache", "web"}) {
		t.Fatalf("services %q, %v; want cache and web", services, err)
	}
	if _, err := ServicesOf(context.Background(), compose, map[string]string{"COMPOSE_PROFILES": ""}); err == nil || !strings.Contains(err.Error(), "set it") {
		t.Errorf("a variable the file requires, set to nothing: %v, want what compose said", err)
	}
}
