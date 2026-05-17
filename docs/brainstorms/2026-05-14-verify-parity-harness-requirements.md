---
date: 2026-05-14
topic: verify-parity-harness
---

# Verify-parity harness for the Ruby → Go analytics port

## Summary

A `verify-parity` capability that compares Ruby and Go output for `gamechanger brief` against a frozen anonymized SQLite fixture, using behavioral equivalence (not byte-exact) as the match bar — exposed as three layered surfaces (manual shell script, Go subcommand for AI-loop oracles, Go test fixture) sharing one diff implementation.

---

## Problem Frame

The Ruby gem's analytics layer is 347 LOC across `pitch_rules.rb`, `lineup_optimizer.rb`, `development_arc.rb`, and `pre_game_brief.rb` — pure-logic code with zero I/O, exercised by 100% line / 85%+ branch coverage on the Ruby side. The Go port (PR #3) covers transport, storage, and sync but no analytics. The user shipped that port intending to retire the Ruby gem once Go reaches parity.

Without a parity oracle, every analytics module port faces the same uncertainty: does the Go output match Ruby on real data, or just on the unit tests the porter happened to write? A Go `lineup_optimizer` could pass hand-written tests, ship, and silently rank players differently than Ruby for a month before a coach notices. Drift would be invisible until a Saturday morning when the suggested lineup looked wrong.

The pain compounds: with no parity tool, the analytics port has to be hand-crafted by a Go-fluent human who reads both the Ruby source and the Ruby tests, then writes Go that matches both. That's the most expensive use of the user's time in the entire backlog — pure-logic translation is exactly what AI assistance is good at, but only if there's a verifiable pass/fail signal. Without one, AI translations can't be trusted; with one, the user's time stays on features that AI can't ghostwrite (watch v1, ask, parents).

---

## Actors

- A1. **Solo developer (the user)** — runs the shell pipeline manually before a game or after a port commit to spot-check that the Go output still matches Ruby on real data; reads diffs to debug Go drift.
- A2. **AI port loop (Codex / Claude)** — calls the Go subcommand as a pass/fail oracle; interprets typed exit codes and structured diff output; iteratively edits Go analytics code until parity holds.
- A3. **CI / `go test`** — runs the Go test fixture on every push; fails the build if a parity regression slips in via an unrelated refactor.

---

## Key Flows

- F1. **Manual spot-check** (A1)
  - **Trigger:** Saturday morning before a game, or after committing a Go analytics change
  - **Actors:** A1
  - **Steps:** Run the shell pipeline; if exit 0, parity confirmed and the dev moves on; if non-zero, dev reads the field-by-field diff and judges whether Go or Ruby is correct
  - **Outcome:** Dev either ships confidently or has a specific lead on what drifted
  - **Covered by:** R1, R2, R5

- F2. **AI port loop iteration** (A2)
  - **Trigger:** Loop has just written or modified Go analytics code and needs to know if it matches Ruby
  - **Actors:** A2
  - **Steps:** Invoke the Go subcommand headlessly; parse the typed exit code; if parity drift, read structured diff naming which fields drifted and by how much; edit the Go code accordingly; re-invoke; repeat until exit 0
  - **Outcome:** AI loop converges to a parity-passing Go implementation or escalates after N attempts
  - **Covered by:** R1, R3, R10, R11, R12

- F3. **Regression catch in CI** (A3)
  - **Trigger:** Push of an unrelated refactor that accidentally changes lineup_optimizer output ordering
  - **Actors:** A3
  - **Steps:** CI runs `go test`; the parity test fixture detects the drift and fails with a structured error
  - **Outcome:** PR is blocked from merge until the regression is fixed or the parity expectations are explicitly updated
  - **Covered by:** R1, R2, R7

---

## Requirements

**Verification surfaces**

- R1. Three entry points exist: a shell pipeline for manual spot-checks, a Go subcommand for AI-loop oracles, and a Go test fixture for regression catching. Each surface is invocable independently.
- R2. The diff result for any given pair of outputs is identical regardless of which entry point triggers it. Drift detected by one surface must be detected by all surfaces, and vice versa. The mechanism (shared library vs shared subprocess vs other) is a planning decision; the invariant is the requirement.
- R3. The Go subcommand is invokable headlessly (no TTY) and returns typed exit codes — no interactive prompts, no expected user input.

**Match semantics**

- R4. Comparison uses three distinct classes by field type. (a) Raw numeric fields compare with an epsilon tolerance. (b) Ordinal and integer fields (`position`, ranks, counts, IDs) compare byte-exact — a rank flip is never within tolerance. (c) Categorical and string fields (trend arrows, sparkline characters, narrative archetypes, status enums) compare byte-exact AND additionally flag any underlying float that sits within epsilon of a known threshold ("parity-unstable" warning even when outputs happen to agree this run). Map/hash keys compare order-independent; ISO-8601 timestamps normalize to a canonical form before comparison.
- R5. When the diff is non-empty, the comparison emits a human-readable diff showing field-by-field mismatches — not an opaque "doesn't match" message. Mismatches are tagged with their comparison class (numeric/ordinal/categorical) so the consumer can interpret severity.
- R6. The Ruby analytics layer must be audited before the fixture is frozen, with known quirks (tie-breaking under unstable sort, first-row-as-team-total assumptions, nil-half delta-zeroing in narrative_for, etc.) catalogued in `docs/research/ruby-quirks-allowlist.md`. The harness consults this allowlist: documented deviations from Ruby are pass-states for the Go port, not drift.

**Test corpus**

- R7. A canonical anonymized SQLite fixture lives in the repo and is the default input for all three surfaces. The same fixture exercises every parity check. **Repo-visibility precondition:** the fixture is only committable to a public repo when R8 has been satisfied; on a private repo the lighter R8 (player-name substitution only) is acceptable.
- R8. The fixture is anonymized at a level that resists re-identification on a public youth-baseball dataset. Anonymization includes: (a) real player names mapped to synthetic ones; (b) opponent and league/team names synthesized; (c) game dates shifted by a per-fixture random offset that preserves day-of-week and relative spacing; (d) stat-value perturbation within statistically plausible ranges so per-game stat-line fingerprints no longer cross-reference to public box scores; (e) the substitution map is written to a path covered by `.gitignore` (e.g., under `~/.gamechanger/`) and the bootstrap script verifies the path is excluded before producing the fixture.
- R9. The bootstrap script in R8 is the single source of truth for fixture generation; re-running it produces an updated fixture. Schema-migration handling is deferred — when migrations land post-port, fixture regeneration is a one-time task, not ongoing tooling concern.

**AI loop integration**

- R10. The Go subcommand emits machine-readable output (structured) in addition to human-readable output, controlled by a flag. An AI loop can parse the structured output without scraping prose.
- R11. Typed exit codes distinguish at least five outcomes: parity pass, parity drift detected, Go command not yet implemented, Ruby unavailable on the host, and corpus or fixture missing. The exact integer values are a planning concern; the categories are a requirement.
- R12. When drift is detected, the structured output names which fields drifted and by how much — enough signal for an AI loop to know what to fix without re-running Ruby to compare.

**Scope progression**

- R13. v1 covers the `brief` command only. The harness is structured so additional commands can be added when they are ported to Go, without restructuring the diff engine.
- R14. Commands not yet implemented in Go return the "not implemented" exit code (per R11), not "drift detected." An AI loop can distinguish "Go has no code for this command" from "Go has code that produces the wrong answer."

---

## Acceptance Examples

- AE1. **Covers R4(a).** Given a fixture where Ruby and Go produce structurally identical brief JSON but Ruby formats `season_obp` as `0.456` and Go as `0.4561` (raw numeric class, epsilon 0.001), when `verify-parity` runs, the result is parity pass.
- AE2. **Covers R4 (map ordering).** Given Ruby's `brief` JSON has the same keys as Go's but in a different insertion order, when `verify-parity` runs, the result is parity pass.
- AE3. **Covers R4(b), R5, R12.** Given Ruby ranks the lineup `[Mason, Asher]` (position 1, 2) and Go produces the same per-batter OBP within epsilon but ranks `[Asher, Mason]` (position 1, 2), when `verify-parity` runs, the result is parity FAIL — the `position` field is class (b) ordinal and must byte-match. Output names the lineup-rank field as drifted.
- AE3b. **Covers R4(c).** Given Ruby produces `bat_trend: "→"` (delta = 0.049) and Go produces `bat_trend: "↑"` (delta = 0.051) — both within epsilon of the 0.05 threshold — when `verify-parity` runs, the result is parity FAIL with a "parity-unstable threshold proximity" warning identifying the underlying delta.
- AE3c. **Covers R6.** Given the Ruby quirks allowlist documents that `LineupOptimizer.ranked` ties break by input-row order (unstable sort), and the Go port breaks ties by alphabetical player name, when `verify-parity` runs on a fixture with tied OBPs, the result is parity pass — the deviation is documented as allowed.
- AE4. **Covers R11, R14.** Given the fixture, when the Go subcommand runs `verify brief` and Go has no `brief` command yet, the exit code distinguishes "Go not implemented" from "Go produced drift" and the message tells the caller which.
- AE5. **Covers R11.** Given that `bundle exec exe/gamechanger` is not available on `$PATH`, when `verify-parity` runs, the exit code distinguishes "Ruby missing" from "Go produced drift," and the human-readable message points the user at the Ruby install step.
- AE6. **Covers R8, R9.** Given a local `~/.gamechanger/cache.db` with real player names, when the fixture-bootstrap script runs, the resulting committed fixture contains synthetic names but the same number of games, outings, and at-bats as the source.

---

## Success Criteria

- **Human outcome.** The user can run a single command before a Saturday game and see, in under 10 seconds, whether the current Go port of analytics matches Ruby's `brief` output for their team's actual schedule and roster. Confidence becomes mechanical instead of judgment-based.
- **AI handoff quality.** An AI port loop calls the Go subcommand as a pass/fail oracle, parses the exit code and structured diff, and iteratively converges a Go analytics port to parity without human intervention for each iteration. The pass criterion is unambiguous.
- **CI integration (temporary).** While the harness exists, a regression introduced by an unrelated refactor fails `go test` and names which field drifted. The CI wiring is deliberately temporary — it's removed in the same commit that retires Ruby (see Clean retirement below). No long-term Go regression suite is being established here.
- **Clean retirement.** When Ruby is retired, the harness is deleted in the same commit that removes the Ruby analytics — leaving no orphan tooling that depends on the gone-away Ruby gem.

---

## Scope Boundaries

- **Sync layer parity** (transport + SQLite write equivalence). Already proven by the live smoke test in PR #3; not the analytics layer this harness exists to verify.
- **Commands not yet ported to Go** (plan, lineup, equity, progress, availability, hitting, pitches). Each gets added when its Go port lands; structuring v1 to handle them now is YAGNI.
- **Property-based / random-input testing.** A single anonymized fixture is enough for v1. Generating random states adds complexity without obviously improving the AI-loop signal.
- **Full Ruby-spec-suite parity.** The harness is a behavioral output check, not a port of `spec/`. The Ruby specs stay where they are.
- **Live API integration during verify.** Runs entirely against the local fixture. No network calls, no `gc-token`, no MFA dance.
- **Permanent regression suite post-retirement.** When Ruby is gone, so is the harness. It is not the long-term Go test suite.
- **Implementation specifics.** Exact paths, command-flag names, JSON normalization implementation, exit-code integer values, error-message wording, library choice for structural diff. Those live in `/ce-plan`.

---

## Key Decisions

- **v1 scope is `brief` only.** Rationale: `brief` exercises all four analytics modules (`pitch_rules`, `lineup_optimizer`, `development_arc`, plus `pre_game_brief` as coordinator) in one command path. Verifying it covers the analytics layer with one diff invocation. Adding more commands first would dilute focus without proving more about the analytics.
- **Three-class comparison (R4) over single-epsilon.** Numeric epsilon alone admits false-pass on rank flips, threshold-derived categoricals, and sparkline drift — the underlying floats agree to epsilon while the user-visible output diverges. Ordinal fields compare byte-exact; categorical fields flag threshold-proximity. This is the right correctness bar for an oracle whose output drives an AI-loop iteration.
- **Anonymized frozen fixture over live cache.** Reproducibility is non-negotiable for an AI loop. Anonymization is non-negotiable for a public repo containing minors' data — and per R8 includes opponent names + date-shift + stat-value perturbation, not just name substitution (synthesized names alone leave date+opponent+stat-line as a re-identification fingerprint against public GameChanger team pages).
- **Ruby is an oracle, not infallible (R6).** Treating Ruby's output as canonical without a quirks allowlist would silently force the Go port to replicate Ruby's bugs. The allowlist document is part of the harness scope, not an afterthought.
- **Three layered surfaces over one (mechanism deferred).** Each actor (human, AI, CI) has different signal needs. The shape of the shared mechanism (Go library vs subprocess vs other) is a planning decision; R2 captures only the behavioral invariant.
- **Typed exit codes over single pass/fail.** An AI loop needs to distinguish "not implemented" from "drift" to decide whether to keep iterating, escalate, or stop. A binary pass/fail makes the loop unable to converge meaningfully.

**FYI / non-blocking observations from doc-review:**

- **Ruby JSON formatter pre-rounds floats to 3 decimals** at the formatter boundary (e.g., `seven_day_obp: slot.seven_day_obp.round(3)`). AE1's example operates at the post-rounding layer; sub-0.001 drift is invisible there. Planning needs to decide whether parity diffs the post-rounded JSON (the only thing Ruby currently exposes) or an unrounded structured form (which would require a new Ruby code path).
- **Ruby is a runtime dependency on every parity invocation, not a fallback.** The fixture is SQLite input, not pre-recorded Ruby output, so every harness run shells out to `bundle exec exe/gamechanger`. Planning needs to decide: record Ruby output once into golden files (CI doesn't need Ruby) vs re-run Ruby live every check (CI needs the full Ruby toolchain).

---

## Dependencies / Assumptions

- The Ruby toolchain (`bundle exec exe/gamechanger`) is reachable from the verify surfaces — the developer has the Ruby gem installed locally. The `Ruby unavailable` exit code (R11) is a fallback, not a primary path.
- The Ruby JSON formatter for `brief` is stable. If the Ruby output shape changes, the fixture and parity expectations need to update in lockstep — that change has to be deliberate, not silent.
- The fixture lifetime ≤ Ruby's lifetime: when Ruby retires, both the fixture and the harness retire with it.
- Anonymization is one-way: once a committed fixture is generated, the original real-name → synthetic-name substitution map is stored locally, not committed.
- Ruby's output is treated as ground truth **except for documented quirks** (see R6 + `docs/research/ruby-quirks-allowlist.md`). Latent bugs exist in any code — the harness's job is to surface them via the allowlist mechanism, not to laminate them into the Go port unexamined. Adversarial review identified three specific concrete cases that need the audit pass before the fixture is frozen: `PreGameBrief#equity_flags` first-row-as-team-total assumption, `LineupOptimizer#ranked` unstable-sort tie-breaking, `DevelopmentArc.narrative_for` nil-half delta-zero behavior.

---

## Outstanding Questions

### Resolve Before Planning

- [Affects whole plan][Strategic] **Pilot before commit (from doc-review F4).** Spike a 2-hour hand-port of `pitch_rules.rb` (41 LOC, the smallest analytics module) with a 5-line shell `diff` script. If a single AI session can converge it to parity using that signal shape, the full harness investment is justified. If not, the harness scope needs revisiting before R1-R14 ship. The AI-loop convergence claim is the load-bearing premise; 2 hours to validate beats 1-2 days to build on an unverified bet.
- [Affects R7, R8][Strategic] **Single-fixture coverage gap (from doc-review F6).** R7 commits to one fixture. Adversarial review named ≥7 real-world classes a one-fixture corpus would miss (nil `last_outing`, doubleheaders, mid-season roster changes, canceled games, tied OBPs, exact threshold straddlers, preseason empties). Decide before fixture freeze: accept "parity is verified for this fixture's distribution only" as a Scope Boundary, OR add 2-3 hand-crafted edge-case fixtures, OR add property-based generation. Status quo overfits.
- [Affects R8][Privacy] **Verify SEC-002 substitution-map lifecycle:** R8(e) requires the map under `.gitignore`. Decide: is the map destroyed after fixture generation, retained for regeneration, or rotated per fixture version? Cross-version linkage attack (same-real-name → same-synthetic-name across fixture v1 and v2) is the threat to scope.
- [Affects R4(c)][Coverage] **Missing acceptance examples (from doc-review F8).** R2, R7, R9, R11, R13, R14 lack AEs. Either add coverage in planning or downgrade the requirements to Key Decisions if behavior is too high-level for an executable example.

### Deferred to Planning

- [Affects R2][Technical] Which Go library implements the structural diff with epsilon — write from scratch, or adopt `google/go-cmp` (with a custom `cmp.Comparer` for floats) or `kylelemons/godebug`?
- [Affects R7, R8][Technical] Where exactly does the fixture live (`internal/parity/testdata/cache.db` vs `spec/fixtures/parity-cache.db` vs `testdata/parity-cache.db` at the repo root) given the Ruby and Go projects share the same repo?
- [Affects R10, R12][Needs research] Should the structured output for AI-loop consumption be JSON (most portable), a more specific schema (better validation), or a domain-specific format that names the drift in baseball terms ("lineup rank mismatch at position 3")?
- [Affects R6][Technical] What's the format of `docs/research/ruby-quirks-allowlist.md` — one quirk per heading with affected-fields metadata, or a structured YAML the harness can parse?
- [Affects R8(d)][Technical] How are stats perturbed to break public-box-score fingerprints while preserving statistical relationships the analytics depend on (per-batter OBP rank, pitcher rest-day distribution, etc.)? This is the trickiest part of the SEC-001 mitigation.
