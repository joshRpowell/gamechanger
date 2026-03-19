---
title: "feat: Autoresearch experiment — optimize test suite for developer iteration speed"
type: feat
status: active
date: 2026-03-19
origin: docs/brainstorms/2026-03-19-test-speed-autoresearch-brainstorm.md
---

# feat: Autoresearch Test Suite Speed Experiment

## Overview

Set up a new `/autoresearch` loop that autonomously optimizes the gamechanger gem's test suite for **developer iteration speed**, targeting **<0.10s wall-clock time** for a full `bundle exec rspec` run without coverage instrumentation. The previous autoresearch experiment targeted 100% line coverage (achieved). This experiment repurposes the loop infrastructure with a new metric, new `autoresearch.sh`, and a new `autoresearch.md`.

Current baseline: **~0.26s** total (0.22s file load + 0.04s execution) for 493 examples. File load time dominates at 83% — SimpleCov and Ruby's require chain are the primary suspects.

## Problem Statement / Motivation

While 0.26s is objectively fast, the *psychological* threshold for a tight dev feedback loop is ~0.10s. Above that, developers often switch context. The goal is a command developers run hundreds of times per day that feels instant. The coverage experiment proved the autoresearch loop can find non-obvious wins autonomously; speed optimization is the natural next target.

Additionally, always-on SimpleCov penalizes every developer test run when coverage is only needed at CI time or explicitly. Separating dev-mode from coverage-mode is a good practice independent of the experiment.

## Proposed Solution

Three coordinated changes bootstrap the experiment, then the loop runs autonomously:

1. **Gate SimpleCov** behind `ENV['COVERAGE']` in `spec/spec_helper.rb` — the P0 win estimated at 0.05–0.10s
2. **Rewrite `autoresearch.sh`** to measure wall-clock seconds instead of coverage percentages
3. **Rewrite `autoresearch.md`** with the new objective, metric, and experiment search space

Once bootstrapped, the loop tries experiments in priority order, keeps improvements, discards regressions, and logs each run to `autoresearch.jsonl`.

## Technical Considerations

### Architecture Impacts

- `spec/spec_helper.rb` is loaded on every test run via `.rspec`'s `--require spec_helper`. Adding an `ENV['COVERAGE']` guard is a single conditional that has zero effect on test behavior — only on instrumentation.
- `autoresearch.sh` replaces coverage metric parsing with `date +%s%N` timing. The JSONL format stays identical; only the metric name and values change.
- `autoresearch.md` is a documentation/instruction file for the loop agent — rewriting it resets the experiment context without touching any test or source files.

### New `autoresearch.sh` Design

```bash
#!/usr/bin/env bash
set -euo pipefail

# Fast syntax pre-check (non-fatal)
ruby -c lib/**/*.rb spec/**/*_spec.rb 2>/dev/null || true

# Measure wall-clock time for dev-mode run (no SimpleCov)
START=$(date +%s%N)
OUTPUT=$(bundle exec rspec --format progress 2>&1)
EXIT_CODE=$?
END=$(date +%s%N)

DURATION=$(echo "scale=3; ($END - $START) / 1000000000" | bc)

# Guard: parse failure count
FAILURES=$(echo "$OUTPUT" | grep -E "^[0-9]+ example" | grep -oE "[0-9]+ failure" | grep -oE "^[0-9]+" || echo "0")

echo "$OUTPUT"
echo "METRIC time_seconds=$DURATION"
echo "METRIC test_failures=$FAILURES"
exit $EXIT_CODE
```

Key properties:
- No `COVERAGE` env var set → SimpleCov never loads
- `time_seconds` is the primary metric (lower is better, `bestDirection: lower`)
- `test_failures` is a guard secondary metric — any nonzero value should trigger discard
- Exit code propagates, so crashes are detected correctly

### Experiment Sequence (priority order for the loop)

| # | Experiment | Files Changed | Estimated Savings |
|---|-----------|---------------|------------------|
| P0 | Gate SimpleCov behind `ENV['COVERAGE']` | `spec/spec_helper.rb` | 0.05–0.10s |
| P1 | Add `bootsnap` gem (bytecode + require cache) | `Gemfile`, `spec/spec_helper.rb` | 0.05–0.15s |
| P2 | Remove `--color` from `.rspec` (skips ANSI work) | `.rspec` | ~0.005s |
| P3 | Replace `config.order = :random` with `defined` | `spec/spec_helper.rb` | ~0.005s |
| P4 | Switch format to `--format dot` in `.rspec` | `.rspec` | ~0.003s |
| P5 | Profile slow requires with `ruby-prof` | analysis only | identifies targets |
| P6 | `parallel_tests` gem — split across CPU cores | `Gemfile`, config | 40–60% on 4-core |
| P7 | Lazy-load heavy requires inside `let` blocks | `spec/**/*_spec.rb` | varies |
| P8 | Trim shared contexts — reduce per-example setup | `spec/spec_helper.rb` | varies |

### Guard Conditions (non-negotiable)

1. **Test count must stay ≥ 493** — any experiment that causes example count to drop is an automatic discard
2. **`COVERAGE=1 bundle exec rspec` must still report 100% line coverage** — run this verification before committing any `keep`
3. **Zero test failures** — `test_failures > 0` in METRIC output triggers automatic discard

### Performance Model

```
Current:     0.26s = 0.22s load + 0.04s execution
After P0:   ~0.18s (SimpleCov removed)
After P1:   ~0.08s (bootsnap bytecode cache)
Target:      < 0.10s ✓
```

P0 + P1 together are expected to hit the target. Remaining experiments squeeze further.

## System-Wide Impact

- **CI:** Existing CI (if any) should use `COVERAGE=1 bundle exec rspec` to preserve coverage reporting. The bare `bundle exec rspec` command becomes the fast dev path.
- **CLAUDE.md:** Update the "Run tests" line to document both modes.
- **Developer experience:** Running `bundle exec rspec` just got faster; coverage requires an explicit flag. This is the conventional Ruby gem pattern (e.g., SimpleCov's own README recommends env-var gating).
- **No impact on lib/ code** — all changes are in spec infrastructure.

## Acceptance Criteria

- [ ] `bundle exec rspec` completes in <0.10s with zero failures
- [ ] `COVERAGE=1 bundle exec rspec` still reports 100% line coverage, 493+ examples
- [ ] `autoresearch.sh` emits `METRIC time_seconds=` and `METRIC test_failures=` lines
- [ ] `autoresearch.md` describes the speed experiment objective and the P0–P8 search space
- [ ] `autoresearch.jsonl` contains a config header with `bestDirection: lower` and `metricName: time_seconds`
- [ ] `spec/spec_helper.rb` gates SimpleCov behind `ENV['COVERAGE']`
- [ ] `CLAUDE.md` documents both run modes (`bundle exec rspec` and `COVERAGE=1 bundle exec rspec`)

## Implementation Plan

### Phase 1: Bootstrap (manual, sets up the loop)

**Files to change:**

**`spec/spec_helper.rb`** — gate SimpleCov:
```ruby
# Before:
require 'simplecov'
SimpleCov.start do
  enable_coverage :branch
  add_filter '/spec/'
end

# After:
if ENV['COVERAGE']
  require 'simplecov'
  SimpleCov.start do
    enable_coverage :branch
    add_filter '/spec/'
  end
end
```

**`autoresearch.sh`** — rewrite for time measurement (see Technical Considerations above)

**`autoresearch.md`** — new objective:
```markdown
# Autoresearch: Test Suite Speed

## Objective
Minimize wall-clock time for `bundle exec rspec` (dev mode, no SimpleCov).
Current baseline: ~0.26s. Target: <0.10s.

## Metrics
- **Primary**: time_seconds (seconds, lower is better)
- **Secondary**: test_failures (must stay 0)

## How to Run
`./autoresearch.sh` — outputs `METRIC time_seconds=N.NNN` and `METRIC test_failures=N`

## Files in Scope
- spec/spec_helper.rb
- spec/**/*_spec.rb
- .rspec
- Gemfile

## Off Limits
- lib/ source files
- Deleting existing tests (count must stay ≥ 493)

## Constraints
- COVERAGE=1 bundle exec rspec must still report 100% line coverage
- test_failures must remain 0

## What's Been Tried
[Updated by the loop as experiments run]
```

**`autoresearch.jsonl`** — initialize new segment:
```json
{"type":"config","name":"gamechanger-test-speed","metricName":"time_seconds","metricUnit":"s","bestDirection":"lower"}
```

**`CLAUDE.md`** — add two-mode documentation:
```markdown
## Testing

Run tests (dev mode, fast):    `bundle exec rspec`
Run tests (with coverage):     `COVERAGE=1 bundle exec rspec`
Test directory: `spec/`
```

### Phase 2: Autoresearch Loop (autonomous)

Once Phase 1 is committed, start the loop:
```bash
git checkout -b autoresearch/test-speed-$(date +%Y%m%d)
# Initialize JSONL with baseline run
./autoresearch.sh  # measure baseline
# Then loop: try P0, P1, P2... keep winners, discard losers
```

The loop runs the P0–P8 experiments in order, logging each to `autoresearch.jsonl` and updating `experiments/worklog.md` and `autoresearch-dashboard.md` after each run.

## Dependencies & Risks

| Risk | Mitigation |
|------|-----------|
| bootsnap incompatibility with Ruby 3.4.x | Check bootsnap Gemfile.lock after add; verify tests still pass |
| `date +%s%N` not available on macOS BSD date | Use `gdate` fallback or `ruby -e 'puts (Time.now.to_f * 1000).to_i'` |
| SimpleCov removal changes test behavior | All tests still run — SimpleCov only instruments, doesn't gate |
| parallel_tests race conditions in SQLite in-memory | Use file-based SQLite in parallel mode; keep `:memory:` for sequential |
| bootsnap caching stale after source changes | bootsnap detects file mtime; no stale cache risk in practice |

**Note on `date +%s%N`:** macOS ships BSD date without `%N`. Use this portable fallback in `autoresearch.sh`:
```bash
START=$(ruby -e 'print (Time.now.to_f * 1000000000).to_i')
# ... run rspec ...
END=$(ruby -e 'print (Time.now.to_f * 1000000000).to_i')
DURATION=$(ruby -e "printf('%.3f', ($END - $START) / 1e9)")
```

## Success Metrics

- **Primary:** `bundle exec rspec` wall-clock time < 0.10s
- **Secondary:** Zero regressions — `COVERAGE=1 bundle exec rspec` still 100% line coverage, 493+ examples, 0 failures
- **Bonus:** Autoresearch loop documents which experiments worked and which didn't, creating a reusable speed-optimization playbook for other Ruby gems

## Sources & References

### Origin

- **Brainstorm document:** [docs/brainstorms/2026-03-19-test-speed-autoresearch-brainstorm.md](../brainstorms/2026-03-19-test-speed-autoresearch-brainstorm.md)
  - Key decisions carried forward: (1) ENV['COVERAGE'] gate for SimpleCov, (2) time_seconds as primary metric, (3) P0–P8 experiment priority order, (4) guard: test count ≥ 493 + coverage regression check

### Internal References

- Current `spec/spec_helper.rb` — SimpleCov unconditional at line 1
- Current `autoresearch.sh` — coverage metric script to replace
- Current `autoresearch.md` — coverage experiment (completed, 6 runs)
- `autoresearch-dashboard.md` — shows coverage experiment result: 100% line, 85.87% branch

### External References

- [SimpleCov README — env-var gating pattern](https://github.com/simplecov-ruby/simplecov#getting-started)
- [bootsnap README — Ruby require speedup](https://github.com/Shopify/bootsnap)
- [parallel_tests README — RSpec parallelization](https://github.com/grosser/parallel_tests)
