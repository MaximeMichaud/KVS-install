package doctor

import (
	"context"
	"encoding/json"
	"io"
	"slices"
	"strings"
	"testing"

	"github.com/MaximeMichaud/KVS-install/cli/internal/dockerx"
)

func TestPHPRuntimeVariants(t *testing.T) {
	for _, tc := range []struct {
		name, version, missing, ioncube string
		loaded, cronWithoutGD           bool
		want                            string
	}{
		{"normal", "8.1.34", "", "YES", true, false, OK},
		{"minimal-cron", "8.1.34", "", "YES", true, true, OK},
		{"ioncube-off", "8.1.34", "", "NO", false, false, OK},
		{"ioncube-required", "8.1.34", "", "YES", false, false, Fail},
		{"version-drift", "8.4.1", "", "YES", true, false, Fail},
		{"missing-mysqli", "8.1.34", "mysqli", "YES", true, false, Fail},
		{"missing-fpm-gd", "8.1.34", "gd", "YES", true, false, Fail},
	} {
		t.Run(tc.name, func(t *testing.T) {
			r, _ := fixture(t)
			r.opts.Only = []string{"php"}
			project, _ := r.probe.compose(context.Background(), "")
			for _, service := range []string{"php-fpm", "cron"} {
				cfg := project.Services[service]
				cfg.Environment = map[string]string{"IONCUBE": tc.ioncube}
				project.Services[service] = cfg
			}
			r.probe.exec = func(_ context.Context, container string, _ io.Reader, _ ...string) ([]byte, error) {
				info := phpInfo{Version: tc.version, IonCube: tc.loaded}
				for _, ext := range []string{"mysqli", "pdo_mysql", "curl", "mbstring", "imagick", "memcached", "gd", "zip"} {
					if ext == tc.missing || (container == "cron" && tc.cronWithoutGD && (ext == "gd" || ext == "zip")) {
						continue
					}
					info.Extensions = append(info.Extensions, ext)
				}
				return json.Marshal(info)
			}
			if result := resultByID(t, r.run(context.Background()), "php"); result.Status != tc.want {
				t.Fatalf("%+v", result)
			}
		})
	}
}

func TestLegacyCronIsAWarning(t *testing.T) {
	r, _ := fixture(t)
	r.opts.Only = []string{"cron"}
	r.probe.exec = func(context.Context, string, io.Reader, ...string) ([]byte, error) { return []byte("root"), nil }
	report := r.run(context.Background())
	if result := resultByID(t, report, "cron"); result.Status != Warn || !report.Complete || report.ExitCode != 0 {
		t.Fatalf("%+v", report)
	}
}

// The second line of the cron probe is the verdict of kvs-cron-health
// (docker/cron/cron-health.sh) on the last completed cron.php run, and the
// last failed run, which kvs-cron-run records, follows a failure;
// tests/integration_cron_health.sh runs the probe itself in the cron image.
func TestCronReportsAFailingCronPHP(t *testing.T) {
	for _, tc := range []struct {
		name, out, status, message string
		details                    []string
	}{
		{"recent run", "www-data\nok cron.php last completed a run 12 s ago\n", OK, "cron.php last completed a run 12 s ago", nil},
		{"first window", "www-data\nok cron.php has not completed a run yet, the container started 40 s ago\n", OK, "has not completed a run yet", nil},
		{"failing", "www-data\nfailed cron.php last completed a run 900 s ago, more than 300 s\nlast failure 20 s ago, exit status 0: [FATAL]: can't connect to database\r\n\n",
			Fail, "KVS cron.php is not completing its runs: cron.php last completed a run 900 s ago, more than 300 s",
			[]string{"last failure 20 s ago, exit status 0: [FATAL]: can't connect to database"}},
		{"no failure recorded", "www-data\nfailed cron.php has not completed a run since the container started 400 s ago: see /var/log/cron.log\n",
			Fail, "has not completed a run since the container started 400 s ago: see /var/log/cron.log", nil},
		{"older image", "www-data", OK, "this cron image does not record whether cron.php runs complete", nil},
		{"unreadable verdict", "www-data\nmaybe\n", Fail, "The KVS cron health could not be read", nil},
	} {
		t.Run(tc.name, func(t *testing.T) {
			r, _ := fixture(t)
			r.opts.Only = []string{"cron"}
			r.probe.exec = func(_ context.Context, container string, _ io.Reader, args ...string) ([]byte, error) {
				if container != "cron" || args[len(args)-1] != cronProbe {
					t.Errorf("unexpected probe in %s: %v", container, args)
				}
				return []byte(tc.out), nil
			}
			report := r.run(context.Background())
			result := resultByID(t, report, "cron")
			if result.Status != tc.status || !strings.Contains(result.Message, tc.message) || !slices.Equal(result.Details, tc.details) {
				t.Fatalf("%+v", result)
			}
			if tc.status == Fail && report.ExitCode == 0 {
				t.Fatalf("a failing cron check left exit code 0: %+v", report)
			}
			if tc.name == "failing" && !strings.Contains(result.Next, "docker compose exec cron tail -n 100 /var/log/cron.log") {
				t.Fatalf("the next step does not point at cron.log: %q", result.Next)
			}
		})
	}
}

func TestCacheProfilesAndSearch(t *testing.T) {
	for _, backend := range []string{"dragonfly", "memcached", "disabled", "both"} {
		t.Run(backend, func(t *testing.T) {
			r, f := fixture(t)
			r.opts.Only = []string{"cache", "search"}
			p, _ := r.probe.compose(context.Background(), "")
			if backend != "dragonfly" && backend != "both" {
				delete(p.Services, "dragonfly")
			}
			if backend == "memcached" || backend == "both" {
				p.Services["memcached"] = dockerx.ServiceConfig{}
				f.states = append(f.states, dockerx.ContainerState{ID: "memcached", Service: "memcached", State: "running"})
			}
			p.Services["manticore"] = dockerx.ServiceConfig{}
			f.states = append(f.states, dockerx.ContainerState{ID: "manticore", Service: "manticore", State: "running"})
			want := OK
			if backend == "disabled" {
				want = Skip
			} else if backend == "both" {
				want = Fail
			}
			report := r.run(context.Background())
			if resultByID(t, report, "cache").Status != want || resultByID(t, report, "search").Status != OK {
				t.Fatalf("%+v", report)
			}
		})
	}
}

func TestDatabaseProbeReceivesLocalHostsOnly(t *testing.T) {
	r, _ := fixture(t)
	r.opts.Only = []string{"database"}
	r.probe.exec = func(_ context.Context, _ string, input io.Reader, args ...string) ([]byte, error) {
		var hosts []string
		if err := json.NewDecoder(input).Decode(&hosts); err != nil {
			t.Fatal(err)
		}
		if strings.Join(hosts, ",") != "mariadb,custom-mariadb" || args[len(args)-1] != databaseProbe {
			t.Fatalf("hosts=%v args=%v", hosts, args)
		}
		return []byte("ok"), nil
	}
	if resultByID(t, r.run(context.Background()), "database").Status != OK {
		t.Fatal("local database probe failed")
	}
}
