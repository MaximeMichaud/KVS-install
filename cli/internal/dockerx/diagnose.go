package dockerx

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"os/exec"
	"strconv"
	"syscall"
	"time"

	"github.com/moby/moby/client"
)

// ProjectConfig is the resolved, active Compose configuration. Environment
// values may contain credentials and must never be printed as diagnostics.
type ProjectConfig struct {
	Name     string                   `json:"name"`
	Services map[string]ServiceConfig `json:"services"`
}

type ServiceConfig struct {
	Image       string            `json:"image"`
	Environment map[string]string `json:"environment"`
	Ports       []PublishedPort   `json:"ports"`
}

type PublishedPort struct {
	HostIP    string `json:"host_ip"`
	Target    int    `json:"target"`
	Published string `json:"published"`
	Protocol  string `json:"protocol"`
}

// PublishedPorts reads the bindings of an existing container, so doctor does
// not accidentally probe a different service after .env was edited.
func (c *Client) PublishedPorts(ctx context.Context, name string) ([]PublishedPort, error) {
	result, err := c.api.ContainerInspect(ctx, name, client.ContainerInspectOptions{})
	if err != nil {
		return nil, err
	}
	var ports []PublishedPort
	if settings := result.Container.NetworkSettings; settings != nil {
		for port, bindings := range settings.Ports {
			for _, binding := range bindings {
				host := ""
				if binding.HostIP.IsValid() {
					host = binding.HostIP.String()
				}
				ports = append(ports, PublishedPort{HostIP: host, Target: int(port.Num()), Published: binding.HostPort, Protocol: string(port.Proto())})
			}
		}
	}
	return ports, nil
}

// ReadProject reads overrides and profiles with exactly the same environment
// isolation as other kvsctl Compose commands. It neither starts nor pulls a
// service. Unlike a mutation, a diagnostic child can be killed at its deadline.
func ReadProject(ctx context.Context, dir string) (*ProjectConfig, error) {
	cmd := diagnosticCommand(ctx, "compose", "config", "--format", "json")
	cmd.Dir, cmd.Env = dir, composeEnv(dir)
	out, err := diagnosticOutput(cmd)
	if err != nil {
		return nil, err
	}
	var project ProjectConfig
	if err := json.Unmarshal(out, &project); err != nil {
		return nil, errors.New("Compose returned invalid configuration JSON")
	}
	if project.Name == "" || len(project.Services) == 0 {
		return nil, errors.New("Compose returned no project name or active services")
	}
	return &project, nil
}

// Probe runs a bounded diagnostic inside an existing container. Callers supply
// fixed, read-only commands; application settings and credentials go on stdin,
// never in command arguments. Output is capped and is not included in errors.
func Probe(ctx context.Context, container string, stdin io.Reader, args ...string) ([]byte, error) {
	if err := ctx.Err(); err != nil {
		return nil, err
	}
	if deadline, ok := ctx.Deadline(); ok {
		// Killing the Docker CLI alone does not end its exec process inside
		// the container. Both GNU and BusyBox timeout support these options.
		seconds := strconv.FormatFloat(max(time.Until(deadline).Seconds(), 0.001), 'f', 3, 64)
		args = append([]string{"timeout", "-s", "KILL", seconds}, args...)
	}
	cmd := diagnosticCommand(ctx, append([]string{"exec", "-i", container}, args...)...)
	cmd.Stdin = stdin
	return diagnosticOutput(cmd)
}

func DiagnosticComposeVersion(ctx context.Context) (string, error) {
	cmd := diagnosticCommand(ctx, "compose", "version", "--short")
	cmd.Env = composeEnv("")
	out, err := diagnosticOutput(cmd)
	return string(bytes.TrimSpace(bytes.TrimPrefix(out, []byte("v")))), err
}

func diagnosticCommand(ctx context.Context, args ...string) *exec.Cmd {
	cmd := command(ctx, "docker", args...).Cmd
	cmd.Cancel = func() error { return syscall.Kill(-cmd.Process.Pid, syscall.SIGKILL) }
	cmd.WaitDelay = time.Second
	return cmd
}

type cappedOutput struct {
	bytes.Buffer
	limit int
}

func (w *cappedOutput) Write(p []byte) (int, error) {
	if len(p) > w.limit-w.Len() {
		return 0, errors.New("diagnostic output exceeds its size limit")
	}
	return w.Buffer.Write(p)
}

func diagnosticOutput(cmd *exec.Cmd) ([]byte, error) {
	out := &cappedOutput{limit: 8 << 20}
	cmd.Stdout, cmd.Stderr = out, io.Discard
	if err := cmd.Run(); err != nil {
		// Compose errors can quote .env values or the interpolated YAML.
		// Never copy that output into a report, including verbose reports.
		return nil, fmt.Errorf("diagnostic command: %w", err)
	}
	return out.Bytes(), nil
}
