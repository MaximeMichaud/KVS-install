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
	// The temporary name kvsctl used, the first one it uses now, which
	// anyone can predict, and the file itself.
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
	writeTree(t, src, map[string]string{"a.txt": "new a", "docker/nginx/conf.d/extra/site.conf": "new site"})
	writeTree(t, root, map[string]string{"a.txt": "old a"})
	site := victim(t, dir, "site.conf")
	old := victim(t, dir, "old.conf")
	if err := os.MkdirAll(filepath.Join(root, "docker/nginx/conf.d"), 0o755); err != nil {
		t.Fatal(err)
	}
	symlink(t, filepath.Dir(site), filepath.Join(root, "docker/nginx/conf.d/extra"))
	files := []string{"a.txt", "docker/nginx/conf.d/extra/site.conf"}
	previous := []string{"a.txt", "docker/nginx/conf.d/extra/old.conf", "docker/nginx/conf.d/extra/site.conf"}
	err := Sync(src, root, files, previous)
	var conflict *ConflictError
	if !errors.As(err, &conflict) || !strings.Contains(err.Error(), "docker/nginx/conf.d/extra is a symbolic link") {
		t.Fatalf("a linked directory must stop the sync, got %v", err)
	}
	untouched(t, site)
	untouched(t, old)
	if got, _ := os.ReadFile(filepath.Join(root, "a.txt")); string(got) != "old a" {
		t.Errorf("a refused sync changed a.txt to %q", got)
	}

	// Below Sync, a link found on the way is refused too, whoever put it
	// there after Conflicts looked.
	if _, err := remove(root, "docker/nginx/conf.d/extra/old.conf", nil); !errors.Is(err, errNotLaid) {
		t.Errorf("remove through a linked directory: %v", err)
	}
	if err := lay(src, root, "docker/nginx/conf.d/extra/site.conf"); !errors.Is(err, errNotLaid) {
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
		if strings.Contains(f.Name(), "z.sh") {
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

// A run killed while it laid a file leaves its temporary file beside it.
// When that file is in a directory that replaced a file of the release in
// place, the recover lays the file back there: the temporary file is
// kvsctl's own, not something the operator keeps, and goes with the
// directory. A temporary file of a file the release does not lay there, or
// a directory under such a name, is not kvsctl's, and is named.
func TestSyncRecoversFromAKillDuringATypeChange(t *testing.T) {
	dir := t.TempDir()
	v1, files1 := writeRelease(t, dir, "1", map[string]string{"conf/extra": "v1 extra", "conf/deep": "v1 deep", "docker/setup.sh": "v1"})
	v2, files2 := writeRelease(t, dir, "2", map[string]string{"conf/extra/site.conf": "v2 site", "conf/deep/sub/a.conf": "v2 a", "docker/setup.sh": "v2"})
	// The tree a SIGKILL leaves while the upgrade laid conf/extra/site.conf,
	// after a run that found the first name taken laid conf/deep/sub/a.conf
	// up to its rename.
	killed := func(t *testing.T) string {
		t.Helper()
		root := mkdir(t, filepath.Join(t.TempDir(), "root"))
		if err := Sync(v1, root, files1, nil); err != nil {
			t.Fatal(err)
		}
		os.Remove(filepath.Join(root, "conf/extra"))
		os.Remove(filepath.Join(root, "conf/deep"))
		writeTree(t, root, map[string]string{
			"conf/extra/.site.conf.kvsctl":                  "v2 s",
			"conf/deep/sub/.a.conf.kvsctl-09f3c2a17b4e6d58": "v2 a",
		})
		return root
	}
	root := killed(t)
	if got := Conflicts(root, files1, files2); len(got) != 0 {
		t.Errorf("Conflicts = %q, want none: the temporary files are kvsctl's", got)
	}
	if err := Sync(v1, root, files1, files2); err != nil {
		t.Fatalf("the rollback of an upgrade killed while it laid a file: %v", err)
	}
	for f, want := range map[string]string{"conf/extra": "v1 extra", "conf/deep": "v1 deep", "docker/setup.sh": "v1"} {
		if got := content(t, filepath.Join(root, f)); got != want {
			t.Errorf("%s = %q, want %q", f, got, want)
		}
	}

	// The upgrade itself, run again over the same tree, lays its files.
	root = killed(t)
	if err := Sync(v2, root, files2, files1); err != nil {
		t.Fatalf("the upgrade run again over a killed one: %v", err)
	}
	if got := names(t, filepath.Join(root, "conf/extra")); !slices.Equal(got, []string{"site.conf"}) {
		t.Errorf("conf/extra holds %q, want site.conf alone", got)
	}

	// What kvsctl does not lay there is the operator's: a name createTemp
	// never gives, its random number of another width or written with a
	// capital, is no temporary file of kvsctl's.
	for _, planted := range []string{"conf/extra/.mine.conf.kvsctl", "conf/extra/.site.conf.kvsctl/x", "conf/extra/.site.conf.kvsctl-NOT",
		"conf/extra/.site.conf.kvsctl-backup2026", "conf/extra/.site.conf.kvsctl-old", "conf/extra/.site.conf.kvsctl-09F3C2A17B4E6D58",
		"conf/extra/.site.conf.kvsctl-09f3c2a17b4e6d5", "conf/extra/.site.conf.kvsctl-09f3c2a17b4e6d580"} {
		root = killed(t)
		held := filepath.Join(root, strings.TrimSuffix(planted, "/x"))
		if held != filepath.Join(root, planted) {
			// A directory under the name of the temporary file.
			os.Remove(held)
		}
		writeTree(t, root, map[string]string{planted: "the operator's"})
		want := []string{filepath.Join(root, "conf/extra") + " is a directory, where the release lays a file, and it holds " + held + ", which the release does not ship: move it away"}
		if got := Conflicts(root, files1, files2); !slices.Equal(got, want) {
			t.Errorf("%s: Conflicts =\n%q\nwant\n%q", planted, got, want)
		}
	}
}

// Every name createTemp gives is taken for a temporary file of kvsctl's:
// the first one, and 16 hexadecimal digits after a dash. A name of another
// shape is the operator's, a suffix of a few letters or a date included.
func TestTemporaryNames(t *testing.T) {
	for _, entry := range []string{".site.conf.kvsctl", ".site.conf.kvsctl-0000000000000000", ".site.conf.kvsctl-09f3c2a17b4e6d58", ".site.conf.kvsctl-ffffffffffffffff"} {
		if !temporaryOf(entry, "site.conf") {
			t.Errorf("%s is a name createTemp gives site.conf", entry)
		}
	}
	for _, entry := range []string{".site.conf.kvsctl-", ".site.conf.kvsctlx", ".site.conf.kvsctl-09f3c2a17b4e6d58.bak", ".other.conf.kvsctl", "site.conf.kvsctl",
		".site.conf.kvsctl-old", ".site.conf.kvsctl-0", ".site.conf.kvsctl-20261007", ".site.conf.kvsctl-x8kq0", ".site.conf.kvsctl-09F3C2A17B4E6D58",
		".site.conf.kvsctl-09f3c2a17b4e6d5", ".site.conf.kvsctl-09f3c2a17b4e6d580", ".site.conf.kvsctl-09f3c2a17b4e6d5g"} {
		if temporaryOf(entry, "site.conf") {
			t.Errorf("%s is no name createTemp gives site.conf", entry)
		}
	}
	// The names createTemp writes, past the first one taken.
	dir := t.TempDir()
	fd, err := unix.Open(dir, unix.O_RDONLY|unix.O_DIRECTORY|unix.O_CLOEXEC, 0)
	if err != nil {
		t.Fatal(err)
	}
	defer unix.Close(fd)
	for range 20 {
		name, f, err := createTemp(fd, "site.conf", dir, false)
		if err != nil {
			t.Fatal(err)
		}
		f.Close()
		if !temporaryOf(name, "site.conf") || len(name) != len(tempName("site.conf"))+1+tempSuffixLen {
			t.Errorf("createTemp named a temporary file %s", name)
		}
	}
}

// A file named like a temporary file of kvsctl's, with a suffix createTemp
// never writes, is the operator's: a release that turns its directory into
// a file names it, and deletes nothing.
func TestSyncNamesAnOperatorFileNamedLikeATemporary(t *testing.T) {
	dir := t.TempDir()
	v2, files2 := writeRelease(t, dir, "2", map[string]string{"conf/extra": "v2 extra"})
	for _, name := range []string{".site.conf.kvsctl-old", ".site.conf.kvsctl-backup2026", ".site.conf.kvsctl-20261007"} {
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

// A temporary name is kvsctl's only beside the release file it is the
// temporary file of: in another directory, it is the operator's.
func TestConflictsNamesATemporaryNameOfAnotherDirectory(t *testing.T) {
	dir := t.TempDir()
	_, files1 := writeRelease(t, dir, "1", map[string]string{"conf/extra": "v1 extra"})
	_, files2 := writeRelease(t, dir, "2", map[string]string{"conf/extra/a.conf": "v2 a", "conf/extra/sub/b.conf": "v2 b"})
	root := mkdir(t, filepath.Join(dir, "root"))
	writeTree(t, root, map[string]string{
		"conf/extra/a.conf":                              "v2 a",
		"conf/extra/.a.conf.kvsctl-09f3c2a17b4e6d58":     "v2 a, cut short",
		"conf/extra/sub/b.conf":                          "v2 b",
		"conf/extra/sub/.a.conf.kvsctl":                  "the operator's",
		"conf/extra/sub/.b.conf.kvsctl-09f3c2a17b4e6d58": "v2 b, cut short",
	})
	want := []string{filepath.Join(root, "conf/extra") + " is a directory, where the release lays a file, and it holds " + filepath.Join(root, "conf/extra/sub/.a.conf.kvsctl") + ", which the release does not ship: move it away"}
	if got := Conflicts(root, files1, files2); !slices.Equal(got, want) {
		t.Errorf("Conflicts =\n%q\nwant\n%q", got, want)
	}
}

// The temporary file of a release file that the next set drops is taken
// away with it: no later lay reclaims it. That is the case of a run killed
// while it laid a file that replaced a directory, rolled back. A directory
// under such a name is the operator's, and stays, even empty.
func TestSyncTakesTheTemporaryFilesOfARemovedFileAway(t *testing.T) {
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
	if got := names(t, filepath.Join(root, "conf")); !slices.Equal(got, []string{"extra"}) {
		t.Errorf("conf/ holds %q, want the release directory alone", got)
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
	if err := Sync(v1, root, files1, files2); err != nil {
		t.Fatalf("the rollback of an upgrade that laid nothing: %v", err)
	}
	for f, want := range map[string]string{"conf/extra": "v1 extra", "conf/deep": "v1 deep", "docker/setup.sh": "v1", "docker/custom": "the operator's"} {
		if got := content(t, filepath.Join(root, f)); got != want {
			t.Errorf("%s = %q, want %q", f, got, want)
		}
	}
}

// An empty directory where the release lays a file holds nothing to keep:
// it gives way to the file.
func TestSyncLaysAFileOverAnEmptyDirectory(t *testing.T) {
	dir := t.TempDir()
	root := mkdir(t, filepath.Join(dir, "root"))
	v1, files1 := writeRelease(t, dir, "1", map[string]string{"docker/setup.sh": "v1"})
	v2, files2 := writeRelease(t, dir, "2", map[string]string{"docker/setup.sh": "v2", "conf/extra": "v2 extra"})
	if err := Sync(v1, root, files1, nil); err != nil {
		t.Fatal(err)
	}
	mkdir(t, filepath.Join(root, "conf/extra"))
	if got := Conflicts(root, files2, files1); len(got) != 0 {
		t.Errorf("Conflicts = %q, want none for an empty directory", got)
	}
	if err := Sync(v2, root, files2, files1); err != nil {
		t.Fatalf("a file where an empty directory stands: %v", err)
	}
	if got := content(t, filepath.Join(root, "conf/extra")); got != "v2 extra" {
		t.Errorf("conf/extra = %q", got)
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
	v1, files1 := writeRelease(t, dir, "1", map[string]string{"a.txt": "v1", "conf/site/kvs.conf": "v1 site"})
	v2, files2 := writeRelease(t, dir, "2", map[string]string{"a.txt": "v2", "conf/site": "v2 site", "docker/custom/extra.conf": "v2 custom"})
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
	if got := content(t, filepath.Join(root, "a.txt")); got != "v1" {
		t.Errorf("a refused sync changed a.txt to %q", got)
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

// The temporary file a killed run left beside a release file is reclaimed
// by the next Sync, which runs under the lock of the installation. WriteFile
// also serves commands that take no lock, so it leaves a temporary name in
// use alone: it may be the file another kvsctl is writing.
func TestTemporaryFilesOfAKilledRunAndOfAnotherWriter(t *testing.T) {
	dir := t.TempDir()
	src, root := filepath.Join(dir, "rel"), mkdir(t, filepath.Join(dir, "root"))
	writeTree(t, src, map[string]string{"docker/setup.sh": "new"})
	writeTree(t, root, map[string]string{"docker/setup.sh": "old", "docker/.setup.sh.kvsctl": "left by a killed run"})
	if err := Sync(src, root, []string{"docker/setup.sh"}, []string{"docker/setup.sh"}); err != nil {
		t.Fatal(err)
	}
	if got := names(t, filepath.Join(root, "docker")); !slices.Equal(got, []string{"setup.sh"}) {
		t.Errorf("docker/ holds %q, want the release file alone", got)
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
