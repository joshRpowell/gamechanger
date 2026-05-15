package parity

import (
	"errors"
	"testing"
)

// AE1 — numeric drift within epsilon → parity-pass.
func TestCompare_AE1_NumericWithinEpsilon(t *testing.T) {
	ruby := []byte(`{"obp": 0.458}`)
	gobs := []byte(`{"obp": 0.4582}`)
	r := mustCompare(t, ruby, gobs)
	if r.Status != StatusPass {
		t.Errorf("AE1: want parity-pass, got %s (diffs: %+v)", r.Status, r.Diffs)
	}
}

// AE2 — different key order → parity-pass (map walks are order-independent).
func TestCompare_AE2_DifferentKeyOrder(t *testing.T) {
	ruby := []byte(`{"a": 1, "b": 2, "c": 3}`)
	gobs := []byte(`{"c": 3, "a": 1, "b": 2}`)
	r := mustCompare(t, ruby, gobs)
	if r.Status != StatusPass {
		t.Errorf("AE2: want parity-pass, got %s (diffs: %+v)", r.Status, r.Diffs)
	}
}

// AE3 — same per-batter OBP within epsilon but a flipped `position` (ordinal) → drift,
// names `position` as the drifted field.
func TestCompare_AE3_FlippedOrdinal(t *testing.T) {
	ruby := []byte(`[
		{"player": "A", "obp": 0.400, "position": 1},
		{"player": "B", "obp": 0.401, "position": 2}
	]`)
	gobs := []byte(`[
		{"player": "A", "obp": 0.400, "position": 2},
		{"player": "B", "obp": 0.401, "position": 1}
	]`)
	r := mustCompare(t, ruby, gobs)
	if r.Status != StatusDrift {
		t.Fatalf("AE3: want drift, got %s", r.Status)
	}
	found := false
	for _, d := range r.Diffs {
		if d.Class == ClassOrdinal && contains(d.Path, "position") {
			found = true
		}
	}
	if !found {
		t.Errorf("AE3: expected an ordinal diff naming `position`. Got diffs: %+v", r.Diffs)
	}
}

// AE3b — categorical trend differs because underlying delta is 0.049 vs 0.051
// around the 0.05 NARRATIVE_THRESHOLD → parity-unstable with threshold_proximity set.
func TestCompare_AE3b_ThresholdProximity(t *testing.T) {
	// Ruby's bat_trend → "→" because delta=0.049 doesn't cross the 0.05 threshold.
	// Go's bat_trend → "↑" because delta=0.051 crosses (post-rounding-quirk).
	// The threshold field is `batting.trend`; the underlying numeric fields are
	// first_half_obp / second_half_obp on the same record.
	// The numeric fields agree to within ε (0.001) on both sides; only the
	// derived trend categorical disagrees because the underlying delta is
	// knife-edge against the 0.05 threshold.
	ruby := []byte(`[{
		"player": "Threshold Test",
		"batting": {
			"first_half_obp": 0.300,
			"second_half_obp": 0.3499,
			"trend": "→"
		}
	}]`)
	gobs := []byte(`[{
		"player": "Threshold Test",
		"batting": {
			"first_half_obp": 0.300,
			"second_half_obp": 0.3501,
			"trend": "↑"
		}
	}]`)
	r := mustCompare(t, ruby, gobs)
	if r.Status != StatusUnstable {
		t.Errorf("AE3b: want parity-unstable, got %s (diffs: %+v)", r.Status, r.Diffs)
	}
	foundProximity := false
	for _, d := range r.Diffs {
		if d.Class == ClassCategorical && d.ThresholdProximity != "" {
			foundProximity = true
		}
	}
	if !foundProximity {
		t.Errorf("AE3b: expected a categorical diff with threshold_proximity set. Got: %+v", r.Diffs)
	}
}

// AE3c — `narrative` differs but matches the `narrative_for.nil_half` quirk → parity-pass,
// disposition=allowlisted-permitted, status=parity-pass.
func TestCompare_AE3c_QuirkMatched(t *testing.T) {
	ruby := []byte(`[{
		"player": "Nil Half Test",
		"batting": {
			"narrative": "nil"
		}
	}]`)
	gobs := []byte(`[{
		"player": "Nil Half Test",
		"batting": {
			"narrative": "Building their game — more at-bats will tell the full story"
		}
	}]`)
	r := mustCompare(t, ruby, gobs)
	if r.Status != StatusPass {
		t.Errorf("AE3c: want parity-pass (quirk filters drift), got %s", r.Status)
	}
	// The diff should still be retained in the structured output for visibility,
	// but with disposition allowlisted-permitted.
	if len(r.Diffs) == 0 {
		t.Fatal("AE3c: expected at least one diff with allowlisted-permitted disposition")
	}
	foundAllowlisted := false
	for _, d := range r.Diffs {
		if d.Disposition == DispAllowlistedPermitted {
			foundAllowlisted = true
			if d.QuirkNote == "" {
				t.Errorf("AE3c: allowlisted diff missing QuirkNote: %+v", d)
			}
		}
	}
	if !foundAllowlisted {
		t.Errorf("AE3c: no diff has DispAllowlistedPermitted. Got: %+v", r.Diffs)
	}
}

// Categorical with no threshold field (sparkline chars) → drift, not parity-unstable.
func TestCompare_CategoricalNoThreshold_Drift(t *testing.T) {
	ruby := []byte(`[{"sparkline": "▁▂▃▄▅"}]`)
	gobs := []byte(`[{"sparkline": "▁▂▃▄▆"}]`)
	r := mustCompare(t, ruby, gobs)
	if r.Status != StatusDrift {
		t.Errorf("categorical-no-threshold: want drift, got %s", r.Status)
	}
}

// null vs empty-string → drift (categorical special case).
func TestCompare_NullVsEmptyString_Drift(t *testing.T) {
	ruby := []byte(`{"narrative": null}`)
	gobs := []byte(`{"narrative": ""}`)
	r := mustCompare(t, ruby, gobs)
	if r.Status != StatusDrift {
		t.Errorf("null-vs-empty: want drift, got %s", r.Status)
	}
}

// Nested map under a key — recurse correctly.
func TestCompare_NestedMapRecursion(t *testing.T) {
	ruby := []byte(`{"a": {"b": {"c": {"deep": 1}}}}`)
	gobs := []byte(`{"a": {"b": {"c": {"deep": 2}}}}`)
	r := mustCompare(t, ruby, gobs)
	if r.Status != StatusDrift {
		t.Fatalf("nested: want drift, got %s", r.Status)
	}
	if len(r.Diffs) != 1 || !contains(r.Diffs[0].Path, "deep") {
		t.Errorf("nested: expected one diff naming `deep`. Got: %+v", r.Diffs)
	}
}

// Doubleheader: two records with the same date but different other fields → drift
// on the differing fields, no spurious drift on the duplicate-date fields.
func TestCompare_DoubleheaderEdgeCase(t *testing.T) {
	ruby := []byte(`[
		{"game_date": "2026-04-15", "score": 5},
		{"game_date": "2026-04-15", "score": 3}
	]`)
	gobs := []byte(`[
		{"game_date": "2026-04-15", "score": 5},
		{"game_date": "2026-04-15", "score": 3}
	]`)
	r := mustCompare(t, ruby, gobs)
	if r.Status != StatusPass {
		t.Errorf("doubleheader: want parity-pass (identical inputs), got %s (diffs: %+v)", r.Status, r.Diffs)
	}
}

// Nil-last-outing: top-level field is null on both sides — no drift.
func TestCompare_NilLastOuting_NoSpuriousDrift(t *testing.T) {
	ruby := []byte(`{"player": "X", "last_outing": null}`)
	gobs := []byte(`{"player": "X", "last_outing": null}`)
	r := mustCompare(t, ruby, gobs)
	if r.Status != StatusPass {
		t.Errorf("nil-last-outing: want parity-pass, got %s", r.Status)
	}
}

// Ruby JSON unparseable → returns (nil, *ParseError{Side:"ruby"}).
func TestCompare_ParseError_RubySide(t *testing.T) {
	res, err := Compare([]byte("not json"), []byte(`{}`))
	if res != nil {
		t.Errorf("want nil Result on parse error, got %+v", res)
	}
	var pe *ParseError
	if !errors.As(err, &pe) {
		t.Fatalf("want *ParseError, got %T: %v", err, err)
	}
	if pe.Side != "ruby" {
		t.Errorf("Side: want ruby, got %s", pe.Side)
	}
	if pe.Snippet == "" {
		t.Error("Snippet should contain unparseable bytes")
	}
}

// Go JSON unparseable → returns (nil, *ParseError{Side:"go"}).
func TestCompare_ParseError_GoSide(t *testing.T) {
	_, err := Compare([]byte(`{}`), []byte("garbage"))
	var pe *ParseError
	if !errors.As(err, &pe) {
		t.Fatalf("want *ParseError, got %T: %v", err, err)
	}
	if pe.Side != "go" {
		t.Errorf("Side: want go, got %s", pe.Side)
	}
}

// Allowlist + threshold-proximity composition: a diff that is BOTH threshold-proximate
// AND quirk-matched. Per the plan's precedence rule: quirk filter wins → parity-pass.
func TestCompare_AllowlistAndProximity_QuirkWins(t *testing.T) {
	// `narrative` differs (quirk match) AND there are threshold-proximate halves.
	// Helper fields agree within ε; only narrative differs (quirk-eligible) AND
	// the underlying obp delta straddles the 0.05 threshold.
	ruby := []byte(`[{
		"player": "X",
		"batting": {
			"first_half_obp": 0.300,
			"second_half_obp": 0.3499,
			"narrative": "nil"
		}
	}]`)
	gobs := []byte(`[{
		"player": "X",
		"batting": {
			"first_half_obp": 0.300,
			"second_half_obp": 0.3501,
			"narrative": "Building their game"
		}
	}]`)
	r := mustCompare(t, ruby, gobs)
	if r.Status != StatusPass {
		t.Errorf("composition: quirk should win, want parity-pass, got %s. Diffs: %+v", r.Status, r.Diffs)
	}
}

// Identical inputs → parity-pass, zero diffs.
func TestCompare_IdenticalInputs(t *testing.T) {
	in := []byte(`{"a": 1, "b": "hello", "c": [1, 2, 3], "d": {"nested": true}}`)
	r := mustCompare(t, in, in)
	if r.Status != StatusPass || len(r.Diffs) != 0 {
		t.Errorf("identical: want parity-pass + 0 diffs, got %s + %d diffs", r.Status, len(r.Diffs))
	}
}

// Type mismatch (number vs string at same path) → drift.
func TestCompare_TypeMismatch_Drift(t *testing.T) {
	ruby := []byte(`{"x": 5}`)
	gobs := []byte(`{"x": "5"}`)
	r := mustCompare(t, ruby, gobs)
	if r.Status != StatusDrift {
		t.Errorf("type mismatch: want drift, got %s", r.Status)
	}
}

// ───────────────────────── helpers ─────────────────────────

func mustCompare(t *testing.T, ruby, gobs []byte) *Result {
	t.Helper()
	r, err := Compare(ruby, gobs)
	if err != nil {
		t.Fatalf("Compare: %v", err)
	}
	if r == nil {
		t.Fatalf("Compare returned nil Result")
	}
	return r
}
