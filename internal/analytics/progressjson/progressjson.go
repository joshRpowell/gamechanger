// Package progressjson renders the Go-side `progress --format json` payload
// matching Ruby's Formatters::Json#progress shape.
//
// Both cmd/progress-json (the U1 pilot binary) and internal/commands/verify
// (the U6 harness) call Render so the byte output is identical between the
// pilot diff loop and the verify-parity harness.
package progressjson

import (
	"context"
	"database/sql"
	"encoding/json"
	"fmt"
	"math"
	"strconv"

	"github.com/joshrpowell/gamechanger-cli/internal/analytics/arc"
	"github.com/joshrpowell/gamechanger-cli/internal/store"
)

// Ruby JSON shape (from Formatters::Json#progress):
//
//	[{
//	  "player":   "Name",
//	  "batting":  {first_half_obp, second_half_obp, recent_obp, total_games, trend, sparkline, narrative},
//	  "pitching": {first_half_strike_pct, second_half_strike_pct, recent_strike_pct, total_outings, trend, sparkline, narrative}
//	}]

type progressEntry struct {
	Player   string          `json:"player"`
	Batting  battingPayload  `json:"batting"`
	Pitching pitchingPayload `json:"pitching"`
}

// rubyFloat mirrors Ruby's JSON.pretty_generate float formatting: whole
// numbers get an explicit ".0" suffix, fractional values use minimum precision.
// Without this, Go would emit `0` where Ruby emits `0.0` and the diff engine
// would flag drift on every batter with no recent games.
type rubyFloat struct{ v *float64 }

func (r rubyFloat) MarshalJSON() ([]byte, error) {
	if r.v == nil {
		return []byte("null"), nil
	}
	f := *r.v
	if f == math.Trunc(f) && !math.IsInf(f, 0) {
		return []byte(strconv.FormatFloat(f, 'f', 1, 64)), nil
	}
	return []byte(strconv.FormatFloat(f, 'f', -1, 64)), nil
}

type battingPayload struct {
	FirstHalfOBP  rubyFloat `json:"first_half_obp"`
	SecondHalfOBP rubyFloat `json:"second_half_obp"`
	RecentOBP     rubyFloat `json:"recent_obp"`
	TotalGames    *int      `json:"total_games"`
	Trend         *string   `json:"trend"`
	Sparkline     *string   `json:"sparkline"`
	Narrative     *string   `json:"narrative"`
}

type pitchingPayload struct {
	FirstHalfStrikePct  rubyFloat `json:"first_half_strike_pct"`
	SecondHalfStrikePct rubyFloat `json:"second_half_strike_pct"`
	RecentStrikePct     rubyFloat `json:"recent_strike_pct"`
	TotalOutings        *int      `json:"total_outings"`
	Trend               *string   `json:"trend"`
	Sparkline           *string   `json:"sparkline"`
	Narrative           *string   `json:"narrative"`
}

// Render opens the SQLite store at `dir` for `season`, loads the development
// summary, and returns the JSON-formatted payload as a byte slice (no trailing
// newline — callers add one if writing to a terminal).
func Render(ctx context.Context, dir string, season int) ([]byte, error) {
	s, err := store.OpenAt(ctx, dir, season)
	if err != nil {
		return nil, fmt.Errorf("open store: %w", err)
	}
	defer s.Close()

	rows, err := s.AllPlayerDevelopmentSummary(ctx)
	if err != nil {
		return nil, fmt.Errorf("load development summary: %w", err)
	}

	arcRows := make([]map[string]any, 0, len(rows))
	for _, r := range rows {
		arcRows = append(arcRows, map[string]any{
			"player_name":            r.PlayerName,
			"first_half_obp":         nullFloatToAny(r.FirstHalfOBP),
			"second_half_obp":        nullFloatToAny(r.SecondHalfOBP),
			"recent_obp":             nullFloatToAny(r.RecentOBP),
			"total_games_batted":     nullIntToAny(r.TotalGamesBatted),
			"first_half_strike_pct":  nullFloatToAny(r.FirstHalfStrikePct),
			"second_half_strike_pct": nullFloatToAny(r.SecondHalfStrikePct),
			"recent_strike_pct":      nullFloatToAny(r.RecentStrikePct),
			"total_games_pitched":    nullIntToAny(r.TotalGamesPitched),
		})
	}

	arcs := arc.BuildSummary(arcRows)

	entries := make([]progressEntry, 0, len(arcs))
	for _, a := range arcs {
		entries = append(entries, progressEntry{
			Player: a.PlayerName,
			Batting: battingPayload{
				FirstHalfOBP:  rubyFloat{v: roundPtr(a.FirstHalfOBP, 3)},
				SecondHalfOBP: rubyFloat{v: roundPtr(a.SecondHalfOBP, 3)},
				RecentOBP:     rubyFloat{v: roundPtr(a.RecentOBP, 3)},
				TotalGames:    a.TotalGamesBatted,
				Trend:         a.BatTrend,
				Sparkline:     emptyStringToNil(a.BatSparkline),
				Narrative:     a.BatNarrative,
			},
			Pitching: pitchingPayload{
				FirstHalfStrikePct:  rubyFloat{v: roundPtr(a.FirstHalfStrikePct, 3)},
				SecondHalfStrikePct: rubyFloat{v: roundPtr(a.SecondHalfStrikePct, 3)},
				RecentStrikePct:     rubyFloat{v: roundPtr(a.RecentStrikePct, 3)},
				TotalOutings:        a.TotalGamesPitched,
				Trend:               a.PitchTrend,
				Sparkline:           emptyStringToNil(a.PitchSparkline),
				Narrative:           a.PitchNarrative,
			},
		})
	}

	out, err := json.MarshalIndent(entries, "", "  ")
	if err != nil {
		return nil, fmt.Errorf("marshal: %w", err)
	}
	return out, nil
}

func nullFloatToAny(v sql.NullFloat64) any {
	if !v.Valid {
		return nil
	}
	return v.Float64
}

func nullIntToAny(v sql.NullInt64) any {
	if !v.Valid {
		return nil
	}
	return int(v.Int64)
}

func roundPtr(p *float64, places int) *float64 {
	if p == nil {
		return nil
	}
	mult := math.Pow(10, float64(places))
	out := math.Round(*p*mult) / mult
	return &out
}

func emptyStringToNil(s string) *string {
	if s == "" {
		return nil
	}
	return &s
}
