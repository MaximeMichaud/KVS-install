package main

import (
	"encoding/json"
	"errors"
	"fmt"
	"slices"
	"sort"
	"strings"
	"time"

	"github.com/spf13/cobra"

	"github.com/MaximeMichaud/KVS-install/cli/internal/instance"
	"github.com/MaximeMichaud/KVS-install/cli/internal/manifest"
	"github.com/MaximeMichaud/KVS-install/cli/internal/semver"
)

func init() { register(releasesCmd) }

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
			ctx, cancel := signalContext()
			defer cancel()
			doc, err := manifest.FetchContext(ctx, manifestURL())
			if ctx.Err() != nil {
				return errors.New("interrupted")
			}
			if err != nil {
				return err
			}
			if err := doc.VerifyAny(keys); err != nil {
				return err
			}
			// A list the URL does not serve, a release candidate marked as
			// the latest release, is refused as check and upgrade refuse it.
			if err := doc.Manifest.CheckChannel(manifestURL()); err != nil {
				return err
			}
			if asJSON {
				encoder := json.NewEncoder(stdout)
				encoder.SetIndent("", "  ")
				return encoder.Encode(doc.Manifest.Releases)
			}
			installed := installedVersion()
			_, _ = fmt.Fprintf(stdout, "%d releases, channel %s, updated %s\n", len(doc.Manifest.Releases), doc.Manifest.Channel, doc.Manifest.Updated)
			for _, line := range releaseLines(doc.Manifest, installed) {
				_, _ = fmt.Fprintln(stdout, line)
			}
			if installed != "" {
				_, _ = fmt.Fprintln(stdout, "* the installed version")
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

// releaseColumns titles the columns of releaseLines.
var releaseColumns = []string{"VERSION", "DATE", "PHP", "MIN FROM", "DATABASE", "NOTES"}

// releaseLines renders the titles of the columns, then one line per
// release, newest first, marking the installed one and naming the latest
// stable release, which upgrade installs when no version is named, and
// each release candidate, which it installs only when it is. The header
// and the releases are laid out alike, every column but the notes as wide
// as its widest cell: a release candidate, or a release that publishes
// four PHP series, keeps every column under its title.
func releaseLines(m *manifest.Manifest, installed string) []string {
	rows := [][]string{releaseColumns}
	marks := []string{" "}
	latest := m.LatestStable()
	for i := range m.Releases {
		r := &m.Releases[i]
		mark := " "
		if r.Version == installed {
			mark = "*"
		}
		notes := r.Notes
		label := ""
		switch {
		case r == latest:
			label = "latest"
		case semver.IsPrerelease(r.Version):
			label = "release candidate"
		}
		if label != "" {
			if notes == "" {
				notes = label
			} else {
				notes = label + ", " + notes
			}
		}
		rows = append(rows, []string{r.Version, releaseDay(r.Date), phpSeries(r), orDash(r.Requires.MinFrom), orDash(r.Database), notes})
		marks = append(marks, mark)
	}
	widths := make([]int, len(releaseColumns)-1)
	for _, row := range rows {
		for c := range widths {
			widths[c] = max(widths[c], len(row[c]))
		}
	}
	lines := make([]string, 0, len(rows))
	for n, row := range rows {
		var b strings.Builder
		b.WriteString(marks[n])
		for c, cell := range row {
			if c < len(widths) {
				_, _ = fmt.Fprintf(&b, " %-*s", widths[c], cell)
			} else {
				b.WriteString(" " + cell)
			}
		}
		lines = append(lines, strings.TrimRight(b.String(), " "))
	}
	return lines
}

// releaseDay is the day, in UTC, of a release date. A release is dated by
// the time of its commit, to the second, which the guard of an adopted
// checkout needs and this table does not; a date that is no timestamp is
// shown as it is.
func releaseDay(date string) string {
	if t, err := time.Parse(time.RFC3339, date); err == nil {
		return t.UTC().Format("2006-01-02")
	}
	return date
}

// phpSeries lists every PHP series a release publishes images for, oldest
// first: the series its images vary by, else the ones its requirements
// list, else the single PHP it ships. The lowest series alone would read
// as the only one.
func phpSeries(r *manifest.Release) string {
	series := r.Series()
	if len(series) == 0 {
		series = slices.Clone(r.Requires.PHPSeries)
		sort.Slice(series, func(i, j int) bool { return manifest.LessSeries(series[i], series[j]) })
	}
	if len(series) == 0 && r.Requires.PHP != "" {
		series = []string{r.Requires.PHP}
	}
	if len(series) == 0 {
		return "-"
	}
	return strings.Join(series, ",")
}

func orDash(s string) string {
	if s == "" {
		return "-"
	}
	return s
}
