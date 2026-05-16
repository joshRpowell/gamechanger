---
date: 2026-05-15
type: feat
origin: docs/brainstorms/2026-05-15-scouting-tui-requirements.md
status: completed
completed_date: 2026-05-16
phase: 1a
pivot: matchup-history-scout
pivot_date: 2026-05-15
pivot_rationale: U1 discovery confirmed the web/desktop API does not expose opposing-team rosters
---

# feat: Pre-game scouting tool — Phase 1a (matchup-history scout)

## Summary

Phase 1a of the scouting tool, **reshaped after U1 discovery** as a matchup-history scout. Given an opponent (by name or UUID), surface every prior game the user's team has played against them with scores, W/L, dates, and home/away. The original "scan opposing roster for familiar names" workflow can't ship against the web/desktop API surface — only the mobile app exposes opposing rosters (see `docs/research/gc-scout-api-notes.md`). The reshape keeps the night-before pre-game prep value via matchup history while remaining shippable against endpoints we've confirmed work.

**What ships:** `gamechanger scout <opponent>` CLI that returns "you've played them N times. Last 5: 2026-04-15 home L 4-7, 2026-03-22 away W 8-3, ...". Uses the discovered `/teams/{uuid}/game-summaries` endpoint as the primary data source. Phase 2 (TUI) and the mobile-roster path (would unblock the original AE2 player-name workflow) both defer to separate plans.

---

## U1 Discovery Outcome (2026-05-15) — Plan Reshape

The U1 gate (HAR/probe against the live API) caught a plan-blocking issue **exactly as designed**: the web/desktop GameChanger API does NOT expose opposing-team rosters. The endpoint we expected to find (something like `/teams/{opp_uuid}/players` or roster-inline-with-opponent-detail) doesn't exist on this API surface. The `/teams/{your_team}/opponent/{opp_uuid}` endpoint exists but returns only 220 bytes of opponent metadata — name and tracking IDs, no players, no coaches.

Three forks emerged from the discovery (full analysis in `docs/research/gc-scout-api-notes.md`):

| Fork | Description | Why it fits / doesn't |
|---|---|---|
| **A — Matchup history scout** (this plan) | Given an opponent, show prior games + scores + W/L | Ships against confirmed `/teams/{uuid}/game-summaries`. Loses AE2 (player-name match). |
| B — Mobile-app capture | Use mitmproxy + cert override to find mobile-app roster endpoints | Larger lift, uncertain payoff, requires phone-side tooling setup |
| C — Park scout | Drop scout entirely; use `/game-summaries` to enrich existing `progress`/`brief` analytics with W/L context | Smallest scope, abandons the scout product surface |

**This plan adopts Fork A.** Forks B and C live in `### Deferred to Follow-Up Work` so they remain visible as future-session options.

What survives intact from the pre-reshape plan:
- **U1's findings doc** (`docs/research/gc-scout-api-notes.md`) is the durable artifact regardless of fork chosen.
- **U2's schema migration v4** still ships — `opposing_teams` becomes a name→UUID cache; `opposing_roster` is unused in Fork A but kept for Fork B's revival path.
- **`ErrAuthInsufficient` sentinel** is generally useful, ships regardless.
- **U6's cross-reference query** (player-name match) ships as committed but is **unused by Fork A's runtime path**. Kept for Fork B revival; documented in U6 below.

---

## Problem Frame

The Go CLI port today is single-team-scoped: one `team_slug` in `~/.gamechanger/config.yml`, one schedule, three analytics endpoints (`/me/teams`, `/teams/{id}/schedule`, `/game-stream-processing/{game_id}/boxscore`), no concept of an opposing team as a first-class entity. The brainstorm (see origin: `docs/brainstorms/2026-05-15-scouting-tui-requirements.md`) frames pre-game scouting as the missing workflow — a coach the night before a game needs the opposing-team roster, coaching staff, and recent results in terminal context so familiar names ("we played them last spring") light up automatically against the user's own historical cache.

The blocking discovery work is API surface: GameChanger's web app exposes opposing-team data, but the gem has never exercised those endpoints. The first unit is reverse-engineering — capturing the web app's network calls for the roster endpoint specifically into HAR fixtures, documenting its request shape and Accept header, and only then implementing the client method. Building against speculative endpoint paths is the most likely failure mode and would poison the test corpus.

**Why slice to Phase 1a:** the pre-reduction plan (8 units, ~20 files) committed to score columns, coaches tables, opposing schedules, slug resolution, and a separate HAR-fixture package before any code touched the real API. The ce-doc-review pass surfaced 6 P1 findings, most clustered on downstream-speculative work that doesn't land until U6+. Phase 1a slices the speculation away: prove the roster fetch + cross-reference workflow against real data first, then commit Phase 1b to the residual surface informed by what we actually learn at U1.

Downstream patterns are well-modeled by what's already in the repo: the parity-harness shape (U1-U6 of the verify-parity plan, just shipped) is the analog for HAR replay; `internal/commands/verify.go` is the freshest example of a typed-exit-code cobra subcommand; `internal/analytics/progressjson/` is the in-process renderer pattern the `scout` formatter mirrors.

---

## Requirements Trace

Carrying forward from origin `docs/brainstorms/2026-05-15-scouting-tui-requirements.md`:

**Actors:** A1 (Coach), A3 (GameChanger web API), A4 (future AI/agent consumer of JSON output). A2 (coaching staff recipients) is satisfied by R6's copy-paste-friendly output, not by the tool itself.

**Key flows addressed in Phase 1a:** F2 (`scout` command — night-before scouting), at the roster + cross-reference layer. F3 (TUI navigator) defers to Phase 2 plan. F1 (current UI workflow) is superseded.

**Requirements covered in Phase 1a (post-reshape):** R3 (opposing schedules with results — repurposed: matchup history with the user's team), R4's date+opponent+score recognition shape (now the primary surface, not a secondary cross-reference), R5 (scout command), R6 (TTY-aware + JSON output), R9 (HAR-fixture validation, in-package), R10 (cache freshness).

**Requirements deferred to Fork B (mobile-app capture) or future re-brainstorm:** R1 (opposing roster — API surface doesn't expose), R2 (coaches — same), R4's player-name-match recognition (depends on R1).

**Requirements deferred to Phase 2:** R7, R8, AE6, AE7 (TUI navigator).

**Acceptance examples covered in Phase 1a:** AE1 — **now fully covered** with score+W/L ("we played them 2026-04-15 — lost 4-2") since `/game-summaries` provides scores directly. AE3 (text-friendly output cap), AE4 (JSON round-trip), AE5 (HAR fixture replay, in-test). **AE2 cannot ship in Fork A** — depends on opposing-roster data the API doesn't expose.

**Scope boundaries preserved verbatim** from origin's two categories (Deferred for later / Outside this product's identity). The plan adds a third subsection, `Deferred to Follow-Up Work`, for plan-local sequencing — Phase 1b follow-up plan, TUI follow-up plan, HAR corpus promotion, broader cross-reference sources.

**Plan-time resolutions of origin Deferred-to-Planning items:**

- D#1 (reverse-engineer endpoints) → **U1**, scoped to the roster endpoint in 1a; coaches + schedule endpoints get their own HAR-capture step in Phase 1b.
- D#2 (cross-reference matching strategy) → **U6**, case-normalized exact string match per origin R4 and AE2; team-scoped join (matching only games whose `games.opponent` equals the scouted team name) avoids the false-positive risk that ce-doc-review flagged.
- D#3 (TUI framework) → out of scope (deferred to Phase 2 plan).
- D#4 (HAR fixture format) → **U1+U4**, normalized snapshot format (request signature → expected response body), local-only per developer in `testdata/har/` (gitignored). Stored as plain JSON files; `scout_test.go` loads them via a small test helper rather than a separate package.
- D#5 (cache freshness signaling) → **U6**, `scout` always reports cache age in human-readable output; explicit `--refresh` flag forces re-fetch.

---

## Key Technical Decisions

| Decision | Choice | Rationale |
|---|---|---|
| **Fork** | **A — Matchup-history scout** (vs. mobile-roster path or full park) | U1 discovery: web/desktop API doesn't expose opposing rosters; A ships against confirmed endpoints |
| Primary data source | `/teams/{your_team_uuid}/game-summaries` — single endpoint returning all games with `owning_team_score`, `opponent_team_score`, `opponent_id`, `home_away`, `last_scoring_update` | Discovered by U1's probe; supersedes the original plan's boxscore-parsing path (no per-game iteration needed) |
| Opponent name lookup | `/teams/{your_team_uuid}/opponent/{opp_uuid}` — 220B response with `name`, `owning_team_id`, `progenitor_team_id`, `root_team_id` | Cached in `opposing_teams` (U2) so subsequent invocations resolve names locally |
| Phase split | This plan covers Phase 1a (matchup-history scout); Phase 1b promotes `/game-summaries` consumption into existing `progress`/`brief` analytics (W/L context); Phase 2 adds TUI; Fork B (mobile roster) is its own brainstorm if pursued | Discovery-driven; original phasing assumed roster endpoint existed |
| Sequencing | U1 is HAR-capture discovery (no code lands) | Opposing-team endpoints are unverified; building against speculative paths is the most likely failure mode |
| Schema | New migration v4 (Go-only); never edit v1–v3 | Ruby gem doesn't gain scouting; v1–v3 stay byte-identical for Ruby↔Go interop on existing analytics |
| Schema scope | v4 adds **opposing_teams** + **opposing_roster** only; opposing_coaches / opposing_games / score columns defer to Phase 1b | Avoids committing to score-extraction shape before U1 confirms boxscore JSON carries scores; keeps migration footprint minimal |
| HAR-fixture replay | Inline test helper in `internal/scout/fixtures_test.go` (~40 LOC); NOT a separate sibling package | Surface is just `loadFixture(name) []byte` and byte-equal compare in `httptest` server — too small to earn a package |
| HAR storage | Local-only per developer in `testdata/har/` (gitignored) | Brainstorm decision; CI-deferred until CI itself lands (mirrors parity-harness plan's stance) |
| Defensive parsing | Triple-shape parse for the new endpoint response | Existing `internal/client/client.go` convention; documented in `docs/research/gc-api-notes.md` |
| Team identifier | `scout <uuid>` only in 1a; slug resolution defers to Phase 1b | AE1's `eagles-12u` slug requires a resolution path (`/me/teams` cache only knows the user's own teams; never-played opponents have no slug source). UUID-only is honest about what 1a knows |
| TTY detection | `mattn/go-isatty` (already a transitive dep via cobra) | No new dependency; widely-used stdlib-adjacent pattern |
| Output renderer | In-process via `internal/format/scout.go`, called by `cmd scout` and by future TUI | Mirrors `internal/analytics/progressjson/` extraction pattern |
| Cross-reference matching | Case-normalized exact name match AND team-scoped (only games where `LOWER(games.opponent) = LOWER(opposing_team.name)`) | Per origin AE2 (name normalization) + ce-doc-review fix (team-scoped join avoids false-positive markers from coincidental name matches across unrelated teams) |
| Recognition marker shape | `{ GameDate, Opponent }` only in 1a — no score, no W/L | Score columns + W/L derivation defer to Phase 1b once score-data shape is confirmed |
| Exit codes | New typed exits via `parityExit`-style pattern (already proven in U6): `scout-pass`, `team-not-found`, `auth-expired`, `auth-insufficient-scope`, `network-error`, `cache-empty` | Lets AI-loop / scripting consumers distinguish failure modes; `auth-insufficient-scope` (403) surfaced by ce-doc-review |
| PII posture | Document in U2's approach that `~/.gamechanger/cache.db` is user-local, no cloud sync expected, no automatic retention TTL in 1a; revisit posture in 1b before committing more opposing-team tables | ce-doc-review flagged minors' names accumulating with no retention; for 1a (roster-only, single table), make the posture explicit; 1b's larger surface earns a deeper retention decision |

---

## High-Level Technical Design

*Directional guidance for review, not implementation specification. The implementing agent should treat this as context, not code to reproduce.*

```
User invocation
    │
    ▼
gamechanger scout <team-uuid>
    │
    ▼
internal/commands/scout.go
    │  validate uuid format; reject anything that doesn't match UUID regex
    │
    ▼
internal/scout/scout.go  (orchestrator)
    │
    │  if --refresh OR cache stale OR cache miss:
    │      internal/client/scout.go.Roster(uuid) → 1 call, rate-limited
    │
    │  persist into opposing_teams + opposing_roster (migration v4)
    │
    ▼
internal/store/scout_queries.go
    │  CrossReferenceRoster(opposingTeamName, rosterNames) → []RecognitionMarker
    │      JOIN game_batter_stats / game_pitcher_stats on case-normalized name
    │      AND scope to games where LOWER(games.opponent) = LOWER(opposingTeamName)
    │
    ▼
ScoutContext{Team, Roster (with markers), CacheAge}
    │
    ▼
internal/format/scout.go
    │  isatty(stdout)?
    │    yes  → terminal-pretty (colors, borders, structured table)
    │    no   → plain text (paste-friendly, <500 chars for AE3)
    │  --format json → JSON encoder
    │
    ▼
exit code:
  0 scout-pass        10 team-not-found      20 auth-expired
  21 auth-insufficient-scope    30 network-error    40 cache-empty
```

---

## Output Structure

```
internal/scout/
├── scout.go                  (U6 — matchup-history orchestrator)
└── scout_test.go             (U6 — uses httptest fake + in-memory SQLite; ~5-LOC inline loadFixture helper at top of file)

internal/client/
├── scout.go                  (U4 — Roster method only)
└── scout_test.go             (U4 — replays HAR via httptest)

internal/store/
├── migrations.go             (U2 — extend, add v4)
├── scout_queries.go          (U6 — cross-reference query)
└── scout_queries_test.go     (U6)

internal/format/
├── scout.go                  (U7 — TTY-aware renderer + JSON)
└── scout_test.go             (U7)

internal/commands/
├── scout.go                  (U7 — cobra wiring)
└── scout_test.go             (U7 — TestHelperProcess pattern from verify.go)

testdata/har/                 (U1 — gitignored; per-developer HAR captures)
├── README.md                 (U1 — capture procedure + endpoint inventory)
└── roster_<sample>.json      (U1 — one sample roster fixture)

docs/research/
└── gc-scout-api-notes.md     (U1 — endpoint shape, Accept header, response structure)

.gitignore                    (U1 — add testdata/har/)
CHANGELOG.md                  (U8 — Unreleased entry)
```

---

## Implementation Units

*U3 and U5 from the pre-reduction plan are deliberately empty — see `Deferred to Follow-Up Work`. Per the plan-template's U-ID stability rule, gaps are preserved so the Phase 1b plan can resume those concepts under their original identifiers.*

### U1. HAR capture session + roster-endpoint documentation (discovery, no code)

**Goal:** Confirm the opposing-team **roster** endpoint exists as an addressable route on `api.team-manager.gc.com`. Produce a sample HAR capture and document the request shape, headers, and response structure. Phase 1b's discovery (coaches + opposing schedules) is a separate U1-like unit in that plan.

**Requirements:** R1 (roster sourcing).

**Dependencies:** None.

**Files:**
- `testdata/har/README.md` (new — capture procedure + endpoint inventory)
- `testdata/har/roster_<sample>.json` (new — sample roster capture, gitignored)
- `docs/research/gc-scout-api-notes.md` (new — endpoint reverse-engineering doc, analog to existing `docs/research/gc-api-notes.md`)
- `.gitignore` (modify — add `testdata/har/`)

**Approach:**
0. **Land the `.gitignore` entry first** — add `testdata/har/` to `.gitignore` and commit BEFORE any HAR capture so no partial-capture state can be staged. The downstream verification step (`git status` shows no uncommitted HAR files) is only meaningful if this happens first.
1. Open `web.gc.com` in Chrome / Firefox with DevTools → Network tab open. Log in (token paste-flow already established).
2. Navigate to an opposing team via the schedule (tap next game → opposing team → roster). Save the relevant network request as HAR via DevTools "Save all as HAR with content".
3. Extract just the response body for the roster endpoint into `testdata/har/roster_<sample>.json` as normalized JSON. **Strip auth context before saving** — credentials can hide in request headers, response headers (`Set-Cookie`), HAR-level cookie arrays, and URL query strings; the filter must cover all four. Use a filter equivalent to:

   ```jq
   .log.entries[] |= (
     .request.cookies = []
     | .response.cookies = []
     | .request.queryString |= map(select(.name | test("token|auth|key|secret|session"; "i") | not))
     | .request.headers |= map(select(.name | test("gc-token|gc-device-id|authorization|cookie|bearer"; "i") | not))
     | .response.headers |= map(select(.name | test("set-cookie|authorization"; "i") | not))
   )
   ```

   Also manually audit `response.content.text` for token-shaped values — no automated filter can know which response fields are credentials without endpoint-specific knowledge. Verify with a composable guard that exits non-zero on detection so it works in pre-commit hooks and CI:

   ```bash
   if grep -rqEi 'gc-token|gc-device-id|authorization|set-cookie|bearer' testdata/har/; then
     echo "SCRUB_FAIL — credentials detected in HAR fixtures" >&2
     exit 1
   fi
   ```
4. Document in `docs/research/gc-scout-api-notes.md`: request path, method, query params, Accept header (the existing `application/vnd.gc.com.team:list+json; version=X.Y.Z` pattern), response shape (note triple-shape candidates: bare array, `{teams:[]}`, `{data:[]}`), and any field-name quirks. Update the existing `docs/research/gc-api-notes.md`'s "Known unknowns" section if the roster endpoint clarifies it.
5. **Decision matrix — record disposition in the doc before U2 begins:**
   - (a) Roster endpoint exists as a separate addressable path → proceed as planned.
   - (b) Roster data is served inline within a larger team/match payload → revise U4's method shape to fetch the parent endpoint and project the roster slice; revise U2 to reflect single-call freshness model.
   - (c) Endpoint exists only as a paginated stream → add pagination handling to U4 + risk-table entry.

**Execution note:** Discovery-only — no Go code lands. This unit is paper output; the artifact is HAR + notes that downstream units consume.

**Patterns to follow:** Existing `docs/research/gc-api-notes.md` documentation structure.

**Test scenarios:** Test expectation: none — this is a discovery unit. Verification is the existence of one captured fixture + a complete endpoint-shape document + recorded disposition (a/b/c).

**Verification:** `docs/research/gc-scout-api-notes.md` documents the roster endpoint with request method, path, query params, Accept header, response shape, and the chosen disposition. One corresponding HAR capture exists in `testdata/har/`. `.gitignore` excludes that directory. `git status` shows no uncommitted HAR files in tracked paths. Scrub verification (the `grep` in step 3) produces no output and exits non-zero — no matches found, so the `&& echo SCRUB_FAIL` branch does not execute.

---

### U2. Schema migration v4 — opposing_teams + opposing_roster

**Goal:** Add storage for opposing-team roster data in a single additive migration. Go-only; Ruby gem's migration history is unaffected. Score columns + opposing_coaches + opposing_games defer to Phase 1b.

**Requirements:** R1, R4 (storage + cross-reference foreign keys).

**Dependencies:** None (U1 informs response shape but schema is independent of exact API field names — store the normalized shape).

**Files:**
- `internal/store/migrations.go` (modify — add v4 migration; never edit v1–v3)
- `internal/store/types.go` (modify — add `OpposingTeam`, `OpposingPlayer`, `RecognitionMarker` types)
- `internal/store/migrations_test.go` (modify or new — verify v4 applies cleanly on fresh DB and on a v3-populated DB)

**Approach:**
- New tables (additive):
  - `opposing_teams (team_uuid PRIMARY KEY, team_name, last_fetched_at)`
  - `opposing_roster (team_uuid, player_name, jersey_number, position, last_fetched_at, PRIMARY KEY (team_uuid, player_name))`
- Existing `games` table: untouched in 1a. Score columns defer to Phase 1b.
- Index: `CREATE INDEX idx_opposing_roster_name_lower ON opposing_roster (LOWER(player_name))` for cross-reference matching.
- **PII posture documentation:** add a top-of-file comment on the migration block: "opposing_roster persists minors' names. cache.db is user-local at ~/.gamechanger/ — no cloud sync, no automatic retention TTL in v4. Phase 1b revisits retention before adding additional opposing-team tables." This is a stated posture, not an enforcement mechanism; it ensures the implementing agent (and future readers) understand the boundary.

**Execution note:** Test-first — write a migration test that applies v4 against a v3-only DB and asserts each table exists with the expected columns before writing the migration SQL.

**Patterns to follow:** `internal/store/migrations.go` v1–v3 (additive style, paired version constants).

**Test scenarios:**
- Apply v4 to a fresh `:memory:` DB; verify both new tables and their columns exist via `PRAGMA table_info`.
- Apply v4 to a DB pre-populated through v3 (using existing migration test helper); verify v1–v3 tables unchanged.
- Re-applying v4 on an already-v4 DB is a no-op (idempotent; standard `IF NOT EXISTS` / version-tracking).
- Inserting a row into `opposing_roster` with the same `(team_uuid, player_name)` fails with a uniqueness violation.
- The `idx_opposing_roster_name_lower` index exists post-migration (`PRAGMA index_list`).

**Verification:** `go test ./internal/store/...` green. Schema introspection on a v4 DB shows the two new tables and the case-insensitive index.

---

### U3. *(Deferred to Phase 1b — boxscore parser score extraction)*

Phase 1b will resume this unit under its original U-ID. The Phase 1b plan will own:
- Field-path discovery for home/away scores in boxscore JSON (anchored on U1-style HAR capture of a boxscore response)
- `games.home_score` / `games.away_score` columns via migration v5
- Parser extension to populate scores during sync
- Backfill mechanism for existing games (mechanism TBD — current schema doesn't persist raw boxscore JSON, so backfill from cache is unimplementable; will be re-fetch on demand or no backfill)

---

### U4. API client expansion — GameSummaries + OpponentDetail methods *(reshaped)*

**Goal:** Add two methods to `*Client`:
- `GameSummaries(ctx, teamUUID) ([]GameSummary, error)` — fetches the full matchup history from `/teams/{uuid}/game-summaries`. Returns games with `opponent_id`, `home_away`, `owning_team_score`, `opponent_team_score`, `game_status`, `last_scoring_update`. Bare-array response (confirmed by U1).
- `OpponentDetail(ctx, teamUUID, opponentUUID) (*OpponentDetail, error)` — fetches `/teams/{uuid}/opponent/{opp_uuid}`. Returns `name`, `owning_team_id`, `progenitor_team_id`, `root_team_id`. Used to resolve opponent name once and cache it. 220B response.

Both return `application/json; charset=utf-8` with `Accept: application/json` (no vendored media type needed — confirmed by U1).

**Requirements:** R3, R4 (matchup history with results).

**Dependencies:** U1 (roster endpoint shape documented).

**Files:**
- `internal/client/scout.go` (new — single method, error types if needed)
- `internal/client/scout_test.go` (new — ~5-LOC inline `loadFixture` helper at top of file, no shared package)
- `internal/client/client.go` (modify if needed — register new Accept header constant alongside existing `ACCEPT_TEAM_LIST` etc.)

**Approach:**
- The method follows the existing pattern in `client.go`: build URL with `WithBaseURL` support, set `gc-token`/`gc-device-id`/`gc-app-name` headers, set the endpoint-specific Accept header from U1 documentation, execute with the existing 35s timeout and 429-retry path, defensively parse the response.
- Define typed errors: `ErrTeamNotFound` (404 on the scout endpoint), `ErrAuthInsufficient` (403 — surfaced by ce-doc-review, distinct from 401's `ErrAuth`), `ErrRosterUnavailable` (200 but empty), as sentinels via `internal/gcerr`.
- HAR replay helper for tests: `internal/client/scout_test.go` reads `testdata/har/roster_<sample>.json` directly via `os.ReadFile` (no separate package) and serves the bytes via `httptest.Server`.

**Execution note:** Test-first using HAR fixtures — the method has a test that loads a fixture, spins up an `httptest.Server` that returns the fixture body for matching requests, and asserts the parsed struct.

**Patterns to follow:** `internal/client/client.go` (existing methods, triple-shape defensive parsing, 429-retry, `WithBaseURL`). `internal/sync/integration_test.go` (httptest pattern).

**Test scenarios:**

> **Note (2026-05-16 retro):** the scenarios below describe the pre-reshape `Roster()` method. The shipped unit ships `GameSummaries()` (bare-array response) and `OpponentDetail()` (bare-object response) — see `internal/client/scout_test.go` for the actual coverage. The triple-shape defensive parsing scenario was unnecessary against the confirmed bare-array / bare-object responses and is not part of the shipped tests.

- `Roster(ctx, validUUID)` against a fake server returning the U1 roster HAR → returns expected `OpposingPlayer` slice with names, jerseys, positions.
- `Roster(ctx, invalidUUID)` against a server returning 404 → returns `ErrTeamNotFound`.
- `Roster(ctx, uuid)` against a server returning 429 once then 200 → retries and succeeds (existing retry path).
- Triple-shape parsing: server returns bare array → parsed correctly; server returns `{data:[...]}` → parsed correctly; server returns `{teams:[...]}` → parsed correctly (skip whichever shape U1 confirms is canonical and test the two non-canonical fallbacks).
- Auth-expired path (401): server returns 401 → returns `gcerr.Authf` wrapping the response body.
- Auth-insufficient path (403): server returns 403 → returns new `ErrAuthInsufficient` sentinel with response body.
- Network failure: httptest server closed mid-request → returns `gcerr.Networkf`.
- **Covers AE5.** HAR fixture replay test: load `testdata/har/roster_<sample>.json` (or skip with `t.Skipf` if fixture absent), serve as response, assert parsed result matches expected shape — byte-equal at the JSON layer, struct-equal after parse.

**Verification:** `go test ./internal/client/...` green. Coverage includes the new method and all five typed-error paths plus the HAR replay.

---

### U5. *(Deferred — collapsed into U4's test file as inline helper)*

The pre-reduction plan had U5 as a separate `internal/scoutfixture/` sibling package. ce-doc-review + Step 0 scope challenge concluded the surface (`Load` + byte-equal compare) is too small to earn a package. The helper lives inline in `internal/client/scout_test.go` and `internal/scout/scout_test.go` as a ~20-line private function. Phase 1b may re-evaluate if the helper grows beyond two callers.

---

### U6. Scout orchestrator + matchup-history query *(reshaped)*

**Goal:** Orchestrate the matchup-history workflow. Given an opponent identifier (name or UUID), fetch `/game-summaries` for the user's team, filter to games against that opponent, persist opponent name to `opposing_teams`, and assemble a `MatchupHistory` with scored games sorted DESC by date.

**Note on already-shipped code (2026-05-16 retro correction):** the pre-reshape `CrossReferenceRoster` query (committed at `36418fd`) is **unused in Fork A's runtime** but kept in the codebase for Fork B's potential revival. Its tests remain green. Fork A's matchup-history filtering happens **inline inside `scout.Scout()`** in `internal/scout/scout.go` — the orchestrator iterates `GameSummaries` and filters by `opponent_id` directly. There is no separate `MatchupAgainstOpponent` function (an earlier draft of this note named one; that name does not exist in the shipped code).

**Requirements:** R3, R4 (matchup history).

**Dependencies:** U2 (schema), U4 (client method).

**Files:**
- `internal/scout/scout.go` (new — `Scout(ctx, store, client, teamUUID) (*ScoutContext, error)`)
- `internal/scout/scout_test.go` (new — uses httptest fake + in-memory SQLite; ~5-LOC inline `loadFixture(t, name) []byte` helper at top of file using `os.ReadFile(filepath.Join("..", "..", "testdata", "har", name))`)
- `internal/store/scout_queries.go` (new — `CrossReferenceRoster(...)` ships as dormant code for Fork B revival; Fork A's runtime does not call it)
- `internal/store/scout_queries_test.go` (new)

**Approach:**
- `Scout(ctx, store, client, teamUUID)` validates the UUID format (reject anything that doesn't match the UUID regex), checks the `opposing_teams` cache for freshness.
- Cache miss OR stale (>24h, configurable via `--refresh`) → call `client.Roster(uuid)`, persist team + roster rows in a single transaction so partial state doesn't poison subsequent reads.
- After persist (or on cache hit), call `store.CrossReferenceRoster(opposingTeamName, rosterNames)`:
  - Roster names normalized to `LOWER(player_name)`.
  - Query `game_batter_stats` + `game_pitcher_stats` for matching names.
  - **Team-scoped join**: only include matching games where `LOWER(games.opponent) = LOWER(opposingTeamName)`. This eliminates false-positive markers when a player name coincidentally matches across unrelated teams (ce-doc-review fix).
  - Recognition marker carries `{ GameDate, Opponent }` only in 1a — no score, no W/L.
- Assemble `ScoutContext{ Team, Roster (with optional RecognitionMarker), CacheAge }`.
- `CacheAge` is the `last_fetched_at` on the `opposing_teams` row.

**Execution note:** Test-first for the orchestrator and the cross-reference query — drive the shapes via tests before implementation.

**Patterns to follow:** `internal/sync/syncer.go` (orchestrator shape with `Now func() time.Time` clock injection, context cancellation). `internal/store/queries.go` (existing query patterns, parameterized SQL).

**Test scenarios:**

> **Note (2026-05-16 retro):** the scenarios below describe the **dormant `CrossReferenceRoster` path** (Fork B revival, not Fork A runtime). Fork A's actual runtime coverage — GameSummaries fetch, opponent_id filtering, opponent-name resolution via `opposing_teams` cache, freshness via `last_fetched_at` — lives in `internal/scout/scout_test.go`. The scenarios are preserved so that Fork B's revival has a starting test contract.

- Happy path: in-memory store seeded with own-team history vs "Eagles 12U" that includes "John Smith"; httptest server returns roster for that team containing "John Smith". `Scout` populates opposing tables and returns ScoutContext with a recognition marker on John Smith pointing to the historical game.
- **Covers AE1 (partial).** Cross-reference returns `RecognitionMarker{ GameDate: "2026-04-15", Opponent: "Eagles 12U" }` — no score field in 1a; Phase 1b adds the score.
- **Dormant scenario — Fork B player-name match path.** Case-insensitive match: "JOHN SMITH" in opposing roster, "john smith" in historical games → marker surfaces. Punctuation-different ("John Smith Jr." vs "John Smith") → NO marker (exact match only). (Originally labeled "Covers AE2"; AE2 cannot ship in Fork A per Requirements Trace.)
- **Team-scoped join (ce-doc-review fix).** Own-team played "Tigers" and faced a "John Smith" there. Now scouting "Eagles 12U" whose roster also has a "John Smith" → NO marker (the John Smith in history played for Tigers, not Eagles). Without team scoping, the marker would falsely surface.
- Cache hit path: pre-populated `opposing_teams` row with `last_fetched_at` < 24h → no API calls issued; ScoutContext returned from cache with cache age in minutes.
- Cache stale path: `last_fetched_at` > 24h → re-fetch triggered.
- `--refresh` flag honored by orchestrator option → forces re-fetch regardless of cache age.
- Invalid UUID format: malformed input → returns `ErrInvalidUUID` (Go-level validation, before any API call).
- Team not found (404): client returns `ErrTeamNotFound` → orchestrator propagates with hint text.
- Network failure during fetch → no partial state committed (transaction rollback verified via test that asserts opposing_teams row absent after failure).
- Cache freshness reported in `CacheAge` (mock clock).
- Empty own-team cache (no games table rows) → cross-reference returns zero markers, ScoutContext renders with roster only, no error.

**Verification:** `go test ./internal/scout/... ./internal/store/...` green. Manual smoke: `go run ./cmd/gamechanger scout <real-team-uuid>` against a populated cache returns a context with at least one recognition marker for a team the user has played.

---

### U7. `scout` cobra subcommand — matchup-history output *(reshaped)*

**Goal:** Wire the user-facing `scout <opponent>` command — argument is opponent name (looked up via `opposing_teams` cache) or opponent UUID. Output is the matchup-history table: last N games vs that opponent with date, home/away, W/L, score. TTY-aware rendering (colored/structured at terminal; plain text when piped); explicit `--format json` for AI/agent consumers; explicit `--refresh` to bypass cache.

**Output example (text format, paste-friendly for AE3):**
```
Matchup vs Eagles 12U (4 games)
2026-04-15  home  L 4-7
2026-03-22  away  W 8-3
2026-02-08  away  W 6-5
2025-11-12  home  L 2-9
```

**Requirements:** R5, R6, R10 (command surface, output, cache behavior).

**Dependencies:** U6 (orchestrator).

**Files:**
- `internal/commands/scout.go` (new — cobra wiring)
- `internal/commands/scout_test.go` (new — uses TestHelperProcess pattern from `verify_test.go`)
- `internal/commands/scout_integration_test.go` (new — end-to-end test: `httptest.Server` returning HAR fixture + in-memory SQLite seeded with own-team history + run `runScout(args)` + assert stdout contains expected recognition marker; pattern matches `internal/sync/integration_test.go`)
- `internal/commands/root.go` (modify — register `newScoutCmd` in `AddCommand` block)
- `internal/format/scout.go` (new — TTY-aware renderer + JSON encoder)
- `internal/format/scout_test.go` (new)

**Approach:**
1. **Argument:** `gamechanger scout <team-uuid>`. Validate via `cobra.ExactArgs(1)` + UUID-format regex. Anything that's not a UUID format → reject with `team-not-found` exit code and hint "expected UUID; slug resolution will land in Phase 1b — for now, find the team UUID by browsing your existing schedule or use `gamechanger refresh` followed by inspecting `cache.db`."
2. **Flags:** `--format human|json` (default human), `--refresh` (force re-fetch).
3. **Renderer:** when format is `human` and `isatty.IsTerminal(os.Stdout.Fd())`, emit colored structured output (team header, roster with markers). When non-TTY (piped/redirected), emit plain text capped to AE3's 500-char limit. When format is `json`, emit `ScoutContext` as JSON via `json.MarshalIndent`. TTY detection injection point: pass `IsTerminal func(uintptr) bool` into the renderer (default to `isatty.IsTerminal`) so tests can mock both branches.
4. **Exit codes:** new typed `scoutExit` mirroring the `parityExit` pattern from U6:
   - 0 `scout-pass`
   - 10 `team-not-found` (invalid UUID or orchestrator returned `ErrTeamNotFound`)
   - 20 `auth-expired` (client returned `gcerr.ErrAuth`)
   - 21 `auth-insufficient-scope` (client returned `ErrAuthInsufficient`)
   - 30 `network-error` (`gcerr.ErrNetwork`)
   - 40 `cache-empty` (user has no own-team data yet; suggest `gamechanger refresh`)

**Execution note:** Test-first for the command's exit-code paths and format-selection logic (TTY vs piped is mockable via the injected `IsTerminal` function).

**Patterns to follow:** `internal/commands/verify.go` (typed exit codes, exit-error suppression of `gamechanger:` prefix when verdict is the output). `internal/commands/auth.go` (multi-subcommand pattern if scout grows). `internal/analytics/progressjson/progressjson.go` (in-process renderer).

**Test scenarios:**
- **Covers AE3.** With format=human, stdout=piped (mock IsTerminal=false): output is ≤500 chars, contains no ANSI escape codes.
- **Covers AE4.** With format=json: output is valid JSON parseable into `ScoutContext`; round-trip preserves all fields including recognition markers.
- TTY mode (mock IsTerminal=true): output contains ANSI escapes; human-readable on terminal.
- Argument missing: `scout` with no args → cobra error, exit 2.
- Invalid UUID: `scout not-a-uuid` → exit 10 with hint text naming UUID expectation.
- Team not found (orchestrator returns `ErrTeamNotFound`): exit 10 with hint "no team data returned — the UUID may be invalid or the team isn't visible to your account; run `gamechanger refresh` first."
- Auth expired: orchestrator returns wrapped `gcerr.ErrAuth` → exit 20 with hint "run `gamechanger auth import` to refresh your token".
- Auth insufficient: orchestrator returns wrapped `ErrAuthInsufficient` → exit 21 with hint "the API requires additional authorization for this team's data; check that your account has access or re-authenticate".
- Network failure: exit 30 with hint to check connectivity.
- Empty own-team cache: orchestrator returns `ErrCacheEmpty` → exit 40 with hint "run `gamechanger refresh` first to populate your team's history".
- `--refresh` flag: orchestrator called with refresh=true; verified via mock.
- **Planned: Covers AE1 end-to-end (integration test) — not landed in Phase 1a.** As written, this scenario would spin up an `httptest.Server` returning a `game-summaries` HAR fixture, seed an in-memory SQLite with own-team games rows including opponent "Eagles 12U", run `runScout(ctx, stdout, stderr, "<team-uuid>", opts)` end-to-end (no mocks below the cobra layer), and assert stdout contains the matchup-history line "we played them 2026-04-15 ... L 4-7". (2026-05-16 retro: the originally drafted scenario asserted on `game_batter_stats` + player-name lines, which was a leftover of the pre-reshape AE2 path — Fork A does not emit player names. `scout_integration_test.go` was **not** created; the cobra→HTTP chain is exercised by the unit-level scout/client tests instead. If end-to-end coverage is wanted, restore this scenario under the Fork A shape above.)

**Verification:** `go test ./internal/commands/... ./internal/format/...` green. Integration test exercises the full real chain (mocks only the HTTP boundary). Manual: `gamechanger scout <real-team-uuid>` returns a populated context; piping through `pbcopy` produces clean text.

---

### U8. Documentation + CHANGELOG + integration smoke

**Goal:** Update the `[Unreleased]` CHANGELOG entry, refresh `docs/research/gc-api-notes.md` cross-references to the new scout-notes doc, and run a final end-to-end smoke against real `~/.gamechanger/cache.db`.

**Requirements:** None directly — closes out Phase 1a.

**Dependencies:** U1–U7.

**Files:**
- `CHANGELOG.md` (modify — Unreleased entry under "Go CLI port" section)
- `docs/research/gc-api-notes.md` (modify — cross-reference to gc-scout-api-notes.md)
- `TODOS.md` (modify if exists — add `GO-X` for Phase 1b plan + Phase 2 TUI plan)
- `README.md` (modify if needed — quick-start example for `gamechanger scout`)

**Approach:**
- CHANGELOG entry summarizes: new `scout` subcommand (Phase 1a), schema v4 (opposing_teams + opposing_roster), Roster API client method, cross-reference recognition markers.
- Manual smoke: `gamechanger scout <real-opposing-uuid>` end-to-end against the user's real cache.db. Document timings (cache hit vs miss) in the CHANGELOG per Success Criteria. Note that the recognition marker omits scores in 1a — that's Phase 1b's job.

**Execution note:** N/A — mostly documentation.

**Test scenarios:**
- N/A — documentation unit. Smoke test is manual and recorded in the CHANGELOG.

**Verification:** `git diff` shows updates to CHANGELOG.md and `docs/research/gc-api-notes.md` cross-reference. Manual smoke output recorded in commit message. `TODOS.md` (or equivalent) has follow-up entries for Phase 1b and Phase 2 plans.

---

## Scope Boundaries

### Deferred for later

*Carried verbatim from origin's "Deferred for later":*

- In-game decision support — live-data refresh and decision-support outputs during a game in progress.
- Tournament / league-wide planning across multiple teams as a coordinated workflow.
- AI/agent integration of the JSON output — the JSON shape ships in 1a but downstream LLM consumption is a separate workstream.
- In-tool note-taking / annotation — output channel for notes remains text messages with coaches.
- TUI editing / modification of any data — read-only in v1 (refers to user-initiated data mutation; internal cache writes by U6 and beyond are not user-edits and are not in scope of this boundary).
- Fuzzy name matching for recognition markers — exact name match (case-normalized) in v1.
- Multi-team / multi-user accounts — single solo coach use case in v1.

### Outside this product's identity

*Carried verbatim from origin's "Outside this product's identity":*

- A general-purpose CLI replica of the GameChanger UI for non-scouting flows.
- Direct integration with iMessage / SMS / coaching-app APIs to push notes automatically.
- A web frontend or mobile app.
- A second visual parity harness comparing TUI output to web UI screenshots.

### Deferred to Follow-Up Work

*Plan-local sequencing — work that this plan defers to separate plans, not non-goals:*

- **Fork B — Mobile-app capture for opposing rosters.** Original brainstorm's AE2 (player-name recognition on opposing rosters) requires endpoints the web/desktop API doesn't expose. Mitmproxy + cert override on a phone could surface the mobile-app endpoints. Larger lift; revisit if matchup-history scout proves valuable and users want the deeper recognition.
- **Fork C — Park scout; promote `/game-summaries` to `progress`/`brief`.** `/game-summaries` returning team-level scores per game is also valuable for existing analytics. Even if scout itself is parked, threading score+W/L into `progress` / `brief` outputs is a smaller, lower-risk delivery path with overlap onto matchup-history value.

- **Phase 1b — Coaches, opposing schedules, scores, slug resolution.** A follow-up plan that resumes U3 (boxscore score extraction + migration v5) and adds:
  - Coaches endpoint discovery + `opposing_coaches` table + `Coaches` client method
  - Opposing schedules endpoint discovery + `opposing_games` table + `OpposingSchedule` client method
  - Score columns (`games.home_score` / `games.away_score`) + boxscore parser extension + backfill mechanism (defer mechanism decision until U1 of 1b confirms data shape)
  - Slug resolution (`scout <slug-or-uuid>` accepting human-friendly slugs derived from the user's upcoming `/teams/{id}/schedule`)
  - Burst-fetch orchestration (three sequential rate-limited calls per scout invocation)
  - Recognition marker score/W/L derivation ("lost 4-2")
  - Pagination handling for opposing schedules (if U1 of 1b confirms paginated responses)
  - Cache freshness coherence for hybrid (burst + lazy) fetch strategy
- **Phase 2 — TUI navigator plan.** A follow-up plan covering R7, R8, AE6, AE7 from the origin: interactive TUI providing scouting-shaped navigation (a strict subset of the web UI's graph, with scout-task annotations as primary content per origin R7/R8 — pure UI parity is explicitly out per origin's identity boundary), lazy-fetch orchestration per screen, cache-age indicators, full keyboard navigation. TUI framework selection (Bubble Tea / tcell / gocui) belongs to that plan.
- **HAR fixture anonymization + committed corpus** — promote from local-only to committed/shared corpus when CI lands or contributor onboarding requires it (mirrors parity-harness plan's CI-deferred posture). **Pre-promotion gate:** the existing anonymizer at `internal/parity/anonymize/anonymize.go` must be extended (or a HAR-specific analog written) to substitute player names, opponent names, and other PII inside HAR response bodies using the same `substitutionMap` pool pattern. Corpus promotion should be gated on a CI check that asserts no committed fixture contains names outside the synthetic pool. Raw response bodies must never enter a shared corpus without this pass.
- **Cross-reference broader sources** — currently only the user's own team's history (cache.db). Broader (prior teams the user coached, league-wide history) is a separate data-source workstream.
- **PII retention TTL on `opposing_roster`** — Phase 1a documents the user-local posture; Phase 1b earns a retention decision before opposing_coaches / opposing_games tables compound the surface.
- **HAR fixture drift detection** — local-only fixtures mean drift surfaces only when a developer re-records. A `make scout-verify-live` opt-in target that hits live endpoints with a known team UUID and runs the parsed-response comparison is a candidate for Phase 1b or independent tooling.

---

## Dependencies / Prerequisites

- **Live `web.gc.com` access** for U1's HAR-capture session. The user is already authenticated for the token-paste flow used by `gamechanger auth import`.
- **A populated `~/.gamechanger/cache.db`** with at least one game where the user's team has played against an opposing team whose roster overlap could be exercised. Already exists in the user's environment.
- **Go 1.26.2** (`go.mod`). No new direct dependencies — `mattn/go-isatty` is already a transitive dep via cobra.
- **`testdata/har/` directory** for per-developer HAR fixtures. Gitignored per Key Decision.

---

## Risk Analysis

| Risk | Likelihood | Impact | Mitigation |
|---|---|---|---|
| Roster endpoint doesn't exist as a separate addressable route (e.g., served inline with team payload) | Low | Medium | U1 decision matrix (a/b/c) explicitly handles this; downstream units adapt to U1's disposition before any U2+ code lands |
| Opposing-team endpoints require stricter auth (per-team-scoped token, signed request) | Medium | High | U1 surfaces auth requirements; `ErrAuthInsufficient` exit code (21) gives the user a clear hint vs the wrong-recovery 30 (network) |
| Team-scoped join misses real prior-matchups due to opponent-name spelling variance ("Eagles 12U" vs "Eagles") | Medium | Low | Acceptable in 1a — false negatives are less costly than false positives; can be tightened in Phase 1b with fuzzy opponent matching if signal warrants |
| Rate limiting hits the single roster call (unlikely — one call per scout invocation) | Very low | Low | Single sequential call inside existing 500ms cadence; existing 429 retry path handles bursts |
| Schema migration v4 incompatible with future Ruby scouting (if scope expands) | Low | Medium | Migration is additive-only; v4+ Go-only is a documented decision; if Ruby ever needs scout tables it adds v5+ in its own namespace |
| HAR fixture drifts from live API over time | Medium | Medium | Local-only fixtures mean each developer refreshes on their own cadence; engine assertion failures surface drift when a developer re-records; doc lifecycle says "re-record when assertions fail" |
| User expects slug-based team lookup (e.g., `scout eagles-12u`); Phase 1a only accepts UUIDs | High initially | Low | U7 explicitly rejects non-UUID input with hint text directing user to Phase 1b for slug support |

---

## Phased Delivery

This plan IS Phase 1a of the broader scouting tool. Within Phase 1a:

- **Phase 1a.1 — Discovery (gate):** U1. Pure investigation; produces HAR + endpoint documentation + a/b/c disposition. Plan halts at the gate if endpoints don't exist or auth is gated.
- **Phase 1a.2 — Foundation:** U2 (schema v4). Independent of U1's endpoint shape; can run in parallel with U1's documentation pass.
- **Phase 1a.3 — Client:** U4 (Roster method). Depends on U1's endpoint shape disposition.
- **Phase 1a.4 — Orchestration:** U6 (scout orchestrator + cross-reference). Pulls together schema + client.
- **Phase 1a.5 — Surface:** U7 (cobra command + TTY-aware renderer).
- **Phase 1a.6 — Closeout:** U8 (CHANGELOG + docs + smoke + TODOS for 1b/Phase 2).

Each phase leaves the repo in a consistent state. Stopping at any phase is fine.

---

## Outstanding Questions

### Resolve Before Implementation

*(none remain — Phase 1a's scope reduction during eng review absorbed prior open questions; Phase 1b's plan will surface its own)*

### Deferred to Implementation

- [Affects U1][Needs research] Exact endpoint path and Accept-header version for opposing-team roster. Resolved at U1 via HAR capture.
- [Affects U6][Technical] Cache freshness TTL — "stale" threshold (24h fixed vs config-driven). Pick during U6 with a default that matches the night-before workflow (24h is the working default).
- [Affects U7][Technical] Plain-text format spec (column widths, max-line for AE3 500-char cap). Pin during U7 via output golden files.
- [Affects U7][Technical] Whether `team-not-found` exit code should distinguish "invalid UUID format" from "valid UUID but team not in API." Code 10 covers both in 1a; revisit if AI-loop usage shows the distinction matters.

---

## Open Questions Surfaced by 2026-05-16 ce-doc-review

*Post-implementation retro review (PR #4 shipped 2026-05-16). Doc-drift fixes and the HAR-scrub procedural update from that pass have been applied in place above. The items below are deferred decisions for Phase 1b's planning session or for an immediate follow-up cleanup.*

### Scope / Fork B disposition

- **[B1] Concrete re-evaluation trigger for Fork B.** Today the trigger is "revisit if matchup-history scout proves valuable" — an indefinite condition. Set a date or signal (e.g., "if Fork B not started by 2026-08-15, file a removal ticket"). Without one, `CrossReferenceRoster` and `opposing_roster` become archaeology.
- **[B2] Disposition for unused `opposing_roster` table.** Keep dormant, drop in migration v5, or wire Fork B before Phase 1b's `opposing_coaches`/`opposing_games` compound the surface? Decision should land before v5 ships.

### Product premise / identity

- **[D1] Re-validate the night-before-value premise** (brainstorm-level) before Phase 1b extends scout's surface. The claim that matchup-history preserves the night-before value is plan-introduced, not origin-validated.
- **[D2] Amend or supersede the origin brainstorm** (`docs/brainstorms/2026-05-15-scouting-tui-requirements.md`) to reflect that the validated product is matchup-history, not roster recognition. AE1 was silently redefined from cross-reference accent to primary surface.
- **[D3] Strategic case for Fork A vs Fork C** (`/game-summaries` as columns inside `progress`/`brief`). What makes scout-as-product distinct from `progress --vs-opponent`?
- **[D4] Identity boundary** between scout and `progress`/`brief`. Phase 1b's slug resolution and score backfill may belong in `progress` rather than scout.

### Security / PII

- **[E1] UUIDs in `cmd/scout-probe/main.go` git history** (added `15564ee`, deleted `d36af56`). **Resolved 2026-05-16: accept-as-leaked, sanitize forward.** Repo confirmed public (`joshRpowell/gamechanger`). UUIDs are opaque GameChanger identifiers (not credentials) but identify the user's youth team. History rewrite was considered but rejected: mirrors and existing clones may already have the data, and the threat model is correlation/inference rather than direct exploit. Forward mitigation landed in `CLAUDE.md` "Working with the GameChanger API" — prohibits hardcoded UUIDs/opponent IDs in committed code going forward, requires env-var reads for probe binaries.
- **[E2] Minors'-PII consent model + deletion path.** Add a `scout --clear-cache <uuid>` (and/or `--clear-all`) command before Phase 1b's `opposing_coaches` / `opposing_games` tables compound the PII surface. COPPA/CPRA territory.

### Phase 1a behaviors to re-examine in 1b

- **[E4] Proximity-aware cache freshness.** Replace uniform 24h TTL with a shorter TTL when a scheduled game against this opponent is within N hours. 24h decays freshness exactly when the night-before workflow consults it.
- **[E5] Content-length / truncated-response validation** in U4 client or U6 orchestrator. A 200 with a partial body currently parses to a smaller-than-expected slice and gets cached as complete for 24h.
- **[E6] Split exit code 10** into 10 (input-malformed) + 11 (resource-not-found) before AE4's AI-loop consumers cement the contract. Reversing later is backward-incompatible.

### Plan-doc hygiene for next time

- **[E7] Trim Phase 1b's 10-item enumeration** in `Deferred to Follow-Up Work` to a single forward pointer (`see Phase 1b plan once written`). Phase 1b's plan author should decide scope after that plan's own discovery work.

---

## GSTACK REVIEW REPORT

| Review | Trigger | Why | Runs | Status | Findings |
|--------|---------|-----|------|--------|----------|
| CEO Review | `/plan-ceo-review` | Scope & strategy | 0 | — | not run (premise validated via `/ce-brainstorm`) |
| Doc Review | `/compound-engineering:ce-doc-review` | Coherence + feasibility + security + adversarial | 1 (2026-05-15) | ISSUES | 6 fixes applied; 10 decisions surfaced (6 P1) — absorbed by eng-review scope reduction |
| Eng Review | `/plan-eng-review` | Architecture & tests (required) | 1 (2026-05-15) | CLEAR | mode: SCOPE_REDUCED, 2 issues found (0 critical gaps); plan reduced from 8 units → 6 units, ~20 files → ~12, 2 new packages → 1 |
| Design Review | `/plan-design-review` | UI/UX gaps | 0 | — | n/a — CLI tool, no UI (TUI deferred to Phase 2 plan) |
| Outside Voice | `/codex review` | Independent 2nd opinion | 0 | — | skipped — ce-doc-review's 4-persona pass + eng review provided multi-model scrutiny |

- **UNRESOLVED:** 0 across all reviews
- **VERDICT:** ENG CLEARED (SCOPE_REDUCED) — ready to implement. ce-doc-review findings absorbed by Phase 1a slicing (Phase 1b plan picks up the deferred surface). No external blockers.

