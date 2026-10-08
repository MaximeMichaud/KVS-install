package manifest

import (
	"errors"
	"net"
	"net/http"
	"net/http/httptest"
	"os"
	"os/signal"
	"sync"
	"syscall"
	"testing"
	"time"
)

// silentServer accepts connections and never answers, which is what a
// manifest server that hangs looks like; asked gets a value per connection.
// The connections close with the test.
func silentServer(t *testing.T) (string, <-chan struct{}) {
	t.Helper()
	listener, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	asked := make(chan struct{}, 16)
	var mu sync.Mutex
	var conns []net.Conn
	go func() {
		for {
			conn, err := listener.Accept()
			if err != nil {
				return
			}
			mu.Lock()
			conns = append(conns, conn)
			mu.Unlock()
			asked <- struct{}{}
		}
	}()
	t.Cleanup(func() {
		listener.Close()
		mu.Lock()
		defer mu.Unlock()
		for _, conn := range conns {
			conn.Close()
		}
	})
	return listener.Addr().String(), asked
}

// An interrupt ends a Fetch at once, as a Ctrl-C does a command that
// catches it to stop cleanly, the signal then takes its course, and a Fetch
// after it fails without asking the server: the command is on its way out.
// A read that fails otherwise is no interrupt.
func TestFetchEndsAtAnInterrupt(t *testing.T) {
	t.Cleanup(func() { interrupted.Store(false) })
	missing := httptest.NewServer(http.NotFoundHandler())
	defer missing.Close()
	if _, err := Fetch(missing.URL + "/manifest.json"); err == nil || errors.Is(err, ErrInterrupted) {
		t.Fatalf("a 404: %v", err)
	}
	// The test process catches the signal as a command does, so a Fetch
	// that does not leaves it running. It gets the interrupt twice: when it
	// is sent, and when Fetch sends it again once it let go of it.
	caught := make(chan os.Signal, 2)
	signal.Notify(caught, os.Interrupt)
	defer signal.Stop(caught)
	addr, asked := silentServer(t)
	url := "http://" + addr + "/manifest.json"
	done := make(chan error, 1)
	go func() {
		_, err := Fetch(url)
		done <- err
	}()
	select {
	case <-asked:
	case err := <-done:
		t.Fatalf("Fetch ended before it asked the server: %v", err)
	case <-time.After(10 * time.Second):
		t.Fatal("Fetch did not ask the server")
	}
	if err := syscall.Kill(os.Getpid(), syscall.SIGINT); err != nil {
		t.Fatal(err)
	}
	select {
	case err := <-done:
		if !errors.Is(err, ErrInterrupted) || err.Error() != "the read of the manifest was interrupted" {
			t.Errorf("the interrupted read: %v", err)
		}
	case <-time.After(5 * time.Second):
		t.Fatal("Fetch still waits for the server 5 seconds after the interrupt")
	}
	// Both have reached the process before the next Fetch listens: the one
	// sent again would otherwise end that Fetch too, whether it remembered
	// the interrupt or not.
	for _, what := range []string{"the interrupt", "the interrupt Fetch sends again"} {
		select {
		case <-caught:
		case <-time.After(5 * time.Second):
			t.Fatalf("%s did not reach the process", what)
		}
	}
	next := make(chan error, 1)
	go func() {
		_, err := Fetch(url)
		next <- err
	}()
	select {
	case err := <-next:
		if !errors.Is(err, ErrInterrupted) {
			t.Errorf("a read after the interrupt: %v", err)
		}
	case <-asked:
		// It waits for the server until the test closes it.
		t.Error("the read after the interrupt asked the server")
	case <-time.After(10 * time.Second):
		t.Fatal("a read after the interrupt still runs 10 seconds later")
	}
}
