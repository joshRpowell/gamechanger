package store

import (
	"context"
	"database/sql"

	"github.com/joshrpowell/gamechanger-cli/internal/gcerr"
)

// UpsertGame inserts or updates a game row. Final games are not updated
// (matches the Ruby WHERE games.status != 'final' clause).
func (s *Store) UpsertGame(ctx context.Context, g Game) error {
	const q = `
		INSERT INTO games (game_id, game_date, opponent, home_away, status, fetched_at)
		VALUES (?, ?, ?, ?, ?, ?)
		ON CONFLICT(game_id) DO UPDATE SET
			game_date  = excluded.game_date,
			opponent   = excluded.opponent,
			home_away  = excluded.home_away,
			status     = excluded.status,
			fetched_at = excluded.fetched_at
		WHERE games.status != 'final'`
	_, err := s.db.ExecContext(ctx, q,
		g.GameID, g.GameDate, g.Opponent, g.HomeAway, g.Status, iso8601Now())
	if err != nil {
		return gcerr.Storagef("upsert game %s: %v", g.GameID, err)
	}
	return nil
}

// UpsertPitcherStats batches a transactional upsert of all pitcher rows
// for a single game.
func (s *Store) UpsertPitcherStats(ctx context.Context, gameID string, stats []PitcherStat) error {
	if len(stats) == 0 {
		return nil
	}
	tx, err := s.db.BeginTx(ctx, nil)
	if err != nil {
		return gcerr.Storagef("begin pitcher tx: %v", err)
	}
	const q = `
		INSERT INTO game_pitcher_stats (game_id, pitcher_name, pitches_thrown, strikes_thrown, innings_pitched, fetched_at)
		VALUES (?, ?, ?, ?, ?, ?)
		ON CONFLICT(game_id, pitcher_name) DO UPDATE SET
			pitches_thrown  = excluded.pitches_thrown,
			strikes_thrown  = excluded.strikes_thrown,
			innings_pitched = excluded.innings_pitched,
			fetched_at      = excluded.fetched_at`
	now := iso8601Now()
	for _, st := range stats {
		if _, err := tx.ExecContext(ctx, q,
			gameID, st.PitcherName, st.PitchesThrown, st.StrikesThrown, st.InningsPitched, now); err != nil {
			_ = tx.Rollback()
			return gcerr.Storagef("upsert pitcher %s: %v", st.PitcherName, err)
		}
	}
	if err := tx.Commit(); err != nil {
		return gcerr.Storagef("commit pitcher tx: %v", err)
	}
	return nil
}

// UpsertBatterStats batches a transactional upsert of all batter rows
// for a single game.
func (s *Store) UpsertBatterStats(ctx context.Context, gameID string, stats []BatterStat) error {
	if len(stats) == 0 {
		return nil
	}
	tx, err := s.db.BeginTx(ctx, nil)
	if err != nil {
		return gcerr.Storagef("begin batter tx: %v", err)
	}
	const q = `
		INSERT INTO game_batter_stats (game_id, batter_name, at_bats, hits, walks, strikeouts, fetched_at)
		VALUES (?, ?, ?, ?, ?, ?, ?)
		ON CONFLICT(game_id, batter_name) DO UPDATE SET
			at_bats    = excluded.at_bats,
			hits       = excluded.hits,
			walks      = excluded.walks,
			strikeouts = excluded.strikeouts,
			fetched_at = excluded.fetched_at`
	now := iso8601Now()
	for _, st := range stats {
		if _, err := tx.ExecContext(ctx, q,
			gameID, st.BatterName, st.AtBats, st.Hits, st.Walks, st.Strikeouts, now); err != nil {
			_ = tx.Rollback()
			return gcerr.Storagef("upsert batter %s: %v", st.BatterName, err)
		}
	}
	if err := tx.Commit(); err != nil {
		return gcerr.Storagef("commit batter tx: %v", err)
	}
	return nil
}

// ClearNonFinal deletes all non-final games (forces re-fetch on next sync).
func (s *Store) ClearNonFinal(ctx context.Context) error {
	_, err := s.db.ExecContext(ctx, `DELETE FROM games WHERE status != 'final'`)
	if err != nil {
		return gcerr.Storagef("clear non-final: %v", err)
	}
	return nil
}

// AllGames returns every game in storage, oldest first.
func (s *Store) AllGames(ctx context.Context) ([]Game, error) {
	rows, err := s.db.QueryContext(ctx,
		`SELECT game_id, game_date, opponent, home_away, status, fetched_at FROM games ORDER BY game_date ASC`)
	if err != nil {
		return nil, gcerr.Storagef("list games: %v", err)
	}
	defer rows.Close()
	var out []Game
	for rows.Next() {
		var g Game
		if err := rows.Scan(&g.GameID, &g.GameDate, &g.Opponent, &g.HomeAway, &g.Status, &g.FetchedAt); err != nil {
			return nil, gcerr.Storagef("scan game: %v", err)
		}
		out = append(out, g)
	}
	return out, rows.Err()
}

// GameStatus returns just the status column for a single game. Empty
// string + nil if the game does not exist.
func (s *Store) GameStatus(ctx context.Context, gameID string) (string, error) {
	row := s.db.QueryRowContext(ctx, `SELECT status FROM games WHERE game_id = ?`, gameID)
	var status sql.NullString
	if err := row.Scan(&status); err != nil {
		if err == sql.ErrNoRows {
			return "", nil
		}
		return "", gcerr.Storagef("game status: %v", err)
	}
	return status.String, nil
}

// NextScheduledGame returns the nearest game strictly after afterDate
// within the configured season, or nil if none.
func (s *Store) NextScheduledGame(ctx context.Context, afterDate string) (*Game, error) {
	const q = `
		SELECT game_id, game_date, opponent, home_away, status, fetched_at
		FROM games
		WHERE game_date > ? AND game_date >= ? AND game_date < ?
		ORDER BY game_date ASC
		LIMIT 1`
	row := s.db.QueryRowContext(ctx, q, afterDate, s.seasonStart(), s.nextSeasonStart())
	var g Game
	if err := row.Scan(&g.GameID, &g.GameDate, &g.Opponent, &g.HomeAway, &g.Status, &g.FetchedAt); err != nil {
		if err == sql.ErrNoRows {
			return nil, nil
		}
		return nil, gcerr.Storagef("next scheduled game: %v", err)
	}
	return &g, nil
}

// PitcherAvailability returns one row per pitcher with last outing, last
// outing pitch count (summed across doubleheaders on the same date), and
// the 7-day rolling total anchored to beforeDate.
func (s *Store) PitcherAvailability(ctx context.Context, beforeDate string) ([]AvailabilityRow, error) {
	const q = `
		SELECT
			sub.pitcher_name,
			sub.last_outing,
			(
				SELECT SUM(gps2.pitches_thrown)
				FROM game_pitcher_stats gps2
				JOIN games g2 ON g2.game_id = gps2.game_id
				WHERE gps2.pitcher_name = sub.pitcher_name
				  AND g2.game_date = sub.last_outing
				  AND gps2.pitches_thrown > 0
			) AS last_pitches,
			sub.seven_day_total
		FROM (
			SELECT
				gps.pitcher_name,
				MAX(g.game_date)     AS last_outing,
				SUM(CASE
					WHEN g.game_date >= date(?, '-7 days') AND gps.pitches_thrown > 0
					THEN gps.pitches_thrown ELSE 0
				END)                 AS seven_day_total
			FROM game_pitcher_stats gps
			JOIN games g ON g.game_id = gps.game_id
			WHERE g.game_date < ?
			  AND g.game_date >= ? AND g.game_date < ?
			  AND gps.pitches_thrown > 0
			GROUP BY gps.pitcher_name
		) sub
		ORDER BY sub.pitcher_name ASC`
	rows, err := s.db.QueryContext(ctx, q, beforeDate, beforeDate, s.seasonStart(), s.nextSeasonStart())
	if err != nil {
		return nil, gcerr.Storagef("pitcher availability: %v", err)
	}
	defer rows.Close()
	var out []AvailabilityRow
	for rows.Next() {
		var r AvailabilityRow
		var sevenDay sql.NullInt64
		if err := rows.Scan(&r.PitcherName, &r.LastOuting, &r.LastPitches, &sevenDay); err != nil {
			return nil, gcerr.Storagef("scan availability: %v", err)
		}
		r.SevenDayTotal = int(sevenDay.Int64)
		out = append(out, r)
	}
	return out, rows.Err()
}

// BatterLineupData returns per-batter 7-day and season aggregates anchored
// to beforeDate. Only includes batters with ≥1 AB.
func (s *Store) BatterLineupData(ctx context.Context, beforeDate string) ([]LineupRow, error) {
	const q = `
		SELECT
			gbs.batter_name,
			SUM(CASE WHEN g.game_date >= date(?, '-7 days') AND gbs.at_bats > 0
				 THEN gbs.at_bats ELSE 0 END)   AS seven_day_ab,
			SUM(CASE WHEN g.game_date >= date(?, '-7 days') AND gbs.at_bats > 0
				 THEN gbs.hits    ELSE 0 END)   AS seven_day_hits,
			SUM(CASE WHEN g.game_date >= date(?, '-7 days') AND gbs.at_bats > 0
				 THEN gbs.walks   ELSE 0 END)   AS seven_day_walks,
			SUM(gbs.at_bats) AS season_ab,
			SUM(gbs.hits)    AS season_hits,
			SUM(gbs.walks)   AS season_walks
		FROM game_batter_stats gbs
		JOIN games g ON g.game_id = gbs.game_id
		WHERE g.game_date < ?
		  AND g.game_date >= ? AND g.game_date < ?
		  AND gbs.at_bats > 0
		GROUP BY gbs.batter_name
		ORDER BY gbs.batter_name ASC`
	rows, err := s.db.QueryContext(ctx, q,
		beforeDate, beforeDate, beforeDate, beforeDate, s.seasonStart(), s.nextSeasonStart())
	if err != nil {
		return nil, gcerr.Storagef("batter lineup: %v", err)
	}
	defer rows.Close()
	var out []LineupRow
	for rows.Next() {
		var r LineupRow
		if err := rows.Scan(
			&r.BatterName,
			&r.SevenDayAB, &r.SevenDayHits, &r.SevenDayWalks,
			&r.SeasonAB, &r.SeasonHits, &r.SeasonWalks,
		); err != nil {
			return nil, gcerr.Storagef("scan lineup: %v", err)
		}
		out = append(out, r)
	}
	return out, rows.Err()
}

// AllPlayerDevelopmentSummary returns the first-half / second-half / recent
// OBP and strike% aggregates for every player with ≥3 appearances in either
// dimension. Uses SQLite window functions (requires SQLite ≥3.25).
func (s *Store) AllPlayerDevelopmentSummary(ctx context.Context) ([]DevelopmentRow, error) {
	const q = `
		WITH total_games AS (
			SELECT COUNT(*) AS n FROM games
			WHERE status = 'final' AND game_date >= ? AND game_date < ?
		),
		ordered_games AS (
			SELECT game_id, game_date,
				ROW_NUMBER() OVER (ORDER BY game_date ASC) AS seq
			FROM games
			WHERE status = 'final' AND game_date >= ? AND game_date < ?
		),
		batting_per_game AS (
			SELECT gbs.batter_name,
				og.seq,
				CAST(gbs.hits + gbs.walks AS REAL) / NULLIF(gbs.at_bats + gbs.walks, 0) AS obp
			FROM game_batter_stats gbs
			JOIN ordered_games og ON og.game_id = gbs.game_id
			WHERE gbs.at_bats + gbs.walks > 0
		),
		batting_recent AS (
			SELECT sub.batter_name, AVG(sub.obp) AS recent_obp
			FROM (
				SELECT batter_name, obp,
					ROW_NUMBER() OVER (PARTITION BY batter_name ORDER BY seq DESC) AS recency
				FROM batting_per_game
			) sub
			WHERE sub.recency <= 5
			GROUP BY sub.batter_name
		),
		batting_summary AS (
			SELECT bpg.batter_name,
				AVG(CASE WHEN bpg.seq <= (SELECT n/2 FROM total_games) THEN bpg.obp END) AS first_half_obp,
				AVG(CASE WHEN bpg.seq >  (SELECT n/2 FROM total_games) THEN bpg.obp END) AS second_half_obp,
				COUNT(DISTINCT bpg.seq) AS total_games_batted
			FROM batting_per_game bpg
			GROUP BY bpg.batter_name
			HAVING COUNT(DISTINCT bpg.seq) >= 3
		),
		pitching_per_game AS (
			SELECT gps.pitcher_name,
				og.seq,
				CAST(gps.strikes_thrown AS REAL) / NULLIF(gps.pitches_thrown, 0) AS strike_pct
			FROM game_pitcher_stats gps
			JOIN ordered_games og ON og.game_id = gps.game_id
			WHERE gps.pitches_thrown > 0
		),
		pitching_recent AS (
			SELECT sub.pitcher_name, AVG(sub.strike_pct) AS recent_strike_pct
			FROM (
				SELECT pitcher_name, strike_pct,
					ROW_NUMBER() OVER (PARTITION BY pitcher_name ORDER BY seq DESC) AS recency
				FROM pitching_per_game
			) sub
			WHERE sub.recency <= 5
			GROUP BY sub.pitcher_name
		),
		pitching_summary AS (
			SELECT ppg.pitcher_name,
				AVG(CASE WHEN ppg.seq <= (SELECT n/2 FROM total_games) THEN ppg.strike_pct END) AS first_half_strike_pct,
				AVG(CASE WHEN ppg.seq >  (SELECT n/2 FROM total_games) THEN ppg.strike_pct END) AS second_half_strike_pct,
				COUNT(DISTINCT ppg.seq) AS total_games_pitched
			FROM pitching_per_game ppg
			GROUP BY ppg.pitcher_name
			HAVING COUNT(DISTINCT ppg.seq) >= 3
		),
		all_players AS (
			SELECT DISTINCT batter_name AS player_name FROM game_batter_stats
			UNION
			SELECT DISTINCT pitcher_name FROM game_pitcher_stats
		)
		SELECT
			p.player_name,
			bat.first_half_obp,
			bat.second_half_obp,
			br.recent_obp,
			bat.total_games_batted,
			pit.first_half_strike_pct,
			pit.second_half_strike_pct,
			pr.recent_strike_pct,
			pit.total_games_pitched
		FROM all_players p
		LEFT JOIN batting_summary  bat ON bat.batter_name  = p.player_name
		LEFT JOIN batting_recent   br  ON br.batter_name   = p.player_name
		LEFT JOIN pitching_summary pit ON pit.pitcher_name = p.player_name
		LEFT JOIN pitching_recent  pr  ON pr.pitcher_name  = p.player_name
		WHERE bat.batter_name IS NOT NULL OR pit.pitcher_name IS NOT NULL
		ORDER BY p.player_name ASC`
	rows, err := s.db.QueryContext(ctx, q,
		s.seasonStart(), s.nextSeasonStart(), s.seasonStart(), s.nextSeasonStart())
	if err != nil {
		return nil, gcerr.Storagef("development summary: %v", err)
	}
	defer rows.Close()
	var out []DevelopmentRow
	for rows.Next() {
		var r DevelopmentRow
		if err := rows.Scan(
			&r.PlayerName,
			&r.FirstHalfOBP, &r.SecondHalfOBP, &r.RecentOBP, &r.TotalGamesBatted,
			&r.FirstHalfStrikePct, &r.SecondHalfStrikePct, &r.RecentStrikePct, &r.TotalGamesPitched,
		); err != nil {
			return nil, gcerr.Storagef("scan dev row: %v", err)
		}
		out = append(out, r)
	}
	return out, rows.Err()
}

// PlayerParticipation returns one row per player with last batting and
// pitching appearance plus games-ago counts. TotalGames (season-wide final
// game count) is set on every row.
func (s *Store) PlayerParticipation(ctx context.Context) ([]ParticipationRow, error) {
	var totalGames int
	err := s.db.QueryRowContext(ctx,
		`SELECT COUNT(*) FROM games WHERE status = 'final' AND game_date >= ? AND game_date < ?`,
		s.seasonStart(), s.nextSeasonStart()).Scan(&totalGames)
	if err != nil {
		return nil, gcerr.Storagef("count final games: %v", err)
	}

	const q = `
		WITH season_games AS (
			SELECT game_id, game_date, status
			FROM games
			WHERE game_date >= ? AND game_date < ?
		),
		all_players AS (
			SELECT DISTINCT gbs.batter_name AS player_name
			FROM game_batter_stats gbs
			JOIN season_games sg ON sg.game_id = gbs.game_id
			UNION
			SELECT DISTINCT gps.pitcher_name
			FROM game_pitcher_stats gps
			JOIN season_games sg ON sg.game_id = gps.game_id
		),
		batting AS (
			SELECT gbs.batter_name,
				MAX(sg.game_date)            AS last_bat_date,
				COUNT(DISTINCT gbs.game_id)  AS total_games_batted
			FROM game_batter_stats gbs
			JOIN season_games sg ON sg.game_id = gbs.game_id
			WHERE gbs.at_bats > 0 AND sg.status = 'final'
			GROUP BY gbs.batter_name
		),
		pitching AS (
			SELECT gps.pitcher_name,
				MAX(sg.game_date)            AS last_pitch_date,
				COUNT(DISTINCT gps.game_id)  AS total_games_pitched
			FROM game_pitcher_stats gps
			JOIN season_games sg ON sg.game_id = gps.game_id
			WHERE gps.pitches_thrown > 0 AND sg.status = 'final'
			GROUP BY gps.pitcher_name
		)
		SELECT
			p.player_name,
			bat.last_bat_date,
			(SELECT COUNT(*) FROM season_games g4
			 WHERE g4.game_date > bat.last_bat_date
			   AND g4.status = 'final')  AS games_since_last_batted,
			bat.total_games_batted,
			pit.last_pitch_date,
			(SELECT COUNT(*) FROM season_games g5
			 WHERE g5.game_date > pit.last_pitch_date
			   AND g5.status = 'final')  AS games_since_last_pitched,
			pit.total_games_pitched
		FROM all_players p
		LEFT JOIN batting  bat ON bat.batter_name  = p.player_name
		LEFT JOIN pitching pit ON pit.pitcher_name = p.player_name
		ORDER BY games_since_last_batted DESC NULLS LAST,
			 p.player_name ASC`
	rows, err := s.db.QueryContext(ctx, q, s.seasonStart(), s.nextSeasonStart())
	if err != nil {
		return nil, gcerr.Storagef("player participation: %v", err)
	}
	defer rows.Close()
	var out []ParticipationRow
	for rows.Next() {
		var r ParticipationRow
		if err := rows.Scan(
			&r.PlayerName,
			&r.LastBatDate, &r.GamesSinceLastBatted, &r.TotalGamesBatted,
			&r.LastPitchDate, &r.GamesSinceLastPitched, &r.TotalGamesPitched,
		); err != nil {
			return nil, gcerr.Storagef("scan participation: %v", err)
		}
		r.TotalGames = totalGames
		out = append(out, r)
	}
	return out, rows.Err()
}
