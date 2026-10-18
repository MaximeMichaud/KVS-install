package main

import (
	"fmt"

	"github.com/MaximeMichaud/KVS-install/cli/internal/manifest"
	"github.com/MaximeMichaud/KVS-install/cli/internal/semver"
)

// Older binaries ignore cache_routing. Their existing kvsctl_min gate must
// refuse the first release using it, before an upgrade changes anything.
// Subsequent direct releases keep that floor instead of requiring a CLI
// update on every stack upgrade.
func cacheRoutingMinimum(policy, minimum string, version semver.Version, previous []manifest.Release) (string, error) {
	if policy == "" {
		return minimum, nil
	}
	if policy != "direct" {
		return "", fmt.Errorf("--cache-routing must be empty or direct")
	}
	floor := version.String()
	for _, rel := range previous {
		if rel.CacheRouting == "direct" && rel.Requires.KvsctlMin != "" && semver.Less(rel.Requires.KvsctlMin, floor) {
			floor = rel.Requires.KvsctlMin
		}
	}
	if minimum == "" {
		return floor, nil
	}
	if semver.Less(minimum, floor) {
		return "", fmt.Errorf("--kvsctl-min %s is older than %s, which implements direct cache routing", minimum, floor)
	}
	return minimum, nil
}
