package parser

import "testing"

func sampleResponse() map[string]any {
	return map[string]any{
		"wGP47FexatoQ": map[string]any{
			"players": []any{
				map[string]any{"id": "p1", "first_name": "Asher", "last_name": "Lima"},
				map[string]any{"id": "p2", "first_name": "Mason", "last_name": "Marrero"},
			},
			"groups": []any{
				map[string]any{
					"category": "pitching",
					"extra": []any{
						map[string]any{
							"stat_name": "#P",
							"stats": []any{
								map[string]any{"player_id": "p1", "value": float64(59)},
								map[string]any{"player_id": "p2", "value": "25"},
							},
						},
						map[string]any{
							"stat_name": "TS",
							"stats": []any{
								map[string]any{"player_id": "p1", "value": float64(38)},
							},
						},
					},
					"stats": []any{
						map[string]any{
							"player_id": "p1",
							"stats":     map[string]any{"IP": float64(4.0)},
						},
					},
				},
				map[string]any{
					"category": "lineup",
					"stats": []any{
						map[string]any{
							"player_id": "p2",
							"stats":     map[string]any{"AB": float64(3), "H": float64(2), "BB": float64(1), "K": float64(0)},
						},
					},
				},
			},
		},
	}
}

func TestPitcherStats(t *testing.T) {
	stats, err := PitcherStats(sampleResponse(), "wGP47FexatoQ")
	if err != nil {
		t.Fatalf("PitcherStats: %v", err)
	}
	if len(stats) != 2 {
		t.Fatalf("len = %d; want 2", len(stats))
	}

	asher := stats[0]
	if asher.PitcherName != "Asher Lima" {
		t.Fatalf("name = %q", asher.PitcherName)
	}
	if asher.PitchesThrown != 59 {
		t.Fatalf("pitches = %d", asher.PitchesThrown)
	}
	if !asher.StrikesThrown.Valid || asher.StrikesThrown.Int64 != 38 {
		t.Fatalf("strikes = %v", asher.StrikesThrown)
	}
	if !asher.InningsPitched.Valid || asher.InningsPitched.Float64 != 4.0 {
		t.Fatalf("IP = %v", asher.InningsPitched)
	}

	mason := stats[1]
	if mason.PitchesThrown != 25 {
		t.Fatalf("mason pitches (from string value) = %d; want 25", mason.PitchesThrown)
	}
	if mason.StrikesThrown.Valid {
		t.Fatalf("mason strikes should be null (no TS entry)")
	}
}

func TestBatterStats(t *testing.T) {
	stats, err := BatterStats(sampleResponse(), "wGP47FexatoQ")
	if err != nil {
		t.Fatalf("BatterStats: %v", err)
	}
	if len(stats) != 1 {
		t.Fatalf("len = %d; want 1", len(stats))
	}
	b := stats[0]
	if b.BatterName != "Mason Marrero" || b.AtBats != 3 || b.Hits != 2 || b.Walks != 1 || b.Strikeouts != 0 {
		t.Fatalf("batter row = %+v", b)
	}
}

func TestPitcherStats_MissingTeamReturnsError(t *testing.T) {
	_, err := PitcherStats(map[string]any{"other": map[string]any{}}, "wGP47FexatoQ")
	if err == nil {
		t.Fatalf("expected error for missing team slug")
	}
}

func TestPitcherStats_NoPitchingGroupReturnsNil(t *testing.T) {
	resp := map[string]any{
		"slug": map[string]any{
			"players": []any{},
			"groups":  []any{},
		},
	}
	stats, err := PitcherStats(resp, "slug")
	if err != nil {
		t.Fatalf("err: %v", err)
	}
	if stats != nil {
		t.Fatalf("expected nil for missing pitching group; got %+v", stats)
	}
}

func TestBatterStats_NoLineupGroupReturnsNil(t *testing.T) {
	resp := map[string]any{
		"slug": map[string]any{
			"players": []any{},
			"groups":  []any{},
		},
	}
	stats, err := BatterStats(resp, "slug")
	if err != nil {
		t.Fatalf("err: %v", err)
	}
	if stats != nil {
		t.Fatalf("expected nil for missing lineup group; got %+v", stats)
	}
}
