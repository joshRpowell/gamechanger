# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [0.1.1] - 2026-03-19

### Added
- `refresh` command for on-demand sync of latest game data from Gamechanger
- Markdown formatter (`--format markdown`) producing pipe-delimited tables and structured pre-game brief
- `--format` enum now accepts `table`, `json`, and `markdown`
- Season-scoped queries in Storage — all stats filtered to the current season
- `Syncer` class extracted from CLI for independently testable sync logic
- `StorageError` exception class wrapping SQLite3 exceptions for consistent error handling
- Comprehensive test suites: `syncer_spec.rb`, `cli_setup_spec.rb`, `formatters/markdown_spec.rb`
- Happy-path and integration tests for all CLI commands
- Seeded storage shared context in `spec_helper.rb` for test data reuse
- API reference documentation in `docs/research/gc-api-notes.md`
- `build_formatter` private helper consolidating format selection across all commands
- `TABLE_STYLE` constant DRY refactor in table formatter

### Fixed
- `PitchRules#available_date` raised `Date::Error` when `last_outing_date` was nil (pitchers who have never pitched). Now returns `Date.today`. (ISSUE-002)
- Flaky test suite — `SystemExit` escaped `rescue nil` (postfix-rescue catches `StandardError`, not `Exception`), causing RSpec to terminate mid-run on some seeds. Fixed with explicit `rescue SystemExit` block. (ISSUE-001)
- Gemspec duplicate URI build warning — removed redundant `source_code_uri`, added `changelog_uri`. (ISSUE-003)

### Changed
- README updated to reflect full coaching analytics suite positioning
- Gemspec summary and description updated to match coaching analytics scope
- Removed unused `game_detail` method and `GAME_DETAIL_PATH` constant from `Client`
- Removed `season` field from README manual config example (config uses current year automatically)

## [0.1.0] - 2026-03-18

### Added
- Initial release: pre-game brief, pitcher availability, batting lineup, equity flags, player development arcs
- CLI commands: `brief`, `availability`, `hitting`, `lineup`, `equity`, `progress`, `sync`, `setup`
- Gamechanger API client with authentication and team/game/boxscore endpoints
- Local SQLite3 cache via `Storage` class
- Table and JSON formatters
- `PitchRules` engine with rest-day thresholds, pitch counts, and availability calculation
- `LineupOptimizer` and `EquityAnalyzer` for lineup and equity analysis
- `PreGameBrief` coordinator aggregating all intelligence sources
- Thor-based CLI with `--format` and `--season` flags
