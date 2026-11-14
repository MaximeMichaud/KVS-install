package doctor

import (
	"context"
	"encoding/json"
	"fmt"
	"regexp"
	"slices"
	"sort"
	"strings"
	"time"

	"github.com/MaximeMichaud/KVS-install/cli/internal/dockerx"
)

func (r *runner) services(ctx context.Context) Result {
	states, err := r.docker.Containers(ctx, r.project.Name)
	if err != nil {
		return failure("Could not inspect the project's containers", "Check 'docker ps --all' and Docker permissions")
	}
	r.containers = states
	var names, details, problems []string
	for name := range r.project.Services {
		names = append(names, name)
	}
	sort.Strings(names)
	pending := false
	for _, name := range names {
		found := false
		for _, s := range states {
			if s.Service != name || s.OneShot {
				continue
			}
			found = true
			label := name + " (" + s.Name + ")"
			switch {
			case (name == "kvs-init" || name == "phpmyadmin-init") && s.State == "exited" && s.Exit == 0:
				details = append(details, label+": completed successfully")
			case s.State != "running":
				problems = append(problems, label+": "+s.State)
			case s.Restarts >= 3 && r.now.Sub(s.Started) < 10*time.Second:
				problems = append(problems, label+": restarting repeatedly")
			case s.Health == "unhealthy":
				problems = append(problems, label+": unhealthy")
			case s.Health == "starting":
				if r.now.Sub(s.Started) > s.HealthWindow() {
					problems = append(problems, label+": health check still starting after its startup window")
				} else {
					pending = true
					details = append(details, label+": still within its health check startup window")
				}
			default:
				state := s.Health
				if state == "" {
					state = "running, no Docker health check"
				}
				details = append(details, label+": "+state)
			}
		}
		if !found {
			problems = append(problems, name+": expected container is missing")
		}
	}
	result := good(fmt.Sprintf("%d configured services inspected", len(names)), details...)
	if pending {
		result = warning("Some services are still starting", "Rerun doctor after startup completes", details...)
		result.Incomplete = true
	}
	if len(problems) > 0 {
		result = failure("Some configured services are missing, stopped or unhealthy", r.command("logs --tail 100"), append(problems, details...)...)
	}
	// A failure of one service must not hide the checks of other services.
	result.ready = true
	return result
}

func (r *runner) running(service string) *dockerx.ContainerState {
	if _, active := r.project.Services[service]; !active {
		return nil
	}
	for i := range r.containers {
		s := &r.containers[i]
		if s.Service == service && !s.OneShot && s.State == "running" {
			return s
		}
	}
	return nil
}

type phpInfo struct {
	Version    string   `json:"version"`
	IonCube    bool     `json:"ioncube"`
	Extensions []string `json:"extensions"`
}

const phpProbe = `echo json_encode(['version'=>PHP_VERSION,'ioncube'=>extension_loaded('ionCube Loader'),'extensions'=>get_loaded_extensions()]);`

func (r *runner) phpRuntime(ctx context.Context) Result {
	var details, problems []string
	missing := false
	for _, service := range []string{"php-fpm", "cron"} {
		c := r.running(service)
		if c == nil {
			missing = true
			details = append(details, service+": requires a running container")
			continue
		}
		out, err := r.probe.exec(ctx, c.ID, nil, "php", "-d", "display_errors=0", "-r", phpProbe)
		var info phpInfo
		if err != nil || json.Unmarshal(out, &info) != nil || info.Version == "" {
			problems = append(problems, service+": PHP diagnostic failed")
			continue
		}
		details = append(details, fmt.Sprintf("%s: PHP %s, IonCube loaded: %t", service, info.Version, info.IonCube))
		if !strings.HasPrefix(info.Version, r.inst.PHPVersion()+".") {
			problems = append(problems, service+": PHP version differs from PHP_VERSION")
		}
		expectedIonCube := r.inst.IonCube()
		if value, set := r.project.Services[service].Environment["IONCUBE"]; set {
			copy := *r.inst
			copy.Env = map[string]string{"IONCUBE": value}
			expectedIonCube = copy.IonCube()
		}
		if info.IonCube != expectedIonCube {
			problems = append(problems, service+": loaded IonCube state differs from IONCUBE")
		}
		extensions := []string{"mysqli", "pdo_mysql", "curl", "mbstring", "imagick", "memcached"}
		if service == "php-fpm" {
			extensions = append(extensions, "gd", "zip")
		}
		for _, ext := range extensions {
			if !slices.Contains(info.Extensions, ext) {
				problems = append(problems, service+": missing PHP extension "+ext)
			}
		}
	}
	if len(problems) > 0 {
		return failure("PHP runtime differs from the configured requirements", "Inspect PHP and cron logs; apply configuration changes by recreating the affected services", append(problems, details...)...)
	}
	if missing {
		result := skipped("PHP runtime could not be checked in every required container", true)
		result.Details = details
		return result
	}
	return good("PHP versions, required extensions and IonCube match the configuration", details...)
}

const toolsProbe = `for tool in ffmpeg ffprobe; do command -v "$tool" >/dev/null 2>&1 || exit 1; done; command -v magick >/dev/null 2>&1 || command -v convert >/dev/null 2>&1`

func (r *runner) tools(ctx context.Context) Result {
	var checked []string
	for _, service := range []string{"php-fpm", "cron"} {
		c := r.running(service)
		if c == nil {
			return skipped("Media tool check requires running PHP-FPM and cron containers", true)
		}
		if _, err := r.probe.exec(ctx, c.ID, nil, "sh", "-c", toolsProbe); err != nil {
			return failure("Required media tools are unavailable in "+service, "Inspect the image and PATH of "+service)
		}
		checked = append(checked, service+": FFmpeg, ffprobe and ImageMagick executables found")
	}
	return good("Media tool executables are present", checked...)
}

// Only setup_db.php is loaded; setup.php is read as text, one line at a time
// as kvs-init's get_tables_prefix reads it, for its tables prefix. Loading
// the application's bootstrap would run application code and could write
// sessions, caches or scheduled jobs. Error text is deliberately not
// emitted: database errors can contain credentials. What the probe found
// is a fixed word on stdout with exit status 0, followed for a table by its
// name, made of identifier characters only, and for a failed query by the
// MariaDB error number. Only "no such table" (1146) and "SELECT denied"
// (1142) say the table is missing: a lock held past the read timeout, for
// one, fails the query too.
const databaseProbe = `mysqli_report(MYSQLI_REPORT_OFF);
$allowed = json_decode(stream_get_contents(STDIN), true);
$include = '/var/www/kvs/admin/include/';
if (!is_readable($include . 'setup_db.php') || !is_readable($include . 'setup.php')) { echo 'config-unreadable'; exit; }
require $include . 'setup_db.php';
foreach (['DB_HOST','DB_LOGIN','DB_PASS','DB_DEVICE'] as $key) { if (!defined($key)) { echo 'config-incomplete'; exit(1); } }
$host = preg_replace('/:[0-9]+$/', '', DB_HOST);
if (!is_array($allowed) || !in_array($host, $allowed, true)) { echo 'nonlocal-database'; exit(1); }
$prefix = 'ktvs_';
if (preg_match('/^[^\S\n]*\$config\[[^\S\n]*[\'"]tables_prefix[\'"][^\S\n]*\][^\S\n]*=[^\S\n]*[\'"]([^\'"\n]*)[\'"]/m', (string) file_get_contents($include . 'setup.php'), $match) && preg_match('/^[A-Za-z0-9_]{1,32}$/', $match[1])) { $prefix = $match[1]; }
try {
  $db = mysqli_init();
  $db->options(MYSQLI_OPT_CONNECT_TIMEOUT, 3);
  $db->options(MYSQLI_OPT_READ_TIMEOUT, 3);
  if (!@$db->real_connect(DB_HOST, DB_LOGIN, DB_PASS, DB_DEVICE)) { exit(1); }
  foreach (['admin_users', 'videos'] as $table) {
    if ($db->query('SELECT 1 FROM ' . chr(96) . $prefix . $table . chr(96) . ' LIMIT 1') === false) {
      if (in_array($db->errno, [1142, 1146], true)) { echo 'no-table:' . $prefix . $table; exit; }
      echo 'query-failed:' . (int) $db->errno . ':' . $prefix . $table; exit;
    }
  }
  $db->close(); echo 'ok';
} catch (Throwable $e) { exit(1); }`

// tableName is what a table named by the database probe may be.
var tableName = regexp.MustCompile(`^[A-Za-z0-9_]{1,64}$`)

// queryFailed is the probe's answer for a query MariaDB refused for another
// reason than a missing table: its error number and the table.
var queryFailed = regexp.MustCompile(`^query-failed:([0-9]{1,5}):([A-Za-z0-9_]{1,64})$`)

// database runs its probe as www-data, the user of the PHP-FPM pool, so it
// reads the files the site reads, not what root could read, and it reads
// two tables every KVS database has, so a database that holds no site, or
// not under the tables prefix of setup.php, fails as well.
func (r *runner) database(ctx context.Context) Result {
	c := r.running("php-fpm")
	if c == nil {
		return skipped("Database query requires a running PHP-FPM container", true)
	}
	db := r.running("mariadb")
	if db == nil {
		return skipped("Database query requires the configured local MariaDB container", true)
	}
	allowed, _ := json.Marshal([]string{"mariadb", db.Name})
	out, err := r.probe.execAs(ctx, c.ID, "www-data", strings.NewReader(string(allowed)), "php", "-d", "display_errors=0", "-r", databaseProbe)
	answer := strings.TrimSpace(string(out))
	if err == nil {
		if answer == "ok" {
			return good("PHP, as www-data, read the KVS tables with the site's database credentials")
		}
		if answer == "config-unreadable" {
			return failure("PHP-FPM's user, www-data, cannot read admin/include/setup_db.php or setup.php", "Check that both files exist and that uid 1000 (www-data) can read them, as kvs-init leaves them")
		}
		if table, found := strings.CutPrefix(answer, "no-table:"); found && tableName.MatchString(table) {
			return failure("The site's database has no "+table+" table its credentials can read: it holds no KVS site, or setup.php names another tables prefix", "Import the site's database, or check tables_prefix in admin/include/setup.php")
		}
	}
	var details []string
	if m := queryFailed.FindStringSubmatch(answer); err == nil && m != nil {
		detail := "Reading " + m[2] + " failed with MariaDB error " + m[1]
		if m[1] == "2006" || m[1] == "2013" {
			detail += ": the connection ended, which a lock, a long write or an ALTER holding the table past the 3 s read timeout also causes"
		}
		details = append(details, detail)
	}
	return failure("PHP could not query the site's configured database", "Check setup_db.php, database access and "+r.command("logs mariadb --tail 100"), details...)
}

const cacheProbe = `$s = @fsockopen('cache', 11211, $errno, $error, 3);
if (!$s) { exit(1); } stream_set_timeout($s, 3); fwrite($s, "version\r\n");
$line = fgets($s, 256); fclose($s); if (!is_string($line) || strpos($line, 'VERSION ') !== 0) { exit(1); } echo 'ok';`

func (r *runner) cache(ctx context.Context) Result {
	var backends []string
	for _, name := range []string{"dragonfly", "memcached"} {
		if _, active := r.project.Services[name]; active {
			backends = append(backends, name)
		}
	}
	if len(backends) == 0 {
		return skipped("No cache backend is enabled in the active Compose configuration", false)
	}
	if len(backends) > 1 {
		return failure("Both cache backends are enabled on the cache endpoint", "Select either dragonfly or memcached in COMPOSE_PROFILES")
	}
	if r.running(backends[0]) == nil {
		return skipped("The configured cache container is not running", true)
	}
	c := r.running("php-fpm")
	if c == nil {
		return skipped("Cache query requires a running PHP-FPM container", true)
	}
	out, err := r.probe.exec(ctx, c.ID, nil, "php", "-d", "display_errors=0", "-r", cacheProbe)
	if err != nil || strings.TrimSpace(string(out)) != "ok" {
		return failure("PHP could not read the cache protocol version", r.command("logs "+backends[0]+" --tail 100"))
	}
	return good(backends[0] + " answered the read-only cache probe from PHP")
}

const searchProbe = `test ! -e /var/run/manticore/kvs-build-failed && test ! -e /var/run/manticore/kvs-rebuild-failed && mariadb --skip-ssl --connect-timeout=3 -h 127.0.0.1 -P 9306 -e 'SHOW STATUS' >/dev/null`

func (r *runner) search(ctx context.Context) Result {
	if _, active := r.project.Services["manticore"]; !active {
		return skipped("Manticore is not enabled in the active Compose configuration", false)
	}
	c := r.running("manticore")
	if c == nil {
		return skipped("Manticore query requires its running container", true)
	}
	if _, err := r.probe.exec(ctx, c.ID, nil, "sh", "-c", searchProbe); err != nil {
		return failure("Manticore did not answer or an index rebuild failure marker exists", r.command("logs manticore --tail 100"))
	}
	return good("Manticore answered SHOW STATUS; no index rebuild failure marker exists")
}

// cronProbe prints the user the KVS task runs as, then, in an image that
// ships kvs-cron-health (docker/cron/cron-health.sh), "ok" or "failed" and
// what it says about the last completed cron.php run, followed on a failure
// by the last failed run, which kvs-cron-run (docker/cron/cron-run.sh)
// records: cron.php writes its errors to /var/log/cron.log, not to the
// container's output, and exits 0 on most of them. The KVS task is
// kvs-cron-run, or cron.php itself in an older image.
const cronProbe = `pgrep -x cron >/dev/null && test -r /var/www/kvs/admin/include/cron.php || exit 1
for user in www-data root; do
  if grep -Eq "^[[:space:]]*[^#[:space:]].*[[:space:]]${user}[[:space:]].*(php[[:space:]]+cron[.]php|/kvs-cron-run)" /etc/cron.d/kvs-cron /etc/crontab 2>/dev/null ||
     crontab -u "$user" -l 2>/dev/null | grep -Eq '^[[:space:]]*[^#[:space:]].*php[[:space:]]+cron[.]php'; then
    printf '%s\n' "$user"
    if [ -x /usr/local/bin/kvs-cron-health ]; then
      if health=$(/usr/local/bin/kvs-cron-health); then
        printf 'ok %s\n' "$health"
      else
        printf 'failed %s\n' "$health"
      fi
    fi
    exit 0
  fi
done
exit 1`

// cronScript is the file the KVS task runs.
const cronScript = "/var/www/kvs/admin/include/cron.php"

// cronReadable prints whether the file it is given is readable: a word on
// stdout, so that the answer of test is never taken for a docker exec that
// failed (a container restarting, the deadline).
const cronReadable = `if test -r "$1"; then echo readable; else echo unreadable; fi`

// cronScriptReadable reads cron.php as www-data, the user the KVS task runs
// as since e3a1dd3; cronProbe runs as root, which reads any file. It
// returns false and the result to report when www-data cannot read it, or
// when the check itself did not run.
func (r *runner) cronScriptReadable(ctx context.Context, container string) (Result, bool) {
	out, err := r.probe.execAs(ctx, container, "www-data", nil, "sh", "-c", cronReadable, "sh", cronScript)
	switch answer := strings.TrimSpace(string(out)); {
	case err == nil && answer == "readable":
		return Result{}, true
	case err == nil && answer == "unreadable":
		return failure("The KVS cron task's user, www-data, cannot read admin/include/cron.php", "Check that uid 1000 (www-data) can read it, as kvs-init leaves the site"), false
	}
	return failure("Could not check that www-data can read admin/include/cron.php", r.command("logs cron --tail 100")), false
}

func (r *runner) cron(ctx context.Context) Result {
	c := r.running("cron")
	if c == nil {
		return skipped("Cron check requires a running cron container", true)
	}
	out, err := r.probe.exec(ctx, c.ID, nil, "sh", "-c", cronProbe)
	if err != nil {
		return failure("Cron daemon, KVS task file or expected schedule is missing", r.command("logs cron --tail 100"))
	}
	lines := strings.Split(strings.TrimRight(string(out), "\n"), "\n")
	user := strings.TrimSpace(lines[0])
	if user == "root" {
		return warning("KVS cron is installed as root using a legacy schedule", "Review the cron image and migrate the task to the application's unprivileged user")
	}
	if user != "www-data" {
		return failure("The KVS cron schedule could not be identified", r.command("logs cron --tail 100"))
	}
	if result, readable := r.cronScriptReadable(ctx, c.ID); !readable {
		return result
	}
	if len(lines) < 2 {
		// An image older than kvs-cron-health records no cron.php result.
		return good("Cron daemon and KVS schedule are present; this cron image does not record whether cron.php runs complete")
	}
	status, health, _ := strings.Cut(strings.TrimSpace(lines[1]), " ")
	switch status {
	case "ok":
		return good("Cron daemon and KVS schedule are present; " + health)
	case "failed":
		var tail []string
		for _, line := range lines[2:] {
			if line = strings.TrimRight(line, "\r"); line != "" {
				tail = append(tail, line)
			}
		}
		return failure("KVS cron.php is not completing its runs: "+health, "Run 'docker compose exec cron tail -n 100 /var/log/cron.log' in "+r.inst.DockerDir, tail...)
	}
	return failure("The KVS cron health could not be read", r.command("logs cron --tail 100"))
}
