package main

import (
	"bytes"
	"context"
	"crypto/ed25519"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"maps"
	"net/http"
	"net/http/httptest"
	"os"
	"os/exec"
	"path"
	"path/filepath"
	"regexp"
	"slices"
	"strconv"
	"strings"
	"testing"

	"github.com/MaximeMichaud/KVS-install/cli/internal/dockerx"
	"github.com/MaximeMichaud/KVS-install/cli/internal/instance"
	"github.com/MaximeMichaud/KVS-install/cli/internal/manifest"
	"github.com/MaximeMichaud/KVS-install/cli/internal/release"
	"github.com/MaximeMichaud/KVS-install/cli/internal/semver"
	"github.com/MaximeMichaud/KVS-install/cli/internal/upgrade"
)

// TestShippedRelease checks the release the publish job of the release
// workflow has just signed, before anything is published, with the code
// the kvsctl of that release installs it with: the signature check and the
// parser of the manifest, the download check of the bundle and of the
// kvsctl builds, the unpacking of the bundle, and the plan of an upgrade,
// which picks the images of an installation and the .env keys the compose
// override of the bundle reads, for every PHP and MariaDB series the
// release publishes. A release no installation could take stops the job
// there.
//
// KVSCTL_SHIPPED_DIR names the directory holding the release assets (dist/
// in the workflow), KVSCTL_SHIPPED_VERSION the version, and
// KVSCTL_SHIPPED_KEYS the keys the kvsctl of the release embeds, as
// .github/scripts/release-public-keys.sh prints them. Without a release
// there is nothing to read and the test skips; the workflow runs it with -v
// and wants its PASS line, so a skip there fails the job.
func TestShippedRelease(t *testing.T) {
	dir, version := os.Getenv("KVSCTL_SHIPPED_DIR"), os.Getenv("KVSCTL_SHIPPED_VERSION")
	if dir == "" || version == "" {
		t.Skip("KVSCTL_SHIPPED_DIR and KVSCTL_SHIPPED_VERSION name no release; the publish job of the release workflow sets them")
	}
	keys, err := manifest.ParseKeys(strings.Split(os.Getenv("KVSCTL_SHIPPED_KEYS"), ","))
	if err != nil {
		t.Fatalf("KVSCTL_SHIPPED_KEYS: %v", err)
	}
	problems, err := checkShipped(fakeEngine(t), dir, version, keys)
	if err != nil {
		t.Fatal(err)
	}
	for _, p := range problems {
		t.Error(p)
	}
}

// resetCompose is the first Docker Compose that applies "build: !reset
// null", with which the release override clears the build sections of the
// base compose file. 2.18 reads it as a build from a directory named null.
const resetCompose = "2.19.0"

// overrideVar is an image the release override reads from .env.
var overrideVar = regexp.MustCompile(`^\$\{([A-Za-z0-9_]+):\?[^}]*\}$`)

// recordedSeries names the .env key in which an installation records its
// series on each axis a release varies by: setup.sh writes PHP_VERSION and
// MARIADB_VERSION, and the plan of an upgrade reads them there when no
// container says more.
var recordedSeries = map[string]string{
	manifest.VariantPHP:     "PHP_VERSION",
	manifest.VariantMariaDB: "MARIADB_VERSION",
}

// checkShipped lists what would keep the kvsctl a release ships from
// installing that release, from the assets in dir: manifest.json and its
// signature, the bundle and the kvsctl builds its URLs name. keys are the
// keys that kvsctl embeds, and docker the engine its plans ask. An error is
// a manifest that kvsctl refuses or cannot read at all.
func checkShipped(docker *dockerx.Client, dir, version string, keys []ed25519.PublicKey) ([]string, error) {
	url := "file://" + filepath.Join(dir, "manifest.json")
	doc, err := manifest.Fetch(url)
	if err != nil {
		return nil, fmt.Errorf("kvsctl cannot read the manifest: %w", err)
	}
	if err := doc.VerifyAny(keys); err != nil {
		return nil, fmt.Errorf("kvsctl refuses the manifest: %w", err)
	}
	m := doc.Manifest
	rel := m.Find(version)
	if rel == nil {
		return nil, fmt.Errorf("the manifest does not list %s", version)
	}
	v, err := semver.Parse(version)
	if err != nil {
		return nil, err
	}
	var problems []string
	add := func(format string, args ...any) { problems = append(problems, fmt.Sprintf(format, args...)) }

	if want := channelOf(v); m.Channel != want {
		add("the manifest is of channel %q, and %s belongs to channel %q", m.Channel, version, want)
	}
	if need := rel.Requires.KvsctlMin; need != "" && semver.Less(version, need) {
		add("%s needs kvsctl %s or newer, and the kvsctl it ships is %s: no installation could install it", version, need, version)
	}
	if published := rel.Series(); strings.Join(rel.Requires.PHPSeries, ",") != strings.Join(published, ",") {
		add("requires.php_series is %v, and the release publishes images for PHP %v", rel.Requires.PHPSeries, published)
	}

	work, err := os.MkdirTemp("", "kvsctl-shipped-")
	if err != nil {
		return nil, err
	}
	defer os.RemoveAll(work)
	ctx := context.Background()

	// The kvsctl builds, found the way update-cli finds them, in the part of
	// the manifest every kvsctl reads, and downloaded with the size the
	// manifest signs for them as the bound.
	if _, ok := rel.CLI["linux-amd64"]; !ok {
		add("the release ships no kvsctl for linux-amd64")
	}
	var frozen *manifest.Release
	if cli, err := doc.VerifyCLI(keys); err != nil {
		add("update-cli cannot read the manifest: %v", err)
	} else if frozen = cli.Find(version); frozen == nil {
		add("update-cli does not find %s in the manifest", version)
	}
	for _, platform := range sortedKeys(rel.CLI) {
		asset := rel.CLI[platform]
		if frozen != nil {
			if seen := frozen.CLI[platform]; seen.URL != asset.URL || seen.SHA256 != asset.SHA256 || seen.Size != asset.Size {
				add("update-cli reads the kvsctl for %s as %s with sha256 %q and size %d, and the manifest signs %s with sha256 %q and size %d", platform, seen.URL, seen.SHA256, seen.Size, asset.URL, asset.SHA256, asset.Size)
			}
		}
		if asset.Size <= 0 {
			add("the manifest signs no size for the kvsctl for %s, which kvsctl-release records from the copy in --assets", platform)
		}
		binary := filepath.Join(dir, path.Base(asset.URL))
		if err := release.DownloadSized(ctx, "file://"+binary, asset.SHA256, asset.Size, filepath.Join(work, "kvsctl-"+platform), nil); err != nil {
			add("kvsctl for %s, %s: %v", platform, binary, err)
		}
	}

	// The bundle, downloaded and unpacked the way kvsctl stages it: held to
	// the size and the sha256 the manifest signs.
	bundlePath := filepath.Join(dir, path.Base(rel.Bundle.URL))
	archive := filepath.Join(work, "bundle.tar.gz")
	if rel.Bundle.Size <= 0 {
		add("the manifest signs no size for the bundle of %s", version)
	}
	if err := release.DownloadSized(ctx, "file://"+bundlePath, rel.Bundle.SHA256, rel.Bundle.Size, archive, nil); err != nil {
		add("bundle %s: %v", bundlePath, err)
		return problems, nil
	}
	root := filepath.Join(work, "stack")
	if _, err := release.Extract(archive, root); err != nil {
		add("bundle %s: %v", bundlePath, err)
		return problems, nil
	}
	read := func(name string) string {
		data, err := os.ReadFile(filepath.Join(root, filepath.FromSlash(name)))
		if err != nil {
			add("the bundle: %v", err)
		}
		return string(data)
	}
	if named := strings.TrimSpace(read("docker/RELEASE")); named != version {
		add("docker/RELEASE of the bundle names %q, not %s", named, version)
	}
	services := composeServices(read("docker/docker-compose.yml"))
	overrideText := read("docker/" + releaseOverride)
	override, err := overrideImages(overrideText)
	if err != nil {
		add("docker/%s of the bundle: %v", releaseOverride, err)
		return problems, nil
	}
	if len(services) == 0 {
		add("docker/docker-compose.yml of the bundle lists no service")
		return problems, nil
	}
	for _, service := range services {
		if _, ok := override[service]; !ok {
			add("the override pins no image for %s, which would be built or pulled by tag on the server", service)
		}
	}
	for _, service := range sortedKeys(override) {
		if !slices.Contains(services, service) {
			add("the override names %s, which docker/docker-compose.yml does not run", service)
		}
	}
	if strings.Contains(overrideText, "!reset") {
		if need := rel.Requires.ComposeMin; need == "" || semver.Less(need, resetCompose) {
			add("the override clears build sections with build: !reset null, which Docker Compose applies from %s on, and requires.compose_min is %q", resetCompose, need)
		}
	}

	// Every kind of installation, planned by kvsctl the way check and
	// upgrade plan it, on the files of the bundle: the images the plan
	// picks are the ones kvsctl pulls, and its .env keys the ones it writes
	// for the override to read.
	kinds, unknown := installations(rel)
	problems = append(problems, unknown...)
	// A plan reads the bundle at the URL the manifest gives, which the
	// publish job has not published yet: it reads the asset of dir, and
	// the check stays off the network.
	defer func(saved http.RoundTripper) { http.DefaultTransport = saved }(http.DefaultTransport)
	http.DefaultTransport = shippedAssets(dir)
	for _, kind := range kinds {
		plan, err := shippedPlan(docker, root, url, keys, version, kind.env)
		if err != nil {
			add("%s: kvsctl cannot plan the upgrade: %v", kind.label, err)
			continue
		}
		// The plan reads the bundle at its URL, held to the signed size
		// and sha256, as it does on every installation.
		for _, blocker := range plan.Blockers {
			if strings.HasPrefix(blocker, "the bundle of "+version+" could not be read") {
				add("%s: %s", kind.label, blocker)
			}
		}
		problems = append(problems, comparePlan(kind.label, plan, kind.published(rel), services, override)...)
	}
	return problems, nil
}

// shippedAssets serves a request for an asset of a release with the file
// of that name in the directory that holds the assets, and anything else
// with a 404.
type shippedAssets string

func (dir shippedAssets) RoundTrip(req *http.Request) (*http.Response, error) {
	f, err := os.Open(filepath.Join(string(dir), path.Base(req.URL.Path)))
	if err != nil {
		return &http.Response{StatusCode: http.StatusNotFound, Status: "404 Not Found", Body: http.NoBody, Request: req}, nil
	}
	info, err := f.Stat()
	if err != nil {
		f.Close()
		return nil, err
	}
	return &http.Response{StatusCode: http.StatusOK, Status: "200 OK", ContentLength: info.Size(), Body: f, Request: req}, nil
}

// comparePlan names what the plan of one kind of installation, the images
// the release publishes for it and the override of the bundle disagree on:
// an image the plan picks of another series, or of a service the release
// publishes nothing of for that installation, a service the plan picks no
// image for or one the override runs another image of, a key the override
// reads that the plan does not write, or one it writes that nothing reads.
func comparePlan(label string, plan *upgrade.Plan, published map[string]manifest.Image, services []string, override map[string]string) []string {
	var problems []string
	add := func(format string, args ...any) { problems = append(problems, label+": "+fmt.Sprintf(format, args...)) }
	selected := map[string]manifest.Image{}
	for _, img := range plan.Images {
		if _, twice := selected[img.Service]; twice {
			add("kvsctl picks two images for %s", img.Service)
		}
		selected[img.Service] = img
		if !slices.Contains(services, img.Service) {
			add("kvsctl pulls %s for %s, which docker/docker-compose.yml does not run", img.Ref, img.Service)
		}
		// The override reads whatever .env says, so an image of another
		// series would agree with it: the manifest says which one it is.
		switch want, ok := published[img.Service]; {
		case !ok:
			add("kvsctl pulls %s@%s for %s, and the release publishes no image of %s for this installation", img.Ref, img.Digest, img.Service, img.Service)
		case img.Ref != want.Ref || img.Digest != want.Digest:
			add("kvsctl pulls %s@%s for %s, and the release publishes %s@%s for this installation", img.Ref, img.Digest, img.Service, want.Ref, want.Digest)
		}
	}
	var missing []string
	readKeys := map[string]bool{}
	for _, service := range services {
		img, ok := selected[service]
		if !ok {
			missing = append(missing, service)
			continue
		}
		pin := img.Ref + "@" + img.Digest
		runs, ok := override[service]
		if !ok {
			continue
		}
		if match := overrideVar.FindStringSubmatch(runs); match != nil {
			readKeys[match[1]] = true
			switch written, ok := plan.ImageEnv[match[1]]; {
			case !ok:
				add("the override reads %s for %s, which kvsctl does not write", match[1], service)
			case written != pin:
				add("kvsctl writes %s=%s and pulls %s for %s", match[1], written, pin, service)
			}
			continue
		}
		if runs != pin {
			add("the override runs %s for %s, and kvsctl pulls %s", runs, service, pin)
		}
	}
	if len(missing) > 0 {
		add("kvsctl picks no image for %s; its plan says: %s", strings.Join(missing, ", "), strings.Join(plan.Blockers, "; "))
	}
	for _, key := range sortedKeys(plan.ImageEnv) {
		if !readKeys[key] {
			add("kvsctl writes %s, which the override does not read", key)
		}
	}
	return problems
}

// installation is one kind of installation a release may meet: the series
// its .env records on each axis.
type installation struct {
	env    map[string]string
	values map[string]string // the series on each axis, by axis
	label  string
}

// published is the image the release publishes for each service an
// installation of this kind runs, read from the manifest alone: the images
// that do not vary, and on each axis the release varies by, the images of
// the series of the installation.
func (kind installation) published(rel *manifest.Release) map[string]manifest.Image {
	images := map[string]manifest.Image{}
	for _, img := range rel.Images {
		images[img.Service] = img
	}
	for axis, byValue := range rel.Variants {
		for _, img := range byValue[kind.values[axis]] {
			images[img.Service] = img
		}
	}
	return images
}

// installations lists every kind of installation that may take the
// release: one for each combination of the series it publishes on the
// axes it varies by, and, for MariaDB and PHP when it does not vary by
// them, the series of its one MariaDB image and the PHP it names. An axis
// no installation records is a problem of its own: kvsctl could pick no
// image on it.
func installations(rel *manifest.Release) ([]installation, []string) {
	var problems []string
	values := map[string][]string{}
	for _, axis := range sortedKeys(rel.Variants) {
		if _, ok := recordedSeries[axis]; !ok {
			problems = append(problems, fmt.Sprintf("the release varies its images by %q, which no installation records", axis))
			continue
		}
		values[axis] = rel.Values(axis)
	}
	if _, varies := values[manifest.VariantMariaDB]; !varies {
		for _, img := range rel.Images {
			if img.Service == "mariadb" {
				if series := tagSeries(img.Ref); series != "" {
					values[manifest.VariantMariaDB] = []string{series}
				}
			}
		}
	}
	if _, varies := values[manifest.VariantPHP]; !varies && rel.Requires.PHP != "" {
		values[manifest.VariantPHP] = []string{rel.Requires.PHP}
	}
	kinds := []installation{{env: map[string]string{}, values: map[string]string{}}}
	for _, axis := range sortedKeys(values) {
		var next []installation
		for _, kind := range kinds {
			for _, value := range values[axis] {
				env := maps.Clone(kind.env)
				env[recordedSeries[axis]] = value
				series := maps.Clone(kind.values)
				series[axis] = value
				label := manifest.AxisLabel(axis) + " " + value
				if kind.label != "" {
					label = kind.label + " and " + label
				}
				next = append(next, installation{env: env, values: series, label: label})
			}
		}
		kinds = next
	}
	if len(kinds) == 1 && kinds[0].label == "" {
		kinds[0].label = "every installation"
	}
	return kinds, problems
}

// tagSeries is the series the tag of an image names, major.minor: 11.8 for
// mariadb:11.8.9, "" for a tag that names none.
func tagSeries(ref string) string {
	_, tag, _ := strings.Cut(ref[strings.LastIndex(ref, "/")+1:], ":")
	parts := strings.Split(tag, ".")
	if len(parts) < 2 {
		return ""
	}
	for _, part := range parts[:2] {
		if _, err := strconv.Atoi(part); err != nil {
			return ""
		}
	}
	return parts[0] + "." + parts[1]
}

// shippedPlan plans the upgrade of an installation of the files in root,
// whose .env records env, to version, as kvsctl check does: the manifest
// at url checked with keys, and docker the engine. The installation is the
// unreleased checkout adopt records, older than every release.
func shippedPlan(docker *dockerx.Client, root, url string, keys []ed25519.PublicKey, version string, env map[string]string) (*upgrade.Plan, error) {
	lines := []string{"DOMAIN=example.com", "COMPOSE_FILE=docker-compose.yml:" + releaseOverride}
	for _, key := range sortedKeys(env) {
		lines = append(lines, key+"="+env[key])
	}
	if err := os.WriteFile(filepath.Join(root, "docker", ".env"), []byte(strings.Join(lines, "\n")+"\n"), 0o600); err != nil {
		return nil, err
	}
	inst, err := instance.Detect(root)
	if err != nil {
		return nil, err
	}
	inst.WebRoot = filepath.Join(root, "www")
	runner := &upgrade.Runner{Inst: inst, Docker: docker, Opts: upgrade.Options{Version: version, ManifestURL: url, PublicKeys: keys}}
	plan, err := runner.Plan(context.Background(), &instance.State{Current: instance.Unreleased})
	if err != nil {
		return nil, err
	}
	if plan.Target == nil || plan.Target.Version != version {
		return nil, fmt.Errorf("the plan targets %v instead of %s", plan.Target, version)
	}
	return plan, nil
}

// apiPrefix is the version prefix of a Docker API path, /v1.51.
var apiPrefix = regexp.MustCompile(`^/v[0-9]+\.[0-9]+`)

// fakeEngine points the Docker client of kvsctl at an engine that answers
// what the plan of an upgrade asks before it picks the images: what the
// engine runs on, and the containers and images it holds, none. Anything
// else is a 404, a container or an image the engine does not hold. A docker
// command that always fails comes first on PATH, so the compose steps of
// the plan stop at once and only report what this machine lacks, which is
// not what this check is about.
func fakeEngine(t *testing.T) *dockerx.Client {
	t.Helper()
	root := t.TempDir()
	engine := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Api-Version", "1.51")
		w.Header().Set("Content-Type", "application/json")
		switch apiPrefix.ReplaceAllString(r.URL.Path, "") {
		case "/_ping":
			w.Header().Set("Content-Type", "text/plain")
			fmt.Fprint(w, "OK")
		case "/info":
			fmt.Fprintf(w, `{"Architecture":"x86_64","OSType":"linux","DockerRootDir":%q,"ServerVersion":"28.5.1"}`, root)
		case "/containers/json", "/images/json":
			fmt.Fprint(w, "[]")
		default:
			w.WriteHeader(http.StatusNotFound)
			fmt.Fprintf(w, `{"message":"no such object: %s"}`, r.URL.Path)
		}
	}))
	t.Cleanup(engine.Close)
	t.Setenv("DOCKER_HOST", "tcp://"+strings.TrimPrefix(engine.URL, "http://"))
	for _, name := range []string{"DOCKER_API_VERSION", "DOCKER_CERT_PATH", "DOCKER_TLS_VERIFY"} {
		t.Setenv(name, "")
	}
	bin := t.TempDir()
	if err := os.WriteFile(filepath.Join(bin, "docker"), []byte("#!/bin/sh\necho 'docker: no docker command runs in this check' >&2\nexit 1\n"), 0o755); err != nil {
		t.Fatal(err)
	}
	t.Setenv("PATH", bin+string(os.PathListSeparator)+os.Getenv("PATH"))
	docker, err := dockerx.New()
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { docker.Close() })
	return docker
}

// overrideImages reads the image of every service of a release override,
// in the form renderOverride writes it.
func overrideImages(text string) (map[string]string, error) {
	images := map[string]string{}
	service := ""
	inServices := false
	for _, line := range strings.Split(text, "\n") {
		switch {
		case line == "services:":
			inServices = true
		case !inServices || strings.HasPrefix(line, "#") || strings.TrimSpace(line) == "":
		case strings.HasPrefix(line, "  ") && !strings.HasPrefix(line, "   ") && strings.HasSuffix(line, ":"):
			service = strings.TrimSuffix(strings.TrimSpace(line), ":")
		case strings.HasPrefix(line, "    image: "):
			value, err := strconv.Unquote(strings.TrimPrefix(line, "    image: "))
			if err != nil || service == "" {
				return nil, fmt.Errorf("cannot read %q", line)
			}
			images[service] = value
		}
	}
	if len(images) == 0 {
		return nil, fmt.Errorf("no service image")
	}
	return images, nil
}

// The check of the publish job accepts a release that kvsctl-release built
// and signed, and names each mismatch between what the release ships and
// what its kvsctl would do with it.
func TestCheckShipped(t *testing.T) {
	registry := registryStub()
	defer registry.Close()
	host := strings.TrimPrefix(registry.URL, "http://")
	keys := t.TempDir()
	if err := keygen([]string{"--out", keys}); err != nil {
		t.Fatal(err)
	}
	trusted := []ed25519.PublicKey{readPub(t, keys)}
	docker := fakeEngine(t)
	repo := gitRepo(t, map[string]string{"docker/docker-compose.yml": stackCompose, "README.md": "readme\n"}, nil)
	const base = "https://example.test/releases/download/26.11.0/"

	// specs are --images and --digests the way release-images.sh writes
	// them, with the digests the registry stub answers, or the ones given.
	specs := func(entries []string, digest map[string]string) (string, string) {
		var images, digests []string
		for _, entry := range entries {
			key, ref, _ := strings.Cut(entry, "=")
			name, tag, _ := strings.Cut(ref, ":")
			images = append(images, key+"="+host+"/"+ref)
			d := stubDigest("/v2/" + name + "/manifests/" + tag)
			if given, ok := digest[key]; ok {
				d = given
			}
			digests = append(digests, key+"="+d)
		}
		return strings.Join(images, ","), strings.Join(digests, ",")
	}
	stack := []string{
		"nginx=kvs-install/nginx:26.11.0", "kvs-init=kvs-install/init:26.11.0", "manticore=kvs-install/manticore:26.11.0",
		"php-fpm@8.1=kvs-install/php:26.11.0-php8.1", "php-fpm@8.4=kvs-install/php:26.11.0-php8.4",
		"cron@8.1=kvs-install/cron:26.11.0-php8.1", "cron@8.4=kvs-install/cron:26.11.0-php8.4",
		"mariadb@11.8=mariadb:11.8.9", "mariadb@12.3=mariadb:12.3.1",
		"memcached=memcached:1.6.45-alpine", "dragonfly=dragonflydb/dragonfly:v1.35.1",
		"acme=neilpang/acme.sh:3.1.6", "phpmyadmin-init=alpine:3.24.2",
	}
	// shipped writes the assets of a release into a directory of its own:
	// the bundle built with bundleSpecs, the kvsctl build, and the manifest
	// signed with manifestSpecs and the extra arguments.
	shipped := func(name string, bundleSpecs, manifestSpecs [2]string, extra ...string) string {
		t.Helper()
		dist := filepath.Join(t.TempDir(), name)
		if err := os.MkdirAll(dist, 0o755); err != nil {
			t.Fatal(err)
		}
		bundlePath := filepath.Join(dist, "kvs-stack-26.11.0.tar.gz")
		if err := bundle([]string{"--repo", repo, "--ref", "HEAD", "--version", "26.11.0", "--images", bundleSpecs[0], "--digests", bundleSpecs[1], "--out", bundlePath}); err != nil {
			t.Fatal(err)
		}
		if err := os.WriteFile(filepath.Join(dist, "kvsctl-linux-amd64"), []byte("kvsctl 26.11.0\n"), 0o755); err != nil {
			t.Fatal(err)
		}
		args := []string{
			"--key", filepath.Join(keys, "release.key"), "--out", dist, "--version", "26.11.0",
			"--bundle", bundlePath, "--bundle-url", base + "kvs-stack-26.11.0.tar.gz",
			"--images", manifestSpecs[0], "--digests", manifestSpecs[1],
			"--php-series", "8.1,8.4", "--compose-min", "2.19.0", "--kvsctl-min", "26.10.0",
			"--cli", "linux-amd64=" + base + "kvsctl-linux-amd64", "--assets", dist,
		}
		if err := manifestCmd(append(args, extra...)); err != nil {
			t.Fatal(err)
		}
		return dist
	}
	finds := func(name, dist string, want ...string) {
		t.Helper()
		problems, err := checkShipped(docker, dist, "26.11.0", trusted)
		if err != nil {
			t.Fatalf("%s: %v", name, err)
		}
		all := strings.Join(problems, "\n")
		t.Logf("%s:\n%s", name, all)
		for _, w := range want {
			if !strings.Contains(all, w) {
				t.Errorf("%s: no problem says %q:\n%s", name, w, all)
			}
		}
		if len(want) == 0 && len(problems) > 0 {
			t.Errorf("%s: a release kvsctl-release built must pass:\n%s", name, all)
		}
	}
	edit := func(dist, file, old, new string) {
		t.Helper()
		path := filepath.Join(dist, file)
		data, err := os.ReadFile(path)
		if err != nil {
			t.Fatal(err)
		}
		if !strings.Contains(string(data), old) {
			t.Fatalf("%s holds no %q", file, old)
		}
		if err := os.WriteFile(path, []byte(strings.Replace(string(data), old, new, 1)), 0o644); err != nil {
			t.Fatal(err)
		}
	}
	// resign signs the manifest of dist again with the release key, as if
	// kvsctl-release had signed what it now holds.
	resign := func(dist string) {
		t.Helper()
		raw, err := os.ReadFile(filepath.Join(dist, "manifest.json"))
		if err != nil {
			t.Fatal(err)
		}
		signers, err := loadSigners([]string{filepath.Join(keys, "release.key")}, nil)
		if err != nil {
			t.Fatal(err)
		}
		sig, err := signManifest(raw, signers)
		if err != nil {
			t.Fatal(err)
		}
		if err := os.WriteFile(filepath.Join(dist, "manifest.json.sig"), sig, 0o644); err != nil {
			t.Fatal(err)
		}
	}

	images, digests := specs(stack, nil)
	whole := [2]string{images, digests}
	good := shipped("good", whole, whole)
	finds("the release as kvsctl-release signs it", good)
	m := readManifest(t, good, keys).Manifest
	kinds, unknown := installations(m.Latest())
	var labels []string
	for _, kind := range kinds {
		labels = append(labels, kind.label)
	}
	if want := "MariaDB 11.8 and PHP 8.1|MariaDB 11.8 and PHP 8.4|MariaDB 12.3 and PHP 8.1|MariaDB 12.3 and PHP 8.4"; strings.Join(labels, "|") != want || len(unknown) > 0 {
		t.Errorf("installations %q %v, want one per pair of a PHP and a MariaDB series: %s", labels, unknown, want)
	}

	// A manifest kvsctl does not trust stops the check at once.
	stranger := t.TempDir()
	if err := keygen([]string{"--out", stranger}); err != nil {
		t.Fatal(err)
	}
	if _, err := checkShipped(docker, good, "26.11.0", []ed25519.PublicKey{readPub(t, stranger)}); err == nil || !strings.Contains(err.Error(), "kvsctl refuses the manifest") {
		t.Errorf("a manifest signed by a key kvsctl does not embed must be refused: %v", err)
	}

	// rewrite changes the bundle of dist with change, after signing.
	rewrite := func(dist string, change func([]byte) []byte) {
		t.Helper()
		path := filepath.Join(dist, "kvs-stack-26.11.0.tar.gz")
		data, err := os.ReadFile(path)
		if err != nil {
			t.Fatal(err)
		}
		if err := os.WriteFile(path, change(data), 0o644); err != nil {
			t.Fatal(err)
		}
	}
	changed := shipped("changed", whole, whole)
	rewrite(changed, func(data []byte) []byte { data[len(data)-1] ^= 0xff; return data })
	edit(changed, "kvsctl-linux-amd64", "26.11.0", "26.11.1")
	finds("a bundle and a kvsctl changed after signing", changed,
		"kvs-stack-26.11.0.tar.gz: checksum mismatch", "kvsctl for linux-amd64, "+filepath.Join(changed, "kvsctl-linux-amd64")+": checksum mismatch")
	// The bundle is read as kvsctl reads it, up to the size the manifest
	// signs: a longer one is refused there.
	longer := shipped("longer", whole, whole)
	rewrite(longer, func(data []byte) []byte { return append(data, 'x') })
	finds("a bundle longer than it was signed", longer, "kvs-stack-26.11.0.tar.gz goes past the ")

	// The bundle reads the MariaDB image from .env, and the manifest lists
	// one MariaDB image for every installation, which kvsctl never writes
	// to .env: Compose would refuse every installation.
	plain := slices.DeleteFunc(slices.Clone(stack), func(e string) bool { return strings.HasPrefix(e, "mariadb@") })
	plainImages, plainDigests := specs(append(plain, "mariadb=mariadb:11.8.9"), nil)
	finds("a MariaDB image the bundle and the manifest place apart", shipped("apart", whole, [2]string{plainImages, plainDigests}),
		"MariaDB 11.8 and PHP 8.1: the override reads KVS_MARIADB_IMAGE for mariadb, which kvsctl does not write")

	// The bundle pins an nginx digest the manifest does not sign.
	other := "sha256:" + strings.Repeat("e", 64)
	pinImages, pinDigests := specs(stack, map[string]string{"nginx": other})
	finds("an override pinning another image", shipped("pin", [2]string{pinImages, pinDigests}, [2]string{images, strings.Replace(digests, "nginx="+stubDigest("/v2/kvs-install/nginx/manifests/26.11.0")+",", "", 1)}),
		"the override runs "+host+"/kvs-install/nginx:26.11.0@"+other+" for nginx, and kvsctl pulls "+host+"/kvs-install/nginx:26.11.0@"+stubDigest("/v2/kvs-install/nginx/manifests/26.11.0"))

	// What kvsctl-release refuses to sign is caught on the manifest too,
	// and so is a kvsctl build longer than the size the manifest signs for
	// it.
	edited := shipped("edited", whole, whole)
	edit(edited, "manifest.json", `"channel": "stable"`, `"channel": "candidate"`)
	edit(edited, "manifest.json", `"kvsctl_min": "26.10.0"`, `"kvsctl_min": "26.12.0"`)
	edit(edited, "manifest.json", `"compose_min": "2.19.0"`, `"compose_min": "2.18.1"`)
	edit(edited, "manifest.json", `"php_series": [`, `"php_series": [ "8.3",`)
	// The build is "kvsctl 26.11.0\n", and its size ends the line.
	edit(edited, "manifest.json", "\"size\": 15\n", "\"size\": 14\n")
	resign(edited)
	finds("a manifest edited after signing", edited,
		`the manifest is of channel "candidate", and 26.11.0 belongs to channel "stable"`,
		"26.11.0 needs kvsctl 26.12.0 or newer",
		`Docker Compose applies from 2.19.0 on, and requires.compose_min is "2.18.1"`,
		"requires.php_series is [8.3 8.1 8.4]",
		"kvsctl-linux-amd64 goes past the 14 bytes the signed manifest gives")
	unsized := shipped("unsized", whole, whole)
	edit(unsized, "manifest.json", "\"size\": 15\n", "\"size\": 0\n")
	resign(unsized)
	finds("a kvsctl build signed without its size", unsized,
		"the manifest signs no size for the kvsctl for linux-amd64")
	// update-cli reads the size of a build only as a count of bytes: one
	// it reads otherwise than the manifest signs it is named.
	negative := shipped("negative", whole, whole)
	edit(negative, "manifest.json", "\"size\": 15\n", "\"size\": -15\n")
	resign(negative)
	finds("a kvsctl build signed with a size update-cli does not read", negative,
		" and size 0, and the manifest signs "+base+"kvsctl-linux-amd64 with sha256 ")
	bare := shipped("bare", whole, whole)
	m = readManifest(t, bare, keys).Manifest
	edit(bare, "manifest.json", fmt.Sprintf("\"size\": %d\n", m.Latest().Bundle.Size), "\"size\": 0\n")
	resign(bare)
	finds("a bundle signed without its size", bare, "the manifest signs no size for the bundle of 26.11.0")
}

// The publish job on a tag of this tree, from the images to the check of
// the kvsctl it ships: release-images.sh turns the digests the images job
// recorded and docker/images.lock into the image list, kvsctl-release
// bundles docker/docker-compose.yml with its override and signs the
// manifest with the knobs of .github/release.env, the kvsctl the cli job
// built reads that manifest with the keys it embeds and prints what the
// job parses, and TestShippedRelease plans every installation on it. The
// registry is a stub that serves every image, the release publishes two
// PHP series and every MariaDB series of the lock, and kvsctl embeds the
// key of the test in place of ReleasePublicKey. A change to the compose
// file, the lock, release-images.sh or kvsctl that would stop the publish
// job of a release stops this test first.
func TestAReleaseOfThisTreePassesThePublishCheck(t *testing.T) {
	if testing.Short() {
		t.Skip("builds kvsctl and runs it as a process")
	}
	const version = "26.11.0"
	root := filepath.Join("..", "..", "..")
	registry := registryStub()
	defer registry.Close()
	host := strings.TrimPrefix(registry.URL, "http://")
	work := t.TempDir()
	write := func(path, content string, mode os.FileMode) {
		t.Helper()
		if err := os.MkdirAll(filepath.Dir(path), 0o755); err != nil {
			t.Fatal(err)
		}
		if err := os.WriteFile(path, []byte(content), mode); err != nil {
			t.Fatal(err)
		}
	}

	// What the images job records for each image it pushes.
	digests := filepath.Join(work, "digests")
	record := func(file, key, repository, tag string) {
		write(filepath.Join(digests, file), key+"="+stubDigest("/v2/kvs-install/"+repository+"/manifests/"+tag)+"\n", 0o644)
	}
	record("nginx.txt", "nginx", "nginx", version)
	record("kvs-init.txt", "kvs-init", "init", version)
	record("manticore.txt", "manticore", "manticore", version)
	for _, series := range []string{"8.1", "8.4"} {
		record("php-fpm"+series+".txt", "php-fpm@"+series, "php", version+"-php"+series)
		record("cron"+series+".txt", "cron@"+series, "cron", version+"-php"+series)
	}
	lock := filepath.Join(work, "images.lock")
	write(lock, stubLock(t, filepath.Join(root, "docker", "images.lock"), host), 0o644)
	spec := filepath.Join(work, "spec")
	script := exec.Command("bash", filepath.Join(root, ".github", "scripts", "release-images.sh"), host+"/kvs-install", version, digests, spec)
	script.Env = append(os.Environ(), "IMAGES_LOCK="+lock)
	if out, err := script.CombinedOutput(); err != nil {
		t.Fatalf("release-images.sh: %v\n%s", err, out)
	}
	read := func(path string) string {
		t.Helper()
		data, err := os.ReadFile(path)
		if err != nil {
			t.Fatal(err)
		}
		return strings.TrimSpace(string(data))
	}
	images, imageDigests, phpSeries := read(filepath.Join(spec, "images.spec")), read(filepath.Join(spec, "digests.spec")), read(filepath.Join(spec, "php-series.spec"))

	// The cli job, with the key of the test embedded.
	keys := t.TempDir()
	if err := keygen([]string{"--out", keys}); err != nil {
		t.Fatal(err)
	}
	pub := read(filepath.Join(keys, "release.pub"))
	dist := filepath.Join(work, "dist")
	kvsctl := filepath.Join(dist, "kvsctl-linux-amd64")
	build := exec.Command("go", "build", "-trimpath", "-ldflags", "-s -w -X main.Version="+version+" -X main.ReleasePublicKey="+pub,
		"-o", kvsctl, "../kvsctl")
	build.Env = append(os.Environ(), "CGO_ENABLED=0")
	if out, err := build.CombinedOutput(); err != nil {
		t.Fatalf("go build: %v\n%s", err, out)
	}
	built, err := os.ReadFile(kvsctl)
	if err != nil {
		t.Fatal(err)
	}
	sum := sha256.Sum256(built)
	write(filepath.Join(dist, sumsFile), hex.EncodeToString(sum[:])+"  kvsctl-linux-amd64\n", 0o644)

	// The publish job: the bundle and the manifest, with the knobs of
	// .github/release.env read the way the job reads them, but NOTES, which
	// the file leaves empty between releases, and those that name a version
	// or a key of a real release: MIN_FROM, KVSCTL_MIN and ANNOUNCE_KEY.
	knobs := exec.Command("bash", "-c", `set -a; . "$1"; set +a; printf '%s\0' "$KVS_MIN" "$COMPOSE_MIN" "$DATABASE" "$ONE_WAY" "$HIGHLIGHT_1" "$HIGHLIGHT_2" "$HIGHLIGHT_3"`, "bash", filepath.Join(root, ".github", "release.env"))
	out, err := knobs.Output()
	if err != nil {
		t.Fatalf(".github/release.env: %v", err)
	}
	knob := strings.Split(strings.TrimSuffix(string(out), "\x00"), "\x00")
	if len(knob) != 7 {
		t.Fatalf(".github/release.env gives KVS_MIN, COMPOSE_MIN, DATABASE, ONE_WAY and the highlights as %q", knob)
	}
	compose := read(filepath.Join(root, "docker", "docker-compose.yml"))
	repo := gitRepo(t, map[string]string{"docker/docker-compose.yml": compose + "\n", "README.md": "readme\n"}, nil)
	bundlePath := filepath.Join(dist, "kvs-stack-"+version+".tar.gz")
	if err := bundle([]string{"--repo", repo, "--ref", "HEAD", "--version", version, "--images", images, "--digests", imageDigests, "--out", bundlePath}); err != nil {
		t.Fatal(err)
	}
	base := "https://example.test/releases/download/" + version + "/"
	arguments := []string{
		"--key", filepath.Join(keys, "release.key"), "--out", dist, "--version", version,
		"--bundle", bundlePath, "--bundle-url", base + "kvs-stack-" + version + ".tar.gz",
		"--images", images, "--digests", imageDigests, "--notes", "a line of notes",
		"--php-series", phpSeries, "--php", strings.Split(phpSeries, ",")[0],
		"--kvs-min", knob[0], "--compose-min", knob[1], "--database", knob[2],
		"--cli", "linux-amd64=" + base + "kvsctl-linux-amd64", "--assets", dist,
	}
	if knob[3] == "true" {
		arguments = append(arguments, "--one-way")
	}
	for _, highlight := range knob[4:] {
		if highlight != "" {
			arguments = append(arguments, "--highlight", highlight)
		}
	}
	if err := manifestCmd(arguments); err != nil {
		t.Fatal(err)
	}

	// The step that tries the kvsctl of the release, which unsets
	// KVSCTL_RELEASE_KEY; no installation is there for kvsctl to remind of.
	run := func(args ...string) []byte {
		t.Helper()
		cmd := exec.Command(kvsctl, args...)
		cmd.Env = []string{"PATH=" + os.Getenv("PATH"), "HOME=" + t.TempDir(), "KVS_INSTALL_DIR=" + t.TempDir()}
		var stderr bytes.Buffer
		cmd.Stderr = &stderr
		out, err := cmd.Output()
		if err != nil {
			t.Fatalf("kvsctl %s: %v\n%s", strings.Join(args, " "), err, stderr.String())
		}
		return out
	}
	// The job reads the version as the second word, awk '{ print $2 }'.
	if words := strings.Fields(string(run("version"))); len(words) < 2 || words[1] != version {
		t.Errorf("kvsctl version prints %q, and the publish job wants %s as its second word", words, version)
	}
	// And any(.[]; .version == $version) of jq on the list of releases.
	var listed []map[string]any
	if err := json.Unmarshal(run("releases", "--json", "--manifest", "file://"+filepath.Join(dist, "manifest.json")), &listed); err != nil {
		t.Errorf("kvsctl releases --json does not print a list of releases: %v", err)
	}
	if !slices.ContainsFunc(listed, func(r map[string]any) bool { return r["version"] == version }) {
		t.Errorf("kvsctl releases --json lists no object whose version is %s: %v", version, listed)
	}

	t.Setenv("KVSCTL_SHIPPED_DIR", dist)
	t.Setenv("KVSCTL_SHIPPED_VERSION", version)
	t.Setenv("KVSCTL_SHIPPED_KEYS", pub)
	t.Run("TestShippedRelease", TestShippedRelease)
}

// stubLock is the lock at path with every image read from the registry
// stub at host instead, under the same repository and tag, and the digest
// the stub answers for it.
func stubLock(t *testing.T, path, host string) string {
	t.Helper()
	data, err := os.ReadFile(path)
	if err != nil {
		t.Fatal(err)
	}
	lines := strings.Split(string(data), "\n")
	for i, line := range lines {
		fields := strings.Split(line, "\t")
		if len(fields) != 3 || strings.HasPrefix(line, "#") {
			continue
		}
		ref, _, _ := strings.Cut(fields[2], "@")
		m := refRe.FindStringSubmatch(ref)
		if m == nil || m[3] == "" {
			t.Fatalf("%s: %q names no repository and tag", path, fields[2])
		}
		fields[2] = host + "/" + m[2] + ":" + m[3] + "@" + stubDigest("/v2/"+m[2]+"/manifests/"+m[3])
		lines[i] = strings.Join(fields, "\t")
	}
	return strings.Join(lines, "\n")
}

// An image of another series agrees with the override as long as .env
// names it, so the plan is compared with the images the release publishes
// for the installation too: a PHP 8.4 site handed the PHP 8.1 image, or a
// MariaDB 12.3 one the 11.8 server, is named.
func TestComparePlanNamesAnImageOfAnotherSeries(t *testing.T) {
	img := func(service, ref, digit string) manifest.Image {
		return manifest.Image{Service: service, Ref: ref, Digest: "sha256:" + strings.Repeat(digit, 64)}
	}
	nginx := img("nginx", "r/nginx:1", "e")
	php81, php84 := img("php-fpm", "r/php:1-php8.1", "a"), img("php-fpm", "r/php:1-php8.4", "b")
	db118, db123 := img("mariadb", "mariadb:11.8.9", "c"), img("mariadb", "mariadb:12.3.1", "d")
	rel := &manifest.Release{
		Images: []manifest.Image{nginx},
		Variants: map[string]map[string][]manifest.Image{
			manifest.VariantPHP:     {"8.1": {php81}, "8.4": {php84}},
			manifest.VariantMariaDB: {"11.8": {db118}, "12.3": {db123}},
		},
	}
	kinds, unknown := installations(rel)
	if len(kinds) != 4 || len(unknown) > 0 {
		t.Fatalf("installations %v %v, want four", kinds, unknown)
	}
	kind := kinds[3]
	if kind.label != "MariaDB 12.3 and PHP 8.4" {
		t.Fatalf("the last installation is %q", kind.label)
	}
	services := []string{"nginx", "php-fpm", "mariadb"}
	override := map[string]string{
		"nginx":   "r/nginx:1@" + nginx.Digest,
		"php-fpm": "${KVS_PHP_FPM_IMAGE:?the release override needs KVS_PHP_FPM_IMAGE}",
		"mariadb": "${KVS_MARIADB_IMAGE:?the release override needs KVS_MARIADB_IMAGE}",
	}
	plan := func(images ...manifest.Image) *upgrade.Plan {
		p := &upgrade.Plan{Images: images, ImageEnv: map[string]string{}}
		for _, i := range images[1:] {
			if i.Service != "adminer" {
				p.ImageEnv[upgrade.ImageEnvKey(i.Service)] = i.Ref + "@" + i.Digest
			}
		}
		return p
	}
	if problems := comparePlan(kind.label, plan(nginx, php84, db123), kind.published(rel), services, override); len(problems) > 0 {
		t.Errorf("the images of its series must pass:\n%s", strings.Join(problems, "\n"))
	}
	adminer := img("adminer", "r/adminer:1", "f")
	problems := strings.Join(comparePlan(kind.label, plan(nginx, php81, db118, adminer), kind.published(rel), services, override), "\n")
	for _, want := range []string{
		"MariaDB 12.3 and PHP 8.4: kvsctl pulls r/php:1-php8.1@" + php81.Digest + " for php-fpm, and the release publishes r/php:1-php8.4@" + php84.Digest + " for this installation",
		"MariaDB 12.3 and PHP 8.4: kvsctl pulls mariadb:11.8.9@" + db118.Digest + " for mariadb, and the release publishes mariadb:12.3.1@" + db123.Digest + " for this installation",
		"MariaDB 12.3 and PHP 8.4: kvsctl pulls r/adminer:1@" + adminer.Digest + " for adminer, and the release publishes no image of adminer for this installation",
	} {
		if !strings.Contains(problems, want) {
			t.Errorf("no problem says %q:\n%s", want, problems)
		}
	}
}

// The installations a release may meet follow its axes, and a single
// MariaDB image or PHP series is the one series of that axis.
func TestInstallations(t *testing.T) {
	img := func(service, ref string) manifest.Image { return manifest.Image{Service: service, Ref: ref} }
	cases := map[string]struct {
		rel  manifest.Release
		want string
	}{
		"no axis": {manifest.Release{Images: []manifest.Image{img("nginx", "r/nginx:1")}}, "every installation"},
		"one MariaDB image and one PHP": {manifest.Release{
			Images:   []manifest.Image{img("mariadb", "registry.example:5000/library/mariadb:11.4.13")},
			Requires: manifest.Requires{PHP: "8.3"},
		}, "MariaDB 11.4 and PHP 8.3"},
		"PHP series only": {manifest.Release{Variants: map[string]map[string][]manifest.Image{
			manifest.VariantPHP: {"8.10": {img("php-fpm", "r/php:1-php8.10")}, "8.2": {img("php-fpm", "r/php:1-php8.2")}},
		}}, "PHP 8.2|PHP 8.10"},
	}
	for name, c := range cases {
		kinds, unknown := installations(&c.rel)
		var labels []string
		for _, kind := range kinds {
			labels = append(labels, kind.label)
		}
		if got := strings.Join(labels, "|"); got != c.want || len(unknown) > 0 {
			t.Errorf("%s: %s %v, want %s", name, got, unknown, c.want)
		}
	}
	rel := manifest.Release{Variants: map[string]map[string][]manifest.Image{"arch": {"arm64": {img("nginx", "r/nginx:1")}}}}
	if _, unknown := installations(&rel); len(unknown) != 1 || !strings.Contains(unknown[0], `by "arch", which no installation records`) {
		t.Errorf("an axis no installation records must be named: %v", unknown)
	}
	for ref, want := range map[string]string{"mariadb:11.8.9": "11.8", "mariadb:latest": "", "mariadb": "", "localhost:5000/mariadb:12.3.1": "12.3", "mariadb:11": ""} {
		if got := tagSeries(ref); got != want {
			t.Errorf("tagSeries(%s) = %q, want %q", ref, got, want)
		}
	}
}
