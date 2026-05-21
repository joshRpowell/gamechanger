# Pitching catch-up extract — requirements

**Date:** 2026-05-21
**Status:** Brainstorm complete, ready for planning
**Scope:** Standard
**Related:**
- `docs/research/gc-api-notes.md` (probe findings, 2026-05-21 section)
- `docs/brainstorms/2026-05-20-pa-and-team-ip-share-requirements.md` (parallel batter-side pattern)
- `lib/gamechanger/boxscore_parser.rb`, `lib/gamechanger/storage.rb`, `lib/gamechanger/commands/pitches.rb`

## Problem

The boxscore endpoint already returns 8 pitching fields the gem ignores: `BF, WP, HBP, H, R, ER, BB, SO`. Today the `pitches` command can only show pitch counts, strikes, and innings — a workload view. It cannot show the rate stats coaches actually use to decide who to start (ERA, WHIP, K/9, BAA) or the workload-density signal that informs pitch-rest decisions (P/IP, P/BF).

The data is one parser change away. No new endpoints, no auth changes.

## Why now

The recent PA/HBP work on the batter side (v0.6.0 / v0.7.0) established the exact pattern: probe `extra[]`, add columns to the stats table via additive migration, parse on next sync, derive rates at query time. This brainstorm applies the same pattern to the pitching group, where the gap is larger (8 fields vs 3) and the unlocked value is higher (ERA/WHIP are the standard youth-coaching metrics, not derived curiosities).

## Goals

- Extract the 8 currently-visible pitching fields into `game_pitcher_stats`.
- Surface ERA, WHIP, K/9, BB/9, BAA, P/IP, P/BF on the `pitches` season summary and per-pitcher view.
- Keep the existing pitch-count / strike-% / IP-share columns untouched — this is additive.

## Non-goals

- First-pitch-strike %, pitch types, count-leverage, inherited runners — not available from `/boxscore`. Defer to a future pitch-by-pitch streaming probe.
- Defensive innings per pitcher — still the open Phase 0 watch-probe question.
- Opposing-team pitcher rate stats — web API gap (mobile-only).
- New command surface. Extend `pitches`, don't add a sibling.

## Success criteria

- `gamechanger pitches` season summary shows at minimum ERA, WHIP, K/9 alongside existing columns (sort keys for each).
- Per-pitcher view (`gamechanger pitches --pitcher <name>`) shows the same rate stats per outing.
- After `gamechanger refresh`, all historical games in the local cache have populated `hits_allowed`, `earned_runs`, `walks_issued`, `strikeouts_recorded`, `batters_faced` (and `wild_pitches`, `hbp_allowed` for games where they occurred).
- Existing tests stay green; new fields covered by spec fixtures.

## Open product questions (resolve in planning)

1. **Column density.** ERA + WHIP + K/9 is the minimum coaches expect. BB/9, K/BB, BAA, P/IP, P/BF round it out but add table width. Default to showing the minimum and gate the rest behind a `--advanced` flag, or show everything and let the user pipe to `less -S`?
2. **Sort key naming.** `era`, `whip`, `k9`, `bb9`, `baa` — confirm naming aligns with existing `SEASON_SORT_KEYS` style (lowercase, no slashes/punctuation).
3. **ERA scale.** Youth baseball games are typically 6 innings, not 9. ERA convention is still ER × 9 / IP regardless of game length — confirm we follow convention, not adjust for league.
4. **Minimum-IP filter for rate stats.** A pitcher with 1 IP and 1 ER has a 9.00 ERA that misleads the season ranking. Apply a min-IP threshold for sort/display, or show all and let the reader interpret?

## Storage shape (sketch — finalize in planning)

Migration v6 — additive, mirrors v5:

```
ALTER TABLE game_pitcher_stats ADD COLUMN batters_faced       INTEGER NOT NULL DEFAULT 0;
ALTER TABLE game_pitcher_stats ADD COLUMN hits_allowed        INTEGER NOT NULL DEFAULT 0;
ALTER TABLE game_pitcher_stats ADD COLUMN runs_allowed        INTEGER NOT NULL DEFAULT 0;
ALTER TABLE game_pitcher_stats ADD COLUMN earned_runs         INTEGER NOT NULL DEFAULT 0;
ALTER TABLE game_pitcher_stats ADD COLUMN walks_issued        INTEGER NOT NULL DEFAULT 0;
ALTER TABLE game_pitcher_stats ADD COLUMN strikeouts_recorded INTEGER NOT NULL DEFAULT 0;
ALTER TABLE game_pitcher_stats ADD COLUMN wild_pitches        INTEGER NOT NULL DEFAULT 0;
ALTER TABLE game_pitcher_stats ADD COLUMN hbp_allowed         INTEGER NOT NULL DEFAULT 0;
```

All rate stats are derived at query time in `season_summary` / `pitcher_games`, following the `ip_share` precedent in `Commands::Pitches#show_season`.

## Parser changes

`BoxscoreParser#pitcher_stats` already extracts `#P/TS` via `extract_extra` and `IP` via `build_ip_map`. Add:

- `BF/WP/HBP` via the same `extract_extra` pattern (default to 0 when sparse).
- `H/R/ER/BB/SO` via the same `build_ip_map`-style helper extended to surface multiple stat keys per row.

## Risks / unknowns

- **WP/HBP sparsity.** Some games have no `WP` entry in `extra[]`. Parser must default to 0, not nil, to keep the storage NOT NULL constraints clean.
- **Backfill cost.** Forcing a refresh re-fetches every cached boxscore. 0.5s rate limit × N games — acceptable for a season but worth a one-line shell.say warning.
- **Display width.** Adding 5+ columns to an already-wide season table may force horizontal scrolling. Plan should produce a mock before implementation.

## Out of scope (deferred)

- Pitch-by-pitch streaming endpoint probe (separate brainstorm).
- Defensive innings per pitcher (Phase 0 watch-probe still owns this).
- Cross-pitcher comparisons / league-relative rankings.
- Opposing-team pitcher data.
