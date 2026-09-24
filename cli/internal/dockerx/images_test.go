package dockerx

import (
	"errors"
	"strings"
	"testing"

	"github.com/docker/docker/api/types/image"
)

func TestRefsOf(t *testing.T) {
	list := []image.Summary{
		{RepoTags: []string{"ghcr.io/x/php:0.2.0", "ghcr.io/x/php:latest"}},
		{RepoTags: []string{"<none>:<none>"}},
		{RepoTags: nil},
		{RepoTags: []string{"ghcr.io/x/nginx:0.1.0", "ghcr.io/x/php:0.2.0"}},
	}
	got := strings.Join(refsOf(list), " ")
	want := "ghcr.io/x/nginx:0.1.0 ghcr.io/x/php:0.2.0 ghcr.io/x/php:latest"
	if got != want {
		t.Fatalf("refs are %q, wanted %q", got, want)
	}
}

func TestInUse(t *testing.T) {
	used := []string{
		`Error response from daemon: conflict: unable to remove repository reference "ghcr.io/x/php:0.1.0" (must force) - container 4b2 is using its referenced image 9ad`,
		"Error response from daemon: conflict: unable to delete 9ad (must be forced) - image is being used by stopped container 4b2",
	}
	for _, msg := range used {
		if !inUse(errors.New(msg)) {
			t.Fatalf("not recognised as in use: %s", msg)
		}
	}
	if inUse(errors.New("Error response from daemon: No such image: ghcr.io/x/php:0.1.0")) {
		t.Fatal("a missing image was read as in use")
	}
}
