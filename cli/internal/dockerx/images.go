package dockerx

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"slices"
	"sort"
	"strings"

	cerrdefs "github.com/containerd/errdefs"
	"github.com/moby/moby/api/types/image"
	"github.com/moby/moby/client"
)

// ErrImageInUse says a container still needs the image, so it stays. An
// upgrade keeps the previous version running until it is replaced, and
// forcing the removal would untag an image a running site depends on.
var ErrImageInUse = errors.New("the image is used by a container")

// RemoveImage deletes one image by reference. It never forces and never
// touches the children: only the exact tag goes, and an image a container
// still uses is reported as ErrImageInUse rather than removed.
func (c *Client) RemoveImage(ctx context.Context, ref string) error {
	_, err := c.api.ImageRemove(ctx, ref, client.ImageRemoveOptions{Force: false, PruneChildren: false})
	if err == nil {
		return nil
	}
	if inUse(err) {
		return fmt.Errorf("%s: %w", ref, ErrImageInUse)
	}
	return fmt.Errorf("remove %s: %w", ref, err)
}

// ImageRefs lists the name:tag of every image the engine holds. Untagged
// images have no reference to remove, so they are left out.
func (c *Client) ImageRefs(ctx context.Context) ([]string, error) {
	list, err := c.api.ImageList(ctx, client.ImageListOptions{})
	if err != nil {
		return nil, err
	}
	return refsOf(list.Items), nil
}

// ImageSize is the size the engine reports for an image, which is what a
// removal reclaims. It answers 0 and no error when the image is gone.
func (c *Client) ImageSize(ctx context.Context, ref string) (int64, error) {
	inspect, err := c.api.ImageInspect(ctx, ref)
	if cerrdefs.IsNotFound(err) {
		return 0, nil
	}
	if err != nil {
		return 0, err
	}
	return inspect.Size, nil
}

// refsOf collects the tags of a listing, sorted and without duplicates.
func refsOf(list []image.Summary) []string {
	seen := map[string]bool{}
	var refs []string
	for _, item := range list {
		for _, tag := range item.RepoTags {
			if tag == "" || strings.HasPrefix(tag, "<none>") || strings.HasSuffix(tag, ":<none>") || seen[tag] {
				continue
			}
			seen[tag] = true
			refs = append(refs, tag)
		}
	}
	sort.Strings(refs)
	return refs
}

// inUse recognises the engine's refusal to delete an image a container
// still references. The message is the only signal the API gives.
func inUse(err error) bool {
	msg := strings.ToLower(err.Error())
	return strings.Contains(msg, "is being used") ||
		strings.Contains(msg, "is using its referenced image") ||
		strings.Contains(msg, "conflict")
}

// ComposeImages lists the images of every service of the project in dir,
// as "docker compose config --images" prints them for the files its .env
// names, with every profile on: a service of a profile that is off, such as
// kvs-init of the setup profile, was built all the same, and its image is
// the project's too. Compose reads --profile '*' that way from 2.19.0, the
// oldest a release supports. A service compose only builds is named
// <project>-<service>, which compose tags latest: it is listed as
// <project>-<service>:latest, the name the engine holds it under.
func ComposeImages(ctx context.Context, dir string) ([]string, error) {
	out, err := composeConfig(ctx, dir, "--profile", "*", "config", "--images")
	if err != nil {
		return nil, err
	}
	var refs []string
	for _, line := range strings.Split(out, "\n") {
		ref := strings.TrimSpace(line)
		if ref == "" {
			continue
		}
		if !strings.Contains(ref, "@") && refTag(ref) == "" {
			ref += ":latest"
		}
		refs = append(refs, ref)
	}
	sort.Strings(refs)
	return slices.Compact(refs), nil
}

// ComposeProject is the name of the compose project in dir, the one
// compose labels the containers it runs and the images it builds with.
func ComposeProject(ctx context.Context, dir string) (string, error) {
	out, err := composeConfig(ctx, dir, "config", "--format=json")
	if err != nil {
		return "", err
	}
	var project struct {
		Name string `json:"name"`
	}
	if err := json.Unmarshal([]byte(out), &project); err != nil {
		return "", fmt.Errorf("docker compose config --format=json: %w", err)
	}
	if project.Name == "" {
		return "", fmt.Errorf("docker compose config names no project in %s", dir)
	}
	return project.Name, nil
}

// composeProjectLabel is the label compose gives the containers and the
// images of a project.
const composeProjectLabel = "com.docker.compose.project"

// BuiltLocally keeps, of refs, the images the engine holds that compose
// built for project on the machine. Compose labels an image it builds with
// its project, which both image stores keep; a repository digest tells
// nothing on the containerd store, the default of Docker 29, which gives
// one to a built image too. An image with no label and no repository
// digest, which an older compose leaves on the classic store, was never
// pulled nor pushed, and counts as built here. An image the engine does
// not hold is left out.
func (c *Client) BuiltLocally(ctx context.Context, project string, refs []string) ([]string, error) {
	var built []string
	for _, ref := range refs {
		inspect, err := c.api.ImageInspect(ctx, ref)
		if cerrdefs.IsNotFound(err) {
			continue
		}
		if err != nil {
			return nil, err
		}
		var labels map[string]string
		if inspect.Config != nil {
			labels = inspect.Config.Labels
		}
		owner, labelled := labels[composeProjectLabel]
		if (labelled && owner == project) || (!labelled && len(inspect.RepoDigests) == 0) {
			built = append(built, ref)
		}
	}
	return built, nil
}

// Unpinned lists, sorted, the containers of project that run another image
// than the one pinned for their service: pins maps a service to the
// reference kvsctl pulled for it, repository[:tag]@digest. The image of a
// container is compared by ID with the image the engine holds at that
// digest, so a variable or a tag that named another image, whatever the
// way, is caught; a pinned image the engine does not hold matches nothing.
// A service with no container is not listed: whether it must run is for
// the other checks to say. One-off containers are skipped.
func (c *Client) Unpinned(ctx context.Context, project string, pins map[string]string) ([]string, error) {
	list, err := c.projectContainers(ctx, project)
	if err != nil {
		return nil, err
	}
	ids := map[string]string{}
	var out []string
	for _, item := range list {
		pin, ok := pins[item.service()]
		if !ok || item.oneShot() {
			continue
		}
		want, seen := ids[pin]
		if !seen {
			lookup := pin
			if name, digest, found := strings.Cut(pin, "@"); found {
				lookup = RefName(name) + "@" + digest
			}
			inspect, err := c.api.ImageInspect(ctx, lookup)
			switch {
			case cerrdefs.IsNotFound(err):
			case err != nil:
				return nil, err
			default:
				want = inspect.ID
			}
			ids[pin] = want
		}
		if got := item.details.Image; want == "" || got != want {
			configured := ""
			if item.details.Config != nil {
				configured = item.details.Config.Image
			}
			out = append(out, fmt.Sprintf("%s runs %s (%s), not the pinned %s", item.name(), configured, shortID(got), pin))
		}
	}
	sort.Strings(out)
	return out, nil
}

// shortID is an image ID as docker prints it.
func shortID(id string) string {
	id = strings.TrimPrefix(id, "sha256:")
	if len(id) > 12 {
		id = id[:12]
	}
	return id
}
