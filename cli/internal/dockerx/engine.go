package dockerx

import (
	"context"
	"fmt"
	"strings"

	"github.com/moby/moby/client"
)

// EngineInfo is what kvsctl needs to know about the Docker engine.
type EngineInfo struct {
	// Architecture is the machine the engine runs on, as it reports it:
	// x86_64, aarch64.
	Architecture string
	// OSType is linux on every engine kvsctl supports.
	OSType string
	// RootDir is where the engine keeps its images and volumes.
	RootDir string
	// Version is the version of the engine.
	Version string
}

// AMD64 reports whether the engine runs on x86_64, the only platform the
// release images are built for.
func (e EngineInfo) AMD64() bool {
	return e.Architecture == "x86_64" || e.Architecture == "amd64"
}

// Info asks the engine what it runs on.
func (c *Client) Info(ctx context.Context) (EngineInfo, error) {
	result, err := c.api.Info(ctx, client.InfoOptions{})
	if err != nil {
		return EngineInfo{}, err
	}
	info := result.Info
	return EngineInfo{Architecture: info.Architecture, OSType: info.OSType, RootDir: info.DockerRootDir, Version: info.ServerVersion}, nil
}

// VolumeMountpoint is the directory of the host that holds a volume, which
// is where its free space is measured.
func (c *Client) VolumeMountpoint(ctx context.Context, name string) (string, error) {
	result, err := c.api.VolumeInspect(ctx, name, client.VolumeInspectOptions{})
	if err != nil {
		return "", err
	}
	if result.Volume.Mountpoint == "" {
		return "", fmt.Errorf("volume %s has no mountpoint", name)
	}
	return result.Volume.Mountpoint, nil
}

// MountSource is the directory of the host mounted at destination in a
// container, a volume or a bind mount alike. It finds the data directory of
// a database without guessing the name compose gave its volume.
func (c *Client) MountSource(ctx context.Context, container, destination string) (string, error) {
	details, err := c.api.ContainerInspect(ctx, container, client.ContainerInspectOptions{})
	if err != nil {
		return "", err
	}
	for _, m := range details.Container.Mounts {
		if m.Destination == destination && m.Source != "" {
			return m.Source, nil
		}
	}
	return "", fmt.Errorf("nothing of the host is mounted at %s in %s", destination, container)
}

// MariaDBVersion is the MariaDB server version a container runs, read from
// the environment of the image it was created from: the official images set
// MARIADB_VERSION=1:11.8.9+maria~ubu2404, which gives 11.8.9. That image is
// the one the container runs, whatever its tag points at today, and the
// environment of the container itself may carry the stack's own
// MARIADB_VERSION instead. "" and no error when the image says nothing.
func (c *Client) MariaDBVersion(ctx context.Context, container string) (string, error) {
	details, err := c.api.ContainerInspect(ctx, container, client.ContainerInspectOptions{})
	if err != nil {
		return "", err
	}
	if details.Container.Image == "" {
		return "", fmt.Errorf("the engine names no image for %s", container)
	}
	img, err := c.api.ImageInspect(ctx, details.Container.Image)
	if err != nil {
		return "", err
	}
	if img.Config == nil {
		return "", nil
	}
	for _, entry := range img.Config.Env {
		if value, ok := strings.CutPrefix(entry, "MARIADB_VERSION="); ok {
			return mariadbVersion(value), nil
		}
	}
	return "", nil
}

// mariadbVersion reads the upstream version out of a Debian package
// version: the epoch before the colon and the build after a + or a ~ go,
// so 1:11.8.9+maria~ubu2404 gives 11.8.9. Anything that is not then a
// dotted version gives "", an unknown version.
func mariadbVersion(pkg string) string {
	if _, rest, found := strings.Cut(pkg, ":"); found {
		pkg = rest
	}
	if i := strings.IndexAny(pkg, "+~-"); i >= 0 {
		pkg = pkg[:i]
	}
	parts := strings.Split(pkg, ".")
	if len(parts) < 2 {
		return ""
	}
	for _, part := range parts {
		if part == "" || strings.Trim(part, "0123456789") != "" {
			return ""
		}
	}
	return pkg
}
