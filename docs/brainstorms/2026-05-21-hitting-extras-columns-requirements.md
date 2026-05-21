# Hitting table: 1B / 2B / 3B / HR columns

**Date:** 2026-05-21
**Status:** Requirements — ready for planning
**Related:** [`2026-05-20-pa-and-team-ip-share-requirements.md`](2026-05-20-pa-and-team-ip-share-requirements.md) (immediate predecessor; same parser-extension + storage-migration pattern), [`../research/gc-api-notes.md`](../research/gc-api-notes.md) (probe confirming `2B/3B/HR` live in `lineup.extra[]`).

## Problem

The `gamechanger hitting` season table reports total hits (H) but does not break hits down by type. Coaches reading the table cannot see at a glance who is producing extra-base power versus singles, and have no way to surface doubles, triples, or home runs without checking GameChanger directly.

## Goal

Add singles, doubles, triples, and home runs as columns on the season hitting table so the hit-type breakdown sits next to the existing AB/H totals.

## User-facing behavior

### Hitting table — new columns

The `gamechanger hitting` table gets four new columns placed between `H` and `BB`:

```
Batter | G | PA | AB | H | 1B | 2B | 3B | HR | BB | K | AVG | OBP | Trend | Pos
```

- `1B`, `2B`, `3B`, `HR` are integer counts, season totals.
- Rendered as plain integers (no zero suppression). A player with no extra-base hits shows `0` in `2B`, `3B`, `HR`.
- `1B` is a derived value: `H − 2B − 3B − HR`. If the arithmetic ever yields a negative number (it should not — would indicate stat-key drift or data corruption), display `0` and continue rendering the row. Do not raise.

### Sort flag

No new `--sort` keys in this iteration. Existing keys (`name`, `g`, `pa`, `ab`, `h`, `bb`, `k`, `avg`, `obp`) continue to work unchanged. Defer adding `1b`/`2b`/`3b`/`hr` sort keys until a user asks.

### Per-batter game view

`gamechanger hitting --player NAME` is **out of scope**. Per-game rows already feel wide; adding four more columns there is deferred until there's a clear ask.

### Refresh

Historical games already in the local cache do not have 2B/3B/HR populated. Users need to run `gamechanger refresh` after upgrading to backfill those values. Document this in the CHANGELOG entry. Same UX as the recent PA/HBP rollout.

## Data sourcing

Confirmed available from the boxscore endpoint per the 2026-05-21 probe (see `docs/research/gc-api-notes.md` §"Probe — batter stat keys for PA computation"):

| Column | Source | Shape |
|---|---|---|
| `2B` | `lineup.extra[]` where `stat_name == "2B"` | Join by `player_id`, mirrors HBP |
| `3B` | `lineup.extra[]` where `stat_name == "3B"` | Same |
| `HR` | `lineup.extra[]` where `stat_name == "HR"` | Same |
| `1B` | Derived: `H − 2B − 3B − HR` at query/render time | Not stored |

`TB` is also present in `lineup.extra[]` but is **explicitly not consumed** in this iteration (see Out of scope).

## Storage

Migration **v6** of the local SQLite cache adds three columns to `game_batter_stats`:

- `doubles INTEGER NOT NULL DEFAULT 0`
- `triples INTEGER NOT NULL DEFAULT 0`
- `home_runs INTEGER NOT NULL DEFAULT 0`

No `singles` column — `1B` is computed at the season-summary SQL or in the formatter. Choose at planning time based on whichever keeps `season_batting_summary` simpler.

## Parser changes

`BatterStatsParser#batter_stats` extends its per-row hash with three integer keys (`doubles`, `triples`, `home_runs`), populated by the same `extra_stat_by_player_id` helper already used for HBP. Update the YARD comment that enumerates the return-hash keys.

## Success criteria

- `gamechanger hitting` renders the four new columns in the documented order with correct values across the sample of completed games in the local cache.
- A player with `H=5, 2B=1, 3B=0, HR=1` displays `1B=3, 2B=1, 3B=0, HR=1`.
- A player with no extras displays `0` in 2B/3B/HR and `H` in 1B.
- Migration v6 is idempotent: running it twice in a row does not error.
- `gamechanger refresh` populates the new columns for all cached games.
- Existing tests for the hitting table continue to pass (after fixture updates for the new headers).
- New regression test covers the `H − 2B − 3B − HR` derivation including the negative-arithmetic guard.

## Out of scope

- **SLG and TB.** The data is available in `lineup.extra[]` but completing the AVG/OBP/SLG slash line is a separate decision — defer until requested.
- **Per-game `--player` breakdown.** Row width is already a concern; add later if asked.
- **Sort keys for 1B/2B/3B/HR.** Defer until a user wants them.
- **Markdown and JSON formatters.** Mirror the table-formatter changes if the existing pattern already covers them; do not invent new fields. If they need significant new work, split into a follow-up.

## Open questions

None blocking. Two minor decisions for planning:

1. Compute `1B` in the SQL summary (`SELECT ... SUM(hits) - SUM(doubles) - SUM(triples) - SUM(home_runs) AS singles`) versus in the formatter. Prefer whichever keeps the surrounding code simpler.
2. Whether to also update the `markdown` and `json` formatters in the same PR or split. Default: same PR if trivial, follow-up if not.

## Non-functional notes

- This is a public repo. No real team UUIDs, player names, or opponent names land in committed code or test fixtures.
- Test pattern: extend the existing `BatterStatsParser` spec with `extra[]` entries for `2B`/`3B`/`HR` mirroring the HBP fixture. Storage spec gets a migration-v6 test mirroring v5. Table-formatter spec updates its expected header row and adds one row that exercises the derivation.
