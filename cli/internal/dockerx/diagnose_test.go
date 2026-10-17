package dockerx

import (
	"context"
	"encoding/json"
	"strings"
	"testing"
	"time"

	"github.com/moby/moby/api/types/container"
)

func TestDiagnosticComposeAndSecretIsolation(t *testing.T) {
	log := installFakeDocker(t, "project")
	t.Setenv("COMPOSE_FILE", "unrelated-shell-project.yml")
	project, err := ReadProject(context.Background(), t.TempDir())
	if err != nil || project.Name != "kvs-example" || len(project.Services) != 1 {
		t.Fatalf("project=%+v error=%v", project, err)
	}
	if got := logged(readLog(t, log), "COMPOSE_FILE"); got != "unset" {
		t.Fatalf("shell Compose setting leaked: %s", got)
	}
	t.Setenv("FAKE_DOCKER_MODE", "fail")
	_, err = ReadProject(context.Background(), t.TempDir())
	if err == nil || strings.Contains(err.Error(), "undefined volume") {
		t.Fatalf("Compose stderr must not appear in diagnostic errors: %v", err)
	}
	for _, mode := range []string{"lines", "empty"} {
		t.Setenv("FAKE_DOCKER_MODE", mode)
		if _, err := ReadProject(context.Background(), t.TempDir()); err == nil {
			t.Fatalf("accepted %s configuration output", mode)
		}
	}
}

func TestDiagnosticProbeKeepsInputOutOfArgumentsAndBoundsExec(t *testing.T) {
	log := installFakeDocker(t, "stdin")
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	out, err := Probe(ctx, "test-container", strings.NewReader("private-input"), "php", "-r", "fixed-script")
	if err != nil || string(out) != "private-input" {
		t.Fatalf("output=%q error=%v", out, err)
	}
	args := logged(readLog(t, log), "args")
	if !strings.HasPrefix(args, "exec -i test-container timeout -s KILL ") || !strings.HasSuffix(args, " php -r fixed-script") || strings.Contains(args, "private-input") {
		t.Fatalf("unexpected exec arguments: %s", args)
	}
}

func TestDiagnosticCancellationKillsAnUnresponsiveCLI(t *testing.T) {
	log := installFakeDocker(t, "stubborn")
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	done := make(chan error, 1)
	go func() {
		_, err := DiagnosticComposeVersion(ctx)
		done <- err
	}()
	waitLogged(t, log, "ready")
	cancel()
	select {
	case err := <-done:
		if err == nil {
			t.Fatal("cancelled diagnostic succeeded")
		}
	case <-time.After(2 * time.Second):
		t.Fatal("unresponsive Docker CLI outlived the diagnostic")
	}
}

func TestDiagnosticOutputIsBounded(t *testing.T) {
	w := &cappedOutput{limit: 8}
	if _, err := w.Write([]byte("12345678")); err != nil {
		t.Fatal(err)
	}
	if _, err := w.Write([]byte("9")); err == nil || w.Len() != 8 {
		t.Fatal("oversized diagnostic output was accepted")
	}
}

func TestDiagnosticReadsActualPublishedPorts(t *testing.T) {
	f, c := newFakeEngine(t)
	var ctr container.InspectResponse
	err := json.Unmarshal([]byte(`{"Id":"nginx-id","Name":"/nginx","NetworkSettings":{"Ports":{"443/tcp":[{"HostIp":"127.0.0.2","HostPort":"8443"},{"HostIp":"::","HostPort":"9443"}],"80/tcp":null}}}`), &ctr)
	if err != nil {
		t.Fatal(err)
	}
	f.set(func(f *fakeEngine) { f.containers = []container.InspectResponse{ctr} })
	ports, err := c.PublishedPorts(context.Background(), "nginx-id")
	if err != nil || len(ports) != 2 {
		t.Fatalf("ports=%v error=%v", ports, err)
	}
	if ports[0].Target != 443 || ports[0].Protocol != "tcp" || ports[0].HostIP != "127.0.0.2" || ports[0].Published != "8443" || ports[1].HostIP != "::" {
		t.Fatalf("ports=%v", ports)
	}
}
