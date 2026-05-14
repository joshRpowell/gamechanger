// Command progress-json is a pilot-only Go entry point for the verify-parity
// harness (U1). It reads the development summary from the gamechanger SQLite
// store and emits JSON matching Ruby's `gamechanger progress --format json`
// output shape (lib/gamechanger/formatters/json.rb#progress).
//
// Reads GAMECHANGER_HOME for the data directory and GC_SEASON for the season
// year. Both have sensible defaults: ~/.gamechanger and current year.
package main

import (
	"context"
	"database/sql"
	"encoding/json"
	"fmt"
	"math"
	"os"
	"strconv"
	"time"

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
//
// Field order is preserved through struct definition order so json.MarshalIndent
// emits keys in the same order Ruby's pretty_generate does.

type progressEntry struct {
	Player   string          `json:"player"`
	Batting  battingPayload  `json:"batting"`
	Pitching pitchingPayload `json:"pitching"`
}

// rubyFloat wraps an optional float and marshals to JSON the way Ruby's
// JSON.pretty_generate emits a Float: whole numbers get an explicit ".0"
// suffix ("0.0", "1.0"), fractional values use minimum precision ("0.563",
// "0.4"). Go's default float marshaler strips the ".0" — the U1 pilot
// surfaced a one-field drift on `0` vs `0.0` for batters with no recent
// games; this type closes it.
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

func main() {
	ctx := context.Background()

	season := currentSeason()
	dir := dataDir()

	s, err := store.OpenAt(ctx, dir, season)
	if err != nil {
		fmt.Fprintf(os.Stderr, "open store: %v\n", err)
		os.Exit(1)
	}
	defer s.Close()

	rows, err := s.AllPlayerDevelopmentSummary(ctx)
	if err != nil {
		fmt.Fprintf(os.Stderr, "load development summary: %v\n", err)
		os.Exit(1)
	}

	// Convert store rows into arc-package input shape (Ruby-side row keys preserved).
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
		fmt.Fprintf(os.Stderr, "marshal: %v\n", err)
		os.Exit(1)
	}
	fmt.Println(string(out))
}

func currentSeason() int {
	if v := os.Getenv("GC_SEASON"); v != "" {
		if i, err := strconv.Atoi(v); err == nil {
			return i
		}
	}
	return time.Now().Year()
}

func dataDir() string {
	if v := os.Getenv("GAMECHANGER_HOME"); v != "" {
		return v
	}
	home, _ := os.UserHomeDir()
	return home + "/.gamechanger"
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
