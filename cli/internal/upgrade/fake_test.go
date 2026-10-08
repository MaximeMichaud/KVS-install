package upgrade

import (
	"bytes"
	"context"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"io"
	"maps"
	"net"
	"net/http"
	"os"
	"path/filepath"
	"regexp"
	"slices"
	"sort"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/MaximeMichaud/KVS-install/cli/internal/dockerx"
	"github.com/MaximeMichaud/KVS-install/cli/internal/instance"
	"github.com/MaximeMichaud/KVS-install/cli/internal/manifest"
)

// afterTests run once every test of the package is over, to remove what a
// test made for all of them: the kvsctl the process tests build.
var afterTests []func()

// TestMain lets the test binary stand in for the docker CLI. The tests
// that drive the runner end to end put a link named docker to it first on
// PATH: run under that name, the binary sends its arguments, its directory
// and its standard input to the fake engine of the test, and answers what
// the fake says, the way the docker CLI answers what the engine does.
func TestMain(m *testing.M) {
	if filepath.Base(os.Args[0]) == "docker" {
		os.Exit(fakeDockerCLI())
	}
	pollInterval = 10 * time.Millisecond
	code := m.Run()
	for _, fn := range afterTests {
		fn()
	}
	os.Exit(code)
}

type cliRequest struct {
	Args  []string `json:"args"`
	Dir   string   `json:"dir"`
	Stdin []byte   `json:"stdin"`
	Env   []string `json:"env"`
}

type cliResponse struct {
	Stdout string `json:"stdout"`
	Stderr string `json:"stderr"`
	Code   int    `json:"code"`
}

// fakeDockerCLI is the docker CLI of the tests.
func fakeDockerCLI() int {
	stdin, err := io.ReadAll(os.Stdin)
	if err != nil {
		fmt.Fprintln(os.Stderr, "fake docker:", err)
		return 125
	}
	dir, _ := os.Getwd()
	body, _ := json.Marshal(cliRequest{Args: os.Args[1:], Dir: dir, Stdin: stdin, Env: os.Environ()})
	sock := strings.TrimPrefix(os.Getenv("DOCKER_HOST"), "unix://")
	client := &http.Client{Transport: &http.Transport{DialContext: func(ctx context.Context, _, _ string) (net.Conn, error) {
		return (&net.Dialer{}).DialContext(ctx, "unix", sock)
	}}}
	resp, err := client.Post("http://fake/_fake/cli", "application/json", bytes.NewReader(body))
	if err != nil {
		fmt.Fprintln(os.Stderr, "fake docker:", err)
		return 125
	}
	defer resp.Body.Close()
	var out cliResponse
	if err := json.NewDecoder(resp.Body).Decode(&out); err != nil {
		fmt.Fprintln(os.Stderr, "fake docker:", err)
		return 125
	}
	os.Stdout.WriteString(out.Stdout)
	os.Stderr.WriteString(out.Stderr)
	return out.Code
}

// behavior is how the containers of an image behave once started.
type behavior struct {
	// ready is how long the health check takes to pass.
	ready time.Duration
	// noCheck is an image without a health check.
	noCheck bool
	// unhealthy is a health check that fails once ready has passed.
	unhealthy bool
	// exits is a process that ends at once, crash a process that ends
	// after a moment and is restarted for ever, its health check starting
	// over each time.
	exits, crash bool
	// startPeriod is the start period the health check declares.
	startPeriod time.Duration
	// sick is a health check that fails for that long after the start,
	// then passes: a server busy upgrading its tables.
	sick time.Duration
	// migrate is what the database holds once a container of the image
	// started: a release whose code changes the schema when it first runs.
	migrate string
}

// crashPeriod is how long a crashing container lives each time.
const crashPeriod = 25 * time.Millisecond

type fakeImage struct {
	id, repo, digest string
	tags             []string
	env              []string
	layers           []string
	// series is the MariaDB series the server of the image runs.
	series string
}

type fakeContainer struct {
	id, name, service, ref string
	image                  *fakeImage
	started                time.Time
	stopped                bool
	// created is a container compose created and never started: the
	// services it depends on did not turn healthy.
	created bool
	behave  behavior
}

// fakeData is what a folder of the MariaDB data volume holds: data files
// of a series, and the database they carry.
type fakeData struct{ series, db string }

// fakeDocker is a Docker engine and a compose project in one: the Engine
// API kvsctl reads, and the docker CLI commands it runs, with a MariaDB
// whose data files have a series and whose database holds a label a dump
// carries and a replay restores.
type fakeDocker struct {
	t  *testing.T
	mu sync.Mutex

	prefix, project string
	// registry holds what a pull by digest finds, held what the engine has.
	registry map[string]*fakeImage
	held     []*fakeImage
	// mirrors are images a pull finds under another repository than the
	// one they were published under, by repository@digest: the same image
	// served by a mirror of its registry.
	mirrors map[string]*fakeImage
	// behaviors are keyed by image reference without the digest; an image
	// without one turns healthy after 20 ms.
	behaviors  map[string]behavior
	containers map[string]*fakeContainer
	seq        int

	// dataSeries is the series of the MariaDB data files, "" for a fresh
	// directory, and db what the database holds.
	dataSeries string
	db         string
	replays    []string
	moved      []string
	calls      []string
	// folders are the folders of the data volume a move filled, marked
	// the ones a move back emptied the data directory into, and back the
	// folders a move back emptied.
	folders map[string]fakeData
	marked  map[string]bool
	back    []string
	// requested are the services whose data volume holds the request to
	// rebuild their indexes, which their entrypoint reads at the next start
	// of a container; rebuilds are the services that started on one, and
	// removed the services whose containers compose rm removed.
	requested map[string]bool
	rebuilds  []string
	removed   []string
	// dumpedWith and replayedWith are the services whose containers ran
	// while each dump was taken and each replay went in, and movedWith
	// while the data files moved aside or back: the ones that could write
	// to the database meanwhile.
	dumpedWith, replayedWith, movedWith [][]string
	// apiFail makes the Engine API answer a request of path with a server
	// error when it says so, the way a daemon that restarts does.
	apiFail func(path string) bool
	// hook answers a docker command in place of the fake when it says so;
	// it runs under the lock and may call the fake's own handlers.
	hook func(f *fakeDocker, req cliRequest) (cliResponse, bool)
	// gate runs before a docker command, outside the lock, so the engine
	// keeps answering while it holds the command; gone is closed when the
	// command went away, killed by kvsctl.
	gate func(req cliRequest, gone <-chan struct{})
	// refusal is what the engine answers every request of its API with,
	// the way an engine older than the client refuses it.
	refusal string

	volume, root, arch string
}

// newFakeDocker starts the fake, a client connected to it and the docker
// link on PATH.
func newFakeDocker(t *testing.T) (*fakeDocker, *dockerx.Client) {
	t.Helper()
	// A unix socket path is short, so the socket lives in a directory of
	// its own under the temporary directory, not in the test's.
	dir, err := os.MkdirTemp("", "kvsctl")
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { os.RemoveAll(dir) })
	sock := filepath.Join(dir, "docker.sock")
	listener, err := net.Listen("unix", sock)
	if err != nil {
		t.Fatal(err)
	}
	f := &fakeDocker{
		t:          t,
		prefix:     "kvs",
		project:    "kvs",
		registry:   map[string]*fakeImage{},
		mirrors:    map[string]*fakeImage{},
		behaviors:  map[string]behavior{},
		containers: map[string]*fakeContainer{},
		folders:    map[string]fakeData{},
		marked:     map[string]bool{},
		requested:  map[string]bool{},
		db:         "data-1",
		volume:     t.TempDir(),
		root:       t.TempDir(),
		arch:       "x86_64",
	}
	srv := &http.Server{Handler: f}
	go func() { _ = srv.Serve(listener) }()
	t.Cleanup(func() { srv.Close() })
	bin := filepath.Join(dir, "bin")
	if err := os.Mkdir(bin, 0o755); err != nil {
		t.Fatal(err)
	}
	exe, err := os.Executable()
	if err != nil {
		t.Fatal(err)
	}
	if err := os.Symlink(exe, filepath.Join(bin, "docker")); err != nil {
		t.Fatal(err)
	}
	t.Setenv("PATH", bin+string(os.PathListSeparator)+os.Getenv("PATH"))
	t.Setenv("DOCKER_HOST", "unix://"+sock)
	t.Setenv("DOCKER_API_VERSION", "")
	t.Setenv("DOCKER_TLS_VERIFY", "")
	t.Setenv("DOCKER_CERT_PATH", "")
	t.Setenv("DOCKER_CONFIG", t.TempDir())
	// A binary built with the race detector sleeps a second before it
	// exits, which every docker command of a test would pay.
	t.Setenv("GORACE", strings.TrimSpace(os.Getenv("GORACE")+" atexit_sleep_ms=0"))
	c, err := dockerx.New()
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { c.Close() })
	return f, c
}

// with runs fn under the lock the handlers take, which is how a test reads
// or changes the fake between requests.
func (f *fakeDocker) with(fn func(f *fakeDocker)) {
	f.mu.Lock()
	defer f.mu.Unlock()
	fn(f)
}

// digestOf is the digest the fake registry gives an image reference.
func digestOf(ref string) string {
	sum := sha256.Sum256([]byte(ref))
	return "sha256:" + hex.EncodeToString(sum[:])
}

// publish puts an image in the fake registry and returns it the way a
// manifest lists it. mariadb, for a MariaDB image, is the server version
// its environment declares.
func (f *fakeDocker) publish(service, ref, mariadb string) manifest.Image {
	repo, tag, _ := splitRef(ref)
	img := &fakeImage{id: digestOf("id " + ref), repo: repo, digest: digestOf(ref), tags: []string{tag}, layers: []string{digestOf("diff " + ref)}}
	if mariadb != "" {
		img.series = versionSeries(mariadb)
		img.env = []string{"MARIADB_VERSION=1:" + mariadb + "+maria~ubu2404", "PATH=/usr/bin"}
	}
	f.with(func(f *fakeDocker) {
		// Releases share images, MariaDB's above all: one reference is
		// one image of the registry.
		if _, ok := f.registry[img.digest]; !ok {
			f.registry[img.digest] = img
		}
	})
	return manifest.Image{
		Service: service,
		Ref:     ref,
		Digest:  img.digest,
		Size:    1000,
		Layers:  []manifest.Layer{{Digest: digestOf("layer " + ref), DiffID: img.layers[0], Size: 1000}},
	}
}

// hold makes the engine hold a published image, as if pulled earlier.
func (f *fakeDocker) hold(img manifest.Image) {
	f.with(func(f *fakeDocker) {
		if found := f.registry[img.Digest]; found != nil && !slices.Contains(f.held, found) {
			f.held = append(f.held, found)
		}
	})
}

// mirror serves a published image under repo too, the way a mirror of its
// registry does: the same digest, layers and image, under another name. It
// returns the image the way a manifest that pins the mirror lists it.
func (f *fakeDocker) mirror(img manifest.Image, repo string) manifest.Image {
	_, tag, _ := splitRef(img.Ref)
	f.with(func(f *fakeDocker) {
		served := *f.registry[img.Digest]
		served.repo, served.tags = repo, []string{tag}
		f.mirrors[repo+"@"+img.Digest] = &served
	})
	img.Ref = repo + ":" + tag
	return img
}

// behave sets how the containers of an image reference behave.
func (f *fakeDocker) behave(ref string, b behavior) {
	f.with(func(f *fakeDocker) { f.behaviors[norm(ref)] = b })
}

// commands are the docker commands run so far, arguments joined.
func (f *fakeDocker) commands() []string {
	f.mu.Lock()
	defer f.mu.Unlock()
	return append([]string(nil), f.calls...)
}

// norm is a reference without the default registry and namespace the
// Docker client adds to Docker Hub names.
func norm(ref string) string {
	ref = strings.TrimPrefix(ref, "docker.io/library/")
	return strings.TrimPrefix(ref, "docker.io/")
}

// splitRef cuts a reference into repository, tag and digest.
func splitRef(ref string) (repo, tag, digest string) {
	ref = norm(ref)
	if i := strings.IndexByte(ref, '@'); i >= 0 {
		ref, digest = ref[:i], ref[i+1:]
	}
	if colon := strings.LastIndexByte(ref, ':'); colon > strings.LastIndexByte(ref, '/') {
		return ref[:colon], ref[colon+1:], digest
	}
	return ref, "", digest
}

// find is the image the engine holds under a name: an ID, repo@digest,
// repo:tag@digest or repo:tag.
func (f *fakeDocker) find(name string) *fakeImage {
	for _, img := range f.held {
		if img.id == name {
			return img
		}
	}
	repo, tag, digest := splitRef(name)
	for _, img := range f.held {
		if img.repo != repo {
			continue
		}
		if digest != "" {
			if img.digest == digest {
				return img
			}
			continue
		}
		if tag == "" {
			tag = "latest"
		}
		if slices.Contains(img.tags, tag) {
			return img
		}
	}
	return nil
}

func (f *fakeDocker) ServeHTTP(w http.ResponseWriter, r *http.Request) {
	path := r.URL.Path
	if m := regexp.MustCompile(`^/v[0-9.]+(/.*)$`).FindStringSubmatch(path); m != nil {
		path = m[1]
	}
	switch {
	case path == "/_ping":
		w.Header().Set("API-Version", "1.47")
		w.Header().Set("OSType", "linux")
		w.WriteHeader(http.StatusOK)
		return
	case path == "/_fake/cli":
		// The whole body is read, to its end: only then does the server
		// watch the connection, and end the context of the request when
		// the docker command on the other side was killed.
		body, err := io.ReadAll(r.Body)
		var req cliRequest
		if err == nil {
			err = json.Unmarshal(body, &req)
		}
		if err != nil {
			http.Error(w, err.Error(), http.StatusBadRequest)
			return
		}
		f.mu.Lock()
		gate := f.gate
		f.mu.Unlock()
		if gate != nil {
			gate(req, r.Context().Done())
		}
		f.mu.Lock()
		resp := f.cli(req)
		f.mu.Unlock()
		writeJSON(w, resp)
		return
	}
	f.mu.Lock()
	defer f.mu.Unlock()
	if f.apiFail != nil && f.apiFail(path) {
		w.Header().Set("Content-Type", "application/json")
		w.WriteHeader(http.StatusInternalServerError)
		_ = json.NewEncoder(w).Encode(map[string]string{"message": "fake engine failure on " + path})
		return
	}
	if f.refusal != "" {
		w.Header().Set("Content-Type", "application/json")
		w.WriteHeader(http.StatusBadRequest)
		_ = json.NewEncoder(w).Encode(map[string]string{"message": f.refusal})
		return
	}
	switch {
	case r.Method == http.MethodGet && path == "/containers/json":
		f.listContainers(w, r)
	case r.Method == http.MethodGet && strings.HasPrefix(path, "/containers/") && strings.HasSuffix(path, "/json"):
		name := strings.TrimSuffix(strings.TrimPrefix(path, "/containers/"), "/json")
		for _, c := range f.containers {
			if c.id == name || c.name == name {
				writeJSON(w, f.inspect(c, time.Now()))
				return
			}
		}
		notFound(w, "No such container: "+name)
	case r.Method == http.MethodGet && path == "/images/json":
		list := []map[string]any{}
		for _, img := range f.held {
			list = append(list, map[string]any{"Id": img.id})
		}
		writeJSON(w, list)
	case r.Method == http.MethodGet && strings.HasPrefix(path, "/images/") && strings.HasSuffix(path, "/json"):
		name := strings.TrimSuffix(strings.TrimPrefix(path, "/images/"), "/json")
		img := f.find(name)
		if img == nil {
			notFound(w, "No such image: "+name)
			return
		}
		writeJSON(w, img.inspect())
	case r.Method == http.MethodPost && path == "/images/create":
		f.pull(w, r)
	case r.Method == http.MethodPost && strings.HasPrefix(path, "/images/") && strings.HasSuffix(path, "/tag"):
		img := f.find(strings.TrimSuffix(strings.TrimPrefix(path, "/images/"), "/tag"))
		if img == nil {
			notFound(w, "No such image")
			return
		}
		repo := norm(r.URL.Query().Get("repo"))
		if repo == img.repo && !slices.Contains(img.tags, r.URL.Query().Get("tag")) {
			img.tags = append(img.tags, r.URL.Query().Get("tag"))
		}
		w.WriteHeader(http.StatusCreated)
	case r.Method == http.MethodGet && path == "/info":
		writeJSON(w, map[string]any{"Architecture": f.arch, "OSType": "linux", "DockerRootDir": f.root, "ServerVersion": "28.5.2"})
	default:
		http.Error(w, `{"message":"the fake engine does not know `+r.Method+" "+path+`"}`, http.StatusNotImplemented)
	}
}

func (img *fakeImage) inspect() map[string]any {
	tags := []string{}
	for _, t := range img.tags {
		tags = append(tags, img.repo+":"+t)
	}
	return map[string]any{
		"Id":          img.id,
		"RepoTags":    tags,
		"RepoDigests": []string{img.repo + "@" + img.digest},
		"Config":      map[string]any{"Env": img.env},
		"RootFS":      map[string]any{"Type": "layers", "Layers": img.layers},
	}
}

func (f *fakeDocker) pull(w http.ResponseWriter, r *http.Request) {
	repo, digest := norm(r.URL.Query().Get("fromImage")), r.URL.Query().Get("tag")
	img := f.registry[digest]
	if img == nil || img.repo != repo {
		img = f.mirrors[repo+"@"+digest]
	}
	if img == nil {
		notFound(w, "manifest unknown")
		return
	}
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(http.StatusOK)
	for _, line := range []string{
		`{"status":"Pulling fs layer","progressDetail":{},"id":"l1"}`,
		`{"status":"Downloading","progressDetail":{"current":500,"total":1000},"id":"l1"}`,
		`{"status":"Download complete","progressDetail":{},"id":"l1"}`,
		`{"status":"Pull complete","progressDetail":{},"id":"l1"}`,
		`{"status":"Digest: ` + digest + `"}`,
	} {
		fmt.Fprintln(w, line)
	}
	if !slices.Contains(f.held, img) {
		f.held = append(f.held, img)
	}
}

func (f *fakeDocker) listContainers(w http.ResponseWriter, r *http.Request) {
	var filter struct {
		Label map[string]bool `json:"label"`
	}
	_ = json.Unmarshal([]byte(r.URL.Query().Get("filters")), &filter)
	list := []map[string]any{}
	for _, c := range f.sortedContainers() {
		labels := f.labels(c)
		keep := true
		for want := range filter.Label {
			key, value, _ := strings.Cut(want, "=")
			if labels[key] != value {
				keep = false
			}
		}
		if keep {
			list = append(list, map[string]any{"Id": c.id, "Names": []string{"/" + c.name}, "Labels": labels})
		}
	}
	writeJSON(w, list)
}

func (f *fakeDocker) sortedContainers() []*fakeContainer {
	out := make([]*fakeContainer, 0, len(f.containers))
	for _, c := range f.containers {
		out = append(out, c)
	}
	sort.Slice(out, func(i, j int) bool { return out[i].name < out[j].name })
	return out
}

func (f *fakeDocker) labels(c *fakeContainer) map[string]string {
	return map[string]string{"com.docker.compose.project": f.project, "com.docker.compose.service": c.service}
}

// status is what the engine says of a container at now.
func (c *fakeContainer) status(now time.Time) (state, health string, started time.Time, restarts, exit int) {
	b := c.behave
	switch {
	case c.created:
		return "created", "", time.Time{}, 0, 0
	case c.stopped:
		return "exited", "", c.started, 0, 0
	case b.exits:
		return "exited", "", c.started, 0, 1
	case b.crash:
		n := int(now.Sub(c.started) / crashPeriod)
		return "running", "starting", c.started.Add(time.Duration(n) * crashPeriod), n, 0
	case b.noCheck:
		return "running", "", c.started, 0, 0
	case now.Sub(c.started) < b.sick:
		return "running", "unhealthy", c.started, 0, 0
	case now.Sub(c.started) < b.ready:
		return "running", "starting", c.started, 0, 0
	case b.unhealthy:
		return "running", "unhealthy", c.started, 0, 0
	}
	return "running", "healthy", c.started, 0, 0
}

func (f *fakeDocker) inspect(c *fakeContainer, now time.Time) map[string]any {
	state, health, started, restarts, exit := c.status(now)
	st := map[string]any{"Status": state, "Running": state == "running", "ExitCode": exit, "StartedAt": started.UTC().Format(time.RFC3339Nano)}
	if health != "" {
		st["Health"] = map[string]any{"Status": health}
	}
	config := map[string]any{"Image": c.ref, "Labels": f.labels(c)}
	if !c.behave.noCheck && !c.behave.exits {
		config["Healthcheck"] = map[string]any{"Test": []string{"CMD", "true"}, "Interval": int64(10 * time.Millisecond), "Timeout": int64(10 * time.Millisecond), "Retries": 1, "StartPeriod": int64(c.behave.startPeriod)}
	}
	out := map[string]any{"Id": c.id, "Name": "/" + c.name, "Image": c.image.id, "RestartCount": restarts, "State": st, "Config": config}
	if c.service == mariadbService {
		out["Mounts"] = []map[string]any{{"Destination": mariadbDataDir, "Source": f.volume}}
	}
	return out
}

// cli runs one docker command.
func (f *fakeDocker) cli(req cliRequest) cliResponse {
	f.calls = append(f.calls, strings.Join(req.Args, " "))
	if f.hook != nil {
		if resp, handled := f.hook(f, req); handled {
			return resp
		}
	}
	args := req.Args
	switch {
	case len(args) >= 2 && args[0] == "compose":
		return f.compose(req, args[1:])
	case len(args) >= 1 && args[0] == "exec":
		return f.exec(args[1:], req.Stdin)
	}
	return cliResponse{Stderr: "fake docker: unknown command " + strings.Join(args, " ") + "\n", Code: 125}
}

func (f *fakeDocker) compose(req cliRequest, args []string) cliResponse {
	dir := req.Dir
	// The flags of compose itself come before its command. A file given
	// on stdin is the only file of its project, whose settings are the
	// environment alone (--env-file /dev/null).
	var stdin bool
	for len(args) > 2 && strings.HasPrefix(args[0], "--") {
		stdin = stdin || (args[0] == "--file" && args[1] == "/dev/stdin")
		args = args[2:]
	}
	switch args[0] {
	case "version":
		return cliResponse{Stdout: "2.29.7\n"}
	case "config":
		load := func() ([]string, error) {
			_, active, err := f.loadProject(dir)
			return active, err
		}
		if stdin {
			load = func() ([]string, error) {
				env := map[string]string{}
				for _, entry := range req.Env {
					key, value, _ := strings.Cut(entry, "=")
					env[key] = value
				}
				_, active, err := parseProject([][]byte{req.Stdin}, env)
				return active, err
			}
		}
		active, err := load()
		if err != nil {
			return cliResponse{Stderr: err.Error() + "\n", Code: 15}
		}
		if slices.Contains(args, "--services") {
			return cliResponse{Stdout: strings.Join(active, "\n") + "\n"}
		}
		return cliResponse{}
	case "up":
		var only []string
		for _, a := range args[1:] {
			if !strings.HasPrefix(a, "-") {
				only = append(only, a)
			}
		}
		return f.up(dir, only)
	case "stop":
		for _, name := range args[1:] {
			if c := f.containers[f.prefix+"-"+name]; c != nil {
				c.stopped = true
			}
		}
		return cliResponse{}
	case "start", "restart":
		for _, name := range args[1:] {
			c := f.containers[f.prefix+"-"+name]
			if c == nil {
				return cliResponse{Stderr: "service " + name + " has no container to start\n", Code: 1}
			}
			if args[0] == "restart" || c.stopped || c.created {
				f.start(c)
			}
		}
		return cliResponse{}
	case "rm":
		for _, name := range args[1:] {
			if strings.HasPrefix(name, "-") {
				continue
			}
			if _, ok := f.containers[f.prefix+"-"+name]; ok {
				delete(f.containers, f.prefix+"-"+name)
				f.removed = append(f.removed, name)
			}
		}
		return cliResponse{}
	case "run":
		return f.run(args[1:])
	}
	return cliResponse{Stderr: "fake compose: unknown command " + args[0] + "\n", Code: 1}
}

// manticoreRequest is the file of the Manticore data volume whose presence
// has the entrypoint drop the indexes and build them from the database
// before searchd answers: REBUILD_REQUEST of
// docker/manticore/docker-entrypoint.sh.
const manticoreRequest = "/var/lib/manticore/kvs-rebuild-before-start"

// run is docker compose run: a command in a container of its own, which the
// fake reads from what kvsctl runs. A touch through the entrypoint of the
// request file leaves it in the data volume of Manticore, and a script on
// the MariaDB volume moves its data files aside, or back.
func (f *fakeDocker) run(args []string) cliResponse {
	if i := slices.Index(args, "--entrypoint"); i >= 0 && i+2 < len(args) && args[i+1] == "touch" {
		if args[len(args)-1] == manticoreRequest {
			f.requested[args[i+2]] = true
		}
		return cliResponse{}
	}
	script := args[len(args)-1]
	f.movedWith = append(f.movedWith, f.runningServices())
	if strings.Contains(script, backMarker) {
		return f.moveBack(script)
	}
	m := regexp.MustCompile(`mkdir -p (\S+);`).FindStringSubmatch(script)
	if m == nil {
		return cliResponse{Stderr: "fake compose run: no folder in " + script + "\n", Code: 1}
	}
	if !slices.Contains(f.moved, m[1]) {
		f.moved = append(f.moved, m[1])
	}
	// Moved again, a folder keeps what the first move put in it.
	if f.dataSeries != "" || f.db != "" {
		f.folders[m[1]] = fakeData{series: f.dataSeries, db: f.db}
	}
	f.dataSeries, f.db = "", ""
	return cliResponse{}
}

// moveBack runs the script that puts the data files of a folder back in
// the data directory, the files there going to a folder of their own
// first when the script says the directory was emptied before.
func (f *fakeDocker) moveBack(script string) cliResponse {
	m := regexp.MustCompile(`if \[ ! -e (\S+)/` + regexp.QuoteMeta(backMarker) + ` \]; then if \[ ! -d (\S+) \]; then if \[ ([01]) = 1 \]`).FindStringSubmatch(script)
	if m == nil {
		return cliResponse{Stderr: "fake compose run: not a move back: " + script + "\n", Code: 1}
	}
	fresh, folder, moved := m[1], m[2], m[3] == "1"
	if !f.marked[fresh] {
		content, ok := f.folders[folder]
		if !ok {
			if moved {
				return cliResponse{Stderr: folder + " is not in the MariaDB data volume\n", Code: 3}
			}
			return cliResponse{}
		}
		if moved {
			f.folders[fresh] = fakeData{series: f.dataSeries, db: f.db}
		}
		f.marked[fresh] = true
		f.dataSeries, f.db = content.series, content.db
		delete(f.folders, folder)
		f.back = append(f.back, folder)
		return cliResponse{}
	}
	if content, ok := f.folders[folder]; ok {
		f.dataSeries, f.db = content.series, content.db
		delete(f.folders, folder)
		f.back = append(f.back, folder)
	}
	return cliResponse{}
}

// up is docker compose up -d: every active service, or the ones named and
// the ones they need, gets a container of the image its files name,
// recreated when that image changed and started when it was stopped. A
// service that needs another one healthy is started once it is, and when
// it is not, compose stops there with the container it created never
// started, the way depends_on with condition service_healthy does.
func (f *fakeDocker) up(dir string, only []string) cliResponse {
	services, active, err := f.loadProject(dir)
	if err != nil {
		return cliResponse{Stderr: err.Error() + "\n", Code: 15}
	}
	targets := active
	if len(only) > 0 {
		targets = slices.Clone(only)
		for i := 0; i < len(targets); i++ {
			for _, need := range services[targets[i]].needs {
				if !slices.Contains(targets, need) {
					targets = append(targets, need)
				}
			}
		}
	}
	targets = slices.Clone(targets)
	sort.SliceStable(targets, func(i, j int) bool { return targets[i] == mariadbService && targets[j] != mariadbService })
	var lines []string
	// printed is what compose printed so far, each line ended.
	printed := func() string {
		if len(lines) == 0 {
			return ""
		}
		return strings.Join(lines, "\n") + "\n"
	}
	for _, name := range targets {
		ref, ok := services[name]
		if !ok {
			return cliResponse{Stdout: printed(), Stderr: "no such service: " + name + "\n", Code: 1}
		}
		img := f.find(ref.image)
		if img == nil {
			return cliResponse{Stdout: printed(), Stderr: "Error response from daemon: pull access denied for " + ref.image + "\n", Code: 1}
		}
		cname := f.prefix + "-" + name
		c := f.containers[cname]
		same := c != nil && c.image == img && c.ref == ref.image
		if failed := f.waitHealthy(ref.needs); failed != "" {
			if !same {
				if c != nil {
					lines = append(lines, "Container "+cname+" Recreate")
				}
				f.seq++
				f.containers[cname] = &fakeContainer{id: fmt.Sprintf("%064x", f.seq), name: cname, service: name, ref: ref.image, image: img, created: true}
				lines = append(lines, "Container "+cname+" Created")
			}
			return cliResponse{Stdout: strings.Join(lines, "\n") + "\n", Stderr: "dependency failed to start: " + failed + "\n", Code: 1}
		}
		switch {
		case same && !c.stopped && !c.created:
			lines = append(lines, "Container "+cname+" Running")
		case same:
			f.start(c)
			lines = append(lines, "Container "+cname+" Started")
		default:
			if c != nil {
				lines = append(lines, "Container "+cname+" Recreate")
			}
			f.seq++
			c = &fakeContainer{id: fmt.Sprintf("%064x", f.seq), name: cname, service: name, ref: ref.image, image: img}
			f.containers[cname] = c
			f.start(c)
			lines = append(lines, "Container "+cname+" Started")
		}
	}
	return cliResponse{Stdout: strings.Join(lines, "\n") + "\n"}
}

// waitHealthy waits, the lock let go meanwhile, for the containers of the
// services needs names to be healthy, and says why one never was: not
// running, unhealthy, or restarting.
func (f *fakeDocker) waitHealthy(needs []string) string {
	deadline := time.Now().Add(5 * time.Second)
	for _, need := range needs {
		for {
			c := f.containers[f.prefix+"-"+need]
			if c == nil {
				return "service " + need + " has no container"
			}
			state, health, _, restarts, _ := c.status(time.Now())
			switch {
			case state != "running" || restarts > 0:
				return "container " + c.name + " exited"
			case health == "unhealthy":
				return "container " + c.name + " is unhealthy"
			case health == "starting" && time.Now().Before(deadline):
				f.mu.Unlock()
				time.Sleep(5 * time.Millisecond)
				f.mu.Lock()
				continue
			case health == "starting":
				return "container " + c.name + " is still starting"
			}
			break
		}
	}
	return ""
}

// start starts a container. A MariaDB server initialises a fresh data
// directory with its series, upgrades older files to it, and cannot open
// the files of a newer series: it then keeps crashing. The entrypoint of a
// service reads the request to rebuild its indexes here, at the start of a
// container, and only then: a container that keeps running never sees one.
func (f *fakeDocker) start(c *fakeContainer) {
	c.started, c.stopped, c.created = time.Now(), false, false
	if f.requested[c.service] {
		delete(f.requested, c.service)
		f.rebuilds = append(f.rebuilds, c.service)
	}
	b, ok := f.behaviors[norm(stripDigest(c.ref))]
	if !ok {
		b = behavior{ready: 20 * time.Millisecond}
	}
	if s := c.image.series; s != "" {
		switch {
		case f.dataSeries == "":
			f.dataSeries = s
		case manifest.LessSeries(s, f.dataSeries):
			b = behavior{crash: true}
		case manifest.LessSeries(f.dataSeries, s):
			f.dataSeries = s
		}
	}
	c.behave = b
	if b.migrate != "" {
		f.db = b.migrate
	}
}

func stripDigest(ref string) string {
	if i := strings.IndexByte(ref, '@'); i >= 0 {
		return ref[:i]
	}
	return ref
}

func (f *fakeDocker) exec(args []string, stdin []byte) cliResponse {
	// exec -i <container> sh -c <script>
	if len(args) < 2 {
		return cliResponse{Stderr: "fake exec: no container\n", Code: 1}
	}
	name, script := args[1], args[len(args)-1]
	c := f.containers[name]
	if c == nil {
		return cliResponse{Stderr: "Error response from daemon: No such container: " + name + "\n", Code: 1}
	}
	if state, _, _, _, _ := c.status(time.Now()); state != "running" {
		return cliResponse{Stderr: "Error response from daemon: container " + name + " is not running\n", Code: 1}
	}
	switch {
	case strings.Contains(script, "mariadb-dump"):
		f.dumpedWith = append(f.dumpedWith, f.runningServices())
		return cliResponse{Stdout: "-- fake dump\n-- holds " + f.db + "\n"}
	case strings.Contains(script, "information_schema.engines"):
		// Every table of the fake takes part in transactions.
		return cliResponse{Stdout: "0\t\n"}
	case strings.Contains(script, "PROCESSLIST"):
		return cliResponse{}
	case strings.Contains(script, "information_schema"):
		return cliResponse{Stdout: "1048576\n"}
	}
	m := regexp.MustCompile(`(?m)^-- holds (.*)$`).FindSubmatch(stdin)
	if m == nil {
		return cliResponse{Stderr: "ERROR 1064: not a dump of the fake\n", Code: 1}
	}
	f.db = string(m[1])
	f.replays = append(f.replays, f.db)
	f.replayedWith = append(f.replayedWith, f.runningServices())
	return cliResponse{}
}

// runningServices are the services whose containers run, sorted.
func (f *fakeDocker) runningServices() []string {
	var out []string
	for _, c := range f.sortedContainers() {
		if state, _, _, _, _ := c.status(time.Now()); state == "running" {
			out = append(out, c.service)
		}
	}
	return out
}

type fakeService struct {
	image, profile string
	// needs are the services this one waits for, healthy.
	needs []string
}

// overrideNames are the overrides compose loads beside docker-compose.yml
// while COMPOSE_FILE is unset, the first one it finds and only that one.
var overrideNames = []string{"compose.override.yml", "compose.override.yaml", "docker-compose.override.yml", "docker-compose.override.yaml"}

// loadProject reads the compose project the way docker compose does, from a
// format of its own: one "service image [profile] [needs:service]" line
// per service, the files COMPOSE_FILE names (later ones override the
// image), or docker-compose.yml and the override compose finds without it,
// ${VAR}, ${VAR:-default} and ${VAR:?message} taken from the .env, and the
// profiles of COMPOSE_PROFILES.
func (f *fakeDocker) loadProject(dir string) (map[string]fakeService, []string, error) {
	env, err := instance.ReadEnv(filepath.Join(dir, ".env"))
	if err != nil {
		return nil, nil, err
	}
	sep := env["COMPOSE_PATH_SEPARATOR"]
	if sep == "" {
		sep = ":"
	}
	files := []string{"docker-compose.yml"}
	if list := env["COMPOSE_FILE"]; list != "" {
		files = strings.Split(list, sep)
	} else {
		for _, name := range overrideNames {
			if _, err := os.Stat(filepath.Join(dir, name)); err == nil {
				files = append(files, name)
				break
			}
		}
	}
	var contents [][]byte
	for _, name := range files {
		data, err := os.ReadFile(filepath.Join(dir, name))
		if err != nil {
			return nil, nil, fmt.Errorf("open %s: no such file or directory", filepath.Join(dir, name))
		}
		contents = append(contents, data)
	}
	return parseProject(contents, env)
}

// parseProject reads the files of a project, in the format of loadProject
// and in their order, with the settings of env.
func parseProject(contents [][]byte, env map[string]string) (map[string]fakeService, []string, error) {
	services := map[string]fakeService{}
	for _, data := range contents {
		for _, line := range strings.Split(string(data), "\n") {
			fields := strings.Fields(line)
			if len(fields) == 0 || strings.HasPrefix(fields[0], "#") {
				continue
			}
			svc := services[fields[0]]
			if len(fields) > 1 {
				svc.image = fields[1]
			}
			for _, field := range fields[min(len(fields), 2):] {
				if need, ok := strings.CutPrefix(field, "needs:"); ok {
					svc.needs = append(svc.needs, need)
				} else {
					svc.profile = field
				}
			}
			services[fields[0]] = svc
		}
	}
	profiles := strings.Split(env["COMPOSE_PROFILES"], ",")
	var active []string
	for _, name := range slices.Sorted(maps.Keys(services)) {
		svc := services[name]
		image, err := interpolate(svc.image, env)
		if err != nil {
			return nil, nil, err
		}
		svc.image = image
		services[name] = svc
		if svc.profile == "" || slices.Contains(profiles, svc.profile) {
			active = append(active, name)
		}
	}
	return services, active, nil
}

var varRe = regexp.MustCompile(`\$\{([A-Z0-9_]+)(?:(:-|:\?)([^}]*))?\}`)

func interpolate(s string, env map[string]string) (string, error) {
	var failure error
	out := varRe.ReplaceAllStringFunc(s, func(m string) string {
		sub := varRe.FindStringSubmatch(m)
		value := env[sub[1]]
		switch {
		case sub[2] == ":-" && value == "":
			return sub[3]
		case sub[2] == ":?" && value == "" && failure == nil:
			failure = fmt.Errorf("required variable %s is missing a value: %s", sub[1], sub[3])
		}
		return value
	})
	return out, failure
}

func writeJSON(w http.ResponseWriter, v any) {
	w.Header().Set("Content-Type", "application/json")
	_ = json.NewEncoder(w).Encode(v)
}

func notFound(w http.ResponseWriter, msg string) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(http.StatusNotFound)
	_ = json.NewEncoder(w).Encode(map[string]string{"message": msg})
}
