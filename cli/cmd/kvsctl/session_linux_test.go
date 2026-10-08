//go:build linux

package main

import (
	"bytes"
	"context"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"golang.org/x/sys/unix"

	"github.com/MaximeMichaud/KVS-install/cli/internal/instance"
	"github.com/MaximeMichaud/KVS-install/cli/internal/manifest"
	"github.com/MaximeMichaud/KVS-install/cli/internal/ui"
	"github.com/MaximeMichaud/KVS-install/cli/internal/upgrade"
)

// openTerminal opens a pseudo-terminal: its master side for the test, its
// slave side for kvsctl.
func openTerminal(t *testing.T) (master, slave *os.File) {
	t.Helper()
	master, err := os.OpenFile("/dev/ptmx", os.O_RDWR|unix.O_NOCTTY, 0)
	if err != nil {
		t.Skipf("no pseudo-terminal: %v", err)
	}
	t.Cleanup(func() { master.Close() })
	var n uint32
	conn, err := master.SyscallConn()
	if err == nil {
		var ioctlErr error
		err = conn.Control(func(fd uintptr) {
			if ioctlErr = unix.IoctlSetPointerInt(int(fd), unix.TIOCSPTLCK, 0); ioctlErr == nil {
				n, ioctlErr = unix.IoctlGetUint32(int(fd), unix.TIOCGPTN)
			}
		})
		if err == nil {
			err = ioctlErr
		}
	}
	if err == nil {
		slave, err = os.OpenFile(fmt.Sprintf("/dev/pts/%d", n), os.O_RDWR|unix.O_NOCTTY, 0)
	}
	if err != nil {
		t.Fatalf("a pseudo-terminal: %v", err)
	}
	t.Cleanup(func() { slave.Close() })
	return master, slave
}

// An upgrade, a rollback or a recovery asks its question only when stdin
// and stdout are both a terminal, as restore and clean ask theirs. With
// the output sent to a file from a terminal, the question is answered no
// at once and stderr says how to answer yes: kvsctl must not wait on the
// terminal for the answer to a question written into the file.
func TestPlainRunAsksOnlyWhenStdoutIsATerminal(t *testing.T) {
	if ui.IsTerminal(os.Stdout) {
		t.Skip("stdout is a terminal, and the case needs it sent elsewhere")
	}
	_, slave := openTerminal(t)
	oldIn := os.Stdin
	os.Stdin = slave
	t.Cleanup(func() { os.Stdin = oldIn })
	errOut := useStderr(t)
	s := testSession(t, newRoot(t))
	runner := &upgrade.Runner{Inst: s.inst}
	answered := make(chan bool, 1)
	go func() {
		_ = s.runScreen(runner, "title", upgrade.UpgradeSteps, func(ctx context.Context) error {
			answered <- runner.Reporter.Confirm(ctx, "Upgrade to 1.1.0?")
			return nil
		})
	}()
	select {
	case yes := <-answered:
		if yes {
			t.Fatal("answered yes")
		}
	case <-time.After(5 * time.Second):
		t.Fatal("the question waits on the terminal while the output goes to a file")
	}
	if want := "Upgrade to 1.1.0? [y/N] no: kvsctl asks only when stdin and stdout are both a terminal; pass --yes to answer yes"; !strings.Contains(errOut.String(), want) {
		t.Fatalf("stderr reads %q, want %q", errOut.String(), want)
	}
}

// terminal is what kvsctl draws on a pseudo-terminal, read as it comes,
// and the side of it the keys are typed on.
type terminal struct {
	*lockedBuffer
	master *os.File
}

// useTerminal makes a pseudo-terminal of cols by rows the stdin and the
// stdout of kvsctl for the length of the test.
func useTerminal(t *testing.T, cols, rows uint16) *terminal {
	t.Helper()
	master, slave := openTerminal(t)
	conn, err := slave.SyscallConn()
	if err != nil {
		t.Fatal(err)
	}
	var sizeErr error
	if err := conn.Control(func(fd uintptr) {
		sizeErr = unix.IoctlSetWinsize(int(fd), unix.TIOCSWINSZ, &unix.Winsize{Col: cols, Row: rows})
	}); err != nil || sizeErr != nil {
		t.Fatalf("the size of the terminal: %v %v", err, sizeErr)
	}
	screen := &lockedBuffer{b: &bytes.Buffer{}}
	go func() { _, _ = io.Copy(screen, master) }()
	oldIn, oldOut := os.Stdin, os.Stdout
	os.Stdin, os.Stdout = slave, slave
	t.Cleanup(func() { os.Stdin, os.Stdout = oldIn, oldOut })
	return &terminal{lockedBuffer: screen, master: master}
}

// --quiet keeps a run off the screen, whose window shows the log lines
// --quiet leaves to the log: its lines show the steps alone, as with
// --plain. Without either, a terminal gets the screen.
func TestQuietRunsHaveNoScreen(t *testing.T) {
	useTerminal(t, 80, 24)
	plain, quiet := flagPlain, flagQuiet
	t.Cleanup(func() { flagPlain, flagQuiet = plain, quiet })
	for _, c := range []struct {
		plain, quiet, screen bool
	}{{false, false, true}, {false, true, false}, {true, false, false}} {
		flagPlain, flagQuiet = c.plain, c.quiet
		if got := screenWanted(); got != c.screen {
			t.Errorf("--plain %v --quiet %v on a terminal: screen %v, want %v", c.plain, c.quiet, got, c.screen)
		}
	}
}

// With --yes nothing is asked: the screen of a run never lists the
// confirmation among the steps still to come, under the one that runs.
// (The name of the test, which names the directory of the run and so its
// log, the screen shows, must not hold the title of that step.)
func TestScreenWithYesListsNoQuestion(t *testing.T) {
	screen := useTerminal(t, 120, 40)
	s := testSession(t, newRoot(t))
	yes, plain, quiet := flagYes, flagPlain, flagQuiet
	t.Cleanup(func() { flagYes, flagPlain, flagQuiet = yes, plain, quiet })
	flagYes, flagPlain, flagQuiet = true, false, false
	runner := &upgrade.Runner{Inst: s.inst}
	proceed := make(chan struct{})
	done := make(chan error, 1)
	go func() {
		done <- s.runScreen(runner, "title", upgrade.UpgradeSteps, func(ctx context.Context) error {
			runner.Reporter.Event(upgrade.Event{Kind: upgrade.KindStepStart, Step: upgrade.StepCheck, Message: "the manifest"})
			runner.Reporter.Event(upgrade.Event{Kind: upgrade.KindStepDone, Step: upgrade.StepCheck, Message: "1.1.0"})
			runner.Reporter.Event(upgrade.Event{Kind: upgrade.KindStepStart, Step: upgrade.StepBackup, Message: "database and configuration"})
			<-proceed
			runner.Reporter.Event(upgrade.Event{Kind: upgrade.KindDone})
			return nil
		})
	}()
	waitFor(t, "the backup running above the steps still to come", func() bool {
		text := screen.String()
		return strings.Contains(text, "database and configuration") && strings.Contains(text, ui.StepTitle(upgrade.StepVerify))
	})
	close(proceed)
	select {
	case err := <-done:
		if err != nil {
			t.Fatal(err)
		}
	case <-time.After(10 * time.Second):
		t.Fatal("the screen did not end with the run")
	}
	if text := screen.String(); strings.Contains(text, ui.StepTitle(upgrade.StepConfirm)) {
		t.Fatalf("with --yes the screen lists the confirmation:\n%s", text)
	}
}

// A quiet upgrade asked on a terminal shows what it asks about before the
// question, as an upgrade that is not quiet does: the services with what
// they download, the notes of every release it installs, and what happens
// to the database. It prints no title: the question names the site and
// the versions.
func TestQuietUpgradeShowsWhatItAsksAbout(t *testing.T) {
	screen := useTerminal(t, 160, 40)
	root := newRoot(t)
	useRoot(t, root)
	useStderr(t)
	// kvsctl prints on the terminal, which is its stdin too.
	oldOut := stdout
	stdout = os.Stdout
	t.Cleanup(func() { stdout = oldOut })
	saveState(t, root, &instance.State{Current: "1.0.0", Files: []string{"docker/docker-compose.yml"}})
	m := &manifest.Manifest{Releases: []manifest.Release{
		{Version: "1.3.0", Date: "2026-10-09", Notes: "Manticore 13", Highlights: []string{"third highlight"}},
		{Version: "1.2.0", Date: "2026-10-05", Notes: "PHP images rebuilt", Database: "migrates"},
		{Version: "1.1.0", Date: "2026-10-01", Notes: "Nginx 1.29"},
		{Version: "1.0.0", Date: "2026-09-01"},
	}}
	usePlan(t, &upgrade.Plan{
		Current:  "1.0.0",
		Target:   &m.Releases[0],
		Manifest: m,
		Releases: []manifest.Release{m.Releases[2], m.Releases[1], m.Releases[0]},
		Services: []upgrade.PlanImage{{Service: "nginx", Ref: "example/nginx:1.3.0", Running: "example/nginx:1.0.0", Active: true, Bytes: 2048}},
		Bytes:    2048,
	})
	keepFlags(t)
	done := make(chan error, 1)
	go func() {
		cmd := rootCmd()
		cmd.SetArgs([]string{"upgrade", "--root", root, "--manifest", "https://example.com/manifest.json", "--quiet"})
		done <- cmd.Execute()
	}()
	waitFor(t, "the question", func() bool { return strings.Contains(screen.String(), "[y/N]") })
	text := screen.String()
	before := text[:strings.Index(text, "[y/N]")]
	for _, want := range []string{"nginx      1.0.0 -> 1.3.0", "2 kB to download", "1.1.0: Nginx 1.29", "1.2.0: PHP images rebuilt", "1.3.0: Manticore 13", "third highlight", "the database changes (1.2.0): a rollback replays the backup"} {
		if !strings.Contains(before, want) {
			t.Errorf("%q is not before the question:\n%s", want, text)
		}
	}
	if strings.Contains(text, "KVS stack · ") {
		t.Errorf("a quiet upgrade prints its title:\n%s", text)
	}
	if _, err := screen.master.Write([]byte("n\r")); err != nil {
		t.Fatal(err)
	}
	select {
	case err := <-done:
		if err == nil || !strings.Contains(err.Error(), "upgrade cancelled, nothing was changed") {
			t.Fatalf("answered no: %v", err)
		}
	case <-time.After(10 * time.Second):
		t.Fatal("the upgrade did not end at the answer")
	}
}

// A quiet clean asked on a terminal lists what it removes before the
// question, as the upgrade shows what it asks about, and the answer no
// removes nothing.
func TestQuietCleanAsksWithItsList(t *testing.T) {
	screen := useTerminal(t, 160, 40)
	root, inst := cleanRoot(t)
	useRoot(t, root)
	useStderr(t)
	// kvsctl prints on the terminal, which is its stdin too.
	oldOut := stdout
	stdout = os.Stdout
	t.Cleanup(func() { stdout = oldOut })
	keepFlags(t)
	done := make(chan error, 1)
	go func() {
		cmd := rootCmd()
		cmd.SetArgs([]string{"clean", "--root", root, "--quiet", "--dry-run=false"})
		done <- cmd.Execute()
	}()
	waitFor(t, "the question", func() bool { return strings.Contains(screen.String(), "[y/N]") })
	text := screen.String()
	before := text[:strings.Index(text, "[y/N]")]
	for _, want := range []string{"Release files:", filepath.Join(inst.StateDir(), "releases", "1.0.0"), "Downloads:", "Total:       2 kB", "Kept:        1.1.0, 1.2.0", "Remove 1 kept release, the downloaded bundles?"} {
		if !strings.Contains(before, want) {
			t.Errorf("%q is not before the question:\n%s", want, text)
		}
	}
	if _, err := screen.master.Write([]byte("n\r")); err != nil {
		t.Fatal(err)
	}
	select {
	case err := <-done:
		if err == nil || !strings.Contains(err.Error(), "clean cancelled, nothing was removed") {
			t.Fatalf("answered no: %v", err)
		}
	case <-time.After(10 * time.Second):
		t.Fatal("clean did not end at the answer")
	}
	if _, err := os.Stat(filepath.Join(inst.StateDir(), "releases", "1.0.0")); err != nil {
		t.Fatalf("the answer no removed the files of 1.0.0: %v", err)
	}
}

// A terminal that does not know its size, a serial console for one, gets
// the question of the screen on as few lines as an 80 column one, not one
// word per line of ten columns.
func TestScreenOfATerminalWithoutASize(t *testing.T) {
	screen := useTerminal(t, 0, 0)
	s := testSession(t, newRoot(t))
	yes, plain, quiet := flagYes, flagPlain, flagQuiet
	t.Cleanup(func() { flagYes, flagPlain, flagQuiet = yes, plain, quiet })
	flagYes, flagPlain, flagQuiet = false, false, false
	runner := &upgrade.Runner{Inst: s.inst}
	done := make(chan error, 1)
	go func() {
		done <- s.runScreen(runner, "title", upgrade.RollbackSteps, func(ctx context.Context) error {
			runner.Reporter.Event(upgrade.Event{Kind: upgrade.KindStepStart, Step: upgrade.StepConfirm, Message: "Roll example.com back from 1.1.0 to 1.0.0?"})
			answer := runner.Reporter.Confirm(ctx, "Roll back to 1.0.0 and replay backup-1.0.0-20261007-005419.tar, taken 2026-10-07 00:54 UTC?")
			runner.Reporter.Event(upgrade.Event{Kind: upgrade.KindDone, Err: fmt.Errorf("answered %v", answer)})
			return nil
		})
	}()
	waitFor(t, "the question", func() bool { return strings.Contains(screen.String(), "[y/N]") })
	if text := screen.String(); !strings.Contains(text, "Roll back to 1.0.0 and replay") {
		t.Errorf("the question is wrapped to a width of no size:\n%s", text)
	}
	if _, err := screen.master.Write([]byte("n")); err != nil {
		t.Fatal(err)
	}
	select {
	case err := <-done:
		if err != nil {
			t.Fatal(err)
		}
	case <-time.After(10 * time.Second):
		t.Fatal("the screen did not end with the run")
	}
}
