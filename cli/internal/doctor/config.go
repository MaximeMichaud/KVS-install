package doctor

import (
	"context"
	"fmt"
	"net"
	"net/url"
	"os"
	"path/filepath"
	"regexp"
	"slices"
	"strconv"
	"strings"

	"github.com/MaximeMichaud/KVS-install/cli/internal/instance"
	"github.com/MaximeMichaud/KVS-install/cli/internal/semver"
	"github.com/MaximeMichaud/KVS-install/cli/internal/upgrade"
)

func (r *runner) filesPresent() Result {
	path := filepath.Join(r.inst.DockerDir, "docker-compose.yml")
	info, err := os.Stat(path)
	if err != nil || !info.Mode().IsRegular() {
		return failure("Installation Compose file is missing or unreadable", "Select the installation with --root DIR", path)
	}
	return good("Installation Compose file found", path)
}

var lineNumber = regexp.MustCompile(`\bline [0-9]+`)

func (r *runner) readEnv() Result {
	info, err := os.Stat(r.inst.EnvPath)
	if err != nil || !info.Mode().IsRegular() || info.Size() > 1<<20 {
		return failure(".env is missing, unreadable or not a regular file under 1 MiB", "Check "+r.inst.EnvPath)
	}
	env, err := instance.ReadEnv(r.inst.EnvPath)
	if err != nil {
		// A parser error can contain the complete value of a password. Only
		// its line number is safe to put in a report, even with --verbose.
		where := lineNumber.FindString(err.Error())
		if where != "" {
			where = " at " + where
		}
		return failure("Could not parse .env"+where, "Check quoting and variable references in "+r.inst.EnvPath)
	}
	r.inst.Env = env
	return good(".env parsed with Compose interpolation rules")
}

var domainLabel = regexp.MustCompile(`^[a-zA-Z0-9](?:[a-zA-Z0-9-]*[a-zA-Z0-9])?$`)

func validDomain(domain string) bool {
	if domain == "" || len(domain) > 64 {
		return false
	}
	for _, part := range strings.Split(domain, ".") {
		if len(part) > 63 || !domainLabel.MatchString(part) {
			return false
		}
	}
	return true
}

func validPort(value string, publish bool) bool {
	if value == "" {
		return true
	}
	port := value
	if publish && strings.Contains(value, ":") {
		host, p, err := net.SplitHostPort(value)
		if err != nil || net.ParseIP(host) == nil {
			return false
		}
		port = p
	}
	n, err := strconv.Atoi(port)
	return err == nil && n > 0 && n <= 65535
}

func (r *runner) settings() Result {
	env := r.inst.Env
	var problems []string
	if !validDomain(r.inst.Domain()) {
		problems = append(problems, "DOMAIN must be a hostname of at most 64 characters, without a scheme, path or port")
	}
	if mode := env["MODE"]; mode != "" && mode != "single" {
		problems = append(problems, "MODE must be single; kvsctl does not support multi-site installations")
	}
	if entries, _ := os.ReadDir(filepath.Join(r.inst.DockerDir, "multi-site", "sites")); len(entries) > 0 {
		problems = append(problems, "A multi-site sites directory is populated; kvsctl does not support this layout")
	}
	for _, key := range []string{"HTTP_PORT", "HTTPS_PORT", "PROJECT_HTTPS_PORT", "MARIADB_HOST_PORT", "CACHE_HOST_PORT", "MANTICORE_MYSQL_HOST_PORT", "MANTICORE_HTTP_HOST_PORT"} {
		if !validPort(env[key], key == "HTTP_PORT" || key == "HTTPS_PORT") {
			problems = append(problems, key+" is not a valid port or supported published endpoint")
		}
	}
	for _, key := range []string{"USE_WWW", "CLOUDFLARE_ENABLED", "ENABLE_MANTICORE", "DISABLE_KVS_SUPPORT_ACCESS"} {
		if value := strings.ToLower(env[key]); value != "" && value != "true" && value != "false" {
			problems = append(problems, key+" must be true or false")
		}
	}
	if value := strings.ToLower(env["IONCUBE"]); !slices.Contains([]string{"", "yes", "true", "1", "on", "no", "false", "0", "off", "disabled"}, value) {
		problems = append(problems, "IONCUBE has an unrecognized value")
	}
	if value := strings.ToLower(env["YT_DLP_AUTO_UPDATE"]); !slices.Contains([]string{"", "yes", "true", "1", "on", "no", "false", "0", "off", "disabled"}, value) {
		problems = append(problems, "YT_DLP_AUTO_UPDATE has an unrecognized value")
	}
	if value := env["SSL_PROVIDER"]; value != "" && !slices.Contains([]string{"letsencrypt", "zerossl", "selfsigned"}, value) {
		problems = append(problems, "SSL_PROVIDER must be letsencrypt, zerossl or selfsigned")
	}
	if !slices.Contains([]string{"8.1", "8.2", "8.3", "8.4"}, r.inst.PHPVersion()) {
		problems = append(problems, "PHP_VERSION must name a PHP series supported by this stack (8.1, 8.2, 8.3 or 8.4)")
	}
	profiles := strings.Split(env["COMPOSE_PROFILES"], ",")
	if slices.Contains(profiles, "dragonfly") && slices.Contains(profiles, "memcached") {
		problems = append(problems, "COMPOSE_PROFILES enables both cache backends on the same cache endpoint")
	}
	if len(problems) > 0 {
		return failure("Invalid stack settings", "Review "+r.inst.EnvPath, problems...)
	}
	r.inst.WebRoot = filepath.Join("/var/www", r.inst.Domain())
	return good("Domain, ports, profiles and stack settings are valid")
}

func (r *runner) composeVersion(ctx context.Context) Result {
	v, err := r.probe.version(ctx)
	if err != nil {
		return failure("Docker Compose is unavailable", "Check 'docker compose version' and the Docker CLI permissions")
	}
	if _, err := semver.Parse(v); err != nil {
		return failure("Docker Compose returned an unreadable version", "Check 'docker compose version'")
	}
	minimum := "2.10.0"
	if _, err := os.Stat(filepath.Join(r.inst.DockerDir, "docker-compose.release.yml")); err == nil {
		minimum = "2.19.0"
	}
	if semver.Less(v, minimum) {
		return failure("Docker Compose "+v+" is older than required "+minimum, "Update the Docker Compose plugin")
	}
	return good("Docker Compose " + v + " is compatible")
}

func (r *runner) compose(ctx context.Context) Result {
	project, err := r.probe.compose(ctx, r.inst.DockerDir)
	if err != nil {
		return failure("Compose could not resolve the active configuration", "Run 'docker compose config --quiet' in "+r.inst.DockerDir+" to inspect the local error")
	}
	r.project = project
	// Compose, including an override's top-level name, owns the project name.
	// Do not guess it from SITE_PREFIX or the directory name.
	if override := upgrade.DefaultOverride(r.inst.DockerDir); override != "" && r.inst.Env["COMPOSE_FILE"] != "" {
		sep := r.inst.Env["COMPOSE_PATH_SEPARATOR"]
		if sep == "" {
			sep = ":"
		}
		loaded := false
		for _, path := range strings.Split(r.inst.Env["COMPOSE_FILE"], sep) {
			loaded = loaded || filepath.Base(path) == override
		}
		if !loaded {
			return warning("The operator's default override is not in COMPOSE_FILE", "Review COMPOSE_FILE before applying changes", "Ignored override: "+override)
		}
	}
	return good(fmt.Sprintf("Compose configuration is valid; project %s, %d active services", project.Name, len(project.Services)))
}

func (r *runner) record() Result {
	if !readableRecord(filepath.Join(r.inst.StateDir(), "state.json")) {
		return failure("The recorded stack state is not a regular file under 16 MiB", "Inspect "+r.inst.StateDir())
	}
	state, err := r.inst.LoadState()
	if err != nil {
		return failure("The recorded stack state is unreadable", "Inspect "+filepath.Join(r.inst.StateDir(), "state.json"))
	}
	r.state = state
	if state == nil {
		return warning("Stack is not recorded by kvsctl; runtime checks remain available", r.command("adopt"))
	}
	if state.Current == "" {
		return failure("The stack state has no current version", "Inspect "+filepath.Join(r.inst.StateDir(), "state.json"))
	}
	return good("Recorded stack: " + state.Label(state.Current))
}

func (r *runner) operation() Result {
	for _, name := range []string{"lock", "journal.json"} {
		if !readableRecord(filepath.Join(r.inst.StateDir(), name)) {
			return failure("An operation record is not a regular file under 16 MiB", "Inspect "+r.inst.StateDir())
		}
	}
	holder, err := r.inst.Holder()
	if err != nil {
		return failure("Could not inspect the installation lock", "Check read access to "+r.inst.StateDir())
	}
	j, err := r.inst.LoadJournal()
	if err != nil {
		return failure("The operation journal is unreadable", "Inspect "+filepath.Join(r.inst.StateDir(), "journal.json"))
	}
	if holder != nil {
		result := warning("Another operation holds the installation lock; this snapshot may change", "Rerun doctor once the operation has ended")
		result.Incomplete = true
		return result
	}
	if j != nil {
		return failure("An unfinished operation requires recovery", r.command("recover"), "The operation journal is still present")
	}
	return good("No operation is running or awaiting recovery")
}

func readableRecord(path string) bool {
	info, err := os.Lstat(path)
	if os.IsNotExist(err) {
		return true
	}
	return err == nil && info.Mode().IsRegular() && info.Size() <= 16<<20
}

func localEngine(endpoint string) bool {
	address, _, _ := strings.Cut(endpoint, ", from the docker context ")
	u, err := url.Parse(address)
	if err != nil {
		return false
	}
	if u.Scheme == "unix" {
		return u.Path != ""
	}
	return u.Scheme == "tcp" && (u.Hostname() == "localhost" || net.ParseIP(u.Hostname()).IsLoopback())
}

func (r *runner) engine(ctx context.Context) Result {
	client, err := r.probe.engine()
	if err != nil {
		return failure("Docker client configuration is unavailable", "Check DOCKER_HOST, DOCKER_CONTEXT and Docker CLI configuration")
	}
	r.docker = client
	if !localEngine(client.Endpoint()) {
		return failure("Doctor requires a local Docker engine for filesystem and endpoint checks", "Run doctor on the engine's host or select a local Docker context")
	}
	info, err := client.Info(ctx)
	if err != nil {
		return failure("The local Docker engine is unreachable", "Check 'docker info', socket permissions and whether Docker is running")
	}
	r.info = info
	if info.OSType != "linux" || !info.AMD64() {
		return failure("This engine does not run the supported linux/amd64 platform", "Use the platform supported by this stack")
	}
	return good("Docker "+info.Version+" is reachable (linux/amd64)", client.Endpoint())
}
