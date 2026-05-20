# Acquiring Fielding Positions Data — Ideation

**Date:** 2026-05-20
**Focus:** "see if we can get positions data"
**Mode:** repo-grounded ideation (gamechanger Ruby gem)

## TL;DR

We currently parse only `pitching` and `lineup` groups from `/game-stream-processing/{id}/boxscore`. **GameChanger's own help docs confirm they track "defensive innings by position, per game and per season"** — meaning the data exists server-side. Three plausible paths to acquire it, ranked by cost: (1) probe boxscore for an unrequested `groups[]` entry, (2) probe the `include=` query parameter on the public details endpoint, (3) OCR the in-app box score screenshot (the `parse_textArray` function in `eeg3/gc-stat-aggregator` already proves position tokens like `(P)`, `(SS)` appear inline next to player names — that project strips them; we'd keep them).

## Grounding Context

**Codebase:** `BoxscoreParser` iterates `groups[]` and filters by `category` ∈ {`pitching`, `lineup`}. Storage is additive, frozen at v3 for Ruby↔Go interop. Phase 0 watch probe already calls out `defensive_innings` per pitcher as an open API question (`.claude/reminders/phase-0-watch-probe.md`). Scout Phase 1a already reserves a dormant `position` column on `opposing_roster` (Go side).

**External:** No public GameChanger API. `eeg3/gc-stat-aggregator` (2025) OCRs GC screenshots and explicitly *strips* position tokens — reversing that yields `{player, position}`. GameChanger's own pipeline is Kafka-based and event-driven (per tech.gc.com); the iOS scorekeeper app posts position assignments in real time.

**Past learnings (`gc-scout-api-notes.md`):** When scout-tool hit a similar API wall, the team adopted an a/b/c disposition (endpoint exists / exists differently / doesn't exist) and reshaped scope rather than building a mobile-app capture pipeline. Same framing applies here.

**Topic axes:** A1 source, A2 capture, A3 storage, A4 unlocks.

## Survivors

### 1. Re-probe `/boxscore` and dump the full `groups[]` array
**Axis:** A1 source • A2 capture
**Basis:** `direct:` `lib/gamechanger/boxscore_parser.rb:34` already filters `groups[]` by category — anything else in the array is silently dropped. GC help docs confirm "defensive innings by position per game" is tracked. The cheapest possible probe is "pretty-print the raw response and see what other categories exist." If a `fielding` or `defense` category is there, we're one parser change away from positions.
**Why it matters:** If true, this is a half-day of work — extend `BoxscoreParser`, add a `game_fielding_positions` table (v4 migration), thread through formatters. Zero new auth surface, zero ToS risk, zero new endpoints. **Try this first.**
**Meeting test:** Yes — outcome reshapes the whole question.

### 2. Probe `include=` variants on `/public/game-stream-processing/{id}/details`
**Axis:** A1 source • A2 capture
**Basis:** `direct:` `docs/research/gc-scout-api-notes.md:134-143` documents the vendored-media-type pattern and `include=line_scores`. The `include=` keyword is a strong signal the endpoint accepts sibling values. Try `include=fielding,positions,lineup,plays,defensive_innings` and observe 200-with-extra-keys vs 400.
**Why it matters:** This endpoint is `public/` — no auth surface, no PII risk on the probe side. Low-cost discovery that either opens a clean alternate channel or rules one out.
**Meeting test:** Yes — discovery is cheap but the answer materially routes the rest of the work.

### 3. OCR the box-score screenshot (keep what eeg3 strips)
**Axis:** A1 source • A2 capture
**Basis:** `external:` [eeg3/gc-stat-aggregator](https://github.com/eeg3/gc-stat-aggregator) shows that the in-app box score screenshot contains position tokens `(P)`, `(C)`, `(SS)` etc. inline with player names. Their `parse_textArray` deliberately strips them. We'd invert that decision and capture them.
**Why it matters:** This is the **fallback path that works regardless of what the API exposes**. If both endpoint probes fail, OCR still gets us per-game (not per-inning) positions for any game already played. Cost: Tesseract or Cloud Vision + a small adapter; no new auth, no ToS scrape of API.
**Meeting test:** Yes — it's the floor we know works.

### 4. Mitmproxy the iOS scorekeeper app for live position events
**Axis:** A1 source • A2 capture
**Basis:** `direct:` `gc-scout-api-notes.md:145-162` already names mobile-app capture as the disposition-c path for opposing rosters. `external:` GC tech blog confirms the scoring pipeline is Kafka event-driven — the app emits position-assignment events in real time. `reasoned:` if any GC endpoint carries inning-level fielding, this is where it's posted from.
**Why it matters:** This is the only path to **per-inning, near-real-time** fielding (the data the "watch" feature wants). Cost is high: cert pinning bypass, one-time setup, must be re-done if GC changes their mobile stack. Worth doing only if (1) and (2) fail AND watch/equity-nudge is the priority.
**Meeting test:** Yes — explicit precedent disposition, high cost, needs a "go" before anyone touches it.

### 5. Parse the legacy XML scorekeeper export
**Axis:** A1 source • A2 capture
**Basis:** `external:` `eByte23/GameChanger` documents an older XML export available to manual scorekeepers. Position columns are plausible (typical scorekeeper exports include them) but unverified.
**Why it matters:** Zero-trust path — user exports XML manually, gem ingests. No API surface at all. Useful for **bulk backfill of past seasons** but not for live data and not for opponents. Sidecar feature, not core flow.
**Meeting test:** Borderline — only matters if (1)–(3) all fail and the user genuinely needs historical positions.

### 6. Storage: per-inning positions table with `(player_id, game_id, inning, position)` rows
**Axis:** A3 storage
**Basis:** `direct:` `lib/gamechanger/storage.rb:38` shows additive-only v1–v3 schema (frozen for Go interop). A v4 migration adding `game_fielding_positions(player_id, game_id, inning, position, fetched_at)` fits the existing pattern. Per-inning, not per-game, because GC tracks "defensive innings *by position*" — the unit is innings.
**Why it matters:** Schema shape is the *only* decision that's hard to undo. If we model per-game and the API gives us per-inning, we'd refit later. Per-inning is strictly more expressive — degrade to per-game in formatters when source is OCR-only.
**Meeting test:** Yes — the data-shape decision precedes acquisition work.

### 7. Position-aware fatigue and rotation suggestions (`/lineup` extension)
**Axis:** A4 unlock
**Basis:** `direct:` `lib/gamechanger/lineup_optimizer.rb` ranks batters by 7-day OBP only. Coaches at this age level (per the focus of the gem) care about defensive innings too — catcher fatigue, pitch-count-vs-position rules, equity of premium positions (SS, CF, P).
**Why it matters:** Positions data unlocks rotation planning and **fairness reporting** — "Player X has caught 3 of the last 4 games" or "Player Y has 0 innings at SS this season." Strong product fit with the existing equity/availability commands.
**Meeting test:** Yes — this is the feature case that justifies acquisition work in the first place.

### 8. Opponent-positions scout cross-link (dormant `opposing_roster.position` column)
**Axis:** A3 storage • A4 unlock
**Basis:** `direct:` `docs/plans/2026-05-15-001-feat-scouting-tool-phase-1-plan.md:266` already reserves a `position` column on `opposing_roster` (Go side). If GC happens to expose opponent positions through the same channel (boxscore is keyed by `team_slug` — both sides are there), one acquisition path lights up two features.
**Why it matters:** Coordination cost is near-zero if planned now, but expensive if done later — Ruby and Go schemas need to converge. Worth flagging in the same PR even if we don't ship scout positions immediately.
**Meeting test:** Yes — cross-feature coordination decision, hard to reverse later.

## Rejected

- **"Build our own scorekeeper app that emits positions."** Out of scope; not what the gem is for. Subject-replacement.
- **"Scrape gc.com web client HTML."** ToS-prohibited per multiple external sources; same risk profile as scraping their API. OCR of the user's own screenshot is the ToS-clean equivalent.
- **"Ask GameChanger for API access."** Confirmed no public API, no developer portal. Dead end; not actionable.
- **"Infer positions from play-by-play events."** Requires a play-by-play endpoint we haven't found and a fragile inference pipeline. Re-evaluate only if (1)–(4) all fail.
- **"Hand-enter positions after each game."** Treadmill; the gem is built to automate this kind of capture, not add manual data entry.

## Recommended next step

Run the Phase 0 watch probe (already a blocking TODO) and **at the same time** pretty-print the full `boxscore` response — answer ideas 1 and 2 in a single live-game session. If either lights up, idea 6 (per-inning storage) and idea 7 (rotation/equity unlocks) follow immediately. If both go dark, idea 3 (OCR) is the deterministic fallback.

## Handoff menu

- **Refine** — sharpen one of these into a brainstorm doc
- **Brainstorm** — `/ce-brainstorm` on idea 1 (boxscore re-probe) to scope acquisition + storage + first unlock
- **Save and end** — keep this doc as-is; resume after the next live-game probe
