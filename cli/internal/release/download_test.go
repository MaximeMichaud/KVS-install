package release

import (
	"archive/tar"
	"bytes"
	"context"
	"crypto/sha256"
	"encoding/hex"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"slices"
	"strconv"
	"strings"
	"sync/atomic"
	"testing"
)

// A server that sends more than the signed manifest gives is cut off at
// that size, before the rest reaches the disk; one that announces more is
// refused before the first byte.
func TestDownloadStopsAtTheSignedSize(t *testing.T) {
	piece := bytes.Repeat([]byte("x"), 1<<20)
	good := []byte("the bundle the manifest signs")
	sum := sha256.Sum256(good)
	sha := hex.EncodeToString(sum[:])
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		switch r.URL.Path {
		case "/good":
			w.Write(good)
		case "/short":
			w.Write(good[:10])
		case "/announced":
			w.Header().Set("Content-Length", strconv.Itoa(64*len(piece)))
			for range 64 {
				if _, err := w.Write(piece); err != nil {
					return
				}
			}
		case "/streamed":
			// No length announced: the body only ends when the client
			// stops reading it.
			for range 64 {
				if _, err := w.Write(piece); err != nil {
					return
				}
				w.(http.Flusher).Flush()
			}
		}
	}))
	defer srv.Close()
	dir := t.TempDir()
	signed := int64(len(good))
	for _, path := range []string{"/announced", "/streamed"} {
		dest := filepath.Join(dir, strings.TrimPrefix(path, "/"))
		var written int64
		err := DownloadSized(context.Background(), srv.URL+path, sha, signed, dest, func(n int64) { written = n })
		if err == nil || !strings.Contains(err.Error(), "the "+strconv.FormatInt(signed, 10)+" bytes the signed manifest gives: refused") {
			t.Errorf("%s: %v, want a refusal at the signed size", path, err)
		}
		if written > signed {
			t.Errorf("%s: %d bytes reached the disk, past the %d the manifest signs", path, written, signed)
		}
		if path == "/announced" && (written != 0 || !strings.Contains(err.Error(), "announces "+strconv.Itoa(64*len(piece))+" bytes")) {
			t.Errorf("a body announced larger than the signed size must be refused unread: %v, %d bytes read", err, written)
		}
		if exists(dest) || exists(dest+".part") {
			t.Errorf("%s: a refused download leaves nothing behind", path)
		}
	}
	dest := filepath.Join(dir, "short")
	if err := DownloadSized(context.Background(), srv.URL+"/short", sha, signed, dest, nil); err == nil || !strings.Contains(err.Error(), "ended after 10 of the") {
		t.Errorf("a body shorter than the signed size: %v", err)
	}
	dest = filepath.Join(dir, "good")
	if err := DownloadSized(context.Background(), srv.URL+"/good", sha, signed, dest, nil); err != nil {
		t.Fatalf("the signed body: %v", err)
	}
	if got := content(t, dest); got != string(good) {
		t.Errorf("downloaded %q", got)
	}

	// Without a size in the manifest, a download still stops at a bound.
	old := maxDownload
	t.Cleanup(func() { maxDownload = old })
	maxDownload = 3 << 20
	var written int64
	dest = filepath.Join(dir, "unsized")
	err := Download(context.Background(), srv.URL+"/streamed", sha, dest, func(n int64) { written = n })
	if err == nil || !strings.Contains(err.Error(), "the 3 MiB kvsctl downloads without a size from the manifest: refused") || written > maxDownload {
		t.Errorf("an unsized download that goes on: %v after %d bytes", err, written)
	}
}

// A plan lists the files of the target's bundle without writing anything,
// under the bounds and the checks of a download, and finds there what the
// operator keeps in the way before the upgrade takes its backup.
func TestReadBundleListsWhatExtractLays(t *testing.T) {
	dir := t.TempDir()
	bundle := filepath.Join(dir, "kvs-stack.tar.gz")
	makeTar(t, bundle,
		tarEntry{hdr: tar.Header{Name: "docker/", Typeflag: tar.TypeDir, Mode: 0o755}},
		file("docker/setup.sh", 0o755, "v2 setup"),
		file("docker/custom/extra.conf", 0o644, "v2 custom"),
		file("conf/extra/site.conf", 0o644, "v2 site"),
	)
	data, err := os.ReadFile(bundle)
	if err != nil {
		t.Fatal(err)
	}
	sum := sha256.Sum256(data)
	sha, size := hex.EncodeToString(sum[:]), int64(len(data))
	extracted, err := Extract(bundle, filepath.Join(dir, "extracted"))
	if err != nil {
		t.Fatal(err)
	}
	var served atomic.Int64
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		switch r.URL.Path {
		case "/bundle":
			n, _ := w.Write(data)
			served.Add(int64(n))
		case "/longer":
			// The signed bundle, then more than the manifest gives.
			n, _ := w.Write(data)
			served.Add(int64(n))
			for range 64 {
				n, err := w.Write(bytes.Repeat([]byte("x"), 1<<20))
				served.Add(int64(n))
				if err != nil {
					return
				}
				w.(http.Flusher).Flush()
			}
		case "/replaced":
			w.Write([]byte("not the signed bundle"))
		case "/announced":
			w.Header().Set("Content-Length", strconv.Itoa(64<<20))
			for range 64 {
				n, err := w.Write(bytes.Repeat([]byte("x"), 1<<20))
				served.Add(int64(n))
				if err != nil {
					return
				}
			}
		}
	}))
	defer srv.Close()
	for _, url := range []string{srv.URL + "/bundle", "file://" + bundle} {
		files, _, err := ReadBundle(context.Background(), url, sha, size, 0)
		if err != nil || !slices.Equal(files, extracted) {
			t.Errorf("%s: ReadBundle lists %q, %v; want what Extract lays, %q", url, files, err, extracted)
		}
	}

	// What the plan does with the list: the file docker/custom of the
	// operator is named, with nothing written in the installation.
	root := mkdir(t, filepath.Join(dir, "root"))
	writeTree(t, root, map[string]string{"docker/setup.sh": "v1 setup", "docker/custom": "the operator's"})
	files, _, err := ReadBundle(context.Background(), srv.URL+"/bundle", sha, size, 0)
	if err != nil {
		t.Fatal(err)
	}
	want := []string{filepath.Join(root, "docker/custom") + " is a file, where the release needs a directory for docker/custom/extra.conf: move it away"}
	if got := Conflicts(root, files, []string{"docker/setup.sh"}); !slices.Equal(got, want) {
		t.Errorf("Conflicts =\n%q\nwant\n%q", got, want)
	}

	served.Store(0)
	if _, _, err := ReadBundle(context.Background(), srv.URL+"/longer", sha, size, 0); err == nil || !strings.Contains(err.Error(), "bytes the signed manifest gives: refused") {
		t.Errorf("a body longer than the signed size: %v", err)
	}
	if n := served.Load(); n >= 64<<20 {
		t.Errorf("the whole longer body was read (%d bytes)", n)
	}
	if _, _, err := ReadBundle(context.Background(), srv.URL+"/announced", sha, size, 0); err == nil || !strings.Contains(err.Error(), "announces 67108864 bytes, more than the "+strconv.FormatInt(size, 10)+" bytes the signed manifest gives: refused") {
		t.Errorf("a body announced larger than the signed size: %v", err)
	}
	if _, _, err := ReadBundle(context.Background(), srv.URL+"/replaced", sha, 0, 0); err == nil || !strings.Contains(err.Error(), "checksum mismatch") {
		t.Errorf("an asset that is not the signed one: %v, want the checksum named", err)
	}
	if _, _, err := ReadBundle(context.Background(), srv.URL+"/bundle", sha, size+1, 0); err == nil || !strings.Contains(err.Error(), "ended after") {
		t.Errorf("a bundle shorter than the signed size: %v", err)
	}

	// A signed bundle Extract would refuse is refused here too, for what it
	// holds: the whole asset is read for its checksum, also past an entry
	// that stops the listing early.
	noise := make([]byte, 256<<10)
	for i := range noise {
		noise[i] = byte(i*7919>>3 ^ i>>11)
	}
	linked := filepath.Join(dir, "linked.tar.gz")
	makeTar(t, linked, tarEntry{hdr: tar.Header{Name: "docker/link", Typeflag: tar.TypeSymlink, Linkname: "/etc/passwd", Mode: 0o777}}, file("docker/big.bin", 0o644, string(noise)))
	data, err = os.ReadFile(linked)
	if err != nil {
		t.Fatal(err)
	}
	sum = sha256.Sum256(data)
	if _, _, err := ReadBundle(context.Background(), "file://"+linked, hex.EncodeToString(sum[:]), int64(len(data)), 0); err == nil || !strings.Contains(err.Error(), `"docker/link" is not a plain file`) {
		t.Errorf("a bundle with a link: %v", err)
	}
}

// The plan reads the compose file of the target in the same pass, as
// Extract leaves it: the last entry of its name, however the name is
// written, within a bound. A bundle that is not the signed one gives
// nothing.
func TestReadBundleKeepsWhatItIsAskedFor(t *testing.T) {
	bundle := filepath.Join(t.TempDir(), "kvs-stack.tar.gz")
	makeTar(t, bundle,
		file("docker/docker-compose.yml", 0o644, "first\n"),
		file("./docker/docker-compose.yml", 0o644, "last\n"),
		file("docker/large.yml", 0o644, strings.Repeat("x", 65)),
		file("docker/setup.sh", 0o755, "setup"),
	)
	data, err := os.ReadFile(bundle)
	if err != nil {
		t.Fatal(err)
	}
	sum := sha256.Sum256(data)
	sha, size := hex.EncodeToString(sum[:]), int64(len(data))
	files, kept, err := ReadBundle(context.Background(), "file://"+bundle, sha, size, 64, "docker/docker-compose.yml", "docker/large.yml", "docker/other.yml")
	if err != nil {
		t.Fatal(err)
	}
	if want := []string{"docker/docker-compose.yml", "docker/docker-compose.yml", "docker/large.yml", "docker/setup.sh"}; !slices.Equal(files, want) {
		t.Errorf("files %q, want %q", files, want)
	}
	if got, ok := kept["docker/docker-compose.yml"]; !ok || string(got) != "last\n" {
		t.Errorf("docker/docker-compose.yml: %q; want the last entry of that name", got)
	}
	if got, ok := kept["docker/large.yml"]; ok {
		t.Errorf("a file past the bound was kept: %d bytes", len(got))
	}
	if got, ok := kept["docker/other.yml"]; ok {
		t.Errorf("a file the bundle does not ship was kept: %q", got)
	}
	if len(kept) != 1 {
		t.Errorf("kept %d files, want 1", len(kept))
	}
	files, kept, err = ReadBundle(context.Background(), "file://"+bundle, strings.Repeat("0", 64), size, 64, "docker/docker-compose.yml")
	if err == nil || !strings.Contains(err.Error(), "checksum mismatch") || files != nil || kept != nil {
		t.Errorf("a bundle that is not the signed one: %q, %q, %v", files, kept, err)
	}
}
