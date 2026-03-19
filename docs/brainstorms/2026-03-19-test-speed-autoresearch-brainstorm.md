# Brainstorm: Autoresearch for Test Suite Speed

**Date:** 2026-03-19
**Status:** Draft

---

## What We're Building

An `/autoresearch` experiment that autonomously optimizes the gamechanger gem's test suite for developer iteration speed — targeting **<0.10s wall-clock time** for a full `bundle exec rspec` run (without coverage). The loop will try modifications to `spec_helper.rb`, `.rspec`, spec files, and the Gemfile, keep whatever improves speed, and discard regressions.

**Context:** The suite currently runs in ~0.26s for 493 examples. File load time dominates (0.22s = 83% of total). All 493 tests pass. 100% line coverage is already achieved. SimpleCov is always-on and is likely the largest single overhead to eliminate.

---

## Why This Approach

The primary dev loop metric is **wall-clock time without coverage** — the number developers experience while iterating. A separate coverage command (`COVERAGE=1 bundle exec rspec`) retains the full SimpleCov audit. Autoresearch optimizes the non-coverage path autonomously, exploring a wide search space of load-time reductions without requiring developer attention.

---

## Key Decisions

### 1. Two-mode setup (Dev vs Coverage)

Gate SimpleCov behind `ENV['COVERAGE']` in `spec_helper.rb`. The autoresearch script measures the dev-mode command (`bundle exec rspec`). Coverage runs are a separate explicit step.

```ruby
# spec/spec_helper.rb
if ENV['COVERAGE']
  require 'simplecov'
  SimpleCov.start { enable_coverage :branch; add_filter '/spec/' }
end
```

**Why:** SimpleCov is estimated to save 0.05–0.10s alone and is the highest-confidence win. It also makes the split explicit and useful beyond the experiment.

### 2. Metric: wall-clock time (seconds, 3 decimal places)

```bash
METRIC time_seconds=0.143
```

Lower is better. Minimum floor: ~0.03s (Ruby startup + 493 examples at 0.05ms each). Realistic target: <0.10s with SimpleCov removed and bootsnap caching.

### 3. Autoresearch script measures dev-mode only

```bash
#!/bin/bash
set -euo pipefail

START=$(date +%s%N)
bundle exec rspec --format progress 2>&1
EXIT_CODE=$?
END=$(date +%s%N)
DURATION=$(echo "scale=3; ($END - $START) / 1000000000" | bc)
echo "METRIC time_seconds=$DURATION"
exit $EXIT_CODE
```

A secondary metric (`test_failures`) guards against test breakage.

### 4. Experiment search space (in priority order)

| Priority | Experiment | Estimated savings |
|----------|-----------|------------------|
| P0 | Gate SimpleCov behind `ENV['COVERAGE']` | 0.05–0.10s |
| P1 | Add `bootsnap` to Gemfile dev group | 0.05–0.15s (bytecode cache) |
| P2 | Switch `.rspec` to `--format dot` (even less output) | ~0.005s |
| P3 | Remove `config.order = :random` (eliminate seed overhead) | ~0.005s |
| P4 | Profile slowest requires with `ruby-prof` | identifies targets |
| P5 | Parallelize with `parallel_tests` gem | 40–60% on multi-core |
| P6 | Lazy-load heavy requires in spec files (move to `let`) | varies |
| P7 | Trim shared contexts — reduce setup per-example | varies |

### 5. Guard rails (off-limits)

- No test deletions — test count must stay ≥ 493
- No modifications to `lib/` source files
- Coverage run (`COVERAGE=1 bundle exec rspec`) must still report 100% line coverage after any change

---

## Experiment Flow

```
Run 1: Baseline (no changes, measure current 0.26s)
Run 2: Gate SimpleCov → likely drops to ~0.16s
Run 3: Add bootsnap → likely drops to ~0.08s (target hit)
Run 4+: Continue searching — parallel_tests, .rspec flags, lazy requires
```

Once <0.10s is sustained across 3 consecutive runs, the experiment concludes.

---

## Open Questions

*None — resolved during brainstorm.*

## Resolved Questions

- **Goal:** Dev loop speed, not CI or branch coverage
- **Scope:** spec_helper, .rspec, spec files, Gemfile all in scope
- **Target:** <0.10s wall time (dev mode, no SimpleCov)
- **Coverage:** Preserved behind `COVERAGE=1` env var — not regressed
