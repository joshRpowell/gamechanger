package commands

import (
	"encoding/json"
	"fmt"

	"github.com/spf13/cobra"

	"github.com/joshrpowell/gamechanger-cli/internal/client"
	"github.com/joshrpowell/gamechanger-cli/internal/gcerr"
	"github.com/joshrpowell/gamechanger-cli/internal/store"
	syncpkg "github.com/joshrpowell/gamechanger-cli/internal/sync"
)

func newRefreshCmd(opts *rootOpts) *cobra.Command {
	var refreshFormat string
	cmd := &cobra.Command{
		Use:   "refresh",
		Short: "Sync latest game data from Gamechanger",
		Args:  cobra.NoArgs,
		RunE: func(cmd *cobra.Command, _ []string) error {
			cfg, err := opts.loadConfig()
			if err != nil {
				return err
			}
			if !cfg.Configured() {
				return gcerr.Configf("not configured. Run `gamechanger setup` first")
			}

			dir, err := opts.configDirOrDefault()
			if err != nil {
				return err
			}
			st, err := store.OpenAt(cmd.Context(), dir, cfg.Season)
			if err != nil {
				return err
			}
			defer st.Close()

			cli := client.New(cfg)
			syncer := &syncpkg.Syncer{
				Config: cfg,
				Client: cli,
				Store:  st,
			}

			fmt.Fprintln(cmd.ErrOrStderr(), "Syncing games from Gamechanger...")
			result, err := syncer.Run(cmd.Context(), true)
			if err != nil {
				return err
			}

			return printRefreshResult(cmd, refreshFormat, result)
		},
	}
	cmd.Flags().StringVar(&refreshFormat, "format", "human",
		"Output format: human | json")
	return cmd
}

func printRefreshResult(cmd *cobra.Command, format string, result store.SyncResult) error {
	out := cmd.OutOrStdout()
	if format == "json" {
		return json.NewEncoder(out).Encode(result)
	}
	fmt.Fprintf(out, "%s, %s, %s updated.\n",
		pluralize(result.Games, "game"),
		pluralize(result.Outings, "outing"),
		pluralize(result.AtBats, "at-bat"),
	)
	return nil
}

func pluralize(n int, noun string) string {
	if n == 1 {
		return fmt.Sprintf("%d %s", n, noun)
	}
	return fmt.Sprintf("%d %ss", n, noun)
}
