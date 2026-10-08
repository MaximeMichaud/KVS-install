package main

import (
	"bytes"
	"context"
	"crypto/sha256"
	"encoding/hex"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"time"

	"github.com/spf13/cobra"

	"github.com/MaximeMichaud/KVS-install/cli/internal/dockerx"
	"github.com/MaximeMichaud/KVS-install/cli/internal/instance"
	"github.com/MaximeMichaud/KVS-install/cli/internal/release"
	"github.com/MaximeMichaud/KVS-install/cli/internal/semver"
)

// phpIni is the PHP configuration of the stack, relative to the root.
const phpIni = "docker/php/php.ini"

// jitBlock is what docker/setup.sh appended to docker/php/php.ini on a site
// without IonCube, before the setting moved to the entrypoint of the PHP
// image. A php.ini that is the committed one plus exactly this block was
// changed by the setup, not by the operator.
const jitBlock = "\n; JIT Configuration (PHP 8.0+ without IonCube)\n; Note: JIT is incompatible with IonCube Loader\nopcache.jit_buffer_size = 256M\nopcache.jit = 1255\n"

func adoptCmd() *cobra.Command {
	var version string
	var force bool
	cmd := &cobra.Command{
		Use:   "adopt",
		Short: "Record a stack that kvs-install.sh installed, so kvsctl can upgrade it",
		Long: "Record a stack that kvs-install.sh installed as a git checkout, so that\n" +
			"kvsctl can upgrade it. The version is the one docker/RELEASE names, else\n" +
			"the release tag at the commit of the checkout, else 0.0.0, which kvsctl\n" +
			"shows as the unreleased checkout of that commit; --version names it\n" +
			"instead. The release files are kept in kvsctl/releases/<version> for a\n" +
			"rollback, the commit is recorded, and the files that differ from it are\n" +
			"listed: the first 'kvsctl check' reports them as local changes. The\n" +
			"images the checkout built are recorded as the images of that version,\n" +
			"which 'kvsctl clean' removes once upgrades have left it behind.",
		Args: cobra.NoArgs,
		RunE: func(cmd *cobra.Command, args []string) error {
			if version != "" {
				v, err := semver.Parse(version)
				if err != nil {
					return usageError{err}
				}
				version = v.String()
			}
			g := newGuard("adopt stops before it records anything", nil)
			s, err := openSession("adopt", g, sessionOptions{})
			if err != nil {
				return err
			}
			return s.finish(adopt(s, version, force))
		},
	}
	cmd.Flags().StringVar(&version, "version", "", "the stack version to record (default: docker/RELEASE, else the release tag at HEAD, else 0.0.0)")
	cmd.Flags().BoolVar(&force, "force", false, "record the stack again, as long as kvsctl has not upgraded it")
	return cmd
}

// adopt records the checkout at the root as a stack kvsctl manages.
func adopt(s *session, version string, force bool) error {
	inst := s.inst
	state, err := inst.LoadState()
	if err != nil {
		return err
	}
	if state != nil {
		if !force {
			return fmt.Errorf("this stack is already recorded as %s ('kvsctl status' shows it); --force records it again, as long as kvsctl has not upgraded it", state.Label(state.Current))
		}
		if state.Upgraded() {
			return errors.New("kvsctl has upgraded this stack: its record comes from the releases it installed, and adopting it again would lose the way back; to finish a run that was cut short, run 'kvsctl recover'")
		}
	}
	co, err := inst.ReadCheckout()
	if err != nil {
		return err
	}
	tracked, err := inst.TrackedFiles()
	if err != nil {
		return err
	}
	source := "--version"
	if version == "" {
		if version, source, err = adoptedVersionOf(inst.Root, co); err != nil {
			return err
		}
	}
	sums, absent, err := inst.HeadChecksums(tracked)
	if err != nil {
		return err
	}
	// A file git tracks but HEAD does not hold yet has no checksum of the
	// commit: an empty one never matches, so it counts as changed.
	for _, f := range absent {
		sums[f] = ""
	}
	jit, err := allowJITBlock(inst.Root, sums)
	if err != nil {
		return err
	}
	changed, err := release.Verify(inst.Root, sums)
	if err != nil {
		return err
	}
	// The snapshot is the working tree, what the stack runs: a tracked
	// file deleted from it has nothing to keep, and stays a change.
	files, missing := present(inst.Root, tracked)
	if err := s.ctx().Err(); err != nil {
		return errors.New("adopt interrupted, nothing was recorded")
	}
	// The images the checkout built are recorded as the images of its
	// version, which is how 'kvsctl clean' removes them once upgrades leave
	// that version behind. Without an engine they stay unrecorded, and the
	// adopt goes on: they cost disk space, not the way back.
	built, imagesErr := checkoutImages(s.ctx(), inst.DockerDir)
	kept := filepath.Join(inst.ReleasesDir(), version)
	if err := release.Snapshot(inst.Root, kept, files); err != nil {
		return fmt.Errorf("keep the release files in %s: %w; nothing was recorded", kept, err)
	}
	if err := s.ctx().Err(); err != nil {
		return errors.New("adopt interrupted, nothing was recorded")
	}
	newState := &instance.State{
		Current:           version,
		Files:             files,
		Checksums:         sums,
		AdoptedCommit:     co.Commit,
		AdoptedCommitDate: co.Date,
	}
	if state != nil {
		newState.History = state.History
		// A record adopted again keeps the images of the versions it
		// recorded before, for clean to find them.
		for v, refs := range state.ReleaseImages {
			if v != version {
				if newState.ReleaseImages == nil {
					newState.ReleaseImages = map[string][]string{}
				}
				newState.ReleaseImages[v] = refs
			}
		}
	}
	if len(built) > 0 {
		if newState.ReleaseImages == nil {
			newState.ReleaseImages = map[string][]string{}
		}
		newState.ReleaseImages[version] = built
	}
	newState.History = append(newState.History, instance.Entry{Version: version, Action: "adopt", Date: time.Now().UTC(), Note: "commit " + shortCommit(co.Commit)})
	if err := inst.SaveState(newState); err != nil {
		// Exit 1 after a change: --quiet printed nothing of it.
		return fmt.Errorf("the release files are kept in %s, but the stack could not be recorded: %w", kept, err)
	}
	if err := inst.SetEnv("KVS_STACK_VERSION", version); err != nil {
		return fmt.Errorf("the stack is recorded as %s, but KVS_STACK_VERSION could not be written to %s: %w", version, inst.EnvPath, err)
	}
	// What adopt recorded is what status and check show from now on: with
	// --quiet it goes to the log alone.
	s.detailf("%s recorded as stack %s (%s)", inst.Domain(), newState.Label(version), source)
	s.detailf("commit %s of %s", co.Commit, co.Date.UTC().Format("2006-01-02 15:04 UTC"))
	s.detailf("%d release files kept in %s for a rollback", len(files), kept)
	switch {
	case imagesErr != nil:
		s.detailf("the images the checkout built could not be listed (%s): 'kvsctl clean' will not remove them", firstLine(imagesErr.Error()))
	case len(built) > 0:
		s.detailf("%d %s the checkout built recorded: 'kvsctl clean' removes %s once %s is neither installed nor the version a rollback returns to", len(built), plural(len(built), "image", "images"), plural(len(built), "it", "them"), newState.Label(version))
	}
	if jit {
		s.detailf("%s holds the JIT block the setup appended to it: counted as unchanged", phpIni)
	}
	if len(changed) > 0 {
		s.detailf("%d %s differ from commit %s; 'kvsctl check' reports them, and 'kvsctl upgrade' replaces them only with --allow-local-changes:", len(changed), plural(len(changed), "file", "files"), shortCommit(co.Commit))
		for _, f := range changed {
			note := ""
			switch {
			case missing[f]:
				note = " (deleted)"
			case sums[f] == "":
				note = " (not committed)"
			}
			s.detailf("  %s%s", f, note)
		}
	}
	s.detail("kvs-install.sh does not update a stack kvsctl manages; run 'kvsctl check', then 'kvsctl upgrade'")
	return nil
}

// checkoutImages lists the images the checkout whose compose project is in
// dir built: the images of the project that compose built on the machine,
// never pulled. A variable so a test reaches no engine.
var checkoutImages = func(ctx context.Context, dir string) ([]string, error) {
	project, err := dockerx.ComposeProject(ctx, dir)
	if err != nil {
		return nil, err
	}
	refs, err := dockerx.ComposeImages(ctx, dir)
	if err != nil {
		return nil, err
	}
	docker, err := dockerx.New()
	if err != nil {
		return nil, err
	}
	defer docker.Close()
	return docker.BuiltLocally(ctx, project, refs)
}

// adoptedVersionOf is the version adopt records without --version, and
// where it comes from: docker/RELEASE, which a release bundle carries;
// else the release tag at HEAD; else 0.0.0, the unreleased checkout.
func adoptedVersionOf(root string, co *instance.Checkout) (version, source string, err error) {
	data, err := os.ReadFile(filepath.Join(root, "docker", "RELEASE"))
	switch {
	case err == nil:
		first, _, _ := strings.Cut(string(data), "\n")
		v, perr := semver.Parse(first)
		if perr != nil {
			return "", "", fmt.Errorf("docker/RELEASE holds %q, which is not a version: name the version with --version", strings.TrimSpace(first))
		}
		return v.String(), "docker/RELEASE", nil
	case !errors.Is(err, os.ErrNotExist):
		return "", "", err
	case co.Tag != "":
		return co.Tag, "the tag at commit " + shortCommit(co.Commit), nil
	}
	return instance.Unreleased, "no release names commit " + shortCommit(co.Commit), nil
}

// allowJITBlock records the php.ini of the working tree as unchanged when it
// is the committed one plus exactly the JIT block the setup appended. It
// reports whether it did.
func allowJITBlock(root string, sums map[string]string) (bool, error) {
	head, ok := sums[phpIni]
	if !ok || head == "" {
		return false, nil
	}
	data, err := os.ReadFile(filepath.Join(root, phpIni))
	if errors.Is(err, os.ErrNotExist) {
		return false, nil
	}
	if err != nil {
		return false, err
	}
	base, found := bytes.CutSuffix(data, []byte(jitBlock))
	if !found || sha256Hex(base) != head {
		return false, nil
	}
	sums[phpIni] = sha256Hex(data)
	return true, nil
}

func sha256Hex(data []byte) string {
	sum := sha256.Sum256(data)
	return hex.EncodeToString(sum[:])
}

// present splits the tracked files into those the working tree holds and
// those it lost.
func present(root string, files []string) (kept []string, missing map[string]bool) {
	missing = map[string]bool{}
	for _, f := range files {
		if _, err := os.Lstat(filepath.Join(root, f)); errors.Is(err, os.ErrNotExist) {
			missing[f] = true
			continue
		}
		kept = append(kept, f)
	}
	return kept, missing
}
