package store

import (
	"context"
	"strings"
	"testing"
)

// Test coverage for migration v4 — scout Phase 1a (U2).
//
// v4 adds two additive tables on top of the v3 schema:
//   - opposing_teams   (team_uuid PK)
//   - opposing_roster  (composite PK on team_uuid + player_name)
//
// plus a case-insensitive index on opposing_roster.player_name to support
// the cross-reference workflow in U6.
//
// v1-v3 tables MUST remain byte-identical so Ruby↔Go interop on the existing
// analytics commands is preserved.

func TestMigrationV4_NewTablesExist(t *testing.T) {
	s := newMemStore(t)
	for _, table := range []string{"opposing_teams", "opposing_roster"} {
		var name string
		err := s.db.QueryRow(
			`SELECT name FROM sqlite_master WHERE type='table' AND name=?`, table,
		).Scan(&name)
		if err != nil {
			t.Fatalf("table %s missing post-migration: %v", table, err)
		}
		if name != table {
			t.Fatalf("table lookup returned %q; want %q", name, table)
		}
	}
}

func TestMigrationV4_OpposingTeamsColumns(t *testing.T) {
	s := newMemStore(t)
	cols := pragmaTableInfo(t, s, "opposing_teams")
	wantCols := []string{"team_uuid", "team_name", "last_fetched_at"}
	for _, want := range wantCols {
		if _, ok := cols[want]; !ok {
			t.Errorf("opposing_teams missing column %q (have: %v)", want, columnNames(cols))
		}
	}
	if !cols["team_uuid"].pk {
		t.Errorf("opposing_teams.team_uuid should be PRIMARY KEY")
	}
}

func TestMigrationV4_OpposingRosterColumns(t *testing.T) {
	s := newMemStore(t)
	cols := pragmaTableInfo(t, s, "opposing_roster")
	wantCols := []string{"team_uuid", "player_name", "jersey_number", "position", "last_fetched_at"}
	for _, want := range wantCols {
		if _, ok := cols[want]; !ok {
			t.Errorf("opposing_roster missing column %q (have: %v)", want, columnNames(cols))
		}
	}
	// Composite primary key on (team_uuid, player_name).
	if !cols["team_uuid"].pk {
		t.Errorf("opposing_roster.team_uuid should be part of PRIMARY KEY")
	}
	if !cols["player_name"].pk {
		t.Errorf("opposing_roster.player_name should be part of PRIMARY KEY")
	}
}

func TestMigrationV4_OpposingRosterIndex(t *testing.T) {
	s := newMemStore(t)
	rows, err := s.db.Query(`PRAGMA index_list(opposing_roster)`)
	if err != nil {
		t.Fatalf("index_list: %v", err)
	}
	defer rows.Close()
	var found bool
	for rows.Next() {
		var seq int
		var name, unique, origin, partial string
		if err := rows.Scan(&seq, &name, &unique, &origin, &partial); err != nil {
			t.Fatalf("scan: %v", err)
		}
		if name == "idx_opposing_roster_name_lower" {
			found = true
		}
	}
	if !found {
		t.Errorf("idx_opposing_roster_name_lower index missing — cross-reference query in U6 depends on it for case-insensitive lookup")
	}
}

func TestMigrationV4_UniquenessViolation(t *testing.T) {
	s := newMemStore(t)
	ctx := context.Background()
	uuid := "11111111-1111-1111-1111-111111111111"
	if _, err := s.db.ExecContext(ctx,
		`INSERT INTO opposing_teams (team_uuid, team_name, last_fetched_at) VALUES (?, ?, ?)`,
		uuid, "Eagles 12U", "2026-05-15T18:00:00Z",
	); err != nil {
		t.Fatalf("seed opposing_teams: %v", err)
	}
	if _, err := s.db.ExecContext(ctx,
		`INSERT INTO opposing_roster (team_uuid, player_name, last_fetched_at) VALUES (?, ?, ?)`,
		uuid, "John Smith", "2026-05-15T18:00:00Z",
	); err != nil {
		t.Fatalf("first insert: %v", err)
	}
	// Second insert with same composite key should fail.
	_, err := s.db.ExecContext(ctx,
		`INSERT INTO opposing_roster (team_uuid, player_name, last_fetched_at) VALUES (?, ?, ?)`,
		uuid, "John Smith", "2026-05-15T19:00:00Z",
	)
	if err == nil {
		t.Fatalf("duplicate (team_uuid, player_name) should have failed uniqueness check")
	}
	if !strings.Contains(strings.ToLower(err.Error()), "unique") &&
		!strings.Contains(strings.ToLower(err.Error()), "constraint") {
		t.Errorf("expected unique/constraint error, got: %v", err)
	}
}

func TestMigrationV4_V1ThroughV3Unchanged(t *testing.T) {
	// v4 is additive; v1-v3 schemas must stay byte-identical for Ruby↔Go
	// interop on the existing analytics commands. Verify each pre-v4 table
	// still has its original columns post-v4.
	s := newMemStore(t)

	gamesCols := pragmaTableInfo(t, s, "games")
	for _, want := range []string{"id", "game_id", "game_date", "opponent", "home_away", "status", "fetched_at", "first_seen_at"} {
		if _, ok := gamesCols[want]; !ok {
			t.Errorf("games table lost column %q after v4 migration", want)
		}
	}

	pitcherCols := pragmaTableInfo(t, s, "game_pitcher_stats")
	for _, want := range []string{"id", "game_id", "pitcher_name", "pitches_thrown", "innings_pitched", "strikes_thrown"} {
		if _, ok := pitcherCols[want]; !ok {
			t.Errorf("game_pitcher_stats lost column %q after v4 migration", want)
		}
	}

	batterCols := pragmaTableInfo(t, s, "game_batter_stats")
	for _, want := range []string{"id", "game_id", "batter_name", "at_bats", "hits", "walks", "strikeouts", "fetched_at"} {
		if _, ok := batterCols[want]; !ok {
			t.Errorf("game_batter_stats lost column %q after v4 migration", want)
		}
	}
}

func TestMigrationV4_SchemaMigrationsCountReflectsV4(t *testing.T) {
	s := newMemStore(t)
	var count int
	if err := s.db.QueryRow(`SELECT COUNT(*) FROM schema_migrations`).Scan(&count); err != nil {
		t.Fatalf("count schema_migrations: %v", err)
	}
	// Existing migrations are v1, v2, v3; this PR adds v4.
	if count != 4 {
		t.Errorf("schema_migrations count = %d; want 4 (v1+v2+v3+v4)", count)
	}
}

// ---------- helpers ----------

type colInfo struct {
	cid     int
	name    string
	colType string
	notNull bool
	dflt    string
	pk      bool
}

// pragmaTableInfo returns a map of column name → column metadata for the given
// table. Failing on missing tables makes test diagnostics easier than empty maps.
func pragmaTableInfo(t *testing.T, s *Store, table string) map[string]colInfo {
	t.Helper()
	rows, err := s.db.Query(`SELECT cid, name, type, "notnull", dflt_value, pk FROM pragma_table_info(?)`, table)
	if err != nil {
		t.Fatalf("pragma_table_info(%s): %v", table, err)
	}
	defer rows.Close()
	out := make(map[string]colInfo)
	for rows.Next() {
		var c colInfo
		var dflt interface{}
		var notNull, pk int
		if err := rows.Scan(&c.cid, &c.name, &c.colType, &notNull, &dflt, &pk); err != nil {
			t.Fatalf("scan pragma_table_info: %v", err)
		}
		c.notNull = notNull != 0
		c.pk = pk != 0
		if s, ok := dflt.(string); ok {
			c.dflt = s
		}
		out[c.name] = c
	}
	if len(out) == 0 {
		t.Fatalf("table %s has no columns — likely missing", table)
	}
	return out
}

func columnNames(cols map[string]colInfo) []string {
	names := make([]string, 0, len(cols))
	for k := range cols {
		names = append(names, k)
	}
	return names
}
