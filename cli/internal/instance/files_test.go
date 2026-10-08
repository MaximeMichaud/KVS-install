package instance

import (
	"errors"
	"os"
	"path/filepath"
	"slices"
	"strings"
	"syscall"
	"testing"
	"time"

	"golang.org/x/sys/unix"
)

// version.php belongs to the PHP container's user: kvsctl, root, reads it
// only as a regular file of a bounded size, reached without a link.
func TestKVSVersionReadsOnlyARegularFile(t *testing.T) {
	inst := newInstance(t, "DOMAIN=example.com\n")
	inst.WebRoot = filepath.Join(t.TempDir(), "www")
	include := filepath.Join(inst.WebRoot, "admin", "include")
	if err := os.MkdirAll(include, 0o755); err != nil {
		t.Fatal(err)
	}
	version := filepath.Join(include, "version.php")
	if err := os.WriteFile(version, []byte("<?php $config['project_version']='6.4.0';\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	if got := inst.KVSVersion(); got != "6.4.0" {
		t.Fatalf("KVSVersion = %q", got)
	}
	outside := filepath.Join(t.TempDir(), "elsewhere.php")
	if err := os.WriteFile(outside, []byte("<?php $config['project_version']='9.9.9';\n"), 0o600); err != nil {
		t.Fatal(err)
	}
	os.Remove(version)
	if err := os.Symlink(outside, version); err != nil {
		t.Fatal(err)
	}
	if got := inst.KVSVersion(); got != "" {
		t.Errorf("a link to a file elsewhere was read: %q", got)
	}
	os.Remove(version)
	big := "<?php $config['project_version']='6.4.0';\n" + strings.Repeat("//\n", maxVersionFile)
	if err := os.WriteFile(version, []byte(big), 0o644); err != nil {
		t.Fatal(err)
	}
	if got := inst.KVSVersion(); got != "" {
		t.Errorf("a file past the bound was read: %q", got)
	}
	os.Remove(version)
	if err := syscall.Mkfifo(version, 0o600); err != nil {
		t.Fatal(err)
	}
	done := make(chan string)
	go func() { done <- inst.KVSVersion() }()
	select {
	case got := <-done:
		if got != "" {
			t.Errorf("a fifo was read: %q", got)
		}
	case <-time.After(10 * time.Second):
		t.Fatal("KVSVersion blocked on a fifo")
	}
}

// keepOwner hands the new file the owner of the regular file it replaces,
// the user and the group each in its place, and only when kvsctl runs as
// root: a link planted at the name hands nothing on.
func TestKeepOwnerTakesTheOwnerOfTheReplacedFile(t *testing.T) {
	oldEuid, oldChown := euid, fchown
	t.Cleanup(func() { euid, fchown = oldEuid, oldChown })
	f, err := os.CreateTemp(t.TempDir(), "new")
	if err != nil {
		t.Fatal(err)
	}
	defer f.Close()
	var calls [][2]int
	fchown = func(got *os.File, uid, gid int) error {
		if got != f {
			t.Errorf("the owner was set on %s, not on the new file", got.Name())
		}
		calls = append(calls, [2]int{uid, gid})
		return nil
	}
	euid = func() int { return 0 }
	regular := &unix.Stat_t{Mode: unix.S_IFREG | 0o600, Uid: 4242, Gid: 4343}
	if err := keepOwner(f, regular); err != nil || !slices.Equal(calls, [][2]int{{4242, 4343}}) {
		t.Errorf("as root over a file of 4242:4343: %v, owner set %v", err, calls)
	}
	for name, replaced := range map[string]*unix.Stat_t{
		"nothing replaced": nil,
		"a link":           {Mode: unix.S_IFLNK | 0o777, Uid: 4242, Gid: 4343},
	} {
		calls = nil
		if err := keepOwner(f, replaced); err != nil || len(calls) != 0 {
			t.Errorf("%s: %v, owner set %v, want none", name, err, calls)
		}
	}
	euid = func() int { return 1000 }
	calls = nil
	if err := keepOwner(f, regular); err != nil || len(calls) != 0 {
		t.Errorf("not root: %v, owner set %v, want none", err, calls)
	}
}

// otherGroup is a group of the test user other than the one its new files
// get, -1 without one.
func otherGroup() int {
	groups, _ := os.Getgroups()
	for _, g := range groups {
		if g != os.Getegid() {
			return g
		}
	}
	return -1
}

// Every .env write gives the new file the owner of the one it replaces
// when kvsctl runs as root, which it does in production, on the open file;
// a failure to do so fails the write and keeps the file in place. The .env
// is given another group of the test user when it has one, so the owner of
// the file replaced differs from the owner of the new file.
func TestEnvWritesKeepTheOwnerAsRoot(t *testing.T) {
	inst := newInstance(t, "DOMAIN=example.com\nA=1\n")
	if g := otherGroup(); g >= 0 {
		if err := os.Chown(inst.EnvPath, -1, g); err != nil {
			t.Fatal(err)
		}
	}
	info, err := os.Stat(inst.EnvPath)
	if err != nil {
		t.Fatal(err)
	}
	st := info.Sys().(*syscall.Stat_t)
	want := [2]int{int(st.Uid), int(st.Gid)}
	oldEuid, oldChown := euid, fchown
	t.Cleanup(func() { euid, fchown = oldEuid, oldChown })
	var calls [][2]int
	euid = func() int { return 0 }
	fchown = func(f *os.File, uid, gid int) error {
		if base := filepath.Base(f.Name()); !strings.HasPrefix(base, ".") || !strings.Contains(base, ".kvsctl") {
			t.Errorf("the owner was set on %s, not on the new file", f.Name())
		}
		calls = append(calls, [2]int{uid, gid})
		// The test user may give its own files any of its groups, so
		// the next write replaces a file of that group again.
		return f.Chown(uid, gid)
	}
	example := filepath.Join(t.TempDir(), ".env.example")
	if err := os.WriteFile(example, []byte("NEW=1\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	writes := map[string]func() error{
		"SetEnv":     func() error { return inst.SetEnv("A", "2") },
		"UnsetEnv":   func() error { return inst.UnsetEnv("A") },
		"MergeEnv":   func() error { _, err := inst.MergeEnv(example); return err },
		"ReplaceEnv": func() error { return inst.ReplaceEnv([]byte("DOMAIN=example.com\n")) },
	}
	for name, write := range writes {
		calls = nil
		if err := write(); err != nil {
			t.Fatalf("%s: %v", name, err)
		}
		if len(calls) != 1 || calls[0] != want {
			t.Errorf("%s set the owner %v, want once %v", name, calls, want)
		}
	}
	// Not root: the owner is left alone.
	euid = func() int { return 1000 }
	calls = nil
	if err := inst.SetEnv("A", "3"); err != nil || len(calls) != 0 {
		t.Errorf("not root: %v, owner set %v", err, calls)
	}
	// Root, and the owner cannot be set: the write fails, the file stays.
	euid = func() int { return 0 }
	fchown = func(*os.File, int, int) error { return errors.New("operation not permitted") }
	before, _ := os.ReadFile(inst.EnvPath)
	if err := inst.SetEnv("A", "4"); err == nil || !strings.Contains(err.Error(), "operation not permitted") {
		t.Errorf("a failed chown must fail the write, got %v", err)
	}
	if after, _ := os.ReadFile(inst.EnvPath); string(after) != string(before) {
		t.Errorf("a failed write changed .env to %q", after)
	}
	if entries, _ := os.ReadDir(inst.DockerDir); len(entries) != 2 {
		t.Errorf("a failed write leaves no temporary file: %v", entries)
	}
	// A link planted at .env hands no owner on, not even the one of the
	// file it points at: the new .env stays root's.
	fchown = func(f *os.File, uid, gid int) error {
		calls = append(calls, [2]int{uid, gid})
		return nil
	}
	outside := filepath.Join(t.TempDir(), "env")
	if err := os.WriteFile(outside, before, 0o600); err != nil {
		t.Fatal(err)
	}
	os.Remove(inst.EnvPath)
	if err := os.Symlink(outside, inst.EnvPath); err != nil {
		t.Fatal(err)
	}
	calls = nil
	if err := inst.SetEnv("A", "5"); err != nil || len(calls) != 0 {
		t.Errorf("a link at .env: %v, owner set %v, want none", err, calls)
	}
}

// The records kvsctl keeps, state.json, the journal of a run and
// updates.json, are written as the .env is: as root, the file that
// replaces one gives it the owner of the file replaced, once, and a file
// that replaces nothing stays root's. The file is given another group of
// the test user when it has one, so the owner of the file replaced
// differs from the owner of the new file.
func TestStateWritesKeepTheOwnerAsRoot(t *testing.T) {
	inst := newInstance(t, "DOMAIN=example.com\n")
	oldEuid, oldChown := euid, fchown
	t.Cleanup(func() { euid, fchown = oldEuid, oldChown })
	var calls [][2]int
	euid = func() int { return 0 }
	fchown = func(f *os.File, uid, gid int) error {
		calls = append(calls, [2]int{uid, gid})
		return f.Chown(uid, gid)
	}
	writes := []struct {
		name, path string
		write      func() error
	}{
		{"SaveState", inst.statePath(), func() error { return inst.SaveState(&State{Current: "26.10.0"}) }},
		{"SaveJournal", inst.journalPath(), func() error {
			return inst.SaveJournal(&Journal{Action: ActionUpgrade, From: "26.9.0", To: "26.10.0"})
		}},
		{"SaveUpdates", inst.updatesPath(), func() error { return inst.SaveUpdates(&Updates{}) }},
	}
	for _, w := range writes {
		calls = nil
		if err := w.write(); err != nil {
			t.Fatalf("%s: %v", w.name, err)
		}
		if len(calls) != 0 {
			t.Errorf("%s set the owner %v of a file that replaced nothing", w.name, calls)
		}
		if g := otherGroup(); g >= 0 {
			if err := os.Chown(w.path, -1, g); err != nil {
				t.Fatal(err)
			}
		}
		info, err := os.Stat(w.path)
		if err != nil {
			t.Fatal(err)
		}
		st := info.Sys().(*syscall.Stat_t)
		want := [2]int{int(st.Uid), int(st.Gid)}
		calls = nil
		if err := w.write(); err != nil {
			t.Fatalf("%s: %v", w.name, err)
		}
		if len(calls) != 1 || calls[0] != want {
			t.Errorf("%s set the owner %v, want once %v, the owner of the file it replaced", w.name, calls, want)
		}
	}
}

// A .env write never goes through a link: a link at .env is replaced, its
// target untouched, and a docker directory that is a link is refused.
func TestEnvWritesDoNotFollowLinks(t *testing.T) {
	inst := newInstance(t, "DOMAIN=example.com\n")
	outside := filepath.Join(t.TempDir(), "env")
	if err := os.WriteFile(outside, []byte("DOMAIN=example.com\n"), 0o600); err != nil {
		t.Fatal(err)
	}
	os.Remove(inst.EnvPath)
	if err := os.Symlink(outside, inst.EnvPath); err != nil {
		t.Fatal(err)
	}
	if err := inst.SetEnv("A", "1"); err != nil {
		t.Fatal(err)
	}
	if got, _ := os.ReadFile(outside); string(got) != "DOMAIN=example.com\n" {
		t.Errorf("the target of the link changed: %q", got)
	}
	if info, err := os.Lstat(inst.EnvPath); err != nil || !info.Mode().IsRegular() {
		t.Errorf(".env must be a file of its own now: %v %v", info, err)
	}

	elsewhere := t.TempDir()
	for name, content := range map[string]string{"docker-compose.yml": "services: {}\n", ".env": "DOMAIN=example.com\n"} {
		if err := os.WriteFile(filepath.Join(elsewhere, name), []byte(content), 0o600); err != nil {
			t.Fatal(err)
		}
	}
	root := t.TempDir()
	if err := os.Symlink(elsewhere, filepath.Join(root, "docker")); err != nil {
		t.Fatal(err)
	}
	linked, err := Detect(root)
	if err != nil {
		t.Fatal(err)
	}
	if err := linked.SetEnv("A", "1"); err == nil || !strings.Contains(err.Error(), "docker is a symbolic link") {
		t.Errorf("a .env write through a linked docker directory: %v", err)
	}
	if got, _ := os.ReadFile(filepath.Join(elsewhere, ".env")); string(got) != "DOMAIN=example.com\n" {
		t.Errorf("the .env behind the link changed: %q", got)
	}
}
