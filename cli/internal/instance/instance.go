// Package instance describes one installed stack: its directory, its .env,
// the site it serves and the kvsctl state kept next to it.
package instance

import (
	"bytes"
	"encoding/json"
	"errors"
	"fmt"
	"net"
	"os"
	"path/filepath"
	"regexp"
	"sort"
	"strings"
	"time"

	"golang.org/x/sys/unix"

	"github.com/MaximeMichaud/KVS-install/cli/internal/dotenv"
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

// Entry is one line of the upgrade history. Its Date is when the run that
// added it started (Journal.Started), not when it was written: the date
// names that run, which is how recover tells that the state already
// records its end, whatever the clock did since. An adopt dates its entry
// when it records it, and a kvsctl before JournalFormat 2 dated the entry
// of a run when it wrote it.
type Entry struct {
	Version string    `json:"version"`
	Action  string    `json:"action"`
	Date    time.Time `json:"date"`
	Note    string    `json:"note,omitempty"`
	// Undid is set on the entry of a rollback that undid a run which did
	// not end on its version: how that run ended and why. An entry an
	// older kvsctl wrote has none, and says it in its note alone.
	Undid *Undone `json:"undid,omitempty"`
}

// Undone is a run a rollback undid, as the history keeps it: status and
// check read from it whether the last upgrade failed, which leaves a cause
// to fix before it runs again, or was cancelled or interrupted, which
// leave none.
type Undone struct {
	// Action is the run, ActionUpgrade or ActionRollback, and To the
	// version it went to.
	Action string `json:"action"`
	To     string `json:"to"`
	// Outcome is how it ended, and Cause why: the first line of the error
	// it failed or was cancelled on, or the phase a run cut short had
	// reached.
	Outcome string `json:"outcome"`
	Cause   string `json:"cause,omitempty"`
}

// How a run that did not end on its version ended: it failed by itself;
// the first Ctrl-C or a SIGTERM cancelled it; or a kill, a crash or a power
// cut stopped it and recover undid it.
const (
	OutcomeFailed      = "failed"
	OutcomeCancelled   = "cancelled"
	OutcomeInterrupted = "interrupted"
)

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
	// Images are the variant settings the current version wrote to .env:
	// KVS_<SERVICE>_IMAGE to ref@digest, and MARIADB_VERSION when the
	// upgrade moved MariaDB to another series. PreviousImages are the
	// values .env held for those keys before, so a rollback puts the old
	// values back and removes the keys that were not there.
	Images         map[string]string `json:"images,omitempty"`
	PreviousImages map[string]string `json:"previous_images,omitempty"`
	// ReleaseImages are the images every version installed by kvsctl
	// pinned, as ref@digest, so clean knows what a dropped version leaves
	// on the engine even when its override read them from .env.
	ReleaseImages map[string][]string `json:"release_images,omitempty"`
	// UpgradeBackup is the archive the upgrade to Current took before it
	// changed anything, by its absolute path: what a manual rollback
	// replays. It is empty when that upgrade took none (--skip-backup), and
	// in a state written before kvsctl recorded it.
	UpgradeBackup string `json:"upgrade_backup,omitempty"`
	// AdoptedCommit and AdoptedCommitDate are the HEAD commit of the git
	// checkout adopt recorded and its committer date, empty for a stack
	// that was not adopted from a checkout. A release dated before that
	// commit would take the checkout's files back.
	AdoptedCommit     string    `json:"adopted_commit,omitempty"`
	AdoptedCommitDate time.Time `json:"adopted_commit_date,omitzero"`
	History           []Entry   `json:"history,omitempty"`
}

// Upgraded reports whether kvsctl has upgraded this stack: a successful
// upgrade in its history. From then on its files and its record come from
// kvsctl, not from the checkout it was adopted from. An upgrade that failed
// and was rolled back leaves no such entry.
func (s *State) Upgraded() bool {
	if s == nil {
		return false
	}
	for _, e := range s.History {
		if e.Action == ActionUpgrade {
			return true
		}
	}
	return false
}

// Unreleased is the version adopt records for a git checkout that no
// release names: older than every release, so the first upgrade installs
// one.
const Unreleased = "0.0.0"

// Label is how a version of the state reads to the operator. Unreleased is
// the checkout adopt recorded, named by its commit; every other version is
// itself. The state, the journal and the history keep the version.
func (s *State) Label(version string) string {
	if version != Unreleased || s == nil || s.AdoptedCommit == "" {
		return version
	}
	commit := s.AdoptedCommit
	if len(commit) > 12 {
		commit = commit[:12]
	}
	return "unreleased checkout " + commit
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

// ReadEnv reads a .env the way docker compose reads it (package dotenv):
// export lines, quotes and their escapes, inline comments, CRLF line ends
// and references to other settings, which are expanded with the
// environment kvsctl gives its compose commands (dotenv.Isolate), so a
// value read here is the value compose runs the stack with. A file compose
// refuses is refused.
func ReadEnv(path string) (map[string]string, error) {
	data, err := os.ReadFile(path)
	if err != nil {
		return nil, err
	}
	env, err := parseEnv(path, data)
	if err != nil {
		return nil, fmt.Errorf("%s cannot be read, by docker compose either: %w", path, err)
	}
	return env, nil
}

// parseEnv reads data as the .env at path holds it (ReadEnv).
func parseEnv(path string, data []byte) (map[string]string, error) {
	return dotenv.Parse(data, dotenv.Lookup(os.Environ(), data, exampleBeside(path)))
}

// exampleBeside is the .env.example next to a .env, nil when there is none:
// the keys it sets are left to the files in the compose environment too.
func exampleBeside(envPath string) []byte {
	data, err := os.ReadFile(filepath.Join(filepath.Dir(envPath), ".env.example"))
	if err != nil {
		return nil
	}
	return data
}

// SetEnv sets key to value in .env: every setting of key is written again
// where it stands, its export keyword and an inline comment kept, in a form
// compose and the shell of the scripts both read as value, the other
// settings of its line each on a line of its own, or a new line is added
// at the end (dotenv.Set). A key or a value no form gives both alike is
// refused, and so is an edit that a line of the operator's would have the
// shell read otherwise, or the opposite edit a rollback makes, in the cases
// dotenv.Set lists. A line the shell misreads before the edit, such as a
// quote left open in a bare value, stays the operator's: the edit does not
// make the file readable by the shell. The file is replaced through a
// temporary file, so a crash never leaves a half written .env.
func (i *Instance) SetEnv(key, value string) error {
	return i.editEnv(func(data []byte) ([]byte, bool, error) {
		out, err := dotenv.Set(data, key, value)
		return out, true, err
	})
}

// UnsetEnv removes every setting of key from .env, export lines included,
// through the same temporary file as SetEnv; a setting that shares its line
// with others leaves them, each on a line of its own (dotenv.Unset). A key
// that is not there is no error. An edit that a line of the operator's
// would have the shell of the scripts read otherwise, or the opposite edit
// a rollback makes, is refused in the cases dotenv.Set lists, one where the
// shell reads key in another value among them; a line the shell misreads
// before the edit stays the operator's.
func (i *Instance) UnsetEnv(key string) error {
	return i.editEnv(func(data []byte) ([]byte, bool, error) {
		return dotenv.Unset(data, key)
	})
}

// editEnv rewrites .env with edit, when it changes something, and reads the
// settings again from what was written.
func (i *Instance) editEnv(edit func([]byte) ([]byte, bool, error)) error {
	data, err := os.ReadFile(i.EnvPath)
	if err != nil {
		return err
	}
	out, changed, err := edit(data)
	if err != nil {
		return fmt.Errorf("%s: %w", i.EnvPath, err)
	}
	if !changed {
		return nil
	}
	return i.ReplaceEnv(out)
}

// ReplaceEnv writes data as the whole .env, through the same temporary
// file as SetEnv, with the mode and the owner of the live file, and takes
// the settings it holds. Data compose could not read is refused (CheckEnv),
// and the live file stays.
func (i *Instance) ReplaceEnv(data []byte) error {
	env, err := i.readNewEnv(data)
	if err != nil {
		return err
	}
	info, err := os.Stat(i.EnvPath)
	if err != nil {
		return err
	}
	if err := i.writeEnv(data, info.Mode().Perm()); err != nil {
		return err
	}
	i.Env = env
	return nil
}

// CheckEnv returns the error ReplaceEnv gives data, nil when it takes it:
// a .env docker compose would not read. A caller asks first when the write
// comes after a change it cannot take back, the replay of a restore.
func (i *Instance) CheckEnv(data []byte) error {
	_, err := i.readNewEnv(data)
	return err
}

// readNewEnv reads data as the .env that would replace the live one.
func (i *Instance) readNewEnv(data []byte) (map[string]string, error) {
	env, err := parseEnv(i.EnvPath, data)
	if err != nil {
		return nil, fmt.Errorf("the new %s would not be read by docker compose: %w", i.EnvPath, err)
	}
	return env, nil
}

// writeEnv replaces .env, reached from the root without following a link
// (release.WriteFile): a link at .env itself is replaced by the new file.
func (i *Instance) writeEnv(data []byte, mode os.FileMode) error {
	root, rel := filepath.Dir(i.EnvPath), filepath.Base(i.EnvPath)
	if r, err := filepath.Rel(i.Root, i.EnvPath); err == nil && r != ".." && !strings.HasPrefix(r, ".."+string(filepath.Separator)) {
		root, rel = i.Root, filepath.ToSlash(r)
	}
	return release.WriteFile(root, rel, data, mode, keepOwner)
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

// MergeEnv appends to the live .env every setting of the release's
// .env.example that the live file lacks, each with the comment lines
// standing immediately above it in the example, and returns the keys added
// in the order the example lists them. Both files are read the way compose
// reads them: a key the live file sets in any form, exported or left to the
// environment, keeps its value and its place, and the keys of mergeKept are
// never added.
func (i *Instance) MergeEnv(examplePath string) ([]string, error) {
	example, err := os.ReadFile(examplePath)
	if err != nil {
		return nil, err
	}
	live, err := os.ReadFile(i.EnvPath)
	if err != nil {
		return nil, err
	}
	settings, err := dotenv.Scan(example)
	if err != nil {
		return nil, fmt.Errorf("%s: %w", examplePath, err)
	}
	have, err := dotenv.Scan(live)
	if err != nil {
		return nil, fmt.Errorf("%s cannot be read, by docker compose either: %w", i.EnvPath, err)
	}
	known := map[string]bool{}
	for _, e := range have {
		known[e.Key] = true
	}
	newline := "\n"
	if bytes.Contains(live, []byte("\r\n")) {
		newline = "\r\n"
	}
	var added, appended []string
	previousEnd := 0
	for n, e := range settings {
		gap := string(example[previousEnd:lineStart(example, e.Start)])
		previousEnd = e.LineEnd
		if e.Inherited || known[e.Key] || mergeKept[e.Key] {
			continue
		}
		known[e.Key] = true
		// The statement and the rest of its line, an inline comment, unless
		// another setting follows on that line.
		end := e.LineEnd
		if n+1 < len(settings) && settings[n+1].Start < end {
			end = e.End
		}
		appended = append(appended, "")
		appended = append(appended, commentBlock(gap)...)
		appended = append(appended, strings.TrimRight(string(example[e.Start:end]), "\r\n"))
		added = append(added, e.Key)
	}
	if len(added) == 0 {
		return nil, nil
	}
	body := strings.TrimRight(string(live), "\r\n") + newline + strings.Join(appended, newline) + newline
	if err := i.ReplaceEnv([]byte(body)); err != nil {
		return nil, err
	}
	return added, nil
}

// lineStart is the offset of the start of the line holding offset at.
func lineStart(data []byte, at int) int {
	return bytes.LastIndexByte(data[:at], '\n') + 1
}

// commentBlock is the comment lines that end gap, the text between two
// settings, up to the first blank line above them.
func commentBlock(gap string) []string {
	lines := strings.Split(strings.TrimRight(gap, "\r\n"), "\n")
	first := len(lines)
	for first > 0 && strings.HasPrefix(strings.TrimSpace(lines[first-1]), "#") {
		first--
	}
	block := lines[first:]
	for n := range block {
		block[n] = strings.TrimRight(block[n], "\r")
	}
	return block
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
// its PHP series. It reads IONCUBE with the words the php and cron
// entrypoints accept (apply_ioncube_setting): unset or empty, the default
// of the stack, and yes, true, 1 or on in any case keep the loader;
// anything else, no, false, 0, off, disabled or a word they do not know,
// disables it.
func (i *Instance) IonCube() bool {
	switch strings.ToLower(i.Env["IONCUBE"]) {
	case "", "yes", "true", "1", "on":
		return true
	}
	return false
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

// maxVersionFile bounds the version.php kvsctl reads: the file is a few
// hundred bytes.
const maxVersionFile = 64 << 10

// KVSVersion reads the KVS version of the site, "" when unknown. The web
// root belongs to the PHP container's user, and kvsctl runs as root, so
// version.php is read only as a regular file of a bounded size, reached
// without following a link (release.ReadBeneath).
func (i *Instance) KVSVersion() string {
	data, err := release.ReadBeneath(i.WebRoot, "admin/include/version.php", maxVersionFile)
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
	if err := i.isCheckout(); err != nil {
		return nil, err
	}
	out, err := i.git(append([]string{"ls-files", "-z", "--"}, release.Paths...)...)
	if err != nil {
		return nil, err
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
// directory (release.WriteFile): the mode and, when kvsctl runs as root, the
// owner of the file it replaces are kept, and both the file and the
// directory are flushed before it returns, so a power cut never leaves a
// truncated one.
func writeAtomic(path string, data []byte, mode os.FileMode) error {
	return release.WriteFile(filepath.Dir(path), filepath.Base(path), data, mode, keepOwner)
}

// euid and fchown are variables so a test can run the branch of keepOwner
// that only runs as root.
var (
	euid   = os.Geteuid
	fchown = (*os.File).Chown
)

// keepOwner gives f, the new file, the owner of replaced, the file it
// replaces (release.WriteFile reads it without following a link), the way
// set_env_value does in docker/setup.sh: a .env written by a setup run under
// another account must not change hands because root upgraded. Only a
// regular file hands its owner on: a link or anything else planted at the
// name leaves the new file to root, who writes it. The owner is set on the
// open file, never through a path.
func keepOwner(f *os.File, replaced *unix.Stat_t) error {
	if euid() != 0 || replaced == nil || replaced.Mode&unix.S_IFMT != unix.S_IFREG {
		return nil
	}
	return fchown(f, int(replaced.Uid), int(replaced.Gid))
}

func syncDir(dir string) error {
	f, err := os.Open(dir)
	if err != nil {
		return err
	}
	defer f.Close()
	return f.Sync()
}
