package instance

import (
	"bufio"
	"crypto/sha256"
	"encoding/hex"
	"os"
	"os/exec"
	"path/filepath"
	"slices"
	"strings"
	"testing"
	"time"

	"github.com/MaximeMichaud/KVS-install/cli/internal/release"
)

// runGit runs git in root with git's own configuration only: the global one
// of the machine running the tests may sign commits or run hooks.
func runGit(t *testing.T, root string, env []string, args ...string) string {
	t.Helper()
	cmd := exec.Command("git", append([]string{"-C", root}, args...)...)
	cmd.Env = append(os.Environ(),
		"GIT_CONFIG_GLOBAL=/dev/null", "GIT_CONFIG_NOSYSTEM=1",
		"GIT_AUTHOR_NAME=kvs", "GIT_AUTHOR_EMAIL=kvs@example.com",
		"GIT_COMMITTER_NAME=kvs", "GIT_COMMITTER_EMAIL=kvs@example.com")
	cmd.Env = append(cmd.Env, env...)
	out, err := cmd.CombinedOutput()
	if err != nil {
		t.Fatalf("git %s: %v\n%s", strings.Join(args, " "), err, out)
	}
	return strings.TrimSpace(string(out))
}

// checkout makes the root of a new instance a git checkout of files, in one
// commit dated committed.
func checkout(t *testing.T, files map[string]string, committed string) *Instance {
	t.Helper()
	if _, err := exec.LookPath("git"); err != nil {
		t.Skip("git is not installed")
	}
	inst := newInstance(t, "DOMAIN=example.com\n")
	for name, content := range files {
		path := filepath.Join(inst.Root, name)
		if err := os.MkdirAll(filepath.Dir(path), 0o755); err != nil {
			t.Fatal(err)
		}
		if err := os.WriteFile(path, []byte(content), 0o644); err != nil {
			t.Fatal(err)
		}
	}
	runGit(t, inst.Root, nil, "init", "-q")
	runGit(t, inst.Root, nil, "add", "--", ".")
	runGit(t, inst.Root, []string{"GIT_AUTHOR_DATE=" + committed, "GIT_COMMITTER_DATE=" + committed}, "commit", "-q", "-m", "release files")
	return inst
}

func TestReadCheckout(t *testing.T) {
	inst := checkout(t, map[string]string{"docker/setup.sh": "setup"}, "2026-09-30T18:04:05+02:00")
	// The newest tag written the way a release is tagged wins: a
	// candidate promoted to the release at the same commit is the release.
	for _, tag := range []string{"26.10.0", "26.11.0-rc2", "26.11.0", "v26.12.0", "26.01.0", "latest"} {
		runGit(t, inst.Root, nil, "tag", tag)
	}
	head, err := inst.ReadCheckout()
	if err != nil {
		t.Fatal(err)
	}
	if want := runGit(t, inst.Root, nil, "rev-parse", "HEAD"); head.Commit != want {
		t.Errorf("commit = %s, want %s", head.Commit, want)
	}
	if want := time.Date(2026, 9, 30, 16, 4, 5, 0, time.UTC); !head.Date.Equal(want) || head.Date.Location() != time.UTC {
		t.Errorf("date = %v, want the committer date in UTC, %v", head.Date, want)
	}
	if head.Tag != "26.11.0" {
		t.Errorf("tag = %q, want 26.11.0", head.Tag)
	}
}

func TestReadCheckoutWithoutAReleaseTag(t *testing.T) {
	inst := checkout(t, map[string]string{"docker/setup.sh": "setup"}, "2026-09-30T18:04:05+02:00")
	runGit(t, inst.Root, nil, "tag", "v26.10.0")
	head, err := inst.ReadCheckout()
	if err != nil {
		t.Fatal(err)
	}
	if head.Tag != "" {
		t.Errorf("tag = %q, want none: v26.10.0 is not how a release is tagged", head.Tag)
	}
}

func TestHeadChecksums(t *testing.T) {
	committed := map[string]string{
		"docker/setup.sh":         "setup as committed",
		"docker/a.sh":             "same content",
		"docker/b.sh":             "same content",
		"conf/nginx/my site.conf": "server {}",
		"docker/lib/[x].sh":       "a name git would read as a pattern",
		"tests/unrelated.sh":      "not asked for",
	}
	inst := checkout(t, committed, "2026-09-30T18:04:05+02:00")
	// Edited on the machine, and added without a commit.
	if err := os.WriteFile(filepath.Join(inst.Root, "docker/setup.sh"), []byte("setup edited"), 0o644); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(inst.Root, "docker/new.sh"), []byte("new"), 0o644); err != nil {
		t.Fatal(err)
	}
	runGit(t, inst.Root, nil, "add", "--", "docker/new.sh")

	asked := []string{"conf/nginx/my site.conf", "docker/a.sh", "docker/b.sh", "docker/lib/[x].sh", "docker/new.sh", "docker/setup.sh"}
	sums, absent, err := inst.HeadChecksums(asked)
	if err != nil {
		t.Fatal(err)
	}
	if !slices.Equal(absent, []string{"docker/new.sh"}) {
		t.Errorf("absent = %v, want the file HEAD does not hold", absent)
	}
	if len(sums) != len(asked)-1 {
		t.Errorf("%d sums for %d committed files asked: %v", len(sums), len(asked)-1, sums)
	}
	for _, f := range asked[:len(asked)-2] {
		sum := sha256.Sum256([]byte(committed[f]))
		if want := hex.EncodeToString(sum[:]); sums[f] != want {
			t.Errorf("%s: %s, want the sum of its committed content %s", f, sums[f], want)
		}
	}
	sum := sha256.Sum256([]byte("setup as committed"))
	if sums["docker/setup.sh"] != hex.EncodeToString(sum[:]) {
		t.Error("an edited file must be summed as HEAD holds it, not as the machine does")
	}
	if _, ok := sums["tests/unrelated.sh"]; ok {
		t.Error("a file nobody asked for has no sum")
	}
	// The working tree sums of the same files tell the edited one apart.
	live, err := release.Checksums(inst.Root, asked[:len(asked)-2])
	if err != nil {
		t.Fatal(err)
	}
	for f, want := range live {
		if f != "docker/setup.sh" && sums[f] != want {
			t.Errorf("%s: HEAD and working tree differ though nothing edited it", f)
		}
	}
}

func TestCheckoutHelpersRefuseAPlainDirectory(t *testing.T) {
	inst := newInstance(t, "DOMAIN=example.com\n")
	if _, err := inst.ReadCheckout(); err == nil || !strings.Contains(err.Error(), "not a git checkout") {
		t.Errorf("ReadCheckout: %v", err)
	}
	if _, _, err := inst.HeadChecksums([]string{"docker/setup.sh"}); err == nil || !strings.Contains(err.Error(), "not a git checkout") {
		t.Errorf("HeadChecksums: %v", err)
	}
}

// fakeGit is a git that answers ls-tree with one file, and fails every
// other command, saying FAKE_GIT_SAYS on stderr.
const fakeGit = `#!/bin/sh
case "$3" in
ls-tree) printf '100644 blob 0123456789abcdef0123456789abcdef01234567\tdocker/setup.sh\0' ;;
*)
	if [ -n "$FAKE_GIT_SAYS" ]; then printf '%s\n' "$FAKE_GIT_SAYS" >&2; else printf ' \n' >&2; fi
	exit 128
	;;
esac
`

// A git that fails without a word on stderr, or with blanks only, gives an
// error that ends with its status, not with a separator and nothing after
// it; what it says otherwise ends the error.
func TestGitFailuresQuoteOnlyWhatGitSaid(t *testing.T) {
	inst := newInstance(t, "DOMAIN=example.com\n")
	if err := os.Mkdir(filepath.Join(inst.Root, ".git"), 0o755); err != nil {
		t.Fatal(err)
	}
	bin := t.TempDir()
	if err := os.WriteFile(filepath.Join(bin, "git"), []byte(fakeGit), 0o755); err != nil {
		t.Fatal(err)
	}
	t.Setenv("PATH", bin+string(os.PathListSeparator)+os.Getenv("PATH"))
	t.Setenv("FAKE_GIT_SAYS", "")
	if _, err := inst.ReadCheckout(); err == nil || err.Error() != "git show in "+inst.Root+": exit status 128" {
		t.Errorf("git show: %q", err)
	}
	if _, _, err := inst.HeadChecksums([]string{"docker/setup.sh"}); err == nil || err.Error() != "git cat-file in "+inst.Root+": exit status 128" {
		t.Errorf("git cat-file: %q", err)
	}
	t.Setenv("FAKE_GIT_SAYS", "fatal: bad object HEAD")
	if _, err := inst.ReadCheckout(); err == nil || err.Error() != "git show in "+inst.Root+": exit status 128: fatal: bad object HEAD" {
		t.Errorf("git show that said why: %q", err)
	}
	if _, _, err := inst.HeadChecksums([]string{"docker/setup.sh"}); err == nil || err.Error() != "git cat-file in "+inst.Root+": exit status 128: fatal: bad object HEAD" {
		t.Errorf("git cat-file that said why: %q", err)
	}
}

func TestReadBlobsRefusesAnAnswerItCannotRead(t *testing.T) {
	for name, answer := range map[string]string{
		"a missing object":          "0123abcd missing\n",
		"content shorter than said": "0123abcd blob 10\nshort",
		"no newline after content":  "0123abcd blob 5\nfiveX",
		"a size that is no number":  "0123abcd blob ten\n",
		"no answer":                 "",
	} {
		if _, err := readBlobs(bufio.NewReader(strings.NewReader(answer)), 1); err == nil {
			t.Errorf("%s was accepted", name)
		}
	}
	sums, err := readBlobs(bufio.NewReader(strings.NewReader("0123abcd blob 5\nfive\n\n")), 1)
	sum := sha256.Sum256([]byte("five\n"))
	if err != nil || sums["0123abcd"] != hex.EncodeToString(sum[:]) {
		t.Errorf("a well formed answer: %v %v", sums, err)
	}
}
