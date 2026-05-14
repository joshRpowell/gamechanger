---
date: 2026-05-14
topic: gamechanger-go-port-direction
focus: "does it make sense to port over the analytics layer? or just start with a plain vanilla implementation that gets past the auth."
mode: repo-grounded
---

# Ideation: Gamechanger Go port direction

## Grounding Context

### Codebase
- Ruby gem (`lib/`, `exe/gamechanger`, 11 commands) + parallel Go port on `experiment/cli-printing-press` worktree.
- Shipped on the Go side (PR #3): foundation, gcerr, config, SQLite store with migrations 1-3, client (4 endpoints), parser, syncer, setup/refresh/version/auth-import/auth-status commands. Smoke-tested against live API (26 games / 67 outings / 272 batter rows synced in ~22s).
- NOT yet ported: analytics (pitch_rules 41 LOC, lineup_optimizer 85 LOC, development_arc 144 LOC, pre_game_brief 77 LOC — **347 LOC total**), three formatters (table 499 LOC, json 285 LOC, markdown 499 LOC), 8 commands (brief, plan, lineup, equity, hitting, progress, availability, pitches).
- Analytics layer is pure-logic, zero I/O, zero hidden coupling. Direct port is feasible.

### User-named references (constraint)
- User's question: "does it make sense to port over the analytics layer? or just start with a plain vanilla implementation that gets past the auth."
- TODOS.md GO-1..GO-7 already names the open work; the user is asking whether to commit to that plan or pivot.

### Past learnings
- `docs/research/gc-api-notes.md` is stale — still documents the OLD `{email,password}` auth contract.
- Recent watch-feature plan: 67% (4 of 6) of architectural decisions revised by Codex outside-voice.
- Repo convention: 100% line / 85%+ branch coverage on the Ruby side. Go port currently 0% on client + commands.
- No prior Ruby→Go port retrospectives anywhere in the user's gstack projects.
- The "if Go survives a season, retire Ruby" framing is already in the CHANGELOG. Direction is set; question is sequencing.

### External context
- **Parse migration (Charity Majors)**: 2 years of parallel operation, sequenced minor services → push backend → core API endpoint-by-endpoint. Transport stabilized first; domain logic last.
- **OneSignal migration**: Single-endpoint port with Scientist-gem shadow traffic. 50% hardware deprovisioning on retirement.
- **Strangler fig pattern**: explicit warning about hybrid-forever stalls when teams start without retirement plan. "Remaining modules are good enough" is the documented failure mode.
- **yt-dlp**: treats `--cookies-from-browser` as PRIMARY auth path, not fallback.
- **GitHub gh CLI**: `gh auth login --with-token` first-class since gh 1.0. Token-paste is a documented interface.
- **HMAC RE shelf life**: community consensus is "temporary inconvenience" — every rotation breaks the client. Session reuse breaks only when session format changes (rare).
- **Go terminal libs**: `xlab/tablewriter` is a direct port of Ruby's terminal-table gem. `pterm` has sparklines + tables standalone.
- **No Go baseball analytics libs exist.** Domain logic is greenfield.

## Topic Axes
- A. Port completeness — finish Ruby→Go feature parity
- B. Auth resolution — paste-token canonical vs. RE the signing vs. hybrid
- C. Test/quality posture — bring Go test coverage to Ruby parity
- D. New-feature direction — invest in NEW capabilities in Go vs. only parity
- E. Documentation / institutional state — gc-api-notes refresh, auth-break retro, port retrospective

## Ranked Ideas

### 1. Build the parity-verify harness FIRST; port analytics behind it
**Description:** The 26 games / 67 outings / 272 batter rows already in the smoke-tested SQLite are a ready-made golden corpus. Build `gamechanger verify` (or `make parity-check`) that runs `gc brief` in both Ruby and Go against the same DB and diffs output. Every subsequent analytics port lands with a byte-equivalent parity proof. "If Go survives a season, retire Ruby" becomes a single command instead of a vibes call.
**Axis:** A + C
**Basis:** *external:* OneSignal's Scientist-gem shadow-traffic migration (50% hardware deprovisioning at retirement); Parse's two-year parallel-running validation. Pure-logic analytics is the unique substrate where penny-perfect ledger reconciliation actually works (no flakiness, no network).
**Rationale:** Solves three problems at once — quality posture for the analytics port, an explicit retirement criterion, and a sequencing forcing function.
**Downsides:** Adds 1-2 days before the first analytics line ships in Go. Requires Ruby and Go to both run during the port (already true).
**Confidence:** 85%
**Complexity:** Medium
**Status:** Unexplored

### 2. Refresh `gc-api-notes.md` + write the auth-break retro before porting more
**Description:** 30-minute task. Replace the auth section in `gc-api-notes.md` with the actual current contract (MFA, gc-signature, paste-token workflow). Add `docs/research/auth-break-retro.md` capturing why the signing flow is out of reach and why session-token reuse is the supported path.
**Axis:** E
**Basis:** *direct:* grounding flags `docs/research/gc-api-notes.md` is stale — still documents the bare `{email,password}` contract that broke. "Cheapest update in this search space."
**Rationale:** Next session that starts with "why is auth failing?" reads the doc and forms the wrong hypothesis. Cost is minutes; debt prevention is hours. Every other survivor implicitly depends on this being current.
**Downsides:** Not glamorous. Easy to defer in favor of code.
**Confidence:** 95%
**Complexity:** Low
**Status:** Unexplored

### 3. Promote `auth import` from workaround to canonical interface
**Description:** Rebrand in `--help` and README: paste-from-browser is the supported path. Stop framing as workaround. The 1-hour TTL cliff becomes a UX iteration target (refresh-token UX, auto-import) rather than an outstanding bug.
**Axis:** B
**Basis:** *external:* yt-dlp's `--cookies-from-browser` and `gh auth login --with-token` both ship browser-token-import as PRIMARY auth path, not fallback. HMAC RE shelf-life: every signing-scheme rotation breaks the client; session formats change rarely.
**Rationale:** Closes the open question of "should we reverse-engineer gc-signature?" with documented industry precedent. Names what's actually working as such.
**Downsides:** Locks out an alternate path (full signed-auth implementation). Reversible.
**Confidence:** 90%
**Complexity:** Low
**Status:** Unexplored

### 4. Define the v1.0 surface explicitly before deciding what to port
**Description:** 10-line `docs/research/go-port-v1-surface.md`. Three columns: command, v1.0 status (in/cut/Ruby-only), reasoning. The "port analytics?" question answers itself: if `brief` is in v1.0, analytics ships; if not, it doesn't.
**Axis:** D
**Basis:** *reasoned:* the user's question conflates sequencing with scope. The 8 unported commands have no order until v1.0 names them in or out. Without that decision, every "what next?" question is premature.
**Rationale:** Eliminates "remaining modules are good enough" stall — there's a deliberate cut list, not a backlog. Reframes the binary "port or skip" into a product decision.
**Downsides:** Closing v1.0 scope feels premature with auth UX still unsettled.
**Confidence:** 80%
**Complexity:** Low
**Status:** Unexplored

### 5. Game-day validation gate: don't port more until the current Go binary has handled one real weekend
**Description:** Set an explicit gate: no more port work on this branch until you've personally run `gamechanger refresh` between two innings of a real game and it didn't bite. Write what broke (or that nothing did) in the auth-break retro from idea 2.
**Axis:** A
**Basis:** *reasoned:* organ transplant — confirm perfusion before grafting; renovation while occupied — don't open the next floor; convoy MVC — current state is mission-complete, harden it. The smoke test was 22 seconds against the live API; real Saturday usage will surface things synthetic tests miss (mid-game token expiry, 429s, partial responses).
**Rationale:** Avoids sinking 1-2 weeks into analytics work on top of an auth surface that hasn't proven it survives game conditions.
**Downsides:** Schedule-dependent (waits for next game). Could be a week of dead time.
**Confidence:** 75%
**Complexity:** Low (it's a wait, not a build)
**Status:** Unexplored

### 6. Run outside-voice (Codex) review on this strategic decision before committing
**Description:** 20 minutes. Pipe this ideation doc through `/codex` consult mode. Ask: "Is this list missing the right answer? Are you confident in idea 1 as the bigger-than-rest leverage move?"
**Axis:** A
**Basis:** *direct:* grounding observed 67% revision rate on the recent watch-feature plan under Codex review (4 of 6 architectural decisions). Same class of decision, same in-repo evidence base.
**Rationale:** Track-record-supported cheap insurance.
**Downsides:** Adds a step. Possible that Codex agrees and you spent 20 min for confirmation.
**Confidence:** 85%
**Complexity:** Low
**Status:** Unexplored

### 7. Queue the analytics port as an AI-loop background task; user time goes to new Go-native features
**Description:** Once idea 1 (parity-verify) lands, the analytics port is no longer hand-crafted. Set up a Codex/Claude loop with `gamechanger verify` as success criterion; let it port one module per session against fixture replay. User invests human time in watch v1 (P1 in TODOS), ask (P2), parents (P2).
**Axis:** A + D
**Basis:** *reasoned:* pure-logic 347 LOC + zero I/O + existing Ruby tests as oracle = ideal LLM port task. The analytics is the easiest code in the gem to translate.
**Rationale:** Inverts who is doing what. AI is uniquely good at "translate pure-logic code with golden output as oracle"; humans are uniquely good at "decide what new capability matters."
**Downsides:** Requires idea 1 to exist as a forcing function. AI loops can produce code that *passes verify* but isn't idiomatic Go — needs a final human review pass.
**Confidence:** 70%
**Complexity:** Medium
**Status:** Unexplored

## Rejection Summary

41 of 48 candidates were cut. Highlights:

| # | Idea | Reason Rejected |
|---|------|-----------------|
| I1 | Drop analytics port entirely — Ruby keeps brains, Go keeps pipes | Contradicts CHANGELOG retire-Ruby goal; subject-replacement-adjacent |
| I8 | Thin Go orchestrator wraps Ruby gem | Requires Ruby install everywhere; defeats half the Go-port purpose |
| R1 | Each language has a job (Ruby=REPL, Go=shipped) | Same shape as I1; preserves dual-stack indefinitely against stated retirement |
| R2 | Plugin-host architecture; analytics as plugins | Over-engineered for single-user CLI |
| R6/C7 | Extract language-neutral spec first | High cost vs. value for solo project |
| A8 | Cave-diving thirds — only port if 3x capacity | Redundant with idea 1's parity-verify harness |
| A2 | Aircraft type rating — force Go-exclusivity | Premature; `auth import` already Go-only |
| P6 | SQLite migration brick risk | Real concern but inactionable until a Go-side migration is proposed |
| P5 | Dual-stack CHEATSHEET | Tactical/low ambition; fails meeting-test |
| C1 | 1-hour vanilla — auth + JSON only | Subsumed by idea 4 |
| C3 | Official token tomorrow | Reveals analytics-as-asset but answer subsumed by idea 1 |
| C4 | gc.com blocks next week — 3 auth fallbacks | Speculative; failure mode hasn't materialized |
| C5 | Ruby retirement Sunday — analytics fastest | Subsumed by idea 1 + idea 7 cluster |
| I3 | Remove formatters; emit JSON only | Too aggressive — product positioning is "coaching analytics suite" |
| I4 | Cookies-from-browser auto-extract | Cross-OS Chrome/Safari decrypt is a project; defer |
| I5 | Fixture replay instead of unit tests | Subsumed by idea 1 |
| I7 | Generate gc-api-notes from --dry-run | More engineering than the simple doc refresh (idea 2) |
| R4 | Coverage isn't the right bar | Subsumed by idea 1 |
| R8 | Set deliberate v1.0-rc.N version | Tactical follow-up to idea 4; not its own strategy |
| L5 | Port SQLite read accessors first | Already shipped |
| L6 | Adopt tablewriter substrate | Tactical library choice; follows from porting decision, not strategic |
| L7 | Write port retro NOW | Subsumed by idea 2 |
| P3 | Zero coverage on client + commands | Subsumed by idea 1 |

Full 48-candidate roster and per-frame breakdown lives in `/tmp/compound-engineering/ce-ideate/05a68ab3/raw-candidates.md` for the session.

## Sequencing if acting on all 7

1. **Idea 2** (30 min) — refresh API doc + write auth-break retro
2. **Idea 4** (1 hour) — write v1.0 surface decision doc
3. **Idea 6** (20 min) — Codex review on idea 4
4. **Idea 3** (30 min) — rebrand `auth import` in docs/help
5. **Idea 5** — wait for next real game weekend
6. **Idea 1** (1-2 days) — build `gamechanger verify` harness
7. **Idea 7** (loop) — queue analytics port as AI-loop work
