package store

import (
	"context"

	"github.com/joshrpowell/gamechanger-cli/internal/gcerr"
)

// Additive migrations only — same numbering as the Ruby version so a
// database created by either implementation is interchangeable.
var migrations = []struct {
	version int
	sql     string
}{
	{1, `
		CREATE TABLE games (
			id            INTEGER PRIMARY KEY,
			game_id       TEXT NOT NULL UNIQUE,
			game_date     TEXT NOT NULL,
			opponent      TEXT,
			home_away     TEXT,
			status        TEXT,
			fetched_at    TEXT NOT NULL,
			first_seen_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%SZ', 'now'))
		);
		CREATE INDEX idx_games_date   ON games (game_date DESC);
		CREATE INDEX idx_games_status ON games (status);

		CREATE TABLE game_pitcher_stats (
			id              INTEGER PRIMARY KEY,
			game_id         TEXT NOT NULL REFERENCES games(game_id) ON DELETE CASCADE,
			pitcher_name    TEXT NOT NULL,
			pitches_thrown  INTEGER NOT NULL DEFAULT 0,
			innings_pitched REAL,
			fetched_at      TEXT NOT NULL,
			first_seen_at   TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%SZ', 'now')),
			UNIQUE(game_id, pitcher_name)
		);
		CREATE INDEX idx_gps_pitcher ON game_pitcher_stats (pitcher_name);
		CREATE INDEX idx_gps_game    ON game_pitcher_stats (game_id);
	`},
	{2, `
		ALTER TABLE game_pitcher_stats ADD COLUMN strikes_thrown INTEGER;
	`},
	{3, `
		CREATE TABLE game_batter_stats (
			id          INTEGER PRIMARY KEY,
			game_id     TEXT NOT NULL REFERENCES games(game_id) ON DELETE CASCADE,
			batter_name TEXT NOT NULL,
			at_bats     INTEGER NOT NULL DEFAULT 0,
			hits        INTEGER NOT NULL DEFAULT 0,
			walks       INTEGER NOT NULL DEFAULT 0,
			strikeouts  INTEGER NOT NULL DEFAULT 0,
			fetched_at  TEXT NOT NULL,
			UNIQUE(game_id, batter_name)
		);
		CREATE INDEX idx_gbs_batter ON game_batter_stats (batter_name);
		CREATE INDEX idx_gbs_game   ON game_batter_stats (game_id);
	`},
}

func (s *Store) migrate(ctx context.Context) error {
	if _, err := s.db.ExecContext(ctx, `
		CREATE TABLE IF NOT EXISTS schema_migrations (
			version    INTEGER PRIMARY KEY NOT NULL,
			applied_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%SZ', 'now'))
		)`); err != nil {
		return gcerr.Storagef("create schema_migrations: %v", err)
	}

	applied := map[int]bool{}
	rows, err := s.db.QueryContext(ctx, `SELECT version FROM schema_migrations`)
	if err != nil {
		return gcerr.Storagef("read schema_migrations: %v", err)
	}
	for rows.Next() {
		var v int
		if err := rows.Scan(&v); err != nil {
			_ = rows.Close()
			return gcerr.Storagef("scan migration row: %v", err)
		}
		applied[v] = true
	}
	if err := rows.Close(); err != nil {
		return gcerr.Storagef("close migration rows: %v", err)
	}

	for _, m := range migrations {
		if applied[m.version] {
			continue
		}
		tx, err := s.db.BeginTx(ctx, nil)
		if err != nil {
			return gcerr.Storagef("begin migration %d: %v", m.version, err)
		}
		if _, err := tx.ExecContext(ctx, m.sql); err != nil {
			_ = tx.Rollback()
			return gcerr.Storagef("apply migration %d: %v", m.version, err)
		}
		if _, err := tx.ExecContext(ctx,
			`INSERT INTO schema_migrations (version) VALUES (?)`, m.version); err != nil {
			_ = tx.Rollback()
			return gcerr.Storagef("record migration %d: %v", m.version, err)
		}
		if err := tx.Commit(); err != nil {
			return gcerr.Storagef("commit migration %d: %v", m.version, err)
		}
	}
	return nil
}
