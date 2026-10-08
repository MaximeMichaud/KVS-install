package main

import (
	"context"
	"errors"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"time"

	"github.com/spf13/cobra"

	"github.com/MaximeMichaud/KVS-install/cli/internal/backup"
	"github.com/MaximeMichaud/KVS-install/cli/internal/instance"
	"github.com/MaximeMichaud/KVS-install/cli/internal/ui"
	"github.com/MaximeMichaud/KVS-install/cli/internal/upgrade"
)

func init() { register(restoreCmd) }

func restoreCmd() *cobra.Command {
	var latest, noBackup, withEnv, otherSite bool
	var waits timeouts
	cmd := &cobra.Command{
		Use:   "restore [backup]",
		Short: "Replay the database of a backup over the running stack",
		Long: "Replay the database of a backup over the running stack. Without an\n" +
			"argument the backups of <root>/backups are listed and the one to\n" +
			"replay is asked for. The services that write to the database are\n" +
			"stopped first, so the site is down until the replay is over, and a\n" +
			"backup of the current database is taken, so a restore is never the\n" +
			"last word. Once the replay has begun it runs to its end: a database\n" +
			"replayed half way is neither the old one nor the new one, and a restore\n" +
			"cut short is finished by kvsctl recover. Once the services run again,\n" +
			"the restore waits for them to be healthy and for the site to answer, as\n" +
			"an upgrade does, leaving out the services that were not healthy before\n" +
			"it began: a stack that does not come up ends it with exit 1, the\n" +
			"database restored all the same. An archive of another site is\n" +
			"refused unless --other-site. With --env, the .env of the archive is put\n" +
			"back too, except the settings kvsctl manages and the ones that name the\n" +
			"site, which keep their live values. With --quiet, the progress of the\n" +
			"backup and of the replay, and the description of an archive named on\n" +
			"the command line or by --latest, go to the log alone.",
		Args: cobra.MaximumNArgs(1),
		RunE: func(cmd *cobra.Command, args []string) error {
			arg := ""
			if len(args) == 1 {
				arg = args[0]
			}
			g := newGuard("the restore stops, and the database is left as it is", nil)
			s, err := openSession("restore", g, sessionOptions{})
			if err != nil {
				return err
			}
			return s.finish(restore(s, arg, restoreOptions{latest: latest, noBackup: noBackup, withEnv: withEnv, otherSite: otherSite, waits: waits}))
		},
	}
	cmd.Flags().BoolVar(&latest, "latest", false, "restore the newest backup without asking which one")
	cmd.Flags().BoolVar(&noBackup, "no-backup", false, "do not back up the current database before replacing it")
	cmd.Flags().BoolVar(&withEnv, "env", false, "also put back the .env the archive carries, keeping the live values of the settings kvsctl manages and of DOMAIN, SITE_PREFIX and COMPOSE_PROJECT_NAME")
	cmd.Flags().BoolVar(&otherSite, "other-site", false, "restore an archive taken on another site, whose domain is not the DOMAIN of this one")
	waits.flags(cmd)
	return cmd
}

// restoreOptions are the flags of restore.
type restoreOptions struct {
	latest, noBackup, withEnv, otherSite bool
	waits                                timeouts
}

// restore replays an archive over the running database, the services that
// write stopped and the current database backed up first, and puts its
// .env back when asked.
func restore(s *session, arg string, opts restoreOptions) error {
	ctx := s.ctx()
	inst := s.inst
	state, err := inst.LoadState()
	if err != nil {
		return err
	}
	dir := inst.BackupDir()
	list, err := backup.List(dir)
	if err != nil {
		return err
	}
	ask := asker()
	path, err := chooseBackup(ctx, s, ask, dir, arg, opts.latest, list)
	if err != nil {
		return err
	}
	// The archive picked from the list is described as the answer to it;
	// one the command line chose is described as progress, which --quiet
	// leaves to the log.
	describe := s.detailf
	if arg == "" && !opts.latest {
		describe = s.sayf
	}
	meta, archivedKVS, err := describeBackup(describe, path)
	if err != nil {
		return err
	}
	site := inst.Domain()
	other := meta.Domain != "" && site != "" && !strings.EqualFold(meta.Domain, site)
	if other && !opts.otherSite {
		return fmt.Errorf("%s is an archive of %s, and this site is %s: its database holds the settings and the server paths of the other site; pass --other-site to restore it here all the same; nothing was changed", filepath.Base(path), meta.Domain, site)
	}
	if site == "" {
		site = orUnknown(meta.Domain)
	}
	if other {
		s.sayf("Warning:     this archive comes from %s, another site than %s (--other-site)", meta.Domain, site)
	}
	if state != nil && meta.Version != "" && meta.Version != state.Current {
		s.sayf("Warning:     this archive comes from stack %s, and the stack runs %s", meta.Version, state.Label(state.Current))
	}
	runningKVS := inst.KVSVersion()
	if archivedKVS != "" && runningKVS != "" && archivedKVS != runningKVS {
		s.sayf("Warning:     this archive holds the database of KVS %s, and the site runs KVS %s, whose files stay as they are", archivedKVS, runningKVS)
	}
	// With --env, the .env of the archive is read and the directory it goes
	// to is checked while nothing has changed: a .env that cannot be written
	// once the database is replayed leaves the restore part way.
	if opts.withEnv {
		if err := checkEnv(inst, path); err != nil {
			return fmt.Errorf("%w; nothing was changed", err)
		}
	}
	question := restoreQuestion(site, path, meta, other, upgrade.KVSNote(archivedKVS, runningKVS), opts.withEnv)
	s.log.Printf("question: %s", question)
	if !ask.Confirm(ctx, question) {
		s.log.Printf("answer: no")
		return errors.New("restore cancelled, nothing was changed")
	}
	s.log.Printf("answer: yes")
	runner, err := newRunner(inst, "")
	if err != nil {
		return err
	}
	defer runner.Docker.Close()
	if err := s.engineReady(runner.Docker, "restore interrupted, nothing was changed"); err != nil {
		return err
	}
	runner.Opts.Yes, runner.Opts.NoBackup, runner.Opts.LogPath = true, opts.noBackup, s.log.Path()
	opts.waits.set(&runner.Opts)
	runner.Reporter = &sayer{s: s}
	start := time.Now()
	if err := runner.Restore(ctx, state, path, opts.withEnv, func() { s.guard.protect("restore") }); err != nil {
		return err
	}
	stack := ""
	if meta.Version != "" {
		stack = fmt.Sprintf(" (stack %s)", meta.Version)
	}
	s.sayf("%s restored from %s%s in %s", site, filepath.Base(path), stack, time.Since(start).Round(time.Second))
	return nil
}

// restoreQuestion is what the operator agrees to: the site whose database is
// replaced, the archive with where it comes from when that is another site
// and the KVS its database belongs to, and that the site is down meanwhile.
func restoreQuestion(site, path string, meta *backup.Meta, other bool, kvs string, withEnv bool) string {
	var about []string
	if other {
		about = append(about, "an archive of "+meta.Domain)
	}
	if kvs != "" {
		about = append(about, kvs)
	}
	q := fmt.Sprintf("Restore the database of %s from %s", site, filepath.Base(path))
	if len(about) > 0 {
		q += " (" + strings.Join(about, "; ") + ")"
	}
	if withEnv {
		q += ", and its .env"
	}
	return q + "? The current data will be replaced, and the site is down until the replay is over"
}

// sayer prints the events of a restore as the lines of the command: a step
// as it begins, then what it logs and how it ended, indented. They are the
// progress of the restore, which --quiet leaves to the log, but for the
// notices: what became of .env, and what is left to run about it.
type sayer struct{ s *session }

func (p *sayer) Event(e upgrade.Event) {
	switch {
	case e.Kind == upgrade.KindLog && e.Notice:
		p.s.say("  " + e.Message)
	case e.Kind == upgrade.KindStepStart:
		p.s.detail(e.Message + ".")
	case e.Kind == upgrade.KindLog, e.Kind == upgrade.KindStepDone:
		p.s.detail("  " + e.Message)
	}
}

// Confirm is never asked: restore asks its question before the run.
func (p *sayer) Confirm(context.Context, string) bool { return false }

// checkEnv builds the .env the restore leaves, the one of the archive with
// the live values kvsctl keeps, and makes sure docker compose reads it and
// the directory of .env takes the temporary file ReplaceEnv writes there
// before it renames it over the live one.
func checkEnv(inst *instance.Instance, path string) error {
	archived, err := backup.ArchivedEnv(path)
	if err != nil {
		return err
	}
	live, err := os.ReadFile(inst.EnvPath)
	if err != nil {
		return err
	}
	merged, _, err := upgrade.MergeArchivedEnv(archived, live)
	if err != nil {
		return fmt.Errorf("the .env of %s cannot be put back: %w", filepath.Base(path), err)
	}
	if err := inst.CheckEnv(merged); err != nil {
		return fmt.Errorf("the .env of %s cannot be put back: %w", filepath.Base(path), err)
	}
	probe, err := os.CreateTemp(inst.DockerDir, "."+filepath.Base(inst.EnvPath)+".kvsctl*")
	if err != nil {
		return fmt.Errorf("%s cannot be replaced: %w", inst.EnvPath, err)
	}
	probe.Close()
	if err := os.Remove(probe.Name()); err != nil {
		return fmt.Errorf("%s cannot be replaced: %w", inst.EnvPath, err)
	}
	return nil
}

// asker asks the questions of a command without a screen, on the terminal
// when there is one; without one it answers no, and --yes answers yes.
func asker() *ui.Plain {
	var in io.Reader
	if interactive() {
		in = os.Stdin
	}
	return ui.NewPlain(os.Stdout, in, flagYes)
}

// chooseBackup picks the archive to replay: the argument, the newest one,
// or the answer to the list.
func chooseBackup(ctx context.Context, s *session, ask *ui.Plain, dir, arg string, latest bool, list []backup.Info) (string, error) {
	if arg != "" {
		return resolveBackup(dir, arg, list)
	}
	if len(list) == 0 {
		return "", fmt.Errorf("no backup in %s (kvsctl backup takes one)", dir)
	}
	if latest {
		return list[0].Path, nil
	}
	if ask.In == nil {
		return "", fmt.Errorf("name the backup to restore, or pass --latest (%d in %s)", len(list), dir)
	}
	s.sayf("Backups in %s:", dir)
	for i, b := range list {
		s.say(" " + formatBackupLine(i+1, b))
	}
	answer, err := ask.Line(ctx, fmt.Sprintf("Which backup? [1-%d] ", len(list)))
	if err != nil {
		return "", fmt.Errorf("no backup chosen: %w", err)
	}
	s.log.Printf("backup chosen: %s", answer)
	n, err := strconv.Atoi(strings.TrimSpace(answer))
	if err != nil || n < 1 || n > len(list) {
		return "", fmt.Errorf("%q is not one of the %d backups listed", strings.TrimSpace(answer), len(list))
	}
	return list[n-1].Path, nil
}

// resolveBackup turns an argument into a path: the name of a backup of
// the directory, or a file anywhere on disk.
func resolveBackup(dir, arg string, list []backup.Info) (string, error) {
	for _, b := range list {
		if b.Name == arg || b.Path == arg {
			return b.Path, nil
		}
	}
	candidate := arg
	if !filepath.IsAbs(candidate) && !strings.ContainsRune(candidate, filepath.Separator) {
		candidate = filepath.Join(dir, arg)
	}
	if info, err := os.Stat(candidate); err == nil && !info.IsDir() {
		return candidate, nil
	}
	return "", fmt.Errorf("no backup named %s in %s", arg, dir)
}

// formatBackupLine is one line of the picker.
func formatBackupLine(n int, b backup.Info) string {
	return fmt.Sprintf("%d) %-40s   %s UTC   %8s   %s", n, b.Name, b.Date.UTC().Format("2006-01-02 15:04"), upgrade.HumanBytes(b.Size), b.Version)
}

// describeBackup prints what the archive holds, from its backup.json, with
// printf, and returns it with the KVS version the archive records, "" when
// it records none.
func describeBackup(printf func(format string, args ...any), path string) (*backup.Meta, string, error) {
	meta, members, err := backup.Describe(path)
	if err != nil {
		return nil, "", fmt.Errorf("%s: %w", path, err)
	}
	size := int64(0)
	if info, err := os.Stat(path); err == nil {
		size = info.Size()
	}
	kvs := meta.KVSVersion
	printf("Archive:     %s (%s)", filepath.Base(path), upgrade.HumanBytes(size))
	printf("Taken:       %s UTC from %s, stack %s, KVS %s, by kvsctl %s", meta.Date.UTC().Format("2006-01-02 15:04"), orUnknown(meta.Domain), orUnknown(meta.Version), orUnknown(kvs), orUnknown(meta.Tool))
	printf("Database:    %s dumped, %s compressed", upgrade.HumanBytes(meta.DumpBytes), upgrade.HumanBytes(meta.CompressedBytes))
	printf("Holds:       %s", strings.Join(members, ", "))
	return meta, kvs, nil
}

func orUnknown(s string) string {
	if s == "" {
		return "unknown"
	}
	return s
}

// interactive reports whether kvsctl can ask a question here.
func interactive() bool { return ui.IsTerminal(os.Stdin) && ui.IsTerminal(os.Stdout) }
