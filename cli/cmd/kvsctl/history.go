package main

import (
	"encoding/json"
	"fmt"
	"os"
	"strings"

	"github.com/spf13/cobra"

	"github.com/MaximeMichaud/KVS-install/cli/internal/instance"
)

func init() { register(historyCmd()) }

func historyCmd() *cobra.Command {
	var asJSON bool
	cmd := &cobra.Command{
		Use:   "history",
		Short: "Print what kvsctl did to this stack, oldest first",
		Args:  cobra.NoArgs,
		RunE: func(cmd *cobra.Command, args []string) error {
			inst, err := instance.Detect(flagRoot)
			if err != nil {
				return err
			}
			state, err := inst.LoadState()
			if err != nil {
				return err
			}
			var entries []instance.Entry
			if state != nil {
				entries = state.History
			}
			if asJSON {
				encoder := json.NewEncoder(os.Stdout)
				encoder.SetIndent("", "  ")
				if entries == nil {
					entries = []instance.Entry{}
				}
				return encoder.Encode(entries)
			}
			if len(entries) == 0 {
				fmt.Println("no history")
				return nil
			}
			for _, line := range historyLines(entries) {
				fmt.Println(line)
			}
			return nil
		},
	}
	cmd.Flags().BoolVar(&asJSON, "json", false, "print the entries as JSON")
	return cmd
}

// historyLines renders one line per entry: when, what, which version and
// the note the action left, in UTC so two machines read the same log.
func historyLines(entries []instance.Entry) []string {
	lines := make([]string, 0, len(entries))
	for _, e := range entries {
		line := fmt.Sprintf("%s  %-10s  %-10s", e.Date.UTC().Format("2006-01-02 15:04"), e.Action, e.Version)
		if e.Note != "" {
			line += "  " + e.Note
		}
		lines = append(lines, strings.TrimRight(line, " "))
	}
	return lines
}
