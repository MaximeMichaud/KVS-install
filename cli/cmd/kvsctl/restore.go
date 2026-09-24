package main

import (
	"bufio"
	"errors"
	"fmt"
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

func init() { register(restoreCmd()) }

func restoreCmd() *cobra.Command {
	var latest, noBackup, withEnv bool
	cmd := &cobra.Command{
		Use:   "restore [backup]",
		Short: "Replay the database of a backup over the running stack",
		Long: "Replay the database of a backup over the running stack. Without an\n" +
			"argument the backups of <root>/backups are listed and the one to\n" +
			"replay is asked for; a backup of the current database is taken first,\n" +
			"so a restore is never the last word.",
		Args: cobra.MaximumNArgs(1),
		RunE: func(cmd *cobra.Command, args []string) error {
			ctx, cancel := signalContext()
			defer cancel()
			inst, err := instance.Detect(flagRoot)
			if err != nil {
				return err
			}
			unlock, err := inst.Lock("restore")
			if err != nil {
				return err
			}
			defer unlock()
			state, err := inst.LoadState()
			if err != nil {
				return err
			}
			dir := inst.BackupDir()
			list, err := backup.List(dir)
			if err != nil {
				return err
			}
			arg := ""
			if len(args) == 1 {
				arg = args[0]
			}
			path, err := chooseBackup(dir, arg, latest, list)
			if err != nil {
				return err
			}
			meta, domain, err := describeBackup(path, inst.Domain())
			if err != nil {
				return err
			}
			if !promptYes(fmt.Sprintf("Restore the database of %s from %s? The current data will be replaced", domain, filepath.Base(path))) {
				return errors.New("restore cancelled")
			}
			mariadb := inst.ContainerPrefix() + "-mariadb"
			if !noBackup {
				version := "unknown"
				if state != nil && state.Current != "" {
					version = state.Current
				}
				fmt.Println("Backing up the current database first.")
				result, err := backup.Create(ctx, dir, version, mariadb, inst.EnvPath, filepath.Join(inst.StateDir(), "state.json"), func(msg string) { fmt.Println("  " + msg) })
				if err != nil {
					return fmt.Errorf("backup before the restore: %w", err)
				}
				fmt.Printf("  %s (%s, %s)\n", result.Path, upgrade.HumanBytes(result.Size), result.Duration.Round(time.Second))
			}
			fmt.Printf("Restoring the database from %s.\n", filepath.Base(path))
			if err := backup.RestoreDatabase(ctx, path, mariadb); err != nil {
				return err
			}
			if withEnv {
				if err := backup.RestoreEnv(ctx, path, inst.EnvPath); err != nil {
					return err
				}
				fmt.Printf("%s comes from the archive; run 'docker compose up -d' in %s for the containers to read it\n", inst.EnvPath, inst.DockerDir)
			}
			if meta != nil && meta.Version != "" {
				fmt.Printf("%s restored from %s (stack %s)\n", domain, filepath.Base(path), meta.Version)
				return nil
			}
			fmt.Printf("%s restored from %s\n", domain, filepath.Base(path))
			return nil
		},
	}
	cmd.Flags().BoolVar(&latest, "latest", false, "restore the newest backup without asking which one")
	cmd.Flags().BoolVar(&noBackup, "no-backup", false, "do not back up the current database before replacing it")
	cmd.Flags().BoolVar(&withEnv, "env", false, "also write the .env the archive carries over the live one")
	return cmd
}

// chooseBackup picks the archive to replay: the argument, the newest one,
// or the answer to the list.
func chooseBackup(dir, arg string, latest bool, list []backup.Info) (string, error) {
	if arg != "" {
		return resolveBackup(dir, arg, list)
	}
	if len(list) == 0 {
		return "", fmt.Errorf("no backup in %s (kvsctl backup takes one)", dir)
	}
	if latest {
		return list[0].Path, nil
	}
	if !interactive() {
		return "", fmt.Errorf("name the backup to restore, or pass --latest (%d in %s)", len(list), dir)
	}
	fmt.Printf("Backups in %s:\n", dir)
	for i, b := range list {
		fmt.Println(" " + formatBackupLine(i+1, b))
	}
	line, err := promptLine(fmt.Sprintf("Which backup? [1-%d] ", len(list)))
	if err != nil {
		return "", err
	}
	n, err := strconv.Atoi(line)
	if err != nil || n < 1 || n > len(list) {
		return "", fmt.Errorf("%q is not one of the %d backups listed", line, len(list))
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

// describeBackup prints what the archive holds, from its backup.json, and
// answers which site it belongs to.
func describeBackup(path, fallbackDomain string) (*backup.Meta, string, error) {
	meta, members, err := backup.Describe(path)
	if err != nil {
		return nil, "", fmt.Errorf("%s: %w", path, err)
	}
	size := int64(0)
	if info, err := os.Stat(path); err == nil {
		size = info.Size()
	}
	domain := fallbackDomain
	fmt.Printf("Archive:     %s (%s)\n", filepath.Base(path), upgrade.HumanBytes(size))
	if meta == nil {
		fmt.Println("Taken:       unknown, the archive carries no metadata (proof of concept format)")
	} else {
		if meta.Domain != "" {
			domain = meta.Domain
		}
		fmt.Printf("Taken:       %s UTC from %s, stack %s, by kvsctl %s\n", meta.Date.UTC().Format("2006-01-02 15:04"), orUnknown(meta.Domain), orUnknown(meta.Version), orUnknown(meta.Tool))
		fmt.Printf("Database:    %s dumped, %s compressed\n", upgrade.HumanBytes(meta.DumpBytes), upgrade.HumanBytes(meta.CompressedBytes))
	}
	fmt.Printf("Holds:       %s\n", strings.Join(members, ", "))
	return meta, domain, nil
}

func orUnknown(s string) string {
	if s == "" {
		return "unknown"
	}
	return s
}

// interactive reports whether kvsctl can ask a question here.
func interactive() bool { return ui.IsTerminal(os.Stdin) && ui.IsTerminal(os.Stdout) }

// stdinLines is kept between questions so a line typed ahead is never
// dropped by a second reader.
var stdinLines *bufio.Reader

// promptLine asks one line on the terminal.
func promptLine(prompt string) (string, error) {
	if !interactive() {
		return "", errors.New("no terminal to ask on")
	}
	if stdinLines == nil {
		stdinLines = bufio.NewReader(os.Stdin)
	}
	fmt.Print(prompt)
	line, err := stdinLines.ReadString('\n')
	if err != nil {
		return "", err
	}
	return strings.TrimSpace(line), nil
}

// promptYes asks a yes or no question; --yes answers it, and a run
// without a terminal answers no rather than waiting for nobody.
func promptYes(question string) bool {
	if flagYes {
		return true
	}
	if !interactive() {
		fmt.Printf("%s [y/N] no terminal: pass --yes\n", question)
		return false
	}
	line, err := promptLine(question + " [y/N] ")
	if err != nil {
		return false
	}
	answer := strings.ToLower(line)
	return answer == "y" || answer == "yes"
}
