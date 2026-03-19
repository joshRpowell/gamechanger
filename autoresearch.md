# Autoresearch: 100% Test Coverage

## Objective

Achieve 100% line and branch coverage for the gamechanger Ruby gem CLI tool.
The gem provides pre-game coaching analytics for youth baseball coaches.

## Metrics
- **Primary**: `line_coverage` (%, higher is better)
- **Secondary**: `branch_coverage` (%, higher is better), `test_failures` (count, lower is better)

## How to Run
`./autoresearch.sh` — outputs `METRIC name=number` lines.

## Files in Scope (sorted by coverage gap, biggest first)

| File | Coverage | Lines Missed |
|------|----------|-------------|
| `lib/gamechanger/formatters/json.rb` | 20.2% | 71 lines |
| `lib/gamechanger/formatters/table.rb` | 47.6% | 150 lines |
| `lib/gamechanger/formatters/markdown.rb` | 37.9% | 193 lines |
| `lib/gamechanger/cli.rb` | 66.9% | 113 lines |
| `lib/gamechanger/config.rb` | 78.6% | 12 lines |
| `lib/gamechanger/development_arc.rb` | 90.3% | 6 lines |
| `lib/gamechanger/storage.rb` | 91.1% | 10 lines |
| `lib/gamechanger/client.rb` | 94.9% | 4 lines |
| `lib/gamechanger/syncer.rb` | 96.5% | 2 lines |

## Spec Files to Create/Extend

- `spec/gamechanger/formatters/json_spec.rb` — NEW (no spec exists for json.rb)
- `spec/gamechanger/formatters/table_spec.rb` — NEW (no spec exists for table.rb)
- `spec/gamechanger/formatters/markdown_spec.rb` — EXTEND (needs pitcher_games, game_breakdown, plan, batter_games, progress, progress_player methods)
- `spec/gamechanger/cli_spec.rb` — EXTEND (missing error paths for many commands)
- `spec/gamechanger/config_spec.rb` — EXTEND (missing write, save, update, clear methods)
- `spec/gamechanger/development_arc_spec.rb` — EXTEND (lines 110-116: pitcher sparkline/trend edge cases)
- `spec/gamechanger/storage_spec.rb` — EXTEND (lines 76-78, 93, 449-450, 589-607)
- `spec/gamechanger/client_spec.rb` — EXTEND (lines 103, 138, 141, 150)
- `spec/gamechanger/syncer_spec.rb` — EXTEND (lines 113, 116)

## Off Limits
- `lib/` source files (do not modify source, only add tests)
- Existing passing tests (never break them)

## Constraints
- Tests must pass (0 failures)
- Use RSpec with `instance_double` pattern
- Use WebMock for HTTP stubs
- Use `Dir.mktmpdir` for temp config dirs
- Use seeded in-memory SQLite (`':memory:'`) for storage fixtures
- Never add real network calls

## What's Been Tried

### Baseline (Run 1)
- Line Coverage: 65.52% (1066/1627)
- Branch Coverage: 40.92% (304/743)
- No json_spec.rb or table_spec.rb existed
- markdown_spec.rb had 10 tests but missed many methods

### Strategy
1. Create json_spec.rb — covers all 11 methods of Formatters::Json
2. Create table_spec.rb — covers all methods of Formatters::Table
3. Extend markdown_spec.rb — cover remaining methods
4. Extend cli_spec.rb — cover error paths (network errors, storage errors, edge cases)
5. Extend config/storage/client/syncer/development_arc specs for final gaps
