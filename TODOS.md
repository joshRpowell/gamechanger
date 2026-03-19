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
