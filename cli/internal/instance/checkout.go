package instance

import (
	"bufio"
	"bytes"
	"crypto/sha256"
	"encoding/hex"
	"fmt"
	"io"
	"os"
	"os/exec"
	"path/filepath"
	"sort"
	"strconv"
	"strings"
	"time"

	"github.com/MaximeMichaud/KVS-install/cli/internal/semver"
)

// Checkout is the HEAD of the git checkout an installation was cloned as by
// kvs-install.sh, as adopt records it.
type Checkout struct {
	// Commit is the full id of the HEAD commit, and Date its committer
	// date in UTC: the date of the newest change the checkout holds.
	Commit string
	Date   time.Time
	// Tag is the release tag at HEAD, a version written the way the
	// releases are tagged (26.10.0, no prefix); the newest one when HEAD
	// carries several, empty when it carries none.
	Tag string
}

// ReadCheckout reads the HEAD of the git checkout at Root.
func (i *Instance) ReadCheckout() (*Checkout, error) {
	if err := i.isCheckout(); err != nil {
		return nil, err
	}
	// --no-show-signature keeps a log.showSignature of the operator's
	// configuration out of the output.
	out, err := i.git("show", "-s", "--no-show-signature", "--format=%H%x00%cI", "HEAD")
	if err != nil {
		return nil, err
	}
	commit, date, ok := strings.Cut(strings.TrimSpace(string(out)), "\x00")
	if !ok || commit == "" {
		return nil, fmt.Errorf("git show HEAD in %s gave %q, not a commit and its date", i.Root, out)
	}
	when, err := time.Parse(time.RFC3339, date)
	if err != nil {
		return nil, fmt.Errorf("the date of HEAD in %s: %w", i.Root, err)
	}
	tags, err := i.git("tag", "--points-at", "HEAD")
	if err != nil {
		return nil, err
	}
	return &Checkout{Commit: commit, Date: when.UTC(), Tag: releaseTag(strings.Fields(string(tags)))}, nil
}

// releaseTag is the newest of tags written exactly the way a release is
// tagged, "" when none is.
func releaseTag(tags []string) string {
	best := ""
	for _, tag := range tags {
		v, err := semver.Parse(tag)
		if err != nil || v.String() != tag {
			continue
		}
		if best == "" || semver.Less(best, tag) {
			best = tag
		}
	}
	return best
}

// HeadChecksums is the sha256 of each listed file, relative to Root, as the
// HEAD commit of the checkout holds it: what a release cut from that commit
// lays down, whatever was edited on the machine since. absent lists, sorted,
// the files HEAD does not hold, added to the checkout and never committed,
// which differ from HEAD by definition.
func (i *Instance) HeadChecksums(files []string) (sums map[string]string, absent []string, err error) {
	if err := i.isCheckout(); err != nil {
		return nil, nil, err
	}
	// The whole tree is listed and filtered here: a path given to git
	// would be read as a pattern.
	tree, err := i.git("ls-tree", "-r", "-z", "--full-tree", "HEAD")
	if err != nil {
		return nil, nil, err
	}
	wanted := map[string]bool{}
	for _, f := range files {
		wanted[f] = true
	}
	paths := map[string][]string{}
	var objects []string
	for _, entry := range strings.Split(string(tree), "\x00") {
		meta, path, ok := strings.Cut(entry, "\t")
		fields := strings.Fields(meta)
		if !ok || len(fields) != 3 || fields[1] != "blob" || !wanted[path] {
			continue
		}
		object := fields[2]
		if paths[object] == nil {
			objects = append(objects, object)
		}
		paths[object] = append(paths[object], path)
		delete(wanted, path)
	}
	for f := range wanted {
		absent = append(absent, f)
	}
	sort.Strings(absent)
	sums = make(map[string]string, len(files))
	if len(objects) == 0 {
		return sums, absent, nil
	}
	hashes, err := i.blobSums(objects)
	if err != nil {
		return nil, nil, err
	}
	for object, sum := range hashes {
		for _, path := range paths[object] {
			sums[path] = sum
		}
	}
	return sums, absent, nil
}

// blobSums hashes the content of git blobs in one git process, streaming
// each one through sha256 rather than holding it.
func (i *Instance) blobSums(objects []string) (map[string]string, error) {
	cmd := exec.Command("git", "-C", i.Root, "cat-file", "--batch")
	cmd.Stdin = strings.NewReader(strings.Join(objects, "\n") + "\n")
	var stderr bytes.Buffer
	cmd.Stderr = &stderr
	stdout, err := cmd.StdoutPipe()
	if err != nil {
		return nil, err
	}
	if err := cmd.Start(); err != nil {
		return nil, err
	}
	sums, readErr := readBlobs(bufio.NewReader(stdout), len(objects))
	if readErr != nil {
		// Reading stopped part way; whatever git still has to say goes
		// nowhere, so it ends instead of blocking on a full pipe.
		_, _ = io.Copy(io.Discard, stdout)
	}
	if err := cmd.Wait(); err != nil {
		return nil, fmt.Errorf("git cat-file in %s: %w%s", i.Root, err, gitSaid(&stderr))
	}
	return sums, readErr
}

// readBlobs reads the answers of git cat-file --batch: a header line
// "<object> blob <size>", the content and a newline, for each object.
func readBlobs(r *bufio.Reader, count int) (map[string]string, error) {
	sums := make(map[string]string, count)
	for n := 0; n < count; n++ {
		header, err := r.ReadString('\n')
		if err != nil {
			return nil, fmt.Errorf("git cat-file ended after %d of %d files: %w", n, count, err)
		}
		fields := strings.Fields(header)
		if len(fields) != 3 || fields[1] != "blob" {
			return nil, fmt.Errorf("git cat-file answered %q", strings.TrimSpace(header))
		}
		size, err := strconv.ParseInt(fields[2], 10, 64)
		if err != nil {
			return nil, fmt.Errorf("git cat-file answered %q", strings.TrimSpace(header))
		}
		hash := sha256.New()
		if _, err := io.CopyN(hash, r, size); err != nil {
			return nil, fmt.Errorf("git cat-file, %s: %w", fields[0], err)
		}
		if end, err := r.ReadByte(); err != nil || end != '\n' {
			return nil, fmt.Errorf("git cat-file, %s: the content does not end where its size says", fields[0])
		}
		sums[fields[0]] = hex.EncodeToString(hash.Sum(nil))
	}
	return sums, nil
}

// isCheckout refuses a root that is not a git checkout, with the reason an
// operator can act on.
func (i *Instance) isCheckout() error {
	if _, err := os.Stat(filepath.Join(i.Root, ".git")); err != nil {
		return fmt.Errorf("%s is not a git checkout: adopt only knows installations cloned by kvs-install.sh", i.Root)
	}
	return nil
}

// git runs a read-only git command in the checkout and returns its output.
func (i *Instance) git(args ...string) ([]byte, error) {
	cmd := exec.Command("git", append([]string{"-C", i.Root}, args...)...)
	var stderr bytes.Buffer
	cmd.Stderr = &stderr
	out, err := cmd.Output()
	if err != nil {
		return nil, fmt.Errorf("git %s in %s: %w%s", args[0], i.Root, err, gitSaid(&stderr))
	}
	return out, nil
}

// gitSaid is what git wrote on stderr, as the end of an error message: ": "
// and the text, or nothing when it wrote nothing but blanks.
func gitSaid(stderr *bytes.Buffer) string {
	if text := strings.TrimSpace(stderr.String()); text != "" {
		return ": " + text
	}
	return ""
}
