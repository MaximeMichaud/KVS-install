package main

import "github.com/spf13/cobra"

// extraCommands collects the commands defined in their own files of this
// package (restore, history, ...), each appended from an init function, so
// adding a command never touches main.go.
var extraCommands []*cobra.Command

// register adds a command to the root command at startup.
func register(cmd *cobra.Command) { extraCommands = append(extraCommands, cmd) }
