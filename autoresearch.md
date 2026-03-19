# Autoresearch: Test Suite Speed

## Objective

Minimize wall-clock time for `bundle exec rspec` (dev mode, no SimpleCov) in the gamechanger Ruby gem.
Current baseline: ~0.69s (full wall-clock including bundler startup). Target: <0.40s initially; stretch goal <0.10s for rspec execution alone.

The previous experiment achieved 100% line coverage (6 runs). This experiment optimizes developer iteration speed.

## Metrics
- **Primary**: `time_seconds` (seconds, lower is better)
- **Secondary**: `test_failures` (count, must stay 0)

## How to Run
`bash autoresearch.sh` — outputs `METRIC time_seconds=N.NNN` and `METRIC test_failures=N` lines.

**Coverage run** (separate, preserved): `COVERAGE=1 bundle exec rspec`

## Files in Scope

| File | What it does |
|------|-------------|
| `spec/spec_helper.rb` | RSpec + SimpleCov config, shared contexts |
| `spec/**/*_spec.rb` | All spec files (reduce setup overhead) |
| `.rspec` | RSpec CLI flags |
| `Gemfile` | Add/remove deps (bootsnap, parallel_tests) |

## Off Limits
- `lib/` source files — never touch
- Deleting or skipping existing tests — example count must stay ≥ 493
- CI coverage runs — `COVERAGE=1 bundle exec rspec` must still report 100% line coverage

## Constraints
- Zero test failures at all times
- `COVERAGE=1 bundle exec rspec` must still report 100% line coverage, 493+ examples
- No test deletions — guard with example count check

## Experiment Search Space (P0 → P8, try in order)

| Priority | Experiment | Estimated Savings | Files |
|----------|-----------|------------------|-------|
| P0 | Gate SimpleCov behind ENV['COVERAGE'] ✅ DONE | ~0.05–0.10s | spec/spec_helper.rb |
| P1 | Add `bootsnap` gem (bytecode + require cache) | 0.05–0.15s | Gemfile, .bundle/config |
| P2 | Remove `--color` from `.rspec` | ~0.005s | .rspec |
| P3 | Replace `config.order = :random` with `:defined` | ~0.005s | spec/spec_helper.rb |
| P4 | Switch to `--format dot` in `.rspec` | ~0.003s | .rspec |
| P5 | Profile slow requires with ruby-prof | identifies targets | analysis |
| P6 | `parallel_tests` gem — split across CPU cores | 40–60% | Gemfile, config |
| P7 | Lazy-load heavy requires inside `let` blocks | varies | spec files |
| P8 | Trim shared contexts — reduce per-example setup | varies | spec/spec_helper.rb |

## What's Been Tried

### Baseline (Run 1) — ~0.69s wall-clock
- SimpleCov gated behind ENV['COVERAGE'] (P0 applied before baseline)
- Measured with bash autoresearch.sh timing ruby subprocesses
- 493 examples, 0 failures
- Note: 0.69s is full pipeline including bundler startup; rspec reports ~0.25s internally

### Strategy Notes
- P0 (SimpleCov gate) is already applied as part of bootstrap — measure its impact in Run 2 vs a coverage-on baseline
- P1 (bootsnap) is highest-upside next experiment — targets Ruby require bytecode caching
- macOS date doesn't support %N; using `ruby -e 'print (Time.now.to_f * 1000000000).to_i'` for nanosecond timing
