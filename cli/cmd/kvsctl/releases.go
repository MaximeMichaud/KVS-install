package main

import (
	"encoding/json"
	"fmt"
	"os"

	"github.com/spf13/cobra"

	"github.com/MaximeMichaud/KVS-install/cli/internal/instance"
	"github.com/MaximeMichaud/KVS-install/cli/internal/manifest"
)

func init() { register(releasesCmd()) }

func releasesCmd() *cobra.Command {
	var asJSON bool
	cmd := &cobra.Command{
		Use:   "releases",
		Short: "List the releases the signed manifest offers",
		Args:  cobra.NoArgs,
		RunE: func(cmd *cobra.Command, args []string) error {
			keys, err := publicKeys()
			if err != nil {
				return err
			}
			doc, err := manifest.Fetch(manifestURL())
			if err != nil {
				return err
			}
			if err := doc.VerifyAny(keys); err != nil {
				return err
			}
			if asJSON {
				encoder := json.NewEncoder(os.Stdout)
				encoder.SetIndent("", "  ")
				return encoder.Encode(doc.Manifest.Releases)
			}
			installed := installedVersion()
			fmt.Printf("%d releases, channel %s, updated %s\n", len(doc.Manifest.Releases), doc.Manifest.Channel, doc.Manifest.Updated)
			fmt.Printf("  %-9s %-10s %-5s %-10s %-9s %s\n", "VERSION", "DATE", "PHP", "MIN FROM", "DATABASE", "NOTES")
			for _, line := range releaseLines(doc.Manifest, installed) {
				fmt.Println(line)
			}
			if installed != "" {
				fmt.Println("* the installed version")
			}
			return nil
		},
	}
	cmd.Flags().BoolVar(&asJSON, "json", false, "print the releases as JSON")
	return cmd
}

// installedVersion is the stack version the state records, or "" when
// there is no stack here or it was never adopted. Listing the releases
// must work from anywhere, so a missing installation is not an error.
func installedVersion() string {
	inst, err := instance.Detect(flagRoot)
	if err != nil {
		return ""
	}
	state, err := inst.LoadState()
	if err != nil || state == nil {
		return ""
	}
	return state.Current
}

// releaseLines renders one line per release, newest first, marking the
// installed one and naming the newest.
func releaseLines(m *manifest.Manifest, installed string) []string {
	lines := make([]string, 0, len(m.Releases))
	for i, r := range m.Releases {
		mark := " "
		if r.Version == installed {
			mark = "*"
		}
		notes := r.Notes
		if i == 0 {
			if notes == "" {
				notes = "latest"
			} else {
				notes = "latest, " + notes
			}
		}
		lines = append(lines, fmt.Sprintf("%s %-9s %-10s %-5s %-10s %-9s %s",
			mark, r.Version, r.Date, orDash(r.Requires.PHP), orDash(r.Requires.MinFrom), orDash(r.Database), notes))
	}
	return lines
}

func orDash(s string) string {
	if s == "" {
		return "-"
	}
	return s
}
