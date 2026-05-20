# Fielding Positions: Parser + Storage + Hitting Column — Requirements

**Date:** 2026-05-20
**Scope:** Standard
**Parent docs:**
- Ideation: `docs/ideation/2026-05-20-fielding-positions-data-acquisition.md`
- Discovery probe: `docs/brainstorms/2026-05-20-boxscore-fielding-groups-probe-requirements.md`
- Probe finding: `docs/research/gc-api-notes.md#boxscore-additional-groups-probe-2026-05-20` (disposition (b))

## Problem

The probe on 2026-05-20 confirmed fielding-position data is already present in every boxscore response we consume, encoded as ordered comma-separated position codes in `lineup.stats[].player_text` (e.g., `(SS, P)`, `(1B, 2B, 1B, P)`). The current `BoxscoreParser` reads every other field on lineup rows and discards this one. No new endpoint, no auth surface, no ToS risk — the data is already in our cache.

Without surfacing positions, the `hitting` command shows a coach who hit, but not what defensive role they played. For coaches managing rotation, equity, and fielding fatigue at the youth level (the gem's audience per `STRATEGY.md`), this is a significant missing dimension.

## Goal

Surface per-game fielding-position data, end-to-end, in one PR:

1. Parser extracts `player_text` from lineup rows for the configured team.
2. New storage table persists each position stint as a row, preserving order.
3. `hitting` command output adds a `Pos` column showing the player's most-recent game's position string.

## Non-goals

- **Opponent positions.** Captured by the same response but out of scope here. The schema supports opponent rows when added later; nothing about own-team-only forecloses that.
- **Cross-link with the Go-side `opposing_roster.position` column.** Deferred to a separate brainstorm; needs Ruby↔Go schema coordination check.
- **Per-inning timing.** Source data is per-stint, not per-inning. No inference attempted.
- **Live/in-progress game updates.** This brainstorm covers completed games only. Live-state behavior of `player_text` is still an open question for the Phase 0 watch probe (`.claude/reminders/phase-0-watch-probe.md`).
- **New commands.** No `positions` command in this PR. No `brief` fielding section. The hitting-column unlock is intentionally minimal to validate end-to-end without designing new surfaces.
- **Position-based equity / fatigue / rotation analytics.** Follow-up brainstorms, gated on this data landing.

## Success criteria

1. After `gamechanger refresh`, the SQLite cache has rows in a `game_fielding_positions` table for every completed game where own-team `player_text` is non-empty.
2. `gamechanger hitting` shows a new `Pos` column. For each player in the output, the column value is the position string from that player's most-recent completed game in the window (e.g., `SS, P` or `2B`). Empty when the player did not take the field in their most recent appearance.
3. Existing `hitting` tests still pass; new tests cover: per-stint parsing (single position, multi-position, empty `player_text`), most-recent-game aggregation, and migration round-trip.
4. The v4 migration is **additive only** — no changes to v1–v3 tables. The Go port's schema awareness can land later without a coordinated release.
5. No real player names, UUIDs, or opponent identifiers in any committed file. Test fixtures follow existing sanitization conventions.

## Design decisions (resolved)

| Decision | Choice | Rationale |
|---|---|---|
| Storage shape | Per-stint ordered list, one row per stint | Lossless; primary-position is derivable as `stint_index = 0`. Multi-position players are first-class. |
| Schema location | New v4 table `game_fielding_positions` | Additive; doesn't touch frozen v1–v3 tables. |
| Team scope | Own team only (current `team_slug`) | Matches existing parser convention. Opponent backfill is its own coordinated brainstorm. |
| First user surface | `Pos` column in `hitting` output | Smallest surface area that validates the data end-to-end. |
| Aggregation rule | Most-recent completed game in the window | Matches the "what did they play last" mental model coaches use. Simple, recency-biased, no tally needed. |

## Schema (v4)

```
game_fielding_positions
  game_id      TEXT NOT NULL
  player_id    TEXT NOT NULL
  stint_index  INTEGER NOT NULL  -- 0-based; preserves player_text order
  position     TEXT NOT NULL     -- one of: P,C,1B,2B,3B,SS,LF,CF,RF,DH,EH
  fetched_at   TEXT NOT NULL
  PRIMARY KEY (game_id, player_id, stint_index)
  -- no FK to games (matches existing convention in storage.rb)
```

Position codes recognized initially: `P, C, 1B, 2B, 3B, SS, LF, CF, RF, DH, EH`. Anything else in `player_text` (future expansion, unexpected codes) is logged and skipped — not stored, not crashed.

## Parser behavior

In `BoxscoreParser`, when iterating the `lineup` group's `stats[]`:

1. Read `player_text` alongside the existing batter stats.
2. Strip parens, split on `,`, trim whitespace → ordered list of codes.
3. Filter to known codes (above); log + skip unknowns.
4. Empty string or all-unknowns → no rows (the player didn't field).
5. Caller (syncer) writes one row per code, with `stint_index` matching list position.

## Hitting column behavior

In the hitting formatter (table/markdown/json):

1. For each player row, look up their position string from the most-recent completed game in the window via a join on `game_fielding_positions` ordered by `games.game_date DESC`.
2. Reconstruct the position string by ordering rows by `stint_index` ASC and joining with `, `.
3. Render as `Pos` column. Empty cell when no rows for that player in the window.
4. JSON formatter: emit `positions: ["SS","P"]` as an array (not a joined string) for consumer flexibility.

## Open questions

- **Position-code completeness.** The probe surfaced 9 codes from one game. `DH` and `EH` are plausible at higher age levels but unseen in the probe sample. The "log + skip unknowns" rule above is the safety net; planning may decide to land the full list of expected codes up-front via a sanity test.
- **Sort interaction.** Existing `--sort` flag on `hitting` doesn't know about `Pos`. Decision: `--sort pos` is **not** supported in this PR; the column is display-only. Add to follow-up if requested.

## Dependencies / assumptions

- Assumes `player_text` is **always** the source of truth for own-team positions in completed games. (Verified for one game in the probe; reasonable confidence but not exhaustive.)
- Assumes the `team_slug` filter in existing parsers correctly identifies own-team data. (Existing convention; no new risk introduced here.)
- Assumes coaches using `hitting` want positional context inline rather than in a separate command. (Product judgment; revisitable if feedback says otherwise.)

## Risks

- **Stale position data after a re-sync.** If a game is re-fetched and `player_text` has changed (e.g., GC corrected a position post-hoc), we'd have both old and new stint rows. Mitigation: the syncer should `DELETE FROM game_fielding_positions WHERE game_id = ?` before re-inserting for that game. Standard upsert pattern, already used elsewhere in `storage.rb`.
- **Aggregation off-by-one with same-day games.** A double-header on the same date: "most recent" needs a tiebreaker. Default to `fetched_at DESC` after `game_date DESC` — same convention the rest of the gem uses.

## Out of scope, deferred for later

- Opponent position capture and the Ruby↔Go scout cross-link.
- `positions` command, fielding section in `brief`, position-based equity/fatigue reports.
- Per-inning timing (requires either the live `player_text` behavior or play-by-play, neither in scope here).
- `--sort pos` on `hitting`.
- Backfill of historical games where `player_text` may not have been captured into the existing `game_batter_stats` row. (Re-running `refresh` is the workaround; durable fix is a separate decision.)

## Handoff

- `/ce-plan` for the implementation plan (recommended — Standard scope warrants formal planning).
- Execute directly without a plan if the scope feels tight enough.
- Park here and pick up later.
