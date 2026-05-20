---
title: "feat: Fielding positions parser, storage, and hitting column"
type: feat
status: active
created: 2026-05-20
origin: docs/brainstorms/2026-05-20-fielding-positions-parser-and-hitting-column-requirements.md
probe: docs/research/gc-api-notes.md#boxscore-additional-groups-probe-2026-05-20
depth: standard
---

# feat: Fielding positions parser, storage, and hitting column

## Summary

Position data is already in the `/boxscore` response we consume — `lineup.stats[].player_text` carries each player's ordered position-stint history (e.g., `(SS, P)`, `(1B, 2B, 1B, P)`). The current `BatterStatsParser` reads every other field on lineup rows and discards this one. This plan extracts that field, persists per-stint rows in a new v4 table, and surfaces the player's most-recent-game position string as a `Pos` column on `gamechanger hitting` (table, markdown, JSON formatters).

End-to-end vertical slice in one PR. Own team only; opponent positions and the Go-side scout cross-link are deferred.

---

## Problem Frame

Coaches using `gamechanger hitting` see who hit but not what defensive role each player played. The data exists in every boxscore we already fetch and cache — we just discard `player_text` during parse. Rotation, equity, and fielding-fatigue analytics all gate on having positions stored; surfacing them on `hitting` is the smallest end-to-end unlock that validates the data plumbing.

See origin: `docs/brainstorms/2026-05-20-fielding-positions-parser-and-hitting-column-requirements.md`.

---

## Requirements (carried from origin)

- **R1.** Parser extracts `player_text` from each lineup row for the configured `team_slug`.
- **R2.** A new v4 migration creates `game_fielding_positions` with one row per (game, player, stint).
- **R3.** Syncer writes per-stint rows during the existing `run` flow; re-syncing a game replaces its rows (delete-then-insert).
- **R4.** `gamechanger hitting` shows a `Pos` column rendering the player's most-recent completed game's position string (e.g., `SS, P`). Empty when the player did not field in their most recent game in the window.
- **R5.** JSON formatter emits positions as an array (`positions: ["SS","P"]`), not a joined string.
- **R6.** v4 migration is additive only; v1–v3 unchanged.
- **R7.** Unknown position codes are logged and skipped — not stored, not crashed.

---

## Scope Boundaries

### In scope
- `BatterStatsParser` extension for `player_text`.
- v4 schema migration and storage methods for per-stint rows.
- Syncer wiring (write positions inside the existing per-game loop).
- `Pos` column on `hitting` across table, markdown, JSON formatters.
- Tests across parser, storage, syncer integration, and formatter rendering.

### Outside this product's identity
- Manual data entry of positions by coaches (gem is automation-first).

### Deferred for later
- Opponent positions and the Ruby↔Go `opposing_roster.position` cross-link (separate brainstorm, requires schema coordination).
- Per-inning timing (source data is per-stint only; live-state behavior is the Phase 0 watch probe's territory).
- `positions` command, fielding section in `brief`, position-based equity/fatigue/rotation reports.
- `--sort pos` on `hitting`.
- Backfill of historical games where `player_text` may have been dropped — re-running `gamechanger refresh` is the workaround.

### Deferred to Follow-Up Work
- Adding `player_id` to `game_batter_stats` (would unify the join key, but out of scope here — the new table stores `player_name` denormalized so the existing name-based query path keeps working).

---

## Key Technical Decisions

| Decision | Choice | Rationale |
|---|---|---|
| Parser surface | Extend `BatterStatsParser`, not `BoxscoreParser` | `BatterStatsParser` reads the `lineup` group where `player_text` lives. `BoxscoreParser` is pitching-only. Origin doc said "BoxscoreParser" imprecisely. |
| Storage shape | One row per (game_id, player_id, stint_index) | Lossless; multi-position players first-class. Primary position derivable as `stint_index = 0`. |
| Join key | Denormalize `player_name` into positions table | `game_batter_stats` uses `batter_name`, not `player_id`. Storing both `player_id` and `player_name` lets the hitting view join by name without touching v3. |
| Re-sync safety | Delete-then-insert per game | Position stints are ordered and the count varies per game; upsert-by-stint-index would leave stale rows when stint count drops. Matches existing `clear_non_final` precedent for re-fetch. |
| Aggregation rule | Most-recent completed game in the window | "What did they play last" matches coach mental model. Tiebreaker for same-day double-headers: `game_date DESC, fetched_at DESC`. |
| Unknown code policy | Log and skip; no crash, no store | New age levels / future expansions may surface unseen codes. Permissive parse prevents sync failure; logs let us notice. |
| Position-code allow-list | `P, C, 1B, 2B, 3B, SS, LF, CF, RF, DH, EH` | Probe confirmed P–RF on one game; DH/EH plausible at higher age levels (not seen in probe but expected). |

---

## High-Level Technical Design

```
                     /game-stream-processing/{id}/boxscore
                                   │
                                   ▼
                          BatterStatsParser
                                   │
              ┌────────────────────┴────────────────────┐
              ▼                                         ▼
        batter_stats(...)                       fielding_stints(...)
        {batter_name, AB,                       {player_id, player_name,
         H, BB, K}                               positions: ["SS","P"]}
              │                                         │
              ▼                                         ▼
   storage.upsert_batter_stats         storage.upsert_fielding_positions
              │                                         │
              ▼                                         ▼
        game_batter_stats                  game_fielding_positions
                                            (game_id, player_id,
                                             stint_index, position,
                                             player_name)
                                                        │
                                                        ▼
                                          hitting view JOIN by name
                                                        │
                                                        ▼
                                          Pos column in table/md/json
```

Directional only. The implementer should pick concrete method names and parameter shapes that match existing parser/storage conventions.

---

## Implementation Units

### U1. Extend `BatterStatsParser` with `fielding_stints`

**Goal:** Surface per-player ordered position-stint lists from the `lineup` group.

**Requirements:** R1, R7.

**Dependencies:** none.

**Files:**
- `lib/gamechanger/batter_stats_parser.rb`
- `spec/gamechanger/batter_stats_parser_spec.rb`

**Approach:**
- Add a `fielding_stints` method returning `[{ player_id:, player_name:, positions: [String] }]`. Each entry corresponds to one row in the lineup group's `stats[]` whose `player_text` is non-empty.
- Parse `player_text` by stripping the leading `(` and trailing `)`, splitting on `,`, and trimming whitespace from each token.
- Filter tokens against the allow-list (`P, C, 1B, 2B, 3B, SS, LF, CF, RF, DH, EH`). Unknown tokens are logged via `warn` (or the gem's existing logging convention if present) and dropped.
- Skip rows whose `player_text` is empty/missing or whose entire token list is filtered out — they did not field.
- Reuse the existing `build_player_index` / `lineup_group` private helpers; do not duplicate them.

**Patterns to follow:**
- Existing `batter_stats` method shape (same parser, sibling method) for player-index lookup, filter_map, and player-name composition.

**Test scenarios:**
- Single-position player: `player_text = "(SS)"` → one stint `["SS"]`.
- Multi-position player: `player_text = "(1B, 2B, 1B, P)"` → four stints in order.
- Whitespace tolerance: `"( SS , P )"` parses identically to `"(SS, P)"`.
- Empty `player_text`: row produces no entry.
- Unknown token: `"(SS, ZZ, P)"` yields `["SS","P"]` and emits a warning.
- Entirely unknown tokens: row produces no entry; one warning per unknown token.
- Pitcher row (`player_text == ""`) is silently skipped (no warning).
- Lineup group absent: returns `[]` (parity with existing `batter_stats` behavior).
- Unknown team_slug: raises `APIShapeError` (parity with existing constructor).

---

### U2. v4 migration and storage methods for `game_fielding_positions`

**Goal:** Persist per-stint position rows alongside existing per-game tables.

**Requirements:** R2, R3, R6.

**Dependencies:** none (parallelizable with U1).

**Files:**
- `lib/gamechanger/storage.rb`
- `spec/gamechanger/storage_spec.rb`

**Approach:**
- Add a `[4, <SQL>]` entry to `MIGRATIONS`:
  ```
  CREATE TABLE game_fielding_positions (
    id            INTEGER PRIMARY KEY,
    game_id       TEXT NOT NULL REFERENCES games(game_id) ON DELETE CASCADE,
    player_id     TEXT NOT NULL,
    player_name   TEXT NOT NULL,
    stint_index   INTEGER NOT NULL,
    position      TEXT NOT NULL,
    fetched_at    TEXT NOT NULL,
    UNIQUE(game_id, player_id, stint_index)
  );
  CREATE INDEX idx_gfp_game   ON game_fielding_positions (game_id);
  CREATE INDEX idx_gfp_name   ON game_fielding_positions (player_name);
  ```
- Add `upsert_fielding_positions(game_id:, stints:)`:
  - Inside `db.transaction(:immediate)`: `DELETE FROM game_fielding_positions WHERE game_id = ?`, then `INSERT` one row per `(stint_index, position)` per player.
  - Skip players whose `positions` array is empty.
- Add `fielding_positions_most_recent_by_name(season_start:, next_season_start:)` that returns `{ batter_name => "Pos1, Pos2" }`. Implementation sketch (SQL): for each `player_name`, find the latest game where they have rows (`game_date DESC, fetched_at DESC`), then concatenate that game's positions ordered by `stint_index`. SQLite supports `group_concat` and window functions; implementer picks the cleanest shape.
- All paths reuse existing helpers (`iso_now`, `db`, etc.).

**Patterns to follow:**
- `upsert_pitcher_stats` and `upsert_batter_stats` for the transaction/insert shape.
- `season_batting_summary` for the `season_start`/`next_season_start` window predicate.

**Test scenarios:**
- Fresh DB applies v1→v4 migrations cleanly; `schema_migrations` reflects v4.
- v3 DB upgrades to v4 without touching existing data.
- `upsert_fielding_positions` inserts ordered rows for a single-stint player.
- `upsert_fielding_positions` inserts ordered rows for a multi-stint player; `stint_index` matches input order.
- Re-running `upsert_fielding_positions` for the same game with a different stint count replaces rows (no stale rows remain).
- Empty `positions` array for a player produces no rows.
- `ON DELETE CASCADE`: deleting a game removes its position rows.
- `fielding_positions_most_recent_by_name` returns the latest game's stints, joined with `, `.
- Same-day double-header: tiebreaker is `fetched_at DESC` per the decision table.
- Player with no positions in the window: absent from the result hash.

---

### U3. Syncer integration — write positions during boxscore sync

**Goal:** Position rows are persisted as part of `gamechanger refresh` with no separate command needed.

**Requirements:** R3.

**Dependencies:** U1, U2.

**Files:**
- `lib/gamechanger/syncer.rb`
- `spec/gamechanger/syncer_spec.rb`

**Approach:**
- Inside the existing per-game block (just below the `upsert_batter_stats` call), instantiate the same `BatterStatsParser` (or reuse the existing instance — implementer's call) and call `fielding_stints`.
- Call `storage.upsert_fielding_positions(game_id:, stints:)` when the list is non-empty.
- Do not change the `SyncResult` struct fields — positions are a side effect of the same loop. (If telemetry is desired later, add in a follow-up.)

**Patterns to follow:**
- Existing `upsert_pitcher_stats` / `upsert_batter_stats` call site shape in `Syncer#run`.

**Test scenarios:**
- Sync of a game with own-team `player_text` populated writes the expected position rows.
- Sync of a game where own-team has no fielders (empty `player_text` everywhere) writes zero position rows but does not raise.
- Re-sync of a finalized game with `force: true` clears and re-inserts positions.
- 404 on boxscore (existing path) does not crash and does not partially-write positions.

---

### U4. Hitting formatter — `Pos` column across table, markdown, JSON

**Goal:** Surface positions in the user-facing `hitting` output.

**Requirements:** R4, R5.

**Dependencies:** U2 (needs `fielding_positions_most_recent_by_name`).

**Files:**
- `lib/gamechanger/commands/hitting.rb`
- `lib/gamechanger/formatters/table.rb`
- `lib/gamechanger/formatters/markdown.rb`
- `lib/gamechanger/formatters/json.rb`
- `spec/gamechanger/commands/hitting_spec.rb`
- `spec/gamechanger/formatters/table_spec.rb`
- `spec/gamechanger/formatters/markdown_spec.rb`
- `spec/gamechanger/formatters/json_spec.rb`

**Approach:**
- In `Hitting#show_hitting`: after `storage.season_batting_summary`, fetch the positions map (`storage.fielding_positions_most_recent_by_name(...)`) once, merge each row with `r['positions'] = positions_map[r['batter_name']] || []`.
- Table/markdown formatters: add a `Pos` column after `Trend`, rendering `r['positions'].join(', ')`. Empty cell when the array is empty.
- JSON formatter: add `positions: r['positions']` (array) to each row's hash. Joined-string rendering is for display formatters only.
- Do not affect `batter_games` (per-batter command) in this PR — it is a separate render path; deferred follow-up.

**Patterns to follow:**
- Existing `Trend` column derivation pattern (data added to row hash, formatter reads it from the row).
- JSON formatter's existing array-typed fields (find any existing precedent in `formatters/json.rb` and mirror its style).

**Test scenarios:**
- Player with single-position most-recent game renders `(SS)` → column shows `SS`.
- Player with multi-stint most-recent game renders `(1B, 2B, P)` → column shows `1B, 2B, P`.
- Player with no fielding rows in the window → column shows empty cell.
- JSON output for the above three cases emits `positions: ["SS"]`, `positions: ["1B","2B","P"]`, and `positions: []` respectively.
- Existing hitting columns (G, AB, H, BB, K, AVG, OBP, Trend) are unchanged in count, order, and values.
- `--sort` on existing keys continues to work (no Pos sort key added).
- Markdown formatter renders the new column with correct header alignment (mirrors existing markdown column conventions).

---

## System-Wide Impact

- **Schema version bumps from v3 → v4.** First-time users on v4 builds get the table; existing users get an additive migration on next CLI run. No data loss path.
- **Ruby↔Go parity.** This change is Ruby-only. Go port's `MIGRATIONS` list is unchanged; the Go side will not see positions until a separate coordinated PR. The dormant `opposing_roster.position` column on the Go side is unaffected.
- **No new API calls, no new auth surface, no new external dependencies.** Same response, more fields consumed.
- **Hitting output gains one column.** Anyone scripting against the table output by column count will need to update. JSON consumers gain an optional `positions` field.

---

## Risks

- **Position-code drift.** GameChanger may surface codes outside the allow-list (e.g., `EH` for extra hitter at higher age levels, or a `BN` for bench). Mitigation: the "log + skip unknowns" rule prevents crashes; the warning makes drift visible. Adding new codes is a one-line allow-list edit.
- **Name collisions on the join.** If two players on the same team share `batter_name`, the positions join is ambiguous. Existing `game_batter_stats` already has this latent issue (same UNIQUE key shape). Out of scope to fix here; flagged in Deferred to Follow-Up Work.
- **Stint count change on re-sync.** Mitigated by delete-then-insert semantics; tested.
- **Empty-cell rendering across formatters.** Easy to miss in markdown (collapses pipes) or table (alignment). Tests cover the empty case explicitly.

---

## Verification

- `bundle exec rspec` passes, including all new specs.
- `bundle exec rspec --tag focus` (or equivalent) on the new specs passes in isolation.
- Manual smoke test: with the existing cache, `gamechanger refresh && gamechanger hitting` shows the new `Pos` column populated for at least one recent game.
- `sqlite3 ~/.gamechanger/cache.db "SELECT * FROM game_fielding_positions LIMIT 5"` returns rows after refresh.
- `gamechanger hitting --format json | jq '.[0].positions'` returns an array.

---

## Open Questions (deferred to implementation)

- Exact SQL shape for `fielding_positions_most_recent_by_name` — window function vs correlated subquery vs two-step query. Implementer picks the clearest shape; query plan can be checked against the cache DB if needed.
- Whether to emit the unknown-code warning via `warn`, `Kernel.warn`, or a project-specific logger. Mirror the convention used elsewhere in the gem if one exists; otherwise `warn` is fine.
- Markdown table column header label (`Pos` vs `Position`). Default `Pos` for terminal width; revisit if review prefers the full word.
