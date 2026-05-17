package store

import (
	"context"
	"database/sql"

	"github.com/joshrpowell/gamechanger-cli/internal/gcerr"
)

// CrossReferenceRoster returns recognition markers for any roster names that
// match players in the user's own historical games against the given
// opposing team.
//
// Semantics (Phase 1a):
//   - Match is case-normalized exact string compare on player name (no
//     punctuation/nickname fuzzing — origin AE2 explicitly scopes that out).
//   - Team-scoped: only games where LOWER(games.opponent) = LOWER(opposingTeamName)
//     count. A player whose name coincidentally matches across an unrelated
//     opponent must NOT surface (eng-review fix for false positives).
//   - A player who batted AND pitched in the same game surfaces once for that
//     game (UNION deduplicates).
//   - Marker carries GameDate + Opponent only. Score columns + W/L derivation
//     defer to Phase 1b.
//
// The returned map's keys match the input rosterNames verbatim (preserving
// original casing for the caller's lookup convenience). Missing-name keys
// are absent from the map; checking `len(markers[name]) == 0` is the
// no-match test.
//
// Empty inputs (empty rosterNames OR empty opposingTeamName) return an empty
// map with no error.
func (s *Store) CrossReferenceRoster(
	ctx context.Context,
	opposingTeamName string,
	rosterNames []string,
) (map[string][]RecognitionMarker, error) {
	out := make(map[string][]RecognitionMarker)
	if opposingTeamName == "" || len(rosterNames) == 0 {
		return out, nil
	}

	// One query per roster name. N is typically 15-25 for a roster, queries
	// are local + indexed, total cost is sub-millisecond on a populated
	// cache. The alternative (single query with dynamic IN-clause) trades
	// readability for marginal performance — not worth it at this scale.
	//
	// The inner UNION dedups when a player both batted and pitched in the
	// same game (rare but real). Outer ORDER BY surfaces most-recent
	// matchups first.
	const q = `
		SELECT game_date, opponent
		FROM games
		WHERE LOWER(opponent) = LOWER(?)
		  AND game_id IN (
		    SELECT game_id FROM game_batter_stats
		      WHERE LOWER(batter_name) = LOWER(?)
		    UNION
		    SELECT game_id FROM game_pitcher_stats
		      WHERE LOWER(pitcher_name) = LOWER(?)
		  )
		ORDER BY game_date DESC`

	for _, name := range rosterNames {
		rows, err := s.db.QueryContext(ctx, q, opposingTeamName, name, name)
		if err != nil {
			return nil, gcerr.Storagef("cross-reference %q vs %q: %v", name, opposingTeamName, err)
		}
		for rows.Next() {
			// games.game_date is NOT NULL; games.opponent is nullable but the
			// LOWER() comparison above filters out NULL opponents already.
			// Defensive scan into NullString anyway in case the schema relaxes.
			var dateNS, oppNS sql.NullString
			if err := rows.Scan(&dateNS, &oppNS); err != nil {
				_ = rows.Close()
				return nil, gcerr.Storagef("scan cross-reference row for %q: %v", name, err)
			}
			out[name] = append(out[name], RecognitionMarker{
				GameDate: dateNS.String,
				Opponent: oppNS.String,
			})
		}
		if err := rows.Close(); err != nil {
			return nil, gcerr.Storagef("close cross-reference rows for %q: %v", name, err)
		}
	}
	return out, nil
}

// ─── Opposing-team metadata cache (U6 — Fork A) ────────────────────────────
//
// These queries back the matchup-history scout orchestrator's opponent
// name↔UUID resolution. opposing_teams (migration v4) caches the 220-byte
// /opponent/{uuid} responses so repeat scout invocations don't re-fetch.

// UpsertOpposingTeam inserts or updates one opposing-team metadata row.
// Used after each successful OpponentDetail fetch.
func (s *Store) UpsertOpposingTeam(ctx context.Context, team OpposingTeam) error {
	if team.TeamUUID == "" {
		return gcerr.Storagef("UpsertOpposingTeam: team_uuid is required")
	}
	const q = `
		INSERT INTO opposing_teams (team_uuid, team_name, last_fetched_at)
		VALUES (?, ?, ?)
		ON CONFLICT(team_uuid) DO UPDATE SET
			team_name       = excluded.team_name,
			last_fetched_at = excluded.last_fetched_at`
	if _, err := s.db.ExecContext(ctx, q,
		team.TeamUUID, team.TeamName, team.LastFetchedAt); err != nil {
		return gcerr.Storagef("upsert opposing_teams %s: %v", team.TeamUUID, err)
	}
	return nil
}

// FindOpposingTeamByUUID returns the cached opposing-team row, or nil if not
// present. Not-present is not an error — caller decides whether to fetch.
func (s *Store) FindOpposingTeamByUUID(ctx context.Context, teamUUID string) (*OpposingTeam, error) {
	if teamUUID == "" {
		return nil, nil
	}
	const q = `SELECT team_uuid, team_name, last_fetched_at FROM opposing_teams WHERE team_uuid = ?`
	row := s.db.QueryRowContext(ctx, q, teamUUID)
	var t OpposingTeam
	if err := row.Scan(&t.TeamUUID, &t.TeamName, &t.LastFetchedAt); err != nil {
		if err == sql.ErrNoRows {
			return nil, nil
		}
		return nil, gcerr.Storagef("FindOpposingTeamByUUID %s: %v", teamUUID, err)
	}
	return &t, nil
}

// FindOpposingTeamByName returns the cached opposing-team row matching the
// given name case-insensitively. Returns nil if not found. If multiple rows
// match (different UUIDs, same case-normalized name — possible when a team
// rebranded), returns the most-recently-fetched.
func (s *Store) FindOpposingTeamByName(ctx context.Context, name string) (*OpposingTeam, error) {
	if name == "" {
		return nil, nil
	}
	const q = `
		SELECT team_uuid, team_name, last_fetched_at
		FROM opposing_teams
		WHERE LOWER(team_name) = LOWER(?)
		ORDER BY last_fetched_at DESC
		LIMIT 1`
	row := s.db.QueryRowContext(ctx, q, name)
	var t OpposingTeam
	if err := row.Scan(&t.TeamUUID, &t.TeamName, &t.LastFetchedAt); err != nil {
		if err == sql.ErrNoRows {
			return nil, nil
		}
		return nil, gcerr.Storagef("FindOpposingTeamByName %q: %v", name, err)
	}
	return &t, nil
}
