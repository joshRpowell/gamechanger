package commands

import (
	"fmt"

	"github.com/spf13/cobra"

	"github.com/joshrpowell/gamechanger-cli/internal/version"
)

func newVersionCmd() *cobra.Command {
	return &cobra.Command{
		Use:   "version",
		Short: "Print version",
		Args:  cobra.NoArgs,
		RunE: func(cmd *cobra.Command, _ []string) error {
			fmt.Fprintln(cmd.OutOrStdout(), "gamechanger", version.Version)
			return nil
		},
	}
}
