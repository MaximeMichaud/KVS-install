package main

import (
	"bufio"
	"errors"
	"fmt"
	"io/fs"
	"os"
	"path/filepath"
	"regexp"
	"sort"
	"strings"

	"github.com/spf13/cobra"

	"github.com/MaximeMichaud/KVS-install/cli/internal/dockerx"
	"github.com/MaximeMichaud/KVS-install/cli/internal/instance"
	"github.com/MaximeMichaud/KVS-install/cli/internal/upgrade"
)

func init() { register(cleanCmd()) }

func cleanCmd() *cobra.Command {
	var dryRun bool
	cmd := &cobra.Command{
		Use:   "clean",
		Short: "Remove what past upgrades left behind",
		Long: "Remove what past upgrades left behind: the images of the versions\n" +
			"that are neither installed nor the one a rollback returns to, the\n" +
			"release files kept for those versions, and the downloaded bundles.\n" +
			"The current and the previous version are never touched, so a\n" +
			"rollback keeps working.",
		Args: cobra.NoArgs,
		RunE: func(cmd *cobra.Command, args []string) error {
			ctx, cancel := signalContext()
			defer cancel()
			inst, err := instance.Detect(flagRoot)
			if err != nil {
				return err
			}
			unlock, err := inst.Lock("clean")
			if err != nil {
				return err
			}
			defer unlock()
			state, err := inst.LoadState()
			if err != nil {
				return err
			}
			plan, err := cleanTargets(inst.StateDir(), state)
			if err != nil {
				return err
			}
			if plan.empty() {
				fmt.Println("nothing to clean")
				return nil
			}
			docker, err := dockerx.New()
			if err != nil {
				return err
			}
			defer docker.Close()
			local, err := docker.ImageRefs(ctx)
			if err != nil {
				return err
			}
			// An image of an old version that the engine no longer holds
			// was removed by hand, or never pulled on this machine.
			plan.Images = onlyLocal(plan.Images, local)
			if plan.empty() {
				fmt.Println("nothing to clean")
				return nil
			}
			sizes := map[string]int64{}
			var total int64
			if len(plan.Images) > 0 {
				fmt.Println("Images:")
				for _, ref := range plan.Images {
					size, err := docker.ImageSize(ctx, ref)
					if err != nil {
						size = 0
					}
					sizes[ref] = size
					total += size
					fmt.Printf("  %-60s %s\n", ref, orBlank(size))
				}
			}
			if len(plan.Releases) > 0 {
				fmt.Println("Release files:")
				for _, dir := range plan.Releases {
					size := dirSize(dir)
					sizes[dir] = size
					total += size
					fmt.Printf("  %-60s %s\n", dir, orBlank(size))
				}
			}
			if plan.Downloads != "" {
				size := dirSize(plan.Downloads)
				sizes[plan.Downloads] = size
				total += size
				fmt.Println("Downloads:")
				fmt.Printf("  %-60s %s\n", plan.Downloads, orBlank(size))
			}
			fmt.Printf("Total:       %s\n", upgrade.HumanBytes(total))
			if len(plan.Kept) > 0 {
				fmt.Printf("Kept:        %s\n", strings.Join(plan.Kept, ", "))
			}
			if dryRun {
				fmt.Println("nothing removed (--dry-run)")
				return nil
			}
			if !promptYes(fmt.Sprintf("Remove %s?", cleanSummary(plan))) {
				return errors.New("clean cancelled")
			}
			var reclaimed int64
			var failures []string
			for _, ref := range plan.Images {
				err := docker.RemoveImage(ctx, ref)
				switch {
				case err == nil:
					reclaimed += sizes[ref]
					fmt.Printf("  removed %s\n", ref)
				case errors.Is(err, dockerx.ErrImageInUse):
					fmt.Printf("  kept %s, a container still uses it\n", ref)
				default:
					failures = append(failures, err.Error())
				}
			}
			for _, dir := range append(append([]string{}, plan.Releases...), existing(plan.Downloads)...) {
				if err := os.RemoveAll(dir); err != nil {
					failures = append(failures, err.Error())
					continue
				}
				reclaimed += sizes[dir]
				fmt.Printf("  removed %s\n", dir)
			}
			fmt.Printf("%s reclaimed\n", upgrade.HumanBytes(reclaimed))
			if len(failures) > 0 {
				return fmt.Errorf("%d removals failed: %s", len(failures), strings.Join(failures, "; "))
			}
			if state != nil && len(plan.Dropped) > 0 && state.ReleaseImages != nil {
				for _, version := range plan.Dropped {
					delete(state.ReleaseImages, version)
				}
				if err := inst.SaveState(state); err != nil {
					return fmt.Errorf("the images are gone but the record in %s could not be updated: %w", inst.StateDir(), err)
				}
			}
			return nil
		},
	}
	cmd.Flags().BoolVar(&dryRun, "dry-run", false, "list what would go, with its size, and remove nothing")
	return cmd
}

// cleanPlan is what clean would remove.
type cleanPlan struct {
	// Images are the references of the versions that are neither current
	// nor previous.
	Images []string
	// Releases are the kept file sets of those same versions.
	Releases []string
	// Downloads is the directory of downloaded bundles, empty when there
	// is nothing to remove there.
	Downloads string
	// Dropped are the versions whose record of pins goes with them.
	Dropped []string
	// Kept names the versions clean refuses to touch.
	Kept []string
}

func (p *cleanPlan) empty() bool {
	return len(p.Images) == 0 && len(p.Releases) == 0 && p.Downloads == ""
}

// cleanTargets works out what past upgrades left behind. A stack that was
// never adopted keeps every version: without a state there is no way to
// tell which images a rollback still needs.
func cleanTargets(stateDir string, state *instance.State) (*cleanPlan, error) {
	plan := &cleanPlan{}
	downloads := filepath.Join(stateDir, "downloads")
	if entries, err := os.ReadDir(downloads); err == nil && len(entries) > 0 {
		plan.Downloads = downloads
	}
	if state == nil {
		return plan, nil
	}
	releases := filepath.Join(stateDir, "releases")
	keep := map[string]bool{}
	for _, v := range []string{state.Current, state.Previous} {
		if v != "" {
			keep[v] = true
			plan.Kept = append(plan.Kept, v)
		}
	}
	versions := map[string]bool{}
	for _, e := range state.History {
		if e.Version != "" {
			versions[e.Version] = true
		}
	}
	entries, err := os.ReadDir(releases)
	if err != nil && !errors.Is(err, os.ErrNotExist) {
		return nil, err
	}
	for _, e := range entries {
		if e.IsDir() {
			versions[e.Name()] = true
		}
	}
	for version := range state.ReleaseImages {
		versions[version] = true
	}
	kept := map[string]bool{}
	drop := map[string]bool{}
	for version := range versions {
		// The pins recorded at install time name the variant images too;
		// the override of an older state only names the direct pins.
		refs := state.ReleaseImages[version]
		if len(refs) == 0 {
			refs, err = refsFromOverride(filepath.Join(releases, version, "docker", upgrade.ReleaseOverride))
			if err != nil {
				return nil, err
			}
		}
		for _, ref := range refs {
			for _, candidate := range imageCandidates(ref) {
				if keep[version] {
					kept[candidate] = true
					continue
				}
				drop[candidate] = true
			}
		}
		if !keep[version] {
			plan.Dropped = append(plan.Dropped, version)
		}
	}
	for ref := range drop {
		if !kept[ref] {
			plan.Images = append(plan.Images, ref)
		}
	}
	sort.Strings(plan.Dropped)
	sort.Strings(plan.Images)
	for _, e := range entries {
		if !e.IsDir() || keep[e.Name()] {
			continue
		}
		plan.Releases = append(plan.Releases, filepath.Join(releases, e.Name()))
	}
	sort.Strings(plan.Releases)
	sort.Strings(plan.Kept)
	return plan, nil
}

var imageLineRe = regexp.MustCompile(`^\s+image:\s*(\S.*?)\s*$`)

// imageCandidates lists the references the engine may hold for a pin. A
// release pins "repo:tag@sha256:...", which the engine lists as "repo:tag"
// once pulled and as "repo@sha256:..." in its digests; a pin without a
// digest is one reference. An .env reference in an override is nothing.
func imageCandidates(ref string) []string {
	if strings.HasPrefix(ref, "${") {
		return nil
	}
	name, digest, hasDigest := strings.Cut(ref, "@")
	if !hasDigest {
		return []string{ref}
	}
	repo := name
	if i := strings.LastIndexByte(name, ':'); i > strings.LastIndexByte(name, '/') {
		repo = name[:i]
	}
	if repo == name {
		return []string{repo + "@" + digest}
	}
	return []string{name, repo + "@" + digest}
}

// refsFromOverride reads the images a release pinned, from the compose
// override its bundle shipped. A version whose override is gone simply
// pins nothing kvsctl knows about.
func refsFromOverride(path string) ([]string, error) {
	f, err := os.Open(path)
	if errors.Is(err, os.ErrNotExist) {
		return nil, nil
	}
	if err != nil {
		return nil, err
	}
	defer f.Close()
	var refs []string
	scanner := bufio.NewScanner(f)
	for scanner.Scan() {
		line := scanner.Text()
		if strings.HasPrefix(strings.TrimSpace(line), "#") {
			continue
		}
		m := imageLineRe.FindStringSubmatch(line)
		if m == nil {
			continue
		}
		if ref := strings.Trim(m[1], `"'`); ref != "" {
			refs = append(refs, ref)
		}
	}
	return refs, scanner.Err()
}

// onlyLocal keeps the references the engine actually holds; the rest were
// already removed, or never pulled on this machine.
func onlyLocal(refs, local []string) []string {
	have := map[string]bool{}
	for _, ref := range local {
		have[ref] = true
	}
	var out []string
	for _, ref := range refs {
		if have[ref] {
			out = append(out, ref)
		}
	}
	return out
}

func cleanSummary(plan *cleanPlan) string {
	var parts []string
	if n := len(plan.Images); n > 0 {
		parts = append(parts, fmt.Sprintf("%d %s", n, plural(n, "image", "images")))
	}
	if n := len(plan.Releases); n > 0 {
		parts = append(parts, fmt.Sprintf("%d kept %s", n, plural(n, "release", "releases")))
	}
	if plan.Downloads != "" {
		parts = append(parts, "the downloaded bundles")
	}
	return strings.Join(parts, ", ")
}

func plural(n int, one, many string) string {
	if n == 1 {
		return one
	}
	return many
}

func existing(path string) []string {
	if path == "" {
		return nil
	}
	return []string{path}
}

func orBlank(size int64) string {
	if size <= 0 {
		return ""
	}
	return upgrade.HumanBytes(size)
}

// dirSize sums the files of a directory, which is what removing it gives
// back.
func dirSize(path string) int64 {
	var total int64
	filepath.WalkDir(path, func(p string, d fs.DirEntry, err error) error {
		if err != nil || d.IsDir() {
			return nil //nolint:nilerr // an unreadable entry is worth no size
		}
		if info, err := d.Info(); err == nil {
			total += info.Size()
		}
		return nil
	})
	return total
}
