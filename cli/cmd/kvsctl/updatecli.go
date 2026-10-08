package main

import (
	"bytes"
	"context"
	"errors"
	"fmt"
	"io"
	"os"
	"os/exec"
	"path/filepath"
	"runtime"
	"sort"
	"strings"
	"time"

	"github.com/spf13/cobra"

	"github.com/MaximeMichaud/KVS-install/cli/internal/instance"
	"github.com/MaximeMichaud/KVS-install/cli/internal/manifest"
	"github.com/MaximeMichaud/KVS-install/cli/internal/release"
	"github.com/MaximeMichaud/KVS-install/cli/internal/upgrade"
)

// versionTimeout bounds the run of the downloaded binary's version
// command; a variable so the tests do not wait for it.
var versionTimeout = 10 * time.Second

func updateCLICmd() *cobra.Command {
	var version string
	cmd := &cobra.Command{
		Use:   "update-cli",
		Short: "Replace this binary with the kvsctl the latest stable release ships",
		Long: "Replace this binary with the kvsctl the latest stable release ships for\n" +
			"this platform, or the one of the release --version names, a release\n" +
			"candidate included. The download stops past the size the signed manifest\n" +
			"gives and is checked against its sha256, and its 'version' has to run and\n" +
			"name that release before it takes the place of this binary. The binary it\n" +
			"replaces is kept next to it as <path>.previous. Of the manifest it reads\n" +
			"only the part every kvsctl reads, so it also works on a manifest of a\n" +
			"newer format. With --quiet it prints nothing unless it fails.",
		Args: cobra.NoArgs,
		RunE: func(cmd *cobra.Command, args []string) error {
			ctx, cancel := signalContext()
			defer cancel()
			inst, err := instance.Detect(flagRoot)
			if err != nil {
				// A machine without an installation may still update its
				// kvsctl.
				inst = nil
			} else if err := refuseInterrupted(inst); err != nil {
				return err
			}
			m, err := cliManifest(ctx)
			if ctx.Err() != nil {
				return errors.New("interrupted, this binary is unchanged")
			}
			if err != nil {
				return err
			}
			// A replayed manifest would hand out an older binary, so the
			// same freshness rule as an upgrade applies when this machine
			// holds an installation to compare against.
			if inst != nil {
				if err := upgrade.CheckManifest(inst, m, manifestURL(), flagAllowStale); err != nil {
					return err
				}
			}
			target, err := cliRelease(m, version)
			if err != nil {
				return err
			}
			asset, err := cliAsset(target)
			if err != nil {
				return err
			}
			msg, outdated := cliState(target.Version)
			if !outdated {
				cliDetail(msg + ", nothing to do")
				return nil
			}
			self, err := os.Executable()
			if err != nil {
				return err
			}
			if self, err = filepath.EvalSymlinks(self); err != nil {
				return err
			}
			if err := replaceBinary(ctx, self, asset, target.Version); err != nil {
				return err
			}
			cliDetail(fmt.Sprintf("%s: %s replaced by the build of release %s; the previous binary is %s.previous", self, Version, target.Version, self))
			return nil
		},
	}
	cmd.Flags().StringVar(&version, "version", "", "the release whose kvsctl to install, a release candidate included (default the latest stable release)")
	return cmd
}

// cliDetail prints what update-cli did, or that it had nothing to do,
// unless --quiet: a run that works then prints nothing, the way a cron job
// wants it, and a failure is the error of the command, printed all the
// same. update-cli writes no log of its own, as it may run without an
// installation, so the line goes nowhere else.
func cliDetail(line string) {
	if !flagQuiet {
		_, _ = fmt.Fprintln(stdout, line)
	}
}

// cliManifest reads the manifest the way update-cli must be able to read
// every later one: the signature checked against the keys this build
// carries, then only the part of the format that never changes, whatever
// its schema (manifest.ParseCLI), and the channel its URL serves. A newer
// schema refuses check and upgrade and sends the operator here, so this
// read must never refuse it in turn.
func cliManifest(ctx context.Context) (*manifest.Manifest, error) {
	keys, err := publicKeys()
	if err != nil {
		return nil, err
	}
	doc, err := manifest.FetchContext(ctx, manifestURL())
	if err != nil {
		return nil, err
	}
	m, err := doc.VerifyCLI(keys)
	if err != nil {
		return nil, err
	}
	if err := m.CheckChannel(manifestURL()); err != nil {
		return nil, err
	}
	return m, nil
}

// cliRelease is the release whose kvsctl update-cli installs: the one named,
// or the latest stable release. A release candidate is installed only when
// it is named.
func cliRelease(m *manifest.Manifest, version string) (*manifest.Release, error) {
	if version != "" {
		if rel := m.Find(version); rel != nil {
			return rel, nil
		}
		return nil, fmt.Errorf("version %s is not in the manifest", version)
	}
	if rel := m.LatestStable(); rel != nil {
		return rel, nil
	}
	return nil, fmt.Errorf("the manifest lists release candidates only (%s is the newest): name the one whose kvsctl to install with --version", m.Latest().Version)
}

// cliPlatform is the platform of this binary, the way the manifest names
// the kvsctl builds of a release.
func cliPlatform() string { return runtime.GOOS + "-" + runtime.GOARCH }

// cliAsset is the build of kvsctl a release ships for this platform.
func cliAsset(rel *manifest.Release) (manifest.Asset, error) {
	if asset, ok := rel.CLI[cliPlatform()]; ok {
		return asset, nil
	}
	if len(rel.CLI) == 0 {
		return manifest.Asset{}, fmt.Errorf("release %s ships no kvsctl build", rel.Version)
	}
	shipped := make([]string, 0, len(rel.CLI))
	for platform := range rel.CLI {
		shipped = append(shipped, platform)
	}
	sort.Strings(shipped)
	return manifest.Asset{}, fmt.Errorf("release %s ships kvsctl for %s only, and this binary runs on %s", rel.Version, strings.Join(shipped, ", "), cliPlatform())
}

// replaceBinary puts the build of release version in place of self. The
// download lands beside self, so the last step is a rename on one
// filesystem; it stops past the size the signed manifest gives (the most
// kvsctl takes without one), and is checked by its sha256, then run, before
// anything else happens. self is copied to self.previous first, which is
// the way back when the new build misbehaves later.
func replaceBinary(ctx context.Context, self string, asset manifest.Asset, version string) error {
	fresh := self + ".new"
	if err := release.DownloadSized(ctx, asset.URL, asset.SHA256, asset.Size, fresh, nil); err != nil {
		return fmt.Errorf("download %s: %w; %s is unchanged", asset.URL, err, self)
	}
	defer os.Remove(fresh)
	if err := os.Chmod(fresh, 0o755); err != nil {
		return err
	}
	if err := checkBinary(ctx, fresh, version); err != nil {
		return fmt.Errorf("%w; %s is unchanged", err, self)
	}
	if err := keepPrevious(self); err != nil {
		return fmt.Errorf("keep %s as %s.previous: %w; %s is unchanged", self, self, err, self)
	}
	if err := os.Rename(fresh, self); err != nil {
		return fmt.Errorf("%w; %s is unchanged", err, self)
	}
	// The new binary is in place; a directory that cannot be flushed only
	// risks the rename after a power cut, which leaves the old binary.
	_ = syncDir(filepath.Dir(self))
	return nil
}

// checkBinary runs the version command of a downloaded build, which has to
// name the release it comes from: a binary that does not start on this
// machine, or answers for another version, never replaces a working one.
func checkBinary(ctx context.Context, path, version string) error {
	ctx, cancel := context.WithTimeout(ctx, versionTimeout)
	defer cancel()
	var stdout, stderr bytes.Buffer
	cmd := exec.CommandContext(ctx, path, "version")
	cmd.Stdout, cmd.Stderr = &stdout, &stderr
	cmd.WaitDelay = time.Second
	if err := cmd.Run(); err != nil {
		if ctx.Err() != nil {
			err = fmt.Errorf("no answer in %s", versionTimeout)
		}
		return fmt.Errorf("the downloaded kvsctl did not run its version command (%v): %s", err, firstLine(strings.TrimSpace(stderr.String())))
	}
	want := "kvsctl " + version + " ("
	if got := firstLine(stdout.String()); !strings.HasPrefix(got, want) {
		return fmt.Errorf("the downloaded kvsctl says %q, not kvsctl %s", got, version)
	}
	return nil
}

// keepPrevious copies self to self.previous, through a temporary file that
// reaches the disk before it takes the name.
func keepPrevious(self string) error {
	in, err := os.Open(self)
	if err != nil {
		return err
	}
	defer in.Close()
	info, err := in.Stat()
	if err != nil {
		return err
	}
	previous := self + ".previous"
	tmp := previous + ".tmp"
	out, err := os.OpenFile(tmp, os.O_CREATE|os.O_WRONLY|os.O_TRUNC, info.Mode().Perm())
	if err != nil {
		return err
	}
	_, err = io.Copy(out, in)
	if err == nil {
		err = out.Sync()
	}
	if cerr := out.Close(); err == nil {
		err = cerr
	}
	if err == nil {
		err = os.Rename(tmp, previous)
	}
	if err != nil {
		os.Remove(tmp)
	}
	return err
}

// syncDir flushes a directory, so the names it holds survive a power cut.
func syncDir(dir string) error {
	d, err := os.Open(dir)
	if err != nil {
		return err
	}
	defer d.Close()
	return d.Sync()
}
