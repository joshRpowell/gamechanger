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

## Experiment Search Space (P0 → P8)

| Priority | Experiment | Result | Savings |
|----------|-----------|--------|---------|
| P0 | Gate SimpleCov behind ENV['COVERAGE'] | ✅ KEEP | baseline set |
| P1 | Add `bootsnap` gem (bytecode + require cache) | ✅ KEEP | −9% (0.628s) |
| P2 | Remove `--color` from `.rspec` | ❌ DISCARD | negligible, high variance |
| P3 | Replace `config.order = :random` with `:defined` | ❌ DISCARD | negligible, high variance |
| P4 | `--format dot` | ❌ DISCARD | not a valid RSpec format |
| P5 | Profile slow requires (ruby-prof / --profile) | ℹ️ DONE | test execution ~0.25s internal; bundler startup ~0.28s |
| P6 | `parallel_tests` gem — split across CPU cores | ❌ DISCARD | 18 test failures (Thor CLI global state) |
| P7 | Lazy-load heavy requires in `let` blocks | ❌ N/A | lib/ is off limits; all spec requires needed |
| P8 | Trim shared contexts / disable warnings | ❌ DISCARD | seeded storage is fast (SQLite :memory:); warnings cost <1ms |
| BONUS | YJIT via RUBYOPT=--yjit | ❌ DISCARD | 2.2× slower (JIT warmup kills short runs) |
| BONUS | binstub (bin/rspec) | ❌ DISCARD | same as bundle exec (no savings) |
| BONUS | bundle install --standalone | ❌ DISCARD | slower (no bootsnap path caching) |

## What's Been Tried

### Architecture Insight (critical finding)
Wall-clock breakdown:
- bundler CLI startup: ~0.28s (irreducible without Spring/nenv)
- file loading (with warm bootsnap cache): ~0.10s
- test execution (493 examples): ~0.25s
- Total floor: ~0.53s

Current best (run 8): **0.628s** — within 0.10s of the theoretical floor.

To reach <0.40s would require eliminating bundler startup via:
- Spring (Rails-only, not applicable here)
- Running ruby directly with pre-built load paths (complex, fragile)
- Fixing parallel_tests Thor failures to enable CPU-parallel execution

### Run 7 — Baseline: 0.688s
- SimpleCov gated (P0), autoresearch.sh measuring wall-clock time
- 493 examples, 0 failures

### Run 8 — bootsnap (P1): 0.628s ✅ KEEP
- bootsnap/setup fails from spec/ dir; use explicit Bootsnap.setup with cache_dir
- ~9% improvement on warm cache runs
- macOS date doesn't support %N; using `ruby -e 'print (Time.now.to_f * 1000000000).to_i'`

### Runs 9-13 — All Discarded
- P2 (--color), P3 (:defined), P6 (parallel_tests), YJIT, binstub: none improved on 0.628s
- High timing variance (±0.1s) masks micro-optimizations
