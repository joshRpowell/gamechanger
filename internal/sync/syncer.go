// Package sync fetches schedule + boxscore data from the Gamechanger API
// and persists it into store.Store. Port of Gamechanger::Syncer.
package sync

import (
	"context"
	"database/sql"
	"errors"
	"strings"
	"time"

	"github.com/joshrpowell/gamechanger-cli/internal/client"
	"github.com/joshrpowell/gamechanger-cli/internal/config"
	"github.com/joshrpowell/gamechanger-cli/internal/gcerr"
	"github.com/joshrpowell/gamechanger-cli/internal/parser"
	"github.com/joshrpowell/gamechanger-cli/internal/store"
)

// Syncer wires together client + store + parsers for a single refresh run.
type Syncer struct {
	Config *config.Config
	Client *client.Client
	Store  *store.Store

	// RateLimit is the pause between game-level requests. Zero ⇒ use the
	// client's default. Tests override to zero to keep them fast.
	RateLimit time.Duration

	// Now is a clock override for tests. Zero ⇒ time.Now().UTC().
	Now func() time.Time
}

func (s *Syncer) now() time.Time {
	if s.Now != nil {
		return s.Now()
	}
	return time.Now().UTC()
}

func (s *Syncer) rateLimit() time.Duration {
	if s.RateLimit > 0 {
		return s.RateLimit
	}
	return client.RateLimitSleep
}

// Run pulls the schedule and any unfinalized stats. force=true clears
// non-final games before syncing, forcing a re-fetch.
func (s *Syncer) Run(ctx context.Context, force bool) (store.SyncResult, error) {
	result := store.SyncResult{}

	if force {
		if err := s.Store.ClearNonFinal(ctx); err != nil {
			return result, err
		}
	}

	teamID := s.Config.TeamID
	teamSlug := s.Config.TeamSlug
	if strings.TrimSpace(teamID) == "" {
		return result, gcerr.Configf("no team_id configured. Run `gamechanger setup` again")
	}
	if strings.TrimSpace(teamSlug) == "" {
		return result, gcerr.Configf(
			"no team_slug configured. Run `gamechanger setup` again. " +
				"Or add team_slug to ~/.gamechanger/config.yml (the short ID from your team URL)")
	}

	raw, err := s.Client.Schedule(ctx, teamID)
	if err != nil {
		return result, err
	}
	scheduleItems, err := extractGames(raw)
	if err != nil {
		return result, err
	}

	today := s.now().Format("2006-01-02")
	for _, item := range scheduleItems {
		parsed, ok := parseGame(item)
		if !ok {
			continue
		}
		if parsed.status == "canceled" {
			continue
		}
		if parsed.gameDate == "" || parsed.gameDate > today {
			continue
		}

		if err := s.Store.UpsertGame(ctx, parsed.toStoreGame()); err != nil {
			return result, err
		}

		// Skip stats fetch when game is already final in cache and we
		// are not forcing a re-sync.
		cachedStatus, err := s.Store.GameStatus(ctx, parsed.gameID)
		if err != nil {
			return result, err
		}
		if cachedStatus == "final" && !force {
			continue
		}

		// Rate-limit between game-level requests.
		select {
		case <-ctx.Done():
			return result, gcerr.Networkf("context cancelled during sync")
		case <-time.After(s.rateLimit()):
		}

		raw, err := s.Client.Boxscore(ctx, parsed.gameID)
		if err != nil {
			if errors.Is(err, client.ErrBoxscoreNotFound) {
				// Canceled, postponed, or never-played game. Keep the
				// schedule row in place but skip stats for this one.
				continue
			}
			return result, err
		}
		pitcherStats, err := parser.PitcherStats(raw, teamSlug)
		if err != nil {
			return result, err
		}
		if err := s.Store.UpsertPitcherStats(ctx, parsed.gameID, pitcherStats); err != nil {
			return result, err
		}

		batterStats, err := parser.BatterStats(raw, teamSlug)
		if err != nil {
			return result, err
		}
		if len(batterStats) > 0 {
			if err := s.Store.UpsertBatterStats(ctx, parsed.gameID, batterStats); err != nil {
				return result, err
			}
		}

		if len(pitcherStats) > 0 {
			finalGame := parsed.toStoreGame()
			finalGame.Status = sql.NullString{String: "final", Valid: true}
			if err := s.Store.UpsertGame(ctx, finalGame); err != nil {
				return result, err
			}
			result.Games++
			result.Outings += len(pitcherStats)
			for _, b := range batterStats {
				result.AtBats += b.AtBats
			}
		}
	}

	return result, nil
}

// parsedGame mirrors the keys Ruby's Syncer#parse_game produces. Internal
// to this package so the store.Game shape stays uncontaminated.
type parsedGame struct {
	gameID   string
	gameDate string
	opponent string
	homeAway string
	status   string
}

func (p parsedGame) toStoreGame() store.Game {
	return store.Game{
		GameID:   p.gameID,
		GameDate: p.gameDate,
		Opponent: nullableString(p.opponent),
		HomeAway: nullableString(p.homeAway),
		Status:   nullableString(p.status),
	}
}

// extractGames flattens the API's schedule response into a list of
// {event, pregame_data} maps, filtered to event_type == "game".
func extractGames(raw any) ([]map[string]any, error) {
	var items []any
	switch v := raw.(type) {
	case []any:
		items = v
	case map[string]any:
		for _, key := range []string{"schedule", "events", "data"} {
			if list, ok := v[key].([]any); ok {
				items = list
				break
			}
		}
		if items == nil {
			return nil, gcerr.APIShapef("unexpected schedule response shape: %T", raw)
		}
	default:
		return nil, gcerr.APIShapef("unexpected schedule response shape: %T", raw)
	}

	out := make([]map[string]any, 0, len(items))
	for _, it := range items {
		m, ok := it.(map[string]any)
		if !ok {
			continue
		}
		event, _ := m["event"].(map[string]any)
		if event == nil {
			continue
		}
		if et, _ := event["event_type"].(string); et != "game" {
			continue
		}
		out = append(out, m)
	}
	return out, nil
}

func parseGame(item map[string]any) (parsedGame, bool) {
	event, _ := item["event"].(map[string]any)
	pregame, _ := item["pregame_data"].(map[string]any)
	if event == nil {
		return parsedGame{}, false
	}

	gameID, _ := event["id"].(string)
	if gameID == "" {
		return parsedGame{}, false
	}

	// Date can come from start.datetime (split on 'T') or start.date.
	gameDate := ""
	if start, ok := event["start"].(map[string]any); ok {
		if dt, _ := start["datetime"].(string); dt != "" {
			if idx := strings.IndexByte(dt, 'T'); idx > 0 {
				gameDate = dt[:idx]
			} else {
				gameDate = dt
			}
		} else if d, _ := start["date"].(string); d != "" {
			gameDate = d
		}
	}

	// opponent: pregame.opponent_name OR event.title
	opponent := ""
	if pregame != nil {
		if s, _ := pregame["opponent_name"].(string); s != "" {
			opponent = s
		}
	}
	if opponent == "" {
		if t, _ := event["title"].(string); t != "" {
			opponent = t
		}
	}

	homeAway := ""
	if pregame != nil {
		homeAway, _ = pregame["home_away"].(string)
	}

	rawStatus, _ := event["status"].(string)
	return parsedGame{
		gameID:   gameID,
		gameDate: gameDate,
		opponent: opponent,
		homeAway: homeAway,
		status:   normalizeStatus(rawStatus),
	}, true
}

func normalizeStatus(raw string) string {
	s := strings.ToLower(strings.TrimSpace(raw))
	switch {
	case strings.Contains(s, "completed"), strings.Contains(s, "final"), strings.Contains(s, "ended"):
		return "final"
	case strings.Contains(s, "progress"), strings.Contains(s, "live"), strings.Contains(s, "active"):
		return "in_progress"
	case strings.Contains(s, "scheduled"), strings.Contains(s, "upcoming"):
		return "scheduled"
	default:
		return s
	}
}

func nullableString(s string) sql.NullString {
	if s == "" {
		return sql.NullString{}
	}
	return sql.NullString{String: s, Valid: true}
}
