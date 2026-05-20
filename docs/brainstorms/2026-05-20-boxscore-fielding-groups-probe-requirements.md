# Boxscore Fielding-Groups Probe — Requirements

**Date:** 2026-05-20
**Scope:** Lightweight (discovery only)
**Parent ideation:** `docs/ideation/2026-05-20-fielding-positions-data-acquisition.md` (idea 1)

## Problem

`BoxscoreParser` filters `groups[]` to `category` ∈ {`pitching`, `lineup`} and silently drops anything else (`lib/gamechanger/boxscore_parser.rb`). GameChanger's own help docs confirm they track "defensive innings by position, per game and per season." It is plausible — but unverified — that a `fielding` (or similarly-named) group is already present in the boxscore response we currently consume, and we just aren't looking at it.

## Goal

Answer one question, document the answer, stop:

> Does `/game-stream-processing/{game_id}/boxscore` return any `groups[]` entries beyond `pitching` and `lineup`?

## Non-goals

- No `BoxscoreParser` changes.
- No new storage migrations.
- No new formatter output.
- No live-game probe (the existing Phase 0 watch-probe TODO covers the live-state question — this brainstorm is about a completed game, which we can probe today).
- No mobile-app capture, no OCR work, no `include=` variants on `/public/.../details` (those are separate ideation entries).

## Success criteria

1. A new section `## Boxscore additional groups (probe 2026-05-20)` exists in `docs/research/gc-api-notes.md` and contains:
   - The list of every `category` value seen in `groups[]` for the probed game.
   - For each non-`pitching`/`lineup` category: the keys present in `stats[]` and `extra[]` (or equivalents), with one sanitized example row.
   - A disposition tag at the end: **(a)** fielding/position data is present in the boxscore as-is, **(b)** present but in a different shape than expected (e.g., embedded in `lineup` rows we currently ignore), or **(c)** not present at all.
2. The probe ran against a real completed game from the configured team's cached schedule (no live game needed).
3. No real player names, opponent names, or UUIDs land in committed files. Sanitization follows the existing convention in `gc-api-notes.md` (initials or `Player A` / `Opp UUID`).
4. The disposition determines the next move and is recorded in the doc so a follow-up brainstorm can route off it.

## Approach

One throwaway probe script under `cmd/` (mirroring the `cmd/scout-probe` precedent called out in `docs/plans/2026-05-15-001-feat-scouting-tool-phase-1-plan.md`):

- Reads `GC_PROBE_GAME_UUID` from env.
- Reuses the existing authenticated client to call the boxscore endpoint.
- Pretty-prints the response to `testdata/har/boxscore-{game-uuid}.json` (gitignored).
- Writes a sanitized excerpt + group inventory to the PR author's working copy of `docs/research/gc-api-notes.md`.
- Deleted in the same PR that lands the doc update.

## Decision routes (post-probe)

- **Disposition (a) — fielding group present as-is:** open a follow-up brainstorm for `BoxscoreParser` extension + v4 migration + first formatter unlock. This is the happy path.
- **Disposition (b) — present in unexpected shape:** open a follow-up brainstorm sized to the actual shape; may be larger if it requires play-by-play traversal.
- **Disposition (c) — not present:** mark idea 1 dead in the parent ideation, escalate to idea 2 (`include=` variants on `/public/.../details`).

## Open questions

None blocking. The "which game to probe" choice is operational — pick the most recent completed game from `~/.gamechanger/cache.db` whose boxscore has been fetched at least once.

## Dependencies / assumptions

- Assumes the boxscore response we currently receive is the *full* response — that GC isn't filtering server-side based on something like `gc-app-name` header. If a different header value yields a different response shape, that is itself a finding and gets recorded under disposition (b).
- Assumes the existing auth flow (session token in `~/.gamechanger/session`) is valid at probe time.

## Out of scope, deferred for later

- Anything from ideas 2–8 in the parent ideation doc — `include=` variants, OCR fallback, mobile mitm, XML import, storage shape, rotation/equity unlocks, scout cross-link. Each is its own brainstorm gated on this probe's disposition.

## Handoff

Next steps (pick one):

- **Execute now** — write the probe script and run it against a recent completed game.
- **Defer to next live-game window** — bundle this probe with the Phase 0 watch-probe (`.claude/reminders/phase-0-watch-probe.md`) so both run in one session.
- **`/ce-plan`** — formal plan for the probe (overkill for Lightweight scope but available).
