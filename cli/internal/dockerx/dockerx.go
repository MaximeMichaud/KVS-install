// Package dockerx drives the Docker engine: image pulls with progress,
// container states and compose commands of the instance.
package dockerx

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"maps"
	"os"
	"path/filepath"
	"slices"
	"sort"
	"strings"
	"sync"
	"time"

	cerrdefs "github.com/containerd/errdefs"
	"github.com/moby/moby/api/types/container"
	"github.com/moby/moby/client"

	"github.com/MaximeMichaud/KVS-install/cli/internal/dotenv"
)

// Client wraps the engine API.
type Client struct {
	api *client.Client
	// context names the docker context the engine was found through, ""
	// when none was.
	context string
	// auth keeps the credentials read for each registry during this run,
	// so a credential helper is asked once and not once per image.
	authMu sync.Mutex
	auth   map[string]credentials
}

// New connects to the engine the docker CLI of the machine uses: the one
// DOCKER_HOST names, else the one of the docker context in use (see
// resolveEndpoint), else the local socket. The client negotiates the API
// version with the engine on its first request, unless DOCKER_API_VERSION
// sets one.
func New() (*Client, error) {
	ep, err := resolveEndpoint()
	if err != nil {
		return nil, err
	}
	opts := []client.Opt{client.FromEnv}
	if ep.host != "" {
		opts = []client.Opt{client.WithHost(ep.host), client.WithAPIVersionFromEnv()}
	}
	api, err := client.New(opts...)
	if err != nil {
		return nil, err
	}
	return &Client{api: api, context: ep.context}, nil
}

// Endpoint names the engine the client talks to, for a message: its
// address, and the docker context it comes from when one does.
func (c *Client) Endpoint() string {
	if c.context != "" {
		return fmt.Sprintf("%s, from the docker context %s", c.api.DaemonHost(), c.context)
	}
	return c.api.DaemonHost()
}

// Close releases the connection.
func (c *Client) Close() error { return c.api.Close() }

// Ping checks the engine answers.
func (c *Client) Ping(ctx context.Context) error {
	_, err := c.api.Ping(ctx, client.PingOptions{})
	return err
}

// Progress reports the bytes downloaded so far and the bytes expected.
type Progress struct {
	Current, Total int64
	// Done is set once the image is fully pulled.
	Done bool
}

type pullMessage struct {
	Status         string `json:"status"`
	ID             string `json:"id"`
	Error          string `json:"error"`
	ProgressDetail struct {
		Current int64 `json:"current"`
		Total   int64 `json:"total"`
	} `json:"progressDetail"`
}

// Pull downloads the image a release pins, by its digest: the repository
// of ref at digest, the tag dropped and the registry kept. The registry may
// have moved the tag since the release was signed, while the digest names
// the bytes the release vouches for. The image must then carry that
// digest, and it is tagged as ref, the name an operator reads in "docker
// images". expectedTotal, when known from the manifest, gives the bars
// their size before the first layer answers.
//
// Credentials come from the Docker CLI configuration of the user running
// kvsctl, so a "docker login" on the machine counts; without any, or when
// they cannot be read, the pull is anonymous.
func (c *Client) Pull(ctx context.Context, ref, digest string, expectedTotal int64, report func(Progress)) error {
	pinned, err := PinnedRef(ref, digest)
	if err != nil {
		return err
	}
	creds := c.credentials(ctx, ref)
	body, err := c.api.ImagePull(ctx, pinned, client.ImagePullOptions{RegistryAuth: creds.header})
	if err != nil {
		return pullError(pinned, err, creds)
	}
	defer body.Close()
	if err := readPull(body, expectedTotal, report); err != nil {
		return pullError(pinned, err, creds)
	}
	has, err := c.HasDigest(ctx, ref, digest)
	if err != nil {
		return fmt.Errorf("inspect %s: %w", pinned, err)
	}
	if !has {
		return fmt.Errorf("%s was pulled but does not carry the digest the manifest lists (%s)", pinned, digest)
	}
	if refTag(ref) == "" {
		return nil
	}
	if _, err := c.api.ImageTag(ctx, client.ImageTagOptions{Source: pinned, Target: RefName(ref) + ":" + refTag(ref)}); err != nil {
		return fmt.Errorf("tag %s as %s: %w", pinned, ref, err)
	}
	return nil
}

// credentials reads the credentials of the registry of ref once per run.
func (c *Client) credentials(ctx context.Context, ref string) credentials {
	key := registryKey(ref)
	c.authMu.Lock()
	defer c.authMu.Unlock()
	if found, ok := c.auth[key]; ok {
		return found
	}
	found := registryCredentials(ctx, ref)
	if c.auth == nil {
		c.auth = map[string]credentials{}
	}
	c.auth[key] = found
	return found
}

// pullError says which reference failed and, when credentials were used or
// could not be read, which: an "unauthorized" is read differently once the
// operator knows the pull was anonymous.
func pullError(pinned string, err error, creds credentials) error {
	if creds.note == "" {
		return fmt.Errorf("pull %s: %w", pinned, err)
	}
	return fmt.Errorf("pull %s (%s): %w", pinned, creds.note, err)
}

// readPull follows the JSON stream of a pull and reports the bytes of every
// layer added up.
func readPull(body io.Reader, expectedTotal int64, report func(Progress)) error {
	type layer struct{ current, total int64 }
	layers := map[string]*layer{}
	dec := json.NewDecoder(body)
	emit := func(done bool) {
		if report == nil {
			return
		}
		var p Progress
		for _, l := range layers {
			p.Current += l.current
			p.Total += l.total
		}
		if expectedTotal > 0 {
			p.Total = expectedTotal
			if p.Current > p.Total {
				p.Current = p.Total
			}
		}
		if done {
			p.Current = p.Total
		}
		p.Done = done
		report(p)
	}
	for {
		var m pullMessage
		if err := dec.Decode(&m); err != nil {
			if errors.Is(err, io.EOF) {
				break
			}
			return err
		}
		if m.Error != "" {
			return errors.New(m.Error)
		}
		if m.ID == "" {
			continue
		}
		l := layers[m.ID]
		if l == nil {
			l = &layer{}
			layers[m.ID] = l
		}
		switch m.Status {
		case "Downloading":
			l.current, l.total = m.ProgressDetail.Current, m.ProgressDetail.Total
		case "Download complete", "Pull complete", "Already exists":
			if l.total == 0 {
				l.total = m.ProgressDetail.Total
			}
			l.current = l.total
		}
		emit(false)
	}
	emit(true)
	return nil
}

// LocalDiffIDs lists the diff IDs of every layer the engine holds, which
// tells how much of an image is still to download.
func (c *Client) LocalDiffIDs(ctx context.Context) (map[string]bool, error) {
	images, err := c.api.ImageList(ctx, client.ImageListOptions{All: true})
	if err != nil {
		return nil, err
	}
	local := map[string]bool{}
	for _, img := range images.Items {
		inspect, err := c.api.ImageInspect(ctx, img.ID)
		if err != nil {
			continue
		}
		for _, diff := range inspect.RootFS.Layers {
			local[diff] = true
		}
	}
	return local, nil
}

// Digests returns the repository digests of a local image.
func (c *Client) Digests(ctx context.Context, ref string) ([]string, error) {
	inspect, err := c.api.ImageInspect(ctx, ref)
	if err != nil {
		return nil, err
	}
	return inspect.RepoDigests, nil
}

// HasDigest reports whether the engine holds the image of ref at digest. It
// looks the image up as repository@digest, so an image pulled under another
// tag of the same repository counts, and a tag that moved since does not
// matter. An image the engine does not hold is false, not an error.
func (c *Client) HasDigest(ctx context.Context, ref, digest string) (bool, error) {
	pinned, err := PinnedRef(ref, digest)
	if err != nil {
		return false, err
	}
	digests, err := c.Digests(ctx, pinned)
	if cerrdefs.IsNotFound(err) {
		return false, nil
	}
	if err != nil {
		return false, err
	}
	for _, d := range digests {
		if strings.HasSuffix(d, "@"+digest) {
			return true, nil
		}
	}
	return false, nil
}

// ContainerState is the state of one container of the project.
type ContainerState struct {
	// ID tells a container from the one that replaced it under the same
	// name, which is how a recreated service is recognised.
	ID      string
	Name    string
	Service string
	State   string
	Health  string
	Exit    int
	OneShot bool
	// Restarts is how many times the engine restarted the container.
	Restarts int
	// Started is when the current process started.
	Started time.Time
	// The timing of the health check of the container, as its
	// configuration declares it; zero for what it leaves to Docker's
	// defaults, and for a container without a health check.
	HealthStartPeriod time.Duration
	HealthInterval    time.Duration
	HealthTimeout     time.Duration
	HealthRetries     int
}

// Docker's health check defaults, for the fields a check leaves at zero.
const (
	defaultHealthInterval = 30 * time.Second
	defaultHealthTimeout  = 30 * time.Second
	defaultHealthRetries  = 3
	// healthSlack is added to the window of a check, for the engine to
	// record the result that settles it.
	healthSlack = 30 * time.Second
)

// HealthWindow is how long after its start a container may report
// "starting" before its own health check settles one way or the other:
// the start period, then retries + 1 intervals and one timeout, plus 30
// seconds. Docker's defaults stand in for what the check leaves unset (an
// interval and a timeout of 30 s, 3 retries, no start period). A service
// whose first answer is minutes away declares a start period that long,
// and this is what lets it take it.
func (s ContainerState) HealthWindow() time.Duration {
	interval, timeout, retries := s.HealthInterval, s.HealthTimeout, s.HealthRetries
	if interval <= 0 {
		interval = defaultHealthInterval
	}
	if timeout <= 0 {
		timeout = defaultHealthTimeout
	}
	if retries <= 0 {
		retries = defaultHealthRetries
	}
	return s.HealthStartPeriod + interval*time.Duration(retries+1) + timeout + healthSlack
}

// ServiceImage is the image one service of a project runs, as the engine
// holds it: the reference the service was configured with, the image behind
// that reference and the digests it was pulled under.
type ServiceImage struct {
	Service, Container, Image, ImageID string
	Digests                            []string
	State, Health                      string
}

// projectContainer is one container of a project with the labels compose
// filtered it by, the pass Containers and ServiceImages both read.
type projectContainer struct {
	labels  map[string]string
	details container.InspectResponse
}

func (p projectContainer) name() string { return strings.TrimPrefix(p.details.Name, "/") }

func (p projectContainer) service() string { return p.labels["com.docker.compose.service"] }

func (p projectContainer) oneShot() bool { return p.labels["com.docker.compose.oneoff"] == "True" }

// state reads what Containers reports of one container.
func (p projectContainer) state() ContainerState {
	inspect := p.details
	s := ContainerState{
		ID:       inspect.ID,
		Name:     p.name(),
		Service:  p.service(),
		OneShot:  p.oneShot(),
		Restarts: inspect.RestartCount,
	}
	if st := inspect.State; st != nil {
		s.State, s.Exit = string(st.Status), st.ExitCode
		if started, err := time.Parse(time.RFC3339Nano, st.StartedAt); err == nil {
			s.Started = started
		}
		if st.Health != nil {
			s.Health = string(st.Health.Status)
		}
	}
	if inspect.Config != nil {
		if hc := inspect.Config.Healthcheck; hc != nil && !(len(hc.Test) > 0 && hc.Test[0] == "NONE") {
			s.HealthStartPeriod, s.HealthInterval = hc.StartPeriod, hc.Interval
			s.HealthTimeout, s.HealthRetries = hc.Timeout, hc.Retries
		}
	}
	return s
}

// projectContainers lists and inspects the containers of a compose project,
// in container name order.
func (c *Client) projectContainers(ctx context.Context, project string) ([]projectContainer, error) {
	args := make(client.Filters).Add("label", "com.docker.compose.project="+project)
	list, err := c.api.ContainerList(ctx, client.ContainerListOptions{All: true, Filters: args})
	if err != nil {
		return nil, err
	}
	out := make([]projectContainer, 0, len(list.Items))
	for _, item := range list.Items {
		details, err := c.api.ContainerInspect(ctx, item.ID, client.ContainerInspectOptions{})
		if err != nil {
			return nil, err
		}
		out = append(out, projectContainer{labels: item.Labels, details: details.Container})
	}
	sort.Slice(out, func(i, j int) bool { return out[i].name() < out[j].name() })
	return out, nil
}

// Containers lists the containers of a compose project.
func (c *Client) Containers(ctx context.Context, project string) ([]ContainerState, error) {
	list, err := c.projectContainers(ctx, project)
	if err != nil {
		return nil, err
	}
	var out []ContainerState
	for _, item := range list {
		out = append(out, item.state())
	}
	return out, nil
}

// Container inspects one container by name or ID: what a caller compares
// before and after compose ran, to tell whether it was recreated.
func (c *Client) Container(ctx context.Context, name string) (ContainerState, error) {
	inspected, err := c.api.ContainerInspect(ctx, name, client.ContainerInspectOptions{})
	if err != nil {
		return ContainerState{}, err
	}
	details := inspected.Container
	var labels map[string]string
	if details.Config != nil {
		labels = details.Config.Labels
	}
	return projectContainer{labels: labels, details: details}.state(), nil
}

// ServiceImages reports the image every service of the project runs, one
// entry per service, which is what the per-service table of check and
// status compares with the images of a release. Containers of a one-off
// docker compose run are skipped, and so is a second container of a service
// a scale left behind.
func (c *Client) ServiceImages(ctx context.Context, project string) (map[string]ServiceImage, error) {
	list, err := c.projectContainers(ctx, project)
	if err != nil {
		return nil, err
	}
	out := map[string]ServiceImage{}
	for _, item := range list {
		service := item.service()
		if service == "" || item.oneShot() {
			continue
		}
		if _, seen := out[service]; seen {
			continue
		}
		inspect := item.details
		state := item.state()
		found := ServiceImage{
			Service:   service,
			Container: item.name(),
			ImageID:   inspect.Image,
			State:     state.State,
			Health:    state.Health,
		}
		if inspect.Config != nil {
			found.Image = inspect.Config.Image
		}
		if img, err := c.api.ImageInspect(ctx, inspect.Image); err == nil {
			found.Digests = img.RepoDigests
		}
		out[service] = found
	}
	return out, nil
}

// settleTime is how long a container that restarted must stay up before
// it counts as healthy again.
const settleTime = 10 * time.Second

// crashLoopRestarts is the number of restarts since the baseline that makes
// a container a crash loop, which ends a wait at once.
const crashLoopRestarts = 3

// Problems lists what keeps the project from being healthy, ignoring
// one-shot and init containers: containers not running, health checks not
// passing, and containers that restarted since the baseline (restart counts
// taken when the wait began) and have not stayed up for settleTime yet.
// crashLoop reports a container that keeps restarting.
func Problems(states []ContainerState, baseline map[string]int, now time.Time) (problems []string, crashLoop bool) {
	for _, s := range states {
		if s.OneShot || strings.HasSuffix(s.Service, "-init") {
			continue
		}
		restarts := s.Restarts - baseline[s.Name]
		up := now.Sub(s.Started)
		switch {
		case s.State != "running":
			problems = append(problems, fmt.Sprintf("%s is %s (exit %d)", s.Name, s.State, s.Exit))
		case s.Health != "" && s.Health != "healthy":
			problems = append(problems, fmt.Sprintf("%s is %s", s.Name, s.Health))
		case restarts > 0 && up < settleTime:
			problems = append(problems, fmt.Sprintf("%s restarted %d times, up for %s", s.Name, restarts, up.Round(time.Second)))
		}
		if restarts >= crashLoopRestarts && (s.State != "running" || up < settleTime) {
			crashLoop = true
		}
	}
	return problems, crashLoop
}

// ByService finds the container of one service, nil when the project runs
// none, which is how a caller budgets a wait per service.
func ByService(states []ContainerState, service string) *ContainerState {
	for n := range states {
		if states[n].Service == service {
			return &states[n]
		}
	}
	return nil
}

// composeEnv is the environment of a compose command run on the project in
// dir: the one kvsctl runs in, without the keys kvsctl owns and those the
// .env of the project or the .env.example of its release give a value
// (dotenv.Isolate). A shell that sourced an older .env, which is what the
// scripts do, exports all of them, and compose prefers an inherited value
// to the file: compose must take each from the file, as kvsctl reads it.
// PWD names dir as given, which is how compose, like the shell of the
// scripts, keeps an installation reached through a link under the name it
// was reached by: the bind mounts compose records, and the project it
// recognises, then do not change with the way kvsctl was started. An empty
// dir is a command on no project.
func composeEnv(dir string) []string {
	var env, example []byte
	if dir != "" {
		env, _ = os.ReadFile(filepath.Join(dir, ".env"))
		example, _ = os.ReadFile(filepath.Join(dir, ".env.example"))
	}
	out := dotenv.Isolate(os.Environ(), env, example)
	if dir != "" {
		if abs, err := filepath.Abs(dir); err == nil {
			out = slices.DeleteFunc(out, func(entry string) bool { return strings.HasPrefix(entry, "PWD=") })
			out = append(out, "PWD="+abs)
		}
	}
	return append(out, "COMPOSE_PROGRESS=plain")
}

// ComposeVersion is the version of the compose plugin, "2.29.7" without
// the v, which a release names a minimum of.
func ComposeVersion(ctx context.Context) (string, error) {
	cmd := command(ctx, "docker", "compose", "version", "--short")
	cmd.Env = composeEnv("")
	out, err := cmd.Output()
	if err != nil {
		return "", fmt.Errorf("docker compose version: %w", err)
	}
	return strings.TrimPrefix(strings.TrimSpace(string(out)), "v"), nil
}

// Compose runs docker compose in the project directory; the .env there
// supplies COMPOSE_FILE and COMPOSE_PROFILES exactly as the setup does.
// Output lines go to the sink as they arrive.
func Compose(ctx context.Context, dir string, sink func(string), args ...string) error {
	_, err := ComposeStarted(ctx, dir, sink, args...)
	return err
}

// ComposeStarted is Compose, and also reports whether the compose process
// started at all. A context that had already ended, or a docker binary that
// cannot be run, leaves started false: compose never saw the project, which
// a rollback must know to leave the containers alone. Once started is true,
// any part of the command may have run, whatever the error.
func ComposeStarted(ctx context.Context, dir string, sink func(string), args ...string) (started bool, err error) {
	what := "docker compose " + strings.Join(args, " ")
	cmd := command(ctx, "docker", append([]string{"compose"}, args...)...)
	cmd.Dir = dir
	cmd.Env = composeEnv(dir)
	// One writer for both streams: the lines keep the order compose wrote
	// them in, and the pipes are closed by WaitDelay should a child of
	// compose keep them open after it was stopped.
	out := &lineWriter{sink: sink}
	cmd.Stdout, cmd.Stderr = out, out
	if err := cmd.Start(); err != nil {
		return false, fmt.Errorf("%s: %w", what, err)
	}
	err = cmd.Wait()
	out.flush()
	if err == nil {
		return true, nil
	}
	if ctxErr := context.Cause(ctx); ctxErr != nil {
		return true, fmt.Errorf("%s: %w (%v)%s", what, ctxErr, err, out.said())
	}
	return true, fmt.Errorf("%s: %w%s", what, err, out.said())
}

// ActiveServices lists, sorted, the services compose runs in the project
// directory: the services of the files COMPOSE_FILE names whose profiles
// COMPOSE_PROFILES turns on, both read from the .env there. A container of
// any other service, from a profile that is off or a service a release
// removed, is a leftover and not part of the stack.
func ActiveServices(ctx context.Context, dir string) ([]string, error) {
	out, err := composeConfig(ctx, dir, "config", "--services")
	if err != nil {
		return nil, err
	}
	return serviceList(out, "in "+dir)
}

// ServicesOf lists, sorted, the services compose runs from the compose
// file compose, given whole on its stdin, with the settings of env in
// place of a .env: what ActiveServices lists for a project directory
// holding that file and that .env, read without writing either anywhere.
// The environment loses the keys kvsctl owns and the ones env sets, as for
// a project (composeEnv), and compose reads no other file.
func ServicesOf(ctx context.Context, compose []byte, env map[string]string) ([]string, error) {
	// /dev/stdin and not "-", which compose 2.30.0 opens as a file of the
	// working directory. The project is named, since the directory of the
	// file gives it no name, and no .env or other file of a directory is
	// read.
	cmd := command(ctx, "docker", "compose", "--project-name", "kvsctl-plan", "--file", "/dev/stdin", "--env-file", os.DevNull, "config", "--services")
	cmd.Dir = "/"
	environ := slices.DeleteFunc(dotenv.Isolate(os.Environ(), nil, nil), func(entry string) bool {
		key, _, _ := strings.Cut(entry, "=")
		_, set := env[key]
		return set || key == "PWD"
	})
	for _, key := range slices.Sorted(maps.Keys(env)) {
		environ = append(environ, key+"="+env[key])
	}
	cmd.Env = append(environ, "PWD=/", "COMPOSE_PROGRESS=plain")
	cmd.Stdin = bytes.NewReader(compose)
	var stdout bytes.Buffer
	stderr := &tailBuffer{max: 8 << 10}
	cmd.Stdout, cmd.Stderr = &stdout, stderr
	if err := cmd.Run(); err != nil {
		return nil, fmt.Errorf("docker compose config --services: %w%s", err, said(stderr))
	}
	return serviceList(stdout.String(), "in the compose file it was given")
}

// serviceList reads the services compose config --services printed,
// sorted; where says where compose looked, for the error of an empty list.
func serviceList(out, where string) ([]string, error) {
	var services []string
	for _, line := range strings.Split(out, "\n") {
		if line = strings.TrimSpace(line); line != "" {
			services = append(services, line)
		}
	}
	if len(services) == 0 {
		return nil, fmt.Errorf("docker compose config --services lists no service %s", where)
	}
	sort.Strings(services)
	return services, nil
}

// ComposeConfigCheck has compose read the project the way up would,
// without touching a container: an interpolation or YAML error in the
// files or the .env fails here, before anything changed.
func ComposeConfigCheck(ctx context.Context, dir string) error {
	_, err := composeConfig(ctx, dir, "config", "--quiet")
	return err
}

// composeConfig runs "docker compose" with args, a config command, and
// returns what it printed; a failure carries what compose said on stderr.
func composeConfig(ctx context.Context, dir string, args ...string) (string, error) {
	cmd := command(ctx, "docker", append([]string{"compose"}, args...)...)
	cmd.Dir = dir
	cmd.Env = composeEnv(dir)
	var stdout bytes.Buffer
	stderr := &tailBuffer{max: 8 << 10}
	cmd.Stdout, cmd.Stderr = &stdout, stderr
	if err := cmd.Run(); err != nil {
		return "", fmt.Errorf("docker compose %s: %w%s", strings.Join(args, " "), err, said(stderr))
	}
	return stdout.String(), nil
}

// said is what a failed command wrote on stderr, as the end of its error
// message: ": " and the text, or nothing when it wrote nothing but blanks.
func said(stderr *tailBuffer) string {
	if text := stderr.String(); text != "" {
		return ": " + text
	}
	return ""
}

// Exec runs a command inside a container, in a process group of its own
// like every docker child, and writes its stdout to stdout.
func Exec(ctx context.Context, name string, stdin io.Reader, stdout io.Writer, args ...string) error {
	cmd := command(ctx, "docker", append([]string{"exec", "-i", name}, args...)...)
	cmd.Stdin = stdin
	cmd.Stdout = stdout
	stderr := &tailBuffer{max: 8 << 10}
	cmd.Stderr = stderr
	if err := cmd.Run(); err != nil {
		if ctxErr := context.Cause(ctx); ctxErr != nil {
			return fmt.Errorf("docker exec %s: %w (%v)%s", name, ctxErr, err, said(stderr))
		}
		return fmt.Errorf("docker exec %s: %w%s", name, err, said(stderr))
	}
	return nil
}
