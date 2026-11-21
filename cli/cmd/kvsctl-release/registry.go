package main

import (
	"crypto/sha256"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net"
	"net/http"
	"os"
	"regexp"
	"strconv"
	"strings"
	"sync"
	"syscall"
	"time"

	"github.com/MaximeMichaud/KVS-install/cli/internal/manifest"
)

var digestRe = regexp.MustCompile(`^sha256:[0-9a-f]{64}$`)
var localRegistryRe = regexp.MustCompile(`^(localhost|127\.0\.0\.1)(:[0-9]+)?$`)

var refRe = regexp.MustCompile(`^(?:([^/]+\.[^/]+|[^/]+:[0-9]+|localhost)/)?([^:@]+)(?::([^@]+))?$`)

// Registries answer 429 when a reader goes over its rate limit (Docker Hub
// counts the manifest reads of every address without credentials) and a
// 5xx now and then. A release job that stopped on the first one would have
// to be re-run by hand, so an answer of that kind, and a connection that
// broke, is tried again after a pause that doubles each time, or after the
// Retry-After the registry sent, up to registryMaxPause.
var (
	registryAttempts  = 6
	registryFirstWait = 5 * time.Second
	registryMaxPause  = 2 * time.Minute
	registrySleep     = time.Sleep
)

// registryTokens keeps the anonymous token of each repository for the run:
// one image takes up to three reads (its index, its linux/amd64 manifest and
// its configuration), and one token covers all of them.
var registryTokens = struct {
	sync.Mutex
	byRepository map[string]string
}{byRepository: map[string]string{}}

// registryDigest asks the registry for the digest, the compressed size and
// the layers of name:tag through the distribution API (anonymous token when
// asked). The diff IDs of the layers come from the image configuration.
func registryDigest(ref string) (string, int64, []manifest.Layer, error) {
	host, base, tag, err := imageLocation(ref)
	if err != nil {
		return "", 0, nil, err
	}
	digest, size, layers, err := readImage(base, tag)
	if err != nil {
		return "", 0, nil, explainRefusal(host, err)
	}
	return digest, size, layers, nil
}

// imageLocation is where the distribution API serves an image reference:
// the registry host, the repository URL ("https://host/v2/name") and the
// tag. A reference without a host is a Docker Hub image, and an official
// image of Docker Hub (mariadb, memcached, alpine) lives under library/.
func imageLocation(ref string) (host, base, tag string, err error) {
	m := refRe.FindStringSubmatch(ref)
	if m == nil {
		return "", "", "", fmt.Errorf("cannot parse image reference %q", ref)
	}
	host, name, tag := m[1], m[2], m[3]
	if tag == "" {
		tag = "latest"
	}
	scheme := "https"
	switch {
	case host == "":
		host = "registry-1.docker.io"
		if !strings.Contains(name, "/") {
			name = "library/" + name
		}
	case localRegistryRe.MatchString(host):
		scheme = "http"
	}
	return host, fmt.Sprintf("%s://%s/v2/%s", scheme, host, name), tag, nil
}

// explainRefusal says what a refused read means for a release. Every image
// a manifest lists has to be readable without credentials, because a server
// that upgrades with kvsctl may have none. GHCR can create a new package
// private, and then the first release of that package stops here until its
// owner makes it public. An anonymous read GHCR refuses is a package that is
// private or an image that is missing, and the message names both. A rate
// limit that outlasted every retry is the time to try later.
func explainRefusal(host string, err error) error {
	var refused *registryError
	if !errors.As(err, &refused) {
		return err
	}
	switch refused.status {
	case http.StatusTooManyRequests:
		return fmt.Errorf("%w\nthe registry still limits this reader after %d attempts; "+
			"a registry counts the reads of an address without credentials, so re-run the publish job later", err, registryAttempts)
	case http.StatusUnauthorized, http.StatusForbidden, http.StatusNotFound:
	default:
		return err
	}
	if host == "ghcr.io" {
		why := "the package is private, or it does not exist"
		if refused.status == http.StatusNotFound {
			why = "the package is private, or this tag was never pushed"
		}
		return fmt.Errorf("%w\nGHCR does not show this image to an anonymous reader: %s. "+
			"A server may pull it without credentials, so every package a release lists must be public, and GHCR can create a new package private: "+
			"on GitHub, open the package (the Packages tab of its owner), Package settings, Danger Zone, Change visibility, Public. "+
			"Then re-run the publish job", err, why)
	}
	if refused.status == http.StatusNotFound {
		return err
	}
	return fmt.Errorf("%w\nthe registry refuses an anonymous read of this image; a server may pull it without credentials, so the image must be public", err)
}

// readImage reads one image of the repository at base ("https://host/v2/name").
func readImage(base, tag string) (string, int64, []manifest.Layer, error) {
	accept := "application/vnd.oci.image.manifest.v1+json, application/vnd.docker.distribution.manifest.v2+json, application/vnd.oci.image.index.v1+json, application/vnd.docker.distribution.manifest.list.v2+json"
	body, digest, err := registryObject(base+"/manifests/", tag, accept, false)
	if err != nil {
		return "", 0, nil, err
	}
	var index struct {
		Manifests []struct {
			Digest   string `json:"digest"`
			Platform struct {
				OS, Architecture string
			} `json:"platform"`
		} `json:"manifests"`
	}
	if err := json.Unmarshal(body, &index); err != nil {
		return "", 0, nil, err
	}
	if len(index.Manifests) > 0 {
		// A multi-platform index: keep the index digest (what docker pull
		// records) and read the linux/amd64 manifest for the layers.
		found := false
		for _, entry := range index.Manifests {
			if entry.Platform.OS == "linux" && entry.Platform.Architecture == "amd64" {
				body, _, err = registryObject(base+"/manifests/", entry.Digest, accept, true)
				if err != nil {
					return "", 0, nil, err
				}
				found = true
				break
			}
		}
		if !found {
			return "", 0, nil, errors.New("the index lists no linux/amd64 image")
		}
	}
	var doc struct {
		Config struct {
			Digest string `json:"digest"`
			Size   int64  `json:"size"`
		} `json:"config"`
		Layers []struct {
			Digest string `json:"digest"`
			Size   int64  `json:"size"`
		} `json:"layers"`
	}
	if err := json.Unmarshal(body, &doc); err != nil {
		return "", 0, nil, err
	}
	if doc.Config.Digest == "" || len(doc.Layers) == 0 {
		return "", 0, nil, errors.New("the image manifest lists no configuration or no layer")
	}
	config, _, err := registryObject(base+"/blobs/", doc.Config.Digest, "application/vnd.oci.image.config.v1+json, application/vnd.docker.container.image.v1+json, application/octet-stream", true)
	if err != nil {
		return "", 0, nil, fmt.Errorf("image configuration: %w", err)
	}
	var cfg struct {
		RootFS struct {
			DiffIDs []string `json:"diff_ids"`
		} `json:"rootfs"`
	}
	if err := json.Unmarshal(config, &cfg); err != nil {
		return "", 0, nil, fmt.Errorf("image configuration: %w", err)
	}
	if len(cfg.RootFS.DiffIDs) != len(doc.Layers) {
		return "", 0, nil, fmt.Errorf("the configuration lists %d diff ids for %d layers", len(cfg.RootFS.DiffIDs), len(doc.Layers))
	}
	size := doc.Config.Size
	var layers []manifest.Layer
	for n, l := range doc.Layers {
		if !digestRe.MatchString(l.Digest) || !digestRe.MatchString(cfg.RootFS.DiffIDs[n]) {
			return "", 0, nil, fmt.Errorf("layer %d has an invalid digest or diff ID", n)
		}
		size += l.Size
		layers = append(layers, manifest.Layer{Digest: l.Digest, DiffID: cfg.RootFS.DiffIDs[n], Size: l.Size})
	}
	return digest, size, layers, nil
}

// registryObject reads a manifest by tag, or a manifest or blob by its parent
// descriptor. Check the raw bytes before using any metadata they contain.
func registryObject(base, ref, accept string, byDigest bool) ([]byte, string, error) {
	if byDigest && !digestRe.MatchString(ref) {
		return nil, "", fmt.Errorf("invalid registry descriptor digest %q", ref)
	}
	body, headers, err := registryGet(base+ref, accept)
	if err != nil {
		return nil, "", err
	}
	digest := fmt.Sprintf("sha256:%x", sha256.Sum256(body))
	if byDigest && ref != digest {
		return nil, "", fmt.Errorf("registry object %s hashes to %s", ref, digest)
	}
	for _, claimed := range headers.Values("Docker-Content-Digest") {
		if claimed != digest {
			return nil, "", fmt.Errorf("registry claims %q for %s, body hashes to %s", claimed, ref, digest)
		}
	}
	return body, digest, nil
}

// registryGet reads url, tried again as the comment on registryAttempts
// says when the answer is a passing one.
func registryGet(url, accept string) ([]byte, http.Header, error) {
	for attempt := 1; ; attempt++ {
		body, headers, err := registryRead(url, accept)
		if err == nil {
			return body, headers, nil
		}
		wait, transient := retryPause(err, attempt)
		if !transient || attempt >= registryAttempts {
			return nil, nil, err
		}
		fmt.Fprintf(os.Stderr, "kvsctl-release: %v; attempt %d of %d in %s\n", err, attempt+1, registryAttempts, wait)
		registrySleep(wait)
	}
}

// retryPause says whether err is worth another attempt, and after how long.
func retryPause(err error, attempt int) (time.Duration, bool) {
	wait := registryFirstWait << (attempt - 1)
	var answer *registryError
	switch {
	case errors.As(err, &answer):
		switch answer.status {
		case http.StatusRequestTimeout, http.StatusTooManyRequests, http.StatusInternalServerError,
			http.StatusBadGateway, http.StatusServiceUnavailable, http.StatusGatewayTimeout:
		default:
			return 0, false
		}
		if after, ok := parseRetryAfter(answer.retryAfter, time.Now()); ok {
			wait = after
		}
	case brokenConnection(err):
	default:
		return 0, false
	}
	if wait > registryMaxPause {
		wait = registryMaxPause
	}
	return wait, true
}

// brokenConnection is a read that timed out or a connection the other side
// dropped, as opposed to an address that does not resolve or refuses.
func brokenConnection(err error) bool {
	var timeout net.Error
	if errors.As(err, &timeout) && timeout.Timeout() {
		return true
	}
	return errors.Is(err, syscall.ECONNRESET) || errors.Is(err, io.ErrUnexpectedEOF) || errors.Is(err, io.EOF)
}

// parseRetryAfter reads a Retry-After header: seconds, or an HTTP date.
func parseRetryAfter(value string, now time.Time) (time.Duration, bool) {
	value = strings.TrimSpace(value)
	if value == "" {
		return 0, false
	}
	if seconds, err := strconv.Atoi(value); err == nil && seconds >= 0 {
		return time.Duration(seconds) * time.Second, true
	}
	if at, err := http.ParseTime(value); err == nil {
		if wait := at.Sub(now); wait > 0 {
			return wait, true
		}
		return 0, true
	}
	return 0, false
}

// registryRead is one read of url. A registry that wants a token says so
// with a 401 and its token service: the anonymous token is fetched, kept
// for the repository, and the read made once more with it. A token kept
// from an earlier read that the registry no longer takes is replaced the
// same way.
func registryRead(url, accept string) ([]byte, http.Header, error) {
	repository := repositoryOf(url)
	registryTokens.Lock()
	token := registryTokens.byRepository[repository]
	registryTokens.Unlock()

	body, headers, challenge, err := registryFetch(url, accept, token)
	if err == nil || challenge == "" {
		return body, headers, err
	}
	realm, service, scope := authParam(challenge, "realm"), authParam(challenge, "service"), authParam(challenge, "scope")
	if realm == "" {
		return nil, nil, err
	}
	token, err = anonymousToken(fmt.Sprintf("%s?service=%s&scope=%s", realm, service, scope))
	if err != nil {
		return nil, nil, err
	}
	registryTokens.Lock()
	registryTokens.byRepository[repository] = token
	registryTokens.Unlock()
	body, headers, _, err = registryFetch(url, accept, token)
	return body, headers, err
}

// registryFetch sends one GET. On a 401 it returns the challenge of the
// registry beside the error.
func registryFetch(url, accept, token string) ([]byte, http.Header, string, error) {
	req, err := http.NewRequest(http.MethodGet, url, nil)
	if err != nil {
		return nil, nil, "", err
	}
	req.Header.Set("Accept", accept)
	if token != "" {
		req.Header.Set("Authorization", "Bearer "+token)
	}
	client := &http.Client{Timeout: 60 * time.Second}
	resp, err := client.Do(req)
	if err != nil {
		return nil, nil, "", err
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		refused := &registryError{url: url, status: resp.StatusCode, text: resp.Status, retryAfter: resp.Header.Get("Retry-After")}
		if resp.StatusCode == http.StatusUnauthorized {
			return nil, nil, resp.Header.Get("WWW-Authenticate"), refused
		}
		return nil, nil, "", refused
	}
	body, err := io.ReadAll(resp.Body)
	return body, resp.Header, "", err
}

// repositoryOf is the repository part of a manifest or blob URL, the key a
// token is kept under.
func repositoryOf(url string) string {
	for _, part := range []string{"/manifests/", "/blobs/"} {
		if n := strings.LastIndex(url, part); n >= 0 {
			return url[:n]
		}
	}
	return url
}

// registryError is an answer of a registry or of its token service other
// than 200, kept with its status so explainRefusal can say what it means,
// and with the Retry-After it carried.
type registryError struct {
	url        string
	status     int
	text       string
	retryAfter string
}

func (e *registryError) Error() string { return e.url + ": " + e.text }

// anonymousToken fetches the pull token a client without credentials gets
// from the token service the registry named. An answer without a token is
// an error: retrying the read without one would only meet the same
// challenge again.
func anonymousToken(url string) (string, error) {
	client := &http.Client{Timeout: 60 * time.Second}
	resp, err := client.Get(url)
	if err != nil {
		return "", err
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		return "", &registryError{url: url, status: resp.StatusCode, text: resp.Status, retryAfter: resp.Header.Get("Retry-After")}
	}
	var doc struct {
		Token       string `json:"token"`
		AccessToken string `json:"access_token"`
	}
	if err := json.NewDecoder(resp.Body).Decode(&doc); err != nil {
		return "", fmt.Errorf("%s: %w", url, err)
	}
	if doc.Token == "" {
		doc.Token = doc.AccessToken
	}
	if doc.Token == "" {
		return "", fmt.Errorf("%s: the token service answered without a token", url)
	}
	return doc.Token, nil
}

func authParam(challenge, key string) string {
	re := regexp.MustCompile(key + `="([^"]*)"`)
	if m := re.FindStringSubmatch(challenge); m != nil {
		return m[1]
	}
	return ""
}
