// Package commands wires the cobra command tree.
//
// Persistent flags:
//
//	--config-dir <path>  Override ~/.gamechanger for tests / smoke runs.
//	                     Also honored via $GAMECHANGER_HOME.
//	--format <mode>      table | json | markdown. Default: table.
//	                     Currently only honored by refresh; the brief and
//	                     analytics commands ship in a later phase.
package commands

import (
	"context"
	"errors"
	"fmt"
	"io"
	"os"
	"path/filepath"

	"github.com/spf13/cobra"

	"github.com/joshrpowell/gamechanger-cli/internal/config"
	"github.com/joshrpowell/gamechanger-cli/internal/gcerr"
)

// rootOpts is set from persistent flags before any subcommand runs.
type rootOpts struct {
	configDir string
	format    string
}

// NewRoot builds the root cobra command. stdout/stderr are passed in so
// tests can capture output without touching os.Stdout.
func NewRoot(stdout, stderr io.Writer) *cobra.Command {
	opts := &rootOpts{}
	root := &cobra.Command{
		Use:           "gamechanger",
		Short:         "Gamechanger baseball CLI",
		SilenceUsage:  true,
		SilenceErrors: true,
	}
	root.SetOut(stdout)
	root.SetErr(stderr)

	root.PersistentFlags().StringVar(&opts.configDir, "config-dir", "",
		"Override ~/.gamechanger (also honored via $GAMECHANGER_HOME)")
	root.PersistentFlags().StringVar(&opts.format, "format", "table",
		"Output format: table | json | markdown")

	root.AddCommand(newVersionCmd())
	root.AddCommand(newSetupCmd(opts))
	root.AddCommand(newRefreshCmd(opts))
	root.AddCommand(newAuthCmd(opts))
	root.AddCommand(newVerifyCmd(opts))
	root.AddCommand(newScoutCmd(opts))
	return root
}

// loadConfig honors --config-dir, then $GAMECHANGER_HOME, then the home
// directory default.
func (o *rootOpts) loadConfig() (*config.Config, error) {
	if dir := resolveConfigDir(o.configDir); dir != "" {
		return config.LoadFrom(dir)
	}
	return config.Load()
}

func resolveConfigDir(flagValue string) string {
	if flagValue != "" {
		return flagValue
	}
	if env := os.Getenv("GAMECHANGER_HOME"); env != "" {
		return env
	}
	return ""
}

// configDirOrDefault returns the resolved config dir, computing the default
// (~/.gamechanger) when neither flag nor env is set.
func (o *rootOpts) configDirOrDefault() (string, error) {
	if d := resolveConfigDir(o.configDir); d != "" {
		return d, nil
	}
	home, err := os.UserHomeDir()
	if err != nil {
		return "", gcerr.Configf("locate home directory: %v", err)
	}
	return filepath.Join(home, ".gamechanger"), nil
}

// Execute is the package entry point used by cmd/gamechanger/main.go.
//
// A *parityExit error carrying an empty message signals "verdict already
// printed to stdout" — we suppress the `gamechanger:` prefix so verify's
// human/JSON output stays clean. Errors with a non-empty message still get
// the prefix (preserves behavior for setup, refresh, auth).
func Execute(ctx context.Context, args []string, stdout, stderr io.Writer) int {
	root := NewRoot(stdout, stderr)
	root.SetArgs(args)
	if err := root.ExecuteContext(ctx); err != nil {
		if msg := err.Error(); msg != "" {
			fmt.Fprintln(stderr, "gamechanger:", msg)
		}
		return exitCodeFor(err)
	}
	return 0
}

// exitCodeFor maps a sentinel error category to a stable POSIX-ish exit
// code, mirroring the Ruby Commands::Base rescue chain. *parityExit takes
// precedence — its Code() carries the typed verify-parity exit code.
func exitCodeFor(err error) int {
	var pex *parityExit
	if errors.As(err, &pex) {
		return pex.Code()
	}
	var sex *scoutExit
	if errors.As(err, &sex) {
		return sex.Code()
	}
	switch {
	case errors.Is(err, gcerr.ErrAuth):
		return 2
	case errors.Is(err, gcerr.ErrAuthInsufficient):
		// Distinct from ErrAuth — token is valid, permissions are not.
		// Mapped separately so users see "check team access" not
		// "re-authenticate."
		return 5
	case errors.Is(err, gcerr.ErrNetwork):
		return 3
	case errors.Is(err, gcerr.ErrAPIShape):
		return 3
	case errors.Is(err, gcerr.ErrConfig):
		return 4
	case errors.Is(err, gcerr.ErrStorage):
		return 1
	default:
		return 1
	}
}
