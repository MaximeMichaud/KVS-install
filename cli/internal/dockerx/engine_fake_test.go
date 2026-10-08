package dockerx

import (
	"encoding/base64"
	"encoding/json"
	"fmt"
	"net"
	"net/http"
	"os"
	"path/filepath"
	"regexp"
	"strings"
	"sync"
	"testing"

	"github.com/moby/moby/api/types/container"
	"github.com/moby/moby/api/types/image"
	"github.com/moby/moby/api/types/registry"
	"github.com/moby/moby/api/types/system"
	"github.com/moby/moby/api/types/volume"
)

// fakeEngine answers the part of the Engine API kvsctl uses, on a unix
// socket DOCKER_HOST points at, and records what it was asked.
type fakeEngine struct {
	mu sync.Mutex
	// images are looked up by every name the engine would find them by:
	// repository:tag and repository@digest.
	images     map[string]image.InspectResponse
	containers []container.InspectResponse
	volumes    map[string]volume.Volume
	info       system.Info
	// pulled answers a pull of fromImage at tag (a digest when the pull is
	// by digest): the stream lines to send, and the image the engine then
	// holds under name@digest.
	pulled func(fromImage, tag string) (lines []string, img *image.InspectResponse)
	pulls  []pullRequest
	tagged []string
	// versions are the API versions the requests named in their path.
	versions []string
}

type pullRequest struct {
	fromImage, tag string
	auth           *registry.AuthConfig
}

// fakeAPIVersion is the API version the fake answers a ping with, older
// than the newest the client knows.
const fakeAPIVersion = "1.47"

var versionPrefix = regexp.MustCompile(`^/v([0-9.]+)(/.*)$`)

// newFakeEngine starts the fake and a client connected to it.
func newFakeEngine(t *testing.T) (*fakeEngine, *Client) {
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
	f := &fakeEngine{images: map[string]image.InspectResponse{}, volumes: map[string]volume.Volume{}}
	srv := &http.Server{Handler: f}
	go func() { _ = srv.Serve(listener) }()
	t.Cleanup(func() { srv.Close() })
	t.Setenv("DOCKER_HOST", "unix://"+sock)
	t.Setenv("DOCKER_API_VERSION", "")
	t.Setenv("DOCKER_TLS_VERIFY", "")
	t.Setenv("DOCKER_CERT_PATH", "")
	c, err := New()
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { c.Close() })
	return f, c
}

// The tests change and read the fake between requests, through these, so
// the race detector sees the same lock the handlers take.

func (f *fakeEngine) setPulled(fn func(fromImage, tag string) ([]string, *image.InspectResponse)) {
	f.mu.Lock()
	defer f.mu.Unlock()
	f.pulled = fn
}

func (f *fakeEngine) pullRequests() []pullRequest {
	f.mu.Lock()
	defer f.mu.Unlock()
	return append([]pullRequest(nil), f.pulls...)
}

func (f *fakeEngine) apiVersions() []string {
	f.mu.Lock()
	defer f.mu.Unlock()
	return append([]string(nil), f.versions...)
}

func (f *fakeEngine) tags() []string {
	f.mu.Lock()
	defer f.mu.Unlock()
	return append([]string(nil), f.tagged...)
}

func (f *fakeEngine) set(fn func(f *fakeEngine)) {
	f.mu.Lock()
	defer f.mu.Unlock()
	fn(f)
}

func (f *fakeEngine) ServeHTTP(w http.ResponseWriter, r *http.Request) {
	path := r.URL.Path
	if path == "/_ping" {
		w.Header().Set("API-Version", fakeAPIVersion)
		w.Header().Set("OSType", "linux")
		w.WriteHeader(http.StatusOK)
		return
	}
	version := ""
	if m := versionPrefix.FindStringSubmatch(path); m != nil {
		version, path = m[1], m[2]
	}
	f.mu.Lock()
	defer f.mu.Unlock()
	if version != "" {
		f.versions = append(f.versions, version)
	}
	switch {
	case r.Method == http.MethodPost && path == "/images/create":
		f.pull(w, r)
	case r.Method == http.MethodPost && strings.HasPrefix(path, "/images/") && strings.HasSuffix(path, "/tag"):
		f.tag(w, r, strings.TrimSuffix(strings.TrimPrefix(path, "/images/"), "/tag"))
	case r.Method == http.MethodGet && strings.HasPrefix(path, "/images/") && strings.HasSuffix(path, "/json"):
		name := strings.TrimSuffix(strings.TrimPrefix(path, "/images/"), "/json")
		img, ok := f.images[name]
		if !ok {
			notFound(w, "No such image: "+name)
			return
		}
		writeJSON(w, img)
	case r.Method == http.MethodGet && path == "/containers/json":
		f.listContainers(w, r)
	case r.Method == http.MethodGet && strings.HasPrefix(path, "/containers/") && strings.HasSuffix(path, "/json"):
		name := strings.TrimSuffix(strings.TrimPrefix(path, "/containers/"), "/json")
		for _, c := range f.containers {
			if c.ID == name || strings.TrimPrefix(c.Name, "/") == name {
				writeJSON(w, c)
				return
			}
		}
		notFound(w, "No such container: "+name)
	case r.Method == http.MethodGet && path == "/info":
		writeJSON(w, f.info)
	case r.Method == http.MethodGet && strings.HasPrefix(path, "/volumes/"):
		name := strings.TrimPrefix(path, "/volumes/")
		vol, ok := f.volumes[name]
		if !ok {
			notFound(w, "get "+name+": no such volume")
			return
		}
		writeJSON(w, vol)
	default:
		http.Error(w, `{"message":"the fake engine does not know `+r.Method+" "+path+`"}`, http.StatusNotImplemented)
	}
}

func (f *fakeEngine) pull(w http.ResponseWriter, r *http.Request) {
	req := pullRequest{fromImage: r.URL.Query().Get("fromImage"), tag: r.URL.Query().Get("tag")}
	if header := r.Header.Get("X-Registry-Auth"); header != "" {
		var auth registry.AuthConfig
		if data, err := base64.URLEncoding.DecodeString(header); err == nil && json.Unmarshal(data, &auth) == nil {
			req.auth = &auth
		}
	}
	f.pulls = append(f.pulls, req)
	if f.pulled == nil {
		notFound(w, "manifest unknown")
		return
	}
	lines, img := f.pulled(req.fromImage, req.tag)
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(http.StatusOK)
	for _, line := range lines {
		fmt.Fprintln(w, line)
	}
	if img != nil {
		for _, name := range img.RepoDigests {
			f.images[name] = *img
		}
	}
}

func (f *fakeEngine) tag(w http.ResponseWriter, r *http.Request, source string) {
	img, ok := f.images[source]
	if !ok {
		notFound(w, "No such image: "+source)
		return
	}
	target := r.URL.Query().Get("repo") + ":" + r.URL.Query().Get("tag")
	img.RepoTags = append(img.RepoTags, target)
	f.images[target] = img
	f.tagged = append(f.tagged, source+" -> "+target)
	w.WriteHeader(http.StatusCreated)
}

func (f *fakeEngine) listContainers(w http.ResponseWriter, r *http.Request) {
	var filter struct {
		Label map[string]bool `json:"label"`
	}
	_ = json.Unmarshal([]byte(r.URL.Query().Get("filters")), &filter)
	list := []container.Summary{}
	for _, c := range f.containers {
		labels := c.Config.Labels
		keep := true
		for want := range filter.Label {
			key, value, _ := strings.Cut(want, "=")
			if labels[key] != value {
				keep = false
			}
		}
		if keep {
			list = append(list, container.Summary{ID: c.ID, Names: []string{c.Name}, Labels: labels})
		}
	}
	writeJSON(w, list)
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
