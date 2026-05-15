package parity

import (
	"encoding/json"
	"testing"
)

// Diff JSON round-trip — required for `verify --format json` (U6).
func TestDiff_JSONRoundTrip_NumericWithDelta(t *testing.T) {
	delta := 0.0008
	orig := Diff{
		Class:       ClassNumeric,
		Path:        "$[0].batting.first_half_obp",
		Ruby:        0.458,
		Go:          0.4588,
		Delta:       &delta,
		Disposition: DispDrift,
	}
	b, err := json.Marshal(orig)
	if err != nil {
		t.Fatalf("marshal: %v", err)
	}
	var round Diff
	if err := json.Unmarshal(b, &round); err != nil {
		t.Fatalf("unmarshal: %v", err)
	}
	if round.Class != ClassNumeric || round.Path != orig.Path || round.Disposition != DispDrift {
		t.Errorf("round-trip: lost fields. got %+v", round)
	}
	if round.Delta == nil || *round.Delta != delta {
		t.Errorf("delta lost: got %v want %v", round.Delta, delta)
	}
}

func TestDiff_JSONOmitsEmptyOptionalFields(t *testing.T) {
	// A drift-only Diff (no delta, no threshold, no quirk note) should not
	// surface those fields in JSON — keeps output schema compact.
	d := Diff{
		Class:       ClassCategorical,
		Path:        "$[0].batting.trend",
		Ruby:        "↑",
		Go:          "↓",
		Disposition: DispDrift,
	}
	b, _ := json.Marshal(d)
	s := string(b)
	for _, omitted := range []string{"\"delta\"", "\"threshold_proximity\"", "\"quirk_note\""} {
		if contains(s, omitted) {
			t.Errorf("expected %s omitted, got: %s", omitted, s)
		}
	}
}

func TestResult_JSONRoundTrip(t *testing.T) {
	orig := Result{
		Status: StatusDrift,
		Diffs: []Diff{
			{
				Class:       ClassOrdinal,
				Path:        "$[1].batting.total_games",
				Ruby:        17,
				Go:          16,
				Disposition: DispDrift,
			},
		},
	}
	b, err := json.Marshal(orig)
	if err != nil {
		t.Fatalf("marshal: %v", err)
	}
	var round Result
	if err := json.Unmarshal(b, &round); err != nil {
		t.Fatalf("unmarshal: %v", err)
	}
	if round.Status != StatusDrift || len(round.Diffs) != 1 {
		t.Errorf("round-trip lost shape: %+v", round)
	}
}

func TestParseError_ErrorString(t *testing.T) {
	pe := &ParseError{Side: "ruby", Cause: errors_New("invalid character 'n'"), Snippet: "not json"}
	s := pe.Error()
	if !contains(s, "ruby") || !contains(s, "invalid character") {
		t.Errorf("ParseError.Error string missing side or cause: %q", s)
	}
}

func contains(s, substr string) bool {
	return len(s) >= len(substr) && stringContains(s, substr)
}

func stringContains(s, substr string) bool {
	for i := 0; i+len(substr) <= len(s); i++ {
		if s[i:i+len(substr)] == substr {
			return true
		}
	}
	return false
}

// errors_New is a tiny shim so output_test.go doesn't need an import for one call.
func errors_New(s string) error { return &simpleErr{s} }

type simpleErr struct{ msg string }

func (e *simpleErr) Error() string { return e.msg }
