---
title: "feat: Pitching catch-up extract (ERA, WHIP, K/9, BAA)"
type: feat
status: active
created: 2026-05-21
origin: docs/brainstorms/2026-05-21-pitching-catch-up-extract-requirements.md
---

# feat: Pitching catch-up extract (ERA, WHIP, K/9, BAA)

## Summary

Extract the 8 already-visible-but-unused pitching fields from `/boxscore` (`BF, WP, HBP, H, R, ER, BB, SO`) and surface coach-standard rate stats on the `pitches` command. Mirrors the v5–v6 batter-side extraction pattern (PA/HBP/2B/3B/HR).

- **Parser:** extend `BoxscoreParser#pitcher_stats` to surface all 8 fields. `BF/H/R/ER/BB/SO` always present; `WP/HBP` sparse (default 0 when absent).
- **Storage:** migration **v7** — 8 additive `ALTER TABLE ADD COLUMN` statements on `game_pitcher_stats`. Update upsert, `season_summary`, and `pitcher_games`.
- **Command (`pitches`):** derive ERA, WHIP, K/9, BAA, BB/9, P/IP, P/BF at query time. Default columns add ERA + WHIP + K/9; BB/9 + BAA + P/IP gated behind `--advanced`. All new columns sortable.
- **Per-outing view (`--pitcher`):** show raw counts (`ER, H, BB, SO, BF`) per outing; add a cumulative-summary row with derived rates rather than rendering noisy per-outing rates.
- **Formatters:** table, markdown, JSON each get the new columns/fields.
- **Docs:** README columns + sort keys; CHANGELOG under `[Unreleased]` with `gamechanger refresh` recommendation.

## Problem Frame

The `pitches` command today shows workload (pitches, strikes, IP, %IP, 7-day) but not the rate stats coaches actually use to compare pitchers — ERA, WHIP, K/9, BAA. The 2026-05-21 probe (see `docs/research/gc-api-notes.md` § "Probe — pitching stat keys gap analysis") confirmed all the inputs are already in the same `/boxscore` response the gem already fetches. This is a parser + storage extension, no new endpoints.

## Scope

### In scope

- Parser: extend `BoxscoreParser#pitcher_stats` to emit `batters_faced, wild_pitches, hbp_allowed, hits_allowed, runs_allowed, earned_runs, walks_issued, strikeouts_recorded`. `WP/HBP` join from `pitching.extra[]` mirroring the existing `#P/TS/BF` extraction shape. `H/R/ER/BB/SO` from per-player `pitching.stats[].stats`.
- Storage: migration **v7** adding 8 columns to `game_pitcher_stats` (all `INTEGER NOT NULL DEFAULT 0`). Update `upsert_pitcher_stats` and the SELECTs in `season_summary`, `pitcher_games`, and `game_by_date`.
- Command: in `Commands::Pitches#show_season`, derive rate stats per row (ERA = ER × 9 / IP; WHIP = (H + BB) / IP; K/9 = SO × 9 / IP; BAA = H / (BF − BB − HBP); BB/9 = BB × 9 / IP; P/IP = pitches / IP; P/BF = pitches / BF). Nil on zero denominators.
- `--advanced` flag on `pitches` (new) that adds BB/9, BAA, P/IP to the default table output.
- Sort key registration: `era`, `whip`, `k9`, `bb9`, `baa`, `p_ip`, `p_bf` on `SEASON_SORT_KEYS`.
- Per-outing view (`pitcher_games`): add `er, h, bb, so, bf, wp, hbp` to the SELECT; render those as columns. Append a cumulative-summary row computing ERA/WHIP/K/9 across the displayed outings.
- Formatters (table, markdown, JSON): wire the new columns/fields end-to-end.
- README + CHANGELOG updates; refresh recommendation for cache backfill.
- Regression tests per scenarios below.

### Deferred to Follow-Up Work

- Per-outing rate stats (ERA per game etc.) — per-outing rates are noisy at youth-game sample sizes; revisit if a coach actually asks.
- Min-IP filter for rate stats — rely on `Sorting.apply` nil-handling for now; revisit if low-IP pitchers visibly distort sort order.
- 7-day rate-stat windows (parallel to `seven_day_total` for pitches).
- Surfacing rate stats on `brief`, `equity`, `progress`, or `availability` commands.
- Rate-stat formatting helper extraction (`Format.rate(value)`) — inline string formatting for now; extract when a third caller needs it.

### Outside this product's identity

- Pitch-by-pitch data (first-pitch-strike %, count leverage, pitch types) — not available on `/boxscore`. Separate streaming-endpoint probe.
- Defensive innings per pitcher — still the open Phase 0 watch-probe question.
- Opposing-team pitcher rate stats — known web-API gap (mobile-only).
- Pitching-workload alerts / rest-day rules — live in `lib/gamechanger/pitch_rules.rb`. This plan is reporting, not workload management.

## Key Technical Decisions

1. **Single migration (v7), all 8 columns.** Brainstorm sketched 8 separate `ALTER`s; collapsing to one migration is the same `[7, <<~SQL]` block with 8 statements (mirrors migration v6's multi-statement shape). One schema bump, one refresh recommendation.
2. **Migration number is v7, not v6.** Brainstorm doc was written before migration v6 (doubles/triples/home_runs) landed earlier today. Verify current MIGRATIONS array max before writing.
3. **Field naming follows batter-side convention.** Batter migration uses descriptive names (`hbp`, `doubles`, `triples`, `home_runs`) over API codes. Pitcher columns: `batters_faced, hits_allowed, runs_allowed, earned_runs, walks_issued, strikeouts_recorded, wild_pitches, hbp_allowed`. The `_allowed` / `_issued` / `_recorded` suffixes disambiguate per-pitcher counts from per-batter counts (a batter's `walks` vs a pitcher's `walks_issued`).
4. **WP/HBP extracted via `extract_extra` (existing parser helper).** Same pattern as `#P/TS/BF`. Default to 0 when sparse — both fields documented sparse in probe (12/15 and 9/15 games respectively).
5. **H/R/ER/BB/SO read directly from per-player `stats` hash.** No new helper needed — extend `build_ip_map` shape (rename to `build_pitcher_stats_map`) to return a hash-of-hashes keyed by `player_id`.
6. **All rate stats derived at query time, not stored.** ERA, WHIP, K/9, etc. are arithmetic on already-stored primary data. Storing derived values would duplicate truth.
7. **Nil on zero denominator, render as em-dash.** Matches existing `pct` (strike%) and `ip_share` (%IP) handling. `Sorting.apply` already handles nil values.
8. **ERA convention: ER × 9 / IP.** Standard baseball ERA, regardless of game length. Youth games are typically 6 innings, but ERA is a normalized rate; we don't adjust the multiplier for league. Confirmed in brainstorm open question.
9. **`--advanced` flag is a single boolean on `pitches`.** Not a multi-level verbosity scale. Adds BB/9 + BAA + P/IP to the table when set. Sort keys remain available regardless of flag (`--sort baa` works whether `--advanced` is set or not).
10. **`--pitcher` view: counts per outing, derived rates only in a cumulative footer.** Avoids the 9.00-ERA-from-1-IP problem the brainstorm flagged. The footer line uses the same SUM-then-divide math the season summary uses.
11. **Pitches command keeps the existing `IP` column.** The brainstorm flagged column-width pressure; we add 3 default columns (ERA/WHIP/K/9) and a `--advanced` flag rather than abbreviating existing headers. Eyeball widths during U3 and abbreviate (`Strike%` → `S%`) only if necessary.

## High-Level Technical Design

Data flow for new rate stats (directional guidance, not implementation specification):

```text
boxscore JSON
  ├── pitching.stats[]   ── IP, H, R, ER, BB, SO         ─┐
  └── pitching.extra[]   ── #P, TS, BF, WP, HBP entries  ─┴── BoxscoreParser
                                                              ├── (existing) pitcher_name, pitches_thrown, strikes_thrown, innings_pitched
                                                              └── (new)      batters_faced, hits_allowed, runs_allowed, earned_runs,
                                                                             walks_issued, strikeouts_recorded, wild_pitches, hbp_allowed
                                                                                │
                                                                                ▼
                                                                      game_pitcher_stats (+8 cols, mig v7)
                                                                                │
                                                                                ▼
                                                                      season_summary (+SUM(*) for each new col)
                                                                                │
                                                                                ▼
                                                                      Pitches#show_season:
                                                                        per-row rates:
                                                                          era  = er * 9.0 / ip
                                                                          whip = (h + bb) / ip
                                                                          k9   = so * 9.0 / ip
                                                                          baa  = h / (bf - bb - hbp)
                                                                          bb9  = bb * 9.0 / ip
                                                                          p_ip = pitches / ip
                                                                          p_bf = pitches / bf
                                                                        all nil on 0 denominator
                                                                                │
                                                                                ▼
                                                                      Formatters render default cols (ERA, WHIP, K/9)
                                                                      + advanced cols (BB/9, BAA, P/IP) when --advanced
```

Default column layout sketch (table formatter), for width budgeting:

```text
Pitcher   GP  Pitches  Strikes  Balls  S%  ERA   WHIP  K/9  %IP   Avg/Game  7-Day  Last Outing
```

`--advanced` adds: `BB/9  BAA   P/IP` between K/9 and %IP.

## Implementation Units

### U1. Extend BoxscoreParser for all 8 pitching fields

**Goal:** Emit `batters_faced, wild_pitches, hbp_allowed, hits_allowed, runs_allowed, earned_runs, walks_issued, strikeouts_recorded` from `pitcher_stats`.

**Requirements:** Brainstorm — parser extraction of the 8 fields.

**Dependencies:** none.

**Files:**
- `lib/gamechanger/boxscore_parser.rb` (modify)
- `spec/gamechanger/boxscore_parser_spec.rb` (modify)

**Approach:**
- Extend `extract_extra` usage in `pitcher_stats` to pull `BF`, `WP`, `HBP` lookups (in addition to existing `#P`, `TS`). Each yields a `player_id → value` map; default 0 when missing.
- Rename `build_ip_map` to `build_pitcher_stats_map` (or add a parallel helper) that returns `player_id → { ip, h, r, er, bb, so }` from `pitching.stats[].stats`. Use the same structure for all per-player stats keys at once rather than five separate map builds.
- Returned hash gains 8 new keys per pitcher. Existing keys (`pitcher_name`, `pitches_thrown`, `strikes_thrown`, `innings_pitched`) unchanged for backwards compatibility within the parse flow.

**Patterns to follow:**
- Existing `extract_extra` and `build_ip_map` helpers in `lib/gamechanger/boxscore_parser.rb`.
- `BatterStatsParser` HBP-from-`extra[]` join pattern (shipped in v5).

**Test scenarios:**
- Happy: three pitchers — one with all 8 stats present, one with WP=0 absent from `extra[]` (sparse), one with HBP=0 absent. All three parse to the right values; missing sparse fields default to 0.
- Happy: a pitcher with IP=4.333, H=4, R=2, ER=1, BB=2, SO=6, BF=18 — returned hash carries all values as integers (except IP as float).
- Edge: `pitching.extra[]` contains a WP entry for a `player_id` not in `pitching.stats[]` — entry is silently ignored (no spurious row).
- Edge: per-pitcher `stats` hash missing one of `H/R/ER/BB/SO` (older or partial payload) — defaults to 0 via `to_i`.
- Edge: zero-stat pitcher (e.g. relief appearance with IP=0) — all rate-input fields render as 0, no nil leakage.

**Verification:** `bundle exec rspec spec/gamechanger/boxscore_parser_spec.rb` passes. All 8 new keys present on the returned hashes for the standard fixture.

---

### U2. Migration v7 and storage upsert/query updates

**Goal:** Persist 8 new pitcher fields; surface totals from `season_summary` and per-outing values from `pitcher_games` / `game_by_date`.

**Requirements:** Brainstorm — migration v7 (single block, all 8 columns).

**Dependencies:** U1 (parser produces fields consumed by storage).

**Files:**
- `lib/gamechanger/storage.rb` (modify)
- `spec/gamechanger/storage_spec.rb` (modify)

**Approach:**
- Append `[7, <<~SQL]` block to `MIGRATIONS` with 8 `ALTER TABLE game_pitcher_stats ADD COLUMN ... INTEGER NOT NULL DEFAULT 0;` statements. Verify against current MIGRATIONS max (v6) before writing.
- Update `upsert_pitcher_stats` INSERT column list + parameter bind + `ON CONFLICT` update set to include all 8 new columns. Bind via `stat[:<field>].to_i` for each.
- Update `season_summary` SELECT to add `SUM(gps.<col>) AS total_<col>` for each new field (8 new SUMs). Match the column-naming convention already in the SELECT (`total_pitches`, `total_strikes`, `total_ip`).
- Update `pitcher_games` SELECT to add `gps.batters_faced, gps.hits_allowed, gps.runs_allowed, gps.earned_runs, gps.walks_issued, gps.strikeouts_recorded, gps.wild_pitches, gps.hbp_allowed` so per-outing rows have raw counts available.
- Update `game_by_date` SELECT similarly so the per-game pitcher rows carry the new fields.

**Patterns to follow:**
- Migration v6 block (`[6, <<~SQL]` with three `ALTER TABLE` statements) at `lib/gamechanger/storage.rb:81-85`.
- `upsert_batter_stats` (post-v6) for the multi-column-add upsert + `ON CONFLICT` shape at `lib/gamechanger/storage.rb:167-191`.
- Existing `season_summary` `SUM(...) AS total_*` pattern at `lib/gamechanger/storage.rb:590-608`.

**Test scenarios:**
- Happy: upsert a pitcher row with all 8 new fields, re-upsert with different values, confirm row reflects latest (idempotent).
- Happy: `season_summary` returns `total_earned_runs`, `total_hits_allowed`, etc. summed correctly across two games for one pitcher.
- Happy: migrating an existing v6 database to v7 leaves existing pitcher rows with 0 for all new columns (no data loss).
- Edge: upsert payload missing one of the new keys (e.g. WP absent) — `to_i(nil)` yields 0, row stores 0, no exception.
- Edge: `pitcher_games` for a pitcher with one outing of 4 IP returns the new columns populated on that row.

**Verification:** `bundle exec rspec spec/gamechanger/storage_spec.rb` passes. After migrations apply, `PRAGMA table_info(game_pitcher_stats)` includes all 8 new columns.

---

### U3. Pitches command: derive rate stats, register sort keys, add --advanced flag

**Goal:** Compute ERA/WHIP/K/9/BAA/BB/9/P-IP/P-BF per row and gate three behind `--advanced`. Register sort keys for all seven.

**Requirements:** Brainstorm — rate stats on `pitches` season summary; sortable.

**Dependencies:** U2 (`total_*` values available on summary rows).

**Files:**
- `lib/gamechanger/commands/pitches.rb` (modify)
- `spec/gamechanger/commands/pitches_spec.rb` (modify)

**Approach:**
- In `Pitches#show_season`, after fetching `rows` and before sort, derive rate stats per row:
  - Define a `derive_rates(row)` helper that computes the 7 rates inline, returning each as float or nil. Pattern: `row['era'] = ip.positive? ? er * 9.0 / ip : nil`, etc.
  - BAA denominator: `bf - bb - hbp`; nil if denominator ≤ 0.
- Extend `SEASON_SORT_KEYS` with 7 new lambdas: `era`, `whip`, `k9`, `bb9`, `baa`, `p_ip`, `p_bf`. Each reads the derived value from the row hash. Nil-safe via existing `Sorting.apply` nil-handling.
- Add `:advanced` boolean option to the command (Thor `class_option` or per-command `method_option`, mirroring the existing `:refresh`/`:sort`/`:desc` pattern in `Commands::Base` / `Commands::Pitches`).
- Pass `advanced: options[:advanced]` through to `formatter.season_summary(rows, advanced: ...)`.

**Patterns to follow:**
- Existing `ip_share` derivation in `Pitches#show_season` at `lib/gamechanger/commands/pitches.rb:48-56` — same shape, just more fields.
- Existing `SEASON_SORT_KEYS` lambdas for `pct` and `ip_share` (nil-on-zero-denominator) at `lib/gamechanger/commands/pitches.rb:32-46`.
- Thor option declaration for `:refresh` (or whatever existing flag is closest in shape) in `Commands::Pitches` / `Commands::Base`.

**Test scenarios:**
- Happy: a pitcher with IP=6.0, ER=2, H=5, BB=2, SO=8, BF=24, HBP=0, pitches=85 yields ERA=3.00, WHIP=1.17 (rounded for display), K/9=12.00, BAA=.227, BB/9=3.00, P/IP=14.17, P/BF=3.54.
- Happy: `--sort era` orders pitchers by ascending ERA (sort default direction stays whatever existing convention is); `--desc` reverses.
- Happy: `--sort k9 --desc` orders pitchers by descending K/9.
- Happy: `--advanced` shows BB/9, BAA, P/IP in formatter output; without `--advanced` they are absent from the rendered row.
- Edge: a pitcher with IP=0 (relief appearance with no outs recorded) — all rates render nil/em-dash, no division error.
- Edge: BAA denominator zero (BF == BB + HBP, all walks/HBP no AB) — BAA renders nil/em-dash.
- Edge: BF=0 — P/BF renders nil; P/IP still computes from IP if IP > 0.
- Edge: sort by a rate stat when all rows have nil values — sorts without error.
- Edge: `--sort baa` with `--advanced` unset still works (sort keys are not gated by display flag).

**Verification:** `bundle exec rspec spec/gamechanger/commands/pitches_spec.rb` passes. Manual: `gamechanger pitches --sort era` prints an ERA column with values ordered ascending; `gamechanger pitches --advanced` includes the three extra columns.

---

### U4. Per-outing view: raw counts + cumulative summary footer

**Goal:** Surface raw per-outing counts (ER, H, BB, SO, BF) on `gamechanger pitches --pitcher <name>` and append a cumulative rate-stat footer row.

**Requirements:** Brainstorm — per-outing surfacing; plan-time decision to defer per-outing rates and use a footer instead.

**Dependencies:** U2 (per-outing rows carry the new fields), U3 (rate derivation logic — reuse the same helper).

**Files:**
- `lib/gamechanger/commands/pitches.rb` (modify — `show_pitcher` path)
- `lib/gamechanger/formatters/table.rb` (modify — `pitcher_games` rendering)
- `lib/gamechanger/formatters/markdown.rb` (modify — `pitcher_games` rendering)
- `lib/gamechanger/formatters/json.rb` (modify — `pitcher_games` rendering)
- `spec/gamechanger/commands/pitches_spec.rb` (modify)
- `spec/gamechanger/formatters/table_spec.rb` (modify)
- `spec/gamechanger/formatters/markdown_spec.rb` (modify)
- `spec/gamechanger/formatters/json_spec.rb` (modify)

**Approach:**
- In `Pitches#show_pitcher`, compute cumulative totals across the returned outings (sum each of `pitches_thrown, strikes_thrown, innings_pitched, batters_faced, hits_allowed, runs_allowed, earned_runs, walks_issued, strikeouts_recorded, wild_pitches, hbp_allowed`). Derive cumulative ERA/WHIP/K/9/BAA from the sums using the same helper as U3.
- Pass `outings` (raw rows) and `totals` (cumulative + derived rates) to `formatter.pitcher_games(name, outings, totals)`.
- Table formatter: add ER/H/BB/SO/BF columns to per-outing rows; render a footer separator (mirroring existing table conventions) and a totals row with the derived rates.
- Markdown formatter: same, expressed as a footer row in the markdown table.
- JSON formatter: include `outings: [...]` and `totals: { ... }` as two top-level keys (or extend the existing return shape — verify whichever pattern is in use for batter per-outing JSON).

**Patterns to follow:**
- Existing `pitcher_games` formatter rendering in `lib/gamechanger/formatters/table.rb`, `markdown.rb`, `json.rb`.
- v5–v6 batter `--player` per-outing rendering for the multi-formatter wiring pattern.

**Test scenarios:**
- Happy: a pitcher with two outings — first 4 IP / 2 ER, second 3 IP / 1 ER — per-outing rows show raw counts; footer shows cumulative ERA = 3 × 9 / 7 ≈ 3.86.
- Happy: cumulative WHIP, K/9, BAA in the footer match the season-summary values for the same pitcher (cross-formatter consistency check).
- Edge: pitcher with one outing of IP=0 — per-outing row renders 0 counts; footer rates render em-dash (no division).
- Edge: pitcher with all outings BF=0 (shouldn't happen but defensive) — footer BAA renders em-dash.
- Markdown and JSON formatters render the same totals values as the table.

**Verification:** `bundle exec rspec spec/gamechanger/commands/pitches_spec.rb spec/gamechanger/formatters/` passes. Manual: `gamechanger pitches --pitcher <name>` shows per-outing counts plus a cumulative footer with the derived rates.

---

### U5. README and CHANGELOG updates

**Goal:** Document the new columns, sort keys, `--advanced` flag, and migration v7 for users.

**Requirements:** Brainstorm — docs/packaging.

**Dependencies:** U1–U4.

**Files:**
- `README.md` (modify — pitches usage section, sort-key table, flag documentation)
- `CHANGELOG.md` (modify — `[Unreleased]` section)

**Approach:**
- README: extend the `pitches` column list with definitions for ERA, WHIP, K/9, BAA, BB/9, P/IP, P/BF (with formulas in plain English). Document the `--advanced` flag. Add the 7 new sort keys to the documented sort-key table. Note in the column descriptions that per-outing view shows raw counts plus a cumulative footer, not per-outing rates.
- CHANGELOG: under `[Unreleased]` add bullets — new rate stats on `gamechanger pitches`, `--advanced` flag, raw per-outing counts + cumulative footer on `--pitcher` view, migration v7 (8 new pitching columns), and refresh recommendation to backfill historical games. Call out that existing cached games show 0 for the new columns until `gamechanger refresh`.

**Test scenarios:** none — pure documentation. `Test expectation: none -- documentation-only changes verified by review.`

**Verification:** README diff shows the new columns, `--advanced` flag, and sort keys. CHANGELOG `[Unreleased]` lists all rate stats with the refresh callout.

---

## System-Wide Impact

- **Schema change (migration v7):** existing users on v6 schema run a single additive multi-statement `ALTER TABLE`. SQLite handles transparently; existing pitcher rows get 0 for all 8 new columns.
- **User-visible data shift after `gamechanger refresh`:** pitcher rate stats become populated for historical games (currently 0/null in cache). CHANGELOG callout is the only mitigation; the underlying fix is correct.
- **No other commands affected.** `hitting`, `fielding`, `equity`, `brief`, `availability`, `lineup`, `plan`, `progress` are untouched. `pitch_rules.rb` (workload rules) is read-only and does not consume the new fields.
- **Cache-DB size growth:** 8 INTEGER columns × N pitcher rows. For a season of ~50 games × ~5 pitchers/game, this is ~250 rows × 8 × ~4 bytes ≈ 8 KB. Negligible.

## Risks

- **Migration number drift.** Brainstorm referenced "v6" before migration v6 (doubles/triples/home_runs) shipped earlier today. Plan uses v7 — implementer must verify against the actual `MIGRATIONS` array max before writing. Listed as decision #2.
- **Column-width pressure on the default table.** Adding ERA + WHIP + K/9 to a table that already has 10 columns. 80-col terminals will likely overflow. Mitigation: eyeball during U3 and abbreviate `Strike%` → `S%` or `Avg/Game` → `Avg` if necessary. `--advanced` gates the next 3 columns out of the default path.
- **Rate-stat sample-size noise.** A pitcher with 1 IP and 1 ER shows 9.00 ERA. Plan-time decision: rely on `Sorting.apply` nil-handling and don't add a synthetic min-IP threshold. If coaches report this is misleading in practice, follow-up work can add a `--min-ip N` filter.
- **BAA correctness.** BAA = H / (BF − BB − HBP) assumes BF, BB, HBP are accurate. Probe confirmed all three populate for completed games; sparse fields (HBP) default to 0 which is correct math (no HBP means none to subtract). Spec coverage includes the BF == BB + HBP edge case explicitly.
- **`--advanced` flag bleed.** Adding a per-command boolean option to `Commands::Pitches` must not conflict with `Commands::Base` shared options. Verify in U3.
- **Spec fixture growth.** Existing pitcher-stats spec fixtures don't carry the 8 new fields. U1 and U2 specs need fixture updates. Catch all sites in one pass per unit.

## Deferred to Implementation

- Exact column ordering in the default `pitches` table (ERA/WHIP/K9 inserted where? — recommend after `S%` and before `%IP`, but eyeball both).
- Whether the `--advanced` columns are inserted after K/9 (grouped with rates) or after `%IP` (grouped with other advanced metrics). Recommend the former.
- Whether `derive_rates(row)` lives as a private method on `Commands::Pitches` or extracts to a `Gamechanger::PitchingRates` module. Default to private method; extract only if a second caller appears (per Deferred YAGNI).
- Exact footer separator characters in the table formatter for the `--pitcher` cumulative row (depends on existing table conventions — match what's there).

## Verification

- All existing specs continue to pass.
- New parser specs cover the five U1 scenarios; storage specs cover the five U2 scenarios; command + formatter specs cover the nine U3 and five U4 scenarios.
- Manual end-to-end:
  - `bundle exec exe/gamechanger refresh` populates the 8 new columns for existing cache games.
  - `gamechanger pitches` shows ERA, WHIP, K/9 in the default table; values are non-zero for pitchers with completed outings.
  - `gamechanger pitches --advanced` adds BB/9, BAA, P/IP columns.
  - `gamechanger pitches --sort era` orders ascending by ERA; `--sort k9 --desc` orders descending by K/9.
  - `gamechanger pitches --pitcher <name>` shows per-outing raw counts (ER, H, BB, SO, BF) and a cumulative footer with derived rates.
  - `gamechanger pitches --format json` includes the new derived rate fields per row.
  - `gamechanger pitches --format markdown` renders the new columns in the markdown table.
  - `bundle exec rspec` reports all green.

## Origin

Brainstorm: `docs/brainstorms/2026-05-21-pitching-catch-up-extract-requirements.md`
Probe findings: `docs/research/gc-api-notes.md` § "Probe — pitching stat keys gap analysis (2026-05-21)"
Parallel pattern: `docs/plans/2026-05-21-001-feat-pa-and-team-ip-share-plan.md` (v5 batter-side extraction)
