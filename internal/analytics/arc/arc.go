// Package arc ports lib/gamechanger/development_arc.rb to Go.
//
// PIPELINE
//
//	rows ──> BuildSummary ──> []PlayerArc (no sparklines)
//	                              │
//	                              ├── buildArc:
//	                              │     ├── trendIndicator  ──> '↑' / '↓' / '→' / nil
//	                              │     └── narrativeFor    ──> 5 archetypes (bat & pitch)
//	                              │           ├─ < MIN_RECENT_GAMES        → "Building their game"
//	                              │           ├─ delta >  threshold        → "Peaking" / "Strike command sharpening"
//	                              │           ├─ delta < -threshold        → "Strong starter" / "Strong start"
//	                              │           ├─ recent >> first_half      → "Finding their groove"
//	                              │           └─ else                      → "Steady contributor" / "Consistent command"
//	                              │
//	BuildPlayer(summary, bat[], pitch[]) ──> PlayerArc with sparklines
//	                                              │
//	                                              └── SparklineFor: ▁▂▃▄▅▆▇█ scaled to per-player min/max
package arc

import (
	"fmt"
	"math"
)

// Thresholds match Ruby DevelopmentArc::NARRATIVE_THRESHOLD and ::MIN_RECENT_GAMES.
const (
	narrativeThreshold = 0.050 // 50 OBP points or 5 strike% points
	minRecentGames     = 5
)

// sparklineChars matches Ruby DevelopmentArc::SPARKLINE_CHARS verbatim.
var sparklineChars = []rune{'▁', '▂', '▃', '▄', '▅', '▆', '▇', '█'}

// PlayerArc mirrors Ruby Gamechanger::PlayerArc Struct.
// Optional fields use pointers so JSON marshaling produces null where Ruby produces nil.
type PlayerArc struct {
	PlayerName          string   `json:"player_name"`
	FirstHalfOBP        *float64 `json:"first_half_obp"`
	SecondHalfOBP       *float64 `json:"second_half_obp"`
	RecentOBP           *float64 `json:"recent_obp"`
	TotalGamesBatted    *int     `json:"total_games_batted"`
	FirstHalfStrikePct  *float64 `json:"first_half_strike_pct"`
	SecondHalfStrikePct *float64 `json:"second_half_strike_pct"`
	RecentStrikePct     *float64 `json:"recent_strike_pct"`
	TotalGamesPitched   *int     `json:"total_games_pitched"`
	BatSparkline        string   `json:"bat_sparkline"`
	PitchSparkline      string   `json:"pitch_sparkline"`
	BatTrend            *string  `json:"bat_trend"`
	PitchTrend          *string  `json:"pitch_trend"`
	BatNarrative        *string  `json:"bat_narrative"`
	PitchNarrative      *string  `json:"pitch_narrative"`
}

// BuildSummary mirrors Ruby DevelopmentArc.build_summary.
func BuildSummary(rows []map[string]any) []PlayerArc {
	arcs := make([]PlayerArc, 0, len(rows))
	for _, r := range rows {
		arcs = append(arcs, buildArc(r))
	}
	return arcs
}

// BuildPlayer mirrors Ruby DevelopmentArc.build_player.
func BuildPlayer(summaryRow map[string]any, batRows, pitchRows []map[string]any) PlayerArc {
	arc := buildArc(summaryRow)
	arc.BatSparkline = SparklineFor(perGameOBPs(batRows))
	arc.PitchSparkline = SparklineFor(perOutingStrikePcts(pitchRows))
	return arc
}

func buildArc(r map[string]any) PlayerArc {
	firstHalfOBP := optFloat(r, "first_half_obp")
	secondHalfOBP := optFloat(r, "second_half_obp")
	recentOBP := optFloat(r, "recent_obp")
	totalBatted := optInt(r, "total_games_batted")

	firstHalfStrike := optFloat(r, "first_half_strike_pct")
	secondHalfStrike := optFloat(r, "second_half_strike_pct")
	recentStrike := optFloat(r, "recent_strike_pct")
	totalPitched := optInt(r, "total_games_pitched")

	return PlayerArc{
		PlayerName:          asString(r["player_name"]),
		FirstHalfOBP:        firstHalfOBP,
		SecondHalfOBP:       secondHalfOBP,
		RecentOBP:           recentOBP,
		TotalGamesBatted:    totalBatted,
		FirstHalfStrikePct:  firstHalfStrike,
		SecondHalfStrikePct: secondHalfStrike,
		RecentStrikePct:     recentStrike,
		TotalGamesPitched:   totalPitched,
		BatSparkline:        "",
		PitchSparkline:      "",
		BatTrend:            trendIndicator(firstHalfOBP, secondHalfOBP),
		PitchTrend:          trendIndicator(firstHalfStrike, secondHalfStrike),
		BatNarrative:        narrativeFor(firstHalfOBP, secondHalfOBP, recentOBP, totalBatted, "bat"),
		PitchNarrative:      narrativeFor(firstHalfStrike, secondHalfStrike, recentStrike, totalPitched, "pitch"),
	}
}

// trendIndicator mirrors Ruby private_class_method .trend_indicator.
// Returns nil unless BOTH halves are present.
func trendIndicator(first, second *float64) *string {
	if first == nil || second == nil {
		return nil
	}
	delta := *second - *first
	var out string
	switch {
	case delta > narrativeThreshold:
		out = "↑"
	case delta < -narrativeThreshold:
		out = "↓"
	default:
		out = "→"
	}
	return &out
}

// narrativeFor mirrors Ruby private_class_method .narrative_for.
// Returns nil only when BOTH halves are nil (matches Ruby's `return nil unless first_half || second_half`).
// `kind` is "bat" or "pitch" — Ruby uses a symbol; Go uses a string for the same dispatch.
func narrativeFor(firstHalf, secondHalf, recent *float64, total *int, kind string) *string {
	if firstHalf == nil && secondHalf == nil {
		return nil
	}
	totalVal := 0
	if total != nil {
		totalVal = *total
	}
	var out string
	if totalVal < minRecentGames {
		if kind == "bat" {
			out = "Building their game — more at-bats will tell the full story"
		} else {
			out = "Building their game — more outings will tell the full story"
		}
		return &out
	}
	// Ruby: delta = (second_half || first_half).to_f - (first_half || second_half).to_f
	// When only one half is set, delta is 0 → falls through to "Steady/Consistent" branch.
	secondOrFirst := firstNonNilFloat(secondHalf, firstHalf)
	firstOrSecond := firstNonNilFloat(firstHalf, secondHalf)
	delta := secondOrFirst - firstOrSecond

	if kind == "bat" {
		switch {
		case delta > narrativeThreshold:
			out = fmt.Sprintf("Peaking at the right time — OBP up .%03d in the second half", int(math.Round(delta*1000)))
		case delta < -narrativeThreshold:
			out = "Strong starter — coaching opportunity to recapture early-season form"
		case recent != nil && firstHalf != nil && (*recent-*firstHalf) > narrativeThreshold:
			out = fmt.Sprintf("Finding their groove — .%03d OBP over last 5 games", int(math.Round(*recent*1000)))
		default:
			firstVal := 0.0
			if firstHalf != nil {
				firstVal = *firstHalf
			}
			seasonAvg := (firstVal + secondOrFirst) / 2.0
			out = fmt.Sprintf("Steady contributor — .%03d OBP all season", int(math.Round(seasonAvg*1000)))
		}
	} else {
		switch {
		case delta > narrativeThreshold:
			out = fmt.Sprintf("Strike command sharpening — %d percentage points gained this half", int(math.Round(delta*100)))
		case delta < -narrativeThreshold:
			out = "Strong start — coaching opportunity to recapture early-season command"
		case recent != nil && firstHalf != nil && (*recent-*firstHalf) > narrativeThreshold:
			out = fmt.Sprintf("Finding their groove — %d%% strike rate over last 5 outings", int(math.Round(*recent*100)))
		default:
			firstVal := 0.0
			if firstHalf != nil {
				firstVal = *firstHalf
			}
			seasonAvg := (firstVal + secondOrFirst) / 2.0
			out = fmt.Sprintf("Consistent command — %d%% strike rate all season", int(math.Round(seasonAvg*100)))
		}
	}
	return &out
}

// SparklineFor mirrors Ruby .sparkline_for. Empty input → empty string.
// Flat values → all middle bucket (▄). Otherwise scales to per-player min/max across 8 buckets.
func SparklineFor(values []float64) string {
	if len(values) == 0 {
		return ""
	}
	min, max := values[0], values[0]
	for _, v := range values {
		if v < min {
			min = v
		}
		if v > max {
			max = v
		}
	}
	span := max - min
	out := make([]rune, 0, len(values))
	for _, v := range values {
		var idx int
		if span == 0 {
			idx = 3 // matches Ruby's middle-bucket choice
		} else {
			idx = int(math.Round((v - min) / span * 7))
			if idx < 0 {
				idx = 0
			} else if idx > 7 {
				idx = 7
			}
		}
		out = append(out, sparklineChars[idx])
	}
	return string(out)
}

// ─── private helpers (Ruby-side: `.to_f`, `.to_i`, `&.to_f` semantics) ───────

func optFloat(r map[string]any, key string) *float64 {
	v, ok := r[key]
	if !ok || v == nil {
		return nil
	}
	switch t := v.(type) {
	case float64:
		return &t
	case float32:
		f := float64(t)
		return &f
	case int:
		f := float64(t)
		return &f
	case int64:
		f := float64(t)
		return &f
	}
	return nil
}

func optInt(r map[string]any, key string) *int {
	v, ok := r[key]
	if !ok || v == nil {
		return nil
	}
	switch t := v.(type) {
	case int:
		return &t
	case int64:
		i := int(t)
		return &i
	case float64:
		i := int(t)
		return &i
	}
	return nil
}

func asString(v any) string {
	if s, ok := v.(string); ok {
		return s
	}
	return ""
}

func firstNonNilFloat(a, b *float64) float64 {
	if a != nil {
		return *a
	}
	if b != nil {
		return *b
	}
	return 0
}

func perGameOBPs(rows []map[string]any) []float64 {
	out := make([]float64, 0, len(rows))
	for _, r := range rows {
		hits := asFloat(r["hits"])
		walks := asFloat(r["walks"])
		ab := asFloat(r["at_bats"])
		denom := ab + walks
		if denom == 0 {
			out = append(out, 0)
		} else {
			out = append(out, (hits+walks)/denom)
		}
	}
	return out
}

func perOutingStrikePcts(rows []map[string]any) []float64 {
	out := make([]float64, 0, len(rows))
	for _, r := range rows {
		pitches := asFloat(r["pitches_thrown"])
		strikes := asFloat(r["strikes_thrown"])
		if pitches == 0 {
			out = append(out, 0)
		} else {
			out = append(out, strikes/pitches)
		}
	}
	return out
}

func asFloat(v any) float64 {
	switch t := v.(type) {
	case float64:
		return t
	case float32:
		return float64(t)
	case int:
		return float64(t)
	case int64:
		return float64(t)
	}
	return 0
}
