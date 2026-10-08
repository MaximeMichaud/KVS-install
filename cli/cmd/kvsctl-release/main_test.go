package main

import (
	"archive/tar"
	"bytes"
	"compress/gzip"
	"crypto/ecdsa"
	"crypto/ed25519"
	"crypto/elliptic"
	"crypto/rand"
	"crypto/sha256"
	"crypto/x509"
	"encoding/base64"
	"encoding/hex"
	"encoding/json"
	"encoding/pem"
	"errors"
	"fmt"
	"io"
	"net/http"
	"net/http/httptest"
	"os"
	"os/exec"
	"path/filepath"
	"slices"
	"strings"
	"testing"
	"time"

	"github.com/MaximeMichaud/KVS-install/cli/internal/manifest"
	"github.com/MaximeMichaud/KVS-install/cli/internal/semver"
)

func TestParseImages(t *testing.T) {
	specs, err := parseImages("nginx=r/nginx:26.10.0, php-fpm@8.1=r/php:26.10.0-php8.1\ncron@8.1=r/cron:26.10.0-php8.1,mariadb@11.8=mariadb:11.8.3,memcached=memcached:1.6.45-alpine")
	if err != nil {
		t.Fatal(err)
	}
	var got []string
	for _, s := range specs {
		got = append(got, s.Key()+" -> "+s.Ref+" ["+s.Axis+"]")
	}
	want := []string{
		"nginx -> r/nginx:26.10.0 []",
		"php-fpm@8.1 -> r/php:26.10.0-php8.1 [php]",
		"cron@8.1 -> r/cron:26.10.0-php8.1 [php]",
		"mariadb@11.8 -> mariadb:11.8.3 [mariadb]",
		"memcached -> memcached:1.6.45-alpine []",
	}
	if strings.Join(got, "; ") != strings.Join(want, "; ") {
		t.Errorf("parseImages = %v, want %v", got, want)
	}
	if specs[1].Series != "8.1" || specs[0].Series != "" || specs[3].Series != "11.8" {
		t.Errorf("the series must come from the @ part: %+v", specs)
	}
	if specs, err := parseImages(""); err != nil || len(specs) != 0 {
		t.Errorf("an empty list is not an error: %v %v", specs, err)
	}
	// A reference that already carries a digest keeps its @.
	pinnedRef, err := parseImages("nginx=r/nginx:26.10.0@sha256:aaa")
	if err != nil || pinnedRef[0].Ref != "r/nginx:26.10.0@sha256:aaa" || pinnedRef[0].Series != "" {
		t.Errorf("a digest in the reference is not a series: %+v %v", pinnedRef, err)
	}
	for _, bad := range []string{
		"nginx", "nginx=", "=ref", "php-fpm@=ref", "nginx=a,nginx=b",
		"php-fpm@8.1=a,php-fpm@8.1=b", "php-fpm=a,php-fpm@8.1=b", "mariadb=a,mariadb@11.8=b",
		// Only php-fpm, cron and mariadb vary, each on its own axis.
		"nginx@8.1=a", "memcached@1.6=a", "kvs-init@8.1=a",
		// A series is major.minor.
		"mariadb@11=a", "mariadb@11.8.9=a", "php-fpm@latest=a", "cron@8.1-fpm=a",
	} {
		if _, err := parseImages(bad); err == nil {
			t.Errorf("parseImages(%q) must fail", bad)
		}
	}
}

// workflowSpecs returns images.spec and digests.spec as
// .github/scripts/release-images.sh writes them: the images this repository
// builds, the PHP variants, one MariaDB image per series of
// docker/images.lock, and the other images the stack runs.
// stackCompose is a compose file with the services of the stack, written
// the way docker/docker-compose.yml is.
const stackCompose = `name: kvs
services:
  nginx:
    build: ./nginx
  php-fpm:
    build: ./php
  mariadb:
    image: mariadb:11.8
  memcached:
    image: memcached:1.6-alpine
    profiles: ["memcached"]
  dragonfly:
    image: docker.dragonflydb.io/dragonflydb/dragonfly
  manticore:
    build: ./manticore
  acme:
    image: neilpang/acme.sh
  cron:
    build: ./cron
  kvs-init:
    build: ./init
  phpmyadmin-init:
    image: alpine:3

volumes:
  mariadb-data:
`

func workflowSpecs() (string, string) {
	keys := []string{
		"nginx=ghcr.io/example/kvs-install/nginx:26.11.0",
		"kvs-init=ghcr.io/example/kvs-install/init:26.11.0",
		"manticore=ghcr.io/example/kvs-install/manticore:26.11.0",
		"cron@8.1=ghcr.io/example/kvs-install/cron:26.11.0-php8.1",
		"cron@8.4=ghcr.io/example/kvs-install/cron:26.11.0-php8.4",
		"php-fpm@8.1=ghcr.io/example/kvs-install/php:26.11.0-php8.1",
		"php-fpm@8.4=ghcr.io/example/kvs-install/php:26.11.0-php8.4",
		"mariadb@11.8=mariadb:11.8.9",
		"mariadb@12.3=mariadb:12.3.1",
		"memcached=memcached:1.6.45-alpine",
		"dragonfly=docker.dragonflydb.io/dragonflydb/dragonfly:v1.35.1",
		"acme=neilpang/acme.sh:3.1.6",
		"phpmyadmin-init=alpine:3.24.2",
	}
	var digests []string
	for _, item := range keys {
		key, _, _ := strings.Cut(item, "=")
		digests = append(digests, key+"="+stubDigest(key))
	}
	return strings.Join(keys, ","), strings.Join(digests, ",")
}

func TestPinnedRefs(t *testing.T) {
	specs, err := parseImages("nginx=r/nginx:1,php-fpm@8.1=r/php:1-php8.1,mariadb@11.8=mariadb:11.8.9")
	if err != nil {
		t.Fatal(err)
	}
	digests := map[string]string{"nginx": "sha256:aaa", "php-fpm@8.1": "sha256:bbb", "mariadb@11.8": "sha256:ccc"}
	pins, err := pinnedRefs(specs, digests)
	if err != nil {
		t.Fatal(err)
	}
	want := map[string]string{"nginx": "r/nginx:1@sha256:aaa", "php-fpm@8.1": "r/php:1-php8.1@sha256:bbb", "mariadb@11.8": "mariadb:11.8.9@sha256:ccc"}
	for key, ref := range want {
		if pins[key] != ref {
			t.Errorf("pin of %s = %q, want %q", key, pins[key], ref)
		}
	}
	// A reference that carries its digest needs no --digests entry, and
	// one that agrees with it is fine.
	carried, err := parseImages("nginx=r/nginx:1@sha256:aaa")
	if err != nil {
		t.Fatal(err)
	}
	for _, given := range []map[string]string{nil, {"nginx": "sha256:aaa"}} {
		if pins, err := pinnedRefs(carried, given); err != nil || pins["nginx"] != "r/nginx:1@sha256:aaa" {
			t.Errorf("a reference with its digest: %v %v", pins, err)
		}
	}
	refused := map[string]struct {
		images  string
		digests map[string]string
	}{
		"an image without a digest":            {"nginx=r/nginx:1,memcached=memcached:1", map[string]string{"nginx": "sha256:aaa"}},
		"a variant without a digest":           {"php-fpm@8.1=r/php:1", nil},
		"a digest the reference contradicts":   {"nginx=r/nginx:1@sha256:aaa", map[string]string{"nginx": "sha256:bbb"}},
		"a reference ending in no sha256":      {"nginx=r/nginx:1@md5:aaa", nil},
		"a digest that names no listed image":  {"nginx=r/nginx:1", map[string]string{"nginx": "sha256:aaa", "cron@8.1": "sha256:bbb"}},
		"a digest of a series that is missing": {"mariadb@11.8=m:11.8.9", map[string]string{"mariadb@11.8": "sha256:aaa", "mariadb@12.3": "sha256:bbb"}},
	}
	for name, c := range refused {
		specs, err := parseImages(c.images)
		if err != nil {
			t.Fatal(err)
		}
		if _, err := pinnedRefs(specs, c.digests); err == nil {
			t.Errorf("%s must be refused", name)
		}
	}
}

func TestParseDigests(t *testing.T) {
	// The workflow writes the services that do not vary as "nginx@=...".
	digests, err := parseDigests("nginx@=sha256:aaa php-fpm@8.1=sha256:bbb\ncron@8.1=sha256:ccc,mariadb=sha256:ddd")
	if err != nil {
		t.Fatal(err)
	}
	want := map[string]string{"nginx": "sha256:aaa", "php-fpm@8.1": "sha256:bbb", "cron@8.1": "sha256:ccc", "mariadb": "sha256:ddd"}
	for key, digest := range want {
		if digests[key] != digest {
			t.Errorf("digest of %s = %q, want %q", key, digests[key], digest)
		}
	}
	if len(digests) != len(want) {
		t.Errorf("parseDigests = %v", digests)
	}
	for _, bad := range []string{"nginx", "nginx=aaa", "=sha256:aaa"} {
		if _, err := parseDigests(bad); err == nil {
			t.Errorf("parseDigests(%q) must fail", bad)
		}
	}
}

func TestRenderOverrideWithVariants(t *testing.T) {
	specs, err := parseImages("nginx=r/nginx:26.10.0,php-fpm@8.1=r/php:26.10.0-php8.1,cron@8.1=r/cron:26.10.0-php8.1,mariadb@11.8=mariadb:11.8.9,mariadb@12.3=mariadb:12.3.1,memcached=memcached:1.6.45-alpine")
	if err != nil {
		t.Fatal(err)
	}
	digests, err := parseDigests("nginx=sha256:aaa,php-fpm@8.1=sha256:bbb,cron@8.1=sha256:ccc,mariadb@11.8=sha256:ddd,mariadb@12.3=sha256:eee,memcached=sha256:fff")
	if err != nil {
		t.Fatal(err)
	}
	pins, err := pinnedRefs(specs, digests)
	if err != nil {
		t.Fatal(err)
	}
	built := map[string]bool{}
	for _, service := range builtByDefault {
		built[service] = true
	}
	out := renderOverride("26.10.0", specs, pins, built)
	header, body, found := strings.Cut(out, "services:\n")
	if !found {
		t.Fatalf("no services section:\n%s", out)
	}
	for _, want := range []string{"26.10.0", "build: !reset null", "2.19.0", "COMPOSE_FILE", "ref@sha256", "PHP series", "MariaDB series"} {
		if !strings.Contains(header, want) {
			t.Errorf("the header does not explain %q:\n%s", want, header)
		}
	}
	want := `  nginx:
    build: !reset null
    image: "r/nginx:26.10.0@sha256:aaa"
  php-fpm:
    build: !reset null
    image: "${KVS_PHP_FPM_IMAGE:?kvsctl writes it to .env when it applies a release}"
  cron:
    build: !reset null
    image: "${KVS_CRON_IMAGE:?kvsctl writes it to .env when it applies a release}"
  mariadb:
    image: "${KVS_MARIADB_IMAGE:?kvsctl writes it to .env when it applies a release}"
  memcached:
    image: "memcached:1.6.45-alpine@sha256:fff"
`
	if body != want {
		t.Errorf("override =\n%s\nwant\n%s", body, want)
	}
	if strings.Contains(missingImageMessage, "}") || strings.Contains(missingImageMessage, "$") {
		t.Errorf("the message must not end the variable early or start another one: %q", missingImageMessage)
	}
}

func TestRenderOverrideWithoutVariants(t *testing.T) {
	specs, err := parseImages("nginx=r/nginx:0.2.0,php-fpm=r/php:0.2.0")
	if err != nil {
		t.Fatal(err)
	}
	pins, err := pinnedRefs(specs, map[string]string{"nginx": "sha256:aaa", "php-fpm": "sha256:bbb"})
	if err != nil {
		t.Fatal(err)
	}
	built := map[string]bool{"nginx": true, "php-fpm": true}
	out := renderOverride("0.2.0", specs, pins, built)
	_, body, _ := strings.Cut(out, "services:\n")
	want := `  nginx:
    build: !reset null
    image: "r/nginx:0.2.0@sha256:aaa"
  php-fpm:
    build: !reset null
    image: "r/php:0.2.0@sha256:bbb"
`
	if body != want {
		t.Errorf("override =\n%s\nwant\n%s", body, want)
	}
	if strings.Contains(out, "${") || strings.Contains(out, "depends on a series") {
		t.Error("a release without variants pins the reference directly")
	}
	// A service the base compose file does not build keeps no build key.
	_, body, _ = strings.Cut(renderOverride("0.2.0", specs, pins, map[string]bool{"nginx": true}), "services:\n")
	if strings.Count(body, "!reset") != 1 {
		t.Errorf("only the built services lose their build section:\n%s", body)
	}
}

// gitRepo commits files into a new repository, the executable ones with
// mode 0755, and returns its directory.
func gitRepo(t *testing.T, files map[string]string, executable map[string]bool) string {
	t.Helper()
	dir := t.TempDir()
	git := func(args ...string) {
		t.Helper()
		base := []string{"-C", dir, "-c", "user.name=test", "-c", "user.email=test@example.com", "-c", "commit.gpgsign=false"}
		if out, err := exec.Command("git", append(base, args...)...).CombinedOutput(); err != nil {
			t.Fatalf("git %v: %v\n%s", args, err, out)
		}
	}
	git("init", "-q")
	for name, content := range files {
		path := filepath.Join(dir, name)
		if err := os.MkdirAll(filepath.Dir(path), 0o755); err != nil {
			t.Fatal(err)
		}
		mode := os.FileMode(0o644)
		if executable[name] {
			mode = 0o755
		}
		if err := os.WriteFile(path, []byte(content), mode); err != nil {
			t.Fatal(err)
		}
	}
	git("add", "-A")
	git("commit", "-q", "-m", "release files")
	return dir
}

// readBundle lists the files of a .tar.gz with their content and mode.
func readBundle(t *testing.T, path string) (map[string]string, map[string]int64) {
	t.Helper()
	f, err := os.Open(path)
	if err != nil {
		t.Fatal(err)
	}
	defer f.Close()
	gz, err := gzip.NewReader(f)
	if err != nil {
		t.Fatal(err)
	}
	tr := tar.NewReader(gz)
	content, modes := map[string]string{}, map[string]int64{}
	for {
		h, err := tr.Next()
		if errors.Is(err, io.EOF) {
			break
		}
		if err != nil {
			t.Fatal(err)
		}
		data, err := io.ReadAll(tr)
		if err != nil {
			t.Fatal(err)
		}
		content[h.Name], modes[h.Name] = string(data), h.Mode
	}
	return content, modes
}

// The bundle the release workflow builds: the release files of the ref,
// docker/RELEASE, and an override that pins every image by digest and reads
// the variant ones, MariaDB included, from .env.
func TestBundleFromTheWorkflowSpecs(t *testing.T) {
	repo := gitRepo(t, map[string]string{
		"docker/docker-compose.yml": stackCompose,
		"docker/setup.sh":           "#!/bin/sh\n",
		"conf/nginx/kvs.conf.tpl":   "server {}\n",
		"README.md":                 "readme\n",
		"cli/go.mod":                "module example\n",
	}, map[string]bool{"docker/setup.sh": true})
	images, digests := workflowSpecs()
	out := filepath.Join(t.TempDir(), "kvs-stack-26.11.0.tar.gz")
	if err := bundle([]string{"--repo", repo, "--ref", "HEAD", "--version", "26.11.0", "--images", images, "--digests", digests, "--out", out}); err != nil {
		t.Fatal(err)
	}
	files, modes := readBundle(t, out)
	for _, name := range []string{"docker/docker-compose.yml", "docker/setup.sh", "conf/nginx/kvs.conf.tpl", "README.md", "docker/RELEASE", "docker/" + releaseOverride} {
		if _, ok := files[name]; !ok {
			t.Errorf("the bundle lacks %s", name)
		}
	}
	if _, ok := files["cli/go.mod"]; ok {
		t.Error("the bundle carries a file outside the release paths")
	}
	if modes["docker/setup.sh"] != 0o755 || modes["README.md"] != 0o644 {
		t.Errorf("modes = %o and %o, want 755 and 644", modes["docker/setup.sh"], modes["README.md"])
	}
	if files["docker/RELEASE"] != "26.11.0\n" {
		t.Errorf("docker/RELEASE = %q", files["docker/RELEASE"])
	}
	override := files["docker/"+releaseOverride]
	for _, line := range strings.Split(override, "\n") {
		ref, ok := strings.CutPrefix(strings.TrimSpace(line), "image: ")
		if !ok {
			continue
		}
		if !strings.Contains(ref, "@sha256:") && !strings.HasPrefix(ref, `"${KVS_`) {
			t.Errorf("the override pins an image by its tag alone: %s", line)
		}
	}
	for _, want := range []string{
		`image: "ghcr.io/example/kvs-install/nginx:26.11.0@` + stubDigest("nginx") + `"`,
		`image: "alpine:3.24.2@` + stubDigest("phpmyadmin-init") + `"`,
		`image: "${KVS_PHP_FPM_IMAGE:?`,
		`image: "${KVS_CRON_IMAGE:?`,
		`image: "${KVS_MARIADB_IMAGE:?`,
	} {
		if !strings.Contains(override, want) {
			t.Errorf("the override lacks %s:\n%s", want, override)
		}
	}
	if strings.Count(override, "mariadb:") != 1 {
		t.Errorf("mariadb must be one service reading its image from .env, not one per series:\n%s", override)
	}

	// Without the digests, or with one missing, nothing is written.
	_, partial, _ := strings.Cut(digests, ",")
	for name, args := range map[string][]string{
		"no digests":        {"--images", images},
		"a missing digest":  {"--images", images, "--digests", partial},
		"an unknown series": {"--images", images, "--digests", digests + ",mariadb@11.4=" + stubDigest("x")},
	} {
		refused := filepath.Join(t.TempDir(), "refused.tar.gz")
		err := bundle(append([]string{"--repo", repo, "--version", "26.11.0", "--out", refused}, args...))
		if err == nil {
			t.Errorf("%s: the bundle must be refused", name)
		}
		if _, statErr := os.Stat(refused); !errors.Is(statErr, os.ErrNotExist) {
			t.Errorf("%s: a refused bundle must leave no file", name)
		}
	}
}

// Two bundles of one ref are the same bytes, and every member carries the
// time of the commit: the sha256 the manifest signs can be checked by
// building the bundle again from the tag.
func TestBundleIsReproducible(t *testing.T) {
	repo := gitRepo(t, map[string]string{
		"docker/docker-compose.yml": stackCompose,
		"docker/setup.sh":           "#!/bin/sh\n",
		"README.md":                 "readme\n",
	}, map[string]bool{"docker/setup.sh": true})
	images, digests := workflowSpecs()
	var sums []string
	for n := 0; n < 2; n++ {
		out := filepath.Join(t.TempDir(), "kvs-stack-26.11.0.tar.gz")
		if err := bundle([]string{"--repo", repo, "--ref", "HEAD", "--version", "26.11.0", "--images", images, "--digests", digests, "--out", out}); err != nil {
			t.Fatal(err)
		}
		sum, _, err := fileSum(out)
		if err != nil {
			t.Fatal(err)
		}
		sums = append(sums, sum)
		if n == 0 {
			when, err := exec.Command("git", "-C", repo, "log", "-1", "--format=%ct").Output()
			if err != nil {
				t.Fatal(err)
			}
			f, err := os.Open(out)
			if err != nil {
				t.Fatal(err)
			}
			gz, err := gzip.NewReader(f)
			if err != nil {
				t.Fatal(err)
			}
			tr := tar.NewReader(gz)
			for {
				h, err := tr.Next()
				if errors.Is(err, io.EOF) {
					break
				}
				if err != nil {
					t.Fatal(err)
				}
				if got := fmt.Sprint(h.ModTime.Unix()); got != strings.TrimSpace(string(when)) {
					t.Errorf("%s carries %s, want the commit time %s", h.Name, got, strings.TrimSpace(string(when)))
				}
			}
			f.Close()
		}
		// A second build a moment later must not differ by the clock.
		time.Sleep(1100 * time.Millisecond)
	}
	if sums[0] != sums[1] {
		t.Errorf("two bundles of one ref differ: %s and %s", sums[0], sums[1])
	}
}

// A symbolic link in the release paths stops the bundle: kvsctl lays down
// regular files, and the link would arrive as a file holding its target.
func TestBundleRefusesASymlink(t *testing.T) {
	repo := gitRepo(t, map[string]string{"docker/setup.sh": "#!/bin/sh\n", "docker/docker-compose.yml": stackCompose}, map[string]bool{"docker/setup.sh": true})
	if err := os.Symlink("setup.sh", filepath.Join(repo, "docker", "install.sh")); err != nil {
		t.Fatal(err)
	}
	base := []string{"-C", repo, "-c", "user.name=test", "-c", "user.email=test@example.com", "-c", "commit.gpgsign=false"}
	for _, args := range [][]string{{"add", "-A"}, {"commit", "-q", "-m", "link"}} {
		if out, err := exec.Command("git", append(base, args...)...).CombinedOutput(); err != nil {
			t.Fatalf("git %v: %v\n%s", args, err, out)
		}
	}
	images, digests := workflowSpecs()
	out := filepath.Join(t.TempDir(), "refused.tar.gz")
	err := bundle([]string{"--repo", repo, "--ref", "HEAD", "--version", "26.11.0", "--images", images, "--digests", digests, "--out", out})
	if err == nil || !strings.Contains(err.Error(), "docker/install.sh has git mode 120000") {
		t.Errorf("a symbolic link must stop the bundle with its name: %v", err)
	}
	if _, statErr := os.Stat(out); !errors.Is(statErr, os.ErrNotExist) {
		t.Error("a refused bundle must leave no file")
	}
}

// The image list has to cover the compose file of the ref exactly.
func TestBundleCoversEveryComposeService(t *testing.T) {
	if got := composeServices(stackCompose); strings.Join(got, ",") != "nginx,php-fpm,mariadb,memcached,dragonfly,manticore,acme,cron,kvs-init,phpmyadmin-init" {
		t.Fatalf("composeServices = %v", got)
	}
	repo := gitRepo(t, map[string]string{"docker/docker-compose.yml": stackCompose}, nil)
	images, digests := workflowSpecs()
	cases := map[string]struct{ images, digests, want string }{
		"a service left out": {
			strings.Replace(images, "acme=neilpang/acme.sh:3.1.6,", "", 1),
			strings.Replace(digests, "acme="+stubDigest("acme")+",", "", 1),
			"no image for acme",
		},
		"a service the stack does not run": {
			images + ",redis=redis:8",
			digests + ",redis=" + stubDigest("redis"),
			"names redis, which",
		},
	}
	for name, c := range cases {
		out := filepath.Join(t.TempDir(), "refused.tar.gz")
		err := bundle([]string{"--repo", repo, "--ref", "HEAD", "--version", "26.11.0", "--images", c.images, "--digests", c.digests, "--out", out})
		if err == nil || !strings.Contains(err.Error(), c.want) {
			t.Errorf("%s: want an error saying %q, got %v", name, c.want, err)
		}
		if _, statErr := os.Stat(out); !errors.Is(statErr, os.ErrNotExist) {
			t.Errorf("%s: a refused bundle must leave no file", name)
		}
	}
}

// The bundle of a tag is built from a checkout of main by hand, to compare
// it with the sha256 the manifest signs: every part of it comes from --ref,
// the files, their modes, the services the image list must cover and the
// time, and nothing from the commits after it.
func TestBundleReadsTheRefNotHEAD(t *testing.T) {
	dir := t.TempDir()
	git := func(date string, args ...string) {
		t.Helper()
		base := []string{"-C", dir, "-c", "user.name=test", "-c", "user.email=test@example.com",
			"-c", "commit.gpgsign=false", "-c", "tag.gpgsign=false", "-c", "tag.forceSignAnnotated=false"}
		cmd := exec.Command("git", append(base, args...)...)
		if date != "" {
			cmd.Env = append(os.Environ(), "GIT_AUTHOR_DATE="+date, "GIT_COMMITTER_DATE="+date)
		}
		if out, err := cmd.CombinedOutput(); err != nil {
			t.Fatalf("git %v: %v\n%s", args, err, out)
		}
	}
	write := func(name, content string, mode os.FileMode) {
		t.Helper()
		path := filepath.Join(dir, name)
		if err := os.MkdirAll(filepath.Dir(path), 0o755); err != nil {
			t.Fatal(err)
		}
		if err := os.WriteFile(path, []byte(content), mode); err != nil {
			t.Fatal(err)
		}
		if err := os.Chmod(path, mode); err != nil {
			t.Fatal(err)
		}
	}
	// The release commit, tagged a day later, then a commit on main.
	tagged, taggedAt, mainAt := "1759689572 +0000", "1759776000 +0000", "1759860000 +0000"
	git("", "init", "-q")
	write("docker/docker-compose.yml", stackCompose, 0o644)
	write("docker/setup.sh", "#!/bin/sh\necho tag\n", 0o755)
	write("docker/removed-later.sh", "#!/bin/sh\n", 0o644)
	write("README.md", "readme of the tag\n", 0o644)
	git(tagged, "add", "-A")
	git(tagged, "commit", "-q", "-m", "release")
	git(taggedAt, "tag", "-a", "26.11.0", "-m", "26.11.0")
	mainCompose := strings.Replace(stackCompose, "\nvolumes:", "  redis:\n    image: redis:8\n\nvolumes:", 1)
	if got := composeServices(mainCompose); got[len(got)-1] != "redis" {
		t.Fatalf("the compose file of main must run one more service: %v", got)
	}
	write("docker/docker-compose.yml", mainCompose, 0o644)
	write("docker/setup.sh", "#!/bin/sh\necho main\n", 0o644)
	write("docker/added-later.sh", "#!/bin/sh\n", 0o644)
	write("README.md", "readme of main\n", 0o644)
	if err := os.Remove(filepath.Join(dir, "docker", "removed-later.sh")); err != nil {
		t.Fatal(err)
	}
	git(mainAt, "add", "-A")
	git(mainAt, "commit", "-q", "-m", "after the release")

	// The image list of the tag: main's compose file has one more service.
	images, digests := workflowSpecs()
	out := filepath.Join(t.TempDir(), "kvs-stack-26.11.0.tar.gz")
	if err := bundle([]string{"--repo", dir, "--ref", "26.11.0", "--version", "26.11.0", "--images", images, "--digests", digests, "--out", out}); err != nil {
		t.Fatalf("the bundle of the tag must be checked against the compose file of the tag: %v", err)
	}
	files, modes := readBundle(t, out)
	if files["README.md"] != "readme of the tag\n" || files["docker/setup.sh"] != "#!/bin/sh\necho tag\n" {
		t.Errorf("the content must be the tag's: README.md %q, docker/setup.sh %q", files["README.md"], files["docker/setup.sh"])
	}
	if modes["docker/setup.sh"] != 0o755 {
		t.Errorf("docker/setup.sh has mode %o in the bundle, want the tag's 755", modes["docker/setup.sh"])
	}
	if _, ok := files["docker/removed-later.sh"]; !ok {
		t.Error("a file of the tag removed on main must be in the bundle")
	}
	if _, ok := files["docker/added-later.sh"]; ok {
		t.Error("a file added on main after the tag must not be in the bundle")
	}
	if strings.Contains(files["docker/docker-compose.yml"], "redis") {
		t.Error("the compose file must be the tag's")
	}
	stamp, err := bundleStamp(out, "26.11.0")
	if err != nil {
		t.Fatal(err)
	}
	if got := stamp.Format(time.RFC3339); got != "2025-10-05T18:39:32Z" {
		t.Errorf("the members carry %s, want the time of the tagged commit, not of the tag or of main", got)
	}
}

// update-cli checks the binary it downloads against the sha256 the manifest
// signs for its platform, so that sum has to be the one of the very file
// the release publishes under that name: computed from the copy in --assets
// when there is one, read from url.sha256 otherwise, and the same as the
// SHA256SUMS line published with it. The size of that copy is signed too,
// the bound of a download of the build; a sum read from url.sha256 comes
// with no size.
func TestManifestCommandRecordsTheCLIChecksums(t *testing.T) {
	registry := registryStub()
	defer registry.Close()
	host := strings.TrimPrefix(registry.URL, "http://")
	dir := t.TempDir()
	if err := keygen([]string{"--out", dir}); err != nil {
		t.Fatal(err)
	}
	bundlePath := writeBundle(t, dir, "26.11.0", time.Date(2026, 11, 2, 9, 0, 0, 0, time.UTC))
	assets := filepath.Join(dir, "dist")
	if err := os.MkdirAll(assets, 0o755); err != nil {
		t.Fatal(err)
	}
	sums := map[string]string{}
	var listing strings.Builder
	for _, name := range []string{"kvsctl-linux-amd64", "kvsctl-linux-arm64", "kvsctl-release-linux-amd64"} {
		content := "the build of " + name + "\n"
		if err := os.WriteFile(filepath.Join(assets, name), []byte(content), 0o755); err != nil {
			t.Fatal(err)
		}
		sum := sha256.Sum256([]byte(content))
		sums[name] = hex.EncodeToString(sum[:])
		fmt.Fprintf(&listing, "%s  %s\n", sums[name], name)
	}
	if err := os.WriteFile(filepath.Join(assets, sumsFile), []byte(listing.String()), 0o644); err != nil {
		t.Fatal(err)
	}
	// Where the release publishes the binaries. Nothing is there before the
	// release, so a sum read from it instead of --assets fails.
	published := filepath.Join(dir, "published")
	if err := os.MkdirAll(published, 0o755); err != nil {
		t.Fatal(err)
	}
	url := func(name string) string { return "file://" + filepath.Join(published, name) }
	release := func(out string, extra ...string) error {
		return manifestCmd(append([]string{
			"--key", filepath.Join(dir, "release.key"), "--out", out, "--version", "26.11.0",
			"--bundle", bundlePath, "--bundle-url", "file://" + bundlePath,
			"--images", "nginx=" + host + "/kvs-install/nginx:26.11.0",
		}, extra...))
	}
	// Two platforms, so a sum taken from another file than the one named
	// shows; the release itself ships linux-amd64 alone.
	cli := "linux-amd64=" + url("kvsctl-linux-amd64") + ",linux-arm64=" + url("kvsctl-linux-arm64")

	site := filepath.Join(dir, "site")
	if err := release(site, "--cli", cli, "--assets", assets); err != nil {
		t.Fatal(err)
	}
	got := readManifest(t, site, dir).Manifest.Latest().CLI
	for platform, name := range map[string]string{"linux-amd64": "kvsctl-linux-amd64", "linux-arm64": "kvsctl-linux-arm64"} {
		if got[platform].URL != url(name) || got[platform].SHA256 != sums[name] || got[platform].Size != int64(len("the build of "+name+"\n")) {
			t.Errorf("cli %s = %+v, want %s with the sha256 and the size of %s", platform, got[platform], url(name), name)
		}
	}
	if len(got) != 2 {
		t.Errorf("cli = %+v, want the two platforms given", got)
	}

	// Without --assets the sum is read from the url with .sha256 appended;
	// with --assets the local copy wins over it.
	elsewhere := strings.Repeat("e", 64)
	if err := os.WriteFile(filepath.Join(published, "kvsctl-linux-amd64.sha256"), []byte(elsewhere+"  kvsctl-linux-amd64\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	site = filepath.Join(dir, "remote")
	if err := release(site, "--cli", "linux-amd64="+url("kvsctl-linux-amd64")); err != nil {
		t.Fatal(err)
	}
	if got := readManifest(t, site, dir).Manifest.Latest().CLI["linux-amd64"]; got.SHA256 != elsewhere || got.Size != 0 {
		t.Errorf("without --assets the asset = %+v, want the sum of the .sha256 file and no size", got)
	}
	site = filepath.Join(dir, "local")
	if err := release(site, "--cli", "linux-amd64="+url("kvsctl-linux-amd64"), "--assets", assets); err != nil {
		t.Fatal(err)
	}
	if got := readManifest(t, site, dir).Manifest.Latest().CLI["linux-amd64"].SHA256; got != sums["kvsctl-linux-amd64"] {
		t.Errorf("with --assets the sum = %s, want the one of the local file", got)
	}

	// A binary that is missing, a SHA256SUMS that disagrees or lacks it, and
	// a .sha256 that holds no sum stop the release.
	if err := os.WriteFile(filepath.Join(published, "kvsctl-linux-riscv64.sha256"), []byte("pending\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	other := filepath.Join(dir, "other")
	if err := os.MkdirAll(other, 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(other, "kvsctl-linux-amd64"), []byte("another build\n"), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(other, sumsFile), []byte(listing.String()), 0o644); err != nil {
		t.Fatal(err)
	}
	lacking := filepath.Join(dir, "lacking")
	if err := os.MkdirAll(lacking, 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(lacking, "kvsctl-linux-amd64"), []byte("the build of kvsctl-linux-amd64\n"), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(lacking, sumsFile), []byte(sums["kvsctl-linux-arm64"]+"  kvsctl-linux-arm64\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	for name, c := range map[string]struct {
		args []string
		want string
	}{
		"a binary missing from --assets": {[]string{"--cli", "linux-riscv64=" + url("kvsctl-linux-riscv64"), "--assets", assets}, "kvsctl-linux-riscv64"},
		"a SHA256SUMS that disagrees":    {[]string{"--cli", "linux-amd64=" + url("kvsctl-linux-amd64"), "--assets", other}, "lists " + sums["kvsctl-linux-amd64"]},
		"a SHA256SUMS that lacks it":     {[]string{"--cli", "linux-amd64=" + url("kvsctl-linux-amd64"), "--assets", lacking}, "kvsctl-linux-amd64 is not listed"},
		"a .sha256 that holds no sum":    {[]string{"--cli", "linux-riscv64=" + url("kvsctl-linux-riscv64")}, "holds no sha256"},
	} {
		out := filepath.Join(dir, strings.ReplaceAll(name, " ", "-"))
		if err := release(out, c.args...); err == nil || !strings.Contains(err.Error(), c.want) {
			t.Errorf("%s: want an error saying %q, got %v", name, c.want, err)
		}
		if _, statErr := os.Stat(filepath.Join(out, "manifest.json")); !errors.Is(statErr, os.ErrNotExist) {
			t.Errorf("%s: a refused manifest must not be written", name)
		}
	}
}

func TestEnvVar(t *testing.T) {
	cases := map[string]string{
		"php-fpm":   "KVS_PHP_FPM_IMAGE",
		"cron":      "KVS_CRON_IMAGE",
		"mariadb":   "KVS_MARIADB_IMAGE",
		"kvs-init":  "KVS_KVS_INIT_IMAGE",
		"manticore": "KVS_MANTICORE_IMAGE",
	}
	for service, want := range cases {
		if got := envVar(service); got != want {
			t.Errorf("envVar(%s) = %s, want %s", service, got, want)
		}
	}
}

// A rotation runs keygen a second time, and a directory given twice by
// mistake must not cost the key the installed binaries trust.
func TestKeygenNeverReplacesAKey(t *testing.T) {
	dir := t.TempDir()
	if err := keygen([]string{"--out", dir}); err != nil {
		t.Fatal(err)
	}
	keyPath := filepath.Join(dir, "release.key")
	info, err := os.Stat(keyPath)
	if err != nil {
		t.Fatal(err)
	}
	if info.Mode().Perm() != 0o600 {
		t.Errorf("release.key has mode %o, want 600", info.Mode().Perm())
	}
	before, err := os.ReadFile(keyPath)
	if err != nil {
		t.Fatal(err)
	}
	err = keygen([]string{"--out", dir})
	if err == nil || !strings.Contains(err.Error(), "already exists") {
		t.Fatalf("a second keygen into the same directory: %v", err)
	}
	after, err := os.ReadFile(keyPath)
	if err != nil {
		t.Fatal(err)
	}
	if string(after) != string(before) {
		t.Error("the refused keygen replaced release.key")
	}

	// A public key alone is refused too, before a private key that does
	// not match it is written next to it.
	lone := t.TempDir()
	if err := os.WriteFile(filepath.Join(lone, "release.pub"), []byte("kept\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	if err := keygen([]string{"--out", lone}); err == nil {
		t.Fatal("keygen wrote next to an existing release.pub")
	}
	if _, err := os.Stat(filepath.Join(lone, "release.key")); !errors.Is(err, os.ErrNotExist) {
		t.Errorf("the refused keygen left a release.key: %v", err)
	}
}

func TestLoadSignersDerivesTheKeyID(t *testing.T) {
	dir := t.TempDir()
	if err := keygen([]string{"--out", dir}); err != nil {
		t.Fatal(err)
	}
	other := filepath.Join(dir, "other")
	if err := keygen([]string{"--out", other}); err != nil {
		t.Fatal(err)
	}
	keyPath := filepath.Join(dir, "release.key")
	encoded, err := os.ReadFile(filepath.Join(dir, "release.pub"))
	if err != nil {
		t.Fatal(err)
	}
	raw, err := base64.StdEncoding.DecodeString(strings.TrimSpace(string(encoded)))
	if err != nil {
		t.Fatal(err)
	}
	pub := ed25519.PublicKey(raw)
	signers, err := loadSigners([]string{keyPath}, nil)
	if err != nil {
		t.Fatal(err)
	}
	if len(signers) != 1 || signers[0].id != manifest.KeyID(pub) {
		t.Fatalf("key id = %q, want %q", signers[0].id, manifest.KeyID(pub))
	}
	if len(signers[0].id) != 8 {
		t.Errorf("a derived key id is eight hex characters, got %q", signers[0].id)
	}
	named, err := loadSigners([]string{keyPath, filepath.Join(other, "release.key")}, []string{"r1"})
	if err != nil {
		t.Fatal(err)
	}
	if named[0].id != "r1" || named[1].id == "r1" {
		t.Errorf("--key-id pairs by position: %q %q", named[0].id, named[1].id)
	}
	if _, err := loadSigners([]string{keyPath}, []string{"r1", "r2"}); err == nil {
		t.Error("more key ids than keys must fail")
	}
	if _, err := loadSigners([]string{keyPath, keyPath}, nil); err == nil {
		t.Error("the same key twice must fail")
	}
	if _, err := loadSigners(nil, nil); err == nil {
		t.Error("signing without a key must fail")
	}
}

// The signing keys job of the release workflow reads every signing secret
// with pubkey, before any image is pushed, and compares the public half
// with the keys kvsctl trusts. So pubkey reads a key as the manifest
// command does, from the same bytes: a secret it accepts, the publish job
// signs with, and one it refuses, the publish job would refuse once every
// image is pushed. A secret pasted with its public half first as a PEM
// PUBLIC KEY block, or with CRLF line ends that lost the last line feed,
// passes openssl and not Go. Text before the key, such as the line of
// release.pub, is skipped by both.
func TestPubkeyReadsAKeyAsTheManifestCommandDoes(t *testing.T) {
	dir := t.TempDir()
	if err := keygen([]string{"--out", dir}); err != nil {
		t.Fatal(err)
	}
	key, err := os.ReadFile(filepath.Join(dir, "release.key"))
	if err != nil {
		t.Fatal(err)
	}
	pub, err := os.ReadFile(filepath.Join(dir, "release.pub"))
	if err != nil {
		t.Fatal(err)
	}
	spki, err := x509.MarshalPKIXPublicKey(readPub(t, dir))
	if err != nil {
		t.Fatal(err)
	}
	ec, err := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
	if err != nil {
		t.Fatal(err)
	}
	ecDER, err := x509.MarshalPKCS8PrivateKey(ec)
	if err != nil {
		t.Fatal(err)
	}
	crlf := bytes.ReplaceAll(key, []byte("\n"), []byte("\r\n"))
	for _, c := range []struct {
		name string
		data []byte
		want string // the refusal, "" for a key both read
	}{
		{"the key keygen writes", key, ""},
		{"the key without its last line feed", bytes.TrimSuffix(key, []byte("\n")), ""},
		{"the key with CRLF line ends", crlf, ""},
		{"the key with CRLF line ends without the last line feed", bytes.TrimSuffix(crlf, []byte("\n")), "release key is not PEM"},
		{"release.pub before the key", append(slices.Clone(pub), key...), ""},
		{"the public half before the key", append(pem.EncodeToMemory(&pem.Block{Type: "PUBLIC KEY", Bytes: spki}), key...), "asn1: structure error"},
		{"an EC key", pem.EncodeToMemory(&pem.Block{Type: "PRIVATE KEY", Bytes: ecDER}), "release key is not Ed25519"},
		{"text", []byte("not a key\n"), "release key is not PEM"},
	} {
		path := filepath.Join(dir, strings.ReplaceAll(c.name, " ", "-"))
		if err := os.WriteFile(path, c.data, 0o600); err != nil {
			t.Fatal(err)
		}
		var out bytes.Buffer
		err := pubkey([]string{"--key", path}, &out)
		// The manifest command reads its keys before the bundle, which does
		// not exist here: a key it accepts fails on the bundle instead.
		signErr := manifestCmd([]string{"--key", path, "--out", filepath.Join(dir, "out"), "--version", "26.11.0",
			"--bundle-url", "file:///nowhere/kvs-stack-26.11.0.tar.gz", "--bundle", filepath.Join(dir, "no-bundle.tar.gz")})
		if c.want == "" {
			if err != nil || out.String() != string(pub) {
				t.Errorf("%s: pubkey printed %q, %v; want release.pub, %q", c.name, out.String(), err, pub)
			}
			if signErr == nil || strings.HasPrefix(signErr.Error(), path+": ") {
				t.Errorf("%s: the manifest command must read the key and stop at the bundle: %v", c.name, signErr)
			}
			continue
		}
		if err == nil || !strings.HasPrefix(err.Error(), path+": "+c.want) || out.Len() > 0 {
			t.Errorf("%s: pubkey must refuse it, saying %q: %v, printed %q", c.name, c.want, err, out.String())
		}
		if signErr == nil || err == nil || signErr.Error() != err.Error() {
			t.Errorf("%s: the manifest command must refuse the key as pubkey does: %v, pubkey %v", c.name, signErr, err)
		}
	}
	if err := pubkey(nil, io.Discard); err == nil {
		t.Error("pubkey without --key must fail")
	}
}

func TestSignManifestIsReadBack(t *testing.T) {
	dir := t.TempDir()
	if err := keygen([]string{"--out", dir}); err != nil {
		t.Fatal(err)
	}
	second := filepath.Join(dir, "next")
	if err := keygen([]string{"--out", second}); err != nil {
		t.Fatal(err)
	}
	signers, err := loadSigners([]string{filepath.Join(dir, "release.key"), filepath.Join(second, "release.key")}, []string{"r1", "r2"})
	if err != nil {
		t.Fatal(err)
	}
	raw := []byte(`{"schema":2,"channel":"stable","updated":"2026-10-15T12:00:00Z","releases":[{"version":"26.10.0","date":"2026-10-15","bundle":{"url":"file:///b.tar.gz","sha256":"0000000000000000000000000000000000000000000000000000000000000000"},"images":[{"service":"nginx","ref":"r/nginx:26.10.0","digest":"sha256:aaa","size":5}]}]}`)
	sig, err := signManifest(raw, signers)
	if err != nil {
		t.Fatal(err)
	}
	if !strings.HasPrefix(strings.TrimSpace(string(sig)), "[") || !strings.Contains(string(sig), `"key_id": "r2"`) {
		t.Fatalf("the signature file must be the JSON list:\n%s", sig)
	}
	path := filepath.Join(dir, "manifest.json")
	if err := os.WriteFile(path, raw, 0o644); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(path+".sig", sig, 0o644); err != nil {
		t.Fatal(err)
	}
	doc, err := manifest.Fetch("file://" + path)
	if err != nil {
		t.Fatal(err)
	}
	for _, s := range signers {
		if err := doc.VerifyAny([]ed25519.PublicKey{s.priv.Public().(ed25519.PublicKey)}); err != nil {
			t.Errorf("key %s must verify the file it signed: %v", s.id, err)
		}
	}
	if doc.Manifest == nil || doc.Manifest.Latest().Version != "26.10.0" {
		t.Error("the verified document must carry the manifest")
	}
}

func TestFirstParagraph(t *testing.T) {
	notes := "### Features\n\n- add the Manticore search backend\n  and drop the internal one\n\n### Fixes\n\n- something else\n"
	if got := firstParagraph(notes); got != "add the Manticore search backend and drop the internal one" {
		t.Errorf("firstParagraph = %q", got)
	}
	if got := firstParagraph("\n\nplain   text\nover two lines\n\nrest\n"); got != "plain text over two lines" {
		t.Errorf("firstParagraph = %q", got)
	}
	if got := firstParagraph("# Title\n"); got != "" {
		t.Errorf("a file of headings gives no note, got %q", got)
	}
}

func TestParseAnnouncedKeys(t *testing.T) {
	dir := t.TempDir()
	if err := keygen([]string{"--out", dir}); err != nil {
		t.Fatal(err)
	}
	encoded, err := os.ReadFile(filepath.Join(dir, "release.pub"))
	if err != nil {
		t.Fatal(err)
	}
	pub := strings.TrimSpace(string(encoded))
	parsed, err := manifest.ParseKeys([]string{pub})
	if err != nil {
		t.Fatal(err)
	}
	id := manifest.KeyID(parsed[0])
	keys, err := parseAnnouncedKeys([]string{id + "=" + pub + "@2026-11-01"})
	if err != nil {
		t.Fatal(err)
	}
	if len(keys) != 1 || keys[0].ID != id || keys[0].Pub != pub || keys[0].ValidFrom != "2026-11-01" {
		t.Errorf("announced key = %+v", keys)
	}
	if keys, err := parseAnnouncedKeys([]string{id + "=" + pub}); err != nil || keys[0].ValidFrom != "" {
		t.Errorf("the date is optional: %+v %v", keys, err)
	}
	// kvsctl recognizes a key it embeds by the derived id, so an announced
	// key under any other name would keep warning on the binaries that
	// already carry it.
	for _, bad := range []string{id, "=" + pub, id + "=not-base64", id + "=" + pub + "@tomorrow", "r2=" + pub} {
		if _, err := parseAnnouncedKeys([]string{bad}); err == nil {
			t.Errorf("parseAnnouncedKeys(%q) must fail", bad)
		}
	}
}

// registryStub answers the two distribution API calls registryDigest makes,
// with a digest derived from the path so every image gets its own.
func registryStub() *httptest.Server {
	mux := http.NewServeMux()
	mux.HandleFunc("/v2/", func(w http.ResponseWriter, r *http.Request) {
		switch {
		case strings.Contains(r.URL.Path, "/manifests/"):
			w.Header().Set("Docker-Content-Digest", stubDigest(r.URL.Path))
			w.Header().Set("Content-Type", "application/vnd.oci.image.manifest.v1+json")
			fmt.Fprint(w, `{"mediaType":"application/vnd.oci.image.manifest.v1+json","config":{"digest":"sha256:config","size":3},"layers":[{"digest":"sha256:layer","size":97}]}`)
		case strings.Contains(r.URL.Path, "/blobs/"):
			fmt.Fprint(w, `{"rootfs":{"diff_ids":["sha256:diff"]}}`)
		default:
			http.NotFound(w, r)
		}
	})
	return httptest.NewServer(mux)
}

func stubDigest(path string) string {
	sum := sha256.Sum256([]byte(path))
	return "sha256:" + hex.EncodeToString(sum[:])
}

// tarMember is one file of a .tar.gz a test writes.
type tarMember struct {
	name, content string
	modTime       time.Time
}

func writeTarGz(t *testing.T, path string, members []tarMember) {
	t.Helper()
	f, err := os.Create(path)
	if err != nil {
		t.Fatal(err)
	}
	gz := gzip.NewWriter(f)
	tw := tar.NewWriter(gz)
	for _, m := range members {
		if err := tw.WriteHeader(&tar.Header{Name: m.name, Mode: 0o644, Size: int64(len(m.content)), ModTime: m.modTime, Typeflag: tar.TypeReg}); err != nil {
			t.Fatal(err)
		}
		if _, err := tw.Write([]byte(m.content)); err != nil {
			t.Fatal(err)
		}
	}
	for _, c := range []io.Closer{tw, gz, f} {
		if err := c.Close(); err != nil {
			t.Fatal(err)
		}
	}
}

// writeBundle writes into dir the bundle of version the way kvsctl-release
// bundle lays it out for the manifest command: docker/RELEASE names the
// version, and every member carries the time of the release commit.
func writeBundle(t *testing.T, dir, version string, commitTime time.Time) string {
	t.Helper()
	path := filepath.Join(dir, "kvs-stack-"+version+".tar.gz")
	writeTarGz(t, path, []tarMember{
		{"docker/docker-compose.yml", stackCompose, commitTime},
		{"docker/RELEASE", version + "\n", commitTime},
	})
	return path
}

// readManifest reads the manifest the manifest command wrote into dir,
// checked with the public key keygen wrote into keyDir.
func readManifest(t *testing.T, dir, keyDir string) *manifest.Document {
	t.Helper()
	doc, err := manifest.Fetch("file://" + filepath.Join(dir, "manifest.json"))
	if err != nil {
		t.Fatal(err)
	}
	if err := doc.VerifyAny([]ed25519.PublicKey{readPub(t, keyDir)}); err != nil {
		t.Fatal(err)
	}
	return doc
}

func TestManifestCommandWritesVariants(t *testing.T) {
	registry := registryStub()
	defer registry.Close()
	host := strings.TrimPrefix(registry.URL, "http://")
	dir := t.TempDir()
	if err := keygen([]string{"--out", dir}); err != nil {
		t.Fatal(err)
	}
	next := filepath.Join(dir, "next")
	if err := keygen([]string{"--out", next}); err != nil {
		t.Fatal(err)
	}
	nextPub := readPub(t, next)
	nextID := manifest.KeyID(nextPub)
	committed := time.Date(2026, 10, 5, 18, 39, 32, 0, time.UTC)
	bundlePath := writeBundle(t, dir, "26.10.0", committed)
	site := filepath.Join(dir, "site")
	nginx := host + "/kvs-install/nginx:26.10.0"
	php := host + "/kvs-install/php:26.10.0-php8.1"
	cron := host + "/kvs-install/cron:26.10.0-php8.1"
	mariadb118 := host + "/mariadb:11.8.9"
	mariadb123 := host + "/mariadb:12.3.1"
	commit := strings.Repeat("a", 40)
	args := []string{
		"--key", filepath.Join(dir, "release.key"), "--key-id", "r1", "--key", filepath.Join(next, "release.key"),
		"--out", site, "--version", "26.10.0", "--commit", commit,
		"--bundle", bundlePath, "--bundle-url", "file://" + bundlePath,
		"--images", fmt.Sprintf("nginx=%s,php-fpm@8.1=%s,cron@8.1=%s,mariadb@11.8=%s,mariadb@12.3=%s", nginx, php, cron, mariadb118, mariadb123),
		"--digests", "nginx@=" + stubDigest("/v2/kvs-install/nginx/manifests/26.10.0") + ",mariadb@11.8=" + stubDigest("/v2/mariadb/manifests/11.8.9"),
		"--notes", "Manticore replaces the internal search", "--notes-url", "https://example.test/26.10.0",
		"--highlight", "Manticore is the default search backend",
		"--announce-key", nextID + "=" + base64.StdEncoding.EncodeToString(nextPub) + "@2026-11-01",
		"--php-series", "8.1",
		"--compose-min", "2.19.0", "--kvs-min", "7.0.0",
		"--database", "migrates", "--one-way",
	}
	if err := manifestCmd(args); err != nil {
		t.Fatal(err)
	}
	doc, err := manifest.Fetch("file://" + filepath.Join(site, "manifest.json"))
	if err != nil {
		t.Fatal(err)
	}
	if err := doc.VerifyAny([]ed25519.PublicKey{readPub(t, dir)}); err != nil {
		t.Fatal(err)
	}
	m := doc.Manifest
	if m.Schema != manifest.Schema || m.Updated == "" || m.Channel != "stable" {
		t.Errorf("schema %d, updated %q, channel %q", m.Schema, m.Updated, m.Channel)
	}
	if len(m.Keys) != 1 || m.Keys[0].ID != nextID || m.Keys[0].ValidFrom != "2026-11-01" {
		t.Errorf("announced keys = %+v", m.Keys)
	}
	rel := m.Latest()
	if rel.Commit != commit {
		t.Errorf("commit = %q, want %q", rel.Commit, commit)
	}
	if rel.Date != "2026-10-05T18:39:32Z" {
		t.Errorf("date = %q, want the time the bundle carries, 2026-10-05T18:39:32Z", rel.Date)
	}
	// kvsctl downloads the bundle and refuses it unless its sha256 and its
	// size are the ones the manifest signs.
	bundleData, err := os.ReadFile(bundlePath)
	if err != nil {
		t.Fatal(err)
	}
	bundleSum := sha256.Sum256(bundleData)
	if rel.Bundle.SHA256 != hex.EncodeToString(bundleSum[:]) || rel.Bundle.Size != int64(len(bundleData)) || rel.Bundle.URL != "file://"+bundlePath {
		t.Errorf("bundle = %+v, want the sha256 %x and the size %d of %s", rel.Bundle, bundleSum, len(bundleData), bundlePath)
	}
	if len(rel.Images) != 1 || rel.Images[0].Service != "nginx" {
		t.Errorf("images = %+v, only the service that does not vary belongs there", rel.Images)
	}
	if rel.Images[0].Size != 100 || len(rel.Images[0].Layers) != 1 {
		t.Errorf("the size and the layers come from the registry: %+v", rel.Images[0])
	}
	series := rel.Variants[manifest.VariantPHP]["8.1"]
	if len(series) != 2 || series[0].Service != "php-fpm" || series[1].Service != "cron" {
		t.Fatalf("variants = %+v", rel.Variants)
	}
	if got := strings.Join(rel.Values(manifest.VariantMariaDB), ","); got != "11.8,12.3" {
		t.Errorf("MariaDB series = %s, want every series given", got)
	}
	for value, ref := range map[string]string{"11.8": mariadb118, "12.3": mariadb123} {
		images := rel.Variants[manifest.VariantMariaDB][value]
		if len(images) != 1 || images[0].Service != "mariadb" || images[0].Ref != ref || !strings.HasPrefix(images[0].Digest, "sha256:") {
			t.Errorf("variant mariadb %s = %+v", value, images)
		}
	}
	images, err := rel.ImagesFor(map[string]string{manifest.VariantPHP: "8.1", manifest.VariantMariaDB: "12.3"})
	if err != nil || len(images) != 4 {
		t.Errorf("ImagesFor(8.1, 12.3) = %d images: %v", len(images), err)
	}
	if _, err := rel.ImagesFor(map[string]string{manifest.VariantPHP: "8.1"}); err == nil {
		t.Error("an installation whose MariaDB series is unknown must be refused")
	}
	if _, err := rel.ImagesFor(map[string]string{manifest.VariantPHP: "8.2", manifest.VariantMariaDB: "11.8"}); err == nil {
		t.Error("a series the release publishes no image for must be refused")
	}
	if rel.Requires.PHP != "8.1" || strings.Join(rel.Requires.PHPSeries, ",") != "8.1" {
		t.Errorf("requires = %+v", rel.Requires)
	}
	if rel.Requires.ComposeMin != "2.19.0" || rel.Requires.MinFrom != "" || rel.Requires.KVSMin != "7.0.0" {
		t.Errorf("requires = %+v", rel.Requires)
	}
	if !rel.OneWay || rel.Database != "migrates" {
		t.Errorf("one_way %v, database %q", rel.OneWay, rel.Database)
	}
	if rel.Notes != "Manticore replaces the internal search" || rel.NotesURL == "" || len(rel.Highlights) != 1 {
		t.Errorf("notes %q, url %q, highlights %v", rel.Notes, rel.NotesURL, rel.Highlights)
	}
	if len(doc.Signatures) != 2 || doc.Signatures[0].KeyID != "r1" || doc.Signatures[1].KeyID != nextID {
		t.Errorf("signatures = %+v, want r1 and the announced key", doc.Signatures)
	}

	// The next release extends the list. It announces nothing, so the
	// announcement of the previous manifest is gone, and its one line of
	// notes comes from the notes file when --notes is absent.
	notesPath := filepath.Join(dir, "RELEASE_NOTES.md")
	if err := os.WriteFile(notesPath, []byte("### Features\n\n- PHP 8.4 images\n\n### Fixes\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	nextBundle := writeBundle(t, dir, "26.11.0", committed.Add(36*time.Hour))
	following := []string{
		"--key", filepath.Join(dir, "release.key"), "--out", site, "--version", "26.11.0",
		"--bundle", nextBundle, "--bundle-url", "file://" + nextBundle,
		"--images", fmt.Sprintf("nginx=%s", nginx),
		"--notes-file", notesPath, "--previous", filepath.Join(site, "manifest.json"),
		"--min-from", "26.10.0",
	}
	if err := manifestCmd(following); err != nil {
		t.Fatal(err)
	}
	doc, err = manifest.Fetch("file://" + filepath.Join(site, "manifest.json"))
	if err != nil {
		t.Fatal(err)
	}
	if err := doc.VerifyAny([]ed25519.PublicKey{readPub(t, dir)}); err != nil {
		t.Fatal(err)
	}
	if len(doc.Manifest.Keys) != 0 {
		t.Errorf("a release that announces no key must not carry the previous announcement: %+v", doc.Manifest.Keys)
	}
	if len(doc.Manifest.Releases) != 2 || doc.Manifest.Latest().Version != "26.11.0" || doc.Manifest.Latest().Notes != "PHP 8.4 images" {
		t.Errorf("releases = %+v", doc.Manifest.Releases)
	}
	if doc.Manifest.Latest().Requires.MinFrom != "26.10.0" {
		t.Errorf("min_from = %q, want the stop given, 26.10.0", doc.Manifest.Latest().Requires.MinFrom)
	}
	if doc.Manifest.Find("26.10.0").Commit != commit {
		t.Error("the previous releases keep their commit")
	}
	if got := doc.Manifest.Find("26.10.0").Date + " " + doc.Manifest.Latest().Date; got != "2026-10-05T18:39:32Z 2026-10-07T06:39:32Z" {
		t.Errorf("dates = %s, want each release dated by its own bundle", got)
	}

	// A digest the registry does not confirm stops the release.
	bad := append([]string{}, args...)
	for i, a := range bad {
		if a == "--digests" {
			bad[i+1] = "nginx@=sha256:0000"
		}
	}
	if err := manifestCmd(bad); err == nil {
		t.Error("a digest the registry does not confirm must be refused")
	}
	unknown := append([]string{}, args...)
	for i, a := range unknown {
		if a == "--digests" {
			unknown[i+1] = "php@8.1=" + stubDigest("/v2/kvs-install/php/manifests/26.10.0-php8.1")
		}
	}
	if err := manifestCmd(unknown); err == nil {
		t.Error("a digest naming an image --images does not build must be refused")
	}
	tooMany := append(append([]string{}, args...), "--highlight", "two", "--highlight", "three", "--highlight", "four")
	if err := manifestCmd(tooMany); err == nil {
		t.Error("more than three highlights must be refused")
	}
}

// readPub reads the release.pub keygen wrote into dir.
func readPub(t *testing.T, dir string) ed25519.PublicKey {
	t.Helper()
	encoded, err := os.ReadFile(filepath.Join(dir, "release.pub"))
	if err != nil {
		t.Fatal(err)
	}
	keys, err := manifest.ParseKeys([]string{strings.TrimSpace(string(encoded))})
	if err != nil {
		t.Fatal(err)
	}
	return keys[0]
}

// The values kvsctl compares are checked before anything is signed: a
// minimum that is not a version would never block anything on the client,
// a stop that is no release would block every older installation, and a
// typo would be signed for every installation to read. The arguments around
// each value make a release that is signed as it is, and a stop that has to
// be refused for its order is a release of the manifest, so each refusal
// below can only come from the check that writes its message.
func TestManifestCommandRefusesWhatKvsctlCannotUse(t *testing.T) {
	registry := registryStub()
	defer registry.Close()
	host := strings.TrimPrefix(registry.URL, "http://")
	dir := t.TempDir()
	if err := keygen([]string{"--out", dir}); err != nil {
		t.Fatal(err)
	}
	committed := time.Date(2026, 11, 2, 9, 0, 0, 0, time.UTC)
	release := func(version, out string, extra ...string) error {
		bundlePath := writeBundle(t, dir, version, committed)
		args := []string{
			"--key", filepath.Join(dir, "release.key"), "--out", out, "--version", version,
			"--bundle", bundlePath, "--bundle-url", "file://" + bundlePath,
			"--images", "nginx=" + host + "/kvs-install/nginx:" + version,
		}
		return manifestCmd(append(args, extra...))
	}
	// The manifest of the previous release, which holds 26.10.0 for a stop.
	site := filepath.Join(dir, "site")
	if err := release("26.10.0", site); err != nil {
		t.Fatal(err)
	}
	previous := []string{"--previous", filepath.Join(site, "manifest.json")}

	alone := filepath.Join(dir, "alone")
	if err := release("26.11.0", alone, previous...); err != nil {
		t.Fatalf("the arguments the refusals start from must be signed as they are: %v", err)
	}
	valid := filepath.Join(dir, "valid")
	err := release("26.11.0", valid, append(previous,
		"--commit", strings.Repeat("a", 40), "--database", "migrates", "--min-from", "26.10.0",
		"--kvs-min", "7.0.0", "--compose-min", "2.19.0")...)
	if err != nil {
		t.Fatalf("valid values must be signed: %v", err)
	}
	rel := readManifest(t, valid, dir).Manifest.Latest()
	if rel.Commit != strings.Repeat("a", 40) || rel.Database != "migrates" || rel.Requires.MinFrom != "26.10.0" ||
		rel.Requires.KVSMin != "7.0.0" || rel.Requires.ComposeMin != "2.19.0" {
		t.Errorf("the signed release does not carry the values given: %+v", rel)
	}

	// The two stops refused for their order are releases of the manifest
	// their case extends, so the check of the stop lets them through: alone
	// holds 26.11.0, as the manifest of a run signing 26.11.0 again does, and
	// later holds 26.12.0, as the manifest a hotfix of 26.11 extends once
	// 26.12.0 is out.
	later := filepath.Join(dir, "later")
	if err := release("26.12.0", later, "--previous", filepath.Join(alone, "manifest.json")); err != nil {
		t.Fatal(err)
	}
	notVersion := func(flag, value string) string {
		_, err := semver.Parse(value)
		if err == nil {
			t.Fatalf("%s %s is a version", flag, value)
		}
		return flag + ": " + err.Error()
	}
	for name, c := range map[string]struct{ version, previous, flag, value, want string }{
		"a short commit":                   {"26.11.0", site, "--commit", "aaaaaaa", `--commit "aaaaaaa" is not a full git commit id`},
		"an upper case commit":             {"26.11.0", site, "--commit", strings.Repeat("A", 40), `--commit "` + strings.Repeat("A", 40) + `" is not a full git commit id`},
		"a commit that is not hex":         {"26.11.0", site, "--commit", strings.Repeat("g", 40), `--commit "` + strings.Repeat("g", 40) + `" is not a full git commit id`},
		"a database kvsctl does not know":  {"26.11.0", site, "--database", "migrate", `--database is "migrate", which is neither none nor migrates`},
		"a min-from that is no version":    {"26.11.0", site, "--min-from", "26.10", notVersion("--min-from", "26.10")},
		"a min-from not older":             {"26.11.0", alone, "--min-from", "26.11.0", "--min-from 26.11.0 is not older than the release 26.11.0"},
		"a min-from newer":                 {"26.11.1", later, "--min-from", "26.12.0", "--min-from 26.12.0 is not older than the release 26.11.1"},
		"a min-from that was never out":    {"26.11.0", site, "--min-from", "26.10.9", "--min-from 26.10.9 names no release of the manifest"},
		"a kvs-min that is no version":     {"26.11.0", site, "--kvs-min", "seven", notVersion("--kvs-min", "seven")},
		"a compose-min that is no version": {"26.11.0", site, "--compose-min", "2.24", notVersion("--compose-min", "2.24")},
	} {
		out := filepath.Join(dir, strings.ReplaceAll(name, " ", "-"))
		err := release(c.version, out, "--previous", filepath.Join(c.previous, "manifest.json"), c.flag, c.value)
		if err == nil || !strings.HasPrefix(err.Error(), c.want) {
			t.Errorf("%s must be refused by the check of %s, saying %q: %v", name, c.flag, c.want, err)
		}
		if _, statErr := os.Stat(filepath.Join(out, "manifest.json")); !errors.Is(statErr, os.ErrNotExist) {
			t.Errorf("%s: a refused manifest must not be written", name)
		}
	}
}

// manifestRun signs releases with one key into directories of dir, each
// with a bundle of its own version, an nginx image of the registry stub
// unless extra gives another --images, and the extra arguments.
type manifestRun struct {
	t    *testing.T
	dir  string
	host string
}

func newManifestRun(t *testing.T, host string) manifestRun {
	t.Helper()
	dir := t.TempDir()
	if err := keygen([]string{"--out", dir}); err != nil {
		t.Fatal(err)
	}
	return manifestRun{t: t, dir: dir, host: host}
}

func (r manifestRun) sign(version, out string, extra ...string) error {
	r.t.Helper()
	bundlePath := writeBundle(r.t, r.dir, version, time.Date(2026, 11, 2, 9, 0, 0, 0, time.UTC))
	args := []string{
		"--key", filepath.Join(r.dir, "release.key"), "--out", out, "--version", version,
		"--bundle", bundlePath, "--bundle-url", "file://" + bundlePath,
		"--images", "nginx=" + r.host + "/kvs-install/nginx:" + version,
	}
	return manifestCmd(append(args, extra...))
}

// refused wants the run refused with an error starting with want, and no
// manifest written into out.
func (r manifestRun) refused(name, out string, err error, want string) {
	r.t.Helper()
	if err == nil || !strings.HasPrefix(err.Error(), want) {
		r.t.Errorf("%s must be refused, saying %q: %v", name, want, err)
	}
	if _, statErr := os.Stat(filepath.Join(out, "manifest.json")); !errors.Is(statErr, os.ErrNotExist) {
		r.t.Errorf("%s: a refused manifest must not be written", name)
	}
}

// kvsctlMins reads requires.kvsctl_min of every release of the manifest
// written into dir, by version, from the file itself.
func kvsctlMins(t *testing.T, dir string) map[string]string {
	t.Helper()
	raw, err := os.ReadFile(filepath.Join(dir, "manifest.json"))
	if err != nil {
		t.Fatal(err)
	}
	var file struct {
		Releases []struct {
			Version  string         `json:"version"`
			Requires map[string]any `json:"requires"`
		} `json:"releases"`
	}
	if err := json.Unmarshal(raw, &file); err != nil {
		t.Fatal(err)
	}
	out := map[string]string{}
	for _, r := range file.Releases {
		if v, ok := r.Requires["kvsctl_min"].(string); ok {
			out[r.Version] = v
		}
	}
	return out
}

// The manifest of a candidate is signed into the candidate channel and the
// one of a release into the stable channel, whatever the previous manifest
// says: kvsctl reads the stable channel alone from the URL of the latest
// release, so a candidate published as the latest release by mistake does
// not pass for the stable list. Both extend the stable list, never the list
// of a candidate, which would carry the candidate into the stable list.
func TestManifestCommandSignsTheChannelOfTheVersion(t *testing.T) {
	registry := registryStub()
	defer registry.Close()
	run := newManifestRun(t, strings.TrimPrefix(registry.URL, "http://"))
	signed := func(out string) *manifest.Manifest {
		t.Helper()
		return readManifest(t, out, run.dir).Manifest
	}
	versions := func(m *manifest.Manifest) string {
		var list []string
		for _, r := range m.Releases {
			list = append(list, r.Version)
		}
		return strings.Join(list, " ")
	}

	stable := filepath.Join(run.dir, "stable")
	if err := run.sign("26.10.0", stable); err != nil {
		t.Fatal(err)
	}
	if m := signed(stable); m.Channel != "stable" {
		t.Errorf("26.10.0 is signed into channel %q, want stable", m.Channel)
	}
	candidate := filepath.Join(run.dir, "candidate")
	if err := run.sign("26.11.0-rc1", candidate, "--previous", filepath.Join(stable, "manifest.json")); err != nil {
		t.Fatal(err)
	}
	if m := signed(candidate); m.Channel != "candidate" || versions(m) != "26.11.0-rc1 26.10.0" {
		t.Errorf("the candidate is signed into channel %q with %s, want candidate with 26.11.0-rc1 26.10.0", m.Channel, versions(m))
	}
	final := filepath.Join(run.dir, "final")
	if err := run.sign("26.11.0", final, "--previous", filepath.Join(stable, "manifest.json")); err != nil {
		t.Fatal(err)
	}
	if m := signed(final); m.Channel != "stable" || versions(m) != "26.11.0 26.10.0" {
		t.Errorf("the release is signed into channel %q with %s, want stable with 26.11.0 26.10.0", m.Channel, versions(m))
	}

	previous := filepath.Join(candidate, "manifest.json")
	for _, version := range []string{"26.11.0-rc2", "26.11.0"} {
		out := filepath.Join(run.dir, "on-the-candidate-"+version)
		err := run.sign(version, out, "--previous", previous)
		run.refused(version+" on the list of a candidate", out, err, "--previous "+previous+` is a manifest of channel "candidate"`)
	}
}

// requires.kvsctl_min names the oldest kvsctl that may install a release.
// update-cli installs the kvsctl a release ships, so the minimum is never
// newer than the release, except for a candidate of that version, which
// asks for its own kvsctl. Every later manifest carries the minimum of each
// release unchanged, and a release signed again takes the new one. What is
// signed is the manifest as the manifest package writes it: the next
// release extends it through manifest.Parse, which would drop a field
// written beside those types.
func TestManifestCommandWritesKvsctlMin(t *testing.T) {
	registry := registryStub()
	defer registry.Close()
	run := newManifestRun(t, strings.TrimPrefix(registry.URL, "http://"))
	signs := func(name, version, out string, want map[string]string, extra ...string) {
		t.Helper()
		// --database writes one more field of the release, so the bytes
		// compared below also say where requires sits among them.
		if err := run.sign(version, out, append([]string{"--database", "none"}, extra...)...); err != nil {
			t.Fatalf("%s: %v", name, err)
		}
		raw := readManifest(t, out, run.dir).Raw
		if got := kvsctlMins(t, out); fmt.Sprint(got) != fmt.Sprint(want) {
			t.Errorf("%s: kvsctl_min = %v, want %v", name, got, want)
		}
		m, err := manifest.Parse(raw)
		if err != nil {
			t.Fatal(err)
		}
		again, err := json.MarshalIndent(m, "", "  ")
		if err != nil {
			t.Fatal(err)
		}
		signed, written := strings.Split(string(raw), "\n"), strings.Split(string(again), "\n")
		for i := range min(len(signed), len(written)) {
			if signed[i] != written[i] {
				t.Errorf("%s: line %d of the manifest is %q, where the manifest package writes %q", name, i+1, signed[i], written[i])
				break
			}
		}
		if len(signed) != len(written) {
			t.Errorf("%s: the manifest has %d lines, and the manifest package writes %d", name, len(signed), len(written))
		}
	}

	first := filepath.Join(run.dir, "first")
	signs("an older kvsctl", "26.10.0", first, map[string]string{"26.10.0": "26.9.0"}, "--kvsctl-min", "26.9.0")
	second := filepath.Join(run.dir, "second")
	signs("the kvsctl of the release", "26.11.0", second, map[string]string{"26.10.0": "26.9.0", "26.11.0": "26.11.0"},
		"--previous", filepath.Join(first, "manifest.json"), "--kvsctl-min", "26.11.0")
	signs("the candidate of the minimum", "26.12.0-rc1", filepath.Join(run.dir, "candidate"),
		map[string]string{"26.10.0": "26.9.0", "26.11.0": "26.11.0", "26.12.0-rc1": "26.12.0-rc1"},
		"--previous", filepath.Join(second, "manifest.json"), "--kvsctl-min", "26.12.0")
	signs("a release without a minimum", "26.12.0", filepath.Join(run.dir, "third"),
		map[string]string{"26.10.0": "26.9.0", "26.11.0": "26.11.0"},
		"--previous", filepath.Join(second, "manifest.json"))
	signs("a release signed again", "26.11.0", filepath.Join(run.dir, "again"),
		map[string]string{"26.10.0": "26.9.0"},
		"--previous", filepath.Join(second, "manifest.json"))

	notVersion := func(value string) string {
		_, err := semver.Parse(value)
		if err == nil {
			t.Fatalf("%s is a version", value)
		}
		return "--kvsctl-min: " + err.Error()
	}
	for name, c := range map[string]struct{ version, value, want string }{
		"a minimum that is no version":                   {"26.12.0", "26.12", notVersion("26.12")},
		"a minimum newer than the release":               {"26.12.0", "26.12.1", "--kvsctl-min 26.12.1 is newer than the release 26.12.0"},
		"a minimum newer than what a candidate leads to": {"26.12.0-rc1", "26.12.1", "--kvsctl-min 26.12.1 is newer than the release 26.12.0-rc1"},
		"a minimum of a later candidate":                 {"26.12.0-rc1", "26.12.0-rc2", "--kvsctl-min 26.12.0-rc2 is newer than the release 26.12.0-rc1"},
	} {
		out := filepath.Join(run.dir, strings.ReplaceAll(name, " ", "-"))
		err := run.sign(c.version, out, "--previous", filepath.Join(second, "manifest.json"), "--kvsctl-min", c.value)
		run.refused(name, out, err, c.want)
	}

	// A minimum the previous manifest carries is a version too.
	raw, err := os.ReadFile(filepath.Join(first, "manifest.json"))
	if err != nil {
		t.Fatal(err)
	}
	broken := filepath.Join(run.dir, "broken.json")
	if err := os.WriteFile(broken, []byte(strings.Replace(string(raw), `"kvsctl_min": "26.9.0"`, `"kvsctl_min": "soon"`, 1)), 0o644); err != nil {
		t.Fatal(err)
	}
	out := filepath.Join(run.dir, "on-a-broken-minimum")
	if err := run.sign("26.11.0", out, "--previous", broken); err == nil || !strings.Contains(err.Error(), "release 26.10.0: kvsctl_min") {
		t.Errorf("a previous manifest whose kvsctl_min is no version must be refused: %v", err)
	}
}

// requires.php_series is what kvsctl offers an installation, so it names
// exactly the PHP series the images cover, oldest first, and the default
// series is one of them.
func TestManifestCommandChecksThePHPSeriesAgainstTheImages(t *testing.T) {
	registry := registryStub()
	defer registry.Close()
	host := strings.TrimPrefix(registry.URL, "http://")
	run := newManifestRun(t, host)
	images := []string{"--images", fmt.Sprintf("nginx=%[1]s/kvs-install/nginx:26.11.0,php-fpm@8.1=%[1]s/kvs-install/php:26.11.0-php8.1,php-fpm@8.2=%[1]s/kvs-install/php:26.11.0-php8.2", host)}

	valid := filepath.Join(run.dir, "valid")
	if err := run.sign("26.11.0", valid, append(images, "--php-series", "8.2,8.1", "--php", "8.2")...); err != nil {
		t.Fatalf("the series of the images must be signed: %v", err)
	}
	rel := readManifest(t, valid, run.dir).Manifest.Latest()
	if got := strings.Join(rel.Requires.PHPSeries, ","); got != "8.1,8.2" || rel.Requires.PHP != "8.2" {
		t.Errorf("php_series %s and php %s, want 8.1,8.2 and 8.2", got, rel.Requires.PHP)
	}
	for name, c := range map[string]struct {
		args []string
		want string
	}{
		"a series missing from --php-series": {[]string{"--php-series", "8.1"}, "the release publishes images for PHP 8.2, which --php-series does not list"},
		"a series without images":            {[]string{"--php-series", "8.1,8.2,8.3"}, "--php-series lists PHP 8.3, for which the release publishes no image"},
		"a default series without images":    {[]string{"--php", "8.3"}, "--php 8.3 is not a series the release publishes images for (8.1, 8.2)"},
	} {
		out := filepath.Join(run.dir, strings.ReplaceAll(name, " ", "-"))
		err := run.sign("26.11.0", out, append(append([]string{}, images...), c.args...)...)
		run.refused(name, out, err, c.want)
	}
}

// A highlight is a line of the confirmation screen: at most three, none
// empty, none on two lines.
func TestManifestCommandRefusesHighlightsKvsctlCannotShow(t *testing.T) {
	registry := registryStub()
	defer registry.Close()
	run := newManifestRun(t, strings.TrimPrefix(registry.URL, "http://"))
	valid := filepath.Join(run.dir, "valid")
	if err := run.sign("26.11.0", valid, "--highlight", "one", "--highlight", "two", "--highlight", "three"); err != nil {
		t.Fatalf("three highlights must be signed: %v", err)
	}
	if got := strings.Join(readManifest(t, valid, run.dir).Manifest.Latest().Highlights, "|"); got != "one|two|three" {
		t.Errorf("highlights %q, want one|two|three", got)
	}
	for name, c := range map[string]struct {
		args []string
		want string
	}{
		"four highlights":          {[]string{"--highlight", "1", "--highlight", "2", "--highlight", "3", "--highlight", "4"}, "4 highlights: at most three"},
		"an empty highlight":       {[]string{"--highlight", "one", "--highlight", " "}, "a --highlight is empty"},
		"a highlight on two lines": {[]string{"--highlight", "one\ntwo"}, `--highlight "one\ntwo" holds more than one line`},
		// A carriage return sends a terminal back to the start of the line,
		// and what follows it overwrites what came before.
		"a highlight with a carriage return": {[]string{"--highlight", "one\rtwo"}, `--highlight "one\rtwo" holds more than one line`},
		// A no-break, figure or ideographic space prints as blank a line
		// as a space does: every Unicode white space is trimmed.
		"a highlight of Unicode white space": {[]string{"--highlight", "  　\u0085 "}, "a --highlight is empty"},
	} {
		out := filepath.Join(run.dir, strings.ReplaceAll(name, " ", "-"))
		run.refused(name, out, run.sign("26.11.0", out, c.args...), c.want)
	}
}

// A stop is a version kvsctl sends older installations through, so it has
// to be a release of the manifest: a version that was never published would
// block them for good, since every later manifest carries the release that
// names it. The refusal names the releases there are.
func TestManifestCommandRefusesAStopThatIsNoRelease(t *testing.T) {
	registry := registryStub()
	defer registry.Close()
	host := strings.TrimPrefix(registry.URL, "http://")
	dir := t.TempDir()
	if err := keygen([]string{"--out", dir}); err != nil {
		t.Fatal(err)
	}
	site := filepath.Join(dir, "site")
	release := func(version, out string, extra ...string) error {
		bundlePath := writeBundle(t, dir, version, time.Date(2026, 10, 5, 18, 39, 32, 0, time.UTC))
		args := []string{
			"--key", filepath.Join(dir, "release.key"), "--out", out, "--version", version,
			"--bundle", bundlePath, "--bundle-url", "file://" + bundlePath,
			"--images", "nginx=" + host + "/kvs-install/nginx:" + version,
		}
		return manifestCmd(append(args, extra...))
	}
	for _, version := range []string{"26.10.0", "26.10.1"} {
		var previous []string
		if version != "26.10.0" {
			previous = []string{"--previous", filepath.Join(site, "manifest.json")}
		}
		if err := release(version, site, previous...); err != nil {
			t.Fatal(err)
		}
	}
	previous := []string{"--previous", filepath.Join(site, "manifest.json")}

	refused := filepath.Join(dir, "refused")
	err := release("26.11.0", refused, append(previous, "--min-from", "26.10.9")...)
	if err == nil || !strings.Contains(err.Error(), "--min-from 26.10.9 names no release") || !strings.Contains(err.Error(), "26.10.1, 26.10.0") {
		t.Errorf("a stop that was never released must be refused with the releases there are: %v", err)
	}
	if _, statErr := os.Stat(filepath.Join(refused, "manifest.json")); !errors.Is(statErr, os.ErrNotExist) {
		t.Error("a refused manifest must not be written")
	}
	// Without the previous manifest there is no release to stop at.
	err = release("26.11.0", refused, "--min-from", "26.10.1")
	if err == nil || !strings.Contains(err.Error(), "--previous") {
		t.Errorf("a stop with no previous manifest must point at --previous: %v", err)
	}

	if err := release("26.11.0", site, append(previous, "--min-from", "26.10.1")...); err != nil {
		t.Fatalf("a stop on a published release must be signed: %v", err)
	}
	m := readManifest(t, site, dir).Manifest
	if m.Latest().Requires.MinFrom != "26.10.1" || m.Find("26.10.1") == nil {
		t.Errorf("the release must name a stop the manifest holds: %+v", m.Releases)
	}
}

// The release date is the time of the release commit, which every member of
// the bundle carries, and not the day the manifest is signed: kvsctl blocks
// an upgrade that would lay a release over an adopted git checkout whose
// commit is newer, and a publish job approved or run again days after the
// tag would otherwise let through every commit made in between.
func TestManifestCommandDatesTheReleaseByItsCommit(t *testing.T) {
	registry := registryStub()
	defer registry.Close()
	host := strings.TrimPrefix(registry.URL, "http://")
	dir := t.TempDir()
	if err := keygen([]string{"--out", dir}); err != nil {
		t.Fatal(err)
	}
	repo := gitRepo(t, map[string]string{"docker/docker-compose.yml": stackCompose, "README.md": "readme\n"}, nil)
	git := []string{"-C", repo, "-c", "user.name=test", "-c", "user.email=test@example.com", "-c", "commit.gpgsign=false"}
	amend := exec.Command("git", append(git, "commit", "-q", "--amend", "--no-edit")...)
	amend.Env = append(os.Environ(), "GIT_COMMITTER_DATE=1759689572 +0000", "GIT_AUTHOR_DATE=1759689572 +0000")
	if out, err := amend.CombinedOutput(); err != nil {
		t.Fatalf("git commit --amend: %v\n%s", err, out)
	}
	images, digests := workflowSpecs()
	bundlePath := filepath.Join(dir, "kvs-stack-26.11.0.tar.gz")
	if err := bundle([]string{"--repo", repo, "--ref", "HEAD", "--version", "26.11.0", "--images", images, "--digests", digests, "--out", bundlePath}); err != nil {
		t.Fatal(err)
	}
	args := func(out, bundlePath string) []string {
		return []string{
			"--key", filepath.Join(dir, "release.key"), "--out", out, "--version", "26.11.0",
			"--bundle", bundlePath, "--bundle-url", "file://" + bundlePath,
			"--images", "nginx=" + host + "/kvs-install/nginx:26.11.0",
		}
	}
	site := filepath.Join(dir, "site")
	if err := manifestCmd(args(site, bundlePath)); err != nil {
		t.Fatal(err)
	}
	committed, err := exec.Command("git", "-C", repo, "log", "-1", "--format=%cI").Output()
	if err != nil {
		t.Fatal(err)
	}
	date := readManifest(t, site, dir).Manifest.Latest().Date
	if date != "2025-10-05T18:39:32Z" || !strings.HasPrefix(strings.TrimSpace(string(committed)), "2025-10-05T18:39:32") {
		t.Errorf("date = %q, want the commit time %s as RFC3339", date, strings.TrimSpace(string(committed)))
	}

	// The bundle has to be the one of the version, and one kvsctl-release
	// built: a member with its own time dates nothing.
	stamp := time.Date(2026, 10, 5, 18, 39, 32, 0, time.UTC)
	other := writeBundle(t, t.TempDir(), "26.10.0", stamp)
	mixed := filepath.Join(dir, "mixed.tar.gz")
	writeTarGz(t, mixed, []tarMember{
		{"docker/RELEASE", "26.11.0\n", stamp},
		{"docker/setup.sh", "#!/bin/sh\n", stamp.Add(time.Hour)},
	})
	noRelease := filepath.Join(dir, "norelease.tar.gz")
	writeTarGz(t, noRelease, []tarMember{{"docker/setup.sh", "#!/bin/sh\n", stamp}})
	plain := filepath.Join(dir, "plain.tar.gz")
	if err := os.WriteFile(plain, []byte("a bundle"), 0o644); err != nil {
		t.Fatal(err)
	}
	for name, c := range map[string]struct{ path, want string }{
		"the bundle of another version": {other, "is the bundle of 26.10.0, not of 26.11.0"},
		"members of different times":    {mixed, "docker/setup.sh carries"},
		"no docker/RELEASE":             {noRelease, "holds no docker/RELEASE"},
		"a file that is no bundle":      {plain, "is not a .tar.gz"},
	} {
		out := filepath.Join(dir, strings.ReplaceAll(name, " ", "-"))
		if err := manifestCmd(args(out, c.path)); err == nil || !strings.Contains(err.Error(), c.want) {
			t.Errorf("%s: want an error saying %q, got %v", name, c.want, err)
		}
		if _, statErr := os.Stat(filepath.Join(out, "manifest.json")); !errors.Is(statErr, os.ErrNotExist) {
			t.Errorf("%s: a refused manifest must not be written", name)
		}
	}
}

// A rotation announces the new key in releases signed with both keys: the
// release that switches checks the manifest it extends with the new key
// alone. A next key forgotten in the release environment is refused at the
// first announcing release, not discovered at the switch.
func TestManifestCommandRefusesAnAnnouncedKeyThatDoesNotSign(t *testing.T) {
	registry := registryStub()
	defer registry.Close()
	host := strings.TrimPrefix(registry.URL, "http://")
	dir := t.TempDir()
	if err := keygen([]string{"--out", dir}); err != nil {
		t.Fatal(err)
	}
	next := filepath.Join(dir, "next")
	if err := keygen([]string{"--out", next}); err != nil {
		t.Fatal(err)
	}
	nextPub := readPub(t, next)
	announce := manifest.KeyID(nextPub) + "=" + base64.StdEncoding.EncodeToString(nextPub) + "@2026-12-01"
	bundlePath := writeBundle(t, dir, "26.11.0", time.Date(2026, 11, 2, 9, 0, 0, 0, time.UTC))
	args := func(out string, keys ...string) []string {
		a := []string{
			"--out", out, "--version", "26.11.0", "--announce-key", announce,
			"--bundle", bundlePath, "--bundle-url", "file://" + bundlePath,
			"--images", "nginx=" + host + "/kvs-install/nginx:26.11.0",
		}
		for _, key := range keys {
			a = append(a, "--key", key)
		}
		return a
	}

	forgotten := filepath.Join(dir, "forgotten")
	err := manifestCmd(args(forgotten, filepath.Join(dir, "release.key")))
	if err == nil || !strings.Contains(err.Error(), manifest.KeyID(nextPub)) || !strings.Contains(err.Error(), "KVSCTL_RELEASE_KEY_NEXT") {
		t.Errorf("an announced key that does not sign must be refused, naming it and the secret: %v", err)
	}
	if _, statErr := os.Stat(filepath.Join(forgotten, "manifest.json")); !errors.Is(statErr, os.ErrNotExist) {
		t.Error("a refused manifest must not be written")
	}

	// Signed with both keys, the manifest verifies with the new key alone,
	// which is how the switch release checks it.
	site := filepath.Join(dir, "site")
	if err := manifestCmd(args(site, filepath.Join(dir, "release.key"), filepath.Join(next, "release.key"))); err != nil {
		t.Fatal(err)
	}
	newKey := base64.StdEncoding.EncodeToString(nextPub)
	if err := verify([]string{"--manifest", filepath.Join(site, "manifest.json"), "--signature", filepath.Join(site, "manifest.json.sig"), "--pub", newKey}); err != nil {
		t.Errorf("the announcing manifest must verify with the announced key alone: %v", err)
	}
}

// bigManifest writes a manifest of about size bytes to path: releases older
// than 26.11.0, each with one image of 250 layers, the order of what a
// release of the stack lists.
func bigManifest(t *testing.T, path string, size int) {
	t.Helper()
	one := func(n int) manifest.Release {
		r := manifest.Release{
			Version: fmt.Sprintf("25.%d.%d", 1+n/50, n%50),
			Date:    "2025-01-01T00:00:00Z",
			Bundle:  manifest.Asset{URL: fmt.Sprintf("https://example.com/%d.tar.gz", n), SHA256: strings.Repeat("0", 64), Size: 1},
		}
		image := manifest.Image{Service: "nginx", Ref: "example.com/nginx:" + r.Version, Digest: fmt.Sprintf("sha256:%064x", n), Size: 1}
		for k := 0; k < 250; k++ {
			image.Layers = append(image.Layers, manifest.Layer{Digest: fmt.Sprintf("sha256:%064x", k), DiffID: fmt.Sprintf("sha256:%064x", k+1), Size: 123456789})
		}
		r.Images = []manifest.Image{image}
		return r
	}
	encode := func(releases int) []byte {
		m := manifest.Manifest{Schema: manifest.Schema, Channel: "stable", Updated: "2025-01-01T00:00:00Z"}
		for n := releases - 1; n >= 0; n-- {
			m.Releases = append(m.Releases, one(n))
		}
		raw, err := json.MarshalIndent(m, "", "  ")
		if err != nil {
			t.Fatal(err)
		}
		return raw
	}
	perRelease := len(encode(2)) - len(encode(1))
	raw := encode(size / perRelease)
	if err := os.WriteFile(path, raw, 0o644); err != nil {
		t.Fatal(err)
	}
}

// captureStderr runs f with os.Stderr sent to a file and returns what f
// wrote there.
func captureStderr(t *testing.T, f func()) string {
	t.Helper()
	file, err := os.Create(filepath.Join(t.TempDir(), "stderr"))
	if err != nil {
		t.Fatal(err)
	}
	saved := os.Stderr
	os.Stderr = file
	defer func() { os.Stderr = saved }()
	f()
	if err := file.Close(); err != nil {
		t.Fatal(err)
	}
	out, err := os.ReadFile(file.Name())
	if err != nil {
		t.Fatal(err)
	}
	return string(out)
}

// The manifest lists every release and only grows, and kvsctl reads 8 MiB
// of it at most. kvsctl-release warns while there is room left and refuses
// to sign what no installed kvsctl would read.
func TestManifestCommandBoundsTheManifestSize(t *testing.T) {
	registry := registryStub()
	defer registry.Close()
	host := strings.TrimPrefix(registry.URL, "http://")
	dir := t.TempDir()
	if err := keygen([]string{"--out", dir}); err != nil {
		t.Fatal(err)
	}
	bundlePath := writeBundle(t, dir, "26.11.0", time.Date(2026, 11, 2, 9, 0, 0, 0, time.UTC))
	release := func(out, previous string) error {
		return manifestCmd([]string{
			"--key", filepath.Join(dir, "release.key"), "--out", out, "--version", "26.11.0",
			"--bundle", bundlePath, "--bundle-url", "file://" + bundlePath,
			"--images", "nginx=" + host + "/kvs-install/nginx:26.11.0",
			"--previous", previous,
		})
	}

	near := filepath.Join(dir, "near.json")
	bigManifest(t, near, 7<<20)
	for _, c := range []struct{ actions, prefix string }{{"", "kvsctl-release: warning: "}, {"true", "::warning::"}} {
		t.Setenv("GITHUB_ACTIONS", c.actions)
		site := filepath.Join(dir, "near"+c.actions)
		var err error
		warned := captureStderr(t, func() { err = release(site, near) })
		if err != nil {
			t.Fatalf("a manifest under the limit must be signed: %v", err)
		}
		if !strings.HasPrefix(warned, c.prefix+"the manifest is ") || !strings.Contains(warned, " MiB of the 8.0 MiB kvsctl reads") || !strings.Contains(warned, "more releases fit") {
			t.Errorf("GITHUB_ACTIONS=%q: a manifest near the limit must warn, got %q", c.actions, warned)
		}
		if info, err := os.Stat(filepath.Join(site, "manifest.json")); err != nil || info.Size() <= warnManifest || info.Size() > maxManifest {
			t.Fatalf("the signed manifest must lie between the warning and the limit: %v, %v", info, err)
		}
	}
	small := filepath.Join(dir, "small.json")
	bigManifest(t, small, 1<<20)
	if warned := captureStderr(t, func() {
		if err := release(filepath.Join(dir, "small"), small); err != nil {
			t.Error(err)
		}
	}); warned != "" {
		t.Errorf("a manifest far from the limit must not warn: %q", warned)
	}

	over := filepath.Join(dir, "over.json")
	bigManifest(t, over, maxManifest+128<<10)
	site := filepath.Join(dir, "over")
	err := release(site, over)
	if err == nil || !strings.Contains(err.Error(), "kvsctl reads at most 8.0 MiB") {
		t.Errorf("a manifest larger than kvsctl reads must be refused: %v", err)
	}
	if _, statErr := os.Stat(filepath.Join(site, "manifest.json")); !errors.Is(statErr, os.ErrNotExist) {
		t.Error("a refused manifest must not be written")
	}
}

// kvsctl-release signs a manifest of up to maxManifest bytes, so every kvsctl
// has to read that much: the kvsctl of this tree, checked by fetching a
// signed manifest of that size the way it fetches one, and every kvsctl
// still installed, down to the first releases, which read 8 MiB at most. An
// installation keeps its kvsctl until update-cli replaces it, and update-cli
// reads the manifest first, so a newer kvsctl reading more is no reason to
// raise maxManifest: the older ones could then neither see a release nor
// update.
func TestManifestLimitIsReadByEveryKvsctl(t *testing.T) {
	if maxManifest > 8<<20 {
		t.Errorf("maxManifest is %d bytes, more than the 8 MiB the first kvsctl releases read: installations still on one could neither read the releases nor run update-cli", maxManifest)
	}
	// kvsctl-release signs up to the limit, and not a byte more.
	captureStderr(t, func() {
		if err := checkSize(maxManifest, 100); err != nil {
			t.Errorf("a manifest of maxManifest bytes must be signed: %v", err)
		}
		if err := checkSize(maxManifest+1, 100); err == nil {
			t.Error("a manifest of a byte more than maxManifest must be refused")
		}
	})

	pub, priv, err := ed25519.GenerateKey(nil)
	if err != nil {
		t.Fatal(err)
	}
	zeros := strings.Repeat("0", 64)
	body := `{"schema":2,"channel":"stable","updated":"2026-10-06T12:00:00Z","releases":[` +
		`{"version":"26.10.0","date":"2026-10-05T18:39:32Z","bundle":{"url":"file:///b.tar.gz","sha256":"` + zeros + `"},` +
		`"images":[{"service":"nginx","ref":"r/nginx:26.10.0","digest":"sha256:aaa","size":5}]}]}`
	// JSON allows spaces after the document, so the padding keeps it valid
	// and signed.
	raw := []byte(body + strings.Repeat(" ", maxManifest-len(body)))
	sig, err := signManifest(raw, []signer{{id: manifest.KeyID(pub), priv: priv}})
	if err != nil {
		t.Fatal(err)
	}
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		switch r.URL.Path {
		case "/manifest.json":
			w.Write(raw)
		case "/manifest.json.sig":
			w.Write(sig)
		default:
			http.NotFound(w, r)
		}
	}))
	defer server.Close()
	doc, err := manifest.Fetch(server.URL + "/manifest.json")
	if err == nil {
		err = doc.VerifyAny([]ed25519.PublicKey{pub})
	}
	if err != nil {
		t.Errorf("kvsctl must read a manifest of %d bytes, which kvsctl-release signs: %v", maxManifest, err)
	}
}

// refusingRegistry answers every read with the challenge of a registry that
// hands out anonymous tokens, and its token service with status and body.
func refusingRegistry(status int, body string) *httptest.Server {
	mux := http.NewServeMux()
	var server *httptest.Server
	mux.HandleFunc("/v2/", func(w http.ResponseWriter, r *http.Request) {
		if r.Header.Get("Authorization") == "" {
			w.Header().Set("WWW-Authenticate", fmt.Sprintf(`Bearer realm="%s/token",service="test",scope="repository:x:pull"`, server.URL))
			w.WriteHeader(http.StatusUnauthorized)
			return
		}
		http.NotFound(w, r)
	})
	mux.HandleFunc("/token", func(w http.ResponseWriter, r *http.Request) {
		w.WriteHeader(status)
		fmt.Fprint(w, body)
	})
	server = httptest.NewServer(mux)
	return server
}

func TestRegistryRefusals(t *testing.T) {
	cases := map[string]struct {
		status   int
		body     string
		contains []string
	}{
		"a token service refusing an anonymous reader": {http.StatusForbidden, `{"errors":[{"code":"DENIED"}]}`, []string{"403", "must be public"}},
		"a token service answering without a token":    {http.StatusOK, `{}`, []string{"without a token"}},
		"a public image without the tag":               {http.StatusOK, `{"token":"t"}`, []string{"404"}},
	}
	for name, c := range cases {
		registry := refusingRegistry(c.status, c.body)
		ref := strings.TrimPrefix(registry.URL, "http://") + "/kvs-install/nginx:26.11.0"
		_, _, _, err := registryDigest(ref)
		registry.Close()
		if err == nil {
			t.Errorf("%s: the read must fail", name)
			continue
		}
		for _, want := range c.contains {
			if !strings.Contains(err.Error(), want) {
				t.Errorf("%s: %q does not say %q", name, err, want)
			}
		}
		if name == "a public image without the tag" && strings.Contains(err.Error(), "public") {
			t.Errorf("%s: a missing tag of another registry is not a visibility problem: %v", name, err)
		}
	}
}

// GHCR gives an anonymous reader the same refusal for a private package as
// for one that does not exist, and creates every new package private, so
// its refusals point at the package settings and at the publish job.
func TestExplainRefusal(t *testing.T) {
	for _, status := range []int{http.StatusUnauthorized, http.StatusForbidden, http.StatusNotFound} {
		err := explainRefusal("ghcr.io", &registryError{url: "https://ghcr.io/token", status: status, text: http.StatusText(status)})
		for _, want := range []string{"private", "Change visibility", "Public", "re-run the publish job"} {
			if !strings.Contains(err.Error(), want) {
				t.Errorf("GHCR %d: %q does not say %q", status, err, want)
			}
		}
		if status == http.StatusNotFound && !strings.Contains(err.Error(), "never pushed") {
			t.Errorf("GHCR 404 may also be a tag that was never pushed: %v", err)
		}
	}
	plain := &registryError{url: "https://ghcr.io/v2/x/manifests/1", status: http.StatusInternalServerError, text: "500 Internal Server Error"}
	if err := explainRefusal("ghcr.io", plain); err.Error() != plain.Error() {
		t.Errorf("a server error is not a visibility problem: %v", err)
	}
	other := errors.New("connection refused")
	if err := explainRefusal("ghcr.io", other); err != other {
		t.Errorf("an error that is no registry answer is passed through: %v", err)
	}
	if err := explainRefusal("registry-1.docker.io", &registryError{status: http.StatusUnauthorized, text: "401 Unauthorized"}); !strings.Contains(err.Error(), "must be public") {
		t.Errorf("another registry refusing an anonymous read: %v", err)
	}
}

// verify accepts a manifest signed by any of the keys given and refuses one
// signed by none of them, in both forms the signature file takes. A bare
// base64 line is not a signature file. With --all, every signature has to
// match: that is how the release workflow proves each key it signed with is
// trusted by the kvsctl it ships.
func TestVerifyCommand(t *testing.T) {
	dir := t.TempDir()
	zeros := strings.Repeat("0", 64)
	raw := []byte(`{"schema":2,"channel":"stable","updated":"2026-09-24T09:00:00Z","releases":[
 {"version":"0.1.0","date":"2026-09-01","bundle":{"url":"file:///b1.tar.gz","sha256":"` + zeros + `"},"images":[{"service":"nginx","ref":"r/nginx:0.1.0","digest":"sha256:aaa","size":5}]}
]}`)
	pub, priv, err := ed25519.GenerateKey(nil)
	if err != nil {
		t.Fatal(err)
	}
	otherPub, otherPriv, err := ed25519.GenerateKey(nil)
	if err != nil {
		t.Fatal(err)
	}
	manifestPath := filepath.Join(dir, "manifest.json")
	if err := os.WriteFile(manifestPath, raw, 0o600); err != nil {
		t.Fatal(err)
	}
	sig := base64.StdEncoding.EncodeToString(ed25519.Sign(priv, raw))
	forms := map[string]string{
		"list":   fmt.Sprintf(`[{"key_id":%q,"alg":"ed25519","sig":%q}]`, manifest.KeyID(pub), sig),
		"object": fmt.Sprintf(`{"key_id":%q,"alg":"ed25519","sig":%q}`, manifest.KeyID(pub), sig),
	}
	good := base64.StdEncoding.EncodeToString(pub)
	other := base64.StdEncoding.EncodeToString(otherPub)
	for name, content := range forms {
		sigPath := filepath.Join(dir, name+".sig")
		if err := os.WriteFile(sigPath, []byte(content), 0o600); err != nil {
			t.Fatal(err)
		}
		if err := verify([]string{"--manifest", manifestPath, "--signature", sigPath, "--pub", other, "--pub", "main=" + good}); err != nil {
			t.Errorf("%s form, the right key among two: %v", name, err)
		}
		if err := verify([]string{"--manifest", manifestPath, "--signature", sigPath, "--pub", other}); err == nil {
			t.Errorf("%s form, a key that did not sign was accepted", name)
		}
	}
	bare := filepath.Join(dir, "bare.sig")
	if err := os.WriteFile(bare, []byte(sig+"\n"), 0o600); err != nil {
		t.Fatal(err)
	}
	if err := verify([]string{"--manifest", manifestPath, "--signature", bare, "--pub", good}); err == nil {
		t.Error("a bare base64 signature was accepted")
	}
	if err := verify([]string{"--manifest", manifestPath}); err == nil {
		t.Error("missing flags were accepted")
	}

	// Two signatures, the second by a key the trusted list lacks.
	otherSig := base64.StdEncoding.EncodeToString(ed25519.Sign(otherPriv, raw))
	both := filepath.Join(dir, "both.sig")
	content := fmt.Sprintf(`[{"key_id":%q,"alg":"ed25519","sig":%q},{"key_id":%q,"alg":"ed25519","sig":%q}]`, manifest.KeyID(pub), sig, manifest.KeyID(otherPub), otherSig)
	if err := os.WriteFile(both, []byte(content), 0o600); err != nil {
		t.Fatal(err)
	}
	if err := verify([]string{"--manifest", manifestPath, "--signature", both, "--pub", good}); err != nil {
		t.Errorf("one matching signature is enough without --all: %v", err)
	}
	err = verify([]string{"--manifest", manifestPath, "--signature", both, "--pub", good, "--all"})
	if err == nil || !strings.Contains(err.Error(), manifest.KeyID(otherPub)) {
		t.Errorf("--all must refuse the signature of an untrusted key and name it: %v", err)
	}
	if err := verify([]string{"--manifest", manifestPath, "--signature", both, "--pub", good, "--pub", other, "--all"}); err != nil {
		t.Errorf("--all with both keys trusted: %v", err)
	}
}
