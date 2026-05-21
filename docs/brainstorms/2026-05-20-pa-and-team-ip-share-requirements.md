# Plate Appearances on Hitting + Team-IP-Share on Pitches

**Date:** 2026-05-20
**Status:** Requirements — ready for planning
**Scope:** Lightweight (two additive columns; one parser extension; one migration)

## Problem

Two gaps in the current report output:

1. **`gamechanger hitting`** shows AB/H/BB/K but not **plate appearances** (PA). Coaches reading the table can't see how many times a hitter actually came up — at-bats alone undercount because walks (and HBP/sacrifices when present) aren't included. PA is the right denominator for hitter rate stats and for judging usage.
2. **`gamechanger pitches`** shows per-pitcher IP and pitch counts but no view of **how much of the team's defensive workload each pitcher carried**. A 12 IP pitcher on a team that threw 60 innings is doing very different work than a 12 IP pitcher on a team that threw 24.

## Users and value

- Single-user, coach-facing CLI. Same audience as existing `hitting` and `pitches` reports.
- Value: at-a-glance read of true offensive opportunity (PA) and pitching load distribution (`%IP`).

## Requirements

### `hitting` report — add `PA` column

- **Definition (confirmed via 2026-05-21 probe, see `docs/research/gc-api-notes.md`):** `PA = AB + BB + HBP`. Sacrifice flies/bunts are NOT exposed by the boxscore endpoint — `SF`/`SH`/`SAC` never appear under any name across 15 sampled games. Document this as a known undercount (a hitter with a sac fly will be undercounted by 1 PA).
- **Source:** AB/BB from per-player `lineup.stats[]` hash; HBP from `lineup.extra[]` where `stat_name == "HBP"`, joined by `player_id` to the lineup row. Parser: `lib/gamechanger/batter_stats_parser.rb`. The HBP-via-extra pattern already exists in `BoxscoreParser` for `#P`/`TS`/`BF` on the pitching group — reuse the same shape.
- **Display:** new `PA` column, table/JSON/markdown formatters. Position adjacent to `AB`.
- **Sortable** via the existing `--sort` flag (see `lib/gamechanger/sorting.rb`).
- **Fallback:** if a particular boxscore omits HBP from `extra[]` (no batters hit that game), HBP defaults to 0 and PA = AB + BB. Never errors.

### Pre-existing bug to fix in the same PR

The probe surfaced that `batter_stats_parser.rb:43` reads `stats['K']` but the real boxscore key is `'SO'`. Result: `game_batter_stats.strikeouts` is 0 across all 306 cached rows — strikeouts have never been populated. Fix this one-line bug at the same time as the PA work (the parser is being touched anyway), and recommend `gamechanger refresh` in the CHANGELOG to repopulate.

### `pitches` report — add `%IP` column

- **Definition:** `pitcher_ip / team_defensive_ip` across the report window, where `team_defensive_ip` per game = `SUM(innings_pitched)` over all of the team's pitchers in that game, summed across the games in the window.
- **Display:** one decimal with `%` suffix (e.g., `42.3%`).
- **Sortable** via the existing `--sort` flag.
- **Source:** derived at query time from `game_pitcher_stats.innings_pitched` already in storage. No new field strictly required for the team-total denominator.

### Storage / schema

- **Migration v5** on `game_batter_stats`: add `hbp INTEGER NOT NULL DEFAULT 0`. No `sac` column — sacrifices unavailable from the API. Existing rows default to 0; user `refresh` repopulates from re-fetched boxscores.
- No schema change required for `%IP` (computed in SQL or Ruby from existing `innings_pitched`).
- PA itself is NOT stored — derived at query time as `at_bats + walks + hbp`.

### Docs / packaging

- Update README usage section for both reports (column meaning + sort key).
- CHANGELOG entry under `[Unreleased]` describing PA column, `%IP` column, and migration v5.
- Version bump deferred to release time (likely 0.6.0).

## Scope boundaries

**In:**
- Parser extension to read HBP/SF/SH keys with graceful absence handling.
- Migration v5 + storage upsert changes for hbp and sac.
- Formatter columns for `PA` (hitting) and `%IP` (pitches), table/JSON/markdown.
- Sort support for the new columns.
- Regression tests covering: PA computation with all four components present, PA fallback when HBP/SAC missing, `%IP` math across single-game and multi-game windows, `%IP` when team total IP is zero (avoid div-by-zero — render `—` or `0.0%`).
- README + CHANGELOG updates.

**Deferred:**
- OBP / SLG / OPS. PA unlocks these but they're separate features.
- Backfilling historical games — users re-run `refresh` to repopulate.
- Per-game breakdown of `%IP` (e.g., game-by-game share). Report-window aggregate only.

**Outside this product's identity:**
- Pitching workload pacing alerts / pitch-count rules already live in `pitch_rules.rb` — `%IP` is a stat column, not a workload-management feature.

## Assumptions (status after 2026-05-21 probe)

1. ~~**Boxscore emits the stat keys we need.**~~ **Resolved.** Per-player `lineup.stats[]` hash exposes `AB, BB, H, R, RBI, SO` only. HBP lives in `lineup.extra[]` as a separate stat-name entry with per-player values. SF/SH/SAC are not exposed by this endpoint. See `docs/research/gc-api-notes.md` § "Probe — batter stat keys for PA computation (2026-05-21)".
2. ~~**`innings_pitched` uses baseball `2.1` notation.**~~ **Resolved.** Verified against cache: `innings_pitched` is stored as a true decimal (`3.333...` for 3⅓, `0.666...` for ⅔). `%IP` math is plain float arithmetic — no thirds-conversion helper needed. Display still rounds to a sensible precision in the formatter.
3. **No retroactive recompute needed** — `refresh` re-parses cached boxscores and re-upserts. Users on existing 0.5.0 caches see PA, HBP, and (fixed) strikeouts populate after their next refresh.

## Success criteria

- `gamechanger hitting` shows a `PA` column with values matching `AB + BB + HBP + SAC` for at least one verified game where all four components have nonzero values.
- `gamechanger hitting --sort pa --desc` sorts correctly.
- `gamechanger pitches` shows a `%IP` column. For a known game/window, the values sum to ~100% across the team's pitchers (rounding tolerance ±0.1% × pitcher_count).
- `gamechanger pitches --sort ip_share --desc` (or whatever the sort key resolves to) sorts correctly.
- All existing tests still pass; new specs cover PA fallback, `%IP` math, and zero-denominator handling.
- Migration v5 applies cleanly on a 0.5.0 schema without data loss.

## Risks

- **Column-width pressure on `pitches` table.** Already has IP, pitches, strikes, batters faced. Adding `%IP` at one decimal is ~5 chars + header. Should fit but worth eyeballing on an 80-col terminal during implementation.
- **HBP join correctness.** HBP entries live in a parallel array keyed by `player_id`, not inside the per-player stats hash. The parser needs to build the lookup once per parse and join, not iterate `extra[]` per batter. Spec coverage for: HBP present, HBP absent (no batters hit), HBP for an unknown player_id (skip).
- **Strikeouts fix changes existing user output.** Coaches who've been looking at K=0 forever will suddenly see real strikeout values after upgrading + refreshing. Worth a CHANGELOG callout: "Strikeouts column now populated correctly; existing cache shows 0 until `gamechanger refresh`."

## Next step

Hand to `/ce-plan` (or `/gsd-plan-phase`) for task breakdown. The Phase 0 boxscore-keys probe should be the first task before any parser/migration code is written.
