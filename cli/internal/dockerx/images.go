package dockerx

import (
	"context"
	"errors"
	"fmt"
	"sort"
	"strings"

	"github.com/docker/docker/api/types/image"
)

// ErrImageInUse says a container still needs the image, so it stays. An
// upgrade keeps the previous version running until it is replaced, and
// forcing the removal would untag an image a running site depends on.
var ErrImageInUse = errors.New("the image is used by a container")

// RemoveImage deletes one image by reference. It never forces and never
// touches the children: only the exact tag goes, and an image a container
// still uses is reported as ErrImageInUse rather than removed.
func (c *Client) RemoveImage(ctx context.Context, ref string) error {
	_, err := c.api.ImageRemove(ctx, ref, image.RemoveOptions{Force: false, PruneChildren: false})
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
	list, err := c.api.ImageList(ctx, image.ListOptions{})
	if err != nil {
		return nil, err
	}
	return refsOf(list), nil
}

// ImageSize is the size the engine reports for an image, which is what a
// removal reclaims. It answers 0 and no error when the image is gone.
func (c *Client) ImageSize(ctx context.Context, ref string) (int64, error) {
	inspect, err := c.api.ImageInspect(ctx, ref)
	if err != nil {
		if strings.Contains(strings.ToLower(err.Error()), "no such image") {
			return 0, nil
		}
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
