package dockerx

import (
	"fmt"
	"strings"
)

// dockerHub is the name Docker Hub goes by in the configuration of the
// Docker CLI, where every other registry goes by its host name.
const dockerHub = "https://index.docker.io/v1/"

// RefName is the repository of an image reference with its registry: the
// tag and the digest are dropped, so ghcr.io/x/php:8.3@sha256:... gives
// ghcr.io/x/php and localhost:5000/x/php:0.2.0 gives localhost:5000/x/php.
func RefName(ref string) string {
	if i := strings.IndexByte(ref, '@'); i >= 0 {
		ref = ref[:i]
	}
	if colon := strings.LastIndexByte(ref, ':'); colon > strings.LastIndexByte(ref, '/') {
		ref = ref[:colon]
	}
	return ref
}

// refTag is the tag of an image reference, "" when it carries none.
func refTag(ref string) string {
	if i := strings.IndexByte(ref, '@'); i >= 0 {
		ref = ref[:i]
	}
	if colon := strings.LastIndexByte(ref, ':'); colon > strings.LastIndexByte(ref, '/') {
		return ref[colon+1:]
	}
	return ""
}

// PinnedRef is the reference the engine pulls and finds a release image
// by: its repository at the digest the release signed, without the tag. A
// registry may move a tag at any time; the digest names the same bytes for
// ever.
func PinnedRef(ref, digest string) (string, error) {
	algo, hex, ok := strings.Cut(digest, ":")
	if !ok || algo != "sha256" || len(hex) != 64 || strings.Trim(hex, "0123456789abcdef") != "" {
		return "", fmt.Errorf("%q is not a sha256 digest", digest)
	}
	name := RefName(ref)
	if name == "" {
		return "", fmt.Errorf("%q names no repository", ref)
	}
	return name + "@" + digest, nil
}

// registryKey is the name the registry of ref has in the configuration of
// the Docker CLI: the host when the first part of the name is one (it
// carries a dot or a port, or is localhost), Docker Hub otherwise, which is
// how the Docker CLI tells a host from a Docker Hub namespace.
func registryKey(ref string) string {
	first, _, found := strings.Cut(RefName(ref), "/")
	if !found || (!strings.ContainsAny(first, ".:") && first != "localhost") {
		return dockerHub
	}
	switch first {
	case "docker.io", "index.docker.io", "registry-1.docker.io":
		return dockerHub
	}
	return first
}
