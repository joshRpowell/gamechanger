package store

import (
	"context"
	"database/sql"
	"testing"
)

// seedHistoricalGame inserts a game, optionally with batter and pitcher
// participation, so cross-reference tests can exercise the JOIN paths.
func seedHistoricalGame(t *testing.T, s *Store, gameID, date, opponent string, batters, pitchers []string) {
	t.Helper()
	ctx := context.Background()
	if err := s.UpsertGame(ctx, Game{
		GameID:   gameID,
		GameDate: date,
		Opponent: sql.NullString{String: opponent, Valid: true},
		HomeAway: sql.NullString{String: "home", Valid: true},
		Status:   sql.NullString{String: "final", Valid: true},
	}); err != nil {
		t.Fatalf("upsert game %s: %v", gameID, err)
	}
	if len(batters) > 0 {
		stats := make([]BatterStat, len(batters))
		for i, b := range batters {
			stats[i] = BatterStat{BatterName: b, AtBats: 3, Hits: 1}
		}
		if err := s.UpsertBatterStats(ctx, gameID, stats); err != nil {
			t.Fatalf("upsert batters %s: %v", gameID, err)
		}
	}
	if len(pitchers) > 0 {
		stats := make([]PitcherStat, len(pitchers))
		for i, p := range pitchers {
			stats[i] = PitcherStat{
				PitcherName:    p,
				PitchesThrown:  50,
				StrikesThrown:  sql.NullInt64{Int64: 30, Valid: true},
				InningsPitched: sql.NullFloat64{Float64: 4.0, Valid: true},
			}
		}
		if err := s.UpsertPitcherStats(ctx, gameID, stats); err != nil {
			t.Fatalf("upsert pitchers %s: %v", gameID, err)
		}
	}
}

func TestCrossReferenceRoster_HappyPath_Batter(t *testing.T) {
	s := newMemStore(t)
	seedHistoricalGame(t, s,
		"g1", "2026-04-15", "Eagles 12U",
		[]string{"John Smith", "Jane Doe"}, nil,
	)

	markers, err := s.CrossReferenceRoster(context.Background(),
		"Eagles 12U", []string{"John Smith", "Sam Adams"})
	if err != nil {
		t.Fatalf("CrossReferenceRoster: %v", err)
	}
	if len(markers["John Smith"]) != 1 {
		t.Fatalf("John Smith markers: got %d, want 1 (markers map: %#v)", len(markers["John Smith"]), markers)
	}
	got := markers["John Smith"][0]
	if got.GameDate != "2026-04-15" {
		t.Errorf("GameDate = %q; want 2026-04-15", got.GameDate)
	}
	if got.Opponent != "Eagles 12U" {
		t.Errorf("Opponent = %q; want Eagles 12U", got.Opponent)
	}
	// Sam Adams not in history → no entry in markers map (or empty slice — both OK).
	if len(markers["Sam Adams"]) != 0 {
		t.Errorf("Sam Adams should have no markers; got %d", len(markers["Sam Adams"]))
	}
}

func TestCrossReferenceRoster_HappyPath_Pitcher(t *testing.T) {
	s := newMemStore(t)
	seedHistoricalGame(t, s,
		"g1", "2026-04-15", "Eagles 12U",
		nil, []string{"John Smith"},
	)

	markers, err := s.CrossReferenceRoster(context.Background(),
		"Eagles 12U", []string{"John Smith"})
	if err != nil {
		t.Fatalf("CrossReferenceRoster: %v", err)
	}
	if len(markers["John Smith"]) != 1 {
		t.Fatalf("pitcher cross-reference: got %d markers, want 1", len(markers["John Smith"]))
	}
}

func TestCrossReferenceRoster_CaseInsensitiveNames(t *testing.T) {
	s := newMemStore(t)
	seedHistoricalGame(t, s,
		"g1", "2026-04-15", "Eagles 12U",
		[]string{"john smith"}, nil,
	)

	markers, err := s.CrossReferenceRoster(context.Background(),
		"Eagles 12U", []string{"JOHN SMITH"})
	if err != nil {
		t.Fatalf("CrossReferenceRoster: %v", err)
	}
	if len(markers["JOHN SMITH"]) != 1 {
		t.Fatalf("case-insensitive name match: got %d, want 1", len(markers["JOHN SMITH"]))
	}
}

func TestCrossReferenceRoster_CaseInsensitiveOpponent(t *testing.T) {
	s := newMemStore(t)
	seedHistoricalGame(t, s,
		"g1", "2026-04-15", "Eagles 12U",
		[]string{"John Smith"}, nil,
	)

	markers, err := s.CrossReferenceRoster(context.Background(),
		"eagles 12u", []string{"John Smith"})
	if err != nil {
		t.Fatalf("CrossReferenceRoster: %v", err)
	}
	if len(markers["John Smith"]) != 1 {
		t.Fatalf("case-insensitive opponent match: got %d, want 1", len(markers["John Smith"]))
	}
}

// TestCrossReferenceRoster_TeamScopedAntiFalsePositive verifies the
// team-scoped join introduced by eng-review: a player with the same name
// who played against a DIFFERENT historical opponent must NOT surface.
func TestCrossReferenceRoster_TeamScopedAntiFalsePositive(t *testing.T) {
	s := newMemStore(t)
	// Own team played "Tigers" with a "John Smith" — this should NOT show
	// up when scouting "Eagles 12U" even though the name matches.
	seedHistoricalGame(t, s,
		"g1", "2026-04-15", "Tigers",
		[]string{"John Smith"}, nil,
	)

	markers, err := s.CrossReferenceRoster(context.Background(),
		"Eagles 12U", []string{"John Smith"})
	if err != nil {
		t.Fatalf("CrossReferenceRoster: %v", err)
	}
	if len(markers["John Smith"]) != 0 {
		t.Fatalf("anti-false-positive: John Smith in Tigers history should NOT surface for Eagles 12U scout; got %d markers", len(markers["John Smith"]))
	}
}

func TestCrossReferenceRoster_MultipleGames(t *testing.T) {
	s := newMemStore(t)
	seedHistoricalGame(t, s, "g1", "2026-04-15", "Eagles 12U", []string{"John Smith"}, nil)
	seedHistoricalGame(t, s, "g2", "2026-05-01", "Eagles 12U", []string{"John Smith"}, nil)

	markers, err := s.CrossReferenceRoster(context.Background(),
		"Eagles 12U", []string{"John Smith"})
	if err != nil {
		t.Fatalf("CrossReferenceRoster: %v", err)
	}
	if len(markers["John Smith"]) != 2 {
		t.Fatalf("multiple-games: got %d markers, want 2", len(markers["John Smith"]))
	}
	// Order: most recent first.
	if markers["John Smith"][0].GameDate != "2026-05-01" {
		t.Errorf("markers should be ordered DESC by date; got %q first, want 2026-05-01", markers["John Smith"][0].GameDate)
	}
}

func TestCrossReferenceRoster_BatterAndPitcherSameGame(t *testing.T) {
	// A player who both batted AND pitched in the same historical game
	// should surface exactly one marker for that game, not two.
	s := newMemStore(t)
	seedHistoricalGame(t, s,
		"g1", "2026-04-15", "Eagles 12U",
		[]string{"John Smith"}, []string{"John Smith"},
	)

	markers, err := s.CrossReferenceRoster(context.Background(),
		"Eagles 12U", []string{"John Smith"})
	if err != nil {
		t.Fatalf("CrossReferenceRoster: %v", err)
	}
	if len(markers["John Smith"]) != 1 {
		t.Fatalf("dedup batter+pitcher same game: got %d markers, want 1", len(markers["John Smith"]))
	}
}

func TestCrossReferenceRoster_PunctuationDoesNotMatch(t *testing.T) {
	// Exact-match-only-after-case-normalization: punctuation/jersey-suffix
	// differences should NOT match. Fuzzy match is deferred to v2 per
	// origin AE2.
	s := newMemStore(t)
	seedHistoricalGame(t, s,
		"g1", "2026-04-15", "Eagles 12U",
		[]string{"John Smith"}, nil,
	)

	markers, err := s.CrossReferenceRoster(context.Background(),
		"Eagles 12U", []string{"John Smith Jr."})
	if err != nil {
		t.Fatalf("CrossReferenceRoster: %v", err)
	}
	if len(markers["John Smith Jr."]) != 0 {
		t.Fatalf("punctuation should not match: got %d markers", len(markers["John Smith Jr."]))
	}
}

func TestCrossReferenceRoster_EmptyInputs(t *testing.T) {
	s := newMemStore(t)
	seedHistoricalGame(t, s, "g1", "2026-04-15", "Eagles 12U", []string{"John Smith"}, nil)
	ctx := context.Background()

	t.Run("empty roster names", func(t *testing.T) {
		markers, err := s.CrossReferenceRoster(ctx, "Eagles 12U", nil)
		if err != nil {
			t.Fatalf("err: %v", err)
		}
		if len(markers) != 0 {
			t.Errorf("empty roster names should return empty map; got %d entries", len(markers))
		}
	})

	t.Run("empty opposing team name", func(t *testing.T) {
		markers, err := s.CrossReferenceRoster(ctx, "", []string{"John Smith"})
		if err != nil {
			t.Fatalf("err: %v", err)
		}
		if len(markers) != 0 {
			t.Errorf("empty opposing team name should return empty map; got %d entries", len(markers))
		}
	})
}

func TestCrossReferenceRoster_NoMatches(t *testing.T) {
	s := newMemStore(t)
	seedHistoricalGame(t, s, "g1", "2026-04-15", "Eagles 12U", []string{"Other Player"}, nil)

	markers, err := s.CrossReferenceRoster(context.Background(),
		"Eagles 12U", []string{"John Smith", "Sam Adams"})
	if err != nil {
		t.Fatalf("CrossReferenceRoster: %v", err)
	}
	// No matches → empty map (no entries for any input name).
	for _, name := range []string{"John Smith", "Sam Adams"} {
		if len(markers[name]) != 0 {
			t.Errorf("name %q should have no markers; got %d", name, len(markers[name]))
		}
	}
}

func TestCrossReferenceRoster_EmptyOwnTeamCache(t *testing.T) {
	// No games seeded: cross-reference returns zero markers, no error.
	s := newMemStore(t)
	markers, err := s.CrossReferenceRoster(context.Background(),
		"Eagles 12U", []string{"John Smith"})
	if err != nil {
		t.Fatalf("CrossReferenceRoster on empty cache: %v", err)
	}
	if len(markers["John Smith"]) != 0 {
		t.Errorf("empty cache should yield no markers; got %d", len(markers["John Smith"]))
	}
}

// ─── Opposing-team cache tests (U6, Fork A) ────────────────────────────────

func TestUpsertOpposingTeam_InsertAndUpdate(t *testing.T) {
	s := newMemStore(t)
	ctx := context.Background()
	team := OpposingTeam{TeamUUID: "opp-1", TeamName: "Eagles 12U", LastFetchedAt: "2026-05-15T18:00:00Z"}
	if err := s.UpsertOpposingTeam(ctx, team); err != nil {
		t.Fatalf("first upsert: %v", err)
	}
	got, err := s.FindOpposingTeamByUUID(ctx, "opp-1")
	if err != nil || got == nil {
		t.Fatalf("FindOpposingTeamByUUID: %v / nil=%v", err, got == nil)
	}
	if got.TeamName != "Eagles 12U" {
		t.Errorf("first read TeamName = %q", got.TeamName)
	}
	// Update: same UUID, new name + timestamp.
	if err := s.UpsertOpposingTeam(ctx, OpposingTeam{
		TeamUUID: "opp-1", TeamName: "Eagles 12U Blue", LastFetchedAt: "2026-05-15T19:00:00Z",
	}); err != nil {
		t.Fatalf("update: %v", err)
	}
	got, _ = s.FindOpposingTeamByUUID(ctx, "opp-1")
	if got.TeamName != "Eagles 12U Blue" {
		t.Errorf("after update, TeamName = %q; want Eagles 12U Blue", got.TeamName)
	}
}

func TestUpsertOpposingTeam_EmptyUUID(t *testing.T) {
	s := newMemStore(t)
	if err := s.UpsertOpposingTeam(context.Background(), OpposingTeam{TeamName: "x"}); err == nil {
		t.Errorf("expected error on empty UUID")
	}
}

func TestFindOpposingTeam_NotFound(t *testing.T) {
	s := newMemStore(t)
	ctx := context.Background()
	got, err := s.FindOpposingTeamByUUID(ctx, "missing")
	if err != nil || got != nil {
		t.Errorf("missing UUID should return (nil, nil); got (%v, %v)", got, err)
	}
	got, err = s.FindOpposingTeamByName(ctx, "missing")
	if err != nil || got != nil {
		t.Errorf("missing name should return (nil, nil); got (%v, %v)", got, err)
	}
}

func TestFindOpposingTeamByName_CaseInsensitive(t *testing.T) {
	s := newMemStore(t)
	ctx := context.Background()
	_ = s.UpsertOpposingTeam(ctx, OpposingTeam{TeamUUID: "opp-1", TeamName: "Eagles 12U", LastFetchedAt: "2026-05-15T18:00:00Z"})
	for _, query := range []string{"eagles 12u", "EAGLES 12U", "Eagles 12U"} {
		got, err := s.FindOpposingTeamByName(ctx, query)
		if err != nil {
			t.Fatalf("query %q: %v", query, err)
		}
		if got == nil || got.TeamUUID != "opp-1" {
			t.Errorf("query %q: got %v; want opp-1", query, got)
		}
	}
}

func TestFindOpposingTeamByName_MostRecentOnCollision(t *testing.T) {
	s := newMemStore(t)
	ctx := context.Background()
	_ = s.UpsertOpposingTeam(ctx, OpposingTeam{TeamUUID: "opp-old", TeamName: "Hawks", LastFetchedAt: "2025-01-01T00:00:00Z"})
	_ = s.UpsertOpposingTeam(ctx, OpposingTeam{TeamUUID: "opp-new", TeamName: "Hawks", LastFetchedAt: "2026-05-15T18:00:00Z"})
	got, err := s.FindOpposingTeamByName(ctx, "Hawks")
	if err != nil {
		t.Fatal(err)
	}
	if got.TeamUUID != "opp-new" {
		t.Errorf("on name collision, want most-recent UUID (opp-new); got %s", got.TeamUUID)
	}
}
