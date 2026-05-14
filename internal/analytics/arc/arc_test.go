package arc

import (
	"strings"
	"testing"
)

// Helpers for building optional values that mirror Ruby's nil-vs-set distinction.
func f64ptr(v float64) *float64 { return &v }
func intptr(v int) *int         { return &v }

// rowOpt describes a single PlayerArc input row in the storage-shaped form
// returned by Storage#all_player_development_summary. Mirrors Ruby spec helpers.
type rowOpt struct {
	playerName          string
	firstHalfOBP        *float64
	secondHalfOBP       *float64
	recentOBP           *float64
	totalGamesBatted    *int
	firstHalfStrikePct  *float64
	secondHalfStrikePct *float64
	recentStrikePct     *float64
	totalGamesPitched   *int
}

func (r rowOpt) toRow() map[string]any {
	row := map[string]any{
		"player_name":              r.playerName,
		"first_half_obp":           pointerToAny(r.firstHalfOBP),
		"second_half_obp":          pointerToAny(r.secondHalfOBP),
		"recent_obp":               pointerToAny(r.recentOBP),
		"total_games_batted":       pointerToAny(r.totalGamesBatted),
		"first_half_strike_pct":    pointerToAny(r.firstHalfStrikePct),
		"second_half_strike_pct":   pointerToAny(r.secondHalfStrikePct),
		"recent_strike_pct":        pointerToAny(r.recentStrikePct),
		"total_games_pitched":      pointerToAny(r.totalGamesPitched),
	}
	return row
}

func pointerToAny(v any) any {
	switch p := v.(type) {
	case *float64:
		if p == nil {
			return nil
		}
		return *p
	case *int:
		if p == nil {
			return nil
		}
		return *p
	}
	return v
}

// ─── SparklineFor (Ruby DevelopmentArc.sparkline_for) ────────────────────────

func TestSparklineFor_EmptyInput(t *testing.T) {
	if got := SparklineFor(nil); got != "" {
		t.Errorf("nil input: want empty string, got %q", got)
	}
	if got := SparklineFor([]float64{}); got != "" {
		t.Errorf("empty input: want empty string, got %q", got)
	}
}

func TestSparklineFor_FlatValues(t *testing.T) {
	// All-same values → middle bucket (▄) repeated for input length.
	got := SparklineFor([]float64{0.3, 0.3, 0.3})
	if got != "▄▄▄" {
		t.Errorf("flat values: want %q, got %q", "▄▄▄", got)
	}
}

func TestSparklineFor_RisingTrend(t *testing.T) {
	got := SparklineFor([]float64{0.1, 0.3, 0.5, 0.7, 0.9})
	runes := []rune(got)
	if len(runes) == 0 {
		t.Fatalf("rising: expected non-empty result")
	}
	if string(runes[0]) != "▁" {
		t.Errorf("rising: first char want %q, got %q", "▁", string(runes[0]))
	}
	if string(runes[len(runes)-1]) != "█" {
		t.Errorf("rising: last char want %q, got %q", "█", string(runes[len(runes)-1]))
	}
}

func TestSparklineFor_FallingTrend(t *testing.T) {
	got := SparklineFor([]float64{0.9, 0.7, 0.5, 0.3, 0.1})
	runes := []rune(got)
	if string(runes[0]) != "█" {
		t.Errorf("falling: first char want %q, got %q", "█", string(runes[0]))
	}
	if string(runes[len(runes)-1]) != "▁" {
		t.Errorf("falling: last char want %q, got %q", "▁", string(runes[len(runes)-1]))
	}
}

func TestSparklineFor_LengthPreservation(t *testing.T) {
	values := []float64{0.2, 0.4, 0.3, 0.5, 0.4, 0.6}
	got := SparklineFor(values)
	if got_runes := []rune(got); len(got_runes) != len(values) {
		t.Errorf("length: want %d, got %d", len(values), len(got_runes))
	}
}

func TestSparklineFor_OnlySparklineChars(t *testing.T) {
	values := []float64{0.1, 0.2, 0.3, 0.4, 0.5, 0.6, 0.7, 0.8, 0.9, 1.0}
	got := SparklineFor(values)
	allowed := "▁▂▃▄▅▆▇█"
	for _, r := range got {
		if !strings.ContainsRune(allowed, r) {
			t.Errorf("found non-sparkline char %q in output %q", r, got)
		}
	}
}

// ─── BuildSummary trends (Ruby trend_indicator) ──────────────────────────────

func TestBuildSummary_BatTrend(t *testing.T) {
	tests := []struct {
		name           string
		firstHalfOBP   *float64
		secondHalfOBP  *float64
		wantTrend      *string
	}{
		{
			name:          "↑ when second half OBP > first by 0.050+",
			firstHalfOBP:  f64ptr(0.271),
			secondHalfOBP: f64ptr(0.338),
			wantTrend:     strptr("↑"),
		},
		{
			name:          "↓ when second half OBP < first by 0.050+",
			firstHalfOBP:  f64ptr(0.380),
			secondHalfOBP: f64ptr(0.210),
			wantTrend:     strptr("↓"),
		},
		{
			name:          "→ when delta within threshold (0.050)",
			firstHalfOBP:  f64ptr(0.300),
			secondHalfOBP: f64ptr(0.310),
			wantTrend:     strptr("→"),
		},
		{
			name:          "nil when first_half missing",
			firstHalfOBP:  nil,
			secondHalfOBP: f64ptr(0.300),
			wantTrend:     nil,
		},
		{
			name:          "nil when second_half missing",
			firstHalfOBP:  f64ptr(0.300),
			secondHalfOBP: nil,
			wantTrend:     nil,
		},
	}

	for _, tc := range tests {
		t.Run(tc.name, func(t *testing.T) {
			row := rowOpt{
				playerName:       "Test",
				firstHalfOBP:     tc.firstHalfOBP,
				secondHalfOBP:    tc.secondHalfOBP,
				totalGamesBatted: intptr(10),
			}
			arcs := BuildSummary([]map[string]any{row.toRow()})
			if len(arcs) != 1 {
				t.Fatalf("BuildSummary returned %d arcs, want 1", len(arcs))
			}
			got := arcs[0].BatTrend
			switch {
			case tc.wantTrend == nil && got != nil:
				t.Errorf("BatTrend: want nil, got %q", *got)
			case tc.wantTrend != nil && got == nil:
				t.Errorf("BatTrend: want %q, got nil", *tc.wantTrend)
			case tc.wantTrend != nil && got != nil && *tc.wantTrend != *got:
				t.Errorf("BatTrend: want %q, got %q", *tc.wantTrend, *got)
			}
		})
	}
}

func strptr(s string) *string { return &s }

// ─── BuildSummary nil handling ───────────────────────────────────────────────

func TestBuildSummary_NoPitchingData_NilPitchTrendAndNarrative(t *testing.T) {
	row := rowOpt{
		playerName:       "Jayden",
		firstHalfOBP:     f64ptr(0.271),
		secondHalfOBP:    f64ptr(0.338),
		recentOBP:        f64ptr(0.400),
		totalGamesBatted: intptr(12),
		// No pitching fields set.
	}
	arcs := BuildSummary([]map[string]any{row.toRow()})
	if len(arcs) != 1 {
		t.Fatalf("want 1 arc, got %d", len(arcs))
	}
	if arcs[0].PitchTrend != nil {
		t.Errorf("PitchTrend: want nil, got %v", *arcs[0].PitchTrend)
	}
	if arcs[0].PitchNarrative != nil {
		t.Errorf("PitchNarrative: want nil, got %v", *arcs[0].PitchNarrative)
	}
	if arcs[0].BatSparkline != "" {
		t.Errorf("BatSparkline: want empty, got %q", arcs[0].BatSparkline)
	}
}

func TestBuildSummary_ReturnsOneArcPerRow(t *testing.T) {
	improving := rowOpt{playerName: "Jayden", firstHalfOBP: f64ptr(0.271), secondHalfOBP: f64ptr(0.338),
		recentOBP: f64ptr(0.400), totalGamesBatted: intptr(12)}
	declining := rowOpt{playerName: "Marcus", firstHalfOBP: f64ptr(0.380), secondHalfOBP: f64ptr(0.210),
		recentOBP: f64ptr(0.400), totalGamesBatted: intptr(12)}
	arcs := BuildSummary([]map[string]any{improving.toRow(), declining.toRow()})
	if len(arcs) != 2 {
		t.Errorf("want 2 arcs, got %d", len(arcs))
	}
	if arcs[0].PlayerName != "Jayden" || arcs[1].PlayerName != "Marcus" {
		t.Errorf("PlayerName order: want [Jayden Marcus], got [%s %s]", arcs[0].PlayerName, arcs[1].PlayerName)
	}
}

// ─── BuildSummary narratives (bat) ───────────────────────────────────────────
// Each test asserts the narrative MATCHES a Ruby-side substring, not exact equality,
// because narratives use Ruby's `format` with computed values.

func TestBuildSummary_BatNarrative(t *testing.T) {
	tests := []struct {
		name        string
		firstHalf   *float64
		secondHalf  *float64
		recent      *float64
		total       *int
		wantSubstr  string
	}{
		{
			name: "Peaking when second half strongly better",
			firstHalf: f64ptr(0.270), secondHalf: f64ptr(0.340), recent: f64ptr(0.400),
			total: intptr(10), wantSubstr: "Peaking at the right time",
		},
		{
			name: "Strong starter when first half strongly better",
			firstHalf: f64ptr(0.380), secondHalf: f64ptr(0.290), recent: f64ptr(0.280),
			total: intptr(10), wantSubstr: "Strong starter",
		},
		{
			name: "Finding their groove when recent >> first_half but halves similar",
			firstHalf: f64ptr(0.280), secondHalf: f64ptr(0.290), recent: f64ptr(0.410),
			total: intptr(10), wantSubstr: "Finding their groove",
		},
		{
			name: "Steady contributor when delta within threshold",
			firstHalf: f64ptr(0.300), secondHalf: f64ptr(0.310), recent: f64ptr(0.305),
			total: intptr(10), wantSubstr: "Steady contributor",
		},
		{
			name: "Building their game when total_games < MIN_RECENT_GAMES",
			firstHalf: f64ptr(0.300), secondHalf: f64ptr(0.400), recent: f64ptr(0.400),
			total: intptr(3), wantSubstr: "Building their game",
		},
	}
	for _, tc := range tests {
		t.Run(tc.name, func(t *testing.T) {
			row := rowOpt{
				playerName:       "Test",
				firstHalfOBP:     tc.firstHalf,
				secondHalfOBP:    tc.secondHalf,
				recentOBP:        tc.recent,
				totalGamesBatted: tc.total,
			}
			arcs := BuildSummary([]map[string]any{row.toRow()})
			if len(arcs) != 1 || arcs[0].BatNarrative == nil {
				t.Fatalf("expected one arc with BatNarrative set, got %+v", arcs)
			}
			if !strings.Contains(*arcs[0].BatNarrative, tc.wantSubstr) {
				t.Errorf("BatNarrative: want substring %q, got %q", tc.wantSubstr, *arcs[0].BatNarrative)
			}
		})
	}
}

// ─── BuildSummary narratives (pitch) ─────────────────────────────────────────

func TestBuildSummary_PitchNarrative(t *testing.T) {
	tests := []struct {
		name       string
		firstHalf  *float64
		secondHalf *float64
		recent     *float64
		total      *int
		wantSubstr string
	}{
		{
			name: "Strike command sharpening when second half strongly better",
			firstHalf: f64ptr(0.58), secondHalf: f64ptr(0.67), recent: f64ptr(0.70),
			total: intptr(8), wantSubstr: "Strike command sharpening",
		},
		{
			name: "Strong start when first half strongly better",
			firstHalf: f64ptr(0.65), secondHalf: f64ptr(0.55), recent: f64ptr(0.50),
			total: intptr(8), wantSubstr: "Strong start",
		},
		{
			name: "Finding their groove when pitcher recent >> first_half but halves similar",
			firstHalf: f64ptr(0.60), secondHalf: f64ptr(0.62), recent: f64ptr(0.68),
			total: intptr(8), wantSubstr: "Finding their groove",
		},
		{
			name: "Consistent command when steady",
			firstHalf: f64ptr(0.60), secondHalf: f64ptr(0.62), recent: f64ptr(0.62),
			total: intptr(8), wantSubstr: "Consistent command",
		},
		{
			name: "Building their game when pitcher outings < MIN_RECENT_GAMES",
			firstHalf: f64ptr(0.58), secondHalf: f64ptr(0.67), recent: f64ptr(0.70),
			total: intptr(3), wantSubstr: "Building their game",
		},
	}
	for _, tc := range tests {
		t.Run(tc.name, func(t *testing.T) {
			row := rowOpt{
				playerName:          "Test",
				firstHalfStrikePct:  tc.firstHalf,
				secondHalfStrikePct: tc.secondHalf,
				recentStrikePct:     tc.recent,
				totalGamesPitched:   tc.total,
			}
			arcs := BuildSummary([]map[string]any{row.toRow()})
			if len(arcs) != 1 || arcs[0].PitchNarrative == nil {
				t.Fatalf("expected one arc with PitchNarrative set, got %+v", arcs)
			}
			if !strings.Contains(*arcs[0].PitchNarrative, tc.wantSubstr) {
				t.Errorf("PitchNarrative: want substring %q, got %q", tc.wantSubstr, *arcs[0].PitchNarrative)
			}
		})
	}
}

// ─── BuildPlayer (sparklines from per-game rows) ─────────────────────────────

func TestBuildPlayer_BatSparklineLength(t *testing.T) {
	summary := rowOpt{
		playerName:          "Jayden",
		firstHalfOBP:        f64ptr(0.271),
		secondHalfOBP:       f64ptr(0.338),
		recentOBP:           f64ptr(0.400),
		totalGamesBatted:    intptr(6),
		firstHalfStrikePct:  f64ptr(0.58),
		secondHalfStrikePct: f64ptr(0.67),
		recentStrikePct:     f64ptr(0.70),
		totalGamesPitched:   intptr(4),
	}.toRow()

	batRows := []map[string]any{
		{"hits": 1.0, "walks": 1.0, "at_bats": 4.0},
		{"hits": 2.0, "walks": 0.0, "at_bats": 3.0},
		{"hits": 1.0, "walks": 2.0, "at_bats": 4.0},
		{"hits": 2.0, "walks": 1.0, "at_bats": 3.0},
		{"hits": 3.0, "walks": 1.0, "at_bats": 4.0},
		{"hits": 3.0, "walks": 2.0, "at_bats": 4.0},
	}
	pitchRows := []map[string]any{
		{"pitches_thrown": 40.0, "strikes_thrown": 24.0},
		{"pitches_thrown": 45.0, "strikes_thrown": 28.0},
		{"pitches_thrown": 50.0, "strikes_thrown": 33.0},
		{"pitches_thrown": 48.0, "strikes_thrown": 32.0},
	}

	arc := BuildPlayer(summary, batRows, pitchRows)
	if got := len([]rune(arc.BatSparkline)); got != len(batRows) {
		t.Errorf("BatSparkline length: want %d, got %d", len(batRows), got)
	}
	if got := len([]rune(arc.PitchSparkline)); got != len(pitchRows) {
		t.Errorf("PitchSparkline length: want %d, got %d", len(pitchRows), got)
	}
}

func TestBuildPlayer_SparklineCharsOnly(t *testing.T) {
	summary := rowOpt{
		playerName:       "Jayden",
		firstHalfOBP:     f64ptr(0.271),
		secondHalfOBP:    f64ptr(0.338),
		totalGamesBatted: intptr(6),
	}.toRow()
	batRows := []map[string]any{
		{"hits": 1.0, "walks": 1.0, "at_bats": 4.0},
		{"hits": 2.0, "walks": 0.0, "at_bats": 3.0},
	}
	arc := BuildPlayer(summary, batRows, nil)
	allowed := "▁▂▃▄▅▆▇█"
	for _, r := range arc.BatSparkline {
		if !strings.ContainsRune(allowed, r) {
			t.Errorf("non-sparkline char %q in BatSparkline %q", r, arc.BatSparkline)
		}
	}
}

func TestBuildPlayer_EmptyBatRows(t *testing.T) {
	summary := rowOpt{
		playerName:       "Jayden",
		firstHalfOBP:     f64ptr(0.271),
		secondHalfOBP:    f64ptr(0.338),
		totalGamesBatted: intptr(6),
	}.toRow()
	arc := BuildPlayer(summary, nil, nil)
	if arc.BatSparkline != "" {
		t.Errorf("empty bat_rows: want empty sparkline, got %q", arc.BatSparkline)
	}
}
