package parity

import (
	"encoding/json"
	"fmt"
	"math"
	"sort"
	"strings"
)

// DIFF PIPELINE (U5 of the verify-parity harness)
//
//   ruby bytes ──▶ json.Unmarshal ─[fail]─▶ ParseError{Side:"ruby"}
//   go   bytes ──▶ json.Unmarshal ─[fail]─▶ ParseError{Side:"go"}
//                                  │
//                                  ▼
//                            walk(ruby, go, "$")
//                                  │
//                                  │  classify each scalar leaf:
//                                  │    float64        → numeric (epsilon)
//                                  │    int / int-as-float → ordinal (byte-exact)
//                                  │    string         → categorical (byte-exact +
//                                  │                     threshold-proximity check)
//                                  ▼
//                            []Diff (raw)
//                                  │
//                                  │  tagProximity(diffs, parent records)
//                                  ▼
//                            []Diff (with ThresholdProximity)
//                                  │
//                                  │  applyQuirks(diffs)
//                                  │    pathSuffix match → DispAllowlistedPermitted
//                                  ▼
//                            []Diff (final dispositions)
//                                  │
//                                  ▼
//                            statusFromDiffs:
//                              all-allowlisted or empty → parity-pass
//                              only proximity-unstable  → parity-unstable
//                              otherwise                → drift

const numericEpsilon = 0.001

// Compare is the engine entry point.
func Compare(ruby, gobs []byte) (*Result, error) {
	rubyVal, err := parseJSON(ruby)
	if err != nil {
		return nil, &ParseError{Side: "ruby", Cause: err, Snippet: snippet(ruby)}
	}
	goVal, err := parseJSON(gobs)
	if err != nil {
		return nil, &ParseError{Side: "go", Cause: err, Snippet: snippet(gobs)}
	}

	var diffs []Diff
	walk(rubyVal, goVal, "$", &diffs)
	diffs = applyQuirks(diffs)

	return &Result{
		Status: statusFromDiffs(diffs),
		Diffs:  diffs,
	}, nil
}

func parseJSON(b []byte) (any, error) {
	var v any
	if err := json.Unmarshal(b, &v); err != nil {
		return nil, err
	}
	return v, nil
}

func snippet(b []byte) string {
	const max = 200
	if len(b) <= max {
		return string(b)
	}
	return string(b[:max])
}

// walk recursively compares two parsed JSON values, appending diffs as it goes.
// Path uses JSONPath-ish syntax for readability: $.foo.bar, $[0].baz, etc.
func walk(ruby, gobs any, path string, diffs *[]Diff) {
	if ruby == nil && gobs == nil {
		return
	}
	if ruby == nil || gobs == nil {
		// One side present, the other null → drift. Treat as categorical.
		*diffs = append(*diffs, Diff{
			Class:       ClassCategorical,
			Path:        path,
			Ruby:        ruby,
			Go:          gobs,
			Disposition: DispDrift,
		})
		return
	}

	rMap, rIsMap := ruby.(map[string]any)
	gMap, gIsMap := gobs.(map[string]any)
	if rIsMap && gIsMap {
		walkMap(rMap, gMap, path, diffs)
		return
	}

	rArr, rIsArr := ruby.([]any)
	gArr, gIsArr := gobs.([]any)
	if rIsArr && gIsArr {
		walkArray(rArr, gArr, path, diffs)
		return
	}

	if rIsMap != gIsMap || rIsArr != gIsArr {
		*diffs = append(*diffs, Diff{
			Class:       ClassCategorical,
			Path:        path,
			Ruby:        ruby,
			Go:          gobs,
			Disposition: DispDrift,
		})
		return
	}

	compareScalars(ruby, gobs, path, diffs)
}

func walkMap(ruby, gobs map[string]any, path string, diffs *[]Diff) {
	keys := unionKeys(ruby, gobs)
	for _, k := range keys {
		rv, rok := ruby[k]
		gv, gok := gobs[k]
		switch {
		case !rok:
			*diffs = append(*diffs, Diff{
				Class:       ClassCategorical,
				Path:        path + "." + k,
				Ruby:        nil,
				Go:          gv,
				Disposition: DispDrift,
			})
		case !gok:
			*diffs = append(*diffs, Diff{
				Class:       ClassCategorical,
				Path:        path + "." + k,
				Ruby:        rv,
				Go:          nil,
				Disposition: DispDrift,
			})
		default:
			walk(rv, gv, path+"."+k, diffs)
		}
	}
	tagProximity(ruby, gobs, path, diffs)
}

func walkArray(ruby, gobs []any, path string, diffs *[]Diff) {
	if len(ruby) != len(gobs) {
		*diffs = append(*diffs, Diff{
			Class:       ClassOrdinal,
			Path:        path + ".length",
			Ruby:        len(ruby),
			Go:          len(gobs),
			Disposition: DispDrift,
		})
	}
	min := len(ruby)
	if len(gobs) < min {
		min = len(gobs)
	}
	for i := 0; i < min; i++ {
		walk(ruby[i], gobs[i], fmt.Sprintf("%s[%d]", path, i), diffs)
	}
}

// compareScalars handles the leaf comparison.
func compareScalars(ruby, gobs any, path string, diffs *[]Diff) {
	rF, rIsF := ruby.(float64)
	gF, gIsF := gobs.(float64)
	rS, rIsS := ruby.(string)
	gS, gIsS := gobs.(string)
	rB, rIsB := ruby.(bool)
	gB, gIsB := gobs.(bool)

	// Type mismatch (e.g., number vs string) → categorical drift.
	if rIsF != gIsF || rIsS != gIsS || rIsB != gIsB {
		*diffs = append(*diffs, Diff{
			Class:       ClassCategorical,
			Path:        path,
			Ruby:        ruby,
			Go:          gobs,
			Disposition: DispDrift,
		})
		return
	}

	if rIsF && gIsF {
		if rF == gF {
			return
		}
		// Distinguish numeric (epsilon tolerance) from ordinal (byte-exact).
		// JSON has no int type; we classify as ordinal when BOTH values are
		// integer-shaped (no fractional component) AND the field name (last
		// segment of path) is in the known ordinal set.
		if isIntegerShape(rF) && isIntegerShape(gF) && isOrdinalField(path) {
			*diffs = append(*diffs, Diff{
				Class:       ClassOrdinal,
				Path:        path,
				Ruby:        int(rF),
				Go:          int(gF),
				Disposition: DispDrift,
			})
			return
		}
		delta := math.Abs(rF - gF)
		if delta < numericEpsilon {
			return
		}
		d := delta
		*diffs = append(*diffs, Diff{
			Class:       ClassNumeric,
			Path:        path,
			Ruby:        rF,
			Go:          gF,
			Delta:       &d,
			Disposition: DispDrift,
		})
		return
	}

	if rIsS && gIsS {
		if rS == gS {
			return
		}
		*diffs = append(*diffs, Diff{
			Class:       ClassCategorical,
			Path:        path,
			Ruby:        rS,
			Go:          gS,
			Disposition: DispDrift,
		})
		return
	}

	if rIsB && gIsB {
		if rB == gB {
			return
		}
		*diffs = append(*diffs, Diff{
			Class:       ClassCategorical,
			Path:        path,
			Ruby:        rB,
			Go:          gB,
			Disposition: DispDrift,
		})
		return
	}
}

func isIntegerShape(f float64) bool { return f == math.Trunc(f) }

// isOrdinalField returns true when the last segment of `path` is in the
// known ordinal-field set. These fields use byte-exact comparison; any other
// integer-shaped float goes through the numeric epsilon comparator.
var ordinalFieldNames = map[string]bool{
	"position":            true,
	"rank":                true,
	"games_pitched":       true,
	"total_games":         true,
	"total_games_batted":  true,
	"total_games_pitched": true,
	"total_outings":       true,
}

func isOrdinalField(path string) bool {
	leaf := lastSegment(path)
	return ordinalFieldNames[leaf]
}

func lastSegment(path string) string {
	// Strip array indices: `$[0].batting.position` -> `position`.
	if idx := strings.LastIndex(path, "."); idx >= 0 {
		return path[idx+1:]
	}
	return path
}

func unionKeys(a, b map[string]any) []string {
	set := make(map[string]bool, len(a)+len(b))
	for k := range a {
		set[k] = true
	}
	for k := range b {
		set[k] = true
	}
	keys := make([]string, 0, len(set))
	for k := range set {
		keys = append(keys, k)
	}
	sort.Strings(keys)
	return keys
}

// tagProximity is called once per map level. If the map (or any nested map
// within it) carries a `first_half_*` + `second_half_*` pair near the
// NARRATIVE_THRESHOLD (0.05), any categorical diff already collected under
// this path with a known threshold-derived field name gets a ThresholdProximity
// note set. Tag-only — does NOT change Disposition; that happens at status
// calculation time.
func tagProximity(ruby, gobs map[string]any, parentPath string, diffs *[]Diff) {
	// Look for first_half_obp+second_half_obp or first_half_strike_pct+second_half_strike_pct
	// at this level OR one nested level deep (handles {batting: {...}} shape).
	check := func(scope map[string]any, scopePath string) {
		for _, pair := range thresholdPairs {
			r1, ok1 := floatOrNil(scope[pair.first])
			r2, ok2 := floatOrNil(scope[pair.second])
			if !ok1 || !ok2 || r1 == nil || r2 == nil {
				continue
			}
			delta := math.Abs(*r2 - *r1)
			if math.Abs(delta-pair.threshold) > pair.window {
				continue
			}
			// We have a threshold-proximate pair at scopePath.
			// Mark any categorical diff with `pair.trendField` or `pair.narrativeField`
			// in its path that lives under scopePath.
			for i := range *diffs {
				if (*diffs)[i].Class != ClassCategorical {
					continue
				}
				if !strings.HasPrefix((*diffs)[i].Path, scopePath+".") {
					continue
				}
				leaf := lastSegment((*diffs)[i].Path)
				if leaf == pair.trendField || leaf == pair.narrativeField {
					(*diffs)[i].ThresholdProximity = fmt.Sprintf(
						"underlying %s delta %.4f is within ±%.3f of %.3f threshold",
						pair.first[len("first_half_"):], delta, pair.window, pair.threshold,
					)
				}
			}
		}
	}
	// At this level on the Ruby side (preferred — Ruby is the oracle).
	check(ruby, parentPath)
	// Nested one level: try common containers like `batting`, `pitching`.
	for _, container := range []string{"batting", "pitching"} {
		if sub, ok := ruby[container].(map[string]any); ok {
			check(sub, parentPath+"."+container)
		}
	}
	_ = gobs
}

type thresholdPair struct {
	first, second  string
	trendField     string
	narrativeField string
	threshold      float64
	window         float64
}

var thresholdPairs = []thresholdPair{
	{first: "first_half_obp", second: "second_half_obp",
		trendField: "trend", narrativeField: "narrative",
		threshold: 0.050, window: 0.005},
	{first: "first_half_strike_pct", second: "second_half_strike_pct",
		trendField: "trend", narrativeField: "narrative",
		threshold: 0.050, window: 0.005},
}

func floatOrNil(v any) (*float64, bool) {
	if v == nil {
		return nil, true
	}
	if f, ok := v.(float64); ok {
		return &f, true
	}
	return nil, false
}

// ─── quirks switch (eng-review scope-reduced; hardcoded for ≤10 entries) ─────

type quirkDisposition int

const (
	notAQuirk quirkDisposition = iota
	permittedGoBehavior
	knownRubyDefect
)

// quirkForPath returns the quirk disposition + rationale for a diff path.
//
// Quirks are scoped by path context, not by leaf-field name alone — a top-level
// `narrative` field unrelated to the progress/brief shape should not be silently
// allowlisted just because it shares a name with a real quirk.
func quirkForPath(path string) (quirkDisposition, string) {
	// narrative_for.nil_half — Ruby emits a literal "nil" string when a half is missing.
	// Scoped to the progress/brief JSON shape: `$.[*].batting.narrative` and `$.[*].pitching.narrative`.
	if strings.HasSuffix(path, ".batting.narrative") || strings.HasSuffix(path, ".pitching.narrative") {
		return permittedGoBehavior, "Ruby's narrative_for emits a literal 'nil' string when half is nil"
	}
	// Path-based matches for cross-module quirks land here.
	// e.g. `lineup_optimizer.tie_break`: would match `$.[*].lineup.tie_break` once
	// a `lineup` JSON shape is wired in.
	// e.g. `equity_flags.first_row`: would match `$.equity[0].*` once equity shape lands.
	return notAQuirk, ""
}

func applyQuirks(diffs []Diff) []Diff {
	for i := range diffs {
		if diffs[i].Disposition != DispDrift {
			continue
		}
		disp, note := quirkForPath(diffs[i].Path)
		switch disp {
		case permittedGoBehavior:
			diffs[i].Disposition = DispAllowlistedPermitted
			diffs[i].QuirkNote = note
		case knownRubyDefect:
			diffs[i].Disposition = DispAllowlistedRubyDefect
			diffs[i].QuirkNote = note
		}
	}
	return diffs
}

// statusFromDiffs derives Result.Status from the post-allowlist diff list.
func statusFromDiffs(diffs []Diff) Status {
	if len(diffs) == 0 {
		return StatusPass
	}
	hasUnstable := false
	hasDrift := false
	for _, d := range diffs {
		switch d.Disposition {
		case DispDrift:
			if d.ThresholdProximity != "" {
				// Threshold-proximate categorical → demote drift to parity-unstable.
				hasUnstable = true
				continue
			}
			hasDrift = true
		case DispParityUnstable:
			hasUnstable = true
		case DispAllowlistedPermitted, DispAllowlistedRubyDefect:
			// Filtered out of status calculation; retained in Result.Diffs for visibility.
		}
	}
	if hasDrift {
		return StatusDrift
	}
	if hasUnstable {
		return StatusUnstable
	}
	return StatusPass
}
