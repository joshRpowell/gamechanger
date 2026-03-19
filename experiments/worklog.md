# Autoresearch Worklog: 100% Test Coverage

## Session: gamechanger — 2026-03-19

**Goal:** Hit 100% line + branch coverage for the gamechanger gem.
**Baseline:** 65.52% line, 40.92% branch.

---

### Run 1: Baseline — line_coverage=65.52 (KEEP)
- Timestamp: 2026-03-19 09:00
- What changed: Added SimpleCov to spec_helper.rb; established baseline
- Result: 65.52% line, 40.92% branch, 258 examples, 0 failures
- Insight: Biggest gaps are json.rb (20%), markdown.rb (38%), table.rb (48%), cli.rb (67%)
- Next: Create json_spec.rb first — it's the largest gap (71 missed lines) and has zero spec file

## Key Insights
- All three formatters (json, table, markdown) have the same structural methods — season_summary, pitcher_games, availability, lineup, brief, hitting, batter_games, equity, progress, progress_player, plan, game_breakdown
- Tests need real struct/double instances of LineupOptimizer::PlayerSlot, DevelopmentArc, TournamentPlanner, PreGameBrief
- json.rb is purely transformational — minimal branching, easy to test
- table.rb and markdown.rb have more branching (empty checks, conditional formatting)

### Run 6: 100% Line Coverage Achieved — line_coverage=100.0% (KEEP)
- Timestamp: 2026-03-19 09:54
- What changed: Added config_spec.rb (new), extended client_spec.rb, storage_spec.rb, syncer_spec.rb, development_arc_spec.rb, cli_spec.rb with tests for all 41 remaining uncovered lines
- Result: 100.0% line, 85.87% branch, 493 examples, 0 failures. +9.16% from Run 5.
- Insight: Key patterns — stub `Config.new` for plan tests needing season; empty boxscore stub for syncer normalize_status; `instance_double` with `configure?` for pitches; `Dir.mktmpdir` for filesystem storage tests; `OpenSSL::SSL::SSLError.new` raisable via WebMock; two consecutive 429 stubs hit the second-attempt NetworkError path.
- Next: PRIMARY GOAL MET. Could target 100% branch coverage next (currently 85.87%).

## Key Insights
- All three formatters (json, table, markdown) have the same structural methods — season_summary, pitcher_games, availability, lineup, brief, hitting, batter_games, equity, progress, progress_player, plan, game_breakdown
- Tests need real struct/double instances of LineupOptimizer::PlayerSlot, DevelopmentArc, TournamentPlanner, PreGameBrief
- json.rb is purely transformational — minimal branching, easy to test
- table.rb and markdown.rb have more branching (empty checks, conditional formatting)
- CLI tests using seeded storage context fail if `Storage.new` is stubbed in same describe block — use explicit mocks instead
- `resolve_next_game_date` tests require `Config.new` to be stubbed too (plan calls `current_season` which calls `Config.new`)
- Empty boxscore (groups: []) ensures stats.any? is false and game status isn't overwritten to 'final' in syncer

## Next Ideas
- Branch coverage improvement: 85.87% → 100% (57 uncovered branches remaining)

---

# Autoresearch Worklog: Test Suite Speed

## Session: gamechanger-test-speed — 2026-03-19

**Goal:** Minimize wall-clock time for `bundle exec rspec` (dev mode, no SimpleCov).
**Baseline:** ~0.69s. Target: <0.10s initially; <0.40s as first milestone.

---

### Run 7: Baseline — time_seconds=0.688 (KEEP)
- Timestamp: 2026-03-19 13:09
- What changed: SimpleCov gated behind ENV['COVERAGE'], autoresearch.sh rewritten for time measurement
- Result: 0.688s, 0 test failures, 493 examples
- Insight: ~0.25s RSpec internal; bundler+ruby startup is a significant chunk. File loading (SimpleCov removed) is still ~83% of wall-clock.
- Next: P1 bootsnap — bytecode and require path caching

### Run 8: P1 bootsnap — time_seconds=0.628 (KEEP)
- Timestamp: 2026-03-19 13:12
- What changed: Added bootsnap gem; explicit Bootsnap.setup in spec_helper.rb with cache_dir: tmp/bootsnap
- Result: 0.628s (-8.7%), 0 test failures, 493 examples
- Insight: ~9% improvement after cache warm-up. First run builds the cache; subsequent runs reuse bytecode. bootsnap/setup was unusable (can't infer app root from spec dir) — explicit Bootsnap.setup with absolute cache_dir required.
- Next: P2 — remove --color from .rspec (~0.005s theoretical)

## Key Insights
- macOS BSD date doesn't support %N — use `ruby -e 'print (Time.now.to_f * 1000000000).to_i'` for nanosecond timing
- bootsnap/setup fails from spec_helper.rb context; use Bootsnap.setup with explicit cache_dir
- Wall-clock includes bundler startup; RSpec internal time (~0.25s) is only part of the picture
- Bootsnap warm cache shows ~9% improvement; cold cache (first run) shows no improvement

## Next Ideas
- P2: Remove --color from .rspec (~0.005s)
- P3: Remove random order (~0.005s)
- P4: --format dot
- P6: parallel_tests across CPU cores (40-60% reduction)
