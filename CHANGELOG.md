# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added — Go CLI port (experimental, side-by-side with Ruby gem)

A parallel Go implementation of the CLI is being developed on `experiment/cli-printing-press`. This is a checkpoint of foundation-through-sync work; the Ruby gem under `lib/` and `exe/gamechanger` are unchanged.

**Shipped in this checkpoint:**
- Module scaffold: `cmd/gamechanger`, `internal/version`, `internal/gcerr` (sentinel error categories).
- `internal/config` — load/save `~/.gamechanger/config.yml` and the `~/.gamechanger/session` token cache. Wire-compatible with the Ruby gem's file format so a user who ran Ruby `setup` does not need to re-authenticate.
- `internal/store` — SQLite cache using `modernc.org/sqlite` (pure-Go, no cgo). Migrations 1-3 match the Ruby schema. Ten queries powering the brief command's data feed: `UpsertGame`, `ClearNonFinal`, `AllGames`, `UpsertPitcherStats`, `UpsertBatterStats`, `NextScheduledGame`, `PitcherAvailability`, `BatterLineupData`, `AllPlayerDevelopmentSummary`, `PlayerParticipation`.
- `internal/client` — HTTP client for the four Gamechanger endpoints (`/auth`, `/me/teams`, `/teams/{id}/schedule`, `/game-stream-processing/{id}/boxscore`) with `gc-token` + `gc-device-id` + `gc-app-name` headers, 429 retry, and a typed `ErrBoxscoreNotFound` so canceled or never-played games are skipped during sync instead of aborting it.
- `internal/parser` — boxscore + batter stats extractors matching the Ruby parsers' field selection.
- `internal/sync` — full port of `Gamechanger::Syncer`, including the `event_type == "game"` filter, the `status != 'canceled'`, future-game, and cached-final skip rules, and the final-game promotion.
- `internal/commands` — Cobra command tree for `setup`, `refresh`, `version`, and a new `auth import` / `auth status` pair that imports a `gc-token` JWT captured from `web.gc.com`. Adds `--config-dir` and `GAMECHANGER_HOME` env-var override for safe smoke testing against a temp directory.

**Why the new `auth import` command exists.** Gamechanger added MFA-with-email-code plus an HMAC-style `gc-signature`/`gc-timestamp` scheme on `POST /auth` that neither the Ruby nor Go CLI's bare `{email, password}` body can satisfy — both implementations currently 401 on `setup`/`refresh`. The data endpoints (`/me/teams`, `/teams/.../schedule`, `/game-stream-processing/.../boxscore`) do **not** require `gc-signature`; they accept any unexpired `gc-token` JWT. `auth import` lets the user paste a token from their logged-in browser session, sidestepping the signed `/auth` flow until either the signing key is reverse-engineered or Gamechanger relaxes auth.

**Verified end-to-end against the live `api.team-manager.gc.com` API.** A single smoke run (browser-pasted token → `gamechanger refresh --config-dir <tmp>`) synced 26 games / 67 pitcher outings / 272 batter rows in ~22 seconds. Currently the Go cache has more recent data than the Ruby gem's cache, because the Ruby `setup`/`refresh` path has been broken by Gamechanger's MFA change.

**Verified offline.** `go test ./...` passes for `gcerr`, `config`, `store`, `parser`, and `sync`. The `sync` package includes an integration test that spins up an `httptest.Server` for `/auth` + `/schedule` + `/boxscore` and runs the full pipeline against in-memory SQLite, asserting both row counts and that the cached token causes the second run to skip re-auth.

**Not yet ported (tracked in TODOS.md → Go port WIP):**
- Analytics layer: `pitch_rules.rb`, `lineup_optimizer.rb`, `development_arc.rb`, `pre_game_brief.rb` — pure-Go domain logic; no I/O.
- Formatters (`Brief()`, `Plan()`, `Hitting()`, etc. across table / json / markdown).
- The eight remaining commands: `brief`, `plan`, `lineup`, `equity`, `hitting`, `progress`, `availability`, `pitches`.
- Unit tests for `internal/client` and `internal/commands` (the `sync` integration test exercises both end-to-end; per-package tests with mocks are still wanted).
- Release packaging (no `.github/workflows` for Go binaries yet).

**Goal:** if the analytics-and-formatter port lands cleanly and the Go binary survives a real season of use, retire the Ruby gem.

## [0.2.0] - 2026-05-13

### Changed
- Refactored CLI command bodies into dedicated `Commands::` classes (one per user-facing command). `lib/gamechanger/cli.rb` is now a 90-line Thor routing layer; command logic, error handling, and command-specific helpers live in `lib/gamechanger/commands/`.
- `Commands::Base` owns shared infrastructure: 5-exception rescue chain (`run_command`), storage open/close (`with_storage`), config loading (`load_config!`), formatter selection (`build_formatter`), and the shared `resolve_target` date resolver.
- Stale "Run `gamechanger pitches --refresh`" error messages updated to point at the top-level `gamechanger refresh` command introduced in v0.1.1.

### Added
- Per-command unit specs under `spec/gamechanger/commands/` — direct invocation of each `Commands::X` class with a doubled shell, covering command-specific helpers and edge cases.

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
