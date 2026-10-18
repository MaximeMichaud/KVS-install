package main

import (
	"flag"
	"fmt"
	"io"

	"github.com/MaximeMichaud/KVS-install/cli/internal/manifest"
	"github.com/MaximeMichaud/KVS-install/cli/internal/semver"
)

// checkCacheRouting runs the publisher's validation before images are pushed.
// The previous manifest has already had its signature checked by the workflow.
func checkCacheRouting(args []string, out io.Writer) error {
	fs := flag.NewFlagSet("check-cache-routing", flag.ContinueOnError)
	version := fs.String("version", "", "release version")
	policy := fs.String("cache-routing", "", "direct or empty")
	minimum := fs.String("kvsctl-min", "", "oldest kvsctl that may install the release")
	previous := fs.String("previous", "", "verified stable manifest to extend")
	if err := fs.Parse(args); err != nil {
		return err
	}
	if *version == "" || fs.NArg() != 0 {
		return fmt.Errorf("--version is required; positional arguments are not accepted")
	}
	released, err := semver.Parse(*version)
	if err != nil {
		return err
	}
	needsKvsctl, err := kvsctlMinimum(*minimum, released)
	if err != nil {
		return err
	}
	m, err := readPreviousManifest(*previous)
	if err != nil {
		return err
	}
	needsKvsctl, err = cacheRoutingMinimum(*policy, needsKvsctl, released, m.Releases)
	if err != nil {
		return err
	}
	if needsKvsctl == "" {
		needsKvsctl = "none"
	}
	_, err = fmt.Fprintf(out, "kvsctl min: %s\n", needsKvsctl)
	return err
}

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
