package upgrade

import (
	"archive/tar"
	"bytes"
	"compress/gzip"
	"context"
	"crypto/ed25519"
	"crypto/sha1"
	"crypto/sha256"
	"encoding/base64"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"maps"
	"net/http"
	"net/http/httptest"
	"net/url"
	"os"
	"path/filepath"
	"slices"
	"sort"
	"strings"
	"sync/atomic"
	"testing"
	"time"

	"github.com/MaximeMichaud/KVS-install/cli/internal/dockerx"
	"github.com/MaximeMichaud/KVS-install/cli/internal/instance"
	"github.com/MaximeMichaud/KVS-install/cli/internal/manifest"
	"github.com/MaximeMichaud/KVS-install/cli/internal/release"
)

// cutRun runs fn on a goroutine of its own, which the cut of rep ends, and
// fails the test when the cut never came.
func cutRun(t *testing.T, rep *recorder, fn func()) {
	t.Helper()
	done := make(chan struct{})
	go func() {
		defer close(done)
		fn()
	}()
	<-done
	rep.mu.Lock()
	defer rep.mu.Unlock()
	if !rep.wasCut {
		t.Fatal("the run ended before the point it was to be cut at")
	}
}

// isStep matches the event of one step.
func isStep(kind Kind, step string) func(Event) bool {
	return func(e Event) bool { return e.Kind == kind && e.Step == step }
}

// isLog matches a log line containing text.
func isLog(text string) func(Event) bool {
	return func(e Event) bool { return e.Kind == KindLog && strings.Contains(e.Message, text) }
}

// rel describes one release of the fake manifest.
type rel struct {
	version, date, database, notes, minFrom, commit string
	oneWay                                          bool
	// php are the PHP series the release publishes, 8.1 by default.
	php []string
	// mariadb maps each MariaDB series the release publishes to the
	// server version of its image: 11.8.9 and 12.3.3 by default.
	mariadb map[string]string
	// extra are services this release runs beside the stack, each pinned
	// to an image of its own.
	extra []string
	// files are release files this release ships beside the ones every
	// release of the tests ships, by path to content.
	files map[string]string
}

func (r rel) phpSeries() []string {
	if len(r.php) == 0 {
		return []string{"8.1"}
	}
	return r.php
}

func (r rel) mariadbVersions() map[string]string {
	if r.mariadb == nil {
		return map[string]string{"11.8": "11.8.9", "12.3": "12.3.3"}
	}
	return r.mariadb
}

const registry = "registry.example.com/kvs/"

// stack is an installation in the fake world: a root holding the files of
// the release installed, its state and .env; the fake engine running its
// containers; the site answering on a local TLS port; and a signed
// manifest of releases with their bundles, served from files.
type stack struct {
	t        *testing.T
	f        *fakeDocker
	docker   *dockerx.Client
	root     string
	dir      string
	pub      ed25519.PublicKey
	priv     ed25519.PrivateKey
	releases []manifest.Release
	// images of each version by service, variants as service@series.
	images map[string]map[string]manifest.Image
	// extra are the extra services of each version, and shipped the files
	// each version ships beside the common ones.
	extra   map[string][]string
	shipped map[string]map[string]string
	site    atomic.Int32
	port    string
	rep     *recorder
}

// newStack installs the first release, running PHP 8.1 and MariaDB of the
// series given (11.8 when empty), and publishes every release.
func newStack(t *testing.T, series string, installed rel, more ...rel) *stack {
	t.Helper()
	if series == "" {
		series = "11.8"
	}
	f, docker := newFakeDocker(t)
	pub, priv, err := ed25519.GenerateKey(nil)
	if err != nil {
		t.Fatal(err)
	}
	s := &stack{t: t, f: f, docker: docker, root: t.TempDir(), dir: t.TempDir(), pub: pub, priv: priv, images: map[string]map[string]manifest.Image{}, extra: map[string][]string{}, shipped: map[string]map[string]string{}, rep: &recorder{answer: true}}
	s.site.Store(http.StatusOK)
	srv := httptest.NewTLSServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		w.WriteHeader(int(s.site.Load()))
	}))
	t.Cleanup(srv.Close)
	u, _ := url.Parse(srv.URL)
	s.port = u.Port()
	for _, r := range append([]rel{installed}, more...) {
		s.addRelease(r)
	}
	s.writeManifest()
	s.install(installed.version, series)
	return s
}

// addRelease publishes the images and the bundle of a release.
func (s *stack) addRelease(r rel) {
	s.t.Helper()
	v := r.version
	images := map[string]manifest.Image{
		"nginx":     s.f.publish("nginx", registry+"nginx:"+v, ""),
		"manticore": s.f.publish("manticore", registry+"manticore:"+v, ""),
		"kvs-init":  s.f.publish("kvs-init", registry+"init:"+v, ""),
	}
	out := manifest.Release{
		Version:  v,
		Date:     r.date,
		Commit:   r.commit,
		Notes:    r.notes,
		Database: r.database,
		OneWay:   r.oneWay,
		Requires: manifest.Requires{MinFrom: r.minFrom},
		Images:   []manifest.Image{images["nginx"], images["manticore"], images["kvs-init"]},
		Variants: map[string]map[string][]manifest.Image{manifest.VariantPHP: {}, manifest.VariantMariaDB: {}},
	}
	for _, svc := range r.extra {
		images[svc] = s.f.publish(svc, registry+svc+":"+v, "")
		out.Images = append(out.Images, images[svc])
	}
	s.extra[v], s.shipped[v] = r.extra, r.files
	if out.Date == "" {
		out.Date = "2026-10-01"
	}
	for _, series := range r.phpSeries() {
		img := s.f.publish("php-fpm", registry+"php:"+v+"-php"+series, "")
		images["php-fpm@"+series] = img
		out.Variants[manifest.VariantPHP][series] = []manifest.Image{img}
	}
	for series, version := range r.mariadbVersions() {
		img := s.f.publish("mariadb", "mariadb:"+version, version)
		images["mariadb@"+series] = img
		out.Variants[manifest.VariantMariaDB][series] = []manifest.Image{img}
	}
	s.images[v] = images
	bundle := filepath.Join(s.dir, "kvs-stack-"+v+".tar.gz")
	data := s.bundle(v, images)
	if err := os.WriteFile(bundle, data, 0o644); err != nil {
		s.t.Fatal(err)
	}
	sum := sha256.Sum256(data)
	out.Bundle = manifest.Asset{URL: "file://" + bundle, SHA256: hex.EncodeToString(sum[:]), Size: int64(len(data))}
	s.releases = append(s.releases, out)
}

// files are the release files of a version, in the format of the fake
// compose: the base file builds the services, the services that need the
// database wait for it to be healthy, the release override pins them, the
// variants through .env. The cache runs under a profile of its own, built
// on the machine.
func (s *stack) files(v string, images map[string]manifest.Image) map[string]string {
	pin := func(service string) string { return images[service].Ref + "@" + images[service].Digest }
	base := "nginx kvs-nginx\nphp-fpm kvs-php needs:mariadb\nmariadb mariadb:${MARIADB_VERSION:-12.3}\nmanticore kvs-manticore manticore needs:mariadb\nkvs-init kvs-init setup needs:mariadb\nmemcached memcached:1.6 memcached\n"
	override := "nginx " + pin("nginx") + "\n" +
		"php-fpm ${KVS_PHP_FPM_IMAGE:?run-kvsctl-upgrade}\n" +
		"mariadb ${KVS_MARIADB_IMAGE:?run-kvsctl-upgrade}\n" +
		"manticore " + pin("manticore") + "\n" +
		"kvs-init " + pin("kvs-init") + "\n"
	for _, svc := range s.extra[v] {
		base += svc + " kvs-" + svc + "\n"
		override += svc + " " + pin(svc) + "\n"
	}
	files := map[string]string{
		"docker/docker-compose.yml": base,
		"docker/" + ReleaseOverride: override,
		"docker/.env.example":       "DOMAIN=\nSETTING_" + strings.ReplaceAll(v, ".", "_") + "=1\n",
		"docker/RELEASE":            v + "\n",
		"docker/only-" + v + ".txt": v + "\n",
		"README.md":                 "KVS stack " + v + "\n",
	}
	maps.Copy(files, s.shipped[v])
	return files
}

func (s *stack) bundle(v string, images map[string]manifest.Image) []byte {
	var buf bytes.Buffer
	gz := gzip.NewWriter(&buf)
	tw := tar.NewWriter(gz)
	files := s.files(v, images)
	for _, name := range slices.Sorted(maps.Keys(files)) {
		if err := tw.WriteHeader(&tar.Header{Name: name, Mode: 0o644, Size: int64(len(files[name])), Typeflag: tar.TypeReg}); err != nil {
			s.t.Fatal(err)
		}
		if _, err := tw.Write([]byte(files[name])); err != nil {
			s.t.Fatal(err)
		}
	}
	if err := tw.Close(); err != nil {
		s.t.Fatal(err)
	}
	if err := gz.Close(); err != nil {
		s.t.Fatal(err)
	}
	return buf.Bytes()
}

// writeManifest signs the list of releases and writes it beside the
// bundles.
func (s *stack) writeManifest() {
	s.t.Helper()
	m := manifest.Manifest{Schema: manifest.Schema, Channel: "stable", Updated: time.Now().UTC().Format(time.RFC3339), Releases: s.releases}
	raw, err := json.Marshal(m)
	if err != nil {
		s.t.Fatal(err)
	}
	sig, _ := json.Marshal(manifest.Signature{KeyID: manifest.KeyID(s.pub), Alg: manifest.AlgEd25519, Sig: base64.StdEncoding.EncodeToString(ed25519.Sign(s.priv, raw))})
	if err := os.WriteFile(filepath.Join(s.dir, "manifest.json"), raw, 0o644); err != nil {
		s.t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(s.dir, "manifest.json.sig"), sig, 0o644); err != nil {
		s.t.Fatal(err)
	}
}

// install lays the files of version as kvsctl would have, writes the .env
// and the state, and starts the containers of the stack.
func (s *stack) install(v, series string) {
	s.t.Helper()
	images := s.images[v]
	files := s.files(v, images)
	var list []string
	for name, content := range files {
		path := filepath.Join(s.root, name)
		if err := os.MkdirAll(filepath.Dir(path), 0o755); err != nil {
			s.t.Fatal(err)
		}
		if err := os.WriteFile(path, []byte(content), 0o644); err != nil {
			s.t.Fatal(err)
		}
		list = append(list, name)
	}
	sort.Strings(list)
	php, mariadb := images["php-fpm@8.1"], images["mariadb@"+series]
	variant := map[string]string{
		"KVS_PHP_FPM_IMAGE": php.Ref + "@" + php.Digest,
		"KVS_MARIADB_IMAGE": mariadb.Ref + "@" + mariadb.Digest,
	}
	env := fmt.Sprintf("DOMAIN=example.com\nSITE_PREFIX=kvs\nHTTPS_PORT=127.0.0.1:%s\nPHP_VERSION=8.1\nMARIADB_VERSION=%s\nCOMPOSE_FILE=docker-compose.yml:%s\nKVS_STACK_VERSION=%s\nKVS_PHP_FPM_IMAGE=%s\nKVS_MARIADB_IMAGE=%s\n",
		s.port, series, ReleaseOverride, v, variant["KVS_PHP_FPM_IMAGE"], variant["KVS_MARIADB_IMAGE"])
	if err := os.WriteFile(filepath.Join(s.root, "docker", ".env"), []byte(env), 0o600); err != nil {
		s.t.Fatal(err)
	}
	sums, err := release.Checksums(s.root, list)
	if err != nil {
		s.t.Fatal(err)
	}
	inst, err := instance.Detect(s.root)
	if err != nil {
		s.t.Fatal(err)
	}
	pins := []string{s.pin(v, "nginx"), s.pin(v, "manticore"), s.pin(v, "kvs-init"), php.Ref + "@" + php.Digest, mariadb.Ref + "@" + mariadb.Digest}
	for _, svc := range s.extra[v] {
		pins = append(pins, s.pin(v, svc))
	}
	state := &instance.State{
		Current:       v,
		Files:         list,
		Checksums:     sums,
		Images:        variant,
		ReleaseImages: map[string][]string{v: pins},
		History:       []instance.Entry{{Version: v, Action: "adopt", Date: time.Now().UTC().Add(-time.Hour)}},
	}
	if err := inst.SaveState(state); err != nil {
		s.t.Fatal(err)
	}
	for _, service := range append([]string{"nginx", "php-fpm@8.1", "mariadb@" + series}, s.extra[v]...) {
		s.f.hold(images[service])
	}
	s.f.with(func(f *fakeDocker) {
		if resp := f.up(inst.DockerDir, nil); resp.Code != 0 {
			s.t.Fatalf("the stack does not start: %s", resp.Stderr)
		}
	})
}

// runner is a runner of the stack with the options of a test.
func (s *stack) runner(set ...func(*Options)) *Runner {
	s.t.Helper()
	inst, err := instance.Detect(s.root)
	if err != nil {
		s.t.Fatal(err)
	}
	opts := Options{
		Yes:           true,
		ManifestURL:   "file://" + filepath.Join(s.dir, "manifest.json"),
		PublicKeys:    []ed25519.PublicKey{s.pub},
		HealthTimeout: 3 * time.Second,
		DBTimeout:     3 * time.Second,
		KeepBackups:   5,
		LogPath:       filepath.Join(s.root, "kvsctl", "logs", "test.log"),
	}
	for _, fn := range set {
		fn(&opts)
	}
	return &Runner{Inst: inst, Docker: s.docker, Reporter: s.rep, Opts: opts}
}

// plan reads the state and plans with r.
func (s *stack) plan(r *Runner) (*instance.State, *Plan) {
	s.t.Helper()
	state, err := r.Inst.LoadState()
	if err != nil {
		s.t.Fatal(err)
	}
	plan, err := r.Plan(context.Background(), state)
	if err != nil {
		s.t.Fatal(err)
	}
	return state, plan
}

// upgrade plans and runs an upgrade with r.
func (s *stack) upgrade(r *Runner) error {
	s.t.Helper()
	state, plan := s.plan(r)
	return r.Run(context.Background(), state, plan)
}

func (s *stack) state() *instance.State {
	s.t.Helper()
	inst, err := instance.Detect(s.root)
	if err != nil {
		s.t.Fatal(err)
	}
	state, err := inst.LoadState()
	if err != nil {
		s.t.Fatal(err)
	}
	return state
}

func (s *stack) env() map[string]string {
	s.t.Helper()
	env, err := instance.ReadEnv(filepath.Join(s.root, "docker", ".env"))
	if err != nil {
		s.t.Fatal(err)
	}
	return env
}

func (s *stack) journal() *instance.Journal {
	s.t.Helper()
	inst, err := instance.Detect(s.root)
	if err != nil {
		s.t.Fatal(err)
	}
	j, err := inst.LoadJournal()
	if err != nil {
		s.t.Fatal(err)
	}
	return j
}

// file is the content of a file of the installation, "" when missing.
func (s *stack) file(name string) string {
	data, err := os.ReadFile(filepath.Join(s.root, name))
	if err != nil {
		return ""
	}
	return string(data)
}

// pin is ref@digest of an image of a version.
func (s *stack) pin(version, service string) string {
	img := s.images[version][service]
	return img.Ref + "@" + img.Digest
}

// running is the image reference the container of a service runs.
func (s *stack) running(service string) string {
	var ref string
	s.f.with(func(f *fakeDocker) {
		if c := f.containers[f.prefix+"-"+service]; c != nil {
			ref = c.ref
		}
	})
	return ref
}

// containerID is the ID of the container of a service.
func (s *stack) containerID(service string) string {
	var id string
	s.f.with(func(f *fakeDocker) {
		if c := f.containers[f.prefix+"-"+service]; c != nil {
			id = c.id
		}
	})
	return id
}

// world reads the database side of the fake: what it holds, the replays,
// the moved folders and the series of the data files.
func (s *stack) world() (db string, replays, moved []string, series string) {
	s.f.with(func(f *fakeDocker) {
		db, replays, moved, series = f.db, slices.Clone(f.replays), slices.Clone(f.moved), f.dataSeries
	})
	return db, replays, moved, series
}

// count is how many docker commands start with prefix.
func (s *stack) count(prefix string) int {
	n := 0
	for _, c := range s.f.commands() {
		if strings.HasPrefix(c, prefix) {
			n++
		}
	}
	return n
}

// held reports whether the engine holds the image of a service of a
// version.
func (s *stack) held(version, service string) bool {
	digest := s.images[version][service].Digest
	found := false
	s.f.with(func(f *fakeDocker) {
		for _, img := range f.held {
			if img.digest == digest {
				found = true
			}
		}
	})
	return found
}

// failOnce makes the first docker command that is exactly cmd fail with
// stderr before it does anything; the ones after it run.
func (s *stack) failOnce(cmd, stderr string) { s.failAt(1, cmd, stderr) }

// failAt makes the nth docker command that is exactly cmd fail with stderr
// before it does anything, the one a rollback runs after the run it undoes
// for instance; every other one runs.
func (s *stack) failAt(n int, cmd, stderr string) {
	seen := 0
	s.f.with(func(f *fakeDocker) {
		f.hook = func(_ *fakeDocker, req cliRequest) (cliResponse, bool) {
			if strings.Join(req.Args, " ") != cmd {
				return cliResponse{}, false
			}
			if seen++; seen != n {
				return cliResponse{}, false
			}
			return cliResponse{Stderr: stderr + "\n", Code: 1}, true
		}
	})
}

// restartWith gives the container of a service a new life that behaves as
// b, the way a restart by the engine would.
func (s *stack) restartWith(service string, b behavior) {
	s.f.with(func(f *fakeDocker) {
		c := f.containers[f.prefix+"-"+service]
		c.behave, c.started, c.stopped = b, time.Now(), false
	})
}

// setEnv changes one setting of the .env of the installation.
func (s *stack) setEnv(key, value string) {
	s.t.Helper()
	inst, err := instance.Detect(s.root)
	if err != nil {
		s.t.Fatal(err)
	}
	if err := inst.SetEnv(key, value); err != nil {
		s.t.Fatal(err)
	}
}

// fresh gives the runners made next a reporter of their own, the way a
// new command starts with a new screen.
func (s *stack) fresh() *recorder {
	s.rep = &recorder{answer: true}
	return s.rep
}

// recover runs Recover with r on the state on disk.
func (s *stack) recover(r *Runner) error {
	s.t.Helper()
	state, err := r.Inst.LoadState()
	if err != nil {
		s.t.Fatal(err)
	}
	return r.Recover(context.Background(), state)
}

// rollback runs a manual rollback with r on the state on disk.
func (s *stack) rollback(r *Runner) error {
	s.t.Helper()
	state, err := r.Inst.LoadState()
	if err != nil {
		s.t.Fatal(err)
	}
	return r.Rollback(context.Background(), state)
}

// ran reports the position of the first docker command that is exactly
// cmd, -1 when none ran.
func (s *stack) ran(cmd string) int {
	return slices.Index(s.f.commands(), cmd)
}

// cutUpgrade plans an upgrade with r and runs it until the first event cut
// matches, where the run dies the way a killed kvsctl does.
func (s *stack) cutUpgrade(r *Runner, cut func(Event) bool) {
	s.t.Helper()
	state, plan := s.plan(r)
	s.rep.cut = cut
	cutRun(s.t, s.rep, func() { _ = r.Run(context.Background(), state, plan) })
}

// back checks that the stack runs version v as the state records it: its
// files, the variant settings in .env, the containers on those images, and
// no journal left.
func (s *stack) back(v string) {
	s.t.Helper()
	if got := s.file("docker/RELEASE"); got != v+"\n" {
		s.t.Errorf("docker/RELEASE holds %q, want %s", got, v)
	}
	for other := range s.images {
		if present := s.file("docker/only-"+other+".txt") != ""; present != (other == v) {
			s.t.Errorf("docker/only-%s.txt present: %v, on %s", other, present, v)
		}
	}
	state := s.state()
	if state.Current != v {
		s.t.Errorf("the state records %s, want %s", state.Current, v)
	}
	env := s.env()
	for key, value := range state.Images {
		if env[key] != value {
			s.t.Errorf(".env has %s=%s, the state records %s", key, env[key], value)
		}
	}
	for service, key := range map[string]string{"php-fpm": "KVS_PHP_FPM_IMAGE", "mariadb": "KVS_MARIADB_IMAGE"} {
		if got := s.running(service); got != env[key] {
			s.t.Errorf("%s runs %s, .env names %s", service, got, env[key])
		}
	}
	if got := s.running("nginx"); got != s.pin(v, "nginx") {
		s.t.Errorf("nginx runs %s, want the image of %s", got, v)
	}
	if j := s.journal(); j != nil {
		s.t.Errorf("the journal is still there: %+v", j)
	}
}

// ended checks that the screen was told the run is over, with err.
func (s *stack) ended(err error) {
	s.t.Helper()
	got, ok := s.rep.done()
	if !ok {
		s.t.Error("the run sent no KindDone event")
	} else if got != err {
		s.t.Errorf("KindDone carries %v, the run returned %v", got, err)
	}
}

// quick bounds the wait of a run meant to fail its verification: an
// unhealthy service ends it after 300 ms. MariaDB, healthy a moment after
// it starts, keeps a budget a slow machine cannot run out of.
func quick(o *Options) {
	o.HealthTimeout, o.DBTimeout = 300*time.Millisecond, 10*time.Second
}

// series asks for a MariaDB series.
func series(s string) func(*Options) {
	return func(o *Options) { o.MariaDBSeries = s }
}

// commit is a git commit id made up for a version.
func commit(v string) string {
	sum := sha1.Sum([]byte(v))
	return hex.EncodeToString(sum[:])
}
