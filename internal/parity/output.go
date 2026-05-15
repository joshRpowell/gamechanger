package parity

// Result is the top-level outcome of Compare. It carries the overall status
// plus every collected diff (post-allowlist). Marshals to JSON for the
// `verify --format json` output (U6).
type Result struct {
	Status Status `json:"status"`
	Diffs  []Diff `json:"diffs"`
}

// Status names the three terminal outcomes from the diff pipeline.
//   parity-pass     — no remaining drift after the quirks switch filter
//   drift           — at least one field diverged in a way the harness can't allowlist
//   parity-unstable — only differences are threshold-proximate categorical fields
//                     (Ruby and Go landed on opposite sides of a known float threshold)
type Status string

const (
	StatusPass     Status = "parity-pass"
	StatusDrift    Status = "drift"
	StatusUnstable Status = "parity-unstable"
)

// Class names how a particular Diff was compared.
//
//   numeric     — float field with epsilon tolerance
//   ordinal     — int / position / rank: byte-exact
//   categorical — string field: byte-exact + threshold-proximity check when
//                 the field name is in the known threshold-derived set
type Class string

const (
	ClassNumeric     Class = "numeric"
	ClassOrdinal     Class = "ordinal"
	ClassCategorical Class = "categorical"
)

// Disposition records what the engine decided about a single diff after the
// allowlist pass. Drift and parity-unstable diffs survive into Result.Status;
// allowlisted-* diffs are filtered out of the status calculation but retained
// in Result.Diffs for visibility.
type Disposition string

const (
	DispDrift                 Disposition = "drift"
	DispParityUnstable        Disposition = "parity-unstable"
	DispAllowlistedPermitted  Disposition = "allowlisted-permitted"
	DispAllowlistedRubyDefect Disposition = "allowlisted-ruby-defect"
)

// Diff is a single field-level difference between Ruby and Go output. Optional
// fields use `omitempty` so JSON output stays compact for the common drift case.
type Diff struct {
	Class       Class       `json:"class"`
	Path        string      `json:"path"`
	Ruby        any         `json:"ruby"`
	Go          any         `json:"go"`
	Disposition Disposition `json:"disposition"`
	// Numeric-class only: |ruby - go|.
	Delta *float64 `json:"delta,omitempty"`
	// Categorical-class only: human-readable note when an adjacent numeric field
	// is within ε of a known threshold (e.g., the 0.05 NARRATIVE_THRESHOLD).
	ThresholdProximity string `json:"threshold_proximity,omitempty"`
	// Allowlisted-* only: the quirk's documented rationale.
	QuirkNote string `json:"quirk_note,omitempty"`
}

// ParseError is returned by Compare when one side's JSON failed to parse.
// The Side field is "ruby" or "go" — verify.go (U6) maps this to a typed
// exit code so the AI-loop driver can distinguish parse failures from drift.
type ParseError struct {
	Side    string
	Cause   error
	Snippet string
}

func (e *ParseError) Error() string {
	return "parity: " + e.Side + " JSON parse: " + e.Cause.Error()
}

func (e *ParseError) Unwrap() error { return e.Cause }
