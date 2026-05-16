package commands

import (
	"context"
	"errors"
	"fmt"
	"io"
	"os"

	isatty "github.com/mattn/go-isatty"
	"github.com/spf13/cobra"

	"github.com/joshrpowell/gamechanger-cli/internal/client"
	"github.com/joshrpowell/gamechanger-cli/internal/format"
	"github.com/joshrpowell/gamechanger-cli/internal/gcerr"
	"github.com/joshrpowell/gamechanger-cli/internal/scout"
	"github.com/joshrpowell/gamechanger-cli/internal/store"
)

// Scout exit codes (U7). The parityExit pattern from verify.go gives us
// distinct codes so AI-loop / scripting consumers can branch on failure mode.
const (
	ExitScoutPass             = 0
	ExitScoutTeamNotFound     = 10
	ExitScoutAuthExpired      = 20
	ExitScoutAuthInsufficient = 21
	ExitScoutNetworkError     = 30
	ExitScoutCacheEmpty       = 40
)

// scoutExit signals a scout-specific exit code to root.Execute. Empty msg →
// no "gamechanger:" stderr prefix (renderer already printed to stdout).
type scoutExit struct {
	code int
	msg  string
}

func (e *scoutExit) Error() string { return e.msg }
func (e *scoutExit) Code() int     { return e.code }

type scoutOpts struct {
	format     string
	refresh    bool
	limitGames int
	teamUUID   string // override; default = first team from /me/teams

	// Test injection points.
	detectTTY   func(w io.Writer) bool
	newClient   func(*scoutOpts, *rootOpts) (scout.ScoutClient, error)
	resolveTeam func(ctx context.Context, cli scout.ScoutClient, override string) (string, error)
}

// defaultDetectTTY returns true when w is a *os.File pointing at a terminal.
// io.Writer concrete types other than *os.File (e.g., bytes.Buffer in tests)
// always return false — render plain output, no ANSI.
func defaultDetectTTY(w io.Writer) bool {
	f, ok := w.(*os.File)
	if !ok {
		return false
	}
	return isatty.IsTerminal(f.Fd())
}

func newScoutCmd(opts *rootOpts) *cobra.Command {
	so := &scoutOpts{
		detectTTY:   defaultDetectTTY,
		newClient:   defaultScoutClient,
		resolveTeam: defaultResolveTeam,
	}
	cmd := &cobra.Command{
		Use:   "scout <opponent>",
		Short: "Matchup-history scout — prior games vs an opponent (Phase 1a)",
		Long: `Show your matchup history against an opponent — every prior game with
score, W/L, and home/away.

Argument can be the opponent's name (case-insensitive) or their GameChanger
team UUID. First invocation against a fresh cache populates opposing-team
metadata; subsequent invocations within 24h reuse the cache.

Output is TTY-aware: colored/structured at a terminal, plain copy-paste-
friendly text when piped (cap 500 chars for messaging).`,
		Args: cobra.ExactArgs(1),
		RunE: func(cmd *cobra.Command, args []string) error {
			return runScout(cmd.Context(), cmd.OutOrStdout(), cmd.ErrOrStderr(), args[0], opts, so)
		},
	}
	cmd.Flags().StringVar(&so.format, "format", "human", "Output format: human | json")
	cmd.Flags().BoolVar(&so.refresh, "refresh", false, "Bypass the opposing-team cache and re-fetch")
	cmd.Flags().IntVar(&so.limitGames, "limit", 0, "Cap matchup history to last N games (0 = all)")
	cmd.Flags().StringVar(&so.teamUUID, "team", "", "Override the user's team UUID (default: first team from /me/teams)")
	return cmd
}

func runScout(ctx context.Context, stdout, stderr io.Writer, opponent string, ro *rootOpts, so *scoutOpts) error {
	cli, err := so.newClient(so, ro)
	if err != nil {
		return err
	}

	teamUUID, err := so.resolveTeam(ctx, cli, so.teamUUID)
	if err != nil {
		return classifyScoutCmdErr(err, opponent)
	}

	// Open the cache.db so the orchestrator can persist opposing-team metadata.
	dir, err := ro.configDirOrDefault()
	if err != nil {
		return err
	}
	cfg, _ := ro.loadConfig()
	season := 0
	if cfg != nil {
		season = cfg.Season
	}
	st, err := store.OpenAt(ctx, dir, season)
	if err != nil {
		return err
	}
	defer st.Close()

	history, err := scout.Scout(ctx, st, cli, teamUUID, opponent, scout.Options{
		Refresh:    so.refresh,
		LimitGames: so.limitGames,
	})
	if err != nil {
		return classifyScoutCmdErr(err, opponent)
	}

	isTTY := false
	if so.detectTTY != nil {
		isTTY = so.detectTTY(stdout)
	}
	if err := format.Scout(stdout, format.ScoutContext{History: history, IsTTY: isTTY}, so.format); err != nil {
		return &scoutExit{code: 1, msg: fmt.Sprintf("render: %v", err)}
	}
	return nil
}

// defaultScoutClient builds the production *client.Client wired against the
// user's config. ScoutClient is satisfied by *client.Client because both
// methods we added in U4 are on it.
func defaultScoutClient(_ *scoutOpts, ro *rootOpts) (scout.ScoutClient, error) {
	cfg, err := ro.loadConfig()
	if err != nil {
		return nil, err
	}
	if !cfg.Configured() && cfg.CachedToken() == "" {
		return nil, gcerr.Authf("not authenticated. Run `gamechanger auth import` first")
	}
	return client.New(cfg), nil
}

// defaultResolveTeam picks the user's team UUID. If --team was passed,
// honor it. Otherwise call /me/teams and pick the first non-archived team.
func defaultResolveTeam(ctx context.Context, cli scout.ScoutClient, override string) (string, error) {
	if override != "" {
		return override, nil
	}
	// ScoutClient doesn't expose /me/teams — fall back to the production
	// client.Teams() by type-asserting. Tests inject a resolveTeam that
	// returns directly so they don't hit this path.
	full, ok := cli.(interface {
		Teams(ctx context.Context) (any, error)
	})
	if !ok {
		return "", gcerr.Configf("scout: cannot resolve team without --team override (client lacks Teams())")
	}
	resp, err := full.Teams(ctx)
	if err != nil {
		return "", err
	}
	uuid, name := firstActiveTeamUUID(resp)
	if uuid == "" {
		return "", gcerr.Configf("scout: no active teams found via /me/teams — pass --team <uuid>")
	}
	_ = name // not currently surfaced; could log at higher verbosity
	return uuid, nil
}

// firstActiveTeamUUID walks the /me/teams response (bare array or wrapped
// shapes) and returns the first non-archived team's id + name.
func firstActiveTeamUUID(v any) (string, string) {
	var arr []any
	switch x := v.(type) {
	case []any:
		arr = x
	case map[string]any:
		// Defensive triple-shape per client convention.
		for _, key := range []string{"teams", "data"} {
			if a, ok := x[key].([]any); ok {
				arr = a
				break
			}
		}
	}
	for _, item := range arr {
		m, ok := item.(map[string]any)
		if !ok {
			continue
		}
		if archived, _ := m["archived"].(bool); archived {
			continue
		}
		id, _ := m["id"].(string)
		name, _ := m["name"].(string)
		if id != "" {
			return id, name
		}
	}
	return "", ""
}

// classifyScoutCmdErr maps domain errors to scoutExit codes with hint text.
func classifyScoutCmdErr(err error, opponent string) error {
	if err == nil {
		return nil
	}
	switch {
	case errors.Is(err, scout.ErrOpponentNotResolvable):
		return &scoutExit{
			code: ExitScoutTeamNotFound,
			msg:  fmt.Sprintf("opponent %q not found in your matchup history (slug, UUID, and name lookups all missed) — run `gamechanger refresh` or check the spelling", opponent),
		}
	case errors.Is(err, scout.ErrCacheEmpty):
		return &scoutExit{
			code: ExitScoutCacheEmpty,
			msg:  "no games in your team's history — run `gamechanger refresh` first to populate the cache",
		}
	case errors.Is(err, client.ErrTeamNotFound):
		return &scoutExit{
			code: ExitScoutTeamNotFound,
			msg:  "API returned 404 — team or opponent UUID may be wrong, or your account lacks access",
		}
	case errors.Is(err, gcerr.ErrAuth):
		return &scoutExit{
			code: ExitScoutAuthExpired,
			msg:  "authentication expired — run `gamechanger auth import` to refresh your token",
		}
	case errors.Is(err, gcerr.ErrAuthInsufficient):
		return &scoutExit{
			code: ExitScoutAuthInsufficient,
			msg:  "API denied access (403) — your account may lack scope for this team's data; re-authenticate or contact support",
		}
	case errors.Is(err, gcerr.ErrNetwork):
		return &scoutExit{
			code: ExitScoutNetworkError,
			msg:  fmt.Sprintf("network error: %v — check connectivity and retry", err),
		}
	}
	return err
}
