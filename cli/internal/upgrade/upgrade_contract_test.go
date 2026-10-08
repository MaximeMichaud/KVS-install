package upgrade

// The tests in this file exercise the parts of the runner that go through
// the instance API added with the hardening: PublishedEndpoint and
// SiteHost. They need that patch to build.

import (
	"context"
	"net"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
)

// site answers like nginx does: the apex redirects to www, the pages
// answer, and anything else is a 404.
func testServer(t *testing.T, handler http.HandlerFunc) (host, port string) {
	t.Helper()
	srv := httptest.NewTLSServer(handler)
	t.Cleanup(srv.Close)
	host, port, err := net.SplitHostPort(strings.TrimPrefix(srv.URL, "https://"))
	if err != nil {
		t.Fatal(err)
	}
	return host, port
}

// A site that answers a redirect is a site that is up. Demanding 200 used
// to roll back healthy upgrades of every USE_WWW installation, and restore
// the database on top of it.
func TestHTTPCheckAcceptsARedirect(t *testing.T) {
	_, port := testServer(t, func(w http.ResponseWriter, req *http.Request) {
		switch req.URL.Path {
		case "/":
			w.Header().Set("Location", "https://www."+req.Host+"/")
			w.WriteHeader(http.StatusMovedPermanently)
		case "/admin/":
			w.WriteHeader(http.StatusOK)
		default:
			w.WriteHeader(http.StatusNotFound)
		}
	})
	rep := &recorder{}
	r := &Runner{Inst: testInstance(t, "DOMAIN=example.com\nHTTPS_PORT=127.0.0.1:"+port+"\n"), Reporter: rep}
	if err := r.httpCheck(context.Background()); err != nil {
		t.Fatalf("a redirecting site is not down: %v", err)
	}
	logs := strings.Join(rep.logs(), "\n")
	if !strings.Contains(logs, "GET / answered 301") || !strings.Contains(logs, "GET /admin/ answered 200") {
		t.Errorf("the answers were not logged: %s", logs)
	}
}

func TestHTTPCheckRefusesAServerError(t *testing.T) {
	_, port := testServer(t, func(w http.ResponseWriter, req *http.Request) {
		w.WriteHeader(http.StatusBadGateway)
	})
	r := &Runner{Inst: testInstance(t, "DOMAIN=example.com\nHTTPS_PORT=127.0.0.1:"+port+"\n"), Reporter: &recorder{}}
	err := r.httpCheck(context.Background())
	if err == nil || !strings.Contains(err.Error(), "502") {
		t.Fatalf("a 502 is a down site, got %v", err)
	}
}

// USE_WWW moves the name the certificate and the server block answer to,
// so the probe has to ask for www.DOMAIN, not the apex.
func TestHTTPCheckAsksTheSiteHost(t *testing.T) {
	var asked []string
	_, port := testServer(t, func(w http.ResponseWriter, req *http.Request) {
		asked = append(asked, req.Host)
		w.WriteHeader(http.StatusOK)
	})
	r := &Runner{Inst: testInstance(t, "DOMAIN=example.com\nUSE_WWW=true\nHTTPS_PORT=127.0.0.1:"+port+"\n"), Reporter: &recorder{}}
	if err := r.httpCheck(context.Background()); err != nil {
		t.Fatal(err)
	}
	for _, host := range asked {
		if host != "www.example.com" {
			t.Errorf("asked %q, want www.example.com", host)
		}
	}
}
