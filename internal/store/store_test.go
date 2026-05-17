package store

import (
	"context"
	"database/sql"
	"testing"
)

func newMemStore(t *testing.T) *Store {
	t.Helper()
	s, err := OpenAt(context.Background(), "", 2026)
	if err != nil {
		t.Fatalf("OpenAt: %v", err)
	}
	t.Cleanup(func() { _ = s.Close() })
	return s
}

func seedGame(t *testing.T, s *Store, gameID, date, status string) {
	t.Helper()
	if err := s.UpsertGame(context.Background(), Game{
		GameID:   gameID,
		GameDate: date,
		Opponent: sql.NullString{String: "Test Opp", Valid: true},
		HomeAway: sql.NullString{String: "home", Valid: true},
		Status:   sql.NullString{String: status, Valid: true},
	}); err != nil {
		t.Fatalf("seed %s: %v", gameID, err)
	}
}

func TestMigrationsApplyIdempotent(t *testing.T) {
	s := newMemStore(t)
	// migrate() ran on Open. Run again and confirm no error and no duplicate
	// schema_migrations rows.
	if err := s.migrate(context.Background()); err != nil {
		t.Fatalf("second migrate: %v", err)
	}
	var count int
	if err := s.db.QueryRow(`SELECT COUNT(*) FROM schema_migrations`).Scan(&count); err != nil {
		t.Fatalf("count: %v", err)
	}
	if count != len(migrations) {
		t.Fatalf("schema_migrations count = %d; want %d", count, len(migrations))
	}
}

func TestUpsertAndListGames(t *testing.T) {
	s := newMemStore(t)
	seedGame(t, s, "g1", "2026-03-15", "final")
	seedGame(t, s, "g2", "2026-04-01", "scheduled")

	games, err := s.AllGames(context.Background())
	if err != nil {
		t.Fatalf("AllGames: %v", err)
	}
	if len(games) != 2 {
		t.Fatalf("len = %d; want 2", len(games))
	}
	if games[0].GameID != "g1" {
		t.Fatalf("oldest game = %s; want g1", games[0].GameID)
	}
}

func TestUpsertGame_FinalIsImmutable(t *testing.T) {
	s := newMemStore(t)
	seedGame(t, s, "g1", "2026-03-15", "final")
	// Attempt to update a final game — Ruby's WHERE status != 'final' clause
	// means this should be a no-op.
	if err := s.UpsertGame(context.Background(), Game{
		GameID:   "g1",
		GameDate: "2099-12-31",
		Status:   sql.NullString{String: "scheduled", Valid: true},
	}); err != nil {
		t.Fatalf("upsert: %v", err)
	}
	status, _ := s.GameStatus(context.Background(), "g1")
	if status != "final" {
		t.Fatalf("status = %q; want final (final games are immutable)", status)
	}
}

func TestClearNonFinalKeepsFinals(t *testing.T) {
	s := newMemStore(t)
	seedGame(t, s, "final1", "2026-03-15", "final")
	seedGame(t, s, "sched1", "2026-04-01", "scheduled")
	seedGame(t, s, "inprog", "2026-04-02", "in_progress")

	if err := s.ClearNonFinal(context.Background()); err != nil {
		t.Fatalf("ClearNonFinal: %v", err)
	}
	games, _ := s.AllGames(context.Background())
	if len(games) != 1 || games[0].GameID != "final1" {
		t.Fatalf("after clear non-final, got %d games (%+v); want only final1", len(games), games)
	}
}

func TestUpsertPitcherStatsRoundTrip(t *testing.T) {
	s := newMemStore(t)
	seedGame(t, s, "g1", "2026-03-15", "final")
	stats := []PitcherStat{
		{PitcherName: "Asher", PitchesThrown: 59,
			StrikesThrown: sql.NullInt64{Int64: 38, Valid: true},
			InningsPitched: sql.NullFloat64{Float64: 4.0, Valid: true}},
		{PitcherName: "Mason", PitchesThrown: 25,
			StrikesThrown: sql.NullInt64{Int64: 14, Valid: true},
			InningsPitched: sql.NullFloat64{Float64: 1.667, Valid: true}},
	}
	if err := s.UpsertPitcherStats(context.Background(), "g1", stats); err != nil {
		t.Fatalf("upsert pitcher: %v", err)
	}

	var got int
	_ = s.db.QueryRow(`SELECT COUNT(*) FROM game_pitcher_stats WHERE game_id = ?`, "g1").Scan(&got)
	if got != 2 {
		t.Fatalf("pitcher rows = %d; want 2", got)
	}

	// Idempotent: re-upsert with new pitch count.
	stats[0].PitchesThrown = 65
	if err := s.UpsertPitcherStats(context.Background(), "g1", stats); err != nil {
		t.Fatalf("re-upsert: %v", err)
	}
	var pitches int
	_ = s.db.QueryRow(`SELECT pitches_thrown FROM game_pitcher_stats WHERE game_id = ? AND pitcher_name = ?`,
		"g1", "Asher").Scan(&pitches)
	if pitches != 65 {
		t.Fatalf("after re-upsert, pitches = %d; want 65", pitches)
	}
}

func TestPitcherAvailabilityRollup(t *testing.T) {
	s := newMemStore(t)
	// Two outings, 5 days apart, both within the 7-day window of 2026-03-20.
	seedGame(t, s, "g1", "2026-03-14", "final")
	seedGame(t, s, "g2", "2026-03-18", "final")
	_ = s.UpsertPitcherStats(context.Background(), "g1", []PitcherStat{
		{PitcherName: "Asher", PitchesThrown: 30},
	})
	_ = s.UpsertPitcherStats(context.Background(), "g2", []PitcherStat{
		{PitcherName: "Asher", PitchesThrown: 45},
	})

	rows, err := s.PitcherAvailability(context.Background(), "2026-03-20")
	if err != nil {
		t.Fatalf("PitcherAvailability: %v", err)
	}
	if len(rows) != 1 {
		t.Fatalf("rows = %d; want 1", len(rows))
	}
	r := rows[0]
	if r.PitcherName != "Asher" {
		t.Fatalf("name = %s", r.PitcherName)
	}
	if !r.LastOuting.Valid || r.LastOuting.String != "2026-03-18" {
		t.Fatalf("last outing = %v; want 2026-03-18", r.LastOuting)
	}
	if !r.LastPitches.Valid || r.LastPitches.Int64 != 45 {
		t.Fatalf("last pitches = %v; want 45", r.LastPitches)
	}
	if r.SevenDayTotal != 75 {
		t.Fatalf("7-day total = %d; want 75 (30+45)", r.SevenDayTotal)
	}
}

func TestBatterLineupData(t *testing.T) {
	s := newMemStore(t)
	seedGame(t, s, "g1", "2026-03-15", "final")
	seedGame(t, s, "g2", "2026-03-18", "final")
	_ = s.UpsertBatterStats(context.Background(), "g1", []BatterStat{
		{BatterName: "Mason", AtBats: 3, Hits: 2, Walks: 1},
	})
	_ = s.UpsertBatterStats(context.Background(), "g2", []BatterStat{
		{BatterName: "Mason", AtBats: 4, Hits: 1, Walks: 0},
		{BatterName: "Asher", AtBats: 0, Hits: 0, Walks: 1}, // 0 ABs — excluded
	})

	rows, err := s.BatterLineupData(context.Background(), "2026-03-20")
	if err != nil {
		t.Fatalf("BatterLineupData: %v", err)
	}
	if len(rows) != 1 {
		t.Fatalf("rows = %d; want 1 (Asher has 0 ABs)", len(rows))
	}
	r := rows[0]
	if r.SevenDayAB != 7 {
		t.Fatalf("7-day AB = %d; want 7 (3+4)", r.SevenDayAB)
	}
	if r.SevenDayHits != 3 {
		t.Fatalf("7-day hits = %d; want 3", r.SevenDayHits)
	}
	if r.SeasonWalks != 1 {
		t.Fatalf("season walks = %d; want 1", r.SeasonWalks)
	}
}

func TestNextScheduledGame(t *testing.T) {
	s := newMemStore(t)
	seedGame(t, s, "past", "2026-03-15", "final")
	seedGame(t, s, "soon", "2026-03-22", "scheduled")
	seedGame(t, s, "later", "2026-04-05", "scheduled")

	g, err := s.NextScheduledGame(context.Background(), "2026-03-20")
	if err != nil {
		t.Fatalf("NextScheduledGame: %v", err)
	}
	if g == nil || g.GameID != "soon" {
		t.Fatalf("next = %+v; want soon", g)
	}

	// After the last scheduled game, expect nil.
	g, err = s.NextScheduledGame(context.Background(), "2026-12-31")
	if err != nil {
		t.Fatalf("late: %v", err)
	}
	if g != nil {
		t.Fatalf("expected nil after season; got %+v", g)
	}
}

func TestPlayerParticipationCountsFinalsOnly(t *testing.T) {
	s := newMemStore(t)
	seedGame(t, s, "f1", "2026-03-15", "final")
	seedGame(t, s, "f2", "2026-03-22", "final")
	seedGame(t, s, "s1", "2026-04-01", "scheduled") // not counted

	_ = s.UpsertBatterStats(context.Background(), "f1", []BatterStat{
		{BatterName: "Mason", AtBats: 3, Hits: 1, Walks: 1},
	})
	_ = s.UpsertBatterStats(context.Background(), "f2", []BatterStat{
		{BatterName: "Mason", AtBats: 4, Hits: 2, Walks: 0},
	})

	rows, err := s.PlayerParticipation(context.Background())
	if err != nil {
		t.Fatalf("PlayerParticipation: %v", err)
	}
	if len(rows) != 1 {
		t.Fatalf("len = %d; want 1", len(rows))
	}
	r := rows[0]
	if r.TotalGames != 2 {
		t.Fatalf("TotalGames = %d; want 2 (only finals count)", r.TotalGames)
	}
	if !r.TotalGamesBatted.Valid || r.TotalGamesBatted.Int64 != 2 {
		t.Fatalf("TotalGamesBatted = %v; want 2", r.TotalGamesBatted)
	}
}

func TestAllPlayerDevelopmentSummary_NeedsThreeGames(t *testing.T) {
	s := newMemStore(t)
	// Mason plays 3 games; Asher plays 2 (filtered out by HAVING ≥ 3)
	for i, date := range []string{"2026-03-01", "2026-03-08", "2026-03-15"} {
		gameID := "g" + string(rune('1'+i))
		seedGame(t, s, gameID, date, "final")
		_ = s.UpsertBatterStats(context.Background(), gameID, []BatterStat{
			{BatterName: "Mason", AtBats: 3, Hits: 1, Walks: 1},
		})
		if i < 2 {
			_ = s.UpsertBatterStats(context.Background(), gameID, []BatterStat{
				{BatterName: "Asher", AtBats: 2, Hits: 0, Walks: 1},
			})
		}
	}

	rows, err := s.AllPlayerDevelopmentSummary(context.Background())
	if err != nil {
		t.Fatalf("AllPlayerDevelopmentSummary: %v", err)
	}
	if len(rows) != 1 || rows[0].PlayerName != "Mason" {
		t.Fatalf("rows = %+v; want only Mason", rows)
	}
}
