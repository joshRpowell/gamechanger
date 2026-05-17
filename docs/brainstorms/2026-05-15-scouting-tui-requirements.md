---
date: 2026-05-15
topic: scouting-tui
---

# Pre-game scouting tool — CLI + TUI with shared data layer

## Summary

A pre-game scouting tool that surfaces opposing-team data (roster, coaches, recent results) in the terminal. Ships in two phases: a `scout <team>` CLI command first to prove the data layer and the recognition workflow, then a TUI navigator that mirrors the GameChanger web UI's navigation graph with scout-task annotations layered on. Both presentations consume one expanded API/cache layer.

---

## Problem Frame

The Ruby gem (and its in-flight Go port) treats GameChanger as a single-team analytics surface: one `team_id` in config, one schedule, and a small set of analytics commands operating on the user's own team. Pre-game scouting — the night-before workflow of pulling up an opposing team to see who's on the roster, who the coaching staff is, what teams they've played, and how those games went — is entirely outside the current product.

The user does that workflow in the GameChanger web UI today: tap into the next opponent on the schedule, scan the roster for familiar names ("who do we know?"), check the staff list, page through the opponent's schedule and results, then text observations to coaches in a group thread. The friction is not navigation speed inside the UI; it is that scouting data lives in an app instead of the terminal where the rest of the user's work happens, and the recognition step ("we played them last spring") is manual rather than automatic. A coach scouting four to six opponents per season currently spends fifteen to thirty minutes per opponent on this loop with no persistent artifact.

---

## Actors

- A1. **Coach (user):** Solo developer running the CLI/TUI for pre-game scouting; consumes data, drafts notes, shares with coaching staff via text.
- A2. **Coaching staff (recipients):** Other coaches receiving formatted scout summaries via text message; not direct users of the tool.
- A3. **GameChanger web API:** Unofficial data source. Endpoints used by the live web UI; the tool reverse-engineers what it needs and treats responses as canonical.
- A4. **AI loop / agent (future consumer):** Consumer of the structured JSON output for scouting-context injection into LLM workflows; not in v1 scope, but the data layer is shaped to accommodate it.

---

## Key Flows

- F1. **Night-before scouting (current — replaced by this work)**
  - **Trigger:** Coach knows tomorrow's opponent from team schedule.
  - **Actors:** A1
  - **Steps:** Open GameChanger app → tap next game → tap opposing team → scan roster for known names → tap staff list → review schedule and recent results → compose text message to coaching group with observations.
  - **Outcome:** Coaching staff has a verbal/text mental model of the opponent; no persistent artifact.
  - **Covered by:** Superseded by F2 / F3.

- F2. **Night-before scouting (phase 1 — `scout` command)**
  - **Trigger:** Coach knows tomorrow's opponent.
  - **Actors:** A1, A3
  - **Steps:** Run `gamechanger scout <opposing-team>` → tool fetches opposing roster + coaches + last-N games via expanded API client → cross-references roster names against local cache of own team's history → emits a human-readable summary with recognition markers ("we played them 2026-04-15, lost 4-2") → coach copy-pastes formatted summary into Messages with coaching staff.
  - **Outcome:** Same scouting result as F1, plus persistent local data, faster lookup, automatic recognition.
  - **Covered by:** R1, R2, R3, R4, R5, R6.

- F3. **Interactive scouting (phase 2 — TUI navigator)**
  - **Trigger:** Coach wants to browse opposing-team data beyond the `scout` command's single-screen output (drill into a specific past game, check a player's stat line, page through other opponents on the schedule).
  - **Actors:** A1, A3
  - **Steps:** Launch the TUI → land on teams list → navigate teams → schedule → game → opposing team → roster → coaches, mirroring the web UI's navigation graph. Scout-task annotations render inline on relevant screens.
  - **Outcome:** Coach has explored the opponent at depth equivalent to the web UI without leaving the terminal.
  - **Covered by:** R5, R7, R8, R10.

---

## Requirements

**Data layer (foundation for all presentations)**
- R1. Fetch opposing-team rosters via the expanded API client; responses are normalized and cached locally alongside the user's own team data.
- R2. Fetch opposing-team coaching staff lists; cached alongside roster.
- R3. Fetch opposing-team schedules and game results; cached alongside roster and staff.
- R4. Cross-reference opposing-roster names against the user's own historical games to surface "we played them" recognition markers (game date, score, W/L). Exact name match in v1.

**`scout` command (phase 1)**
- R5. `scout <team-identifier>` emits a single-screen, human-readable scouting summary: opposing-team roster (with recognition markers), coaches list, last-N games with results.
- R6. `scout` produces a human-readable output by default; the rendering is TTY-aware (colored/structured when stdout is a terminal; plain text suitable for copy-paste when piped or redirected). A `--format json` flag emits structured output for AI/agent pipeline consumption.

**TUI (phase 2)**
- R7. The TUI provides interactive navigation that mirrors the GameChanger web UI's graph: teams list → team detail → schedule → game detail → opposing team → roster → coaches.
- R8. Scout-task annotations (recognition markers, cross-references) render inline on relevant TUI screens — pure UI parity is not the goal; the TUI is opinionated for the scouting workflow.

**Harness / validation**
- R9. API responses are validated against recorded fixtures (HAR-style captures from the live web UI) so the client survives short-term API drift. Fixtures are local-only per-developer in v1 (gitignored); the committed/shared corpus is deferred until CI lands, mirroring the parity-harness plan's CI-deferred stance. This is a separate harness from the cache.db parity harness already shipped.
- R10. Cached data persists between invocations and refreshes on user-initiated action only; the tool never silently issues live API calls during interactive TUI navigation without an explicit refresh gesture.

---

## Acceptance Examples

- AE1. **Covers R1, R4, R5.** Given the user's own team has played "Eagles 12U" once on 2026-04-15 (recorded in local cache), when the user runs `scout eagles-12u`, the output includes the line "we played them 2026-04-15 — lost 4-2" attached to the opposing-team header.
- AE2. **Covers R4.** When an opposing-team roster contains a player whose name exactly matches a player from the user's own team's historical games, the recognition marker surfaces with the prior matchup context. Names that differ by casing only normalize before matching; names that differ by punctuation, nicknames, or jersey number are NOT matched in v1.
- AE3. **Covers R6.** When the user runs `scout <team>` with the text-friendly format flag, the output is at most 500 characters and contains no terminal escape codes, so paste into Messages renders cleanly.
- AE4. **Covers R6.** When the user runs `scout <team>` with the JSON format flag, the output is valid JSON parseable into a documented structure with named fields for roster, coaches, recent games, and recognition markers.
- AE5. **Covers R9.** Given a recorded HAR fixture for the opposing-roster endpoint, when the API client is exercised against that fixture in tests, the parsed result matches the snapshot byte-for-byte.
- AE6. **Covers R10.** When the user navigates from "team detail" to "roster" in the TUI and the roster is already cached, no live API call fires; a visible indicator names the cache age.
- AE7. **Covers R7.** From any TUI screen, the user can reach any other screen named in the navigation graph (teams list → team detail → schedule → game → opposing team → roster → coaches) using only keyboard input.

---

## Success Criteria

- **Human outcome:** The user runs `scout` the night before a game, gets a single-screen summary with at least one recognition marker on a familiar opponent, copies the formatted output into a text message to coaches, and stops opening the web app for scouting. Time-to-summary under five seconds on cache hit, under thirty seconds on cache miss + live fetch.
- **Downstream-agent handoff:** A subsequent `ce-plan` invocation can break this into implementation units without inventing product behavior — API surface, data shapes, command shape, TUI navigation graph, validation strategy, and output formats are all specified.
- **Integration with prior work:** The expanded API client lands as a clean addition to the existing Go module — no regressions in `go test ./...`, `bundle exec rspec`, or the cache.db parity harness for currently-ported analytics commands.

---

## Scope Boundaries

### Deferred for later

- In-game decision support — live-data refresh and decision-support outputs during a game in progress.
- Tournament / league-wide planning across multiple teams as a coordinated workflow.
- AI/agent integration of the JSON output — the JSON shape ships in v1 but downstream LLM consumption is a separate workstream.
- In-tool note-taking / annotation — the output channel for notes remains text messages with coaches, not the tool itself.
- TUI editing / modification of any data — read-only in v1.
- Fuzzy name matching for recognition markers — exact name match (case-normalized) in v1.
- Multi-team / multi-user accounts — single solo coach use case in v1.

### Outside this product's identity

- A general-purpose CLI replica of the GameChanger UI for non-scouting flows (lineup management, in-app scoring, equity tracking that is not pre-game-related). Those uses stay in the web app; this tool is opinionated for pre-game scouting.
- Direct integration with iMessage / SMS / coaching-app APIs to push notes automatically. The tool emits paste-friendly output; the messaging step stays human-driven.
- A web frontend or mobile app. Terminal-only by intent — the form factor IS part of the product positioning (developer-in-terminal workflow), not an incidental choice.
- A second visual parity harness comparing TUI output to web UI screenshots. Visual parity is not a goal; data parity is.

---

## Key Decisions

- **B-first sequencing under Approach C:** Ship the `scout` command before the TUI so the data layer is proven against the actual workflow before the navigator builds on it. The TUI build does not have to simultaneously debug "do we have the right data."
- **Hybrid UI parity:** The TUI mirrors the web UI's navigation graph at the structural level but is opinionated about cross-reference annotations (recognition markers, scout-task curation). Pure UI parity is not the standard.
- **Separate HAR-fixture harness:** API response validation uses a new harness distinct from the cache.db parity harness already shipped. The two harnesses share neither fixtures nor verification logic — conflating them would muddy both oracles.
- **Text-message-friendly output as primary:** The user-facing default of `scout` is shaped for copy-paste into coaching group texts. JSON format exists for AI/agent pipelines but is the secondary consumer.
- **Read-only in v1:** No editing, no annotations stored in the tool. Notes stay in Messages; this tool exists to surface data, not to manage it.
- **Hybrid fetch strategy:** `scout <team>` does a single-burst fetch (user explicitly asked for the full scouting summary; one timestamp per team, predictable cache freshness). TUI navigation lazy-fetches per screen (user might never visit certain screens; smaller per-step API cost). Both share underlying populate functions, just with different orchestration. Decided over single-burst-always (wastes calls when TUI user only wants a list view) and lazy-always (worse `scout` latency, multiple freshness timestamps per team).
- **HAR fixtures local-only in v1:** Each developer records HAR into a gitignored local dir; no committed shared corpus. Deferred until CI itself lands (mirrors the cache.db parity plan's CI-deferred posture). Anonymize-and-commit is the v2 move when contributor onboarding or CI matters.
- **TTY-aware default for `scout`:** Detect stdout TTY → colored/structured terminal rendering; pipe/redirect → plain copy-paste-friendly text. Unix-idiomatic (`ls`, `grep`, `git diff` pattern). One mental model, no flag needed for the common `scout team | pbcopy` workflow. JSON stays behind an explicit `--format json` flag.

---

## Dependencies / Assumptions

- **GameChanger API endpoints for opposing-team data exist and are reachable.** The current gem uses `/me/teams`, `/teams/{id}/schedule`, and `/game-stream-processing/{game_id}/boxscore`. Endpoints for arbitrary team rosters, coaching staffs, and arbitrary team schedules are not currently used and have **NOT** been verified to exist as separate addressable endpoints — they may need reverse-engineering against the web UI's network calls. *Unverified assumption.*
- **The token-paste auth flow extends to opposing-team endpoints.** The current Go port's `auth import` flow imports a `gc-token` JWT; if opposing-team endpoints require a stricter auth model (per-team access tokens or signed requests), the auth surface needs extension.
- **API stability for the duration of the product's life.** GameChanger does not publish API stability guarantees; auth-flow shifts or anti-scraping mitigations would break the tool. The HAR-fixture harness reduces test-corpus blast radius but cannot prevent live-fetch breakage.
- **Cross-reference data source.** Recognition markers default to the user's own team's local cache (cache.db). Broader sources (prior teams the user coached, league-wide history) are out of v1 scope.
- **Terminal/TUI framework choice.** Implementation-level decision deferred to planning. Whatever is chosen, it must run on macOS terminals (user's environment).

---

## Outstanding Questions

### Resolve Before Planning

*(All three prior items resolved 2026-05-15 — see Key Decisions: hybrid fetch strategy, HAR fixtures local-only in v1, TTY-aware default for `scout`.)*

### Deferred to Planning

- [Affects R1, R2, R3][Needs research] Reverse-engineer the web UI's network traffic to identify the exact endpoints, request shapes, and Accept headers for opposing-team roster, coaches, and schedule. Approach: capture HAR while navigating the web UI; this becomes the first HAR fixture set.
- [Affects R4][Technical] Cross-reference matching strategy — exact string match on player name? Match on (name, jersey number)? Match windows by date range? Resolve during planning after the data shapes are known.
- [Affects R7, R8][Technical] TUI framework selection — Bubble Tea, tcell, gocui, or a thinner readline-based shape? Resolve during planning with a UX prototype.
- [Affects R9][Technical] HAR fixture format — raw HAR, or a normalized snapshot (request → expected JSON body)? The cache.db anchor's regeneration model is a reasonable analog.
- [Affects R10][Technical] Cache freshness signaling — TTL? Last-fetched timestamp visible in TUI? Explicit "refresh" gesture? Resolve during planning.
