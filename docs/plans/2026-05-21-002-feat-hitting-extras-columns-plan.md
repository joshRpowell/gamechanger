---
title: "feat: Add 1B / 2B / 3B / HR columns to hitting table"
type: feat
status: active
created: 2026-05-21
depth: lightweight
origin: docs/brainstorms/2026-05-21-hitting-extras-columns-requirements.md
---

# feat: Add 1B / 2B / 3B / HR columns to hitting table

## Problem

`gamechanger hitting` shows total hits but no hit-type breakdown. Coaches reading the table can't see who is producing extra-base power without leaving the CLI.

## Goal

Add singles, doubles, triples, and home runs as integer columns to the season hitting table, placed between `H` and `BB`. Singles are derived (`H − 2B − 3B − HR`); doubles, triples, and home runs are stored.

## Approach summary

Mirror the just-shipped PA/HBP rollout (`docs/plans/2026-05-21-001-feat-pa-and-team-ip-share-plan.md`) one-for-one:

1. Extend `BatterStatsParser` to read `2B`, `3B`, `HR` from `lineup.extra[]` using the existing `extra_stat_by_player_id` helper (same pattern already used for `HBP`).
2. Add migration v6 to `Storage::MIGRATIONS` adding `doubles`, `triples`, `home_runs` columns to `game_batter_stats`.
3. Extend `upsert_batter_stats` and `season_batting_summary` to read/write/sum the new columns. Compute `singles = total_hits − total_2b − total_3b − total_hr` in SQL alongside the existing aggregates.
4. Extend the table, markdown, and JSON formatters to render the four new columns between `H` and `BB`.

No new endpoints, no new external dependencies. Existing `gamechanger refresh` re-runs the parser and populates the new columns for cached games.

## Key technical decisions

- **Singles derived in SQL, not in the formatter.** `season_batting_summary` already computes derived aggregates (PA, OBP-input sums); adding `(SUM(hits) - SUM(doubles) - SUM(triples) - SUM(home_runs)) AS total_singles` keeps each formatter trivial and ensures table/markdown/json render identically. Negative-arithmetic guard lives in the formatters (clamp to 0). (see origin: `docs/brainstorms/2026-05-21-hitting-extras-columns-requirements.md` §Open questions Q1)
- **All three formatters updated in the same PR.** The changes to `markdown.rb` and `json.rb` are 4 lines each — pulling the headings array and the row tuple. Splitting would create unnecessary churn. (see origin: Q2)
- **No new sort keys this iteration.** `HITTING_SORT_KEYS` stays as-is. (see origin: §Sort flag)
- **Per-batter `--player` view untouched.** Row width is already a concern; deferred. (see origin: §Per-batter game view)
- **TB / SLG not consumed.** Available in `lineup.extra[]` per the 2026-05-21 probe but explicitly out of scope. (see origin: §Out of scope)

## Scope boundaries

In scope: `BatterStatsParser` extension; migration v6; storage upsert + season-summary SQL; table/markdown/json formatter updates for `show_hitting`.

### Deferred to follow-up work

- TB column and SLG. Data is already in `lineup.extra[]` — pickup is cheap when wanted.
- `--sort 1b|2b|3b|hr` flags. Add when a user asks.
- Per-game `--player NAME` breakdown columns for extras.

## Implementation units

### U1. Extend `BatterStatsParser` with 2B / 3B / HR

**Goal:** Surface `doubles`, `triples`, `home_runs` on each per-row hash returned by `BatterStatsParser#batter_stats`.

**Requirements:** Origin §Parser changes; §Success criteria (parser populates new keys).

**Dependencies:** None.

**Files:**
- `lib/gamechanger/batter_stats_parser.rb` — extend the row hash and add three more `extra_stat_by_player_id` lookups.
- `spec/gamechanger/batter_stats_parser_spec.rb` — extend fixtures with `extra[]` entries for `2B`, `3B`, `HR`.

**Approach:** The parser already builds an `hbp_by_player_id` map from `lineup.extra[]`. Build three more (`doubles_by_player_id`, `triples_by_player_id`, `home_runs_by_player_id`) via the same helper, and add the three integer fields to the per-row hash. Update the YARD comment on `#batter_stats` to list the new keys.

**Patterns to follow:** Lines around `lib/gamechanger/batter_stats_parser.rb:37-52` — `hbp_by_player_id = extra_stat_by_player_id(lineup, 'HBP')` plus the `hbp:` line on the per-row hash.

**Test scenarios:**
- Happy path: lineup with `extra[]` entries for `2B`/`3B`/`HR` returns rows whose `doubles`/`triples`/`home_runs` integers match the source values.
- Edge case — missing `extra[]`: when `extra[]` is absent or none of the three stat_names appear, all three fields default to `0` (already covered by `extra_stat_by_player_id` returning `{}`; assert the row shape).
- Edge case — player in lineup with no extras: a row whose `player_id` does not appear in any of the three `extra[].stats[]` lists returns `0` for each.
- Edge case — `extra[]` lists a `player_id` not in the lineup: extra entry is silently ignored (already the behavior; assert the lineup-driven row count is unchanged).

**Verification:** `bundle exec rspec spec/gamechanger/batter_stats_parser_spec.rb` passes. The returned hash documented in the YARD comment matches the actual keys.

---

### U2. Migration v6: add `doubles`, `triples`, `home_runs` columns

**Goal:** Persist the three new integer fields on `game_batter_stats`.

**Requirements:** Origin §Storage.

**Dependencies:** None (additive ALTER TABLE; independent of U1).

**Files:**
- `lib/gamechanger/storage.rb` — append `[6, <<~SQL] ... SQL` entry to `MIGRATIONS` array.
- `spec/gamechanger/storage_spec.rb` — migration idempotency test mirroring the existing v5 test.

**Approach:** Three sequential `ALTER TABLE game_batter_stats ADD COLUMN <name> INTEGER NOT NULL DEFAULT 0;` statements in a single migration entry (SQLite executes them one per `db.execute_batch` call — match whatever invocation style migrations 1–5 already use; v5 used a single ALTER and is invoked the same way).

**Patterns to follow:** `lib/gamechanger/storage.rb:78-80` — the v5 HBP migration. Use the identical shape, three statements concatenated.

**Test scenarios:**
- Happy path: fresh in-memory DB → `migrate!` → `PRAGMA table_info(game_batter_stats)` shows `doubles`, `triples`, `home_runs` columns with `dflt_value=0`, `notnull=1`.
- Idempotency: `migrate!` followed by a second `migrate!` does not error and does not re-apply the migration (verify `schema_migrations` has exactly one row at version 6).
- Backward compatibility: an existing row inserted before migration v6 (simulated by manually rolling back to v5 — or skipped if the test harness doesn't support partial migration; in that case verify a fresh row inserted via the old INSERT signature would still get `0` defaults).

**Verification:** Migration block in `storage_spec` passes; existing migration tests still pass.

---

### U3. Storage: persist and aggregate the new columns

**Goal:** Plumb the three new fields from `upsert_batter_stats` into the table, and surface them (plus derived `total_singles`) in `season_batting_summary`.

**Requirements:** Origin §Storage; §Success criteria (refresh populates new columns; `season_batting_summary` exposes new aggregates).

**Dependencies:** U1 (parser keys), U2 (column exists).

**Files:**
- `lib/gamechanger/storage.rb` — extend `upsert_batter_stats` INSERT + ON CONFLICT clauses with the three columns; extend `season_batting_summary` SELECT.
- `spec/gamechanger/storage_spec.rb` — extend upsert and summary specs with new columns.

**Approach:** In `upsert_batter_stats` (around `lib/gamechanger/storage.rb:161-179`), add three more `?` placeholders, three more bound values (`stat[:doubles].to_i` etc.), and three more `excluded.<col>` lines in the ON CONFLICT block. In `season_batting_summary` (around `lib/gamechanger/storage.rb:274-296`), add `SUM(gbs.doubles) AS total_2b`, `SUM(gbs.triples) AS total_3b`, `SUM(gbs.home_runs) AS total_hr`, and `(SUM(gbs.hits) - SUM(gbs.doubles) - SUM(gbs.triples) - SUM(gbs.home_runs)) AS total_1b`.

**Patterns to follow:** The HBP column threading at `lib/gamechanger/storage.rb:166-176` and the `SUM(gbs.hbp) AS total_hbp` line at `lib/gamechanger/storage.rb:283`.

**Test scenarios:**
- Happy path — upsert: insert a row with `doubles: 1, triples: 0, home_runs: 1` → read back the row → values match.
- Happy path — re-upsert (ON CONFLICT): upsert the same `(game_id, batter_name)` with different values → row is updated, not duplicated.
- Default behavior: upsert a stat hash with no `:doubles`/`:triples`/`:home_runs` keys → row gets `0` for each (relies on `.to_i` on nil).
- Season summary aggregation: insert two games for one batter (`H=2, 2B=1, HR=1` and `H=3, 2B=0, 3B=1, HR=0`) → `season_batting_summary` returns `total_hits=5, total_2b=1, total_3b=1, total_hr=1, total_1b=2`.
- Season summary derivation when extras exceed hits (shouldn't happen, but guard): `H=2, 2B=3` → `total_1b` is `-1`; this is the formatter's job to clamp, not the SQL's. Assert the raw SQL returns the negative value so the formatter clamp is exercised by U4 tests.
- Season summary with no batters in window: returns `[]` (existing behavior, regression check).

**Verification:** `bundle exec rspec spec/gamechanger/storage_spec.rb` passes. `season_batting_summary` row keys include `total_1b`, `total_2b`, `total_3b`, `total_hr`.

---

### U4. Syncer: pass new keys through to storage

**Goal:** Ensure parsed `:doubles`/`:triples`/`:home_runs` reach `upsert_batter_stats`.

**Requirements:** Origin §Success criteria (`gamechanger refresh` populates new columns).

**Dependencies:** U1, U3.

**Files:**
- `lib/gamechanger/syncer.rb` — verify `batter_stats` array flows through verbatim (no field whitelisting expected; confirm and adjust if needed).
- `spec/gamechanger/syncer_spec.rb` — extend integration spec.

**Approach:** Inspect `lib/gamechanger/syncer.rb:71-72` (`batter_stats = batter_parser.batter_stats; @storage.upsert_batter_stats(...)`). If the syncer passes the parser output straight through, no syncer code changes are needed and this unit is test-only. If the syncer projects keys, extend the projection.

**Patterns to follow:** Existing HBP threading — the syncer already passes the parser hash directly; HBP arrived for free. Expect the same here.

**Test scenarios:**
- Integration: stub the boxscore response with `extra[]` entries for `2B`/`3B`/`HR` → run the syncer's batter-stats path → `game_batter_stats` row carries the values.
- Idempotency: run the sync twice → row is upserted, not duplicated; values match the latest fetch.

**Verification:** `bundle exec rspec spec/gamechanger/syncer_spec.rb` passes.

---

### U5. Formatters: render the four new columns

**Goal:** Add `1B`/`2B`/`3B`/`HR` to the table, markdown, and JSON outputs of `show_hitting`, between `H` and `BB`.

**Requirements:** Origin §Hitting table — new columns.

**Dependencies:** U3 (summary exposes new fields).

**Files:**
- `lib/gamechanger/formatters/table.rb` — extend headings + row tuple in `#hitting`.
- `lib/gamechanger/formatters/markdown.rb` — same.
- `lib/gamechanger/formatters/json.rb` — same.
- `spec/gamechanger/formatters/table_spec.rb`, `..._markdown_spec.rb`, `..._json_spec.rb` — extend expected output.

**Approach:** Each formatter currently builds a `headings` list and a row tuple from `season_batting_summary` rows. Insert `'1B', '2B', '3B', 'HR'` between `'H'` and `'BB'` in headings, and the matching values in the row tuple. Singles read from `r['total_1b'].to_i.clamp(0, Float::INFINITY)` (clamp negative to 0 per origin §Hitting table — new columns).

**Patterns to follow:** Current headings array at `lib/gamechanger/formatters/table.rb:173`; row tuple at `lib/gamechanger/formatters/table.rb:183`. Markdown counterpart at `lib/gamechanger/formatters/markdown.rb:164,174`. JSON at `lib/gamechanger/formatters/json.rb:139-150` — add `singles:`, `doubles:`, `triples:`, `home_runs:` keys between `hits:` and `walks:`.

**Test scenarios:**
- Happy path — table: row with `total_hits=5, total_2b=1, total_3b=0, total_hr=1` renders `5 | 3 | 1 | 0 | 1` for `H | 1B | 2B | 3B | HR`.
- Happy path — markdown: same row renders with the same values; header row contains the four new column names in order.
- Happy path — JSON: serialized row contains `singles: 3, doubles: 1, triples: 0, home_runs: 1`.
- Zero case: row with `total_hits=0` renders `0` for all four columns.
- Clamp case: row with `total_hits=2, total_2b=3` (impossible-but-guarded) renders `1B=0`, not `-1`.
- Header order across all three formatters matches the documented order exactly: `Batter | G | PA | AB | H | 1B | 2B | 3B | HR | BB | K | AVG | OBP | Trend | Pos`.

**Verification:** All three formatter specs pass. Snapshot tests, if present, are updated.

---

### U6. CHANGELOG and version bump

**Goal:** Record the user-visible change and the refresh requirement.

**Requirements:** Origin §Refresh.

**Dependencies:** U1–U5.

**Files:**
- `CHANGELOG.md` — new entry under next version heading.
- `lib/gamechanger/version.rb` — minor version bump (0.6.0 → 0.7.0, since this adds user-visible columns).

**Approach:** Mirror the v0.6.0 entry style (PA + %IP rollout). Note that `gamechanger refresh` is required to backfill historical games.

**Test scenarios:** None — pure documentation and version constant.

**Test expectation:** none -- documentation and version constant only.

**Verification:** `bundle exec rspec` full suite green. `gamechanger hitting` on a refreshed local cache shows the four new columns populated with sensible values.

## Verification

- `bundle exec rspec` — full suite green.
- `gamechanger refresh` then `gamechanger hitting` on a real local cache → output matches the documented column order with populated values.
- A player known to have an extra-base hit in the cache shows non-zero `2B`/`3B`/`HR` as appropriate; the rest show `0` and `1B = H`.

## Risks

- **Negative `total_1b`** if a future bug causes hits to be under-counted relative to extras. Mitigated by the clamp-to-0 in the formatters (U5) and the dedicated test scenario.
- **Stale cache rows.** Existing rows have `0` for the new columns until `refresh` runs. The CHANGELOG note is the user-facing mitigation; matches the just-shipped PA/HBP UX.
- **Spec fixture drift.** The existing parser spec uses small hand-crafted boxscore responses. Extending them is mechanical, but missing an `extra[]` entry in the new fixtures would cause confusingly-passing tests. The "missing `extra[]`" scenario in U1 is the canary for this.
