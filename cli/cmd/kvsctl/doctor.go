package main

import (
	"encoding/json"
	"errors"
	"fmt"
	"strings"
	"time"
	"unicode"

	"github.com/spf13/cobra"

	"github.com/MaximeMichaud/KVS-install/cli/internal/doctor"
)

func init() { register(doctorCmd) }

func doctorCmd() *cobra.Command {
	var opts doctor.Options
	var asJSON, verbose, list bool
	cmd := &cobra.Command{
		Use:   "doctor",
		Short: "Diagnose the local stack without changing it or checking for releases",
		Long: "Check the installation, Compose configuration, services, PHP, database,\n" +
			"cache, search, cron, storage, backups and local HTTPS endpoint. Each check\n" +
			"reports OK, WARN, FAIL or SKIP and an action when useful. Checks continue\n" +
			"after a failure; unavailable prerequisites are named. No release manifest\n" +
			"or update reminder is read, and no repairs are applied. --network opts in\n" +
			"to DNS, the DNS-resolved site and configured image registry checks.\n\n" +
			"Exit 0 means no failed check and a complete diagnostic; warnings alone\n" +
			"exit 0 unless --strict. Failed or incomplete checks exit 1; bad flags\n" +
			"exit 2. Disabled optional services and network checks are normal skips.\n" +
			"--only also runs the selected checks' prerequisites. --timeout applies\n" +
			"to each check, not the whole command. --quiet shows problems only.",
		Example: "  kvsctl doctor\n  kvsctl doctor --root /srv/kvs --verbose\n  kvsctl doctor --only database,storage\n  kvsctl doctor --json --strict\n  kvsctl doctor --network --timeout 15s",
		Args:    cobra.NoArgs,
		RunE: func(cmd *cobra.Command, args []string) error {
			opts.Root = flagRoot
			if err := doctor.Validate(opts); err != nil {
				return usageError{err}
			}
			if list {
				if asJSON {
					return json.NewEncoder(stdout).Encode(doctor.Catalog())
				}
				for _, check := range doctor.Catalog() {
					_, _ = fmt.Fprintf(stdout, "%-23s %-10s %s\n", check.ID, check.Group, check.Description)
				}
				return nil
			}
			ctx, cancel := signalContext()
			defer cancel()
			report := doctor.Run(ctx, opts)
			if asJSON {
				encoder := json.NewEncoder(stdout)
				encoder.SetIndent("", "  ")
				if err := encoder.Encode(report); err != nil {
					return err
				}
			} else {
				printDoctor(report, verbose, flagQuiet)
			}
			if report.ExitCode != 0 {
				return errors.New("doctor found failed checks, an incomplete diagnostic, or warnings under --strict")
			}
			return nil
		},
	}
	cmd.Flags().BoolVar(&asJSON, "json", false, "print a structured report with stable check IDs")
	cmd.Flags().BoolVarP(&verbose, "verbose", "v", false, "include evidence for successful checks")
	cmd.Flags().BoolVar(&list, "list-checks", false, "list check IDs and groups without probing the installation")
	cmd.Flags().StringSliceVar(&opts.Only, "only", nil, "run selected check IDs or groups, and their prerequisites (comma separated)")
	cmd.Flags().BoolVar(&opts.Network, "network", false, "also check DNS, the DNS-resolved site and configured image registries")
	cmd.Flags().BoolVar(&opts.Strict, "strict", false, "exit 1 for warnings as well as failures or incomplete checks")
	cmd.Flags().DurationVar(&opts.Timeout, "timeout", 10*time.Second, "maximum time for each check")
	_ = cmd.RegisterFlagCompletionFunc("only", func(*cobra.Command, []string, string) ([]string, cobra.ShellCompDirective) {
		var names []string
		for _, c := range doctor.Catalog() {
			names = append(names, c.ID+"\t"+c.Description)
		}
		return names, cobra.ShellCompDirectiveNoFileComp
	})
	return cmd
}

func doctorText(value string) string {
	return strings.Map(func(r rune) rune {
		if unicode.IsControl(r) {
			return ' '
		}
		return r
	}, value)
}

func printDoctor(report doctor.Report, verbose, quiet bool) {
	if !quiet {
		_, _ = fmt.Fprintf(stdout, "KVS Doctor\nRoot: %s\n", doctorText(report.Root))
		if report.Site != "" {
			_, _ = fmt.Fprintf(stdout, "Site: %s\n", report.Site)
		}
		_, _ = fmt.Fprintln(stdout)
	}
	for _, result := range report.Checks {
		problem := result.Status == doctor.Fail || result.Status == doctor.Warn || result.Incomplete
		if quiet && !problem {
			continue
		}
		_, _ = fmt.Fprintf(stdout, "[%-4s] %-23s %s\n", strings.ToUpper(result.Status), result.ID, doctorText(result.Message))
		if verbose || problem {
			for _, detail := range result.Details {
				_, _ = fmt.Fprintf(stdout, "       %s\n", doctorText(detail))
			}
		}
		if result.Next != "" {
			_, _ = fmt.Fprintf(stdout, "       Next: %s\n", doctorText(result.Next))
		}
	}
	if !quiet {
		s := report.Summary
		_, _ = fmt.Fprintf(stdout, "\n%d passed, %d warning(s), %d failed, %d skipped.\n", s.Passed, s.Warnings, s.Failed, s.Skipped)
		verdict := "no problems detected by the completed checks"
		if s.Warnings > 0 || s.Failed > 0 || !report.Complete {
			verdict = "attention required"
		}
		_, _ = fmt.Fprintf(stdout, "Result: %s (exit %d)\n", verdict, report.ExitCode)
	}
}
