package doctor

import (
	"context"
	"fmt"
	"os"
	"path/filepath"
	"slices"
	"sort"
	"strings"
	"time"

	"golang.org/x/sys/unix"

	"github.com/MaximeMichaud/KVS-install/cli/internal/backup"
	"github.com/MaximeMichaud/KVS-install/cli/internal/dockerx"
	"github.com/MaximeMichaud/KVS-install/cli/internal/release"
	"github.com/MaximeMichaud/KVS-install/cli/internal/upgrade"
)

func (r *runner) storageInstallation(ctx context.Context) Result {
	return r.measurePaths(ctx, []string{r.inst.Root, r.inst.StateDir(), r.inst.BackupDir()}, true)
}

func (r *runner) storageData(ctx context.Context) Result {
	paths := []string{r.info.RootDir}
	var missing []string
	for _, mount := range []struct{ service, path string }{{"mariadb", "/var/lib/mysql"}, {"php-fpm", "/var/www/kvs"}} {
		c := r.running(mount.service)
		if c == nil {
			missing = append(missing, mount.service+": container is not running")
			continue
		}
		path, err := r.docker.MountSource(ctx, c.ID, mount.path)
		if err != nil {
			missing = append(missing, mount.service+": data mount could not be located")
			continue
		}
		paths = append(paths, path)
	}
	result := r.measurePaths(ctx, paths, false)
	if len(missing) > 0 {
		if result.Status != Fail {
			result.Status, result.Message = Warn, "Some data filesystems could not be measured"
		}
		result.Incomplete = true
		result.Details = append(result.Details, missing...)
	}
	return result
}

func (r *runner) measurePaths(ctx context.Context, paths []string, access bool) Result {
	var details, warnings, problems []string
	seen := map[string]bool{}
	for _, path := range paths {
		if path == "" || seen[path] {
			continue
		}
		seen[path] = true
		if ctx.Err() != nil {
			break
		}
		space, err := r.probe.space(path)
		if err != nil {
			problems = append(problems, path+": filesystem could not be measured")
			continue
		}
		line := fmt.Sprintf("%s: %s available", path, upgrade.HumanBytes(space.Avail))
		if space.Files > 0 {
			line += fmt.Sprintf(", %.1f%% inodes free", float64(space.FreeFiles)*100/float64(space.Files))
		}
		details = append(details, line)
		switch {
		case space.ReadOnly:
			problems = append(problems, path+": filesystem is read-only")
		case space.Avail < backup.FreeFloor(space.Size):
			problems = append(problems, path+": below the backup reserve (larger of 1 GiB and 2%)")
		case space.Size > 0 && space.Avail < space.Size/10:
			warnings = append(warnings, path+": less than 10% disk space available")
		}
		if space.Files > 0 && space.FreeFiles == 0 {
			problems = append(problems, path+": no free inodes")
		} else if space.Files > 0 && float64(space.FreeFiles)/float64(space.Files) < .05 {
			warnings = append(warnings, path+": less than 5% inodes free")
		}
		if access {
			parent := path
			for {
				_, err := os.Stat(parent)
				if !os.IsNotExist(err) || filepath.Dir(parent) == parent {
					break
				}
				parent = filepath.Dir(parent)
			}
			if unix.Faccessat(unix.AT_FDCWD, parent, unix.R_OK|unix.W_OK|unix.X_OK, unix.AT_EACCESS) != nil {
				problems = append(problems, path+": current user cannot access the directory or create files in its nearest existing parent")
			}
		}
	}
	if len(problems) > 0 {
		return failure("Storage or directory access needs attention", "Inspect disk usage, mounts and directory permissions", append(problems, details...)...)
	}
	if len(warnings) > 0 {
		return warning("Storage is running low", "Review disk and inode usage before maintenance", append(warnings, details...)...)
	}
	return good("Filesystem space and inodes are available", details...)
}

func (r *runner) backups(ctx context.Context) Result {
	entries, err := os.ReadDir(r.inst.BackupDir())
	if os.IsNotExist(err) {
		return warning("No local backup directory exists; external backup coverage is unknown", r.command("backup"))
	}
	if err != nil {
		return failure("Local backups cannot be listed", "Check read access to "+r.inst.BackupDir())
	}
	// Avoid following symlinks or opening special files through backup.List.
	for _, entry := range entries {
		if !strings.HasPrefix(entry.Name(), "backup-") || !strings.HasSuffix(entry.Name(), ".tar") {
			continue
		}
		info, err := entry.Info()
		if err != nil || !info.Mode().IsRegular() {
			return failure("A backup archive is not an accessible regular file", "Inspect the entries in "+r.inst.BackupDir())
		}
	}
	list, err := backup.List(r.inst.BackupDir())
	if err != nil {
		return failure("Local backup metadata cannot be listed", "Inspect the archives in "+r.inst.BackupDir())
	}
	if len(list) == 0 {
		return warning("No local backup archive found; external backup coverage is unknown", r.command("backup"))
	}
	var bad []string
	for _, archive := range list {
		if ctx.Err() != nil {
			break
		}
		meta, names, err := backup.Describe(archive.Path)
		if err != nil || meta == nil || !slices.Contains(names, "database.sql.zst") {
			bad = append(bad, archive.Name+": unreadable or missing database member")
		}
	}
	if len(bad) > 0 {
		return failure("Some backup archives have unreadable or incomplete metadata", "Inspect these archives and take a new backup if necessary", bad...)
	}
	latest := list[0]
	age := r.now.Sub(latest.Date)
	detail := fmt.Sprintf("Newest: %s, age %s, archive %s", latest.Name, age.Round(time.Hour), upgrade.HumanBytes(latest.Size))
	if age < -5*time.Minute {
		return warning("Newest backup is dated in the future", "Check the host clock and archive timestamps", detail)
	}
	return good(fmt.Sprintf("%d backup archive(s) have readable metadata; restore was not tested", len(list)), detail)
}

func (r *runner) files(ctx context.Context) Result {
	if r.state == nil {
		return skipped("No recorded release checksums on this unadopted installation", false)
	}
	if len(r.state.Checksums) == 0 {
		return warning("No file checksums were recorded for this stack", "Inspect the recorded state before the next upgrade")
	}
	var changed []string
	for name, sum := range r.state.Checksums {
		if ctx.Err() != nil {
			break
		}
		files, err := release.Verify(r.inst.Root, map[string]string{name: sum})
		if err != nil {
			return failure("Recorded release files could not all be read", "Check file access under "+r.inst.Root)
		}
		changed = append(changed, files...)
	}
	sort.Strings(changed)
	if len(changed) > 0 {
		return warning(fmt.Sprintf("%d tracked release file(s) differ from their recorded checksums", len(changed)), "Review local changes before an upgrade; keep custom configuration in an operator override", changed...)
	}
	return good(fmt.Sprintf("%d release file checksums match their local record", len(r.state.Checksums)))
}

func (r *runner) images(ctx context.Context) Result {
	if r.state == nil {
		return skipped("No recorded release image pins on this unadopted installation", false)
	}
	recorded := r.state.ReleaseImages[r.state.Current]
	if len(recorded) == 0 {
		return warning("No release image pins were recorded for the installed version", "Inspect the recorded state before the next upgrade")
	}
	pins := map[string]string{}
	var differences []string
	for service, config := range r.project.Services {
		if service == "kvs-init" || service == "phpmyadmin-init" {
			continue
		}
		if slices.Contains(recorded, config.Image) {
			pins[service] = config.Image
			continue
		}
		for _, pin := range recorded {
			if dockerx.RefName(config.Image) == dockerx.RefName(pin) {
				pins[service] = pin
				break
			}
		}
		if pins[service] == "" {
			differences = append(differences, service+": configured image has no matching recorded release pin")
		} else {
			differences = append(differences, service+": configured image reference differs from the recorded release pin")
		}
	}
	wrong, err := r.docker.Unpinned(ctx, r.project.Name, pins)
	if err != nil {
		return failure("Running images could not be compared with their local pins", "Check access to the local Docker image metadata")
	}
	if len(wrong) > 0 {
		return failure("Running images differ from the recorded release pins", "Review the release override and the running containers", wrong...)
	}
	if len(differences) > 0 {
		sort.Strings(differences)
		return warning("Configured images differ from the recorded release pins", "Review custom services and release image settings before recreating containers", differences...)
	}
	return good("Running images match the recorded release pins")
}
