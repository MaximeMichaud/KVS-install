package doctor

import (
	"context"
	"encoding/json"
	"os"
	"os/exec"
	"path/filepath"
	"slices"
	"strings"
	"testing"
	"time"

	"golang.org/x/sys/unix"

	"github.com/MaximeMichaud/KVS-install/cli/internal/dockerx"
)

func TestSpecialStateFilesCannotBlockTheDiagnostic(t *testing.T) {
	for _, name := range []string{"state.json", "journal.json", "lock"} {
		t.Run(name, func(t *testing.T) {
			r, _ := fixture(t)
			r.opts.Only = []string{"state"}
			if err := os.MkdirAll(r.inst.StateDir(), 0o700); err != nil {
				t.Fatal(err)
			}
			if err := unix.Mkfifo(filepath.Join(r.inst.StateDir(), name), 0o600); err != nil {
				t.Fatal(err)
			}
			id := "state.operation"
			if name == "state.json" {
				id = "state.record"
			}
			if got := resultByID(t, r.run(context.Background()), id); got.Status != Fail {
				t.Fatalf("%+v", got)
			}
		})
	}
}

func TestEnvSyntaxAndInterpolation(t *testing.T) {
	for _, tc := range []struct{ name, text, domain, want string }{
		{"bare", "DOMAIN=example.test\n", "example.test", OK},
		{"export-crlf", "export DOMAIN=\"example.test\"\r\nIONCUBE='NO' # comment\r\n", "example.test", OK},
		{"references", "SITE=example\nDOMAIN=${SITE}.test\n", "example.test", OK},
		{"fallback", "DOMAIN=${UNSET_DOCTOR_DOMAIN:-example.test}\n", "example.test", OK},
		{"single-quote", "DOMAIN='example.test'\nMARIADB_PASSWORD='literal-$value'\n", "example.test", OK}, // pragma: allowlist secret - synthetic parser fixture
		{"required", "DOMAIN=${UNSET_DOCTOR_DOMAIN:?required}\n", "", Fail},
		{"quote-error", "DOMAIN=example.test\nMARIADB_PASSWORD=\"fixture-secret-do-not-print\n", "", Fail},
		{"bad-key", "DOMAIN=example.test\n!PASSWORD=fixture-secret-do-not-print\n", "", Fail}, // pragma: allowlist secret - synthetic parser fixture
	} {
		t.Run(tc.name, func(t *testing.T) {
			r, _ := fixture(t)
			r.opts.Only = []string{"config.env", "storage.installation"}
			t.Setenv("DOMAIN", "shell-value-must-not-win.test")
			t.Setenv("UNSET_DOCTOR_DOMAIN", "")
			writeFile(t, r.inst.EnvPath, tc.text)
			report := r.run(context.Background())
			result := resultByID(t, report, "config.env")
			if result.Status != tc.want || report.Site != tc.domain {
				t.Fatalf("report: %+v", report)
			}
			data, _ := json.Marshal(report)
			if strings.Contains(string(data), "fixture-secret-do-not-print") {
				t.Fatal("parser error exposed a secret")
			}
			if resultByID(t, report, "storage.installation").Status != OK {
				t.Fatal("independent storage check did not run")
			}
		})
	}
}

func TestStackSettings(t *testing.T) {
	for _, tc := range []struct{ name, settings, want string }{
		{"defaults", "", OK}, {"missing-domain", "DOMAIN=\n", Fail},
		{"domain-url", "DOMAIN=https://example.test\n", Fail}, {"domain-label", "DOMAIN=bad..test\n", Fail},
		{"multi", "MODE=multi\n", Fail}, {"bad-mode", "MODE=unknown\n", Fail},
		{"ipv4", "HTTP_PORT=127.0.0.2:8080\nHTTPS_PORT=0.0.0.0:8443\n", OK},
		{"ipv6", "HTTPS_PORT=[::1]:8443\n", OK}, {"wildcard-ipv6", "HTTPS_PORT=[::]:443\n", OK},
		{"invalid-port", "HTTPS_PORT=65536\n", Fail}, {"unbracketed-ipv6", "HTTPS_PORT=::1:443\n", Fail},
		{"named-binding", "HTTPS_PORT=remote.test:443\n", Fail}, {"port-range", "HTTPS_PORT=440-443\n", Fail},
		{"selfsigned", "SSL_PROVIDER=selfsigned\n", OK}, {"zerossl", "SSL_PROVIDER=zerossl\n", OK}, {"unknown-tls", "SSL_PROVIDER=none\n", Fail},
		{"ioncube-off", "IONCUBE=off\n", OK}, {"ioncube-on", "IONCUBE=TrUe\n", OK}, {"ioncube-typo", "IONCUBE=maybe\n", Fail},
		{"cf-www", "CLOUDFLARE_ENABLED=true\nUSE_WWW=true\n", OK}, {"boolean-typo", "USE_WWW=yes\n", Fail},
		{"both-caches", "COMPOSE_PROFILES=dragonfly,memcached\n", Fail}, {"search-profile", "COMPOSE_PROFILES=dragonfly,manticore\n", OK},
		{"php84", "PHP_VERSION=8.4\n", OK}, {"unsupported-php", "PHP_VERSION=7.4\n", Fail},
		{"invalid-auto-update", "YT_DLP_AUTO_UPDATE=typo\n", Fail},
	} {
		t.Run(tc.name, func(t *testing.T) {
			r, _ := fixture(t)
			r.opts.Only = []string{"config.settings"}
			data, _ := os.ReadFile(r.inst.EnvPath)
			writeFile(t, r.inst.EnvPath, string(data)+tc.settings)
			if got := resultByID(t, r.run(context.Background()), "config.settings"); got.Status != tc.want {
				t.Fatalf("%+v", got)
			}
		})
	}
}

func TestMissingInstallationAndEnv(t *testing.T) {
	for _, path := range []string{"docker-compose.yml", ".env"} {
		t.Run(path, func(t *testing.T) {
			r, _ := fixture(t)
			r.opts.Only = []string{"config", "storage.installation"}
			if err := os.Remove(filepath.Join(r.inst.DockerDir, path)); err != nil {
				t.Fatal(err)
			}
			report := r.run(context.Background())
			if report.ExitCode != 1 || resultByID(t, report, "storage.installation").Status != OK {
				t.Fatalf("%+v", report)
			}
		})
	}
}

// This exercises the actual shipped Compose file and the real Compose parser,
// without an engine or containers. Shell values deliberately conflict with .env.
func TestShippedComposeEnvVariants(t *testing.T) {
	ctx, cancel := context.WithTimeout(context.Background(), time.Minute)
	defer cancel()
	if _, err := exec.LookPath("docker"); err != nil {
		t.Skip("Docker CLI is unavailable")
	}
	if _, err := dockerx.DiagnosticComposeVersion(ctx); err != nil {
		t.Skip("Docker Compose is unavailable")
	}
	compose, err := os.ReadFile("../../../docker/docker-compose.yml")
	if err != nil {
		t.Fatal(err)
	}
	example, err := os.ReadFile("../../../docker/.env.example")
	if err != nil {
		t.Fatal(err)
	}
	t.Setenv("DOMAIN", "wrong-shell.test")
	t.Setenv("COMPOSE_PROJECT_NAME", "wrong-shell-project")
	t.Setenv("COMPOSE_PROFILES", "memcached,setup")
	t.Setenv("COMPOSE_FILE", "missing-shell-compose.yml")
	t.Setenv("DOCKER_HOST", "unix:///nonexistent-doctor-test.sock")
	for _, tc := range []struct {
		name, profiles, ports string
		extra                 string
		want                  []string
	}{
		{"dragonfly", "dragonfly", "127.0.0.2:8443", "", []string{"dragonfly"}},
		{"memcached", "memcached", "8443", "", []string{"memcached"}},
		{"search", "dragonfly,manticore", "[::1]:8443", "", []string{"dragonfly", "manticore"}},
		{"tls", "dragonfly,direct-tls", "443", "", []string{"dragonfly", "acme"}},
		{"setup", "memcached,setup", "443", "", []string{"memcached", "kvs-init", "phpmyadmin-init"}},
		{"no-optional", "", "443", "", nil},
		{"quoted", "dragonfly", "127.0.0.2:443", "export IONCUBE='NO'\r\nUSE_WWW=true\r\n", []string{"dragonfly"}},
	} {
		t.Run(tc.name, func(t *testing.T) {
			dir := t.TempDir()
			writeFile(t, filepath.Join(dir, "docker-compose.yml"), string(compose))
			writeFile(t, filepath.Join(dir, ".env.example"), string(example))
			writeFile(t, filepath.Join(dir, ".env"), fmtEnv(tc.profiles, tc.ports)+tc.extra)
			p, err := dockerx.ReadProject(ctx, dir)
			if err != nil {
				t.Fatal(err)
			}
			if p.Name != "doctor-fixture" || p.Services["nginx"].Environment["DOMAIN"] != "example.test" {
				t.Fatalf("shell environment leaked into Compose: name %s", p.Name)
			}
			for _, optional := range []string{"dragonfly", "memcached", "manticore", "acme", "kvs-init", "phpmyadmin-init"} {
				_, found := p.Services[optional]
				if found != slices.Contains(tc.want, optional) {
					t.Errorf("service %s enabled=%t, want %v", optional, found, tc.want)
				}
			}
			if tc.name == "quoted" && p.Services["php-fpm"].Environment["IONCUBE"] != "NO" {
				t.Error("quoted override not applied")
			}
		})
	}
	t.Run("operator-override", func(t *testing.T) {
		dir := t.TempDir()
		writeFile(t, filepath.Join(dir, "docker-compose.yml"), string(compose))
		writeFile(t, filepath.Join(dir, ".env.example"), string(example))
		writeFile(t, filepath.Join(dir, ".env"), fmtEnv("dragonfly", "443"))
		writeFile(t, filepath.Join(dir, "docker-compose.override.yml"), "name: doctor-custom-name\nservices:\n  php-fpm:\n    environment:\n      IONCUBE: 'NO'\n")
		p, err := dockerx.ReadProject(ctx, dir)
		if err != nil {
			t.Fatal(err)
		}
		if p.Services["php-fpm"].Environment["IONCUBE"] != "NO" {
			t.Fatal("default operator override was not loaded")
		}
	})
	t.Run("malformed-compose-secret-is-not-reported", func(t *testing.T) {
		dir := t.TempDir()
		writeFile(t, filepath.Join(dir, "docker-compose.yml"), "services:\n  app:\n    image: alpine\n    command: [fixture-secret-do-not-print\n")
		_, err := dockerx.ReadProject(ctx, dir)
		if err == nil || strings.Contains(err.Error(), "fixture-secret-do-not-print") {
			t.Fatalf("unsafe or absent error: %v", err)
		}
	})
}

func fmtEnv(profiles, port string) string {
	return "SITE=example\nexport DOMAIN=\"${SITE}.test\"\nCOMPOSE_PROJECT_NAME=doctor-fixture\nSITE_PREFIX=doctor-fixture\nMARIADB_ROOT_PASSWORD='fixture-root-only'\nMARIADB_PASSWORD='fixture-db-only'\nCOMPOSE_PROFILES=" + profiles + "\nHTTPS_PORT='" + port + "'\nPHP_VERSION=8.1\nIONCUBE=YES\nSSL_PROVIDER=selfsigned\n" // pragma: allowlist secret - synthetic Compose fixture
}

func TestExplicitComposeFileWarning(t *testing.T) {
	r, _ := fixture(t)
	r.opts.Only = []string{"config.compose"}
	writeFile(t, filepath.Join(r.inst.DockerDir, "compose.override.yaml"), "services: {}\n")
	data, _ := os.ReadFile(r.inst.EnvPath)
	writeFile(t, r.inst.EnvPath, string(data)+"COMPOSE_FILE=docker-compose.yml\n")
	if got := resultByID(t, r.run(context.Background()), "config.compose"); got.Status != Warn {
		t.Fatalf("%+v", got)
	}
}
