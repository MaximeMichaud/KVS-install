// Package instance describes one installed stack: its directory, its .env,
// the site it serves and the kvsctl state kept next to it.
package instance

import (
	"bufio"
	"encoding/json"
	"errors"
	"fmt"
	"net"
	"os"
	"os/exec"
	"path/filepath"
	"regexp"
	"sort"
	"strings"
	"syscall"
	"time"

	"github.com/MaximeMichaud/KVS-install/cli/internal/release"
)

// DefaultRoot is where the Docker path installs the stack.
const DefaultRoot = "/opt/kvs"

// Instance is an installed stack.
type Instance struct {
	// Root holds docker/, conf/ and the kvsctl state (default /opt/kvs).
	Root string
	// DockerDir is the compose project directory (Root/docker).
	DockerDir string
	// EnvPath is DockerDir/.env.
	EnvPath string
	// Env is the parsed .env.
	Env map[string]string
	// WebRoot is the site directory on the host (/var/www/<domain>).
	WebRoot string
}

// Entry is one line of the upgrade history.
type Entry struct {
	Version string    `json:"version"`
	Action  string    `json:"action"`
	Date    time.Time `json:"date"`
	Note    string    `json:"note,omitempty"`
}

// State is what kvsctl remembers between runs.
type State struct {
	// Current is the installed stack version.
	Current string `json:"current"`
	// Previous is the version a rollback returns to.
	Previous string `json:"previous,omitempty"`
	// Files lists the release files of the current version, relative to Root.
	Files []string `json:"files,omitempty"`
	// PreviousFiles lists the release files of the previous version.
	PreviousFiles []string `json:"previous_files,omitempty"`
	// Checksums is the sha256 of every release file as kvsctl laid it,
	// relative path to hex sum, which tells the files of the release from
	// the ones edited on the machine afterwards.
	Checksums map[string]string `json:"checksums,omitempty"`
	// Database is what the installed release declared about the schema:
	// "migrates" when it changes it, empty when it leaves it alone.
	Database string `json:"database,omitempty"`
	// OneWay is set when the installed release cannot be undone by
	// restarting the previous images, a MariaDB series change being the
	// case: a rollback recreates the data directory and replays the backup.
	OneWay bool `json:"one_way,omitempty"`
	// Images are the variant images the current version wrote to .env,
	// KVS_<SERVICE>_IMAGE to ref@digest, and PreviousImages the same for
	// the previous version, so a rollback puts the old values back.
	Images         map[string]string `json:"images,omitempty"`
	PreviousImages map[string]string `json:"previous_images,omitempty"`
	// ReleaseImages are the images every version installed by kvsctl
	// pinned, as ref@digest, so clean knows what a dropped version leaves
	// on the engine even when its override read them from .env.
	ReleaseImages map[string][]string `json:"release_images,omitempty"`
	History       []Entry             `json:"history,omitempty"`
}

// Detect reads the stack at root, or at $KVS_INSTALL_DIR, or /opt/kvs.
func Detect(root string) (*Instance, error) {
	if root == "" {
		root = os.Getenv("KVS_INSTALL_DIR")
	}
	if root == "" {
		root = DefaultRoot
	}
	root, err := filepath.Abs(root)
	if err != nil {
		return nil, err
	}
	inst := &Instance{Root: root, DockerDir: filepath.Join(root, "docker")}
	inst.EnvPath = filepath.Join(inst.DockerDir, ".env")
	if _, err := os.Stat(filepath.Join(inst.DockerDir, "docker-compose.yml")); err != nil {
		return nil, fmt.Errorf("no stack in %s (docker/docker-compose.yml is missing); set KVS_INSTALL_DIR or --root", root)
	}
	inst.Env, err = ReadEnv(inst.EnvPath)
	if err != nil {
		return nil, err
	}
	if found := multiSite(inst); found != "" {
		return nil, fmt.Errorf("multi-site installations are not supported by kvsctl yet (found %s)", found)
	}
	if inst.Domain() == "" {
		return nil, fmt.Errorf("%s has no DOMAIN: the setup has not run yet", inst.EnvPath)
	}
	inst.WebRoot = filepath.Join("/var/www", inst.Domain())
	return inst, nil
}

// ReadEnv parses KEY=value lines; quotes around the value are removed.
func ReadEnv(path string) (map[string]string, error) {
	f, err := os.Open(path)
	if err != nil {
		return nil, err
	}
	defer f.Close()
	env := map[string]string{}
	scanner := bufio.NewScanner(f)
	for scanner.Scan() {
		line := strings.TrimSpace(scanner.Text())
		if line == "" || strings.HasPrefix(line, "#") {
			continue
		}
		key, value, ok := strings.Cut(line, "=")
		if !ok {
			continue
		}
		key = strings.TrimSpace(key)
		value = strings.TrimSpace(value)
		if len(value) >= 2 && (value[0] == '"' && value[len(value)-1] == '"' || value[0] == '\'' && value[len(value)-1] == '\'') {
			value = value[1 : len(value)-1]
		}
		env[key] = value
	}
	return env, scanner.Err()
}

// SetEnv writes key=value into .env, replacing the line if the key exists,
// through a temporary file so a crash never leaves a half written .env.
func (i *Instance) SetEnv(key, value string) error {
	data, err := os.ReadFile(i.EnvPath)
	if err != nil {
		return err
	}
	lines := strings.Split(strings.TrimRight(string(data), "\n"), "\n")
	replaced := false
	for n, line := range lines {
		if strings.HasPrefix(strings.TrimSpace(line), key+"=") {
			lines[n] = key + "=" + value
			replaced = true
		}
	}
	if !replaced {
		lines = append(lines, key+"="+value)
	}
	info, err := os.Stat(i.EnvPath)
	if err != nil {
		return err
	}
	if err := writeAtomic(i.EnvPath, []byte(strings.Join(lines, "\n")+"\n"), info.Mode().Perm()); err != nil {
		return err
	}
	i.Env[key] = value
	return nil
}

// UnsetEnv removes key from .env when it is there, through the same
// temporary file as SetEnv.
func (i *Instance) UnsetEnv(key string) error {
	data, err := os.ReadFile(i.EnvPath)
	if err != nil {
		return err
	}
	lines := strings.Split(strings.TrimRight(string(data), "\n"), "\n")
	kept := lines[:0]
	removed := false
	for _, line := range lines {
		if strings.HasPrefix(strings.TrimSpace(line), key+"=") {
			removed = true
			continue
		}
		kept = append(kept, line)
	}
	if !removed {
		return nil
	}
	info, err := os.Stat(i.EnvPath)
	if err != nil {
		return err
	}
	if err := writeAtomic(i.EnvPath, []byte(strings.Join(kept, "\n")+"\n"), info.Mode().Perm()); err != nil {
		return err
	}
	delete(i.Env, key)
	return nil
}

// mergeKept are the keys a merge never adds: the operator gives them their
// value at install time, or the setup owns them, so a release example must
// never resurrect one with its default.
var mergeKept = map[string]bool{
	"DOMAIN":                true,
	"EMAIL":                 true,
	"MARIADB_ROOT_PASSWORD": true, // pragma: allowlist secret
	"MARIADB_PASSWORD":      true, // pragma: allowlist secret
	"COMPOSE_FILE":          true,
	"COMPOSE_PROFILES":      true,
	"COMPOSE_PROJECT_NAME":  true,
	"SITE_PREFIX":           true,
	"TABLES_PREFIX":         true,
	"KVS_IMPORT_COMPLETED":  true,
	"KVS_STACK_VERSION":     true,
}

// MergeEnv appends to the live .env every KEY=value of the release's
// .env.example that the live file lacks, each with the comment lines
// standing immediately above it in the example, and returns the keys added
// in the order the example lists them. A key already in the live file keeps
// its value and its place, and the keys of mergeKept are never added.
func (i *Instance) MergeEnv(examplePath string) ([]string, error) {
	example, err := os.ReadFile(examplePath)
	if err != nil {
		return nil, err
	}
	live, err := os.ReadFile(i.EnvPath)
	if err != nil {
		return nil, err
	}
	have, err := ReadEnv(i.EnvPath)
	if err != nil {
		return nil, err
	}
	var added, appended, block []string
	values := map[string]string{}
	for _, line := range strings.Split(string(example), "\n") {
		line = strings.TrimRight(line, "\r")
		trimmed := strings.TrimSpace(line)
		if trimmed == "" {
			block = nil
			continue
		}
		if strings.HasPrefix(trimmed, "#") {
			block = append(block, line)
			continue
		}
		key, value, ok := strings.Cut(trimmed, "=")
		key = strings.TrimSpace(key)
		if ok && key != "" {
			if _, known := have[key]; !known && !mergeKept[key] {
				appended = append(appended, "")
				appended = append(appended, block...)
				appended = append(appended, trimmed)
				added = append(added, key)
				have[key] = value
				values[key] = strings.TrimSpace(value)
			}
		}
		block = nil
	}
	if len(added) == 0 {
		return nil, nil
	}
	info, err := os.Stat(i.EnvPath)
	if err != nil {
		return nil, err
	}
	body := strings.TrimRight(string(live), "\n") + "\n" + strings.Join(appended, "\n") + "\n"
	if err := writeAtomic(i.EnvPath, []byte(body), info.Mode().Perm()); err != nil {
		return nil, err
	}
	for _, key := range added {
		i.Env[key] = values[key]
	}
	return added, nil
}

// Domain is the site's domain.
func (i *Instance) Domain() string { return i.Env["DOMAIN"] }

// ProjectName is the compose project, which prefixes containers and volumes.
func (i *Instance) ProjectName() string {
	if p := i.Env["COMPOSE_PROJECT_NAME"]; p != "" {
		return p
	}
	if p := i.Env["SITE_PREFIX"]; p != "" {
		return p
	}
	return "kvs"
}

// ProjectNameKnown reports whether the .env names the compose project
// itself, by COMPOSE_PROJECT_NAME or SITE_PREFIX. Without one ProjectName
// guesses, the label filter can match no container at all, and a caller
// must not read that emptiness as a healthy project.
func (i *Instance) ProjectNameKnown() bool {
	return i.Env["COMPOSE_PROJECT_NAME"] != "" || i.Env["SITE_PREFIX"] != ""
}

// ContainerPrefix names containers (<prefix>-php, <prefix>-mariadb ...).
func (i *Instance) ContainerPrefix() string {
	if p := i.Env["SITE_PREFIX"]; p != "" {
		return p
	}
	return "kvs"
}

// PHPVersion is the PHP series the stack runs (8.1 when unset).
func (i *Instance) PHPVersion() string {
	for _, key := range []string{"PHP_VERSION", "KVS_PHP_VERSION"} {
		if v := i.Env[key]; v != "" {
			return v
		}
	}
	return "8.1"
}

// IonCube reports whether the site runs encoded files, which binds it to
// its PHP series.
func (i *Instance) IonCube() bool {
	return strings.EqualFold(i.Env["IONCUBE"], "YES") || strings.EqualFold(i.Env["IONCUBE"], "true")
}

// PublishedEndpoint is the host and port the site is reached on from this
// machine. HTTPS_PORT carries the PORT, IPv4:PORT and [IPv6]:PORT forms
// docker/setup.sh publishes (parse_publish_endpoint); a wildcard bind and a
// value kvsctl cannot read are reached through the loopback.
func (i *Instance) PublishedEndpoint() (host, port string) {
	endpoint := strings.TrimSpace(i.Env["HTTPS_PORT"])
	if endpoint == "" {
		return "127.0.0.1", "443"
	}
	if !strings.Contains(endpoint, ":") {
		return "127.0.0.1", endpoint
	}
	host, port, err := net.SplitHostPort(endpoint)
	if err != nil || port == "" {
		return "127.0.0.1", "443"
	}
	switch host {
	case "", "0.0.0.0", "::":
		host = "127.0.0.1"
	}
	return host, port
}

// HTTPSPort is the host port the site listens on.
func (i *Instance) HTTPSPort() string {
	_, port := i.PublishedEndpoint()
	return port
}

// SiteHost is the name the site answers on: the domain, or www.<domain>
// when USE_WWW is true, because the nginx entrypoint then serves the site
// on www and answers 301 on the apex.
func (i *Instance) SiteHost() string {
	domain := i.Domain()
	if domain == "" {
		return ""
	}
	if strings.EqualFold(strings.TrimSpace(i.Env["USE_WWW"]), "true") {
		return "www." + domain
	}
	return domain
}

var versionRe = regexp.MustCompile(`\$config\[['"]project_version['"]\]\s*=\s*['"]([^'"]+)['"]`)

// KVSVersion reads the KVS version of the site, "" when unknown.
func (i *Instance) KVSVersion() string {
	data, err := os.ReadFile(filepath.Join(i.WebRoot, "admin", "include", "version.php"))
	if err != nil {
		return ""
	}
	if m := versionRe.FindSubmatch(data); m != nil {
		return string(m[1])
	}
	return ""
}

// StateDir holds the kvsctl state and the kept releases.
func (i *Instance) StateDir() string { return filepath.Join(i.Root, "kvsctl") }

// ReleasesDir keeps the file sets of installed versions for rollbacks.
func (i *Instance) ReleasesDir() string { return filepath.Join(i.StateDir(), "releases") }

// BackupDir receives the backups taken before an upgrade.
func (i *Instance) BackupDir() string { return filepath.Join(i.Root, "backups") }

func (i *Instance) statePath() string { return filepath.Join(i.StateDir(), "state.json") }

// LoadState reads the state; a missing file means the stack was never adopted.
func (i *Instance) LoadState() (*State, error) {
	data, err := os.ReadFile(i.statePath())
	if errors.Is(err, os.ErrNotExist) {
		return nil, nil
	}
	if err != nil {
		return nil, err
	}
	var s State
	if err := json.Unmarshal(data, &s); err != nil {
		return nil, fmt.Errorf("%s: %w", i.statePath(), err)
	}
	return &s, nil
}

// SaveState writes the state atomically.
func (i *Instance) SaveState(s *State) error {
	if err := os.MkdirAll(i.StateDir(), 0o750); err != nil {
		return err
	}
	data, err := json.MarshalIndent(s, "", "  ")
	if err != nil {
		return err
	}
	return writeAtomic(i.statePath(), data, 0o600)
}

// TrackedFiles lists the release files of a git checkout, relative to Root:
// the paths a release bundle ships (release.Paths) as git tracks them. This
// is how an installation made by kvs-install.sh, which clones the
// repository, is adopted; whatever else the checkout holds is never touched.
func (i *Instance) TrackedFiles() ([]string, error) {
	if _, err := os.Stat(filepath.Join(i.Root, ".git")); err != nil {
		return nil, fmt.Errorf("%s is not a git checkout: adopt only knows installations cloned by kvs-install.sh", i.Root)
	}
	args := append([]string{"-C", i.Root, "ls-files", "-z", "--"}, release.Paths...)
	cmd := exec.Command("git", args...)
	out, err := cmd.Output()
	if err != nil {
		return nil, fmt.Errorf("git ls-files: %w", err)
	}
	var files []string
	for _, f := range strings.Split(string(out), "\x00") {
		if f != "" {
			files = append(files, f)
		}
	}
	sort.Strings(files)
	if len(files) == 0 {
		return nil, fmt.Errorf("%s tracks none of the release paths (%s): not an installation cloned by kvs-install.sh", i.Root, strings.Join(release.Paths, ", "))
	}
	return files, nil
}

// multiSite names what makes root a multi-site installation, "" when it is
// the single-site layout kvsctl knows: MODE=multi is what setup.sh writes
// for the Caddy layout, and docker/multi-site/sites holds one directory per
// site that site-manager.sh registered.
func multiSite(i *Instance) string {
	if strings.EqualFold(strings.TrimSpace(i.Env["MODE"]), "multi") {
		return fmt.Sprintf("MODE=multi in %s", i.EnvPath)
	}
	sites := filepath.Join(i.DockerDir, "multi-site", "sites")
	if entries, err := os.ReadDir(sites); err == nil && len(entries) > 0 {
		return sites
	}
	return ""
}

// writeAtomic replaces path with data through a temporary file in the same
// directory: the mode and, when kvsctl runs as root, the owner of the file
// it replaces are kept, and both the file and the directory are flushed
// before the rename returns, so a power cut never leaves a truncated one.
func writeAtomic(path string, data []byte, mode os.FileMode) error {
	dir := filepath.Dir(path)
	f, err := os.CreateTemp(dir, "."+filepath.Base(path)+".kvsctl*")
	if err != nil {
		return err
	}
	tmp := f.Name()
	err = fillTemp(f, tmp, path, data, mode)
	if cerr := f.Close(); err == nil {
		err = cerr
	}
	if err != nil {
		os.Remove(tmp)
		return err
	}
	if err := os.Rename(tmp, path); err != nil {
		os.Remove(tmp)
		return err
	}
	return syncDir(dir)
}

func fillTemp(f *os.File, tmp, path string, data []byte, mode os.FileMode) error {
	if _, err := f.Write(data); err != nil {
		return err
	}
	if err := f.Chmod(mode); err != nil {
		return err
	}
	if err := keepOwner(tmp, path); err != nil {
		return err
	}
	return f.Sync()
}

// keepOwner gives tmp the owner of the file it replaces, the way
// set_env_value does in docker/setup.sh: a .env written by a setup run
// under another account must not change hands because root upgraded.
func keepOwner(tmp, path string) error {
	if os.Geteuid() != 0 {
		return nil
	}
	info, err := os.Stat(path)
	if errors.Is(err, os.ErrNotExist) {
		return nil
	}
	if err != nil {
		return err
	}
	st, ok := info.Sys().(*syscall.Stat_t)
	if !ok {
		return nil
	}
	return os.Chown(tmp, int(st.Uid), int(st.Gid))
}

func syncDir(dir string) error {
	f, err := os.Open(dir)
	if err != nil {
		return err
	}
	defer f.Close()
	return f.Sync()
}
