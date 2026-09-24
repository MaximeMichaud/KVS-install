// Package dockerx drives the Docker engine: image pulls with progress,
// container states and compose commands of the instance.
package dockerx

import (
	"bufio"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"os"
	"os/exec"
	"sort"
	"strings"
	"time"

	"github.com/docker/docker/api/types/container"
	"github.com/docker/docker/api/types/filters"
	"github.com/docker/docker/api/types/image"
	"github.com/docker/docker/client"
)

// Client wraps the engine API.
type Client struct {
	api *client.Client
}

// New connects to the local engine.
func New() (*Client, error) {
	api, err := client.NewClientWithOpts(client.FromEnv, client.WithAPIVersionNegotiation())
	if err != nil {
		return nil, err
	}
	return &Client{api: api}, nil
}

// Close releases the connection.
func (c *Client) Close() error { return c.api.Close() }

// Ping checks the engine answers.
func (c *Client) Ping(ctx context.Context) error {
	_, err := c.api.Ping(ctx)
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

// Pull downloads ref and reports progress. expectedTotal, when known from
// the manifest, gives the bars their size before the first layer answers.
func (c *Client) Pull(ctx context.Context, ref string, expectedTotal int64, report func(Progress)) error {
	body, err := c.api.ImagePull(ctx, ref, image.PullOptions{})
	if err != nil {
		return err
	}
	defer body.Close()
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
			return fmt.Errorf("pull %s: %w", ref, err)
		}
		if m.Error != "" {
			return fmt.Errorf("pull %s: %s", ref, m.Error)
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
	images, err := c.api.ImageList(ctx, image.ListOptions{All: true})
	if err != nil {
		return nil, err
	}
	local := map[string]bool{}
	for _, img := range images {
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

// Digest returns the repository digests of a local image.
func (c *Client) Digests(ctx context.Context, ref string) ([]string, error) {
	inspect, err := c.api.ImageInspect(ctx, ref)
	if err != nil {
		return nil, err
	}
	return inspect.RepoDigests, nil
}

// HasDigest reports whether the local image ref carries the wanted digest.
func (c *Client) HasDigest(ctx context.Context, ref, digest string) (bool, error) {
	digests, err := c.Digests(ctx, ref)
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

// projectContainers lists and inspects the containers of a compose project,
// in container name order.
func (c *Client) projectContainers(ctx context.Context, project string) ([]projectContainer, error) {
	args := filters.NewArgs(filters.Arg("label", "com.docker.compose.project="+project))
	list, err := c.api.ContainerList(ctx, container.ListOptions{All: true, Filters: args})
	if err != nil {
		return nil, err
	}
	out := make([]projectContainer, 0, len(list))
	for _, item := range list {
		details, err := c.api.ContainerInspect(ctx, item.ID)
		if err != nil {
			return nil, err
		}
		out = append(out, projectContainer{labels: item.Labels, details: details})
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
		inspect := item.details
		state := ContainerState{
			Name:     item.name(),
			Service:  item.service(),
			State:    inspect.State.Status,
			Exit:     inspect.State.ExitCode,
			OneShot:  item.oneShot(),
			Restarts: inspect.RestartCount,
		}
		if started, err := time.Parse(time.RFC3339Nano, inspect.State.StartedAt); err == nil {
			state.Started = started
		}
		if inspect.State.Health != nil {
			state.Health = inspect.State.Health.Status
		}
		out = append(out, state)
	}
	return out, nil
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
		found := ServiceImage{
			Service:   service,
			Container: item.name(),
			ImageID:   inspect.Image,
			State:     inspect.State.Status,
		}
		if inspect.Config != nil {
			found.Image = inspect.Config.Image
		}
		if inspect.State.Health != nil {
			found.Health = inspect.State.Health.Status
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

// composeOwnedByEnvFile are the keys the .env of the project owns. A shell
// that sourced an older .env, which is what docker/setup.sh does, exports
// them, and an inherited value wins over the file, so the child never sees
// them: the project the command acts on must come from the project.
var composeOwnedByEnvFile = map[string]bool{
	"COMPOSE_FILE":           true,
	"COMPOSE_PROFILES":       true,
	"COMPOSE_PROJECT_NAME":   true,
	"COMPOSE_PATH_SEPARATOR": true,
}

// composeEnv is the environment of a compose command: the one kvsctl runs
// in, without the keys the .env of the project owns.
func composeEnv() []string {
	inherited := os.Environ()
	env := make([]string, 0, len(inherited)+1)
	for _, entry := range inherited {
		key, _, _ := strings.Cut(entry, "=")
		if composeOwnedByEnvFile[key] {
			continue
		}
		env = append(env, entry)
	}
	return append(env, "COMPOSE_PROGRESS=plain")
}

// ComposeVersion is the version of the compose plugin, "2.29.7" without
// the v, which a release names a minimum of.
func ComposeVersion(ctx context.Context) (string, error) {
	cmd := exec.CommandContext(ctx, "docker", "compose", "version", "--short")
	cmd.Env = composeEnv()
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
	cmd := exec.CommandContext(ctx, "docker", append([]string{"compose"}, args...)...)
	cmd.Dir = dir
	cmd.Env = composeEnv()
	pipe, err := cmd.StdoutPipe()
	if err != nil {
		return err
	}
	cmd.Stderr = cmd.Stdout
	if err := cmd.Start(); err != nil {
		return fmt.Errorf("docker compose %s: %w", strings.Join(args, " "), err)
	}
	scanner := bufio.NewScanner(pipe)
	scanner.Buffer(make([]byte, 1<<20), 1<<20)
	var last []string
	for scanner.Scan() {
		line := scanner.Text()
		last = append(last, line)
		if len(last) > 20 {
			last = last[1:]
		}
		if sink != nil {
			sink(line)
		}
	}
	if err := cmd.Wait(); err != nil {
		return fmt.Errorf("docker compose %s: %w\n%s", strings.Join(args, " "), err, strings.Join(last, "\n"))
	}
	return nil
}

// Exec runs a command inside a container and returns its stdout.
func Exec(ctx context.Context, name string, stdin io.Reader, stdout io.Writer, args ...string) error {
	cmd := exec.CommandContext(ctx, "docker", append([]string{"exec", "-i", name}, args...)...)
	cmd.Stdin = stdin
	cmd.Stdout = stdout
	var stderr strings.Builder
	cmd.Stderr = &stderr
	if err := cmd.Run(); err != nil {
		return fmt.Errorf("docker exec %s: %w: %s", name, err, strings.TrimSpace(stderr.String()))
	}
	return nil
}
