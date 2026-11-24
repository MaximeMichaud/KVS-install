package doctor

import (
	"context"
	"encoding/json"
	"errors"
	"io"
	"os"
	"os/exec"
	"path/filepath"
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
			if backend == "disabled" || backend == "both" {
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
	r.probe.execAs = func(_ context.Context, container, user string, input io.Reader, args ...string) ([]byte, error) {
		var hosts []string
		if err := json.NewDecoder(input).Decode(&hosts); err != nil {
			t.Fatal(err)
		}
		if strings.Join(hosts, ",") != "mariadb,custom-mariadb" || args[len(args)-1] != databaseProbe {
			t.Fatalf("hosts=%v args=%v", hosts, args)
		}
		// As the PHP-FPM pool reads the site: root reads files www-data
		// cannot.
		if container != "php-fpm" || user != "www-data" {
			t.Fatalf("the database probe ran in %q as %q", container, user)
		}
		return []byte("ok"), nil
	}
	if resultByID(t, r.run(context.Background()), "database").Status != OK {
		t.Fatal("local database probe failed")
	}
}

// Only "ok" passes. A configuration www-data cannot read and a missing KVS
// table fail with what to look at; anything else, a table name that is not
// one included, is the generic failure and never reaches the report.
func TestDatabaseProbeFindings(t *testing.T) {
	lock := "Reading ktvs_videos failed with MariaDB error 2006: the connection ended, which a lock, a long write or an ALTER holding the table past the 3 s read timeout also causes"
	for _, tc := range []struct {
		name, out string
		err       error
		status    string
		message   string
		details   []string
	}{
		{"the KVS tables", "ok", nil, OK, "read the KVS tables", nil},
		{"missing import marker", "partial-import", nil, Fail, "partial import", nil},
		{"an empty database", "no-table:ktvs_admin_users", nil, Fail, "no ktvs_admin_users table", nil},
		{"another prefix", "no-table:kvs7_videos\n", nil, Fail, "no kvs7_videos table", nil},
		{"setup_db.php only root reads", "config-unreadable", nil, Fail, "www-data, cannot read admin/include/setup_db.php", nil},
		{"not a table name", "no-table:x`; DROP", nil, Fail, "could not query", nil},
		{"an empty table name", "no-table:", nil, Fail, "could not query", nil},
		{"no connection", "", errors.New("exit status 1"), Fail, "could not query", nil},
		{"a word after a failure", "config-unreadable", errors.New("exit status 1"), Fail, "could not query", nil},
		// The tables are there: a lock held past the read timeout is no
		// missing table.
		{"a lock past the read timeout", "query-failed:2006:ktvs_videos\n", nil, Fail, "could not query", []string{lock}},
		{"a lost connection", "query-failed:2013:ktvs_videos", nil, Fail, "could not query", []string{strings.Replace(lock, "2006", "2013", 1)}},
		{"another refusal", "query-failed:1045:ktvs_admin_users", nil, Fail, "could not query", []string{"Reading ktvs_admin_users failed with MariaDB error 1045"}},
		{"a refusal after a failure", "query-failed:2006:ktvs_videos", errors.New("exit status 1"), Fail, "could not query", nil},
		{"a refusal that is not a table", "query-failed:2006:x`; DROP", nil, Fail, "could not query", nil},
		{"a refusal without a number", "query-failed::ktvs_videos", nil, Fail, "could not query", nil},
	} {
		t.Run(tc.name, func(t *testing.T) {
			r, _ := fixture(t)
			r.opts.Only = []string{"database"}
			r.probe.execAs = func(context.Context, string, string, io.Reader, ...string) ([]byte, error) {
				return []byte(tc.out), tc.err
			}
			report := r.run(context.Background())
			result := resultByID(t, report, "database")
			if result.Status != tc.status || !strings.Contains(result.Message, tc.message) || strings.Join(result.Details, "|") != strings.Join(tc.details, "|") {
				t.Fatalf("%+v", result)
			}
			if tc.status == Fail && report.ExitCode == 0 {
				t.Fatalf("a failing database check left exit code 0: %+v", report)
			}
			if tc.out == "partial-import" && (!strings.Contains(result.Next, r.command("logs kvs-init --tail 100")) ||
				!strings.Contains(result.Next, "restore a verified database backup")) {
				t.Fatal(result.Next)
			}
			if strings.Contains(result.Message+strings.Join(result.Details, ""), "DROP") {
				t.Fatalf("the probe's output reached the report: %+v", result)
			}
		})
	}
}

// cronProbe runs as root, which reads any file: cron.php is read again as
// www-data, the user the KVS task runs as. Only the probe's own word says
// the file is unreadable; a docker exec that fails says nothing of it.
func TestCronReadsTheScriptAsWwwData(t *testing.T) {
	for _, tc := range []struct {
		name, out string
		err       error
		status    string
		message   string
	}{
		{"readable", "readable\n", nil, OK, "KVS schedule are present"},
		{"unreadable", "unreadable\n", nil, Fail, "www-data, cannot read admin/include/cron.php"},
		{"the exec failed", "", errors.New("exit status 1"), Fail, "Could not check that www-data can read"},
		{"a container restarting", "", errors.New("exit status 125"), Fail, "Could not check that www-data can read"},
		{"a word after a failure", "unreadable", errors.New("exit status 137"), Fail, "Could not check that www-data can read"},
		{"readable after a failure", "readable", errors.New("exit status 137"), Fail, "Could not check that www-data can read"},
		{"another answer", "maybe", nil, Fail, "Could not check that www-data can read"},
	} {
		t.Run(tc.name, func(t *testing.T) {
			r, _ := fixture(t)
			r.opts.Only = []string{"cron"}
			var asked []string
			r.probe.execAs = func(_ context.Context, container, user string, _ io.Reader, args ...string) ([]byte, error) {
				asked = append(asked, container+" "+user+" "+strings.Join(args, " "))
				return []byte(tc.out), tc.err
			}
			result := resultByID(t, r.run(context.Background()), "cron")
			if want := "cron www-data sh -c " + cronReadable + " sh " + cronScript; strings.Join(asked, ",") != want {
				t.Fatalf("asked %q, want %q", asked, want)
			}
			if result.Status != tc.status || !strings.Contains(result.Message, tc.message) {
				t.Fatalf("%+v", result)
			}
		})
	}
}

func TestCacheUsesSiteRoute(t *testing.T) {
	php, err := exec.LookPath("php")
	if err != nil {
		t.Skip("PHP is needed to run the cache probe against setup.php fixtures")
	}
	const direct = "$config['memcache_server']='cache';"
	const loopback = "$config['memcache_server']='127.0.0.1';"
	for _, tc := range []struct{ name, settings, endpoint, response, status string }{
		{"direct", direct, "cache:11211", "VERSION fixture", OK},
		{"backend service", "$config['memcache_server']='dragonfly';", "dragonfly:11211", "VERSION fixture", OK},
		{"backend container", "$config['memcache_server']='custom-dragonfly';", "custom-dragonfly:11211", "VERSION fixture", OK},
		{"IPv6 loopback", "$config['memcache_server']='::1';", "[::1]:11211", "VERSION fixture", OK},
		{"localhost", "$config['memcache_server']='localhost';", "localhost:11211", "VERSION fixture", OK},
		{"missing relay", loopback, "cache:11211", "VERSION fixture", Fail},
		{"relay on custom port", loopback + "$config['memcache_port']=11212;", "127.0.0.1:11212", "VERSION fixture", OK},
		{"invalid port", direct + "$config['memcache_port']='11211x';", "cache:11211", "VERSION fixture", Fail},
		{"port out of range", direct + "$config['memcache_port']=65536;", "cache:65536", "VERSION fixture", Fail},
		{"port zero", direct + "$config['memcache_port']=0;", "cache:0", "VERSION fixture", Fail},
		{"invalid response", direct, "cache:11211", "ERROR", Fail},
		{"disabled", "$config['memcache_server']='';", "", "", Skip},
		{"strict types", "declare(strict_types=1);" + loopback, "127.0.0.1:11211", "VERSION fixture", OK},
		{"negative port", direct + "$config['memcache_port']=-1;", "cache:11211", "VERSION fixture", Fail},
		{"invalid string port", direct + "$config['memcache_port']='bad port!';", "cache:11211", "VERSION fixture", Fail},
		{"computed", "$config['memcache_server']=getenv('CACHE');", "cache:11211", "VERSION fixture", OK},
		{"fallback protocol failure", "$config['memcache_server']=getenv('CACHE');", "cache:11211", "ERROR", Fail},
		{"other host", "$config['memcache_server']='elsewhere.test';", "cache:11211", "VERSION fixture", OK},
		{"other host protocol failure", "$config['memcache_server']='elsewhere.test';", "cache:11211", "ERROR", Fail},
		// A literal port counts as PHP evaluates it, whatever its spelling.
		{"separated port", loopback + "$config['memcache_port']=11_212;", "127.0.0.1:11212", "VERSION fixture", OK},
		{"hexadecimal port", loopback + "$config['memcache_port']=0x2BCC;", "127.0.0.1:11212", "VERSION fixture", OK},
		{"octal port", loopback + "$config['memcache_port']=0o25714;", "127.0.0.1:11212", "VERSION fixture", OK},
		{"legacy octal port", loopback + "$config['memcache_port']=025714;", "127.0.0.1:11212", "VERSION fixture", OK},
		{"binary port", loopback + "$config['memcache_port']=0b10101111001100;", "127.0.0.1:11212", "VERSION fixture", OK},
		{"signed port", loopback + "$config['memcache_port']=+11212;", "127.0.0.1:11212", "VERSION fixture", OK},
		{"binary string port", loopback + "$config['memcache_port']=b'11212';", "127.0.0.1:11212", "VERSION fixture", OK},
		{"spaced string port", loopback + "$config['memcache_port']=' 11212 ';", "127.0.0.1:11212", "VERSION fixture", OK},
		{"tabbed string port", loopback + "$config['memcache_port']='\t11212\n';", "127.0.0.1:11212", "VERSION fixture", OK},
		{"signed string port", loopback + "$config['memcache_port']='+11212';", "127.0.0.1:11212", "VERSION fixture", OK},
		{"negative string port", loopback + "$config['memcache_port']='-11212';", "cache:11211", "VERSION fixture", Fail},
		{"inner space string port", loopback + "$config['memcache_port']='+ 11212';", "cache:11211", "VERSION fixture", Fail},
		{"other host with a signed string port", "$config['memcache_server']='elsewhere.test';$config['memcache_port']=' +11212 ';", "cache:11211", "VERSION fixture", OK},
		// Anything else than one integer literal is not evaluated.
		{"port sum", loopback + "$config['memcache_port']=11212+1;", "cache:11211", "VERSION fixture", OK},
		{"port concatenation", loopback + "$config['memcache_port']='11212'.'0';", "cache:11211", "VERSION fixture", OK},
		{"float port", loopback + "$config['memcache_port']=11212.0;", "cache:11211", "VERSION fixture", OK},
		{"signed float port", loopback + "$config['memcache_port']=+1.5;", "cache:11211", "VERSION fixture", OK},
		{"float string port", loopback + "$config['memcache_port']='11212.0';", "cache:11211", "VERSION fixture", OK},
		{"exponent string port", loopback + "$config['memcache_port']='1e3';", "cache:11211", "VERSION fixture", OK},
		{"separated port out of range", loopback + "$config['memcache_port']=65_536;", "cache:11211", "VERSION fixture", Fail},
		{"negative hexadecimal port", loopback + "$config['memcache_port']=-0x2BCC;", "cache:11211", "VERSION fixture", Fail},
		{"integer port beyond PHP integers", loopback + "$config['memcache_port']=999999999999999999999999;", "cache:11211", "VERSION fixture", Fail},
		{"other host with a negative port", "$config['memcache_server']='elsewhere.test';$config['memcache_port']=-1;", "cache:11211", "VERSION fixture", Fail},
		{"other host with a port out of range", "$config['memcache_server']='elsewhere.test';$config['memcache_port']='65536';", "cache:11211", "VERSION fixture", Fail},
		{"other host with a computed port", "$config['memcache_server']='elsewhere.test';$config['memcache_port']=intval(getenv('PORT'));", "cache:11211", "VERSION fixture", OK},
	} {
		t.Run(tc.name, func(t *testing.T) {
			r, _ := fixture(t)
			r.opts.Only = []string{"cache"}
			path := filepath.Join(t.TempDir(), "setup.php")
			writeFile(t, path, "<?php\n"+tc.settings+"\nthrow new Exception('site code must not run');")
			useCacheProbe(t, r, php, path, tc.endpoint, tc.response)
			result := resultByID(t, r.run(context.Background()), "cache")
			if result.Status != tc.status {
				t.Errorf("got %+v, want %s", result, tc.status)
			}
			if slices.Contains([]string{"computed", "fallback protocol failure", "port sum", "port concatenation", "float port", "signed float port",
				"float string port", "exponent string port"}, tc.name) {
				if !strings.Contains(strings.Join(result.Details, " "), "route was not read from setup.php") {
					t.Errorf("missing fallback detail: %+v", result)
				}
				attempt, err := os.ReadFile(path + ".attempt")
				if err != nil || string(attempt) != "cache:11211" {
					t.Errorf("fallback endpoint %q, %v", attempt, err)
				}
			}
			// A host outside the local routes is not probed: the report
			// must say that the alias stood in for it, and why.
			if slices.Contains([]string{"other host", "other host protocol failure", "other host with a computed port", "other host with a signed string port"}, tc.name) {
				detail := strings.Join(result.Details, " ")
				if !strings.Contains(result.Message, "alias") || !strings.Contains(detail, "configured host is outside the local cache routes") ||
					!strings.Contains(detail, "cache:11211") || strings.Contains(detail, "route was not read from setup.php") {
					t.Errorf("missing nonlocal fallback detail: %+v", result)
				}
				attempt, err := os.ReadFile(path + ".attempt")
				if err != nil || string(attempt) != "cache:11211" {
					t.Errorf("nonlocal fallback endpoint %q, %v", attempt, err)
				}
			}
			if slices.Contains([]string{"negative port", "invalid string port", "separated port out of range", "negative hexadecimal port",
				"integer port beyond PHP integers", "negative string port", "inner space string port", "other host with a negative port", "other host with a port out of range"}, tc.name) {
				if !strings.Contains(result.Message, "port is invalid") {
					t.Errorf("missing invalid port diagnostic: %+v", result)
				}
				if _, err := os.Stat(path + ".attempt"); !os.IsNotExist(err) {
					t.Error("attempted a connection with an invalid port")
				}
			}
			if tc.name == "missing relay" && !strings.Contains(result.Next, "PHP-FPM cache relay") {
				t.Errorf("missing relay diagnostic: %+v", result)
			}
			if tc.status == Skip {
				if result.Incomplete != (tc.name != "disabled") {
					t.Errorf("unexpected completeness: %+v", result)
				}
				if _, err := os.Stat(path + ".attempt"); !os.IsNotExist(err) {
					t.Error("attempted a connection without a supported local cache route")
				}
			}
		})
	}
}

func useCacheProbe(t *testing.T, r *runner, php, path, endpoint, response string) {
	t.Helper()
	// The PHP probe runs as shipped, with the site mount and socket
	// replaced by fixtures. Only the named endpoint can reply.
	r.probe.execAs = func(ctx context.Context, container, user string, _ io.Reader, args ...string) ([]byte, error) {
		at := slices.Index(args, "-r")
		if user != "www-data" || container != "php-fpm" || at < 0 || at+1 >= len(args) {
			t.Fatalf("expected a PHP probe in php-fpm as www-data, got container %q, user %q, script index %d", container, user, at)
		}
		script := strings.ReplaceAll(args[at+1], "'/var/www/kvs/admin/include/setup.php'", "getenv('FIXTURE_SETUP')")
		const socket = `function fsockopen($host, $port, &$errno, &$error, $timeout) {
    file_put_contents(getenv('FIXTURE_ATTEMPT'), "$host:$port");
    if ("$host:$port" !== getenv('FIXTURE_ENDPOINT')) { return false; }
    $s = fopen('php://temp', 'w+');
    fwrite($s, "version\r\n" . getenv('FIXTURE_RESPONSE') . "\r\n");
    rewind($s);
    return $s;
}
`
		cmd := exec.CommandContext(ctx, php, append([]string{"-d", "disable_functions=fsockopen", "-r", socket + script}, args[at+2:]...)...)
		cmd.Env = append(os.Environ(), "FIXTURE_SETUP="+path, "FIXTURE_ENDPOINT="+endpoint, "FIXTURE_RESPONSE="+response, "FIXTURE_ATTEMPT="+path+".attempt")
		return cmd.CombinedOutput()
	}
}

func TestCacheRoutePrerequisites(t *testing.T) {
	php, err := exec.LookPath("php")
	if err != nil {
		t.Skip("PHP is needed to run the cache probe")
	}
	const direct = "$config['memcache_server']='cache';"
	const disabled = "$config['memcache_server']='';"
	const computedPort = "$config['memcache_port']=intval(getenv('PORT'));"
	cases := []struct {
		name, settings, link, backend, status string
		incomplete                            bool
	}{
		{"invalid syntax", direct + "\n$label=\"\"FixtureMarker\"\";", "", "running", OK, false},
		{"invalid break", direct + "break;", "", "running", OK, false},
		{"global override", direct + "$GLOBALS['config']['memcache_server']='127.0.0.1';", "", "running", OK, false},
		{"aliased host", direct + "$alias=&$config['memcache_server']; $alias='127.0.0.1';", "", "running", OK, false},
		{"variable variable", direct + "$name='config'; $$name=['memcache_server'=>'localhost'];", "", "running", OK, false},
		{"extract", direct + "extract(['config'=>['memcache_server'=>'localhost']]);", "", "running", OK, false},
		{"unknown constructor", direct + "new SiteSettings();", "", "running", OK, false},
		{"side effect", direct + "file_put_contents(__FILE__.'.executed','yes');", "", "running", OK, false},
		{"dynamic call", direct + "$fn='extract'; $fn(['config'=>[]]);", "", "running", OK, false},
		{"list assignment", direct + "list($config)=[[]];", "", "running", OK, false},
		{"destructured port", disabled + "[$config['memcache_port']]=[11212];", "", "running", OK, false},
		{"literal setup", "if (!isset($config)) { $config=[]; } $config['path']='/site'; $config['derived']=\"$config[path]/data\";" + disabled, "", "running", Skip, false},
		{"symlinked file", direct, "file", "running", OK, false},
		{"symlinked directory", direct, "directory", "running", OK, false},
		{"disabled with computed port", disabled + computedPort, "", "running", Skip, false},
		{"enabled with computed port", direct + computedPort, "", "running", OK, false},
		{"disabled without profile", disabled, "", "absent", Skip, false},
		{"enabled without profile", direct, "", "absent", Fail, false},
		{"computed port without profile", direct + computedPort, "", "absent", Fail, false},
		{"container without profile", "$config['memcache_server']='kvs-dragonfly';", "", "absent", Fail, false},
		{"custom project prefix", "$config['memcache_server']='second_site-memcached';", "", "absent", Fail, false},
		{"existing project container", "$config['memcache_server']='custom-dragonfly';", "", "absent", Fail, false},
		{"other project container", "$config['memcache_server']='foreign-dragonfly';", "", "absent", Skip, false},
		{"unknown without profile", "$config['memcache_server']=getenv('CACHE');", "", "absent", Skip, false},
		{"disabled with stopped backend", disabled, "", "stopped", Skip, false},
		{"enabled with stopped backend", direct, "", "stopped", Skip, true},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			r, f := fixture(t)
			r.opts.Only = []string{"cache"}
			project, _ := r.probe.compose(context.Background(), "")
			if tc.name == "custom project prefix" {
				writeFile(t, r.inst.EnvPath, "DOMAIN=example.test\nSITE_PREFIX=second_site\nCOMPOSE_PROJECT_NAME=kvs\n")
			}
			switch tc.backend {
			case "absent":
				delete(project.Services, "dragonfly")
			case "stopped":
				for i := range f.states {
					if f.states[i].Service == "dragonfly" {
						f.states[i].State = "exited"
					}
				}
			}
			dir := t.TempDir()
			path := filepath.Join(dir, "setup.php")
			writeFile(t, path, "<?php "+tc.settings)
			if tc.link != "" {
				target := path
				if tc.link == "directory" {
					target = dir
				}
				link := filepath.Join(t.TempDir(), "link")
				if err := os.Symlink(target, link); err != nil {
					t.Fatal(err)
				}
				path = link
				if tc.link == "directory" {
					path = filepath.Join(link, "setup.php")
				}
			}
			useCacheProbe(t, r, php, path, "cache:11211", "VERSION fixture")
			result := resultByID(t, r.run(context.Background()), "cache")
			if tc.backend == "absent" && tc.status == Fail && !strings.Contains(result.Message, "no cache backend is enabled") {
				t.Errorf("missing profile diagnostic: %+v", result)
			}
			if _, err := os.Stat(path + ".executed"); !os.IsNotExist(err) {
				t.Error("executed the site configuration")
			}
			detail := strings.Join(result.Details, " ")
			if tc.name == "invalid syntax" && (!strings.Contains(detail, "Parse error on line 2") || strings.Contains(result.Message+detail+result.Next, "FixtureMarker")) {
				t.Errorf("expected only PHP error category and line: %+v", result)
			}
			if tc.name == "invalid break" && !strings.Contains(detail, "Fatal error on line 1") {
				t.Errorf("missing PHP compile error: %+v", result)
			}
			if result.Status != tc.status || result.Incomplete != tc.incomplete {
				t.Errorf("got %+v, want %s and incomplete=%t", result, tc.status, tc.incomplete)
			}
			if tc.status == OK {
				attempt, err := os.ReadFile(path + ".attempt")
				if err != nil || string(attempt) != "cache:11211" || !strings.Contains(detail, "route was not read from setup.php") {
					t.Errorf("expected a reported Compose alias probe, got %q, %v, %+v", attempt, err, result)
				}
			} else if _, err := os.Stat(path + ".attempt"); !os.IsNotExist(err) {
				t.Error("unexpected connection attempt")
			}
		})
	}
	for _, keyword := range []string{"include", "include_once", "require", "require_once"} {
		t.Run(keyword, func(t *testing.T) {
			r, _ := fixture(t)
			r.opts.Only = []string{"cache"}
			dir := t.TempDir()
			path := filepath.Join(dir, "setup.php")
			writeFile(t, path, "<?php "+direct+keyword+" __DIR__.'/local.php';")
			writeFile(t, filepath.Join(dir, "local.php"), "<?php $config['memcache_server']='127.0.0.1';")
			useCacheProbe(t, r, php, path, "cache:11211", "VERSION fixture")
			result := resultByID(t, r.run(context.Background()), "cache")
			if result.Status != OK || !strings.Contains(strings.Join(result.Details, " "), "route was not read from setup.php") {
				t.Errorf("ambiguous route: %+v", result)
			}
			attempt, err := os.ReadFile(path + ".attempt")
			if err != nil || string(attempt) != "cache:11211" {
				t.Errorf("expected only the Compose alias, got %q, %v", attempt, err)
			}
		})
	}
}

func TestCacheOnlyRequiresSingleSite(t *testing.T) {
	for _, layout := range []string{"multi", "populated"} {
		t.Run(layout, func(t *testing.T) {
			r, _ := fixture(t)
			r.opts.Only = []string{"cache"}
			if layout == "multi" {
				writeFile(t, r.inst.EnvPath, "DOMAIN=example.test\nMODE=multi\n")
			} else {
				writeFile(t, filepath.Join(r.inst.DockerDir, "multi-site", "sites", "second.example", "docker-compose.yml"), "services: {}\n")
			}
			r.probe.execAs = func(context.Context, string, string, io.Reader, ...string) ([]byte, error) {
				t.Error("probed a single project on a multi-site installation")
				return []byte("ok"), nil
			}
			report := r.run(context.Background())
			cache := resultByID(t, report, "cache")
			if cache.Status != Skip || !cache.Incomplete || report.ExitCode == 0 || report.Complete {
				t.Errorf("cache=%+v, complete=%t, exit=%d", cache, report.Complete, report.ExitCode)
			}
		})
	}
}

func TestCacheStockLayout(t *testing.T) {
	php, err := exec.LookPath("php")
	if err != nil {
		t.Skip("PHP is needed to run the cache probe")
	}
	// Synthetic site with the distribution's delegation guard, version
	// include, request setup and literal cache settings.
	const setup = `<?php
if (isset($_SERVER['KVS_DEV_PATH']) && is_dir($_SERVER['KVS_DEV_PATH'])) {
    require_once "{$_SERVER['KVS_DEV_PATH']}/fixture.php";
    return;
}
include_once 'version.php';
umask(0022);
error_reporting(E_ERROR | E_WARNING);
ini_set('session.cookie_domain', str_replace('www.', '', 'site.example'));
if (isset($_SERVER['HTTP_HOST'])) { $name = 'fixture'; }
elseif (strpos('site.example', '.') !== false) { $name = trim(substr(' fixture ', 0)); }
if (!isset($config)) { $config = []; }
$config['project_path'] = '/site';
$config['files'] = "$config[project_path]/files";
$config['label'] = (strpos($config['files'], '/files') !== false ? 'site' : 'fixture') . '.example';
$config['memcache_server'] = 'localhost';
$config['memcache_port'] = 11212;
`
	const version = "<?php /* fixture */ $config['project_version'] = '7.0.0';"
	for _, tc := range []struct {
		name, version       string
		delegated, fallback bool
	}{
		{"stock", version, false, false},
		{"active delegation", version, true, true},
		{"relative delegation", version, false, true},
		{"missing version", "", false, true},
		{"shadowed version", version, false, true},
		{"version with another write", version + "$config['memcache_server']='cache';", false, true},
	} {
		t.Run(tc.name, func(t *testing.T) {
			r, _ := fixture(t)
			r.opts.Only = []string{"cache"}
			dir := t.TempDir()
			path := filepath.Join(dir, "setup.php")
			writeFile(t, path, setup)
			if tc.version != "" {
				writeFile(t, filepath.Join(dir, "version.php"), tc.version)
			}
			if tc.name == "shadowed version" {
				shadow := t.TempDir()
				writeFile(t, filepath.Join(shadow, "version.php"), "<?php $config['memcache_server']='cache';")
				t.Chdir(shadow)
			}
			devPath := filepath.Join(dir, "absent")
			if tc.delegated {
				devPath = dir
			} else if tc.name == "relative delegation" {
				devPath = "relative/site"
			}
			t.Setenv("KVS_DEV_PATH", devPath)
			endpoint := "localhost:11212"
			if tc.fallback {
				endpoint = "cache:11211"
			}
			useCacheProbe(t, r, php, path, endpoint, "VERSION fixture")
			report := r.run(context.Background())
			cache := resultByID(t, report, "cache")
			detail := strings.Join(cache.Details, " ")
			attempt, err := os.ReadFile(path + ".attempt")
			if cache.Status != OK || report.ExitCode != 0 || !report.Complete || err != nil || string(attempt) != endpoint ||
				strings.Contains(detail, "route was not read from setup.php") != tc.fallback {
				t.Fatalf("cache=%+v exit=%d complete=%t endpoint=%q err=%v", cache, report.ExitCode, report.Complete, attempt, err)
			}
		})
	}
}

func TestCacheOnlyIgnoresUnrelatedSettings(t *testing.T) {
	r, _ := fixture(t)
	r.opts.Only = []string{"cache"}
	writeFile(t, r.inst.EnvPath, "DOMAIN=example.test\nYT_DLP_AUTO_UPDATE=weekly\n")
	calls := 0
	r.probe.execAs = func(context.Context, string, string, io.Reader, ...string) ([]byte, error) {
		calls++
		return []byte("ok"), nil
	}
	report := r.run(context.Background())
	cache := resultByID(t, report, "cache")
	if cache.Status != OK || report.ExitCode != 0 || !report.Complete || calls != 1 {
		t.Errorf("cache=%+v exit=%d complete=%t calls=%d", cache, report.ExitCode, report.Complete, calls)
	}
}
