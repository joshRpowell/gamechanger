# Fielding Pivot Command — Requirements

**Date:** 2026-05-20
**Status:** Brainstorm complete, ready for `/ce-plan`
**Scope tier:** Standard

## Problem

We now store fielding-position stints per player per game (v0.4.0 added the `game_fielding_positions` table). Today this data only surfaces as a "Pos" column in `gamechanger hitting`, showing each player's most-recent positions. There is no way to see season-wide position usage — e.g., "who plays SS, and how often?" — without writing SQL.

## Goal

A new subcommand that renders a player-by-position pivot table aggregated across all stored games, so a coach can see at a glance who plays where and how concentrated each player is at a given position.

## User-facing behavior

### Command surface

```
gamechanger fielding [--format table|markdown|json] [--sort COL] [--desc]
```

- Standalone subcommand. **Not** layered onto `hitting`.
- Reuses the existing formatter / sorting plumbing established for `hitting`, `pitches`, `equity`.

### Output shape (table format)

```
#    Player          P   C   1B  2B  3B  SS  LF  CF  RF  Total
1    Bob Jones       2   .   .   .   .   5   .   .   .   7
3    Alice Smith     .   1   .   3   .   .   .   .   .   4
12   Charlie Brown   .   .   4   .   .   .   .   2   .   6
```

- **Rows:** every player who has at least one stored stint across the season.
- **Columns:** `#` (jersey number), `Player` (full name), then one column per fielding position that has at least one stint anywhere in the data set, then a `Total` column.
- **Cells:** integer stint counts. Empty cells render as `.` (baseball convention).
- **Position column order:** fixed canonical order — `P, C, 1B, 2B, 3B, SS, LF, CF, RF, DH, EH` — with absent positions skipped.
- **Default sort:** `Total` descending, jersey number ascending as tiebreaker.

### Cell metric: stint count

A "stint" is one entry in the boxscore `player_text` field. `(SS, P)` for a game contributes one SS stint + one P stint to that player. **We do not estimate or report innings** — the boxscore does not carry inning numbers per stint, and fabricating them would mislead.

### Format variants

- `--format markdown` — same shape, markdown table.
- `--format json` — array of objects: `{ jersey, player_name, positions: { P: 2, SS: 5, ... }, total: 7 }`. Empty positions are omitted from the per-row `positions` hash.

### Sort

`--sort COL` accepts: `jersey`, `player`, `total`, or any position code present in the table (e.g. `--sort SS`). `--desc` reverses. Defaults: `--sort total --desc`.

## Scope boundaries

### In scope

- New `fielding` subcommand with table / markdown / json output.
- Storage query that aggregates stint counts by player and position across all stored games.
- Sorting parity with existing report commands.

### Deferred for later

- **Per-inning counts.** Requires confirming whether the live boxscore endpoint exposes inning data — tracked by the existing `.claude/reminders/phase-0-watch-probe.md` reminder. If/when inning data is confirmed, the cell metric can be upgraded; the table shape stays the same.
- **Per-game breakdown.** A `gamechanger fielding --game GAME_ID` view is a plausible follow-up but not v1.
- **`--last N` window flag.** v1 is season-aggregate. Adding a window flag is mechanical; defer until asked.
- **Game-count metric alternative.** Decided against — stint count is more informative and equally honest to the data.
- **Defensive performance stats** (errors, assists, putouts). Not in our data and not in scope.

### Outside this product's identity

- Not a defensive analytics product. We surface what the boxscore already gives us; we do not invent metrics.

## Success criteria

- `gamechanger fielding` prints a pivot table whose row count equals the number of distinct players with at least one stint in storage.
- Each row's `Total` equals the sum of its position cells, and equals `SELECT COUNT(*) FROM game_fielding_positions WHERE player_name = ?` for that player.
- Position columns appear in canonical order; absent positions are omitted.
- `--format json` round-trips through `jq` cleanly.
- `--sort` works across `jersey`, `player`, `total`, and any position code; `--desc` reverses.
- Empty data set (fresh cache, no fielding stints yet) prints a friendly "no fielding data — run `gamechanger refresh`" message, not a crash or empty table.

## Open questions

- **Jersey number resolution at aggregation time.** `game_fielding_positions` stores `player_name` but not `jersey`. Jersey lives on `game_batter_stats` / `players` data. Planning will need to decide the join — likely most-recent jersey by player name from `game_batter_stats`, consistent with how `hitting` resolves it. Confirm during planning, not now.

## Dependencies / assumptions

- Assumes `game_fielding_positions` continues to use `player_name` as its identity key (current behavior — denormalized when v4 migration landed).
- Assumes per-player stint counts across the season are a coach-meaningful signal even without inning weight. If a coach is using this view and finds the stint count misleading because stint durations vary widely game to game, that's the trigger to revisit the live-game probe and upgrade to inning counts.

## Handoff

Ready for `/ce-plan`. Suggested plan scope: parser/storage already in place; this is a new reader command + formatter columns + tests.
