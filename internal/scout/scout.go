// Package scout orchestrates the matchup-history scouting workflow (U6, Fork A).
//
// Given an opponent (by name or UUID), Scout fetches the user's team's game
// history, resolves opponent name↔UUID via the cached opposing_teams table
// (refreshing from /opponent/{uuid} when missing or stale), and returns the
// games played against that opponent sorted DESC by date.
//
// See docs/research/gc-scout-api-notes.md for why this is matchup-history-
// shaped vs. roster-shaped: the web/desktop API doesn't expose opposing-team
// rosters.
package scout

import (
	"context"
	"errors"
	"sort"
	"strings"
	"time"

	"github.com/joshrpowell/gamechanger-cli/internal/client"
	"github.com/joshrpowell/gamechanger-cli/internal/gcerr"
	"github.com/joshrpowell/gamechanger-cli/internal/store"
)

// Sentinel errors. ErrOpponentNotResolvable is returned when the user's input
// (name or UUID) doesn't match any team in the matchup history — either an
// invalid name/UUID, or a team you've never played.
var (
	ErrOpponentNotResolvable = errors.New("scout: opponent not resolvable from cached opposing teams or game history")
	ErrCacheEmpty            = errors.New("scout: own team has no games in history yet — run `gamechanger refresh`")
)

// ScoutClient is the API surface the orchestrator needs. Defined as an
// interface so tests can inject mocks without spinning up httptest servers.
type ScoutClient interface {
	GameSummaries(ctx context.Context, teamUUID string) ([]client.GameSummary, error)
	OpponentDetail(ctx context.Context, teamUUID, opponentUUID string) (*client.OpponentDetail, error)
}

// MatchupGame is one row in a matchup history — the subset of GameSummary
// scout's output renderer cares about.
type MatchupGame struct {
	EventID       string // GameChanger event UUID (link to game detail if needed)
	Date          string // ISO date YYYY-MM-DD extracted from LastScoringUpdate
	HomeAway      string // "home" or "away"
	OwningScore   int
	OpponentScore int
	Outcome       string // "W", "L", or "T"
	GameStatus    string // "completed", "in_progress", "scheduled", etc.
}

// MatchupHistory is the orchestrator's return value.
type MatchupHistory struct {
	Opponent OpposingTeamRef
	Games    []MatchupGame
	CacheAge time.Duration // how stale the opposing_teams cache entry is for this opponent
}

// OpposingTeamRef is the minimum scout-renderer needs about the opponent.
type OpposingTeamRef struct {
	UUID string
	Name string
}

// Options tunes orchestrator behavior. Zero value works (24h cache, no refresh).
type Options struct {
	Refresh    bool          // force re-fetch of OpponentDetail entries
	CacheTTL   time.Duration // override default 24h
	Now        func() time.Time // injectable clock for tests
	LimitGames int           // 0 = all matchups; positive = cap last N (DESC)
}

const defaultCacheTTL = 24 * time.Hour

// Scout is the orchestrator entry point.
//
//   teamUUID    — the user's own team UUID (caller resolves from config / /me/teams)
//   opponentArg — opponent name (case-insensitive) OR opponent UUID
//
// Flow:
//   1. Fetch GameSummaries for teamUUID (single API call).
//   2. Build set of unique opponent_ids from results.
//   3. For each unknown / stale opponent_id, fetch OpponentDetail and upsert.
//   4. Resolve opponentArg against opposing_teams cache (UUID first, then name).
//   5. Filter games to target opponent_id, build MatchupGame list, sort DESC.
//   6. Return MatchupHistory (or ErrOpponentNotResolvable / ErrCacheEmpty).
func Scout(
	ctx context.Context,
	st *store.Store,
	cli ScoutClient,
	teamUUID, opponentArg string,
	opts Options,
) (*MatchupHistory, error) {
	if teamUUID == "" {
		return nil, gcerr.Configf("scout: teamUUID is required")
	}
	if opponentArg == "" {
		return nil, gcerr.Configf("scout: opponent is required")
	}
	now := opts.Now
	if now == nil {
		now = time.Now
	}
	ttl := opts.CacheTTL
	if ttl <= 0 {
		ttl = defaultCacheTTL
	}

	// 1. Fetch matchup history. One API call, returns ALL games.
	games, err := cli.GameSummaries(ctx, teamUUID)
	if err != nil {
		return nil, err
	}
	if len(games) == 0 {
		return nil, ErrCacheEmpty
	}

	// 2. Unique opponent_ids in the response.
	uniqueOpps := make(map[string]struct{}, 16)
	for _, g := range games {
		if g.GameStream.OpponentID != "" {
			uniqueOpps[g.GameStream.OpponentID] = struct{}{}
		}
	}

	// 3. For each opp_id, ensure cache is fresh.
	nowStr := now().UTC().Format(time.RFC3339)
	cutoff := now().Add(-ttl)
	for oppID := range uniqueOpps {
		cached, err := st.FindOpposingTeamByUUID(ctx, oppID)
		if err != nil {
			return nil, err
		}
		if cached != nil && !opts.Refresh && !isStale(cached.LastFetchedAt, cutoff) {
			continue
		}
		detail, err := cli.OpponentDetail(ctx, teamUUID, oppID)
		if err != nil {
			// Don't fail the whole scout on one opponent — log + continue would be
			// nicer, but for v1 propagate. The caller can retry --refresh.
			return nil, err
		}
		if err := st.UpsertOpposingTeam(ctx, store.OpposingTeam{
			TeamUUID:      oppID,
			TeamName:      detail.Name,
			LastFetchedAt: nowStr,
		}); err != nil {
			return nil, err
		}
	}

	// 4. Resolve opponentArg.
	target, err := resolveOpponent(ctx, st, opponentArg)
	if err != nil {
		return nil, err
	}
	if target == nil {
		return nil, ErrOpponentNotResolvable
	}

	// 5. Filter games to target opponent + assemble MatchupGames.
	matched := make([]MatchupGame, 0, 8)
	for _, g := range games {
		if g.GameStream.OpponentID != target.TeamUUID {
			continue
		}
		matched = append(matched, MatchupGame{
			EventID:       g.EventID,
			Date:          extractDate(g.LastScoringUpdate),
			HomeAway:      g.HomeAway,
			OwningScore:   g.OwningTeamScore,
			OpponentScore: g.OpponentTeamScore,
			Outcome:       outcome(g.OwningTeamScore, g.OpponentTeamScore, g.GameStatus),
			GameStatus:    g.GameStatus,
		})
	}
	sort.SliceStable(matched, func(i, j int) bool {
		return matched[i].Date > matched[j].Date // DESC: newest first
	})
	if opts.LimitGames > 0 && len(matched) > opts.LimitGames {
		matched = matched[:opts.LimitGames]
	}

	// 6. Compute cache age for the chosen opponent.
	var cacheAge time.Duration
	if t, err := time.Parse(time.RFC3339, target.LastFetchedAt); err == nil {
		cacheAge = now().Sub(t)
	}

	return &MatchupHistory{
		Opponent: OpposingTeamRef{UUID: target.TeamUUID, Name: target.TeamName},
		Games:    matched,
		CacheAge: cacheAge,
	}, nil
}

// resolveOpponent tries UUID lookup first, then case-insensitive name lookup.
func resolveOpponent(ctx context.Context, st *store.Store, arg string) (*store.OpposingTeam, error) {
	// Try as UUID first (no harm if it's actually a name — UUID lookup is exact).
	if t, err := st.FindOpposingTeamByUUID(ctx, arg); err != nil {
		return nil, err
	} else if t != nil {
		return t, nil
	}
	// Fall back to name.
	return st.FindOpposingTeamByName(ctx, arg)
}

func isStale(lastFetchedAt string, cutoff time.Time) bool {
	t, err := time.Parse(time.RFC3339, lastFetchedAt)
	if err != nil {
		return true // unparseable timestamp = treat as stale
	}
	return t.Before(cutoff)
}

// extractDate pulls YYYY-MM-DD from an RFC3339 timestamp like
// "2026-03-15T16:42:18.702Z". If parsing fails, returns the raw input.
func extractDate(rfc3339 string) string {
	if t, err := time.Parse(time.RFC3339, rfc3339); err == nil {
		return t.UTC().Format("2006-01-02")
	}
	if i := strings.IndexByte(rfc3339, 'T'); i > 0 {
		return rfc3339[:i]
	}
	return rfc3339
}

// outcome computes W/L/T from team scores. Status non-completed returns "".
func outcome(owning, opponent int, status string) string {
	if status != "completed" {
		return ""
	}
	switch {
	case owning > opponent:
		return "W"
	case owning < opponent:
		return "L"
	default:
		return "T"
	}
}
