package doctor

import (
	"context"
	"encoding/json"
	"io"
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
