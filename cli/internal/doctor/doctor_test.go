package doctor

import (
	"context"
	"crypto/ecdsa"
	"crypto/elliptic"
	"crypto/rand"
	"crypto/tls"
	"crypto/x509"
	"crypto/x509/pkix"
	"encoding/json"
	"encoding/pem"
	"errors"
	"fmt"
	"io"
	"math/big"
	"net"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"reflect"
	"slices"
	"strings"
	"testing"
	"time"

	"github.com/MaximeMichaud/KVS-install/cli/internal/diskspace"
	"github.com/MaximeMichaud/KVS-install/cli/internal/dockerx"
)

type fakeEngine struct {
	bindings                                  []dockerx.PublishedPort
	root                                      string
	endpoint                                  string
	states                                    []dockerx.ContainerState
	infoErr, containersErr, mountErr, pinsErr error
	wrong                                     []string
	pins                                      map[string]string
	closed                                    bool
}

func (f *fakeEngine) Endpoint() string {
	if f.endpoint != "" {
		return f.endpoint
	}
	return "unix:///test-doctor.sock"
}
func (f *fakeEngine) Info(context.Context) (dockerx.EngineInfo, error) {
	return dockerx.EngineInfo{OSType: "linux", Architecture: "x86_64", Version: "27.3.1", RootDir: f.root}, f.infoErr
}
func (f *fakeEngine) Containers(context.Context, string) ([]dockerx.ContainerState, error) {
	return f.states, f.containersErr
}
func (f *fakeEngine) MountSource(context.Context, string, string) (string, error) {
	return f.root, f.mountErr
}

func (f *fakeEngine) PublishedPorts(context.Context, string) ([]dockerx.PublishedPort, error) {
	return f.bindings, nil
}
func (f *fakeEngine) Unpinned(_ context.Context, _ string, pins map[string]string) ([]string, error) {
	f.pins = pins
	return f.wrong, f.pinsErr
}
func (f *fakeEngine) Close() error { f.closed = true; return nil }

type roundTrip func(*http.Request) (*http.Response, error)

func (f roundTrip) RoundTrip(r *http.Request) (*http.Response, error) { return f(r) }

func writeFile(t *testing.T, path, value string) {
	t.Helper()
	if err := os.MkdirAll(filepath.Dir(path), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(path, []byte(value), 0o600); err != nil {
		t.Fatal(err)
	}
}

func fixture(t *testing.T) (*runner, *fakeEngine) {
	t.Helper()
	root := t.TempDir()
	writeFile(t, filepath.Join(root, "docker", "docker-compose.yml"), "services: {}\n")
	writeFile(t, filepath.Join(root, "docker", ".env"), "DOMAIN=example.test\nSITE_PREFIX=kvs\nCOMPOSE_PROJECT_NAME=kvs\nPHP_VERSION=8.1\nIONCUBE=YES\nSSL_PROVIDER=selfsigned\n")
	r := newRunner(Options{Root: root, Timeout: 2 * time.Second})
	f := &fakeEngine{root: root}
	project := &dockerx.ProjectConfig{Name: "kvs", Services: map[string]dockerx.ServiceConfig{}}
	for _, name := range []string{"nginx", "php-fpm", "mariadb", "cron", "dragonfly"} {
		project.Services[name] = dockerx.ServiceConfig{}
		f.states = append(f.states, dockerx.ContainerState{ID: name, Name: "custom-" + name, Service: name, State: "running", Health: "healthy", Started: time.Now().Add(-time.Hour)})
	}
	r.probe.engine = func() (engine, error) { return f, nil }
	r.probe.version = func(context.Context) (string, error) { return "2.40.0", nil }
	r.probe.compose = func(context.Context, string) (*dockerx.ProjectConfig, error) { return project, nil }
	r.probe.space = func(string) (diskspace.Space, error) {
		return diskspace.Space{Size: 100 << 30, Avail: 42 << 30, Files: 1000, FreeFiles: 900}, nil
	}
	r.probe.client = &http.Client{Transport: roundTrip(func(req *http.Request) (*http.Response, error) {
		t.Errorf("unexpected external request: %s", req.URL)
		return nil, errors.New("external network forbidden")
	})}
	certificate, certPEM := testCertificate(t, []string{"example.test", "www.example.test"}, time.Now().Add(-time.Hour), time.Now().Add(90*24*time.Hour))
	server := httptest.NewUnstartedServer(http.HandlerFunc(func(w http.ResponseWriter, req *http.Request) {
		if req.Host != "example.test" {
			t.Errorf("HTTP Host = %s", req.Host)
		}
		fmt.Fprint(w, "ok")
	}))
	server.TLS = &tls.Config{Certificates: []tls.Certificate{certificate}}
	server.StartTLS()
	t.Cleanup(server.Close)
	host, port, _ := net.SplitHostPort(server.Listener.Addr().String())
	project.Services["nginx"] = dockerx.ServiceConfig{Ports: []dockerx.PublishedPort{{HostIP: host, Published: port, Target: 443, Protocol: "tcp"}}}
	f.bindings = project.Services["nginx"].Ports
	r.probe.exec = func(_ context.Context, _ string, _ io.Reader, args ...string) ([]byte, error) {
		last := args[len(args)-1]
		switch last {
		case phpProbe:
			return json.Marshal(phpInfo{Version: "8.1.34", IonCube: true, Extensions: []string{"mysqli", "pdo_mysql", "curl", "mbstring", "gd", "imagick", "zip", "memcached"}})
		case databaseProbe, cacheProbe:
			return []byte("ok"), nil
		case cronProbe:
			return []byte("www-data"), nil
		case searchProbe, toolsProbe:
			return nil, nil
		case "/etc/nginx/ssl/example.test/cert.pem":
			return certPEM, nil
		default:
			t.Errorf("unexpected container command: %v", args)
			return nil, errors.New("unexpected command")
		}
	}
	return r, f
}

func testCertificate(t *testing.T, names []string, before, after time.Time) (tls.Certificate, []byte) {
	t.Helper()
	key, err := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
	if err != nil {
		t.Fatal(err)
	}
	cert := &x509.Certificate{SerialNumber: big.NewInt(1), Subject: pkix.Name{CommonName: names[0]}, DNSNames: names, NotBefore: before, NotAfter: after, KeyUsage: x509.KeyUsageDigitalSignature | x509.KeyUsageCertSign, ExtKeyUsage: []x509.ExtKeyUsage{x509.ExtKeyUsageServerAuth}, BasicConstraintsValid: true, IsCA: true}
	der, err := x509.CreateCertificate(rand.Reader, cert, cert, &key.PublicKey, key)
	if err != nil {
		t.Fatal(err)
	}
	return tls.Certificate{Certificate: [][]byte{der}, PrivateKey: key}, pem.EncodeToMemory(&pem.Block{Type: "CERTIFICATE", Bytes: der})
}

func resultByID(t *testing.T, report Report, id string) Result {
	t.Helper()
	for _, result := range report.Checks {
		if result.ID == id {
			return result
		}
	}
	t.Fatalf("missing result %s: %+v", id, report)
	return Result{}
}

func snapshot(t *testing.T, root string) map[string]string {
	t.Helper()
	out := map[string]string{}
	err := filepath.WalkDir(root, func(path string, entry os.DirEntry, err error) error {
		if err != nil {
			return err
		}
		if entry.IsDir() {
			return nil
		}
		data, err := os.ReadFile(path)
		if err != nil {
			return err
		}
		out[path] = string(data)
		return nil
	})
	if err != nil {
		t.Fatal(err)
	}
	return out
}

func TestLocalDoctorOnUnadoptedInstallationDoesNotWriteOrFetch(t *testing.T) {
	r, f := fixture(t)
	t.Setenv("KVSCTL_MANIFEST_URL", "https://github.invalid/must-not-be-read")
	t.Setenv("KVSCTL_RELEASE_KEY", "invalid-key-must-not-be-read")
	before := snapshot(t, r.inst.Root)
	report := r.run(context.Background())
	if report.ExitCode != 0 || !report.Complete || report.Summary.Failed != 0 {
		t.Fatalf("report: %+v", report)
	}
	for _, id := range []string{"state.record", "backups"} {
		if resultByID(t, report, id).Status != Warn {
			t.Errorf("%s should warn", id)
		}
	}
	for _, id := range []string{"search", "files", "images", "network.dns", "network.https", "network.registries"} {
		if got := resultByID(t, report, id); got.Status != Skip || got.Incomplete {
			t.Errorf("normal skip %s: %+v", id, got)
		}
	}
	if !reflect.DeepEqual(before, snapshot(t, r.inst.Root)) {
		t.Fatal("doctor changed the installation")
	}
	if !f.closed {
		t.Error("Docker connection was not closed")
	}
}

func TestStrictAndSelection(t *testing.T) {
	r, _ := fixture(t)
	r.opts.Strict = true
	r.opts.Only = []string{"state"}
	report := r.run(context.Background())
	if report.ExitCode != 1 || report.Summary.Warnings != 1 || report.Summary.Failed != 0 || !report.Complete {
		t.Fatalf("strict report: %+v", report)
	}
	for _, check := range report.Checks {
		if check.Group != "state" && check.ID != "config.files" {
			t.Errorf("unexpected dependency: %s", check.ID)
		}
	}
	for _, o := range []Options{{Timeout: 0}, {Timeout: time.Second, Only: []string{"unknown"}}, {Timeout: time.Second, Only: []string{"network"}}} {
		if Validate(o) == nil {
			t.Errorf("accepted invalid options: %+v", o)
		}
	}
	if err := Validate(Options{Timeout: time.Second, Only: []string{"database", "storage", "config.env"}}); err != nil {
		t.Fatal(err)
	}
}

func TestFailureDoesNotHideIndependentChecks(t *testing.T) {
	r, f := fixture(t)
	f.infoErr = errors.New("socket inaccessible")
	report := r.run(context.Background())
	if report.ExitCode != 1 || report.Complete {
		t.Fatalf("report: %+v", report)
	}
	for _, id := range []string{"config.env", "config.compose", "storage.installation"} {
		if resultByID(t, report, id).Status != OK {
			t.Errorf("independent check %s did not run", id)
		}
	}
	if got := resultByID(t, report, "services"); got.Status != Skip || !got.Incomplete {
		t.Errorf("services: %+v", got)
	}
}

func TestUnrelatedServiceFailureDoesNotHideDatabaseProbe(t *testing.T) {
	r, f := fixture(t)
	project, _ := r.probe.compose(context.Background(), "")
	project.Services["manticore"] = dockerx.ServiceConfig{}
	f.states = append(f.states, dockerx.ContainerState{ID: "search", Service: "manticore", State: "exited", Exit: 1})
	report := r.run(context.Background())
	if resultByID(t, report, "services").Status != Fail || resultByID(t, report, "database").Status != OK || resultByID(t, report, "search").Status != Skip {
		t.Fatalf("report: %+v", report)
	}
}

func TestServicesProfilesOneShotsAndHealth(t *testing.T) {
	for _, tc := range []struct {
		name, state, health string
		code, restarts      int
		age                 time.Duration
		want                string
	}{
		{"healthy", "running", "healthy", 0, 0, time.Hour, OK},
		{"no-healthcheck", "running", "", 0, 0, time.Hour, OK},
		{"stopped", "exited", "", 1, 0, time.Hour, Fail},
		{"unhealthy", "running", "unhealthy", 0, 0, time.Hour, Fail},
		{"starting", "running", "starting", 0, 0, time.Second, Warn},
		{"stuck-starting", "running", "starting", 0, 0, time.Hour, Fail},
		{"crash-loop", "running", "healthy", 0, 4, time.Second, Fail},
	} {
		t.Run(tc.name, func(t *testing.T) {
			r, f := fixture(t)
			r.opts.Only = []string{"services"}
			f.states[0].State = tc.state
			f.states[0].Health = tc.health
			f.states[0].Exit = tc.code
			f.states[0].Restarts = tc.restarts
			f.states[0].Started = r.now.Add(-tc.age)
			if got := resultByID(t, r.run(context.Background()), "services").Status; got != tc.want {
				t.Fatalf("got %s, want %s", got, tc.want)
			}
		})
	}
	t.Run("completed-init-and-disabled-leftover", func(t *testing.T) {
		r, f := fixture(t)
		r.opts.Only = []string{"services"}
		p, _ := r.probe.compose(context.Background(), "")
		p.Services["kvs-init"] = dockerx.ServiceConfig{}
		f.states = append(f.states, dockerx.ContainerState{Service: "kvs-init", State: "exited", Exit: 0}, dockerx.ContainerState{Service: "manticore", State: "exited", Exit: 1}, dockerx.ContainerState{Service: "nginx", State: "exited", Exit: 1, OneShot: true})
		if got := resultByID(t, r.run(context.Background()), "services"); got.Status != OK {
			t.Fatalf("%+v", got)
		}
	})
}

func TestReadOnlyRuntimeFailures(t *testing.T) {
	for _, id := range []string{"php", "tools", "database", "cache", "search", "cron"} {
		t.Run(id, func(t *testing.T) {
			r, f := fixture(t)
			r.opts.Only = []string{id}
			if id == "search" {
				p, _ := r.probe.compose(context.Background(), "")
				p.Services["manticore"] = dockerx.ServiceConfig{}
				f.states = append(f.states, dockerx.ContainerState{ID: "search", Service: "manticore", State: "running"})
			}
			r.probe.exec = func(context.Context, string, io.Reader, ...string) ([]byte, error) {
				return nil, errors.New("credentials-must-not-appear")
			}
			report := r.run(context.Background())
			data, _ := json.Marshal(report)
			if resultByID(t, report, id).Status != Fail || strings.Contains(string(data), "credentials-must-not-appear") {
				t.Fatalf("%s", data)
			}
		})
	}
}

func TestTimeoutAndCancellation(t *testing.T) {
	r, _ := fixture(t)
	r.opts.Timeout = 20 * time.Millisecond
	r.opts.Only = []string{"config.compose", "storage.installation"}
	r.probe.compose = func(ctx context.Context, _ string) (*dockerx.ProjectConfig, error) {
		<-ctx.Done()
		return nil, ctx.Err()
	}
	start := time.Now()
	report := r.run(context.Background())
	if time.Since(start) > time.Second || report.Complete || resultByID(t, report, "storage.installation").Status != OK {
		t.Fatalf("report: %+v", report)
	}
	r, _ = fixture(t)
	ctx, cancel := context.WithCancel(context.Background())
	cancel()
	report = r.run(ctx)
	if report.ExitCode != 1 || report.Complete || report.Summary.Passed != 0 {
		t.Fatalf("cancelled report: %+v", report)
	}
}

func TestRemoteDockerIsNotContacted(t *testing.T) {
	r, f := fixture(t)
	r.opts.Only = []string{"docker.engine"}
	f.endpoint = "tcp://remote.example.test:2375"
	if resultByID(t, r.run(context.Background()), "docker.engine").Status != Fail {
		t.Fatal("remote engine accepted")
	}
	for _, ep := range []string{"unix:///run/user/1000/docker.sock", "tcp://127.0.0.1:2375", "tcp://[::1]:2375", "unix:///socket, from the docker context dev"} {
		if !localEngine(ep) {
			t.Errorf("local endpoint rejected: %s", ep)
		}
	}
}

func TestRecordedStateAndRecovery(t *testing.T) {
	for _, tc := range []struct {
		name, state, journal string
		id, want             string
	}{
		{"bad-state", "{", "", "state.record", Fail},
		{"empty-state", "{}", "", "state.record", Fail},
		{"recorded", `{"current":"1.0.0"}`, "", "state.record", OK},
		{"bad-journal", "", "{", "state.operation", Fail},
		{"unfinished", "", `{"format":2,"action":"upgrade","phase":"apply"}`, "state.operation", Fail},
	} {
		t.Run(tc.name, func(t *testing.T) {
			r, _ := fixture(t)
			r.opts.Only = []string{"state"}
			if tc.state != "" {
				writeFile(t, filepath.Join(r.inst.StateDir(), "state.json"), tc.state)
			}
			if tc.journal != "" {
				writeFile(t, filepath.Join(r.inst.StateDir(), "journal.json"), tc.journal)
			}
			if got := resultByID(t, r.run(context.Background()), tc.id); got.Status != tc.want {
				t.Fatalf("%+v", got)
			}
		})
	}
	t.Run("live-lock", func(t *testing.T) {
		r, _ := fixture(t)
		r.opts.Only = []string{"state.operation"}
		unlock, err := r.inst.Lock("test")
		if err != nil {
			t.Fatal(err)
		}
		defer unlock()
		report := r.run(context.Background())
		if report.Complete || resultByID(t, report, "state.operation").Status != Warn {
			t.Fatalf("%+v", report)
		}
	})
}

func TestCatalogDependenciesAreStableAndAcyclic(t *testing.T) {
	seen := []string{}
	for _, c := range Catalog() {
		if slices.Contains(seen, c.ID) {
			t.Fatalf("duplicate %s", c.ID)
		}
		for _, dep := range c.Requires {
			if !slices.Contains(seen, dep) {
				t.Fatalf("%s has unordered dependency %s", c.ID, dep)
			}
		}
		seen = append(seen, c.ID)
	}
}
