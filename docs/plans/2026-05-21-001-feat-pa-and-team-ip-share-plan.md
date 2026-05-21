---
title: "feat: Add PA to hitting and %IP to pitches"
type: feat
status: active
created: 2026-05-21
origin: docs/brainstorms/2026-05-20-pa-and-team-ip-share-requirements.md
---

# feat: Add PA to hitting and %IP to pitches

## Summary

Two additive columns to existing CLI reports, plus a pre-existing parser bug fix surfaced during the brainstorm probe.

- **`gamechanger hitting`** gains a `PA` column (plate appearances), computed as `AB + BB + HBP`. Sacrifices (`SF`/`SH`/`SAC`) are not exposed by the GameChanger boxscore endpoint — documented undercount.
- **`gamechanger pitches`** gains a `%IP` column showing each pitcher's share of the team's actual defensive innings across the report window, formatted as one decimal with `%` suffix (e.g. `42.3%`).
- **K/SO parser bug fix.** `lib/gamechanger/batter_stats_parser.rb:43` reads `stats['K']` but the real boxscore key is `'SO'`. All 306 cached `strikeouts` rows are 0. Bundled into this PR per scoping decision; CHANGELOG calls it out.

Both new columns are sortable via the existing `--sort` flag.

## Problem Frame

Coaches reading `hitting` can't see how many times a hitter actually came up — AB alone undercounts (walks, HBP). Coaches reading `pitches` can see per-pitcher IP but not how it distributes across the staff's defensive workload. The brainstorm's 2026-05-21 probe (see `docs/research/gc-api-notes.md` § "Probe — batter stat keys for PA computation") also surfaced that strikeouts have silently never been populated due to a key-name mismatch.

## Scope

### In scope

- Parser: extend `BatterStatsParser` to read HBP from `lineup.extra[]` (joined by `player_id`), and fix the `K` → `SO` key.
- Storage: migration v5 adding `hbp INTEGER NOT NULL DEFAULT 0` to `game_batter_stats`. Upsert + query changes.
- Derived stats at query time: PA = `at_bats + walks + hbp`; team-IP-share computed in Ruby from `season_summary` rows.
- Formatters (table, markdown, JSON): add `PA` column on `hitting`, `%IP` column on `pitches`.
- Sort key registration: `pa` on `HITTING_SORT_KEYS`, `ip_share` on `SEASON_SORT_KEYS`.
- README updates for both columns + sort keys; CHANGELOG entry under `[Unreleased]` calling out PA, %IP, migration v5, and the K/SO fix (with refresh recommendation).
- Regression tests for each unit per scenarios below.

### Deferred to Follow-Up Work

- OBP / SLG / OPS (PA unlocks these — separate work).
- Per-game breakdown of `%IP` (game-by-game share view).
- Surfacing PA on the per-batter `--player` view (`batter_games`) — current scope is the season summary only.

### Outside this product's identity

- Pitching workload pacing alerts / pitch-count rules already live in `lib/gamechanger/pitch_rules.rb`. `%IP` is a stat column, not a workload-management feature.

## Key Technical Decisions

1. **HBP via `lineup.extra[]` join, not a per-player `stats` field.** Mirrors the existing `BoxscoreParser` pattern for `#P`/`TS`/`BF` on the pitching group (`lib/gamechanger/boxscore_parser.rb`). Build the `player_id → hbp_value` lookup once per parse, then attach to the lineup row.
2. **No stored `pa` column.** PA is derived at query time as `at_bats + walks + hbp`. Storing it would duplicate primary data.
3. **`%IP` computed in Ruby, not SQL.** Single SQL query already returns season pitcher rows; computing the share in Ruby is clearer to test in isolation and keeps the SQL untouched. Group rows by team-total IP across the same window, divide per pitcher, render as one decimal. Zero-denominator → render `—`.
4. **`innings_pitched` is a true decimal** (`3.333...` for 3⅓), not baseball `3.1` notation. Verified against cache. `%IP` is plain float math.
5. **K/SO parser fix bundles with PA work.** One parser pass, one CHANGELOG callout, one user-facing refresh recommendation.
6. **Spec fixtures hard-flip from `'K'` to `'SO'`.** No defensive alias. Spec fixtures should mirror the real API.
7. **Sort key names:** `pa` (hitting) and `ip_share` (pitches). Lower-case, brief, consistent with existing keys (`ab`, `bb`, `pct`, `7day`).

## High-Level Technical Design

Data flow for the new derived columns (directional guidance, not implementation specification):

```text
boxscore JSON
  ├── lineup.stats[]   ── AB, BB, H, SO         ─┐
  └── lineup.extra[]   ── HBP entries by player ─┴── BatterStatsParser
                                                      ├── (existing) at_bats, hits, walks, strikeouts
                                                      └── (new)      hbp
                                                              │
                                                              ▼
                                                    game_batter_stats (+hbp col, mig v5)
                                                              │
                                                              ▼
                                                    season_batting_summary (+SUM(hbp) AS total_hbp)
                                                              │
                                                              ▼
                                                    Hitting cmd → derive PA = total_ab + total_walks + total_hbp
                                                              │
                                                              ▼
                                                    Formatters render PA column

game_pitcher_stats (existing innings_pitched)
                                                              │
                                                              ▼
                                                    season_summary rows
                                                              │
                                                              ▼
                                                    Pitches cmd → team_total_ip = SUM(rows.innings_pitched)
                                                              │     per-row pct = row.ip / team_total_ip * 100
                                                              ▼
                                                    Formatters render %IP column
```

## Implementation Units

### U1. Fix K → SO key and extend BatterStatsParser with HBP

**Goal:** Make the parser read strikeouts correctly (`SO`) and extract HBP from `lineup.extra[]`.

**Requirements:** Brainstorm — PA definition (`AB + BB + HBP`), K/SO bug fix.

**Dependencies:** none.

**Files:**
- `lib/gamechanger/batter_stats_parser.rb` (modify)
- `spec/gamechanger/batter_stats_parser_spec.rb` (modify)

**Approach:**
- Change `stats['K'].to_i` → `stats['SO'].to_i` and rename the returned key path remains `strikeouts:`.
- Add `hbp:` to the returned hash. Build `hbp_by_player_id` from the lineup group's `extra[]` entries where `stat_name == 'HBP'`, mapping `player_id → value`. Default to 0 when absent.
- Hard-flip all spec fixtures in `batter_stats_parser_spec.rb` from `'K' => N` to `'SO' => N`. Add fixtures exercising the `extra[]` HBP shape.

**Patterns to follow:**
- `lib/gamechanger/boxscore_parser.rb` already joins `pitching.extra[]` entries (`#P`, `TS`, `BF`, `WP`) to per-player stats. Mirror the lookup-once-then-attach shape.

**Test scenarios:**
- Happy: a lineup with three batters, two with HBP entries in `extra[]` — parser returns correct `hbp` values for both, 0 for the third.
- Happy: parser returns `strikeouts` populated from the `SO` key (regression for the bug).
- Edge: `extra[]` array is empty (no HBP that game) — all batters get `hbp: 0`, no error.
- Edge: `extra[]` contains an HBP entry for a `player_id` not in the lineup roster — entry is silently ignored (no exception, no spurious row).
- Edge: `lineup.stats[]` row has no `SO` key at all (older or partial payload) — `strikeouts` defaults to 0.
- Edge: an HBP entry value is `0` — accepted as 0, treated identically to absence.

**Verification:** `bundle exec rspec spec/gamechanger/batter_stats_parser_spec.rb` passes. No specs anywhere still reference the `'K' =>` fixture shape.

---

### U2. Migration v5 and storage upsert for hbp

**Goal:** Persist HBP per batter per game; surface `total_hbp` from the season query.

**Requirements:** Brainstorm — migration v5 (single `hbp` column on `game_batter_stats`).

**Dependencies:** U1 (parser produces the `hbp` field consumed by storage).

**Files:**
- `lib/gamechanger/storage.rb` (modify)
- `spec/gamechanger/storage_spec.rb` (modify)

**Approach:**
- Append `[5, "ALTER TABLE game_batter_stats ADD COLUMN hbp INTEGER NOT NULL DEFAULT 0;"]` to the `MIGRATIONS` array. Existing rows backfill to 0; user `gamechanger refresh` repopulates.
- Update `upsert_batter_stats` INSERT column list and `ON CONFLICT` update list to include `hbp`. Bind `stat[:hbp].to_i`.
- Update `season_batting_summary` SQL to add `SUM(gbs.hbp) AS total_hbp` in the SELECT (and into the 7-day window block if 7-day PA exposure is desired — for now, season-total only is enough for the `PA` column).
- Update `batter_games` SQL to include `gbs.hbp` so the per-game view has the field available (not displayed yet — see Deferred).

**Patterns to follow:**
- The existing migration v2 (`ADD COLUMN strikes_thrown`) and v4 (`game_fielding_positions`) sequencing in `storage.rb` MIGRATIONS. Follow the same `[N, <<~SQL]` shape and ordering.
- `upsert_pitcher_stats` for the upsert + `ON CONFLICT` pattern.

**Test scenarios:**
- Happy: upserting a batter row with `hbp: 2` then re-upserting with `hbp: 3` leaves the row with `hbp: 3` (idempotent).
- Happy: `season_batting_summary` returns `total_hbp` summed correctly across multiple games for one batter.
- Happy: migrating an existing v4 database to v5 leaves existing rows with `hbp = 0` (no data loss).
- Edge: a batter row with no HBP key in the upsert payload (older parser path during transition) — `to_i` of nil yields 0, no error.

**Verification:** `bundle exec rspec spec/gamechanger/storage_spec.rb` passes. `sqlite3 :memory:` schema after migrations applied contains an `hbp` column on `game_batter_stats`.

---

### U3. Hitting command: derive PA, register sort key, propagate to formatters

**Goal:** Surface `PA` as a sortable column on the `hitting` season summary.

**Requirements:** Brainstorm — `PA` column on `hitting`, sortable via `--sort`.

**Dependencies:** U2 (`total_hbp` available on summary rows).

**Files:**
- `lib/gamechanger/commands/hitting.rb` (modify)
- `lib/gamechanger/formatters/table.rb` (modify — hitting headings + row builder)
- `lib/gamechanger/formatters/markdown.rb` (modify — hitting headings + row builder)
- `lib/gamechanger/formatters/json.rb` (modify — add `pa` to the JSON row hash)
- `spec/gamechanger/commands/hitting_spec.rb` (modify)
- `spec/gamechanger/formatters/table_spec.rb` (modify)
- `spec/gamechanger/formatters/markdown_spec.rb` (modify)
- `spec/gamechanger/formatters/json_spec.rb` (modify)

**Approach:**
- In `Hitting#show_hitting`, derive `r['pa']` per row as `r['total_ab'].to_i + r['total_walks'].to_i + r['total_hbp'].to_i` before sort/render.
- Register `'pa' => ->(r) { r['pa'].to_i }` in `HITTING_SORT_KEYS`.
- Formatter table heading: insert `'PA'` adjacent to `'AB'` (recommend before `'AB'` so PA-then-AB reads as superset-then-subset). Markdown formatter: same. JSON formatter: add `pa` key to the per-row hash.

**Patterns to follow:**
- Existing `HITTING_SORT_KEYS` lambdas in `lib/gamechanger/commands/hitting.rb` for the sort registration shape.
- Existing column extension pattern from the recently-shipped fielding `Pos` column (v0.5.0) for formatter wiring.

**Test scenarios:**
- Happy: a batter with AB=4, BB=2, HBP=1 shows `PA = 7` in the table.
- Happy: `--sort pa` orders rows by descending (with `--desc`) and ascending (without) PA.
- Happy: `--sort pa` with a tie at PA=5 falls back to existing tie-break behavior (whatever `Sorting.apply` does today — assert on observed order, do not invent a new tie-break).
- Edge: a batter with AB=0, BB=0, HBP=0 (e.g. lineup row with all zeroes) — PA renders as `0`, doesn't break the table.
- Edge: `--sort pa` with an empty rowset — sorts to empty without error.
- Markdown and JSON formatters render the same `pa` value as the table for the same input row.

**Verification:** `bundle exec rspec spec/gamechanger/commands/hitting_spec.rb spec/gamechanger/formatters/` passes. Manual: `gamechanger hitting --sort pa --desc` prints a `PA` column ordered descending.

---

### U4. Pitches command: compute %IP, register sort key, propagate to formatters

**Goal:** Surface `%IP` as a sortable column on the `pitches` season summary.

**Requirements:** Brainstorm — `%IP` column on `pitches`, one decimal, sortable.

**Dependencies:** none beyond existing storage (uses `innings_pitched` already in cache).

**Files:**
- `lib/gamechanger/commands/pitches.rb` (modify)
- `lib/gamechanger/formatters/table.rb` (modify — pitches headings + row builder)
- `lib/gamechanger/formatters/markdown.rb` (modify — pitches headings + row builder)
- `lib/gamechanger/formatters/json.rb` (modify — add `ip_share` to JSON row hash)
- `spec/gamechanger/commands/pitches_spec.rb` (modify)
- `spec/gamechanger/formatters/table_spec.rb` (modify)
- `spec/gamechanger/formatters/markdown_spec.rb` (modify)
- `spec/gamechanger/formatters/json_spec.rb` (modify)

**Approach:**
- In `Pitches#show_season`, after fetching `season_summary` rows but before sort:
  - `team_total_ip = rows.sum { |r| r['innings_pitched'].to_f }` — note `season_summary` SELECT may need `SUM(gps.innings_pitched) AS total_ip` added (verify the existing SELECT; if absent, add it as a minimal SQL change in this unit rather than splitting).
  - Per row: `r['ip_share'] = team_total_ip.positive? ? (r['total_ip'].to_f / team_total_ip * 100.0) : nil`.
- Register `'ip_share' => ->(r) { r['ip_share'] }` in `SEASON_SORT_KEYS`. Sorting module handles `nil` per existing convention.
- Formatter: new column header `'%IP'`. Render `'%.1f%%' % v` when non-nil; render `'—'` (em-dash) when nil.

**Patterns to follow:**
- Existing `SEASON_SORT_KEYS` `'pct'` lambda — same nil-on-zero-denominator pattern.
- Formatter column rendering for `%` already exists for strike percentage (`pct`). Reuse the formatting helper if one exists; otherwise inline `'%.1f%%' %`.

**Test scenarios:**
- Happy: three pitchers with IP 4.0, 3.0, 3.0 → shares `40.0%`, `30.0%`, `30.0%`. Sum is 100.0%.
- Happy: `--sort ip_share --desc` orders pitchers by descending share.
- Happy: a pitcher with IP=0 and others with IP — gets `0.0%`, doesn't break the row.
- Edge: a team-total IP of 0 (no pitching data) — every row renders `—`, no division by zero.
- Edge: fractional IP — pitcher with `3.333...` IP on a team total of `10.0` renders `33.3%` (one decimal, rounded).
- Edge: `--sort ip_share` when all rows have `nil` share — sorts without error.
- Markdown and JSON formatters render the same `ip_share` value (formatter-appropriate type — string with `%` for table/markdown, float for JSON).

**Verification:** `bundle exec rspec spec/gamechanger/commands/pitches_spec.rb spec/gamechanger/formatters/` passes. Manual: `gamechanger pitches --sort ip_share --desc` prints a `%IP` column ordered descending.

---

### U5. README and CHANGELOG updates

**Goal:** Document the new columns, sort keys, and the K/SO fix for users.

**Requirements:** Brainstorm — docs/packaging.

**Dependencies:** U1–U4.

**Files:**
- `README.md` (modify — hitting and pitches usage sections, sort-key tables)
- `CHANGELOG.md` (modify — `[Unreleased]` section)

**Approach:**
- README: add `PA` to the hitting column list with definition (`AB + BB + HBP`; note SF/SH unavailable); add `%IP` to the pitches column list with definition; add `pa` and `ip_share` to the documented sort keys for each command.
- CHANGELOG: under `[Unreleased]` add three bullets — `PA` column on `gamechanger hitting`, `%IP` column on `gamechanger pitches`, strikeouts column now populated correctly (existing cache rows show 0 until `gamechanger refresh`). Note migration v5 in the same section.

**Test scenarios:** none — pure documentation. `Test expectation: none -- documentation-only changes verified by review.`

**Verification:** README diff shows the new columns and sort keys; CHANGELOG `[Unreleased]` lists all three changes with the refresh callout.

## System-Wide Impact

- **Schema change (migration v5):** existing users on the 0.5.0 schema run a single additive `ALTER TABLE ADD COLUMN` on first invocation. SQLite handles this transparently; existing rows get `hbp = 0`.
- **User-visible data change:** strikeouts column transitions from always-0 to real values after a `refresh`. CHANGELOG calls this out so coaches aren't confused by the sudden jump.
- **No other commands affected.** `fielding`, `equity`, `brief`, `availability`, `lineup`, `plan`, `progress` are untouched. The per-batter `--player` view does not yet show PA (deferred).

## Risks

- **HBP join correctness.** The lookup must be built once per parse, not per batter (avoid O(n*m) on big lineups). Spec coverage explicitly exercises HBP for unknown player_id and absent HBP entries.
- **Column-width pressure on the `pitches` table.** Adding `%IP` at one decimal (`42.3%` = 5 chars + header). The table already has IP / pitches / strikes / 7day / avg / last. Eyeball on an 80-col terminal during implementation; if it overflows, consider abbreviating an existing column header.
- **Strikeouts surprise factor.** Coaches who've been looking at K=0 forever will suddenly see real numbers post-upgrade. CHANGELOG callout is the only mitigation; the underlying fix is correct.
- **Spec fixture hard-flip.** All existing batter-stats specs using `'K' =>` will fail until updated. Catching all fixture sites in one pass is the work of U1.

## Deferred to Implementation

- Exact column position of `PA` in the hitting table (before vs. after `AB`) — let the implementer eyeball both and pick what reads better. Recommendation in U3.
- Whether to also add `total_hbp` to the 7-day window block in `season_batting_summary` (would enable a future 7-day PA view) — leaving it season-only for now; can be added as a one-line follow-up if needed.
- Whether `season_summary` SQL needs `SUM(innings_pitched) AS total_ip` added or whether the existing SELECT already provides a per-row `innings_pitched` aggregate that can be summed in Ruby. U4 covers the small SQL adjustment if needed; verify against the actual SELECT during implementation.

## Verification

- All existing 683 specs continue to pass.
- New parser specs cover the four U1 scenarios; storage specs cover the four U2 scenarios; command + formatter specs cover the six U3 and six U4 scenarios.
- Manual end-to-end:
  - `bundle exec exe/gamechanger refresh` re-populates `game_batter_stats.hbp` and `.strikeouts` for the existing cache.
  - `gamechanger hitting --sort pa --desc` shows a `PA` column with values matching `AB + BB + HBP` and is correctly sorted.
  - `gamechanger pitches --sort ip_share --desc` shows a `%IP` column where row values sum to ~100% (within ±0.1% × pitcher count) and is correctly sorted.
  - `gamechanger hitting --format json` and `--format markdown` include the `PA` field/column.
  - `gamechanger pitches --format json` and `--format markdown` include the `ip_share` field/column.

## Origin

Brainstorm: `docs/brainstorms/2026-05-20-pa-and-team-ip-share-requirements.md`
Probe findings: `docs/research/gc-api-notes.md` § "Probe — batter stat keys for PA computation (2026-05-21)"
