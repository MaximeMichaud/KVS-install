package doctor

import (
	"context"
	"crypto/tls"
	"errors"
	"fmt"
	"io"
	"net"
	"net/http"
	"net/http/httptest"
	"strings"
	"sync/atomic"
	"testing"
	"time"

	"github.com/MaximeMichaud/KVS-install/cli/internal/dockerx"
)

func TestOptionalHTTPSResponsesAndResolution(t *testing.T) {
	for _, tc := range []struct {
		name   string
		status int
		want   string
	}{{"reachable", 200, OK}, {"protected", 401, Warn}, {"forbidden", 403, Warn}, {"broken", 503, Fail}, {"transport-failure", 0, Fail}} {
		t.Run(tc.name, func(t *testing.T) {
			r, _ := fixture(t)
			r.opts.Network = true
			r.opts.Only = []string{"network.https"}
			writeFile(t, r.inst.EnvPath, `DOMAIN=localhost
PROJECT_HTTPS_PORT=8443
`)
			r.probe.client = &http.Client{Transport: roundTrip(func(req *http.Request) (*http.Response, error) {
				if req.URL.String() != "https://localhost:8443/" {
					t.Fatalf("unexpected endpoint: %s", req.URL)
				}
				if tc.status == 0 {
					return nil, errors.New("transport failure")
				}
				return &http.Response{StatusCode: tc.status, Body: io.NopCloser(strings.NewReader(""))}, nil
			})}
			report := r.run(context.Background())
			if resultByID(t, report, "network.dns").Status != OK || resultByID(t, report, "network.https").Status != tc.want {
				t.Fatalf("%+v", report)
			}
		})
	}
}

func setHTTPS(t *testing.T, r *runner, f *fakeEngine, cert tls.Certificate, certPEM []byte, handler http.Handler) {
	t.Helper()
	server := httptest.NewUnstartedServer(handler)
	server.TLS = &tls.Config{Certificates: []tls.Certificate{cert}}
	server.StartTLS()
	t.Cleanup(server.Close)
	host, port, _ := net.SplitHostPort(server.Listener.Addr().String())
	project, _ := r.probe.compose(context.Background(), "")
	config := project.Services["nginx"]
	config.Ports = []dockerx.PublishedPort{{HostIP: host, Target: 443, Published: port, Protocol: "tcp"}}
	project.Services["nginx"] = config
	f.bindings = config.Ports
	previous := r.probe.exec
	r.probe.exec = func(ctx context.Context, name string, input io.Reader, args ...string) ([]byte, error) {
		if args[0] == "cat" {
			return certPEM, nil
		}
		return previous(ctx, name, input, args...)
	}
}

func TestHTTPFailuresProtectionAndRedirectIsolation(t *testing.T) {
	for _, tc := range []struct {
		name           string
		status         int
		location, want string
	}{{"success", 200, "", OK}, {"protected", 401, "", Warn}, {"forbidden", 403, "", Warn}, {"server-error", 500, "", Fail}, {"missing", 404, "", Fail}, {"same-site-redirect", 302, "/login/", OK}, {"external-redirect", 302, "https://github.invalid/never-follow", Warn}, {"redirect-without-location", 301, "", Warn}} {
		t.Run(tc.name, func(t *testing.T) {
			r, f := fixture(t)
			r.opts.Only = []string{"http"}
			var calls atomic.Int32
			cert, pem := testCertificate(t, []string{"example.test"}, time.Now().Add(-time.Hour), time.Now().Add(90*24*time.Hour))
			setHTTPS(t, r, f, cert, pem, http.HandlerFunc(func(w http.ResponseWriter, req *http.Request) {
				calls.Add(1)
				if tc.location != "" {
					w.Header().Set("Location", tc.location)
				}
				w.WriteHeader(tc.status)
			}))
			report := r.run(context.Background())
			if got := resultByID(t, report, "http"); got.Status != tc.want {
				t.Fatalf("%+v", got)
			}
			if calls.Load() != 2 {
				t.Fatalf("requests=%d, redirects must not be followed", calls.Load())
			}
			if resultByID(t, report, "tls").Status != OK {
				t.Fatal("HTTP result hid the TLS check")
			}
		})
	}
}

func TestTLSModesAndValidity(t *testing.T) {
	for _, tc := range []struct {
		name          string
		names         []string
		before, after time.Duration
		mode, want    string
	}{
		{"selfsigned", []string{"example.test"}, -time.Hour, 90 * 24 * time.Hour, "selfsigned", OK},
		{"near-expiry", []string{"example.test"}, -time.Hour, 7 * 24 * time.Hour, "selfsigned", Warn},
		{"expired", []string{"example.test"}, -48 * time.Hour, -time.Hour, "selfsigned", Fail},
		{"not-yet-valid", []string{"example.test"}, time.Hour, 90 * 24 * time.Hour, "selfsigned", Fail},
		{"wrong-host", []string{"other.test"}, -time.Hour, 90 * 24 * time.Hour, "selfsigned", Fail},
		{"public-mode-untrusted", []string{"example.test"}, -time.Hour, 90 * 24 * time.Hour, "letsencrypt", Fail},
	} {
		t.Run(tc.name, func(t *testing.T) {
			r, f := fixture(t)
			r.opts.Only = []string{"tls"}
			project, _ := r.probe.compose(context.Background(), "")
			cfg := project.Services["nginx"]
			cfg.Environment = map[string]string{"SSL_PROVIDER": tc.mode}
			project.Services["nginx"] = cfg
			cert, pem := testCertificate(t, tc.names, time.Now().Add(tc.before), time.Now().Add(tc.after))
			setHTTPS(t, r, f, cert, pem, http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) { fmt.Fprint(w, "ok") }))
			if got := resultByID(t, r.run(context.Background()), "tls"); got.Status != tc.want {
				t.Fatalf("%+v", got)
			}
		})
	}
}

func TestHTTPDoesNotProbeAnotherServiceAfterPortChange(t *testing.T) {
	r, f := fixture(t)
	r.opts.Only = []string{"http"}
	f.bindings = nil
	result := resultByID(t, r.run(context.Background()), "http")
	if result.Status != Fail || !strings.Contains(result.Message, "binding differs") {
		t.Fatalf("%+v", result)
	}
}

func TestNetworkIsExplicitAndDoesNotFetchReleaseManifests(t *testing.T) {
	r, _ := fixture(t)
	r.opts.Network = true
	r.opts.Only = []string{"network.registries"}
	project, _ := r.probe.compose(context.Background(), "")
	project.Services["mariadb"] = dockerx.ServiceConfig{Image: "mariadb:12.3"}
	project.Services["nginx"] = dockerx.ServiceConfig{Image: "ghcr.io/example/nginx:1"}
	var hosts []string
	r.probe.client = &http.Client{Transport: roundTrip(func(req *http.Request) (*http.Response, error) {
		if req.URL.Path != "/v2/" || req.Header.Get("Authorization") != "" {
			t.Fatalf("unexpected request: %v", req)
		}
		hosts = append(hosts, req.URL.Host)
		return &http.Response{StatusCode: 401, Body: io.NopCloser(strings.NewReader(""))}, nil
	})}
	report := r.run(context.Background())
	if resultByID(t, report, "network.registries").Status != OK || len(hosts) != 2 {
		t.Fatalf("hosts=%v report=%+v", hosts, report)
	}
}

func TestLocalAddressIPv4IPv6AndRemote(t *testing.T) {
	for _, tc := range []struct{ host, want string }{{"", "127.0.0.1:443"}, {"0.0.0.0", "127.0.0.1:443"}, {"127.0.0.2", "127.0.0.2:443"}, {"::", "[::1]:443"}, {"::1", "[::1]:443"}, {"203.0.113.1", ""}} {
		t.Run(tc.host, func(t *testing.T) {
			r, _ := fixture(t)
			r.project = &dockerx.ProjectConfig{Services: map[string]dockerx.ServiceConfig{"nginx": {Ports: []dockerx.PublishedPort{{HostIP: tc.host, Target: 443, Published: "443"}}}}}
			got, err := r.localAddress()
			if got != tc.want || (tc.want == "" && err == nil) {
				t.Fatalf("%s, %v", got, err)
			}
		})
	}
}
