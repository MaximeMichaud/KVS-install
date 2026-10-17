package doctor

import (
	"context"
	"encoding/json"
	"fmt"
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

// Only setup_db.php is loaded. Loading the application's bootstrap would run
// application code and could write sessions, caches or scheduled jobs. Error
// text is deliberately not emitted: database errors can contain credentials.
const databaseProbe = `mysqli_report(MYSQLI_REPORT_OFF);
$allowed = json_decode(stream_get_contents(STDIN), true);
if (!is_readable('/var/www/kvs/admin/include/setup_db.php')) { echo 'config-missing'; exit(1); }
require '/var/www/kvs/admin/include/setup_db.php';
foreach (['DB_HOST','DB_LOGIN','DB_PASS','DB_DEVICE'] as $key) { if (!defined($key)) { echo 'config-incomplete'; exit(1); } }
$host = preg_replace('/:[0-9]+$/', '', DB_HOST);
if (!is_array($allowed) || !in_array($host, $allowed, true)) { echo 'nonlocal-database'; exit(1); }
try {
  $db = mysqli_init();
  $db->options(MYSQLI_OPT_CONNECT_TIMEOUT, 3);
  $db->options(MYSQLI_OPT_READ_TIMEOUT, 3);
  if (!@$db->real_connect(DB_HOST, DB_LOGIN, DB_PASS, DB_DEVICE)) { exit(1); }
  $result = $db->query('SELECT 1');
  if (!$result || $result->fetch_row()[0] != 1) { exit(1); }
  $db->close(); echo 'ok';
} catch (Throwable $e) { exit(1); }`

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
	out, err := r.probe.exec(ctx, c.ID, strings.NewReader(string(allowed)), "php", "-d", "display_errors=0", "-r", databaseProbe)
	if err != nil || strings.TrimSpace(string(out)) != "ok" {
		return failure("PHP could not query the site's configured database", "Check setup_db.php, database access and "+r.command("logs mariadb --tail 100"))
	}
	return good("SELECT 1 succeeded from PHP with the site's database credentials")
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

const cronProbe = `pgrep -x cron >/dev/null && test -r /var/www/kvs/admin/include/cron.php || exit 1
for user in www-data root; do
  if grep -Eq "^[[:space:]]*[^#[:space:]].*[[:space:]]${user}[[:space:]].*php[[:space:]]+cron[.]php" /etc/cron.d/kvs-cron /etc/crontab 2>/dev/null ||
     crontab -u "$user" -l 2>/dev/null | grep -Eq '^[[:space:]]*[^#[:space:]].*php[[:space:]]+cron[.]php'; then
    printf '%s' "$user"; exit 0
  fi
done
exit 1`

func (r *runner) cron(ctx context.Context) Result {
	c := r.running("cron")
	if c == nil {
		return skipped("Cron check requires a running cron container", true)
	}
	out, err := r.probe.exec(ctx, c.ID, nil, "sh", "-c", cronProbe)
	if err != nil {
		return failure("Cron daemon, KVS task file or expected schedule is missing", r.command("logs cron --tail 100"))
	}
	if strings.TrimSpace(string(out)) == "root" {
		return warning("KVS cron is installed as root using a legacy schedule", "Review the cron image and migrate the task to the application's unprivileged user")
	}
	if strings.TrimSpace(string(out)) != "www-data" {
		return failure("The KVS cron schedule could not be identified", r.command("logs cron --tail 100"))
	}
	return good("Cron daemon and KVS schedule are present; no job was executed")
}
