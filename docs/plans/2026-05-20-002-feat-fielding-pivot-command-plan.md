---
title: "feat: Fielding pivot command"
type: feat
status: active
created: 2026-05-20
origin: docs/brainstorms/2026-05-20-fielding-pivot-command-requirements.md
---

# feat: Fielding pivot command

## Summary

Add `gamechanger fielding` — a new subcommand that renders a player-by-position pivot table of stored fielding stints across the season. Rows are players; columns are the canonical fielding positions present in the data; cells are integer stint counts; a `Total` column sums each row. Supports `--format table|markdown|json`, `--sort COL`, and `--desc` consistent with `hitting` / `pitches` / `equity`.

## Problem Frame

`v0.4.0` started storing per-stint fielding positions in `game_fielding_positions`, but the only consumer is the `Pos` column in `gamechanger hitting` showing each player's *most recent* positions. There is no surface for season-wide position usage — coaches asking "who plays SS, and how often?" have to read SQL.

This plan surfaces the existing data as a pivot view. It does not change parsing, syncing, or storage shape.

(see origin: `docs/brainstorms/2026-05-20-fielding-pivot-command-requirements.md`)

---

## Requirements

Carried from origin:

- R1. Standalone `gamechanger fielding` subcommand; not layered onto `hitting`.
- R2. Pivot shape: rows = players, columns = position codes in canonical order (`P, C, 1B, 2B, 3B, SS, LF, CF, RF, DH, EH`), cells = integer stint counts. Empty cells render as `.`.
- R3. Position columns are *dynamic*: only positions with ≥1 stint anywhere in the data set appear.
- R4. `Total` column = sum of per-row position cells; default sort `total` desc, jersey-name tiebreak; overridable via `--sort COL [--desc]` accepting `player`, `total`, or any position code present.
- R5. `--format table|markdown|json`. JSON is array of `{ player_name, positions: { POS: N, ... }, total: N }` with empty positions omitted from per-row hash.
- R6. Empty-data path: yellow "No fielding data in cache. Run `gamechanger refresh` to sync." + exit 1, matching `hitting`.
- R7. Cell metric is **stint count, not innings**. Honest to the data we have.

Deferred to follow-up (see Scope Boundaries):

- D1. Jersey number column (no current persistence path; adding it expands scope beyond this view).
- D2. `--last N` game window flag.
- D3. Per-game `--game GAME_ID` breakdown.
- D4. Per-inning counts (gated on the existing `phase-0-watch-probe` reminder).

---

## Scope Boundaries

### In scope

- New `Commands::Fielding` class delegating from `CLI#fielding`.
- New storage method aggregating stint counts per player per position across the season.
- New formatter methods `fielding(rows, columns)` on `Formatters::Table`, `Formatters::Markdown`, and `Formatters::Json`.
- Sort plumbing via the existing `Sorting` module.
- Test coverage for storage aggregation, command, each formatter, and CLI routing.

### Deferred to Follow-Up Work

- Jersey number column (requires persisting `players[].number` in storage; out of scope for the pivot view).
- `--last N` window flag (mechanical addition; defer until asked).
- Per-game breakdown subcommand or flag.

### Outside this product's identity

- Defensive performance metrics (errors, assists, putouts) — not in our data, not in scope.

---

## Key Technical Decisions

### KTD1. Aggregate in SQL, return a per-player row with a positions hash

The storage method returns one row per player whose per-position cells are already counted, plus a `total`. Shape:

```
[
  { 'player_name' => 'Bob Jones',
    'positions'   => { 'P' => 2, 'SS' => 5 },
    'total'       => 7 },
  ...
]
```

Rationale: keeps the SQL → Ruby translation thin, mirrors how `hitting` and `pitches` move rows from storage straight into formatters, and lets sorting operate on a single hash per row. The set of columns to render is derived from the union of `positions` keys across all rows in the command layer.

### KTD2. Canonical position-column ordering enforced in the command, referencing the existing constant

Storage returns the raw counts; the command computes the union of position codes seen across all rows and intersects with the canonical order to produce the column list passed to formatters. This keeps storage queries oblivious to display order and matches the brainstorm decision that column set is "positions with ≥1 stint, in canonical order."

**The canonical order reuses `Gamechanger::BatterStatsParser::KNOWN_POSITIONS`** (`lib/gamechanger/batter_stats_parser.rb:19`) rather than re-declaring the same list on the command. One source of truth: when the parser's allow-list changes, the pivot's column set follows automatically.

### KTD3. Sort plumbing reuses `Sorting.apply` with a lowercase, dynamic key map

`Sorting.apply` downcases the user's `--sort` argument before key lookup (`lib/gamechanger/sorting.rb:18`). The sort map therefore uses **lowercase** keys for both static columns and position codes (`'player'`, `'total'`, `'p'`, `'ss'`, `'1b'`, …). Users may type `--sort SS` or `--sort ss`; both resolve to the same lookup. Position codes are added dynamically per-invocation based on which columns are present in the current data set, each returning `row['positions'][code.upcase].to_i` so missing positions sort as 0.

### KTD4. Default sort applied manually before `Sorting.apply` short-circuits

`Sorting.apply` returns `rows` unchanged when `sort_key.nil?`, so the command cannot rely on it for the default. When `options[:sort]` is nil, the command sorts rows in Ruby by `total` desc with `player_name` asc tiebreak *before* calling `apply_sort`. When `options[:sort]` is set, the user's choice wins and the default is skipped.

### KTD5. Stint count, not innings

The cell metric is `COUNT(*)` from `game_fielding_positions` grouped by player + position. The brainstorm explicitly rules out inning-estimation. No fabrication.

---

## Implementation Units

### U1. Storage: `season_fielding_summary`

**Goal:** New storage method returning per-player aggregated stint counts by position across the season window.

**Requirements:** R2, R3, R4 (data), KTD1, KTD5.

**Dependencies:** None — the `game_fielding_positions` table already exists (v4 migration, `lib/gamechanger/storage.rb:64-77`).

**Files:**
- `lib/gamechanger/storage.rb` — add `season_fielding_summary` public method.
- `spec/gamechanger/storage_spec.rb` — add specs covering the new method.

**Approach:**
- Single query: `SELECT player_name, position, COUNT(*) AS n FROM game_fielding_positions gfp JOIN games g ON g.game_id = gfp.game_id WHERE g.game_date >= ? AND g.game_date < ? GROUP BY player_name, position`.
- Use the same `season_start` / `next_season_start` window pattern that `season_batting_summary` and `season_summary` use.
- Aggregate raw rows in Ruby into the per-player hash structure described in KTD1. Compute `total` per player as the sum of position counts.
- Order returned rows by `player_name ASC` — stable, deterministic. The command (U3) handles the user-facing default sort because `Sorting.apply` no-ops on a nil sort key (see KTD4).

**Patterns to follow:**
- `season_batting_summary` (`lib/gamechanger/storage.rb:233-258`) for window parameters.
- `fielding_positions_most_recent_by_name` (`lib/gamechanger/storage.rb:204-228`) for the JOIN + Ruby aggregation idiom.

**Test scenarios:**
- Happy path: two players with overlapping positions across multiple games returns correct counts per position and correct totals.
- Single-position player returns a one-entry `positions` hash with `total` equal to that count.
- Player whose stints all fall outside the season window is excluded from results.
- Empty `game_fielding_positions` table returns `[]`.
- Players ordered alphabetically when counts are equal.
- Re-syncing a game (which delete-then-inserts in `upsert_fielding_positions`) does not double-count.

**Verification:** Specs in `spec/gamechanger/storage_spec.rb` exercise each scenario against an in-memory SQLite store and the aggregated row shape matches KTD1.

---

### U2. Formatters: `fielding` method on table, markdown, json

**Goal:** Add `fielding(rows, columns)` to each formatter, rendering the pivot.

**Requirements:** R2, R3, R5, R7.

**Dependencies:** None at code level; logically depends on U1 for the input shape.

**Files:**
- `lib/gamechanger/formatters/table.rb` — add `fielding(rows, columns)`.
- `lib/gamechanger/formatters/markdown.rb` — add `fielding(rows, columns)`.
- `lib/gamechanger/formatters/json.rb` — add `fielding(rows, columns)`.
- `spec/gamechanger/formatters/table_spec.rb` — add fielding specs.
- `spec/gamechanger/formatters/markdown_spec.rb` — add fielding specs.
- `spec/gamechanger/formatters/json_spec.rb` — add fielding specs.

**Approach:**
- Inputs: `rows` is the array of hashes from `season_fielding_summary`. `columns` is the ordered array of position codes the command computed (canonical order, present-only).
- Table format: headers `Player`, each position code, `Total`. Empty cells render `.`. Right-align integer columns; left-align `Player`. Mirror the column-width logic already used for `hitting` (see `lib/gamechanger/formatters/table.rb`).
- Markdown format: pipe table; same column set; empty cells render `.`.
- JSON format: array of `{ player_name, positions: { POS: N, ... }, total: N }`. Per-row `positions` hash omits zero entries. Top-level shape is a plain array (not wrapped), consistent with how `hitting_json` returns its data.

**Patterns to follow:**
- Existing `hitting` method on each formatter for column construction, header rendering, and alignment.
- JSON formatter's array-of-hash output for `hitting`.

**Test scenarios:**
- Table — multi-player input renders header row, one row per player in input order, empty cells as `.`, `Total` column equals sum of cells.
- Table — single-player input renders correctly.
- Table — empty `rows` returns a header-only table or empty string (match existing formatter convention for empty input).
- Markdown — identical content shape, pipe-delimited, with a separator row.
- Markdown — `.` empty cells survive markdown rendering.
- JSON — `positions` hash omits zero entries; `total` is correct; structure parses with `JSON.parse` and round-trips through `JSON.generate`.
- JSON — empty input returns `[]`.
- Column ordering — when `columns` is `['P', 'SS', '2B']`, output preserves that exact order (the command, not the formatter, owns canonicalization).

**Verification:** All three formatter spec files exercise the above; manual visual check via `gamechanger fielding --format table` confirms alignment after U4 wiring.

---

### U3. Command: `Commands::Fielding`

**Goal:** New command class that loads the data, derives canonical column order, applies sort, and dispatches to the chosen formatter.

**Requirements:** R1, R4, R6, KTD2, KTD3.

**Dependencies:** U1, U2.

**Files:**
- `lib/gamechanger/commands/fielding.rb` — new command class.
- `spec/gamechanger/commands/fielding_spec.rb` — new spec file.

**Approach:**
- Inherits from `Commands::Base` like `Hitting`.
- `call` → `run_command` → `with_storage do |storage| show_fielding(storage) end`.
- `show_fielding(storage)`:
  1. `rows = storage.season_fielding_summary`.
  2. If `rows.empty?`: yellow "No fielding data in cache. Run `gamechanger refresh` to sync." + `exit 1` (mirror `Hitting#show_hitting`, `lib/gamechanger/commands/hitting.rb:40-43`).
  3. Build `columns` = `BatterStatsParser::KNOWN_POSITIONS & rows.flat_map { |r| r['positions'].keys }.uniq`. **Reuses the existing parser constant** (`lib/gamechanger/batter_stats_parser.rb:19`) — no second source of truth.
  4. Build dynamic sort map with **lowercase keys** (the `Sorting` module downcases user input — see KTD3). Static entries: `{ 'player' => ->(r) { r['player_name'] }, 'total' => ->(r) { r['total'].to_i } }`. Then one entry per present column: `code.downcase => ->(r) { r['positions'][code].to_i }`.
  5. Default sort (KTD4): when `options[:sort]` is nil, sort rows in Ruby by `[-r['total'].to_i, r['player_name']]` before calling `apply_sort`. This produces `total` desc, `player_name` asc tiebreak without relying on `Sorting.apply`.
  6. Call `apply_sort` (already on `Base` via the `Sorting` module pattern used in `Hitting`) — no-ops when sort_key is nil.
  7. `puts build_formatter.fielding(rows, columns)`.

**Patterns to follow:**
- `Commands::Hitting` (`lib/gamechanger/commands/hitting.rb`) — overall structure, error path, `apply_sort` reuse.
- `HITTING_SORT_KEYS` constant pattern for the static portion of the sort map.

**Test scenarios:**
- Happy path: multi-player rows produce one printed table, sorted by `total` desc by default.
- Default sort tiebreak: two players with equal totals are ordered by `player_name` ascending.
- `--sort player` sorts alphabetically ascending; `--sort player --desc` reverses.
- `--sort SS` (uppercase) AND `--sort ss` (lowercase) both resolve and sort by stint count at SS — regression coverage for the case-sensitivity bug surfaced in plan review.
- `--sort SS` ascending without `--desc`; descending with `--desc`.
- `--sort SS` when SS is not in the present columns raises `Sorting::InvalidSortKey` and the command prints the error to stderr and exits 1 (matches `Hitting`). Error message lists available sort keys lowercase, consistent with `Sorting.build_error`.
- `--format json` produces parseable JSON with the expected array shape.
- Empty storage prints the yellow "no fielding data" message and exits 1.
- Canonical column order: when the data set has stints at `RF`, `P`, `SS`, the `columns` passed to the formatter is `['P', 'SS', 'RF']`, not the insertion order, and is derived from `BatterStatsParser::KNOWN_POSITIONS`.

**Verification:** Specs in `spec/gamechanger/commands/fielding_spec.rb` cover each scenario using `instance_double(Storage)` and an in-memory shell, following `hitting_spec.rb`.

---

### U4. CLI routing

**Goal:** Register the `fielding` Thor command and document its flags.

**Requirements:** R1, R4, R5.

**Dependencies:** U3.

**Files:**
- `lib/gamechanger/cli.rb` — add `desc`, options, and method.
- `spec/gamechanger/cli_spec.rb` — if it exists, add a smoke spec for `gamechanger fielding --help` and routing. (Skip if no CLI spec file exists; command-level coverage in U3 is sufficient.)

**Approach:**
- Mirror the `hitting` block in `lib/gamechanger/cli.rb:62-68`:
  ```
  desc 'fielding', 'Show season fielding position usage'
  option :sort, type: :string,  desc: 'Sort by column key (player, total, or a position code present in the table)'
  option :desc, type: :boolean, default: false, desc: 'Sort descending'
  def fielding
    Commands::Fielding.new(options: options, shell: shell).call
  end
  ```
- `--format` is already a class-level option on `CLI` (`lib/gamechanger/cli.rb:16-17`), no need to re-declare.

**Patterns to follow:**
- The existing `hitting`, `equity`, and `pitches` Thor command definitions.

**Test scenarios:**
- `gamechanger fielding --help` includes the command description and sort/desc flags.
- Test expectation: routing-level coverage is incidental; command-level specs (U3) are authoritative.

**Verification:** `gamechanger fielding --help` lists the command; manual invocation against the existing cache renders the pivot.

---

### U5. Smoke test against the existing cache and update README + CHANGELOG

**Goal:** Confirm the feature works end-to-end against real data and document it.

**Requirements:** All R-IDs.

**Dependencies:** U1–U4.

**Files:**
- `README.md` — add a "Fielding pivot" subsection under the reports section, with an example output and a mention of `--sort`.
- `CHANGELOG.md` — add an entry under `## [Unreleased]` (or current next-release section) for the new command.

**Approach:**
- Run `bundle exec exe/gamechanger fielding` against `~/.gamechanger/cache.db` and visually confirm the table renders with sensible column set, totals, and alphabetic / numeric ordering.
- Run `bundle exec exe/gamechanger fielding --format json | jq .` to confirm JSON parses cleanly.
- Run `bundle exec exe/gamechanger fielding --sort total --desc` and a position-column sort to confirm sort plumbing works against real data.
- Add a usage example to README following the existing `hitting` / `pitches` section conventions.

**Test scenarios:**
- Test expectation: none — smoke verification + docs update. All behavioral coverage is in U1–U4 specs.

**Verification:** Smoke commands render the expected output; README diff renders cleanly in markdown preview; CHANGELOG entry follows the established format.

---

## System-Wide Impact

- **CLI surface:** adds one new command. No existing commands change.
- **Storage:** adds one read-only method on `Storage`. No schema changes — `game_fielding_positions` already supports the query.
- **Formatters:** adds one method to each of three formatters. Existing formatter behavior is untouched.
- **No external contract surfaces:** no env vars, no CI changes, no exported types.

---

## Risks

- **Risk: sort key validation surprises users.** If a user types `--sort 1B` but the team has no 1B stints in storage, `1B` will not be in the dynamic sort map and `Sorting::InvalidSortKey` fires. The error message should make this clear ("unknown sort key '1B' — valid keys: player, total, P, SS, ..."). Mitigation: the command-level test scenario for invalid sort keys verifies this message shape against `hitting`'s existing error UX.

- **Risk: same-name players collide in aggregation.** `game_fielding_positions` uses `player_name` as identity (denormalized when v4 landed; see origin doc Open Questions in `2026-05-20-fielding-positions-parser-and-hitting-column-requirements.md`). If two players share a name across the season, their stints are merged here, same as in `hitting` and other reports. Not introduced by this plan; documented as a known limitation in the same way the hitting view tolerates it.

---

## Verification (Plan-Level)

- All new specs pass under `bundle exec rspec`.
- `gamechanger fielding` runs against the existing cache, renders a pivot, and sorts correctly across `table`, `markdown`, and `json` formats.
- `gamechanger hitting` output is unchanged (no regression in the existing `Pos` column).
- README and CHANGELOG reflect the new command.

---

## What already exists

- `game_fielding_positions` table and `upsert_fielding_positions` (`lib/gamechanger/storage.rb:64-77`, `lib/gamechanger/storage.rb:182-197`) — schema is reused, no changes.
- `BatterStatsParser::KNOWN_POSITIONS` (`lib/gamechanger/batter_stats_parser.rb:19`) — position allow-list referenced by this plan, not duplicated.
- `Sorting.apply` (`lib/gamechanger/sorting.rb`) — sort plumbing reused with lowercase key map.
- `Commands::Base#with_storage` / `#build_formatter` / `#apply_sort` — shared infrastructure reused, no new abstraction.
- Existing `Formatters::{Table, Markdown, Json}#hitting` — pattern mirrored by the new `#fielding` methods.

## NOT in scope

- Jersey number column — needs new persistence path through syncer; deferred per brainstorm.
- `--last N` window flag — mechanical addition; deferred until requested.
- Per-game `--game GAME_ID` breakdown.
- Per-inning counts — gated on the existing `phase-0-watch-probe` reminder; live-game API surface not yet validated.
- Defensive performance stats (errors, assists, putouts) — not in API response.

---

## GSTACK REVIEW REPORT

| Review | Trigger | Why | Runs | Status | Findings |
|--------|---------|-----|------|--------|----------|
| Eng Review | `/plan-eng-review` | Architecture & tests (required) | 1 | CLEAR | 3 issues, all folded into plan |

**Findings folded:**
- **P1** — `Sorting.apply` downcases user input; original plan used uppercase position keys. Fix landed in KTD3 + U3: lowercase sort-map keys; regression test added covering both `--sort SS` and `--sort ss`.
- **P2** — DRY: `KNOWN_POSITIONS` would have been duplicated as `CANONICAL_POSITIONS` on `Commands::Fielding`. Plan now references `BatterStatsParser::KNOWN_POSITIONS` directly (KTD2, U3 step 3).
- **P3** — Default sort was described but not encoded; `Sorting.apply` no-ops on nil sort key. Fix landed in KTD4 + U3 step 5: command applies `[-total, player_name]` sort in Ruby before calling `apply_sort`.

**UNRESOLVED:** 0
**VERDICT:** ENG CLEARED — ready to implement.
