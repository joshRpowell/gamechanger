package sync

import "testing"

func TestNormalizeStatus(t *testing.T) {
	cases := map[string]string{
		"":             "",
		"completed":    "final",
		"FINAL":        "final",
		"Game ended":   "final",
		"in_progress":  "in_progress",
		"live":         "in_progress",
		"Active":       "in_progress",
		"scheduled":    "scheduled",
		"upcoming":     "scheduled",
		"canceled":     "canceled", // not in switch — fallthrough lowercases
		"Postponed":    "postponed",
	}
	for in, want := range cases {
		got := normalizeStatus(in)
		if got != want {
			t.Errorf("normalizeStatus(%q) = %q; want %q", in, got, want)
		}
	}
}

func TestExtractGames_BareArray(t *testing.T) {
	raw := []any{
		map[string]any{"event": map[string]any{"event_type": "game", "id": "g1"}},
		map[string]any{"event": map[string]any{"event_type": "practice", "id": "p1"}},
	}
	games, err := extractGames(raw)
	if err != nil {
		t.Fatalf("extractGames: %v", err)
	}
	if len(games) != 1 {
		t.Fatalf("len = %d; want 1 (practice filtered)", len(games))
	}
}

func TestExtractGames_WrappedShapes(t *testing.T) {
	for _, key := range []string{"schedule", "events", "data"} {
		raw := map[string]any{
			key: []any{
				map[string]any{"event": map[string]any{"event_type": "game", "id": "g1"}},
			},
		}
		games, err := extractGames(raw)
		if err != nil {
			t.Errorf("%s shape: %v", key, err)
			continue
		}
		if len(games) != 1 {
			t.Errorf("%s shape: len = %d", key, len(games))
		}
	}
}

func TestExtractGames_UnknownShapeReturnsError(t *testing.T) {
	if _, err := extractGames("not a list"); err == nil {
		t.Fatal("expected error on string input")
	}
}

func TestParseGame_FullShape(t *testing.T) {
	item := map[string]any{
		"event": map[string]any{
			"id":         "abc-123",
			"event_type": "game",
			"start":      map[string]any{"datetime": "2026-03-15T18:30:00Z"},
			"status":     "Completed",
			"title":      "Title fallback",
		},
		"pregame_data": map[string]any{
			"opponent_name": "Crushers",
			"home_away":     "home",
		},
	}
	g, ok := parseGame(item)
	if !ok {
		t.Fatal("parseGame returned ok=false")
	}
	if g.gameID != "abc-123" || g.gameDate != "2026-03-15" ||
		g.opponent != "Crushers" || g.homeAway != "home" || g.status != "final" {
		t.Fatalf("parsed = %+v", g)
	}
}

func TestParseGame_FallsBackToEventTitle(t *testing.T) {
	item := map[string]any{
		"event": map[string]any{
			"id":     "g1",
			"start":  map[string]any{"date": "2026-04-01"},
			"status": "Scheduled",
			"title":  "Title fallback",
		},
	}
	g, ok := parseGame(item)
	if !ok {
		t.Fatal("parseGame ok=false")
	}
	if g.opponent != "Title fallback" {
		t.Fatalf("opponent = %q; want title fallback", g.opponent)
	}
	if g.gameDate != "2026-04-01" {
		t.Fatalf("gameDate = %q; want start.date fallback", g.gameDate)
	}
}

func TestParseGame_MissingIDReturnsFalse(t *testing.T) {
	item := map[string]any{"event": map[string]any{"event_type": "game"}}
	if _, ok := parseGame(item); ok {
		t.Fatal("parseGame ok=true with no id")
	}
}
