# TODOS

Deferred work captured during /plan-eng-review and /plan-ceo-review on 2026-03-18.

---

## ~~CEO-8. Rewrite README + gemspec description~~ ✅

**What:** Rewrite the README opening paragraph, gemspec summary and description, and add a "Commands at a glance" section listing all 8 commands with one-line descriptions.
**Why:** The gem is described as a "pitch count tracker" but is a full coaching analytics suite. Misrepresentation hurts discoverability and creates cognitive dissonance.
**Pros:** Accurately reflects the tool; improves discoverability on RubyGems.org.
**Cons:** None.
**Effort:** S (human ~30 min / CC ~5 min). **Priority:** P1.
**Depends on:** Nothing.
**Completed:** v0.1.1 (2026-03-19)

---

## ~~CEO-9. Create `docs/research/gc-api-notes.md` + resolve inline TODOs~~ ✅

**What:** Write API documentation derived from existing client + parser code. Document confirmed endpoints, request/response shapes, auth flow, and the confirmed field names referenced by the two Phase 0 TODOs in `cli.rb:42,57`. Remove those TODO comments once confirmed.
**Why:** The README promises this file exists. Without it, any API change requires re-reverse-engineering from scratch.
**Pros:** Institutional knowledge captured; README promise fulfilled; inline TODOs cleared.
**Cons:** Requires careful reading of client.rb + BoxscoreParser to derive shapes (no live API needed).
**Effort:** S (human ~2 hours / CC ~10 min). **Priority:** P1.
**Depends on:** Nothing.
**Completed:** v0.1.1 (2026-03-19)

---

## ~~CEO-10. `gamechanger refresh` command + `brief` as default + `--format markdown`~~ ✅

**What:** Three UX improvements: (1) `gamechanger refresh` top-level sync command with count reporting ("3 games, 8 outings, 45 at-bats updated"); (2) `default_task :brief` so bare `gamechanger` runs the brief; (3) `Formatters::Markdown` class + extend `--format` enum to include `markdown` on all commands.
**Why:** Removes friction for the pre-game use case; makes data lifecycle explicit; enables sharing briefs via pipe/clipboard.
**Pros:** Killer feature (`brief`) becomes the zero-arg default; shareable Markdown output; `refresh` replaces the confusing `pitches --refresh`.
**Cons:** `refresh` should be implemented after Syncer extraction (TODO #1) to avoid a second call site to the untestable private method.
**Effort:** M (human ~1 day / CC ~20 min). **Priority:** P1.
**Depends on:** Eng TODO #1 (Syncer extraction).
**Completed:** v0.1.1 (2026-03-19)

---

## ~~CEO-11. Season-scoped Storage queries~~ ✅

**What:** Update all ~12 Storage query methods to add `game_date >= :season_start AND game_date < :next_season_start` filters derived from `config.season`. Use the date-range approach (no new DB column, no migration, no backfill). Pass season range from CLI commands to Storage.
**Why:** When 2027 arrives, 2026 data commingles with 2027 data in cache.db, corrupting player arcs, equity counts, and pitcher rest calculations.
**Pros:** Data isolation across seasons; activates the documented but dead `season:` config field; zero migration risk.
**Cons:** Touches ~12 Storage methods + callers; future queries must remember the season filter pattern.
**Effort:** M (human ~1 day / CC ~20 min). **Priority:** P2 (urgent before 2027 season start).
**Depends on:** Nothing.
**Completed:** v0.1.1 (2026-03-19)

---

## ~~1. Extract `Syncer` class from CLI~~ ✅

**What:** Move `sync_data`, `extract_games`, `parse_game` (~70 lines) from `cli.rb` into `lib/gamechanger/syncer.rb`. CLI calls `Syncer.new(config, storage).run(force:)`.
**Why:** Business logic in the CLI is untestable and blocks retry logic, progress reporting, or incremental sync without touching Thor internals.
**Pros:** Directly unit-testable; clean separation of concerns; easier to extend.
**Cons:** One new file; small CLI update; new spec needed.
**How to apply:** Create `Syncer`, cut-paste `sync_data` body, extract `extract_games` + `parse_game` as `Syncer` private methods. Add `spec/gamechanger/syncer_spec.rb` using WebMock.
**Depends on:** Nothing.
**Completed:** v0.1.1 (2026-03-19)

---

## ~~2. CLI happy-path tests for 5 commands~~ ✅

**What:** Add RSpec tests in `cli_spec.rb` for `pitches`, `brief`, `availability`, `plan`, `hitting` — each seeding an in-memory `Storage.new(data_dir: ':memory:')`, stubbing `Storage.new`, asserting exit 0 + table output.
**Why:** Every command's rendering pipeline is untested. A nil field or missing key in a new data shape would crash silently.
**Pros:** Catches formatter regressions; high confidence for the full command pipeline.
**Cons:** Requires realistic fixture data per command.
**How to apply:** Build a shared `let(:storage)` helper that inserts 2 games + pitcher + batter stats. Stub `allow(Gamechanger::Storage).to receive(:new).and_return(storage)`. Assert output includes column headers.
**Depends on:** Nothing.
**Completed:** v0.1.1 (2026-03-19)

---

## ~~3. `setup` command tests (3 scenarios)~~ ✅

**What:** New `spec/gamechanger/cli_setup_spec.rb` with: (1) single-team success — config written, exit 0; (2) auth failure — exits 2 with message; (3) multiple teams — prompts for selection.
**Why:** `setup` is the mandatory first step and contains the most complex branching in the codebase. Zero coverage here.
**Pros:** Covers the onboarding path; team-selection branches are non-trivial.
**Cons:** Interactive `ask` prompts require stubbing `described_class.any_instance` for `ask`.
**How to apply:** Use `allow_any_instance_of(described_class).to receive(:ask).and_return(...)`. Stub `Client` HTTP calls with WebMock. Use a temp config dir via `Dir.mktmpdir`.
**Depends on:** Nothing.
**Completed:** v0.1.1 (2026-03-19)

---

## ~~4. Fix multiple Storage connections per command~~ ✅

**What:** In `cli.rb`, create one `Storage.new` per command and pass it into `resolve_target(date_opt, storage:)` and `resolve_plan_games(storage:)`.
**Why:** `availability`, `lineup`, `brief`, and `plan` currently open 2–3 SQLite connections per invocation. None are explicitly closed.
**Pros:** One connection per command; enables proper `close` in an `ensure` block.
**Cons:** Small signature change to two private helper methods.
**How to apply:** In each affected command, create `storage = Storage.new` at the top. Pass it to resolve helpers. Add `ensure; storage&.close; end` block.
**Depends on:** Nothing.
**Completed:** v0.1.1 (2026-03-19)

---

## ~~5. Rescue SQLite3 exceptions in CLI commands~~ ✅

**What:** Add `rescue SQLite3::Exception => e` (or a narrow `StorageError` wrapper) to command bodies. Show: 'Cache read failed — try deleting ~/.gamechanger/cache.db and re-running `gamechanger pitches --refresh`'.
**Why:** DB corruption currently produces a raw Ruby backtrace. Two critical failure modes (corrupt db, missing permissions) have no user-friendly error handling.
**Pros:** Friendly error; actionable recovery instructions.
**Cons:** Needs to be targeted to avoid masking genuine bugs.
**How to apply:** Wrap the rescue in each command's existing rescue chain. Add `StorageError` to `Gamechanger::Error` hierarchy, raise it from `Storage#db` rescue.
**Depends on:** Nothing.
**Completed:** v0.1.1 (2026-03-19)

---

## ~~6. README security note + dead code cleanup~~ ✅

**What:** (1) Add to README under "Data storage": "Password stored in plaintext (mode 0600) — same security model as AWS CLI and Heroku CLI." (2) Delete `Client#game_detail` (unused, `client.rb:84–86`). (3) Either pass `config.season` to the API schedule call or remove the `season` config field entirely.
**Why:** Transparency about the security model; dead code causes confusion when the API notes reference it; `season` config is documented but has no effect.
**Pros:** Honest docs; less confusion for future contributors.
**Depends on:** Nothing.
**Completed:** v0.1.1 (2026-03-19)

---

## ~~7. Minor DRY cleanup~~ ✅ (partial: TABLE_STYLE constant; build_player_index module skipped per TODO note; availability refactor deferred)

**What:** (1) Extract `TABLE_STYLE = { border_x: '─', border_i: '┼', border_y: '│' }.freeze` constant in `formatters/table.rb` (used 15 times). (2) Extract `build_player_index` shared between `BoxscoreParser` and `BatterStatsParser` into a `Boxscore::PlayerIndex` module. (3) Refactor `Formatters::Table#availability` to accept pre-enriched rows (same shape as `PreGameBrief#pitcher_plan`) rather than recomputing `available?/remaining/avail_date/high_load` itself.
**Why:** Small DRY violations — not bugs, but friction when availability rules or border styles change.
**Pros:** One place to update when rules change.
**Cons:** Item (2) adds a file for a 4-line method; may not be worth it.
**Depends on:** Nothing.
**Completed:** v0.1.1 (2026-03-19) — partial (TABLE_STYLE extracted; build_player_index skipped; availability refactor deferred)

---

## Active backlog (deferred from /plan-ceo-review 2026-05-13)

### BLOCKER: API-1 — Adapt to the rewritten GameChanger API (2026-05-14)

**What:** Between v0.2.0 and now, GameChanger restructured large parts of the team-manager API. The CLI is non-functional against the live service. At minimum three breakages are confirmed via direct curl probes on 2026-05-14:

1. **Auth requires 2FA code.** `POST /auth` with `{email, password}` returns 401. Web login now prompts for a 6-digit code sent to the account email *before* the password screen is accepted. The CLI must implement a multi-step auth flow (request code → user reads email → submit `{email, password, code}` or equivalent). See full breakdown below as "AUTH-1".
2. **Boxscore endpoint is gone.** `GET /game-stream-processing/<game_id>/boxscore` returns 404 (verified with a known-valid `gc-token` for a real `game_id`). The replacement path is unknown — needs devtools capture of a completed game's load on web.gc.com. Likely candidates already eliminated via probe: `/games/<id>(/boxscore)`, `/events/<id>/boxscore`, `/scorekeeping/.../boxscore`, `/stats/games/<id>/boxscore`. `GET /events/<id>` returns 200 but only contains calendar fields (`event`, `pregame_data`) — no stats.
3. **Schedule status semantics changed.** `/teams/<uuid>/schedule?fetch_place_details=true` still 200s, but for one user with 41 past games, **zero** are reported with `status: final|completed|ended`. All past games show `status: scheduled` or `canceled`, and the schedule items have no `result`/`score`/`stat` keys. Either status is now reported elsewhere (a separate "results" endpoint?), or the field has shifted to `event.status` semantics meaning something different. The CLI's `Syncer#normalize_status` and the "skip if cached and final" cache-skip logic assume the old semantics.

**Why this is a blocker:** `setup`, `refresh`, and every command depending on synced data is non-functional. Stopgap (manual `gc-token` paste + restored team_id/team_slug in config) lets `Client#games` work, but `Syncer#run` still fails on the boxscore call for the first non-canceled past game.

**Recovery path (in order):**

1. **Comprehensive devtools capture session.** Log in via browser with DevTools open from start of session. Click through: (a) team home, (b) schedule, (c) a completed game's detail page, (d) the boxscore / stats view for that game, (e) pitcher stats, (f) player stats, (g) season stats. Save HAR file from devtools. From the HAR, derive: every API path the web app hits, plus request/response shapes. Update `docs/research/gc-api-notes.md` with a `## 2026-05 API surface` section.
2. Rewrite `lib/gamechanger/client.rb` with the new endpoints and shapes.
3. Rewrite `lib/gamechanger/syncer.rb` to match the new status semantics — figure out how "this game is done, fetch stats now" is signaled.
4. Update `BoxscoreParser` and `BatterStatsParser` for new response shapes (likely field renames; possibly structural changes).
5. Ship behind a major version bump (v1.0.0) — this is a breaking rewrite, and the cache schema may need an `api_version` column so post-upgrade users don't pollute old data.

**Stopgap until shipped (gets some commands working ~1 hour at a time):**
```
# In DevTools, right-click gc-token value → Copy Value, then:
echo "$(pbpaste)|9999999999" > ~/.gamechanger/session && chmod 600 ~/.gamechanger/session
```
This unblocks any command that hits only the schedule endpoint (e.g. `availability` for date math against scheduled games). `refresh` still fails on boxscore. The JWT expires in ~1 hour; redo as needed.

**Effort:** human ~half-day devtools capture + ~2 days rewrite / CC ~2 hours once paths are mapped. **Priority:** P0 (blocker; gem fully unusable for primary use cases).
**Depends on:** A live web.gc.com session for the user to do the capture from.
**Source:** Discovered 2026-05-14 while attempting `gamechanger setup`. Each step revealed another breakage: 401 (auth) → 404 (boxscore) → empty-result schedule (status semantics). Related fix already shipped on 2026-05-14: `Setup` now calls `cfg.clear_token` before re-authenticating (closed a stale-token bug that masked the 2FA discovery).

---

#### AUTH-1 sub-detail — multi-step login implementation

**What:** GameChanger has added 2FA to the web login: the password screen now also requires an email-delivered code. The CLI's `POST /auth` flow (sending `{email, password}` only) returns 401 across the board, so `setup`, `refresh`, and every authenticated command are non-functional unless the user manually pastes a `gc-token` JWT from browser devtools into `~/.gamechanger/session` (and that JWT expires in ~1 hour).

Implementation work:
1. Open Firefox/Chrome DevTools → Network → log in normally on web.gc.com. Capture the multi-step auth requests. Expect a "request code" call (likely `POST /auth/code` or similar with `{email}`), then the existing `POST /auth` now extended with `{email, password, code}` (or a separate `POST /auth/verify`).
2. Update `lib/gamechanger/client.rb`:
   - Add `request_code(email:)` calling the new endpoint.
   - Update `authenticate` to: (a) trigger code send, (b) prompt the caller for the 6-digit code, (c) POST `{email, password, code}` to the verify endpoint.
3. Update `lib/gamechanger/commands/setup.rb` to prompt for the email code between password entry and the `authenticate_or_exit` call. Add `--code` option / `GAMECHANGER_CODE` env var for non-interactive usage (though the user still has to read the email).
4. Document the new flow in `docs/research/gc-api-notes.md` under a new "## Auth (2FA, 2026-05)" section with the captured endpoint shapes.
5. Tests: add `client_spec.rb` cases for the new request-code call and the augmented `authenticate` flow. Add `setup_spec.rb` regression case that stubs the code prompt.
6. **Related: `Config#save` is destructive when partial.** `lib/gamechanger/config.rb:24` rewrites the YAML from scratch using only the kwargs passed in, so `cfg.save(email:, password:)` wipes `team_id`, `team_slug`, and `season`. `Commands::Setup` calls save twice — once with creds, once with creds+team — and if auth fails between the two calls, the user is left with a half-broken config. Fix `save` to merge into existing data (read current YAML, overlay kwargs, write back), or split into `save_credentials` and `save_team` so neither destroys the other. Add a regression spec: save(email:, password:) on a config that already has team_id should preserve team_id. Surfaced 2026-05-14 during the auth-failure path.

**Why:** Without this, the gem is dead. Every command path that hits the API will 401. The manual token-paste workaround (see "Stopgap" below) is brittle because the JWT lifespan is ~1 hour, forcing the user to redo browser devtools dance every hour they want to use the tool.

**Stopgap until shipped:**
```
echo "$(pbpaste)|9999999999" > ~/.gamechanger/session && chmod 600 ~/.gamechanger/session
```
(Copy `gc-token` from any authenticated request in DevTools first.) Refresh approximately every hour.

**Open questions to answer during devtools capture:**
- Does the new flow expose a "remember device" / extended-session option (e.g., a longer-lived refresh token)? If yes, persist that so we don't trigger 2FA on every CLI invocation.
- Does the existing `gc-device-id` we already generate factor into the trust decision? (If a device is "known" maybe 2FA is skipped — test by re-using device_id across logins.)
- Is there a refresh-token endpoint we can hit silently before the JWT expires, to avoid re-prompting?

**Effort:** human ~half-day investigation + ~1 day implementation / CC ~45 min total once endpoints are mapped. **Priority:** P0 (blocker; gem unusable without it).
**Depends on:** Network capture of the new login flow (requires logging in via browser at least once with DevTools open).
**Source:** Surfaced 2026-05-14 while attempting `gamechanger setup` — every attempt 401s; browser login confirms 2FA code is now mandatory. Related fix already shipped: setup now calls `cfg.clear_token` before re-authenticating (see commit on 2026-05-14 — closed a separate stale-token bug that masked this discovery).

---

### CEO-13. `journal` — coaching notes capture + pattern surfacing

**What:** New `gc note "told Tommy to relax at the plate" --player Tommy` command writes a timestamped note attached to a player/game/practice. New `gc journal` shows recent notes grouped by player; surfaces patterns over time.
**Why:** By mid-season you forget what you tried. A journal makes year-over-year coaching learnings legible and is the foundation for an eventual end-of-season report card.
**Effort:** M (human ~1 day / CC ~30 min). **Priority:** P3.
**Source:** D5 from 2026-05-13 brainstorm review.

### CEO-14. `practice` — practice plan generator from team weak spots

**What:** Analyzes recent batting/pitching/fielding data, surfaces 3-5 team weak spots, generates a 60-min practice plan markdown with drill priorities.
**Why:** Turns data into action — the highest-value coaching transformation. "Team K-rate up 20%" → "prioritize 2-strike approach drills."
**Effort:** L (human ~1.5 days / CC ~45 min). **Priority:** P3.
**Depends on:** Validating which drill recs actually work — needs a few real practice plans to compare against.
**Source:** D6 from 2026-05-13 brainstorm review.

### ~~CEO-15. `scout` — opposing team pre-game data~~ ✅ (partial — shipped as Fork A)

**Status:** Phase 1a shipped on `feat/scout-phase-1a` (PR #4) as `gamechanger scout <opponent>` — matchup-history view (date / score / W/L / home-away). U1 discovery found the web/desktop API doesn't expose opposing-team rosters or pitcher tendencies, so the original "competitive scouting brief" framing pivoted to matchup history against confirmed endpoints. See `docs/research/gc-scout-api-notes.md` for the full discovery + 3-fork analysis. Follow-ups split into **GO-9, GO-10, GO-11** below.

### GO-9. Promote `/game-summaries` to `progress` / `brief` for W/L context

**What:** Scout's U1 surfaced `/teams/{uuid}/game-summaries` returning per-game `owning_team_score` + `opponent_team_score` + `opponent_id` in a single API call. Weave this into existing `progress` and `brief` outputs so the developmental arc renders alongside W/L context ("strong starter, 8-4 in last 12 games"). Strictly additive — no breaking changes to existing output.
**Why:** The data is one call away and is qualitatively the most-requested missing context for a coach reviewing player development trends in-season.
**Effort:** M (human ~half-day / CC ~30 min). **Priority:** P2.
**Depends on:** scout PR #4 merged (so `client.GameSummaries` is on `main`).

### GO-10. Scout TUI navigator (Phase 2)

**What:** Interactive TUI on top of the Phase 1a data layer. Navigate teams → schedule → game → opposing team and show matchup history per-opponent with keyboard shortcuts. Cache-age indicator. Read-only.
**Why:** The brainstorm's original B-first sequencing — prove the data layer with `scout`, then add the TUI on top.
**Effort:** L (human ~2-3 days / CC ~2 hours). **Priority:** P3.
**Depends on:** GO-9 (or scout PR #4 standalone). TUI framework selection (Bubble Tea vs tcell vs gocui) belongs to the Phase 2 plan.

### GO-11. Fork B — Mobile-app capture for opposing roster recognition

**What:** The original brainstorm AE2 — "scan opposing roster for familiar names" — requires opposing-team player data the web/desktop API doesn't expose. Mobile app likely has it. Mitmproxy + cert-pinning bypass on a phone to capture mobile-app traffic, find the opposing-roster endpoints, and unblock the recognition workflow. Larger lift, uncertain payoff.
**Why:** Original product workflow. Worth pursuing if matchup-history scout proves valuable and users want deeper recognition.
**Effort:** L+ (human ~half-day initial setup + research / CC trivial after). **Priority:** P4 (defer pending scout adoption signal).
**Depends on:** scout PR #4 in active use; observed value signal worth deeper investment.

### CEO-16. Morning auto-brief — launchd job delivers brief to phone

**What:** A launchd plist + `gc daemon install` command. On game-day mornings (detected from cached schedule), runs `brief --format markdown` and delivers to phone via email / iCloud folder / Pushover.
**Why:** Extends the "tool talks first" inflection beyond just in-game notifications. Pairs with watch.
**Effort:** M (human ~1 day / CC ~30 min). **Priority:** P3.
**Depends on:** Watch v1 shipped (so launchd patterns are established).
**Source:** D8 from 2026-05-13 brainstorm review.

### CEO-17. Multi-season `progress` — year-over-year arcs

**What:** Relax season-scoped queries for `progress` so it can show 2+ year trajectories. New `--seasons 2024,2025,2026` flag. No schema migration required.
**Why:** Multi-year arcs are the most meaningful coaching wins. "Hit .180 last year, .280 this year" is a powerful story to share with a kid.
**Effort:** S (human ~half-day / CC ~20 min). **Priority:** P3.
**Depends on:** Having 2+ seasons of cached data (verify before building).
**Source:** D9 from 2026-05-13 brainstorm review.

### CEO-18. Highlight detection — breakout games, slumps, personal bests

**What:** After each sync, scan recent games for milestones (career-high pitch count, OBP > 1.5x season avg, 3+ K game). Surface as a section in `brief` and as flags in `progress`.
**Why:** Data tells stories. "Tommy just had his best at-bat performance of the season" becomes a coaching moment grounded in hard data.
**Effort:** M (human ~1 day / CC ~30 min). **Priority:** P3.
**Source:** D10 from 2026-05-13 brainstorm review.

### MAINT-1. Split `formatters/table.rb` + `formatters/markdown.rb`

**What:** Both files are at 499 LOC and growing. Pull per-command formatting (`#brief`, `#availability`, `#plan`, `#progress`, etc.) into per-command modules: `Formatters::Table::Brief`, `Formatters::Markdown::Brief`, etc. The top-level class becomes a thin dispatcher.
**Why:** Adding new commands (watch, ask, parents) will push these past 700 LOC. The pain compounds.
**Effort:** S (human ~half-day / CC ~20 min). **Priority:** P3 (do when one of the new feature PRs would otherwise push a file past 600 LOC).
**Source:** 2026-05-13 brainstorm review architecture observation.

### ACTIVE: D1+D2+D12 — `watch` (live-game pitch count + equity nudges + observability)

**What:** macOS-notification-based silent sentinel for USSSA pitch count thresholds + in-game equity nudges. New `lib/gamechanger/commands/watch.rb` + `lib/gamechanger/watcher.rb` + `lib/gamechanger/notifier.rb`. Heartbeat file + stderr log for crash detection.
**Why:** Mid-game decision support is where USSSA violations happen and youth arm injuries originate. The cathedral's anchor feature.
**Effort:** human ~3 days / CC ~30 min. **Priority:** P1 (next active feature).
**Depends on:** D11 (this PR — CLI refactor) — must land first.
**Source:** D1+D2+D12 from 2026-05-13 CEO brainstorm. Design doc: `~/.gstack/projects/joshRpowell-gamechanger/joshuapowell-main-design-20260319-150720.md`.

### ACTIVE: D4 — `parents` post-game text drafter

**What:** `gc parents` outputs one short message per player after a game ("Tommy went 2-for-3 today, made a great play at SS"). Markdown-formatted, copy-paste-able to iMessage.
**Why:** Eliminates 20-30 min of post-game work; high-frequency use case.
**Effort:** human ~half-day / CC ~15 min. **Priority:** P2.
**Depends on:** D11 (CLI refactor pattern).
**Source:** D4 from 2026-05-13 CEO brainstorm.

### ACTIVE: D3 — `ask` natural-language Q&A

**What:** `gc ask 'how is Tommy doing?'` — LLM call (Anthropic or OpenAI) with structured data as context.
**Why:** Conversational entry point over already-structured data; high leverage. Eliminates need to remember exact flag/option syntax.
**Effort:** human ~1 day / CC ~30 min. **Priority:** P2 (after watch + parents).
**Depends on:** D11 (CLI refactor pattern), provider selection at eng-review time.
**Source:** D3 from 2026-05-13 CEO brainstorm.

---

## Go port WIP — checkpoint shipped 2026-05-14 (branch `experiment/cli-printing-press`)

The Go port replaces ~30% of the Ruby gem (transport, storage, sync, basic commands). The analytics layer and 7 of 11 commands are still in Ruby. Once analytics ships in Go and the binary survives a real season of in-game use, the Ruby gem will be retired.

### GO-1. Port analytics layer to Go

**What:** Port `pitch_rules.rb`, `lineup_optimizer.rb`, `development_arc.rb`, `pre_game_brief.rb` into `internal/analytics/{pitch,lineup,development}` and `internal/brief`. Pure-Go domain logic; no I/O. Each Ruby Struct becomes a Go struct; class methods become package functions.
**Why:** Without analytics the Go binary can only sync — it cannot brief. The analytics ARE the product; the Go port is incomplete until they land.
**Effort:** human ~1 day / CC ~30 min. **Priority:** P1 (next Go port milestone).
**Depends on:** Nothing — pure-Go work against the row types already defined in `internal/store/types.go`.
**Source:** Deferred at /ship checkpoint 2026-05-14 after smoke-test passed against live API.

### GO-2. Port formatters to Go

**What:** Port `formatters/{table,json,markdown}.rb` `Brief()` methods (the only formatter surface needed for the `brief` command) into `internal/format`. Use `github.com/olekukonko/tablewriter` for table output to match the Ruby version's `terminal-table` aesthetic.
**Why:** The `brief` command's value is in its formatted output. Without ported formatters, the Go binary cannot produce the brief.
**Effort:** human ~half-day / CC ~20 min. **Priority:** P1 (after GO-1).
**Depends on:** GO-1.
**Source:** Deferred at /ship checkpoint 2026-05-14.

### GO-3. Port remaining 7 commands to Go

**What:** Wire Cobra commands for `brief` (default), `plan`, `lineup`, `equity`, `hitting`, `progress`, `availability`, `pitches`. Each follows the same shape as the already-ported `refresh` command: load config → open store → query → format → print.
**Why:** Achieves full Ruby parity. Required before the Ruby gem can be retired.
**Effort:** human ~1 day / CC ~30 min. **Priority:** P1 (after GO-2).
**Depends on:** GO-1, GO-2.
**Source:** Deferred at /ship checkpoint 2026-05-14.

### GO-4. Unit tests for `internal/client` and `internal/commands`

**What:** Add `client_test.go` (mock `http.RoundTripper` to assert request shape, auth retry behavior, `ErrBoxscoreNotFound` mapping) and per-command tests using Cobra's `SetArgs`/`SetOut` plumbing.
**Why:** Currently these packages have 0% unit coverage. The `sync` integration test exercises both end-to-end, but per-package mocks catch edge cases (network errors, malformed JSON, retry exhaustion) that the integration test doesn't.
**Effort:** human ~half-day / CC ~20 min. **Priority:** P2.
**Depends on:** Nothing.
**Source:** Test coverage gap identified at /ship checkpoint 2026-05-14.

### GO-5. Resolve gc.com `/auth` signing — or commit to `auth import` as the path

**What:** Two options. (a) Reverse-engineer the `gc-signature`/`gc-timestamp` HMAC scheme by inspecting web.gc.com's JS bundle, then implement the multi-step (client-auth → user-auth-with-code) login in `internal/client` and the Ruby `Client`. (b) Accept that `auth import` (paste-from-browser token) is the supported flow, document it as such, and remove the broken `setup` interactive flow from both implementations.
**Why:** Today neither CLI can authenticate via username/password. The Ruby `setup` path is broken and the Go `setup` path inherits the same bug. `auth import` works but the user has to copy a token from DevTools every hour. Picking one path closes the auth story.
**Effort:** (a) human ~1-3 days reverse engineering + CC ~1 hour wiring / (b) human ~30 min + CC ~10 min. **Priority:** P2.
**Depends on:** Nothing.
**Source:** Surfaced during /ship checkpoint 2026-05-14 when both CLIs 401'd. Documented in CHANGELOG Unreleased.

### GO-6. Release packaging for the Go binary

**What:** Add `.github/workflows/release.yml` that builds the Go binary for darwin/arm64 + darwin/amd64 + linux/amd64 on tag push and attaches artifacts to the GitHub release. Optionally homebrew tap.
**Why:** Once the port reaches parity (after GO-1..GO-3) users need a way to install it. Today the only install path is `go install github.com/joshrpowell/gamechanger-cli/cmd/gamechanger@latest` which assumes the user has Go on PATH.
**Effort:** human ~half-day / CC ~30 min. **Priority:** P3 (only matters once Go reaches parity).
**Depends on:** GO-1, GO-2, GO-3.
**Source:** Distribution gap identified at /ship checkpoint 2026-05-14.

### GO-7. Decide Go module path

**What:** Current module path is `github.com/joshrpowell/gamechanger-cli` but the repo is `github.com/joshRpowell/gamechanger` (no `-cli` suffix, capital R in `joshRpowell`). Decide whether to (a) rename the module to match the repo, (b) move the Go code to a sub-repo, or (c) keep the mismatch and document it.
**Why:** `go install` will fail until the module path matches the repo path. Today the only install path is `go build` from a local checkout.
**Effort:** human ~15 min / CC ~5 min. **Priority:** P3.
**Depends on:** GO-6 (only matters once `go install` is the install path).
**Source:** Identified at /ship checkpoint 2026-05-14.

### GO-8. Anchor-fixture regeneration cadence + procedure (verify-parity harness)

**What:** Document in `internal/parity/testdata/README.md` (1) the regeneration command (`go run ./cmd/anonymize-fixture --source ~/.gamechanger/cache.db --out internal/parity/testdata/cache-anchor.db`), (2) the expected cadence (regenerate after any change to `internal/store/migrations.go` that adds/renames columns the analytics modules read, OR when `go test ./internal/parity/...` fails with "no such column"), and (3) how to verify the new fixture preserves the threat model (run the U3 falsification check after each regen).
**Why:** The committed anchor fixture goes stale as Ruby's Storage schema evolves. Today there is no documented signal that says "regenerate now" — first failure mode is a confusing "no such column: equity_score" from go-cmp during a CI run or local `go test`. A two-paragraph README closes this loop.
**Effort:** human ~30 min / CC ~10 min. **Priority:** P3 (only matters once the verify-parity harness ships — see 2026-05-14 plan).
**Depends on:** Verify-parity harness shipping (U4 fixture exists).
**Source:** Surfaced during /plan-eng-review on the verify-parity harness plan, 2026-05-14.
