// Package doctor diagnoses an installed stack without changing it or reading
// a release manifest. Each check reports its evidence and any unmet prerequisite.
package doctor

import (
	"context"
	"fmt"
	"io"
	"net/http"
	"os"
	"path/filepath"
	"slices"
	"strings"
	"time"

	"github.com/MaximeMichaud/KVS-install/cli/internal/diskspace"
	"github.com/MaximeMichaud/KVS-install/cli/internal/dockerx"
	"github.com/MaximeMichaud/KVS-install/cli/internal/instance"
)

const (
	OK   = "ok"
	Warn = "warn"
	Fail = "fail"
	Skip = "skip"
)

type Options struct {
	Root    string
	Only    []string
	Network bool
	Strict  bool
	Timeout time.Duration
}

type Check struct {
	ID          string   `json:"id"`
	Group       string   `json:"group"`
	Description string   `json:"description"`
	Requires    []string `json:"requires,omitempty"`
}

type Result struct {
	ID         string   `json:"id"`
	Group      string   `json:"group"`
	Status     string   `json:"status"`
	Message    string   `json:"message"`
	Details    []string `json:"details,omitempty"`
	Next       string   `json:"next,omitempty"`
	Incomplete bool     `json:"incomplete,omitempty"`
	DurationMS int64    `json:"duration_ms"`
	ready      bool
}

type Summary struct {
	Passed   int `json:"passed"`
	Warnings int `json:"warnings"`
	Failed   int `json:"failed"`
	Skipped  int `json:"skipped"`
}

type Report struct {
	SchemaVersion int       `json:"schema_version"`
	Root          string    `json:"root"`
	Site          string    `json:"site,omitempty"`
	Network       bool      `json:"network"`
	Complete      bool      `json:"complete"`
	Checks        []Result  `json:"checks"`
	Summary       Summary   `json:"summary"`
	ExitCode      int       `json:"exit_code"`
	Started       time.Time `json:"started"`
	DurationMS    int64     `json:"duration_ms"`
}

type engine interface {
	Endpoint() string
	Info(context.Context) (dockerx.EngineInfo, error)
	Containers(context.Context, string) ([]dockerx.ContainerState, error)
	MountSource(context.Context, string, string) (string, error)
	PublishedPorts(context.Context, string) ([]dockerx.PublishedPort, error)
	Unpinned(context.Context, string, map[string]string) ([]string, error)
	Close() error
}

type probes struct {
	engine  func() (engine, error)
	compose func(context.Context, string) (*dockerx.ProjectConfig, error)
	version func(context.Context) (string, error)
	exec    func(context.Context, string, io.Reader, ...string) ([]byte, error)
	space   func(string) (diskspace.Space, error)
	client  *http.Client
}

type runner struct {
	opts       Options
	probe      probes
	inst       *instance.Instance
	state      *instance.State
	docker     engine
	info       dockerx.EngineInfo
	project    *dockerx.ProjectConfig
	containers []dockerx.ContainerState
	response   *http.Response
	ready      map[string]bool
	now        time.Time
}

// Catalog is ordered by prerequisites. Identifiers and groups are also the
// public --only vocabulary; adding a check must not rename an existing ID.
func Catalog() []Check {
	return []Check{
		{"config.files", "config", "Installation directory and Compose file", nil},
		{"config.env", "config", "Read .env with Compose interpolation rules", []string{"config.files"}},
		{"config.settings", "config", "Domain, ports, profiles and stack settings", []string{"config.env"}},
		{"docker.compose", "docker", "Docker Compose version", nil},
		{"config.compose", "config", "Resolved Compose configuration and overrides", []string{"config.env", "docker.compose"}},
		{"state.record", "state", "Recorded stack version", []string{"config.files"}},
		{"state.operation", "state", "Current lock and interrupted operation", []string{"config.files"}},
		{"docker.engine", "docker", "Local Docker engine and architecture", nil},
		{"services", "services", "Expected services, health and completed init jobs", []string{"config.compose", "docker.engine"}},
		{"php", "php", "PHP versions, extensions and IonCube in PHP-FPM and cron", []string{"services", "config.settings"}},
		{"tools", "php", "FFmpeg and media tools in PHP-FPM and cron", []string{"services"}},
		{"database", "database", "Database query from PHP using the site's credentials", []string{"services"}},
		{"cache", "cache", "Read-only cache protocol probe from PHP", []string{"services"}},
		{"search", "search", "Manticore status and index rebuild failure markers", []string{"services"}},
		{"cron", "cron", "Cron daemon and KVS schedule", []string{"services"}},
		{"storage.installation", "storage", "Installation space, inodes and directory access", nil},
		{"storage.data", "storage", "Docker and actual database/site mount filesystems", []string{"services"}},
		{"backups", "backups", "Local backup metadata and age, without a restore", []string{"config.files"}},
		{"files", "integrity", "Release file checksums recorded locally", []string{"state.record"}},
		{"images", "integrity", "Running images against locally recorded release pins", []string{"state.record", "services"}},
		{"http", "http", "Local site and admin HTTP responses", []string{"services", "config.settings"}},
		{"tls", "http", "Local certificate hostname, validity and trust mode", []string{"http"}},
		{"network.dns", "network", "Public site DNS lookup (requires --network)", []string{"config.settings"}},
		{"network.https", "network", "Public HTTPS endpoint (requires --network)", []string{"network.dns"}},
		{"network.registries", "network", "Configured image registry endpoints (requires --network)", []string{"config.compose"}},
	}
}

// Validate rejects misspelled selections before any probe runs.
func Validate(o Options) error {
	if o.Timeout <= 0 {
		return fmt.Errorf("--timeout must be greater than zero")
	}
	for _, name := range o.Only {
		found := false
		for _, c := range Catalog() {
			found = found || name == c.ID || name == c.Group
		}
		if !found {
			return fmt.Errorf("unknown doctor check or group %q; run 'kvsctl doctor --list-checks'", name)
		}
		if (name == "network" || strings.HasPrefix(name, "network.")) && !o.Network {
			return fmt.Errorf("%s requires --network", name)
		}
	}
	return nil
}

func Run(ctx context.Context, opts Options) Report {
	r := newRunner(opts)
	return r.run(ctx)
}

func newRunner(opts Options) *runner {
	root := opts.Root
	if root == "" {
		root = os.Getenv("KVS_INSTALL_DIR")
	}
	if root == "" {
		root = instance.DefaultRoot
	}
	if abs, err := filepath.Abs(root); err == nil {
		root = abs
	}
	return &runner{
		opts: opts, inst: &instance.Instance{Root: root, DockerDir: filepath.Join(root, "docker"), EnvPath: filepath.Join(root, "docker", ".env")},
		ready: map[string]bool{}, now: time.Now(),
		probe: probes{
			engine: func() (engine, error) { return dockerx.New() }, compose: dockerx.ReadProject,
			version: dockerx.DiagnosticComposeVersion, exec: dockerx.Probe, space: diskspace.Measure,
			client: &http.Client{Timeout: opts.Timeout, CheckRedirect: func(*http.Request, []*http.Request) error { return http.ErrUseLastResponse }},
		},
	}
}

func (r *runner) run(ctx context.Context) Report {
	report := Report{SchemaVersion: 1, Root: r.inst.Root, Network: r.opts.Network, Complete: true, Started: r.now.UTC(), Checks: []Result{}}
	defer func() {
		if r.docker != nil {
			_ = r.docker.Close()
		}
	}()
	selected := r.selected()
	for _, check := range Catalog() {
		if !selected[check.ID] {
			continue
		}
		start := time.Now()
		var result Result
		switch {
		case ctx.Err() != nil:
			result = skipped("Diagnostic interrupted", true)
		case check.Group == "network" && !r.opts.Network:
			result = skipped("External network checks are disabled; use --network", false)
		default:
			var missing []string
			for _, id := range check.Requires {
				if !r.ready[id] {
					missing = append(missing, id)
				}
			}
			if len(missing) > 0 {
				result = skipped("Requires a successful "+strings.Join(missing, ", ")+" check", true)
			} else {
				checkCtx, cancel := context.WithTimeout(ctx, r.opts.Timeout)
				result = r.check(checkCtx, check.ID)
				if checkCtx.Err() != nil {
					result = failure("Check interrupted or timed out", "Rerun this check with --verbose and a longer --timeout if needed")
					result.Incomplete = true
				}
				cancel()
			}
		}
		result.ID, result.Group, result.DurationMS = check.ID, check.Group, time.Since(start).Milliseconds()
		r.ready[check.ID] = result.ready
		report.Checks = append(report.Checks, result)
		if result.Incomplete {
			report.Complete = false
		}
		switch result.Status {
		case OK:
			report.Summary.Passed++
		case Warn:
			report.Summary.Warnings++
		case Fail:
			report.Summary.Failed++
		case Skip:
			report.Summary.Skipped++
		}
	}
	if validDomain(r.inst.Domain()) {
		report.Site = r.inst.Domain()
	}
	report.DurationMS = time.Since(r.now).Milliseconds()
	if report.Summary.Failed > 0 || !report.Complete || (r.opts.Strict && report.Summary.Warnings > 0) {
		report.ExitCode = 1
	}
	return report
}

func (r *runner) selected() map[string]bool {
	selected := map[string]bool{}
	catalog := Catalog()
	var add func(Check)
	add = func(c Check) {
		if selected[c.ID] {
			return
		}
		selected[c.ID] = true
		for _, id := range c.Requires {
			for _, dependency := range catalog {
				if dependency.ID == id {
					add(dependency)
				}
			}
		}
	}
	for _, c := range catalog {
		if len(r.opts.Only) == 0 || slices.Contains(r.opts.Only, c.ID) || slices.Contains(r.opts.Only, c.Group) {
			add(c)
		}
	}
	return selected
}

func good(message string, details ...string) Result {
	return Result{Status: OK, Message: message, Details: details, ready: true}
}

func warning(message, next string, details ...string) Result {
	return Result{Status: Warn, Message: message, Next: next, Details: details, ready: true}
}

func failure(message, next string, details ...string) Result {
	return Result{Status: Fail, Message: message, Next: next, Details: details}
}

func skipped(message string, incomplete bool) Result {
	return Result{Status: Skip, Message: message, Incomplete: incomplete}
}

// command preserves the selected installation in every suggested kvsctl action.
func (r *runner) command(command string) string {
	return "kvsctl " + command + " --root '" + strings.ReplaceAll(r.inst.Root, "'", "'\\''") + "'"
}

func (r *runner) check(ctx context.Context, id string) Result {
	switch id {
	case "config.files":
		return r.filesPresent()
	case "config.env":
		return r.readEnv()
	case "config.settings":
		return r.settings()
	case "docker.compose":
		return r.composeVersion(ctx)
	case "config.compose":
		return r.compose(ctx)
	case "state.record":
		return r.record()
	case "state.operation":
		return r.operation()
	case "docker.engine":
		return r.engine(ctx)
	case "services":
		return r.services(ctx)
	case "php":
		return r.phpRuntime(ctx)
	case "tools":
		return r.tools(ctx)
	case "database":
		return r.database(ctx)
	case "cache":
		return r.cache(ctx)
	case "search":
		return r.search(ctx)
	case "cron":
		return r.cron(ctx)
	case "storage.installation":
		return r.storageInstallation(ctx)
	case "storage.data":
		return r.storageData(ctx)
	case "backups":
		return r.backups(ctx)
	case "files":
		return r.files(ctx)
	case "images":
		return r.images(ctx)
	case "http":
		return r.http(ctx)
	case "tls":
		return r.tls(ctx)
	case "network.dns":
		return r.dns(ctx)
	case "network.https":
		return r.publicHTTPS(ctx)
	case "network.registries":
		return r.registries(ctx)
	default:
		return failure("Unknown diagnostic", "")
	}
}
