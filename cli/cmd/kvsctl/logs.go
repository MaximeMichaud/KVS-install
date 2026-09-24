package main

import (
	"fmt"
	"strconv"

	"github.com/spf13/cobra"

	"github.com/MaximeMichaud/KVS-install/cli/internal/dockerx"
	"github.com/MaximeMichaud/KVS-install/cli/internal/instance"
)

func init() { register(logsCmd()) }

func logsCmd() *cobra.Command {
	var tail int
	var follow bool
	cmd := &cobra.Command{
		Use:   "logs [service]",
		Short: "Show the logs of the stack, or of one service",
		Args:  cobra.MaximumNArgs(1),
		RunE: func(cmd *cobra.Command, args []string) error {
			ctx, cancel := signalContext()
			defer cancel()
			inst, err := instance.Detect(flagRoot)
			if err != nil {
				return err
			}
			err = dockerx.Compose(ctx, inst.DockerDir, func(line string) { fmt.Println(line) }, logsArgs(tail, follow, args)...)
			// Ctrl-C is how one leaves a follow, not a failure.
			if err != nil && ctx.Err() != nil {
				return nil
			}
			return err
		},
	}
	cmd.Flags().IntVar(&tail, "tail", 200, "how many lines of each service to show first")
	cmd.Flags().BoolVarP(&follow, "follow", "f", false, "keep printing new lines until Ctrl-C")
	return cmd
}

// logsArgs builds the compose command line.
func logsArgs(tail int, follow bool, services []string) []string {
	if tail < 0 {
		tail = 0
	}
	args := []string{"logs", "--no-color", "--tail", strconv.Itoa(tail)}
	if follow {
		args = append(args, "-f")
	}
	return append(args, services...)
}
