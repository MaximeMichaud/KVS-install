package release

import (
	"errors"
	"os"
	"path/filepath"
	"slices"
	"strings"
	"testing"
	"time"

	"golang.org/x/sys/unix"
)

// victimContent is what the file outside the root of a test holds, the
// file a link planted in the tree points at.
const victimContent = "not kvsctl's"

// victim makes a file outside the root of a test, mode 0600, and returns
// its path.
func victim(t *testing.T, dir, name string) string {
	t.Helper()
	p := filepath.Join(dir, "outside", name)
	if err := os.MkdirAll(filepath.Dir(p), 0o700); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(p, []byte(victimContent), 0o600); err != nil {
		t.Fatal(err)
	}
	return p
}

// untouched fails the test when the file outside the root changed.
func untouched(t *testing.T, p string) {
	t.Helper()
	info, err := os.Lstat(p)
	if err != nil {
		t.Errorf("the file outside the root: %v", err)
		return
	}
	got, _ := os.ReadFile(p)
	if string(got) != victimContent || info.Mode() != 0o600 {
		t.Errorf("the file outside the root now holds %q, mode %v", got, info.Mode())
	}
}

func symlink(t *testing.T, target, link string) {
	t.Helper()
	if err := os.Symlink(target, link); err != nil {
		t.Fatal(err)
	}
}

// within fails the test when f does not return in time: reading a fifo
// waits for a writer that never comes.
func within(t *testing.T, what string, f func()) {
	t.Helper()
	done := make(chan struct{})
	go func() {
		defer close(done)
		f()
	}()
	select {
	case <-done:
	case <-time.After(10 * time.Second):
		t.Fatalf("%s blocked", what)
	}
}

// The nginx container writes docker/nginx/conf.d as root through a bind
// mount, and the release ships a file there. A link it plants must never
// make kvsctl, root on the host, write a file outside the installation.
func TestSyncReplacesLinksPlantedInAContainerDirectory(t *testing.T) {
	dir := t.TempDir()
	src, root := filepath.Join(dir, "rel"), filepath.Join(dir, "root")
	const conf = "docker/nginx/conf.d/.gitignore"
	shipped := map[string]string{conf: "*.conf\n!.gitignore\n", "docker/setup.sh": "new setup"}
	writeTree(t, src, shipped)
	writeTree(t, root, map[string]string{conf: "old", "docker/setup.sh": "old setup"})
	files := []string{conf, "docker/setup.sh"}
	confDir := filepath.Join(root, "docker/nginx/conf.d")
	// Two legacy temporary names and the file itself.
	planted := map[string]string{}
	for _, name := range []string{".gitignore.kvsctl.tmp", "..gitignore.kvsctl", ".gitignore"} {
		planted[name] = victim(t, dir, name)
		if name == ".gitignore" {
			os.Remove(filepath.Join(confDir, name))
		}
		symlink(t, planted[name], filepath.Join(confDir, name))
	}
	if err := Sync(src, root, files, files); err != nil {
		t.Fatal(err)
	}
	for _, p := range planted {
		untouched(t, p)
	}
	info, err := os.Lstat(filepath.Join(root, conf))
	if err != nil || !info.Mode().IsRegular() {
		t.Fatalf("the release file must replace the link: %v %v", info, err)
	}
	if got, _ := os.ReadFile(filepath.Join(root, conf)); string(got) != shipped[conf] {
		t.Errorf("%s = %q", conf, got)
	}

	// The checksums are read the same way: a link to a file outside that
	// holds the release content is not the file kvsctl laid.
	sums, err := Checksums(root, files)
	if err != nil {
		t.Fatal(err)
	}
	copyOutside := filepath.Join(dir, "outside", "copy")
	if err := os.WriteFile(copyOutside, []byte(shipped[conf]), 0o644); err != nil {
		t.Fatal(err)
	}
	os.Remove(filepath.Join(root, conf))
	symlink(t, copyOutside, filepath.Join(root, conf))
	changed, err := Verify(root, sums)
	if err != nil || !slices.Equal(changed, []string{conf}) {
		t.Errorf("a link in the place of a release file: changed = %v, %v; want it listed", changed, err)
	}
	if _, err := Checksums(root, files); !errors.Is(err, errNotLaid) {
		t.Errorf("the checksums of a link: %v, want a refusal", err)
	}
}

// A directory of the tree replaced by a link to a directory elsewhere is
// refused before anything changes: neither the files laid below it nor the
// files removed from it may be reached through it.
func TestSyncRefusesALinkedDirectory(t *testing.T) {
	dir := t.TempDir()
	src, root := filepath.Join(dir, "rel"), filepath.Join(dir, "root")
	writeTree(t, src, map[string]string{"README.md": "new a", "docker/nginx/conf.d/extra/site.conf": "new site"})
	writeTree(t, root, map[string]string{"README.md": "old a"})
	site := victim(t, dir, "site.conf")
	old := victim(t, dir, "old.conf")
	if err := os.MkdirAll(filepath.Join(root, "docker/nginx/conf.d"), 0o755); err != nil {
		t.Fatal(err)
	}
	symlink(t, filepath.Dir(site), filepath.Join(root, "docker/nginx/conf.d/extra"))
	files := []string{"README.md", "docker/nginx/conf.d/extra/site.conf"}
	previous := []string{"README.md", "docker/nginx/conf.d/extra/old.conf", "docker/nginx/conf.d/extra/site.conf"}
	err := Sync(src, root, files, previous)
	var conflict *ConflictError
	if !errors.As(err, &conflict) || !strings.Contains(err.Error(), "docker/nginx/conf.d/extra is a symbolic link") {
		t.Fatalf("a linked directory must stop the sync, got %v", err)
	}
	untouched(t, site)
	untouched(t, old)
	if got, _ := os.ReadFile(filepath.Join(root, "README.md")); string(got) != "old a" {
		t.Errorf("a refused sync changed README.md to %q", got)
	}

	// Below Sync, a link found on the way is refused too, whoever put it
	// there after Conflicts looked.
	if _, err := remove(root, "docker/nginx/conf.d/extra/old.conf", nil, nil); !errors.Is(err, errNotLaid) {
		t.Errorf("remove through a linked directory: %v", err)
	}
	if err := lay(src, root, "docker/nginx/conf.d/extra/site.conf", false, nil); !errors.Is(err, errNotLaid) {
		t.Errorf("lay through a linked directory: %v", err)
	}
	untouched(t, site)
	untouched(t, old)
}

// A fifo in the place of a release file never stalls check, upgrade or
// rollback: it is not opened.
func TestVerifyDoesNotOpenAFifo(t *testing.T) {
	root := t.TempDir()
	writeTree(t, root, map[string]string{"docker/setup.sh": "setup", "docker/nginx/conf.d/.gitignore": "conf"})
	files := []string{"docker/nginx/conf.d/.gitignore", "docker/setup.sh"}
	sums, err := Checksums(root, files)
	if err != nil {
		t.Fatal(err)
	}
	fifo := filepath.Join(root, "docker/nginx/conf.d/.gitignore")
	os.Remove(fifo)
	if err := unix.Mkfifo(fifo, 0o600); err != nil {
		t.Fatal(err)
	}
	within(t, "Verify on a fifo", func() {
		changed, err := Verify(root, sums)
		if err != nil || !slices.Equal(changed, files[:1]) {
			t.Errorf("a fifo in the place of a release file: changed = %v, %v; want it listed", changed, err)
		}
	})
	within(t, "Checksums on a fifo", func() {
		if _, err := Checksums(root, files); !errors.Is(err, errNotLaid) {
			t.Errorf("the checksums of a fifo: %v, want a refusal", err)
		}
	})
	within(t, "Snapshot of a fifo", func() {
		if err := Snapshot(root, filepath.Join(t.TempDir(), "snap"), files); !errors.Is(err, errNotLaid) {
			t.Errorf("a snapshot of a fifo: %v, want a refusal", err)
		}
	})

	// A directory of the tree that is now a file: what was below it is
	// gone, which is a change, not an error.
	os.RemoveAll(filepath.Join(root, "docker/nginx"))
	writeTree(t, root, map[string]string{"docker/nginx": "a file now"})
	changed, err := Verify(root, sums)
	if err != nil || !slices.Equal(changed, files[:1]) {
		t.Errorf("a file in the place of a directory: changed = %v, %v; want it listed", changed, err)
	}
}

func TestReadBeneath(t *testing.T) {
	dir := t.TempDir()
	root := filepath.Join(dir, "www")
	writeTree(t, root, map[string]string{"admin/include/version.php": "<?php $config['project_version']='6.4.0';"})
	got, err := ReadBeneath(root, "admin/include/version.php", 1024)
	if err != nil || !strings.Contains(string(got), "6.4.0") {
		t.Fatalf("ReadBeneath = %q, %v", got, err)
	}
	if _, err := ReadBeneath(root, "admin/include/version.php", 8); err == nil || !strings.Contains(err.Error(), "larger than 8 bytes") {
		t.Errorf("a file over the limit: %v", err)
	}
	if _, err := ReadBeneath(root, "admin/include/missing.php", 8); !errors.Is(err, os.ErrNotExist) {
		t.Errorf("a missing file: %v", err)
	}
	if _, err := ReadBeneath(root, "../outside/x", 8); err == nil || !strings.Contains(err.Error(), "leaves") {
		t.Errorf("a path leaving the root: %v", err)
	}

	secret := victim(t, dir, "shadow")
	os.Remove(filepath.Join(root, "admin/include/version.php"))
	symlink(t, secret, filepath.Join(root, "admin/include/version.php"))
	if _, err := ReadBeneath(root, "admin/include/version.php", 1024); !errors.Is(err, errNotLaid) {
		t.Errorf("a link to a file outside: %v", err)
	}
	os.RemoveAll(filepath.Join(root, "admin/include"))
	symlink(t, filepath.Dir(secret), filepath.Join(root, "admin/include"))
	if _, err := ReadBeneath(root, "admin/include/shadow", 1024); !errors.Is(err, errNotLaid) {
		t.Errorf("a linked directory: %v", err)
	}
	os.Remove(filepath.Join(root, "admin/include"))
	if err := os.MkdirAll(filepath.Join(root, "admin/include"), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := unix.Mkfifo(filepath.Join(root, "admin/include/version.php"), 0o600); err != nil {
		t.Fatal(err)
	}
	within(t, "ReadBeneath on a fifo", func() {
		if _, err := ReadBeneath(root, "admin/include/version.php", 1024); !errors.Is(err, errNotLaid) {
			t.Errorf("a fifo: %v", err)
		}
	})
	untouched(t, secret)
}

// writeRelease writes the release directory of one version and lists its
// files.
func writeRelease(t *testing.T, dir, version string, files map[string]string) (string, []string) {
	t.Helper()
	src := filepath.Join(dir, version)
	writeTree(t, src, files)
	var list []string
	for f := range files {
		list = append(list, f)
	}
	slices.Sort(list)
	return src, list
}

func mkdir(t *testing.T, p string) string {
	t.Helper()
	if err := os.MkdirAll(p, 0o755); err != nil {
		t.Fatal(err)
	}
	return p
}

func content(t *testing.T, p string) string {
	t.Helper()
	got, err := os.ReadFile(p)
	if err != nil {
		t.Errorf("%v", err)
	}
	return string(got)
}

// A release that turns a file into a directory, or a directory into a file,
// lays, and its rollback lays the previous set back.
func TestSyncChangesTheTypeOfAPath(t *testing.T) {
	dir := t.TempDir()
	root := mkdir(t, filepath.Join(dir, "root"))
	v1, files1 := writeRelease(t, dir, "1", map[string]string{"conf/extra": "v1 extra", "docker/setup.sh": "v1"})
	v2, files2 := writeRelease(t, dir, "2", map[string]string{"conf/extra/site.conf": "v2 site", "docker/setup.sh": "v2"})
	if err := Sync(v1, root, files1, nil); err != nil {
		t.Fatal(err)
	}
	// File to directory.
	if err := Sync(v2, root, files2, files1); err != nil {
		t.Fatalf("a file that becomes a directory: %v", err)
	}
	if got := content(t, filepath.Join(root, "conf/extra/site.conf")); got != "v2 site" {
		t.Errorf("conf/extra/site.conf = %q", got)
	}
	// Directory to file, which is also the rollback of the step above.
	if err := Sync(v1, root, files1, files2); err != nil {
		t.Fatalf("a directory that becomes a file: %v", err)
	}
	if got := content(t, filepath.Join(root, "conf/extra")); got != "v1 extra" {
		t.Errorf("conf/extra = %q", got)
	}
}

// The upgrade that fails half way through a type change leaves a tree its
// rollback lays the previous set over, so recover never wedges.
func TestSyncRollsBackAHalfLaidTypeChange(t *testing.T) {
	dir := t.TempDir()
	root := mkdir(t, filepath.Join(dir, "root"))
	v1, files1 := writeRelease(t, dir, "1", map[string]string{"conf/extra": "v1 extra", "docker/z.sh": "v1"})
	v2, files2 := writeRelease(t, dir, "2", map[string]string{"conf/extra/site.conf": "v2 site", "docker/z.sh": "v2"})
	if err := Sync(v1, root, files1, nil); err != nil {
		t.Fatal(err)
	}
	stubFlushes(t, func(f *os.File) error {
		if content(t, f.Name()) == "v2" {
			return errors.New("no space left on device")
		}
		return f.Sync()
	}, func(string) error { return nil })
	if err := Sync(v2, root, files2, files1); err == nil || !strings.Contains(err.Error(), "no space left") {
		t.Fatalf("the half laid upgrade: %v", err)
	}
	stubFlushes(t, func(f *os.File) error { return f.Sync() }, func(string) error { return nil })
	if err := Sync(v1, root, files1, files2); err != nil {
		t.Fatalf("the rollback of a half laid type change: %v", err)
	}
	if got := content(t, filepath.Join(root, "conf/extra")); got != "v1 extra" {
		t.Errorf("conf/extra = %q", got)
	}
	if got := content(t, filepath.Join(root, "docker/z.sh")); got != "v1" {
		t.Errorf("docker/z.sh = %q", got)
	}
}

// A journal identifies the exact temporary to reclaim. Other names stay,
// even when their spelling matches a temporary created by an older build.
func TestJournalTemporaryCleanup(t *testing.T) {
	root, src := t.TempDir(), t.TempDir()
	const name = "conf/policy.xml"
	writeTree(t, src, map[string]string{name: "release"})
	local := map[string]string{"conf/.kvsctl-123": "local", "conf/.policy.xml.kvsctl": "fixed", "conf/.policy.xml.kvsctl-0123456789abcdef": "lookalike"}
	writeTree(t, root, local)
	var last string
	for range 2 {
		var pending PendingCopy
		journal := &SyncJournal{
			Pending: func(copy PendingCopy) error {
				if copy.File != name || copy.Temporary == last {
					t.Fatalf("pending %+v, previous %q", copy, last)
				}
				info, err := os.Lstat(filepath.Join(root, copy.Temporary))
				if err != nil || !info.Mode().IsRegular() || info.Size() != 0 {
					t.Fatalf("journal must identify an empty reservation before copying: %v %v", info, err)
				}
				pending = copy
				return nil
			},
			Created: func(string) error { return nil },
		}
		stubFlushes(t, func(f *os.File) error {
			full, err := filepath.EvalSymlinks(f.Name())
			if err != nil || filepath.Join(root, pending.Temporary) != full {
				t.Fatalf("unrecorded temporary %s: %v", full, err)
			}
			return f.Sync()
		}, func(string) error { return nil })
		if err := SyncWithJournal(src, root, []string{name}, nil, journal); err != nil {
			t.Fatal(err)
		}
		tmp := filepath.Join(root, pending.Temporary)
		writeTree(t, root, map[string]string{pending.Temporary: "reused by operator"})
		if err := RemovePending(root, pending); err != nil || content(t, tmp) != "reused by operator" {
			t.Fatalf("reused name: %v", err)
		}
		if err := os.Rename(filepath.Join(root, name), tmp); err != nil {
			t.Fatal(err)
		}
		if err := RemovePending(root, pending); err != nil {
			t.Fatal(err)
		}
		if _, err := os.Lstat(tmp); !os.IsNotExist(err) {
			t.Fatalf("temporary remains: %v", err)
		}
		last = pending.Temporary
	}
	for file, want := range local {
		if got := content(t, filepath.Join(root, file)); got != want {
			t.Errorf("%s: %q", file, got)
		}
	}
}

func TestNewReleaseEntryRefusals(t *testing.T) {
	const name = "conf/policy.xml"
	for _, kind := range []string{"link", "dangling link", "directory", "fifo", "late file"} {
		t.Run(kind, func(t *testing.T) {
			root, src := t.TempDir(), t.TempDir()
			writeTree(t, root, map[string]string{"conf/local": "local", "conf/obsolete": "old"})
			writeTree(t, src, map[string]string{name: "release"})
			dest := filepath.Join(root, name)
			var err error
			switch kind {
			case "link":
				err = os.Symlink("local", dest)
			case "dangling link":
				err = os.Symlink("absent", dest)
			case "directory":
				err = os.Mkdir(dest, 0700)
			case "fifo":
				err = unix.Mkfifo(dest, 0600)
			case "late file":
				stubFlushes(t, func(f *os.File) error { return os.WriteFile(dest, []byte("late"), 0600) }, func(string) error { return nil })
			}
			if err != nil {
				t.Fatal(err)
			}
			if kind != "late file" && len(Conflicts(root, []string{name}, []string{"conf/obsolete"})) == 0 {
				t.Fatal("preflight accepted local entry")
			}
			err = Sync(src, root, []string{name}, []string{"conf/obsolete"})
			if err == nil || !strings.Contains(err.Error(), name) {
				t.Fatalf("unmanaged entry: %v", err)
			}
			if kind == "late file" {
				if content(t, dest) != "late" {
					t.Fatal("late file overwritten")
				}
			} else if !exists(filepath.Join(root, "conf/obsolete")) {
				t.Fatal("preflight changed the tree")
			}
		})
	}
}

// A file named like a temporary file of kvsctl's, with a suffix createTemp
// never writes, is the operator's: a release that turns its directory into
// a file names it, and deletes nothing.
func TestSyncNamesAnOperatorFileNamedLikeATemporary(t *testing.T) {
	dir := t.TempDir()
	v2, files2 := writeRelease(t, dir, "2", map[string]string{"conf/extra": "v2 extra"})
	for _, name := range []string{".site.conf.kvsctl", ".site.conf.kvsctl-09f3c2a17b4e6d58", ".site.conf.kvsctl-old", ".site.conf.kvsctl-backup2026", ".site.conf.kvsctl-20261007"} {
		root := mkdir(t, filepath.Join(t.TempDir(), "root"))
		writeTree(t, root, map[string]string{"conf/extra/site.conf": "v1 site", "conf/extra/" + name: "the operator's"})
		held := filepath.Join(root, "conf/extra", name)
		if err := Sync(v2, root, files2, []string{"conf/extra/site.conf"}); err == nil || !strings.Contains(err.Error(), "it holds "+held+", which the release does not ship") {
			t.Errorf("%s: %v, want the file named", name, err)
		}
		if got := content(t, held); got != "the operator's" {
			t.Errorf("%s = %q", name, got)
		}
	}
}

// Removing an obsolete file leaves its unrecorded neighbors alone.
func TestSyncKeepsUnrecordedTemporariesOfARemovedFile(t *testing.T) {
	dir := t.TempDir()
	_, files1 := writeRelease(t, dir, "1", map[string]string{"conf/extra": "v1 extra", "docker/setup.sh": "v1"})
	v2, files2 := writeRelease(t, dir, "2", map[string]string{"conf/extra/site.conf": "v2 site", "docker/setup.sh": "v2"})
	root := mkdir(t, filepath.Join(dir, "root"))
	if err := Sync(v2, root, files2, nil); err != nil {
		t.Fatal(err)
	}
	// The upgrade to 1 removed conf/extra/site.conf and its directory, and
	// was killed while it laid conf/extra.
	os.RemoveAll(filepath.Join(root, "conf/extra"))
	writeTree(t, root, map[string]string{"conf/.extra.kvsctl": "v1 ex", "conf/.extra.kvsctl-00000000000001a9": "v1"})
	if err := Sync(v2, root, files2, files1); err != nil {
		t.Fatalf("the rollback of a killed type change: %v", err)
	}
	if got := names(t, filepath.Join(root, "conf")); !slices.Equal(got, []string{".extra.kvsctl", ".extra.kvsctl-00000000000001a9", "extra"}) {
		t.Errorf("conf/ holds %q, want both local files and the release directory", got)
	}
	if got := content(t, filepath.Join(root, "conf/extra/site.conf")); got != "v2 site" {
		t.Errorf("conf/extra/site.conf = %q", got)
	}

	// A release that drops conf/extra/site.conf, beside empty directories
	// of the operator's under its temporary names.
	v3, files3 := writeRelease(t, dir, "3", map[string]string{"conf/extra/other.conf": "v3 other", "docker/setup.sh": "v3"})
	for _, held := range []string{".site.conf.kvsctl", ".site.conf.kvsctl-09f3c2a17b4e6d58"} {
		mkdir(t, filepath.Join(root, "conf/extra", held))
	}
	if err := Sync(v3, root, files3, files2); err != nil {
		t.Fatalf("a release that drops a file: %v", err)
	}
	if got := names(t, filepath.Join(root, "conf/extra")); !slices.Equal(got, []string{".site.conf.kvsctl", ".site.conf.kvsctl-09f3c2a17b4e6d58", "other.conf"}) {
		t.Errorf("conf/extra holds %q, want the directories of the operator's beside other.conf", got)
	}
}

// An upgrade refused before it laid anything, or cut before it removed a
// file, is rolled back over a tree that still holds the previous set: the
// files of the new set it removes are below paths that are files again, or
// still, and are gone already. That is no error, or every recover of such
// an upgrade would fail the same way.
func TestSyncRollsBackAnUpgradeThatLaidNothing(t *testing.T) {
	dir := t.TempDir()
	root := mkdir(t, filepath.Join(dir, "root"))
	v1, files1 := writeRelease(t, dir, "1", map[string]string{"conf/extra": "v1 extra", "conf/deep": "v1 deep", "docker/setup.sh": "v1"})
	v2, files2 := writeRelease(t, dir, "2", map[string]string{
		"conf/extra/site.conf": "v2 site", "conf/deep/sub/site.conf": "v2 deep",
		"docker/custom/extra.conf": "v2 custom", "docker/setup.sh": "v2",
	})
	if err := Sync(v1, root, files1, nil); err != nil {
		t.Fatal(err)
	}
	writeTree(t, root, map[string]string{"docker/custom": "the operator's"})
	var conflict *ConflictError
	if err := Sync(v2, root, files2, files1); !errors.As(err, &conflict) {
		t.Fatalf("the upgrade = %v, want it refused", err)
	}
	if err := Sync(v1, root, files1, slices.Concat(files1, files2)); err != nil {
		t.Fatalf("the rollback of an upgrade that laid nothing: %v", err)
	}
	for f, want := range map[string]string{"conf/extra": "v1 extra", "conf/deep": "v1 deep", "docker/setup.sh": "v1", "docker/custom": "the operator's"} {
		if got := content(t, filepath.Join(root, f)); got != want {
			t.Errorf("%s = %q, want %q", f, got, want)
		}
	}
}

// A directory of the operator's, even an empty one, below a directory of
// the release that becomes a file would stay where the file goes: it is
// named before anything changes. A directory that only holds release files
// is no obstacle.
func TestConflictsNameADirectoryOfTheOperator(t *testing.T) {
	dir := t.TempDir()
	root := mkdir(t, filepath.Join(dir, "root"))
	v1, files1 := writeRelease(t, dir, "1", map[string]string{"conf/menu/a.conf": "v1 a", "conf/menu/sub/b.conf": "v1 b"})
	v2, files2 := writeRelease(t, dir, "2", map[string]string{"conf/menu": "v2 menu"})
	if err := Sync(v1, root, files1, nil); err != nil {
		t.Fatal(err)
	}
	if got := Conflicts(root, files2, files1); len(got) != 0 {
		t.Errorf("Conflicts = %q, want none: conf/menu only holds release files", got)
	}
	drafts := mkdir(t, filepath.Join(root, "conf/menu/drafts"))
	want := []string{filepath.Join(root, "conf/menu") + " is a directory, where the release lays a file, and it holds " + drafts + ", which the release does not ship: move it away"}
	if got := Conflicts(root, files2, files1); !slices.Equal(got, want) {
		t.Errorf("Conflicts =\n%q\nwant\n%q", got, want)
	}
	var conflict *ConflictError
	if err := Sync(v2, root, files2, files1); !errors.As(err, &conflict) {
		t.Fatalf("Sync = %v, want the conflict", err)
	}
	if got := content(t, filepath.Join(root, "conf/menu/a.conf")); got != "v1 a" {
		t.Errorf("a refused sync changed conf/menu/a.conf to %q", got)
	}
	os.Remove(drafts)
	if err := Sync(v2, root, files2, files1); err != nil {
		t.Fatal(err)
	}
	if got := content(t, filepath.Join(root, "conf/menu")); got != "v2 menu" {
		t.Errorf("conf/menu = %q", got)
	}
}

// WriteFile hands its prepare step what stands at the name it replaces,
// read without following a link: the file it replaces, not the new one,
// and nothing for a name that holds nothing yet.
func TestWriteFileHandsPrepareWhatItReplaces(t *testing.T) {
	dir := t.TempDir()
	root := mkdir(t, filepath.Join(dir, "root"))
	writeTree(t, root, map[string]string{"docker/.env": "A=1\n"})
	lstat := func(p string) unix.Stat_t {
		t.Helper()
		var st unix.Stat_t
		if err := unix.Lstat(p, &st); err != nil {
			t.Fatal(err)
		}
		return st
	}
	var replaced *unix.Stat_t
	var made uint64
	prepare := func(f *os.File, r *unix.Stat_t) error {
		replaced = r
		var st unix.Stat_t
		if err := unix.Fstat(int(f.Fd()), &st); err != nil {
			return err
		}
		made = st.Ino
		return nil
	}
	env := filepath.Join(root, "docker/.env")
	before := lstat(env)
	if err := WriteFile(root, "docker/.env", []byte("A=2\n"), 0o600, prepare); err != nil {
		t.Fatal(err)
	}
	if replaced == nil || replaced.Ino != before.Ino || replaced.Ino == made {
		t.Errorf("prepare got %+v, want the file replaced (inode %d), not the new one (inode %d)", replaced, before.Ino, made)
	}
	if err := WriteFile(root, "docker/new", []byte("B=1\n"), 0o600, prepare); err != nil || replaced != nil {
		t.Errorf("a new name: %v, prepare got %+v, want nothing", err, replaced)
	}
	target := victim(t, dir, "env")
	os.Remove(env)
	symlink(t, target, env)
	link := lstat(env)
	if err := WriteFile(root, "docker/.env", []byte("A=3\n"), 0o600, prepare); err != nil {
		t.Fatal(err)
	}
	if replaced == nil || replaced.Ino != link.Ino || replaced.Mode&unix.S_IFMT != unix.S_IFLNK {
		t.Errorf("prepare got %+v, want the link itself (inode %d)", replaced, link.Ino)
	}
	untouched(t, target)
}

// What the operator keeps where the release needs the place stops the sync
// before it changes anything, with what to move.
func TestSyncRefusesWhatTheOperatorKeepsInTheWay(t *testing.T) {
	dir := t.TempDir()
	root := mkdir(t, filepath.Join(dir, "root"))
	v1, files1 := writeRelease(t, dir, "1", map[string]string{"README.md": "v1", "conf/site/kvs.conf": "v1 site"})
	v2, files2 := writeRelease(t, dir, "2", map[string]string{"README.md": "v2", "conf/site": "v2 site", "docker/custom/extra.conf": "v2 custom"})
	if err := Sync(v1, root, files1, nil); err != nil {
		t.Fatal(err)
	}
	writeTree(t, root, map[string]string{"docker/custom": "the operator's", "conf/site/mine.conf": "the operator's"})
	want := []string{
		filepath.Join(root, "conf/site") + " is a directory, where the release lays a file, and it holds " + filepath.Join(root, "conf/site/mine.conf") + ", which the release does not ship: move it away",
		filepath.Join(root, "docker/custom") + " is a file, where the release needs a directory for docker/custom/extra.conf: move it away",
	}
	if got := Conflicts(root, files2, files1); !slices.Equal(got, want) {
		t.Errorf("Conflicts =\n%q\nwant\n%q", got, want)
	}
	err := Sync(v2, root, files2, files1)
	var conflict *ConflictError
	if !errors.As(err, &conflict) || !slices.Equal(conflict.Problems, want) {
		t.Fatalf("Sync = %v, want the conflicts", err)
	}
	if got := content(t, filepath.Join(root, "README.md")); got != "v1" {
		t.Errorf("a refused sync changed README.md to %q", got)
	}
	if got := content(t, filepath.Join(root, "conf/site/kvs.conf")); got != "v1 site" {
		t.Errorf("a refused sync changed conf/site/kvs.conf to %q", got)
	}
	// Once they are moved away, the same sync lays.
	os.Remove(filepath.Join(root, "docker/custom"))
	os.Remove(filepath.Join(root, "conf/site/mine.conf"))
	if got := Conflicts(root, files2, files1); len(got) != 0 {
		t.Errorf("Conflicts = %q, want none", got)
	}
	if err := Sync(v2, root, files2, files1); err != nil {
		t.Fatal(err)
	}
	if got := content(t, filepath.Join(root, "conf/site")); got != "v2 site" {
		t.Errorf("conf/site = %q", got)
	}
}

// An obsolete file whose place now holds a directory of the operator's
// leaves the directory alone, and the directories the new set needs stay
// with their mode.
func TestSyncLeavesWhatIsNotTheRelease(t *testing.T) {
	dir := t.TempDir()
	root := mkdir(t, filepath.Join(dir, "root"))
	v1, files1 := writeRelease(t, dir, "1", map[string]string{"conf/old.conf": "v1", "conf/sub/gone.conf": "v1"})
	v2, files2 := writeRelease(t, dir, "2", map[string]string{"conf/new.conf": "v2"})
	if err := Sync(v1, root, files1, nil); err != nil {
		t.Fatal(err)
	}
	os.Remove(filepath.Join(root, "conf/old.conf"))
	writeTree(t, root, map[string]string{"conf/old.conf/mine": "the operator's"})
	if err := os.Chmod(filepath.Join(root, "conf"), 0o750); err != nil {
		t.Fatal(err)
	}
	if err := Sync(v2, root, files2, files1); err != nil {
		t.Fatal(err)
	}
	if got := content(t, filepath.Join(root, "conf/old.conf/mine")); got != "the operator's" {
		t.Errorf("the operator's file = %q", got)
	}
	if _, err := os.Lstat(filepath.Join(root, "conf/sub")); !errors.Is(err, os.ErrNotExist) {
		t.Errorf("the directory the obsolete files leave empty must go: %v", err)
	}
	info, err := os.Stat(filepath.Join(root, "conf"))
	if err != nil || info.Mode().Perm() != 0o750 {
		t.Errorf("a directory the new set needs must stay as it is: %v %v", info.Mode(), err)
	}
}

// Both writers leave unrecorded temporaries untouched.
func TestTemporaryFilesOfAKilledRunAndOfAnotherWriter(t *testing.T) {
	dir := t.TempDir()
	src, root := filepath.Join(dir, "rel"), mkdir(t, filepath.Join(dir, "root"))
	writeTree(t, src, map[string]string{"docker/setup.sh": "new"})
	writeTree(t, root, map[string]string{"docker/setup.sh": "old", "docker/.setup.sh.kvsctl": "left by a killed run"})
	if err := Sync(src, root, []string{"docker/setup.sh"}, []string{"docker/setup.sh"}); err != nil {
		t.Fatal(err)
	}
	if got := names(t, filepath.Join(root, "docker")); !slices.Equal(got, []string{".setup.sh.kvsctl", "setup.sh"}) {
		t.Errorf("docker/ holds %q, want the release file and its local neighbor", got)
	}

	writeTree(t, root, map[string]string{"kvsctl/updates.json": "{}", "kvsctl/.updates.json.kvsctl": "another kvsctl is writing this"})
	if err := WriteFile(root, "kvsctl/updates.json", []byte(`{"checks":{}}`), 0o600, nil); err != nil {
		t.Fatal(err)
	}
	if got := content(t, filepath.Join(root, "kvsctl/.updates.json.kvsctl")); got != "another kvsctl is writing this" {
		t.Errorf("WriteFile took the temporary file of another writer: %q", got)
	}
	if got := content(t, filepath.Join(root, "kvsctl/updates.json")); got != `{"checks":{}}` {
		t.Errorf("updates.json = %q", got)
	}
	if got := names(t, filepath.Join(root, "kvsctl")); !slices.Equal(got, []string{".updates.json.kvsctl", "updates.json"}) {
		t.Errorf("kvsctl/ holds %q, want updates.json and the file of the other writer", got)
	}
}

// names lists the entries of dir, sorted.
func names(t *testing.T, dir string) []string {
	t.Helper()
	entries, err := os.ReadDir(dir)
	if err != nil {
		t.Fatal(err)
	}
	var out []string
	for _, e := range entries {
		out = append(out, e.Name())
	}
	return out
}

func TestNewFilePublicationFallback(t *testing.T) {
	const file = "conf/policy.xml"
	for _, tc := range []struct {
		name                        string
		renameErr, linkErr, wantErr error
		late                        bool
	}{
		{name: "ENOSYS", renameErr: unix.ENOSYS},
		{name: "EINVAL", renameErr: unix.EINVAL},
		{name: "ENOTSUP", renameErr: unix.ENOTSUP},
		{name: "EOPNOTSUPP", renameErr: unix.EOPNOTSUPP},
		{name: "late file", renameErr: unix.ENOSYS, wantErr: unix.EEXIST, late: true},
		{name: "link unsupported", renameErr: unix.ENOSYS, linkErr: unix.EOPNOTSUPP, wantErr: unix.EOPNOTSUPP},
		{name: "permission denied", renameErr: unix.EACCES, wantErr: unix.EACCES},
		{name: "existing entry", renameErr: unix.EEXIST, wantErr: unix.EEXIST},
	} {
		t.Run(tc.name, func(t *testing.T) {
			root, src := t.TempDir(), t.TempDir()
			writeTree(t, src, map[string]string{file: "release"})
			oldRename, oldLink := renameNew, linkNew
			t.Cleanup(func() { renameNew, linkNew = oldRename, oldLink })
			renameNew = func(fromFD int, from string, toFD int, to string, flags uint) error {
				if flags != unix.RENAME_NOREPLACE {
					t.Fatalf("rename flags = %v", flags)
				}
				if tc.late {
					writeTree(t, root, map[string]string{file: "local"})
				}
				return tc.renameErr
			}
			var pending PendingCopy
			linkCalled := false
			linkNew = func(fromFD int, from string, toFD int, to string, flags int) error {
				linkCalled = true
				if fromFD != toFD || from != filepath.Base(pending.Temporary) || to != filepath.Base(file) || flags != 0 {
					t.Fatalf("linkat arguments: %d, %q, %d, %q, %d", fromFD, from, toFD, to, flags)
				}
				if tc.linkErr != nil {
					return tc.linkErr
				}
				if err := unix.Linkat(fromFD, from, toFD, to, flags); err != nil {
					return err
				}
				var final unix.Stat_t
				if err := unix.Stat(filepath.Join(root, file), &final); err != nil {
					t.Fatal(err)
				}
				if pending.File != file || final.Nlink != 2 || uint64(final.Dev) != pending.Device || final.Ino != pending.Inode {
					t.Fatalf("linked file does not share the journaled temporary: %+v, links %d", pending, final.Nlink)
				}
				return nil
			}
			created := false
			journal := &SyncJournal{
				Pending: func(copy PendingCopy) error { pending = copy; return nil },
				Created: func(rel string) error {
					if rel != file || exists(filepath.Join(root, pending.Temporary)) {
						t.Fatal("creation recorded before temporary cleanup")
					}
					created = true
					return nil
				},
			}
			err := SyncWithJournal(src, root, []string{file}, nil, journal)
			wantLink := tc.renameErr != unix.EACCES && tc.renameErr != unix.EEXIST
			if linkCalled != wantLink {
				t.Fatalf("linkat called = %v, want %v", linkCalled, wantLink)
			}
			if !errors.Is(err, tc.wantErr) || (err != nil && !strings.Contains(err.Error(), file)) {
				t.Fatalf("publish: %v, want %v for %s", err, tc.wantErr, file)
			}
			if created != (err == nil) || exists(filepath.Join(root, pending.Temporary)) {
				t.Fatalf("unexpected publication state: created=%v, pending=%+v", created, pending)
			}
			dest := filepath.Join(root, file)
			switch {
			case tc.late:
				if got := content(t, dest); got != "local" {
					t.Fatalf("late file = %q", got)
				}
			case err == nil:
				if got := content(t, dest); got != "release" {
					t.Fatalf("published file = %q", got)
				}
			case exists(dest):
				t.Fatal("failed publication left a final file")
			}
		})
	}
}

func TestSyncReplacesEmptyManagedAncestor(t *testing.T) {
	for _, remaining := range []string{"conf/extra", "conf/extra/nested", "conf/extra/nested/deeper"} {
		t.Run(remaining, func(t *testing.T) {
			const file = "conf/extra"
			root, src := t.TempDir(), t.TempDir()
			old := []string{"conf/obsolete", "conf/extra/nested/deeper/old.conf"}
			writeTree(t, root, map[string]string{old[0]: "previous release"})
			writeTree(t, src, map[string]string{file: "present release"})
			local := mkdir(t, filepath.Join(root, remaining, "local"))
			var conflict *ConflictError
			if err := Sync(src, root, []string{file}, old); !errors.As(err, &conflict) || !strings.Contains(err.Error(), local) {
				t.Fatalf("preflight with a local entry: %v", err)
			}
			if got := content(t, filepath.Join(root, old[0])); got != "previous release" {
				t.Fatalf("preflight changed the obsolete file: %q", got)
			}
			if err := os.Remove(local); err != nil {
				t.Fatal(err)
			}
			if problems := Conflicts(root, []string{file}, old); len(problems) != 0 {
				t.Fatal(problems)
			}
			if err := Sync(src, root, []string{file}, old); err != nil {
				t.Fatal(err)
			}
			if got := content(t, filepath.Join(root, file)); got != "present release" {
				t.Fatalf("published file = %q", got)
			}
		})
	}
}

func TestSyncPublishesMaxLengthName(t *testing.T) {
	root, src := t.TempDir(), t.TempDir()
	file := "conf/" + strings.Repeat("x", 255)
	writeTree(t, src, map[string]string{file: "release"})
	if err := Sync(src, root, []string{file}, nil); err != nil {
		t.Fatal(err)
	}
	if got := content(t, filepath.Join(root, file)); got != "release" {
		t.Fatalf("published file = %q", got)
	}
}
