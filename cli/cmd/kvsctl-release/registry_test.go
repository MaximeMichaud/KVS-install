package main

import (
	"fmt"
	"net/http"
	"net/http/httptest"
	"strings"
	"sync"
	"sync/atomic"
	"testing"
	"time"
)

// recordSleeps replaces the pause between attempts for one test and
// returns what it was asked to wait.
func recordSleeps(t *testing.T) *[]time.Duration {
	t.Helper()
	var mu sync.Mutex
	waits := &[]time.Duration{}
	previous := registrySleep
	registrySleep = func(d time.Duration) {
		mu.Lock()
		*waits = append(*waits, d)
		mu.Unlock()
	}
	t.Cleanup(func() { registrySleep = previous })
	return waits
}

// flakyRegistry serves one single-platform image, after answering the first
// `failures` manifest reads with status (and Retry-After when set).
func flakyRegistry(failures int32, status int, retryAfter string) (*httptest.Server, *atomic.Int32) {
	var manifestReads atomic.Int32
	mux := http.NewServeMux()
	mux.HandleFunc("/v2/", func(w http.ResponseWriter, r *http.Request) {
		switch {
		case strings.Contains(r.URL.Path, "/manifests/"):
			if manifestReads.Add(1) <= failures {
				if retryAfter != "" {
					w.Header().Set("Retry-After", retryAfter)
				}
				w.WriteHeader(status)
				return
			}
			w.Header().Set("Docker-Content-Digest", stubDigest(r.URL.Path))
			fmt.Fprint(w, `{"mediaType":"application/vnd.oci.image.manifest.v1+json","config":{"digest":"sha256:config","size":3},"layers":[{"digest":"sha256:layer","size":97}]}`)
		case strings.Contains(r.URL.Path, "/blobs/"):
			fmt.Fprint(w, `{"rootfs":{"diff_ids":["sha256:diff"]}}`)
		default:
			http.NotFound(w, r)
		}
	})
	return httptest.NewServer(mux), &manifestReads
}

// A rate limit or a passing server error is read again after the pause the
// registry asked for, and the release goes on.
func TestRegistryRetriesARateLimit(t *testing.T) {
	waits := recordSleeps(t)
	registry, reads := flakyRegistry(2, http.StatusTooManyRequests, "3")
	defer registry.Close()

	digest, size, _, err := registryDigest(strings.TrimPrefix(registry.URL, "http://") + "/library/mariadb:11.8.9")
	if err != nil {
		t.Fatalf("a rate limit that passes must not stop the read: %v", err)
	}
	if digest == "" || size != 100 {
		t.Errorf("read after the retries: digest %q, size %d", digest, size)
	}
	if reads.Load() != 3 {
		t.Errorf("the manifest was read %d times, want 3", reads.Load())
	}
	if len(*waits) != 2 || (*waits)[0] != 3*time.Second || (*waits)[1] != 3*time.Second {
		t.Errorf("the pauses must follow Retry-After: %v", *waits)
	}
}

// Without Retry-After the pause doubles, up to the limit, and the read
// gives up after registryAttempts with the last answer and what to do.
func TestRegistryGivesUpAfterTheAttempts(t *testing.T) {
	waits := recordSleeps(t)
	registry, reads := flakyRegistry(100, http.StatusTooManyRequests, "")
	defer registry.Close()

	_, _, _, err := registryDigest(strings.TrimPrefix(registry.URL, "http://") + "/library/mariadb:11.8.9")
	if err == nil {
		t.Fatal("a registry that never stops limiting must fail the read")
	}
	if int(reads.Load()) != registryAttempts {
		t.Errorf("the manifest was read %d times, want %d", reads.Load(), registryAttempts)
	}
	want := []time.Duration{5 * time.Second, 10 * time.Second, 20 * time.Second, 40 * time.Second, 80 * time.Second}
	if fmt.Sprint(*waits) != fmt.Sprint(want) {
		t.Errorf("pauses %v, want %v", *waits, want)
	}
	for _, part := range []string{"429", "re-run the publish job later"} {
		if !strings.Contains(err.Error(), part) {
			t.Errorf("%q does not say %q", err, part)
		}
	}
}

// A refusal is no passing condition: it is reported at once.
func TestRegistryDoesNotRetryARefusal(t *testing.T) {
	waits := recordSleeps(t)
	for _, status := range []int{http.StatusNotFound, http.StatusForbidden, http.StatusBadRequest} {
		registry, reads := flakyRegistry(100, status, "")
		_, _, _, err := registryDigest(strings.TrimPrefix(registry.URL, "http://") + "/kvs-install/nginx:26.11.0")
		registry.Close()
		if err == nil {
			t.Errorf("status %d: the read must fail", status)
		}
		if reads.Load() != 1 {
			t.Errorf("status %d: read %d times, want once", status, reads.Load())
		}
	}
	if len(*waits) != 0 {
		t.Errorf("no pause is due for a refusal: %v", *waits)
	}
}

// The anonymous token of a repository serves every read of its image: the
// index, the linux/amd64 manifest and the configuration. A token the
// registry stops taking is replaced once.
func TestRegistryKeepsTheTokenOfARepository(t *testing.T) {
	recordSleeps(t)
	var tokens atomic.Int32
	var current atomic.Value
	current.Store("token-1")
	mux := http.NewServeMux()
	var server *httptest.Server
	mux.HandleFunc("/v2/", func(w http.ResponseWriter, r *http.Request) {
		if r.Header.Get("Authorization") != "Bearer "+current.Load().(string) {
			w.Header().Set("WWW-Authenticate", fmt.Sprintf(`Bearer realm="%s/token",service="test",scope="repository:library/mariadb:pull"`, server.URL))
			w.WriteHeader(http.StatusUnauthorized)
			return
		}
		switch {
		case strings.HasSuffix(r.URL.Path, "/manifests/11.8.9"):
			w.Header().Set("Docker-Content-Digest", "sha256:index")
			fmt.Fprint(w, `{"mediaType":"application/vnd.oci.image.index.v1+json","manifests":[{"digest":"sha256:amd64","platform":{"os":"linux","architecture":"amd64"}}]}`)
		case strings.HasSuffix(r.URL.Path, "/manifests/sha256:amd64"):
			fmt.Fprint(w, `{"mediaType":"application/vnd.oci.image.manifest.v1+json","config":{"digest":"sha256:config","size":3},"layers":[{"digest":"sha256:layer","size":97}]}`)
		case strings.Contains(r.URL.Path, "/blobs/"):
			fmt.Fprint(w, `{"rootfs":{"diff_ids":["sha256:diff"]}}`)
		default:
			http.NotFound(w, r)
		}
	})
	mux.HandleFunc("/token", func(w http.ResponseWriter, r *http.Request) {
		tokens.Add(1)
		fmt.Fprintf(w, `{"token":%q}`, current.Load().(string))
	})
	server = httptest.NewServer(mux)
	defer server.Close()
	ref := strings.TrimPrefix(server.URL, "http://") + "/library/mariadb:11.8.9"

	digest, _, _, err := registryDigest(ref)
	if err != nil {
		t.Fatal(err)
	}
	if digest != "sha256:index" {
		t.Errorf("digest %q, want the index digest", digest)
	}
	if tokens.Load() != 1 {
		t.Errorf("%d token requests for one image, want 1", tokens.Load())
	}

	current.Store("token-2")
	if _, _, _, err := registryDigest(ref); err != nil {
		t.Fatalf("an expired token must be replaced: %v", err)
	}
	if tokens.Load() != 2 {
		t.Errorf("%d token requests after the token expired, want 2", tokens.Load())
	}
}

// A multi-platform index is read for its linux/amd64 image, wherever the
// index lists it: the manifest gets the index digest, which docker pull
// records, and the layers, diff IDs and sizes of the amd64 image, which
// kvsctl compares with what the engine holds. An index lists other
// platforms, a Windows image on amd64 among them, and attestations
// (unknown/unknown) as well, in any order: the linux/amd64 entry below is
// neither the first nor the last, so only its platform can pick it.
func TestRegistryReadsTheAMD64ImageOfAnIndex(t *testing.T) {
	recordSleeps(t)
	images := map[string]string{
		"sha256:arm64":       `{"config":{"digest":"sha256:config-arm64","size":5},"layers":[{"digest":"sha256:arm-1","size":11},{"digest":"sha256:arm-2","size":12}]}`,
		"sha256:windows":     `{"config":{"digest":"sha256:config-windows","size":8},"layers":[{"digest":"sha256:win-1","size":21},{"digest":"sha256:win-2","size":22}]}`,
		"sha256:attestation": `{"config":{"digest":"sha256:config-attestation","size":6},"layers":[{"digest":"sha256:in-toto","size":13}]}`,
		"sha256:amd64":       `{"config":{"digest":"sha256:config-amd64","size":7},"layers":[{"digest":"sha256:amd-1","size":100},{"digest":"sha256:amd-2","size":200},{"digest":"sha256:amd-3","size":300}]}`,
	}
	configs := map[string]string{
		"sha256:config-arm64":       `{"rootfs":{"diff_ids":["sha256:arm-diff-1","sha256:arm-diff-2"]}}`,
		"sha256:config-windows":     `{"rootfs":{"diff_ids":["sha256:win-diff-1","sha256:win-diff-2"]}}`,
		"sha256:config-attestation": `{"rootfs":{"diff_ids":["sha256:in-toto-diff"]}}`,
		"sha256:config-amd64":       `{"rootfs":{"diff_ids":["sha256:amd-diff-1","sha256:amd-diff-2","sha256:amd-diff-3"]}}`,
	}
	index := map[string]string{
		"11.8.9": `{"mediaType":"application/vnd.oci.image.index.v1+json","manifests":[
			{"digest":"sha256:arm64","platform":{"os":"linux","architecture":"arm64","variant":"v8"}},
			{"digest":"sha256:windows","platform":{"os":"windows","architecture":"amd64","os.version":"10.0.20348.2340"}},
			{"digest":"sha256:amd64","platform":{"os":"linux","architecture":"amd64"}},
			{"digest":"sha256:attestation","platform":{"os":"unknown","architecture":"unknown"}}]}`,
		"no-linux-amd64": `{"mediaType":"application/vnd.oci.image.index.v1+json","manifests":[
			{"digest":"sha256:arm64","platform":{"os":"linux","architecture":"arm64","variant":"v8"}},
			{"digest":"sha256:windows","platform":{"os":"windows","architecture":"amd64","os.version":"10.0.20348.2340"}}]}`,
	}
	registry := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		_, ref, _ := strings.Cut(r.URL.Path, "/manifests/")
		_, blob, _ := strings.Cut(r.URL.Path, "/blobs/")
		switch {
		case index[ref] != "":
			w.Header().Set("Docker-Content-Digest", "sha256:index")
			fmt.Fprint(w, index[ref])
		case images[ref] != "":
			fmt.Fprint(w, images[ref])
		case configs[blob] != "":
			fmt.Fprint(w, configs[blob])
		default:
			http.NotFound(w, r)
		}
	}))
	defer registry.Close()
	host := strings.TrimPrefix(registry.URL, "http://")

	digest, size, layers, err := registryDigest(host + "/library/mariadb:11.8.9")
	if err != nil {
		t.Fatal(err)
	}
	if digest != "sha256:index" {
		t.Errorf("digest %q, want the digest of the index", digest)
	}
	if size != 7+100+200+300 {
		t.Errorf("size %d, want the configuration and the layers of the amd64 image, 607", size)
	}
	want := []string{"sha256:amd-1 sha256:amd-diff-1 100", "sha256:amd-2 sha256:amd-diff-2 200", "sha256:amd-3 sha256:amd-diff-3 300"}
	var got []string
	for _, l := range layers {
		got = append(got, fmt.Sprintf("%s %s %d", l.Digest, l.DiffID, l.Size))
	}
	if strings.Join(got, ", ") != strings.Join(want, ", ") {
		t.Errorf("layers %v, want the amd64 ones %v", got, want)
	}

	if _, _, _, err := registryDigest(host + "/library/mariadb:no-linux-amd64"); err == nil || !strings.Contains(err.Error(), "no linux/amd64 image") {
		t.Errorf("an index without a linux/amd64 image must be refused, whatever else runs on amd64: %v", err)
	}
}

// The diff IDs of the configuration pair with the layers by position, so a
// configuration that lists another number of them describes another image.
func TestRegistryRefusesDiffIDsThatDoNotPairWithTheLayers(t *testing.T) {
	recordSleeps(t)
	for _, diffIDs := range []string{
		`["sha256:d1","sha256:d2","sha256:d3","sha256:d4"]`,
		`["sha256:d1","sha256:d2"]`,
	} {
		registry := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
			switch {
			case strings.Contains(r.URL.Path, "/manifests/"):
				fmt.Fprint(w, `{"config":{"digest":"sha256:config","size":3},"layers":[{"digest":"sha256:l1","size":1},{"digest":"sha256:l2","size":2},{"digest":"sha256:l3","size":3}]}`)
			case strings.Contains(r.URL.Path, "/blobs/"):
				fmt.Fprintf(w, `{"rootfs":{"diff_ids":%s}}`, diffIDs)
			default:
				http.NotFound(w, r)
			}
		}))
		_, _, _, err := registryDigest(strings.TrimPrefix(registry.URL, "http://") + "/kvs-install/nginx:26.11.0")
		registry.Close()
		if err == nil || !strings.Contains(err.Error(), "diff ids for 3 layers") {
			t.Errorf("diff ids %s for three layers must be refused: %v", diffIDs, err)
		}
	}
}

// Each repository has its own anonymous token: a token kept under the wrong
// key would be sent to another repository and refused, and fetched again
// for every image read.
func TestRegistryKeepsATokenPerRepository(t *testing.T) {
	recordSleeps(t)
	var tokens atomic.Int32
	mux := http.NewServeMux()
	var server *httptest.Server
	mux.HandleFunc("/v2/", func(w http.ResponseWriter, r *http.Request) {
		repository, _, _ := strings.Cut(strings.TrimPrefix(r.URL.Path, "/v2/"), "/manifests/")
		repository, _, _ = strings.Cut(repository, "/blobs/")
		if r.Header.Get("Authorization") != "Bearer token-"+repository {
			w.Header().Set("WWW-Authenticate", fmt.Sprintf(`Bearer realm="%s/token",service="test",scope="repository:%s:pull"`, server.URL, repository))
			w.WriteHeader(http.StatusUnauthorized)
			return
		}
		switch {
		case strings.Contains(r.URL.Path, "/manifests/"):
			fmt.Fprint(w, `{"config":{"digest":"sha256:config","size":3},"layers":[{"digest":"sha256:layer","size":97}]}`)
		default:
			fmt.Fprint(w, `{"rootfs":{"diff_ids":["sha256:diff"]}}`)
		}
	})
	mux.HandleFunc("/token", func(w http.ResponseWriter, r *http.Request) {
		tokens.Add(1)
		repository := strings.TrimSuffix(strings.TrimPrefix(r.URL.Query().Get("scope"), "repository:"), ":pull")
		fmt.Fprintf(w, `{"token":%q}`, "token-"+repository)
	})
	server = httptest.NewServer(mux)
	defer server.Close()
	host := strings.TrimPrefix(server.URL, "http://")

	for _, ref := range []string{"/library/mariadb:11.8.9", "/library/memcached:1.6.45-alpine", "/library/mariadb:11.4.13"} {
		if _, _, _, err := registryDigest(host + ref); err != nil {
			t.Fatalf("%s: %v", ref, err)
		}
	}
	if tokens.Load() != 2 {
		t.Errorf("%d token requests for two repositories, want 2", tokens.Load())
	}
}

// A reference names its registry, or it is a Docker Hub image, whose
// official images (mariadb, memcached, alpine) live under library/.
func TestImageLocation(t *testing.T) {
	cases := map[string][3]string{
		"mariadb:11.8.9":         {"registry-1.docker.io", "https://registry-1.docker.io/v2/library/mariadb", "11.8.9"},
		"alpine":                 {"registry-1.docker.io", "https://registry-1.docker.io/v2/library/alpine", "latest"},
		"neilpang/acme.sh:3.1.6": {"registry-1.docker.io", "https://registry-1.docker.io/v2/neilpang/acme.sh", "3.1.6"},
		"ghcr.io/example/kvs-install/nginx:26.11.0":           {"ghcr.io", "https://ghcr.io/v2/example/kvs-install/nginx", "26.11.0"},
		"docker.dragonflydb.io/dragonflydb/dragonfly:v1.35.1": {"docker.dragonflydb.io", "https://docker.dragonflydb.io/v2/dragonflydb/dragonfly", "v1.35.1"},
		"localhost:5000/kvs/nginx:1":                          {"localhost:5000", "http://localhost:5000/v2/kvs/nginx", "1"},
		"127.0.0.1:5000/kvs/nginx:1":                          {"127.0.0.1:5000", "http://127.0.0.1:5000/v2/kvs/nginx", "1"},
	}
	for ref, want := range cases {
		host, base, tag, err := imageLocation(ref)
		if err != nil || [3]string{host, base, tag} != want {
			t.Errorf("imageLocation(%q) = %s %s %s, %v; want %v", ref, host, base, tag, err, want)
		}
	}
	if _, _, _, err := imageLocation("nginx:1.27@sha256:aaa"); err == nil {
		t.Error("a reference that does not parse must be refused")
	}
}

func TestParseRetryAfter(t *testing.T) {
	now := time.Date(2026, 10, 6, 12, 0, 0, 0, time.UTC)
	cases := []struct {
		value string
		want  time.Duration
		ok    bool
	}{
		{"7", 7 * time.Second, true},
		{" 0 ", 0, true},
		{"Tue, 06 Oct 2026 12:00:30 GMT", 30 * time.Second, true},
		{"Tue, 06 Oct 2026 11:00:00 GMT", 0, true},
		{"", 0, false},
		{"-3", 0, false},
		{"soon", 0, false},
	}
	for _, c := range cases {
		got, ok := parseRetryAfter(c.value, now)
		if got != c.want || ok != c.ok {
			t.Errorf("parseRetryAfter(%q) = %v, %v; want %v, %v", c.value, got, ok, c.want, c.ok)
		}
	}
}

// A Retry-After beyond the limit is cut to it.
func TestRetryPauseIsBounded(t *testing.T) {
	err := &registryError{url: "u", status: http.StatusTooManyRequests, text: "429", retryAfter: "3600"}
	if wait, ok := retryPause(err, 1); !ok || wait != registryMaxPause {
		t.Errorf("retryPause = %v, %v; want %v, true", wait, ok, registryMaxPause)
	}
}
