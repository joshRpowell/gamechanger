# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Changed
- CLI startup ~28% faster for non-network commands: `net/http`/`openssl` (via `Client`/`Signer`) and `terminal-table` (via `Formatters::Table`) are now lazy-loaded with `Module#autoload` instead of eagerly required by `lib/gamechanger.rb`. Network commands (`setup`, `refresh`, `pitches`) and table rendering load them on first constant reference — no behavior change.
- `Syncer#run` now resolves a game's cached status with an indexed point lookup (`Storage#find_game`, `SELECT ... WHERE game_id = ?`) instead of scanning the entire `games` table (`all_games`) and doing a linear `find` on every loop iteration. Sync behavior is unchanged (identical skip/force semantics); this removes quadratic DB work as seasons accumulate. Wall-clock impact on a live sync is marginal because that loop is network/rate-limit bound, but the isolated lookup pattern is ~23x faster at 60 games and ~350x faster at 1000 games in a synthetic in-memory benchmark.

- `gamechanger refresh` no longer re-downloads boxscores for games already cached as final. Final boxscores are immutable, but `refresh` passed `force: true` unconditionally and `force` disabled the final-game skip, so every run spent one HTTP request plus one 0.5s `Client::RATE_LIMIT_SLEEP` per already-final game re-fetching identical data. `refresh` still drops and re-fetches all non-final games (that is what `force` means now). In a synthetic 30-final-game season this cuts a refresh from 31 HTTP requests and 15.0s of rate-limit sleep to 1 request and 0.0s. Pass `gamechanger refresh --force` to restore the old re-download-everything behavior.
- `gamechanger pitches --refresh` likewise no longer re-downloads already-final games, matching what the flag has always advertised ("force re-fetch of non-final games").
- **Behavior change:** `gamechanger pitches` is now cache-only by default and no longer syncs from the API on every invocation. Pass `--refresh` to sync first, then display — the flag now opts *into* the network round trip (and the syncer's 0.5s-per-non-final-game rate-limit sleep) rather than only escalating an always-on sync to a forced one. This makes `pitches` consistent with every sibling read command (`hitting`, `fielding`, `equity`, `availability`, `brief`), all of which already read only the cache. On an interactive terminal, a cache-only run warns when it holds in-progress or same-day games; the warning is suppressed for non-TTY/piped output. In a synthetic benchmark of a 12-game cached season (10 final, 2 in progress), a default `pitches` run drops from 1.036s / 3 HTTP requests / 1.00s slept to 0.006s / 0 HTTP requests / 0s slept, with byte-identical table output.

### Added
- `gamechanger refresh --force` — also re-download games already cached as final. Escape hatch for a cache that looks wrong; costs one request + one rate-limit sleep per final game.
- `Syncer#run(refetch_final:)` — separates "invalidate cached non-final games" (`force:`) from "re-download already-final boxscores" (`refetch_final:`).
- `Storage#pitcher_stats?(game_id)` — true when pitcher stats have been cached for a game. Lets the syncer skip only games it genuinely finished, so a game the schedule feed marked final before its boxscore existed still gets re-fetched.
- `Storage#find_game(game_id)` — returns a single game row (or `nil`) via the `games.game_id` UNIQUE index.
- `Client` now reuses a single persistent keep-alive HTTP connection across all API requests instead of opening a fresh TCP + TLS connection per request. During `sync`, which issues one boxscore request per non-final game (typically 20-60 sequential calls to the same host), this pays the TLS handshake once rather than once per request. The connection is transparently re-opened if the server closes it (idle timeout); request/response semantics, retry behavior (429), rate-limit throttling, and error mapping are unchanged. A `Client#close` method is available to release the socket explicitly.

## [0.8.0] - 2026-05-21

### Added
- Rate stats on `gamechanger pitches`: `ERA`, `WHIP`, `K/9` shown by default; `BB/9`, `BAA`, `P/IP` gated behind `--advanced`. All sortable via the existing `--sort` flag (`era`, `whip`, `k9`, `bb9`, `baa`, `p_ip`, `p_bf`).
- `gamechanger pitches --pitcher NAME` per-outing view: now shows raw counts (`BF`, `H`, `R`, `ER`, `BB`, `SO`) per outing plus a cumulative footer with derived ERA, WHIP, K/9, and BAA. Per-outing rates intentionally omitted (single-outing rates are too noisy at youth-game sample sizes).
- Migration v7: 8 new integer columns on `game_pitcher_stats` — `batters_faced`, `hits_allowed`, `runs_allowed`, `earned_runs`, `walks_issued`, `strikeouts_recorded`, `wild_pitches`, `hbp_allowed` (NOT NULL DEFAULT 0). Existing rows default to 0. Run `gamechanger refresh` to backfill historical games from cached boxscores.

### Changed
- `BoxscoreParser#pitcher_stats` returns 8 additional keys (`batters_faced`, `wild_pitches`, `hbp_allowed`, `hits_allowed`, `runs_allowed`, `earned_runs`, `walks_issued`, `strikeouts_recorded`). `BF` is always present in the boxscore; `WP` and `HBP` are sparse and default to 0 when absent from `pitching.extra[]`.
- `Storage#season_summary` SQL exposes `total_bf`, `total_h`, `total_r`, `total_er`, `total_bb`, `total_so`, `total_wp`, `total_hbp` aggregates used to derive the new rate columns at query time.
- `Strike%` column header abbreviated to `S%` in the default pitches table to leave room for `ERA`, `WHIP`, `K/9`.

## [0.7.0] - 2026-05-21

### Added
- Hit-type breakdown on `gamechanger hitting`: `1B`, `2B`, `3B`, `HR` columns inserted between `H` and `BB`. `1B` is derived as `H - 2B - 3B - HR` (clamped to 0); `2B`, `3B`, `HR` are sourced from `lineup.extra[]` and stored. Run `gamechanger refresh` to backfill historical games.
- Migration v6: new `doubles`, `triples`, `home_runs` integer columns on `game_batter_stats` (NOT NULL DEFAULT 0).

### Changed
- `BatterStatsParser#batter_stats` returns three additional keys (`doubles`, `triples`, `home_runs`), joined from `lineup.extra[]` by `player_id` using the existing HBP pattern.
- `season_batting_summary` SQL exposes `total_1b`, `total_2b`, `total_3b`, `total_hr` aggregates. JSON formatter emits `singles`, `doubles`, `triples`, `home_runs` keys.

## [0.6.0] - 2026-05-21

### Added
- `PA` (plate appearances) column on `gamechanger hitting`, computed as `AB + BB + HBP`. Sortable via `--sort pa`. Sacrifice flies and bunts are not exposed by the GameChanger boxscore endpoint, so `PA` undercounts by 1 for each sac (documented limitation).
- `%IP` column on `gamechanger pitches` showing each pitcher's share of the team's actual defensive innings across the report window, formatted as one decimal (e.g. `42.3%`). Sortable via `--sort ip_share`.
- Migration v5: new `hbp INTEGER NOT NULL DEFAULT 0` column on `game_batter_stats`. Existing rows default to 0; run `gamechanger refresh` to repopulate from cached boxscores.

### Fixed
- **Strikeouts column now populated correctly.** Pre-existing bug: the parser read `stats['K']` from the boxscore, but the real API key is `'SO'`. All historical `game_batter_stats.strikeouts` rows are 0. Run `gamechanger refresh` after upgrading to backfill real strikeout values from cached games.

### Changed
- `BatterStatsParser` joins HBP from `lineup.extra[]` (keyed by `player_id`), mirroring the existing pattern `BoxscoreParser` uses for `#P`/`TS`/`BF`.
- `season_summary` SQL exposes `SUM(innings_pitched)` as `total_ip`, enabling team-IP-share derivation in the `pitches` command.

## [0.5.0] - 2026-05-20

### Added — Fielding pivot command

- `gamechanger fielding` — new subcommand that renders a player × position pivot of season fielding stints. Columns: `Player`, `G` (distinct games fielded), then fielding positions in canonical order (`P C 1B 2B 3B SS LF CF RF DH EH`) limited to positions actually present in the data, then `Total` (sum of position stints).
- Cell metric for position columns is intentionally **stint count**, not innings — the boxscore doesn't carry per-inning data. (See `docs/research/gc-api-notes.md` for the full data-shape note.)
- Supports `--sort COL` and `--desc`. Sort keys: `player`, `g` / `games`, `total`, or any position code present (case-insensitive — `--sort SS` and `--sort ss` both resolve). Default sort is `total` desc with player-name ascending tiebreak.
- `--format table | markdown | json`. JSON shape is an array of `{ player_name, games, positions: { POS: N, ... }, total: N }` with zero-count positions omitted from each row's hash.
- No schema changes — reuses the `game_fielding_positions` table introduced in 0.4.0.

## [0.4.0] - 2026-05-20

### Added — Fielding positions

The boxscore response GameChanger already returns carries each player's defensive position-stint history inline in the `lineup` group, but the parser was discarding it. This release surfaces that data end-to-end so `gamechanger hitting` shows each player's most-recent defensive role alongside their bat.

- `gamechanger hitting` now has a `Pos` column showing the player's most-recent completed game's position string (e.g., `SS, P` for a player who started at short and moved to the mound). Empty cell when the player didn't take the field in their most recent appearance.
- Multi-position players are first-class — the stint order is preserved exactly as GameChanger reports it.
- v4 schema migration adds a `game_fielding_positions` table with one row per (game, player, stint). Existing v3 caches upgrade additively on next CLI run; no data loss path.
- `BatterStatsParser#fielding_stints` parses the `lineup.stats[].player_text` field with a known-positions allow-list (`P, C, 1B, 2B, 3B, SS, LF, CF, RF, DH, EH`). Unknown codes are logged and skipped rather than crashing the sync.
- JSON output (`gamechanger hitting --format json`) emits `positions` as an array per row, not a joined string, so downstream consumers can format however they want.
- `--sort COL` and `--desc` flags on `hitting`, `pitches`, and `equity` for column-ordered reports. Stored columns and computed metrics (AVG, OBP, Strike%) sort uniformly; nils sort last in both directions. Run `gamechanger help <command>` for the per-report column keys.

## [0.3.0] - 2026-05-18

### Added — MFA-aware auth + 1Password integration

Gamechanger's API moved to a multi-step MFA-required auth flow with HMAC-signed requests. The old `email + password → token` call now 401s silently. This release rebuilds the auth pipeline end-to-end so the gem keeps working.

- `gamechanger setup` now runs the full 5-step flow: `client-auth` → `user-auth` (triggers OTP email) → prompt user for the 6-digit code → `mfa-code` → `password` → receives access + refresh JWTs.
- Once authenticated, the refresh token mints new access tokens for ~14 days without re-prompting for the OTP, so day-to-day commands like `gamechanger refresh` stay non-interactive.
- New `Gamechanger::Signer` module computes the `gc-signature` header (HMAC-SHA256 with previous-signature chaining) for every `/auth` POST. Reverse-engineered from the GC web bundle and verified byte-identical against captured live requests.
- Optional 1Password CLI integration: set `password_op_ref: op://Vault/Item/password` in `~/.gamechanger/config.yml` instead of an inline password. Resolved lazily via `op read` and memoized.

### Changed

- Session file (`~/.gamechanger/session`) is now YAML with separate access + refresh tokens and their expirations. Legacy single-token `<token>|<expires>` format still reads for backwards compat.
- `Config#save` now accepts either `password:` or `password_op_ref:` (one is required).
- `gamechanger setup` defaults email and op-ref from any existing saved config so re-runs only prompt for what's missing.
- Team auto-detect during setup now reads `public_id` (the actual GC slug field), falling back to `slug` / `short_id`.

### Fixed

- Syncer no longer crashes on the first game that has no boxscore yet — 404s are skipped so the rest of the sync proceeds.
- Gemspec exclude list now covers `.gstack/` and `.claude/`, so `gem build` doesn't fail on tracked-but-deleted files from local tooling.
- `sqlite3` dependency loosened to `>= 1.7, < 3.0` so the gem installs cleanly on Ruby 3.4.

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

### Added — Pre-game scout (Phase 1a, Fork A: matchup-history)

`gamechanger scout <opponent>` — show matchup history against an opponent. Given an opponent name (case-insensitive) or UUID, returns every prior game with score, W/L, home/away, sorted DESC by date. TTY-aware output: colored at terminal, plain copy-paste text when piped (cap 500 chars for messaging into a coaches' group thread). `--format json` for AI/agent pipelines. `--refresh` bypasses the 24h opposing-team metadata cache. `--limit N` caps last N games.

**U1 discovery (the gate)** caught that the GameChanger web/desktop API does NOT expose opposing-team rosters — the original brainstorm's "scan opposing roster for familiar names" workflow can't ship against this API. Only the mobile app has those endpoints. The plan was reshaped to matchup-history scout (Fork A) which ships against confirmed endpoints. Full discovery write-up in `docs/research/gc-scout-api-notes.md`.

**Bonus discovery:** `/teams/{uuid}/game-summaries` returns per-game `owning_team_score` + `opponent_team_score` + `opponent_id` in a single call. Much cleaner score-data source for a future `progress`/`brief` enrichment than the boxscore-parsing path the original plan assumed.

**Shipped:**
- Migration v4: `opposing_teams` + `opposing_roster` tables (Go-only, additive). `opposing_roster` unused under Fork A; kept for Fork B (mobile-app capture) revival.
- `gcerr.ErrAuthInsufficient` sentinel for distinguishing 403 (auth scope) from 401 (token expired).
- `internal/client/scout.go` — `GameSummaries` + `OpponentDetail` methods, defensive parsing, `ErrTeamNotFound` sentinel.
- `internal/scout/` orchestrator — W/L/T outcome derivation, 24h cache TTL, injectable clock + client for tests.
- `internal/store/scout_queries.go` — `UpsertOpposingTeam`, `FindOpposingTeamByUUID`, `FindOpposingTeamByName` (case-insensitive, most-recent on collision). Also `CrossReferenceRoster` (kept for Fork B but unused under Fork A).
- `internal/format/scout.go` — TTY-aware renderer + JSON encoder.
- `internal/commands/scout.go` — cobra wiring with `scoutExit` typed exit pattern (6 distinct codes per failure mode).

**Tests:** 201 across 18 packages, no regressions.

**Deferred:**
- Promote `/game-summaries` to existing `progress`/`brief` for W/L context in own-team analytics (GO-9).
- Phase 2 — TUI navigator (GO-10).
- Fork B — mobile-app capture to unblock opposing-roster recognition (original AE2) — requires mitmproxy + cert override (GO-11).

### Added — Verify-parity harness pilot (U1, AI-loop gate)

A Ruby-versus-Go behavioral parity harness for the analytics port — pilot stage only. U1 is the gate that decides whether the full harness (U3-U6) gets built. The pilot ports `development_arc.rb` to Go via an AI-driven loop and diffs the JSON output against the real Ruby implementation. **Gate result: PASS in 2 iterations.**

**Shipped in this checkpoint:**
- **Ruby side, `GAMECHANGER_HOME` env var** — `Config.home_dir` / `.config_file_path` / `.session_file_path` and `Storage#data_dir` now consult `GAMECHANGER_HOME` with a `~/.gamechanger` fallback. Lets the harness point Ruby and Go at the same fixture directory. Legacy `CONFIG_DIR` / `CONFIG_FILE` / `SESSION_FILE` / `DATA_DIR` constants preserved for back-compat. +14 rspec cases including regression guards on default-path behavior; `bundle exec rspec` = 586 examples, 0 failures.
- **`internal/analytics/arc/`** — Go port of `lib/gamechanger/development_arc.rb` (144 LOC source → 179 LOC Go). `PlayerArc` struct + `BuildSummary`, `BuildPlayer`, `SparklineFor`, faithful narrative-archetype branching (peaking / strong starter / finding their groove / steady / building) and trend indicators (↑ / ↓ / →). Optional fields use `*float64` / `*int` / `*string` so JSON null marshals where Ruby emits nil. 25 Go table tests translate `spec/gamechanger/development_arc_spec.rb`.
- **`cmd/progress-json/main.go`** — pilot-only Go entry point. Reads the gamechanger SQLite store and emits JSON matching Ruby's `Formatters::Json#progress` shape. Includes a `rubyFloat` custom marshaler so whole-number floats serialize as `0.0` (matching Ruby's `Float#to_s`) instead of Go's default `0`.
- **`bin/pilot-diff`** — shell harness. Runs Ruby `progress --format json` + Go `progress-json` against the same `GAMECHANGER_HOME`, canonicalizes both via `jq -S`, diffs them, exits 0 / 2 / 3 by outcome. Designed for AI-loop iteration: each per-iteration diff field count is the gate trajectory signal.
- **Plan, brainstorm, ideation docs** — `docs/plans/2026-05-14-001-feat-verify-parity-harness-plan.md` (5-unit plan post-eng-review), `docs/brainstorms/2026-05-14-verify-parity-harness-requirements.md` (R1-R14, AE1-AE6), and `docs/ideation/2026-05-14-gamechanger-go-port-direction-ideation.md` (Go-port strategic framing). Plan went through ce-doc-review (19 fixes, 5-persona pass), plan-eng-review (scope reduction 8→5 units; 7 issues fixed), and this `/ship`.
- **TODOS.md** — `GO-8 Anchor-fixture regeneration cadence + procedure` for future U3/U4 work.

**Pilot gate trajectory** (the load-bearing signal):
- Iteration 0 (pre-impl): all Go table tests undefined → build fails
- Iteration 1 (full Ruby→Go port): table tests PASS; pilot-diff = 1 drifted field (Go `json.Marshal` emits `0` for `0.0` vs Ruby `0.0`)
- Iteration 2 (`rubyFloat` custom marshaler): pilot-diff = **0 drifted lines** — PARITY-PASS

Gate criteria: monotonic reduction in drift, within iteration budget of 5. Both satisfied.

**What this pilot did NOT validate** (intentional, per the plan's "bet" framing): convergence on `lineup_optimizer` (multi-pass ranking) or `tournament_planner` (stateful projection) — those are 3.6× larger and have more cross-field interaction. U3-U6 build is now justified but not committed; pause for user decision before continuing.

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
