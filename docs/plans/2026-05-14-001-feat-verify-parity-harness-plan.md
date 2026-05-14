---
date: 2026-05-14
type: feat
origin: docs/brainstorms/2026-05-14-verify-parity-harness-requirements.md
status: active
---

# feat: Verify-parity harness for the Ruby → Go analytics port

## Summary

Implement a minimal verify-parity harness for the Ruby → Go analytics port. The pilot spike (U1) is a gate: an AI-loop port of `development_arc.rb` (144 LOC, single isolated module) against the `progress` command (which does NOT invoke Syncer) validates the AI-loop convergence trajectory before the full harness is built. If the loop converges with diff-size reduction each iteration, units U3-U6 land the production harness. If it doesn't, the user revisits scope before committing more work.

**Scope discipline (post-eng-review):** the harness retires when Ruby retires (per Scope Boundaries), so the surface area is matched to that lifetime — quirks are hardcoded in `engine.go` rather than externalized to YAML, the fixture corpus is the anchor alone, and CI integration tests are deferred until CI itself lands.

---

## Problem Frame

The Ruby gem's analytics layer (516 LOC across `pitch_rules.rb`, `lineup_optimizer.rb`, `development_arc.rb`, `pre_game_brief.rb`, and `tournament_planner.rb`) is the pure-logic kernel of the product. The Go port (PR #3, shipped 2026-05-14) covers transport, storage, sync, and basic commands but not analytics. The user wants to port analytics via an AI loop using a parity-verify harness as the pass/fail oracle — but the loop's convergence is unproven, and several premises in the brainstorm (anonymization adequacy, Ruby-as-oracle correctness, single-fixture coverage, epsilon-on-floats) carry real failure modes the doc-review pass surfaced.

This plan threads those 9 open items (4 Resolve-Before-Planning + 5 Deferred-to-Planning from origin) into 5 implementation units, ordered so the cheapest premise-validation runs first.

---

## Requirements Trace

Carried forward from origin (see `docs/brainstorms/2026-05-14-verify-parity-harness-requirements.md`):

**Actors:** A1 (solo developer), A2 (AI port loop), A3 (`go test`, manual for now; CI when it lands).
**Key flows:** F1 (manual spot-check), F2 (AI port loop iteration), F3 (regression catch in local `go test`), F4 (cost/benefit + AI-loop pilot evidence), F12 (Ruby-is-runtime-dep observation).
**Requirements addressed in this plan:** R1, R2, R3, R4, R5, R6, R7, R8, R9, R10, R11, R12, R13, R14.
**Acceptance examples:** AE1, AE2, AE3, AE3b, AE3c, AE4, AE5, AE6 — all verified via `engine_test.go` against synthetic JSON pairs; AE3b is not exercised against a dedicated fixture (single-fixture corpus), but the engine path is fully tested in isolation.
**Scope boundaries:** preserved verbatim — no sync-layer parity, no commands-not-yet-ported, no property-based testing in v1, no full Ruby-spec parity, no live API, no permanent post-retirement regression suite.

**Plan-time resolutions of origin RBP items:**

- RBP#1 (pilot before commit) → **U1**.
- RBP#2 (single-fixture coverage gap) → **U4** ships the anchor fixture only. The 3 named edge cases (nil-last-outing, doubleheader, threshold-straddle) are exercised as synthetic JSON pairs in `engine_test.go` (U5), not as separate fixture SQLite files. If the AI loop surfaces a real-world edge the anchor misses, add a fixture at that point — don't pre-build them.
- RBP#3 (substitution-map lifecycle) → **U3** writes the map per fixture-version with a **fresh random seed per regeneration** (the seed is stored inside the fixture SQLite, not the map); rotation is enforced by code, not documentation; old maps stay local until the user manually deletes them.
- RBP#4 (missing AEs for R2/R7/R9/R11/R13/R14) → AE coverage captured inline below in this plan's Requirements Trace (origin brainstorm doc is NOT modified by this plan):
  - **AE-R2** (parity-pass on epsilon drift): `bat_avg` differs by 0.0005 — engine emits `parity-pass`.
  - **AE-R7** (anonymized fixture parity): running `verify brief --fixture cache-anchor.db` against both stacks emits `parity-pass` for the anchor fixture.
  - **AE-R9** (deterministic regeneration): bootstrapping the same source `cache.db` with the same seed produces a byte-identical fixture SQLite.
  - **AE-R11** (exit code on Ruby unavailable): `verify brief` with no `bundle` on PATH exits with the Ruby-unavailable code and prints an install hint.
  - **AE-R13** (human-readable diff path): `verify brief --format human` on a synthetic input with a drifted `position` field prints the field name, both values, and the comparison class.
  - **AE-R14** (Go subcommand not yet implemented): `verify lineup` before `lineup` is in the allowlist exits with the not-implemented code and a one-line message naming the missing Go command.

**Plan-time resolutions of origin Deferred-to-Planning items:**

- D#1 (diff library) → `google/go-cmp` with custom `cmp.Comparer` per comparison class.
- D#2 (fixture path) → `internal/parity/testdata/`.
- D#3 (structured output schema) → JSON with `class` (numeric/ordinal/categorical), `path` (field path), `ruby`, `go`, `delta` (when numeric), `threshold_proximity` (when categorical), `disposition` (`drift`, `parity-unstable`, `allowlisted-permitted`, `allowlisted-ruby-defect`). Documented as a Go struct in `internal/parity/output.go`.
- D#4 (quirks allowlist format) → **hardcoded** as a `switch` statement in `engine.go` keyed by `(module, field)`, with each quirk as a Go `case` returning a `quirkDisposition` (one of `permittedGoBehavior` or `knownRubyDefect`). Three quirks known from origin/adversarial review: `equity_flags` first-row, unstable sort tie-break in `lineup_optimizer`, `narrative_for` nil-half. If quirks exceed ~10 mid-port, refactor to YAML at that point — not before.
- D#5 (stat-perturbation strategy) → perturb individual counts by ±3 within game constraints (AB ≥ H+BB+K, etc.); rank order across players is verified by the engine, not preserved as a fixture invariant; use a fresh random seed per bootstrap so the substitution map is non-stable across regenerations. The seed is stored inside the fixture SQLite (a `meta` row).

---

## Key Technical Decisions

| Decision | Choice | Rationale |
|---|---|---|
| Diff library | `google/go-cmp` with custom `cmp.Comparer` per class | Best-in-class structural comparison for Go; native support for custom comparers across float/int/string classes; widely used in stdlib testing |
| Three-class comparison shape | `numeric` (epsilon) / `ordinal` (byte-exact) / `categorical` (byte-exact + threshold-proximity warning) | Per origin R4; reconciles AE1/AE3 contradiction the doc-review pass identified |
| Diff-pipeline precedence | (1) collect diffs, (2) tag threshold-proximity, (3) apply hardcoded quirks `switch` | Locks in deterministic behavior when a diff is BOTH threshold-proximate AND quirk-allowed: quirk filter wins, status is parity-pass, proximity logged at INFO |
| Quirks handling | **Hardcoded `switch` in `engine.go`** keyed by `(module, field)`; two dispositions: `permittedGoBehavior` (acceptable Ruby behavior) and `knownRubyDefect` (Ruby bug, Go correct) | Per-eng-review scope reduction. YAML externalization is correct only if the audit produces >10 quirks; 3 known quirks fit cleanly in code with a 30-line `switch`. `knownRubyDefect` disposition prevents bug-preserving parity |
| Fixture corpus shape | **1 anchor only** (anonymized from real cache.db); edge cases tested via synthetic JSON in `engine_test.go` | Per-eng-review scope reduction. The 3 origin edge classes (nil-last-outing, doubleheader, threshold-straddle) are exercised in unit tests against handcrafted JSON pairs, which is faster to author and faster to run than committing 3 extra SQLite files |
| Substitution-map handling | Map written to `~/.gamechanger/parity-substitution-{fixture-hash}.yml`; **fresh random seed per regeneration**, seed stored inside the fixture SQLite; rotation enforced by code | Stable mapping would *enable* cross-version linkage; rotation defeats it. Path is outside the repo, so no `git check-ignore` step |
| Verify subcommand surface | `gamechanger verify <command>` with `--fixture <path>`, `--format human|json`, `--strict` flags; `<command>` checked against an explicit allowlist | Cobra fits existing pattern in `internal/commands/`; explicit allowlist prevents argv-injection through the positional argument |
| Shell wrapper | Thin `bin/verify-parity` that just forwards to the Go binary with default flags; all validation lives in `internal/commands/verify.go` | Per origin R1 it's a surface; the wrapper has zero logic of its own |
| Ruby fixture-path injection | Both stacks read fixture path via `GAMECHANGER_HOME` env var (Ruby `Config` and `Storage` honor it; Go already does in `internal/commands/root.go`) | Without parity here, Ruby always reads `~/.gamechanger/cache.db` and the harness cannot operate on a chosen fixture |
| Regression coverage | Local `go test ./internal/parity/...` (developer-run, not CI) | Per-eng-review scope reduction. CI workflow doesn't exist yet (GO-6); a CI-only integration test is premature. Engine unit tests catch regressions adequately for a solo dev |

---

## High-Level Technical Design

*Directional guidance for review, not implementation specification.*

```
                           User invocations
            +-----------------+--------+
            |                          |
       bin/verify-parity                | gamechanger verify
            |                          |
            v                          v
            +--------------------------+
                              |
                              v
                  internal/parity (Go package)
              +---------------+----------------+
              | engine.go     | exec.Command bundle exec exe/gamechanger
              |               |   (GAMECHANGER_HOME=<fixture dir>)
              |               | parse Ruby JSON
              |               | parse Go JSON (in-process)
              |               | go-cmp w/ custom Comparers
              |               | switch (module, field) -> quirk disposition
              |               | -> structured Diff{class,path,ruby,go,...}
              +---------------+----------------+
              | fixture.go    | open testdata/cache-anchor.db read-only
              |               |   (mode=ro&immutable=1, skip migrations)
              +---------------+----------------+
                              |
                              v
                       Exit code + output
            (parity-pass / drift / not-implemented /
             ruby-unavailable / fixture-missing)
```

**Comparison class routing:**

| Field shape | Class | Comparator |
|---|---|---|
| OBP, strike% (raw float) | numeric | epsilon 0.001 |
| position, games_pitched, total_games (int) | ordinal | byte-exact |
| trend arrow, sparkline char, narrative archetype, status enum | categorical | byte-exact + flag if underlying float within epsilon of known threshold |
| game_date (ISO 8601) | numeric/normalized | canonical-form equal |
| nullable date string | categorical (special-case) | both `null` or both equal string |

---

## Output Structure

```
internal/parity/
├── engine.go            (U5 — includes the 3-quirk hardcoded switch)
├── engine_test.go       (U5 — also exercises AE3b/AE3c via synthetic JSON)
├── output.go            (U5)
├── output_test.go       (U5)
├── fixture.go           (U4)
├── fixture_test.go      (U4)
└── testdata/
    └── cache-anchor.db                  (U4 — anchor only)

internal/parity/anonymize/
├── anonymize.go         (U3)
├── anonymize_test.go    (U3)
└── README.md            (U3 — threat model + lifecycle)

internal/commands/
└── verify.go            (U6)

cmd/
├── anonymize-fixture/
│   └── main.go          (U3)
└── progress-json/
    └── main.go          (U1 — pilot-only Go entry point for `progress` JSON output)

internal/analytics/arc/
├── arc.go               (U1)
└── arc_test.go          (U1)

bin/
├── verify-parity        (U6)
└── pilot-diff           (U1)
```

(Note: `lib/gamechanger/config.rb` and `lib/gamechanger/storage.rb` are MODIFIED by U1 to honor `GAMECHANGER_HOME`; see U1.)

---

## Implementation Units

### U1. Pilot spike: AI-loop port of `development_arc` + GAMECHANGER_HOME (gate)

**Goal:** Validate origin RBP#1 — does the AI-loop convergence claim hold for a small isolated analytics module, when the loop is doing the porting (not a human)? Simultaneously, unblock the rest of the plan by introducing Ruby-side fixture-path injection. If the loop converges with diff-size reduction per iteration, the full harness (U3-U6) is justified. If it doesn't, scope revisits before more work.

**Why `progress` (and not `brief` or `pitches`):**
- `Commands::Pitches#call` unconditionally invokes `Syncer.new(config, storage).run(...)`, which hits the live API and mutates the SQLite cache — would fail offline, be non-deterministic, mutate the oracle, and violate "Runs entirely against local fixtures."
- `Commands::Brief#call` looks storage-only at first glance, but `PreGameBrief` coordinates `PitchRules` + `LineupOptimizer` + `DevelopmentArc` + `PlayerArc` = 347 LOC. Picking brief expands U1 to nearly the entire analytics layer; the pilot loses its "small bet" shape.
- `Commands::Progress#call` is storage-only AND its analytics surface is a single module: `DevelopmentArc.build_summary(rows)` → `Array<PlayerArc>`. 144 LOC. Rich branching (bat_trend arrows, half-period thresholds, recent-vs-season comparisons) so the AI-loop is exercised on real ranking/threshold work, not just integer arithmetic.

**Requirements:** Gates everything. Origin RBP#1.

**Dependencies:** None.

**Files:**
- `lib/gamechanger/config.rb` (modify — read `GAMECHANGER_HOME` env var with fallback to `~/.gamechanger`)
- `lib/gamechanger/storage.rb` (modify — same env-var fallback for `data_dir`)
- `internal/analytics/arc/arc.go` (new, AI-ported from `lib/gamechanger/development_arc.rb` by the AI loop; exports `BuildSummary([]Row) []PlayerArc`)
- `internal/analytics/arc/arc_test.go` (new, ports the Ruby spec cases — written first, by hand)
- `cmd/progress-json/main.go` (new — minimal pilot-only Go entry point that reads from storage and emits `progress` JSON matching Ruby's `Formatters::Json#progress` shape)
- `bin/pilot-diff` (new, ~15 lines; sets `GAMECHANGER_HOME=<fixture dir>` and pipes Ruby `progress --format json` + Go `progress-json` through `jq` and `diff`)

**Approach:**
1. Modify Ruby `Config` and `Storage` to honor `GAMECHANGER_HOME`. This is a small change in each file (a single `ENV.fetch` with the existing constant as default). Add Ruby spec coverage.
2. Hand-write the Go table tests under `internal/analytics/arc/arc_test.go` derived from the Ruby spec cases in `spec/gamechanger/development_arc_spec.rb`. These are the oracle.
3. Hand off to the AI loop: "port `lib/gamechanger/development_arc.rb` to `internal/analytics/arc/arc.go` until `bin/pilot-diff` produces empty output." The loop runs the table tests + the shell diff each iteration.
4. Document each iteration: which Ruby idiom tripped the loop, how it self-corrected, and the byte-diff size after each iteration.

**Bet:** Convergence on this 144-LOC isolated module is a bet on the 516-LOC analytics layer overall. The full layer is ~3.6× larger and has more cross-field interaction (`lineup_optimizer` has multi-pass ranking, `tournament_planner` has stateful day-by-day projection, `pre_game_brief` coordinates 3 modules). A clean pilot result is necessary but not sufficient for harness-wide success.

**Execution note:** Test-first — the Ruby spec cases become Go table tests, written by hand before the AI loop touches the Go implementation.

**Patterns to follow:** Existing Go test conventions in `internal/parser/parser_test.go` (table-driven, no external deps).

**Test scenarios:**
- **[REGRESSION GUARD]** Existing rspec coverage for `Config` and `Storage` default-path behavior (env var unset → uses `~/.gamechanger`) MUST continue to pass. The new env-var-set branch only adds; it does not weaken or replace existing tests.
- Ruby `Config` / `Storage` honor `GAMECHANGER_HOME` (set env, point to a tmp dir, verify it reads/writes there).
- Go arc table tests cover the Ruby spec cases for `development_arc.rb` (happy path, improving/declining bat_trend, threshold-straddle, empty rows, nil-half edge).
- Behavioral parity (the actual pilot test): run `bin/pilot-diff` against `~/.gamechanger/cache.db` (developer's local DB, not committed). Pass = empty diff. Document the iteration count and the per-iteration diff size.

**Verification:** `go test ./internal/analytics/arc/...` green. `bundle exec rspec spec/gamechanger/config_spec.rb spec/gamechanger/storage_spec.rb` green. `bin/pilot-diff` produces empty diff. Per-iteration diff sizes recorded in the pilot log.

**Gate criterion (trajectory, not count):** each AI iteration reduces the diff field count vs. the prior iteration, and the loop reaches parity-pass within an iteration budget of 5. **Real failure signal:** iteration N+1 does not reduce the diff vs. iteration N — the loop is not converging, STOP and revisit scope. A successful pilot may take 1, 2, 3, or 4 iterations — count alone is not the signal.

---

### U3. Anonymization bootstrap package

**Goal:** Implement origin R7+R8 — generate an anonymized SQLite fixture from a local cache.db. Resolves RBP#3 (substitution-map lifecycle) and Deferred-D#5 (stat-perturbation strategy).

**Requirements:** R7, R8 (a, b, c, d, e), R9.

**Dependencies:** None (parallel to U5 design work once U1 passes).

**Files:**
- `internal/parity/anonymize/anonymize.go` (new)
- `internal/parity/anonymize/anonymize_test.go` (new)
- `internal/parity/anonymize/README.md` (new — threat model + substitution-map lifecycle docs)
- `cmd/anonymize-fixture/main.go` (new — small binary that runs the bootstrap)

**Threat model (stated up front, lives in README):**
- **In-scope adversary:** an anonymous reader of the public repo, with optional access to public youth-baseball stats sites (GameChanger team pages, USSSA/PerfectGame results).
- **Out-of-scope:** an adversary with access to the substitution map (the map is gitignored and stays local).
- **Defended properties:** no real player name appears in the committed fixture; no committed combination of (date, opponent, stat-line) is linkable to a single public game record with >5% confidence.

**Approach:** Read source SQLite via `modernc.org/sqlite`. For each `games` row:
- Shift `game_date` by a **random offset of 0–365 days** (does NOT preserve day-of-week). The harness only needs relative spacing for rest-day calculation, which the shift preserves.
- Synthesize opponent name from a static name pool.
For each `game_pitcher_stats` and `game_batter_stats` row:
- Synthesize player name from a static name pool.
- Perturb stat counts by seeded RNG **±3** within game constraints (AB ≥ H+BB+K, etc.). Rank order across players is NOT preserved as a fixture invariant — U5's engine verifies rank as part of the comparison; the fixture itself can reorder freely.

**Seed handling (RBP#3 resolution):** each bootstrap invocation generates a **fresh random seed** (e.g., `crypto/rand` 64 bits). The seed is written to a `meta` row inside the fixture SQLite and also recorded in the substitution map. Same source + same seed → byte-identical fixture (R9 determinism). Different bootstrap invocations → different seeds → different mappings → cross-version linkage broken.

**Substitution map:** written to `~/.gamechanger/parity-substitution-{fixture-hash}.yml`. The path lives outside the repo and outside any git work tree. A follow-up pre-commit hook (Outstanding Question) can enforce that `parity-substitution-*.yml` never lands in the repo regardless of location.

**Execution note:** Test-first — define expected anonymization invariants in tests before writing logic.

**Patterns to follow:** `internal/store/store.go` SQLite open pattern; `internal/config/config.go` for `~/.gamechanger/` path handling.

**Test scenarios:**
- Happy path: anonymize a 5-game / 3-player fixture; output has 5 games, 3 players, all real names absent.
- Anonymization preservation: real game count = output game count; real outing count = output outing count.
- Edge case (R8c): game dates are shifted by a random 0-365 day offset; day-of-week is NOT preserved.
- Edge case (R8e): substitution map path defaults under `~/.gamechanger/`; map writes regardless of `.gitignore` (the path is outside the repo).
- Determinism (R9): same input + same seed → byte-identical fixture output.
- Cross-version unlinkability: two bootstrap runs against the same source produce <5% overlap in synthetic names.
- Falsification: fresh AI agent given only the fixture + public youth-baseball stats sites cannot identify any real player with >5% confidence. (Manual check, recorded in README.)
- **Error path — source missing:** point `--source /tmp/nonexistent.db` → returns `ErrSourceMissing` with the path; bootstrap CLI prints "source not found at <path> — run `gamechanger refresh` first" and exits with the source-missing typed code.
- **Error path — source corrupt:** create a truncated SQLite file and pass as `--source` → returns `ErrSourceCorrupt` wrapping the underlying SQLite error; bootstrap CLI prints an actionable "source database is corrupt or unreadable" message and exits.
- **Error path — wrong schema:** create a SQLite with `games` table missing the `game_date` column → returns `ErrSourceSchema` naming the missing column; bootstrap CLI prints "source schema mismatch (expected column `game_date` in `games`) — Ruby gem version may differ" and exits.

**Verification:** `go test ./internal/parity/anonymize/...` green. Running `go run ./cmd/anonymize-fixture --source ~/.gamechanger/cache.db --out /tmp/test-fixture.db` produces a valid SQLite with synthetic names and a fresh seed.

---

### U4. Generate the anchor fixture

**Goal:** Run U3's bootstrap to produce the canonical anchor fixture. Edge cases live in `engine_test.go` (U5), not as separate SQLite files.

**Requirements:** R7.

**Dependencies:** U3.

**Files:**
- `internal/parity/testdata/cache-anchor.db` (new, committed — anonymized from real cache.db via U3)
- `internal/parity/testdata/README.md` (new — what this fixture is and how to regenerate)
- `internal/parity/fixture.go` (new — loader helper for tests; opens with `file:...?mode=ro&immutable=1`)
- `internal/parity/fixture_test.go` (new)

**Approach:** Run U3's bootstrap binary against the user's real `~/.gamechanger/cache.db`. The output is `internal/parity/testdata/cache-anchor.db`. Commit it. The README documents the source hash + seed (for regeneration) and the U3 threat-model link.

**Fixture loading (feasibility fix):** `fixture.go` opens the `.db` via the read-only immutable DSN `file:<path>?mode=ro&immutable=1` and skips the migration pass. This prevents WAL sidecar creation (`-wal`, `-shm` files) and migration writes to the committed binary, which would otherwise dirty the working tree on every read.

**Patterns to follow:** Existing test fixtures in `internal/sync/integration_test.go` (in-memory SQLite seeded from Go code).

**Test scenarios:**
- The anchor fixture opens cleanly via `fixture.go`, with no WAL sidecars created.
- `cache-anchor.db` has at least 5 games, 3 players, all final-status (validated by `fixture_test.go`).
- After opening the fixture, the working tree has no new untracked files in `internal/parity/testdata/`.

**Verification:** `cache-anchor.db` exists, opens cleanly via `fixture.go`, asserts the named invariants in `fixture_test.go`, and produces no sidecars. README documents the source and regeneration steps.

---

### U5. Three-class diff engine (the core)

**Goal:** Implement origin R4 (three-class comparison), R5 (human-readable diff), R6 (quirks handling), R12 (named-field structured diff). The heart of the harness.

**Requirements:** R2, R4, R5, R6, R10, R12.

**Dependencies:** U4 (anchor fixture for tests).

**Files:**
- `internal/parity/engine.go` (new — includes hardcoded 3-quirk `switch`)
- `internal/parity/engine_test.go` (new — also covers AE3b/AE3c via synthetic JSON pairs)
- `internal/parity/output.go` (new — `Diff` struct + JSON marshaling)
- `internal/parity/output_test.go` (new)

**Approach:** `Compare(ruby, go []byte) (*Result, error)` is the entry point — both inputs are JSON byte streams. Parse both into `map[string]any`. If either side fails to parse, return `(nil, &ParseError{Side: "ruby"|"go", Cause: err, Snippet: first 200 chars of input})`. `verify.go` maps `ParseError{Side: "ruby"}` to a **ruby-parse-error** typed exit code and `ParseError{Side: "go"}` to a **go-parse-error** typed exit code (rarely triggered, but possible if Go's JSON serializer has a bug). Parse failures never reach the diff walker — the AI loop sees a clean "Ruby output unparseable" signal instead of a phantom drift report. Walk the trees in parallel using `google/go-cmp` with custom `cmp.Comparer` opts:
- Numeric (float): `math.Abs(a-b) < epsilon`
- Ordinal (int, position, rank): `==` strict
- Categorical (string in known threshold-derived field allowlist): `==` strict, plus check threshold-proximity of an underlying float field
- Map: order-independent
- Timestamp string: canonicalize then `==`

**Hardcoded quirks `switch` (lives in `engine.go`):**

```go
type quirkDisposition int
const (
    notAQuirk quirkDisposition = iota
    permittedGoBehavior         // acceptable Ruby behavior, Go may match or diverge
    knownRubyDefect             // Ruby is wrong, Go is correct
)

func quirkFor(module, field string) (quirkDisposition, string) {
    switch {
    case module == "lineup_optimizer" && field == "tie_break":
        return permittedGoBehavior, "Ruby's tie-break is unstable; Go may produce a different but consistent order"
    case module == "equity_flags" && field == "first_row":
        return permittedGoBehavior, "Ruby treats first-row equity as a special case (origin: equity_flags first-row quirk)"
    case module == "narrative_for" && field == "nil_half":
        return permittedGoBehavior, "Ruby's narrative_for emits a literal 'nil' string when half is nil"
    }
    return notAQuirk, ""
}
```

If quirks exceed ~10 mid-port, refactor to YAML (deferred). For now, hardcoded is the minimum viable shape.

**Diff-pipeline precedence:**
1. Collect all diffs from the tree walk.
2. Tag any categorical diff with `threshold_proximity` when the underlying float is within epsilon of a known threshold.
3. Apply the quirks `switch` — any diff matching a quirk drops to parity-pass with the disposition surfaced in the structured output (`allowlisted-permitted` or `allowlisted-ruby-defect`).
4. The remaining filtered set determines `Result.Status`: `parity-pass | drift | parity-unstable`.

A diff that is BOTH threshold-proximate AND quirk-matched: the quirk wins (status is parity-pass), but the proximity event is logged at INFO.

The `Result` struct carries `[]Diff` where each `Diff` has `class`, `path`, `ruby`, `go`, `disposition` (one of `drift`, `parity-unstable`, `allowlisted-permitted`, `allowlisted-ruby-defect`), optional `delta` (numeric) and `threshold_proximity` (categorical).

**Patterns to follow:** Use `cmp.Diff` + `cmp.Options` from `google/go-cmp`. Reference `internal/parser/parser.go` for the `map[string]any` walking pattern.

**Test scenarios (all synthetic JSON in `engine_test.go` — no fixture SQLite needed):**
- AE1: numeric drift within epsilon → parity-pass.
- AE2: different key order → parity-pass.
- AE3 (rank flip): same per-batter OBP within epsilon but flipped `position` ordinal → drift, names `position` as the drifted field.
- **AE3b (threshold proximity — synthetic, replaces fixture):** `bat_trend` differs because underlying delta is 0.049 vs 0.051 around 0.05 threshold → parity-unstable with `threshold_proximity` field set.
- **AE3c (quirk match — synthetic, replaces fixture):** `lineup_optimizer.tie_break` differs between Ruby and Go rankings; `quirkFor("lineup_optimizer", "tie_break")` returns `permittedGoBehavior`; engine emits parity-pass with `disposition: allowlisted-permitted`.
- **Doubleheader edge case (synthetic, replaces fixture):** input contains two `games` rows with the same `game_date`; engine handles correctly (no spurious drift).
- **Nil-last-outing edge case (synthetic, replaces fixture):** pitcher with `last_outing: null` in input; engine handles ISSUE-002 nil-handling path correctly.
- `known_ruby_defect` disposition: handcraft a synthetic input where Go produces the documented `go_correct_behavior`; engine emits parity-pass with the defect note.
- Categorical with no threshold: sparkline chars differ → drift.
- Edge case: null vs empty-string drift → drift (categorical class, special-case).
- Structured output: `Diff` marshals to JSON with all expected fields including `disposition`; round-trip preserves data.
- Parse failure (Ruby side): pass `[]byte("not json")` as Ruby input → Compare returns `(nil, *ParseError{Side: "ruby"})`; the snippet contains the unparseable bytes.
- Parse failure (Go side): pass valid Ruby JSON + malformed Go input → Compare returns `(nil, *ParseError{Side: "go"})`.
- **Integration smoke (uses anchor fixture):** run Ruby and Go both against `cache-anchor.db` via the U6 verify subcommand machinery; assert parity-pass for currently-ported commands.

**Verification:** `go test ./internal/parity/...` green. Engine handles 8+ edge cases against synthetic inputs; integration smoke passes against the anchor fixture.

---

### U6. Go verify subcommand + shell wrapper

**Goal:** Wire the cobra subcommand `gamechanger verify` (origin R1, R3) and the shell pipeline wrapper (origin R1). Implements R11 typed exit codes and R10 structured output flag.

**Requirements:** R1, R3, R10, R11, R13, R14.

**Dependencies:** U5.

**Files:**
- `internal/commands/verify.go` (new)
- `internal/commands/verify_test.go` (new)
- `internal/commands/root.go` (modify — register `verify` subcommand)
- `bin/verify-parity` (new — pass-through shell wrapper with zero logic)
- `bin/verify-parity.md` (new — usage docs)

**Approach:** `verify` takes a positional `<command>` arg (e.g., `brief`) and flags `--fixture <path>` (defaults to anchor), `--format human|json` (default human), `--strict` (categorical threshold-proximity is failure not warning). The command:

1. **Validate `<command>` against an explicit allowlist:**
   ```go
   var verifyAllowedCommands = map[string]bool{"progress": true}
   ```
   Anything not in the allowlist exits with the not-implemented code. New analytics commands are verify-able only by being added to this map. (`pitches` is excluded because it always invokes Syncer; `brief` is excluded until its dependency tree — PitchRules, LineupOptimizer — is ported. See U1 rationale.)

2. **Validate `--fixture <path>`:** call `filepath.EvalSymlinks(path)` first, then accept only if the RESOLVED path matches `internal/parity/testdata/*.db` (repo-relative) OR is under `~/.gamechanger/`. Reject other paths with the fixture-missing code. Symlinks that resolve outside the allowed scopes are rejected before any SQLite open is attempted — this closes the symlink-traversal surface. Error messages emit only `filepath.Base(<resolved path>)`, not the full path, to avoid leaking directory structure into AI-loop transcripts.

3. **Shell out to Ruby with `GAMECHANGER_HOME=<fixture dir>` and a 60s timeout:**
   `exec.CommandContext(ctx, "bundle", "exec", "exe/gamechanger", command, "--format", "json")` where `ctx, cancel := context.WithTimeout(context.Background(), 60*time.Second)` (and `defer cancel()`). Argv form, no shell-string interpolation. **Build `cmd.Env` as `os.Environ()` minus a secrets denylist** (`GC_TOKEN`, `GAMECHANGER_TOKEN`, any var matching the regex `(?i).*(_TOKEN|_SECRET|_KEY)$`), then append `GAMECHANGER_HOME=<dir containing the fixture>`. This lets `bundle exec` find Ruby/gems via PATH/GEM_HOME/HOME while denying secrets to the subprocess. If `bundle` or `exe/gamechanger` not found, exit with the Ruby-unavailable code. **If the timeout fires (`ctx.Err() == context.DeadlineExceeded`), exit with the new ruby-timeout typed code** — distinct signal from drift/error so the AI loop can recognize "Ruby hung, try next iteration" without ambiguity.

4. **Check the Ruby exit code before engaging the engine.** If `cmd.Run()` returns an `*exec.ExitError` with nonzero exit code (and `ctx.Err()` is NOT `DeadlineExceeded` — that's the timeout path), exit with the new **ruby-error** typed code. Capture the first 500 chars of stderr in the human-format error message so the AI loop has something actionable. The engine NEVER runs in this case — passing partial/empty Ruby stdout to `parity.Compare` would produce phantom drift the loop would try to "fix" by making Go match Ruby's panic state.
5. Invoke the Go command in-process against the same fixture. Capture stdout.
6. Call `parity.Compare(ruby, go)`. Return `Result`.
7. Print human or JSON output based on `--format`.
8. Exit with one of the typed codes: parity-pass, drift, parity-unstable (or collapsed into drift — Outstanding Question), Go-not-implemented, Ruby-unavailable, fixture-missing, **ruby-timeout** (60s subprocess timeout fired), **ruby-error** (Ruby exited nonzero before timeout), **ruby-parse-error** (Ruby stdout not valid JSON), **go-parse-error** (Go produced invalid JSON — engine signal, rare). Exact integers picked at implementation time.

**Shell wrapper:** `bin/verify-parity` is literally `gamechanger verify "$@"` plus a shebang and a one-line comment explaining it's a thin pass-through. All validation lives in `internal/commands/verify.go`; the wrapper does not add logic.

**Patterns to follow:** Existing cobra subcommands in `internal/commands/refresh.go`, `internal/commands/auth.go`.

**Test scenarios:**
- Happy path: anchor fixture, both Ruby and Go produce identical output → parity-pass exit code.
- AE3: Go produces different ranks → drift exit code, structured output names `position`.
- AE3b: Go output classifies as parity-unstable → parity-unstable exit code by default, drift exit code with `--strict`.
- AE-R14 / AE4: `verify lineup` when `lineup` is not in allowlist → not-implemented exit code with one-line message.
- Argv-injection: `verify "brief; rm -rf /"` → not-implemented exit code (the string is not in the allowlist, command is never constructed).
- AE-R11 / AE5: PATH unset such that `bundle` is missing → Ruby-unavailable exit code with install hint.
- AE6 (fixture missing): `--fixture /nonexistent.db` → fixture-missing exit code with basename in message (not the full path).
- Path scope: `--fixture /etc/passwd` → fixture-missing exit code (not in allowed scope) before any open is attempted.
- Symlink traversal: create symlink `~/.gamechanger/sneaky.db` → `/etc/passwd`; `--fixture ~/.gamechanger/sneaky.db` → fixture-missing exit code (resolved path is outside allowed scopes); error message contains basename only, never `/etc/passwd`.
- `--format json` produces valid JSON that round-trips through `parity.Result`.
- `--format human` produces a readable diff with field names and values (AE-R13).
- Ruby GAMECHANGER_HOME injection: Ruby subprocess reads from the chosen fixture's directory, NOT from `~/.gamechanger/cache.db`.
- Ruby-timeout: subprocess that sleeps 65 seconds (test helper) → ruby-timeout exit code; output names the timeout duration in the human-format error message.
- Secrets denylist: parent env contains `GC_TOKEN=secret123`, `AWS_SECRET_ACCESS_KEY=...`, and `MY_PASSWORD_KEY=...`; the Ruby subprocess does NOT see any of these (test inspects the subprocess env via a small Ruby probe script). PATH, GEM_HOME, HOME are inherited.
- Ruby-error: subprocess that exits 1 with a stack trace on stderr → ruby-error exit code; error message contains the first 500 chars of stderr; engine is NOT invoked (no phantom drift report).

**Verification:** `go test ./internal/commands/...` covers verify (mock the Ruby subprocess via test helper). Manual: `./gamechanger verify brief --fixture internal/parity/testdata/cache-anchor.db` against a Go binary with brief ported (from U1) exits with parity-pass.

---

## Post-ship Verification (manual, non-blocking)

The following is a manual checklist run AFTER U1-U6 land, not an implementation unit:

- Run `gamechanger verify progress --fixture ~/.gamechanger/cache.db` (local, not committed). Confirm parity-pass.
- Run the full AI-loop scenario against `lineup_optimizer.rb` — porting it to Go in `internal/analytics/lineup/` using `gamechanger verify lineup --strict` as the success criterion. Record iteration count, time-to-convergence, and surprises.

The port retrospective (covering U1 pilot results, harness performance, AI-loop convergence data, lessons for next port, and the Ruby-as-runtime-dep choice) is tracked as a separate doc task outside this plan's scope. It belongs in `docs/research/go-port-retro.md` when the analytics port is in motion.

---

## Scope Boundaries

(Carried forward from origin Scope Boundaries; preserved verbatim except where this plan resolves a previously-deferred item.)

- **Sync layer parity** (transport + SQLite write equivalence). Already proven by PR #3 smoke test.
- **Commands not yet ported to Go** (plan, lineup, equity, progress, availability, hitting). Each gets added when its Go port lands.
- **Property-based / random-input testing.** Fixed anchor fixture is the v1 answer.
- **Full Ruby-spec-suite parity.** The harness is a behavioral output check, not a port of `spec/`.
- **Live API integration during verify.** Runs entirely against local fixtures.
- **Permanent regression suite post-retirement.** Harness retires when Ruby retires.

### NOT in scope (eng-review additions)

- **YAML-externalized quirks allowlist.** Hardcoded `switch` in `engine.go` for 3 known quirks. Promote to YAML only if quirks exceed ~10 during the port. Rationale: matches harness lifetime (retires with Ruby).
- **Multi-fixture corpus (nil-last-outing, doubleheader, threshold-straddle as separate SQLite files).** Edge cases live as synthetic JSON pairs in `engine_test.go`. Faster to author, faster to run, no extra .db binaries in the repo. Add a fixture later only if the AI loop surfaces a real-world edge the anchor misses.
- **CI integration test (`internal/parity/parity_test.go` running Ruby via `exec.Command`).** Local `go test ./internal/parity/...` against the engine + anchor is enough for a solo dev. CI integration lands when CI itself lands (GO-6).

### Deferred to Follow-Up Work

- **Browser-cookie auto-import** (yt-dlp style) — relates to the broader auth question (GO-5 in TODOS.md), not the parity harness. Out of this plan's scope.
- **MCP-style remote oracle** — running the parity check as a hosted service so contributors without Ruby can still validate. Worth considering once the analytics port is in motion.
- **Property-based generation of fixture states** — v2 if single-fixture coverage proves insufficient in practice.
- **Port retrospective doc** — separate doc task, written once analytics port is in motion.
- **YAML quirks externalization** — promote from hardcoded `switch` to YAML if the audit reveals >10 quirks during the port.

---

## What already exists

- **Go `GAMECHANGER_HOME` support** — `internal/commands/root.go` already implements it; U1 is the Ruby symmetry, not new infrastructure.
- **SQLite open pattern** — `internal/store/store.go` already opens DSNs and applies pragmas; U3 reuses the same pattern.
- **In-memory SQLite test fixture pattern** — `internal/sync/integration_test.go` already demonstrates the seed-from-Go pattern; U5's synthetic-JSON tests draw from the same idea.
- **Cobra subcommand registration** — `internal/commands/refresh.go`, `internal/commands/auth.go` already establish the pattern; U6 follows it directly.
- **Ruby `--format json` output** — already exists for `brief` and other commands; the harness consumes it as-is.
- **`spec/gamechanger/pre_game_brief_spec.rb` Ruby test cases** — the U1 pilot ports them to Go table tests, then uses them as the oracle.

---

## System-Wide Impact

- **Ruby gem** gains `GAMECHANGER_HOME` env-var support in `Config` and `Storage` (U1, ~5 lines each + spec coverage). No edits to `lib/gamechanger/analytics/*` or to `spec/gamechanger/analytics/*`. The harness consumes the Ruby gem's existing `--format json` output; Ruby's analytics behavior is treated as the oracle.
- **Go module** gains `internal/parity/`, `internal/parity/anonymize/`, `internal/analytics/arc/` (from U1), `internal/commands/verify.go`, `cmd/anonymize-fixture/`, `cmd/progress-json/`. Adds `github.com/google/go-cmp` to `go.mod` (single transitive dep, widely used).
- **Repo** gains `bin/verify-parity`, `bin/pilot-diff`, 1 anchor fixture SQLite file in `internal/parity/testdata/`.
- **Privacy posture**: this plan commits an anonymized fixture to a public repo. U3 states an explicit threat model and falsification test for SEC-001. The substitution map stays local; a pre-commit hook to enforce its exclusion is an Outstanding Question.

---

## Inline ASCII Diagrams Required

Three files cross a complexity threshold where an ASCII diagram in the comment header pays for itself. Implementer writes these as part of the change, not as a follow-up. Diagrams stay accurate as the code evolves (per the eng-review skill's diagram-maintenance rule — stale diagrams are worse than no diagrams).

- **`internal/parity/engine.go`** — diff-pipeline precedence flowchart showing: parse Ruby + Go JSON → tree walk via go-cmp → collect Diffs → tag threshold_proximity on categorical diffs near known float thresholds → apply quirks `switch` (permittedGoBehavior / knownRubyDefect / notAQuirk) → compute Result.Status (parity-pass / drift / parity-unstable). One arrow per pipeline stage; show where ParseError exits early.

- **`internal/parity/anonymize/anonymize.go`** — anonymization pipeline showing: open source SQLite (read-only) → generate fresh seed (crypto/rand) → for each games row, shift date 0-365 days + substitute opponent → for each batter/pitcher stat row, substitute name + perturb counts ±3 within constraints → write fresh fixture + meta seed → write substitution map under ~/.gamechanger/. Make the trust boundary explicit (source = private real data, output = public-safe).

- **`internal/commands/verify.go`** — exit-code decision tree showing the 10 typed codes (parity-pass, drift, parity-unstable, Go-not-implemented, Ruby-unavailable, fixture-missing, ruby-timeout, ruby-error, ruby-parse-error, go-parse-error). One branch per condition; ordering matches the runtime check order so the diagram doubles as a code structure map.

---

## Dependencies / Prerequisites

- Ruby toolchain on user's local machine for U1 (pilot) and post-ship verification: `bundle exec exe/gamechanger` must work.
- `~/.gamechanger/cache.db` populated with real data (already exists from prior Ruby usage).
- `github.com/google/go-cmp` added to `go.mod` (U5).
- Local Go toolchain (already in use).
- No new external services, no API access required.

---

## Risk Analysis

| Risk | Likelihood | Impact | Mitigation |
|---|---|---|---|
| Pilot (U1) AI-loop fails to reduce diff size per iteration | Medium | High | Plan halts at U1 gate (trajectory criterion); user revisits scope before sinking U3-U6 effort |
| Anchor-only coverage misses a real-world edge case | Medium | Medium | The 3 named edge classes (nil-last-outing, doubleheader, threshold-straddle) are covered in `engine_test.go` against synthetic JSON pairs — same code path as fixture-driven, less infrastructure. If the AI loop surfaces a real-world edge the anchor + synthetic tests miss, add a fixture at that point |
| Anonymization is reverse-engineerable from committed fixture | Medium without falsification | High if true | U3 states an explicit threat model and a falsification test (fresh-AI-agent with public data only, <5% confidence) before the fixture is committed; if the test fails, switch to fully synthetic fixtures |
| `google/go-cmp` doesn't support the three-class shape cleanly | Low | Medium | Custom `cmp.Comparer` opts cover exactly this case; fallback is hand-rolled tree walker (~50 LOC) |
| Ruby JSON formatter is non-deterministic across runs | Low | Medium | U5 implementation includes running `bundle exec exe/gamechanger brief --format json` 10× against the anchor fixture and checking sha256 equivalence as a sanity step; if non-zero, add Ruby-side canonicalization |
| Quirks count exceeds the 3 hardcoded cases mid-port | Medium | Low | Hardcoded `switch` accommodates 10+ quirks readably; if it exceeds 10, refactor to YAML at that point. No upfront cost |
| Argv injection via `verify <command>` | Low after U6 | High if exploited | Explicit allowlist; argv-form `exec.Command`; covered by U6 test scenario |
| Committed anchor mutated by WAL/migrations on read | Low after U4 | Medium | U4's `fixture.go` opens with `mode=ro&immutable=1` and skips migrations; covered by a U4 test scenario |

---

## Phased Delivery

**Phase 1 (Gate):** U1 — ~2 hours of work (env-var injection + pilot). Decision point.

**Phase 2 (Foundation):** U3 alone. ~1 day. (No U2; quirks are hardcoded in U5.)

**Phase 3 (Anchor):** U4. ~half-day.

**Phase 4 (Core):** U5. ~1-2 days. This is the largest single unit; includes the 3-quirk hardcoded `switch` and the synthetic-JSON edge-case tests.

**Phase 5 (Surface):** U6. ~half-day. (No U7; CI integration test deferred.)

**Total estimate:** ~3-4 days of focused work, plus U1's ~2-hour gate. Stopping at any phase is fine — each phase leaves the repo in a consistent state. Post-ship verification (manual checklist + retro) is tracked separately.

---

## Outstanding Questions

### Resolve Before Implementation

- [Affects U1] Should the pilot use Codex or Claude as the AI loop? (Not strictly blocking — either works — but worth committing before starting so iteration count is comparable.)
- [Affects U6 / R11] Collapse parity-unstable into the drift exit code (5 codes total, matches origin R11 "at least five") OR keep parity-unstable as a separate exit code (6 codes total, distinct semantics for the AI loop). Contested design call against origin language.

### Deferred to Implementation

- [Affects U5] Exact `cmp.Option` shape for the three-class system — best resolved while writing tests.
- [Affects U6] Exact integer values for the typed exit codes — pick at implementation time; document in `internal/commands/verify.go` doc comment. Avoid conflicts with Go runtime exit codes (1 = general error, 2 = misuse-of-shell-builtins on some platforms).
- [Affects U1] Gate Decision Protocol if the pilot marginally fails (diff reduces in 4 iterations but doesn't reach parity in budget of 5): who decides "proceed anyway," where is the decision logged, what is the exit criterion for proceeding? Capture as `GATE-DECISION.md` if the case arises.
- [Affects U3] Pre-commit hook to enforce `parity-substitution-*.yml` exclusion regardless of file location (defense in depth against `git add -f`). Implementation deferred; hook installation step documented in U3's README.
- [Affects U3] Whether `internal/parity/anonymize/` earns its keep as a separate sub-package vs. collapsing into `cmd/anonymize-fixture/` (single current consumer). Go-package-taste call; revisit if the harness engine ever calls anonymization logic directly.
- [Affects U5 / Risk Analysis] When the audit surfaces quirk #11 (if ever), promote the hardcoded `switch` to a YAML-driven allowlist. Threshold is 10; revisit at that point.

### From 2026-05-14 reviews (ce-doc-review + plan-eng-review passes)

- ce-doc-review applied 19 substantive fixes and surfaced 5 open questions (above).
- plan-eng-review Step 0 reduced scope: dropped U2 (YAML quirks → hardcoded `switch`), dropped 3 of 4 fixtures (anchor only), dropped U7 (CI integration test → local `go test`). Net: ~30 files → ~16 files, 4 new packages → 3 new packages, 4-5 days → 3-4 days.

---

## GSTACK REVIEW REPORT

| Review | Trigger | Why | Runs | Status | Findings |
|--------|---------|-----|------|--------|----------|
| CEO Review | `/plan-ceo-review` | Scope & strategy | 1 | CLEAR | mode: SCOPE_EXPANSION, 12 proposals, 6 accepted, 6 deferred |
| Codex Review | `/codex review` | Independent 2nd opinion | 1 | ISSUES (stale, pre-rewrite) | findings at commit c50d487; likely addressed by ce-doc-review + this eng review |
| Eng Review | `/plan-eng-review` | Architecture & tests (required) | 3 (latest 2026-05-14) | CLEAR | mode: SCOPE_REDUCED, 7 issues found (0 critical gaps); plan reduced from 8 units → 5 units |
| Design Review | `/plan-design-review` | UI/UX gaps | 0 | — | n/a — CLI tool, no UI |
| DX Review | `/plan-devex-review` | Developer experience gaps | 0 | — | not run |

- **UNRESOLVED:** 0 across all reviews
- **VERDICT:** CEO + ENG CLEARED — ready to implement. Codex pre-rewrite findings already absorbed via ce-doc-review (19 fixes) + this eng-review (7 fixes). Re-run /codex review post-implementation if desired, not blocking.
