package upgrade

import (
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/MaximeMichaud/KVS-install/cli/internal/instance"
)

// Cloudflare is an operator setting, not an image pin: upgrading adds its
// default once, and neither an upgrade nor a rollback replaces a saved choice.
func TestCloudflareSettingSurvivesUpgradeAndRollback(t *testing.T) {
	const main = "docker/nginx/nginx.conf"
	const oldConfig = "events {}\nhttp {}\n"
	const newConfig = "events {}\nhttp { include /run/kvs-nginx/*.conf; }\n"
	for _, value := range []string{"absent", "true", "false", ""} {
		t.Run(value, func(t *testing.T) {
			s := newStack(t, "",
				rel{version: "1.0.0", files: map[string]string{main: oldConfig}},
				rel{version: "1.1.0", files: map[string]string{
					main:                  newConfig,
					"docker/.env.example": "CLOUDFLARE_ENABLED=false\n",
				}})
			runner := s.runner()
			want := value
			if value == "absent" {
				want = "false"
			} else if err := runner.Inst.SetEnv("CLOUDFLARE_ENABLED", value); err != nil {
				t.Fatal(err)
			}
			manual := "docker/nginx/conf.d/operator.conf"
			if err := os.MkdirAll(filepath.Join(s.root, filepath.Dir(manual)), 0o755); err != nil {
				t.Fatal(err)
			}
			if err := os.WriteFile(filepath.Join(s.root, manual), []byte("# Operator configuration\n"), 0o644); err != nil {
				t.Fatal(err)
			}
			if err := s.upgrade(runner); err != nil {
				t.Fatal(err)
			}
			if got := s.env()["CLOUDFLARE_ENABLED"]; got != want || s.file(main) != newConfig {
				t.Fatalf("upgrade: setting %q, main %q", got, s.file(main))
			}
			if err := s.rollback(s.runner()); err != nil {
				t.Fatal(err)
			}
			if got := s.env()["CLOUDFLARE_ENABLED"]; got != want || s.file(main) != oldConfig {
				t.Fatalf("rollback: setting %q, main %q", got, s.file(main))
			}
			if s.file(manual) != "# Operator configuration\n" {
				t.Fatal("the operator's configuration was replaced")
			}
		})
	}
}

func TestCloudflareRestoreUsesTheArchivedSetting(t *testing.T) {
	archived := []byte("DOMAIN=example.com\nexport CLOUDFLARE_ENABLED=true # saved choice\n")
	live := []byte("DOMAIN=example.com\nCLOUDFLARE_ENABLED=false\n")
	merged, _, err := MergeArchivedEnv(archived, live)
	if err != nil {
		t.Fatal(err)
	}
	file := filepath.Join(t.TempDir(), ".env")
	if err := os.WriteFile(file, merged, 0o600); err != nil {
		t.Fatal(err)
	}
	env, err := instance.ReadEnv(file)
	if err != nil || env["CLOUDFLARE_ENABLED"] != "true" || !strings.Contains(string(merged), "# saved choice") {
		t.Fatalf("restored setting: %v, %v, %s", env, err, merged)
	}
}
