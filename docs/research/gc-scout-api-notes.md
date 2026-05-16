# GameChanger scout API discovery — U1 findings (2026-05-15)

Probe artifact: `cmd/scout-probe/main.go` (throwaway, ran once against
`api.team-manager.gc.com` using the user's gc-token captured from web.gc.com).
Raw + pretty responses dumped to `testdata/har/` (gitignored).

All endpoints respond `application/json; charset=utf-8`. `Accept: application/json`
is sufficient — no vendored media types required for any probed endpoint.

## Plan-blocking finding

**The web/desktop API surface does NOT expose opposing-team rosters.** The
brainstorm's core premise — fetch opposing roster + cross-reference names — is
broken against this API. Only the mobile app has access to opposing-team
player lists (the web UI explicitly says "Download the app from here").

`a/b/c` disposition from the plan: **None of the above applies cleanly.** The
opposing-team endpoint exists but returns only metadata (no roster data
inline, no roster via a separate addressable path, no pagination needed).

## Endpoint inventory

### `/me/teams` (200, 12780B)

User's full team list, including archived. Each team carries:
- `id` (UUID), `public_id` (short slug like `wGP47FexatoQ`), `name`
- `age_group`, `city`, `country`, `competition_level`, `ngb`, `archived`
- `record` (wins/losses/ties), `season_name`, `season_year`
- `created_at`, `settings`, `paid_access_level`

**Plan use:** already covered by existing `client.Teams()`. Confirmed
shape — bare array.

### `/teams/{team_uuid}/players` (200, 4783B for current team)

**YOUR OWN team's roster.** Returns bare array of player objects:
```json
{
  "id": "1f45f31f-...",
  "first_name": "Asher",
  "last_name": "Lima",
  "number": "3",
  "person_id": "1f45f31f-...",
  "status": "active",
  "team_id": "b4ded52d-...",
  "bats": {
    "batting_side": "right",
    "throwing_hand": "right",
    "player_id": "..."
  }
}
```

**Plan use:** does NOT accept an opposing-team UUID — only the requester's
own teams. Adds value: structured roster metadata (jersey number, batting
side, throwing hand) the cache.db doesn't currently carry. Future:
populate richer player records for own-team stats display.

### `/teams/{team_uuid}/opponent/{opp_uuid}` (200, 220B) — **scope-blocker**

Returns minimal opponent metadata only:
```json
{
  "is_hidden": false,
  "name": "11U Driftwood Dragons",
  "owning_team_id": "b4ded52d-...",
  "progenitor_team_id": "ab77a075-...",
  "root_team_id": "006e1663-..."
}
```

No roster, no coaches, no schedule, no players. Just the opponent's
display name + tracking IDs. The 14 calls we observed during web-app load
are bulk metadata fetches to populate the schedule's opponent-name labels.

**Plan use:** can still resolve opp_uuid → display name (useful when
building scout-friendly output from the user's own game history). Cannot
power the original "scan opposing roster for familiar names" workflow.

### `/teams/{team_uuid}/users` (200, 8423B)

**YOUR OWN team's staff/parents/access list.** Bare array of:
```json
{
  "id": "2e11d9b9-...",
  "first_name": "Adam",
  "last_name": "Cohen2",
  "email": "adam@aecohen.com",
  "status": "active"
}
```

Pagination via `?start_at=50` observed in network log. Includes coaches,
parents, and anyone with team access (~50+ for an active team). No
opposing-team variant.

**Plan use:** future feature surface — display own-team staff. Not in
scope for any current scout unit.

### `/teams/{team_uuid}/game-summaries` (200, 18690B) — **Phase 1b gold**

**Game history with scores at the team level.** Bare array of game summaries:
```json
{
  "event_id": "3fa11cab-...",
  "game_status": "completed",
  "home_away": "home",
  "opponent_team_score": 8,
  "owning_team_score": 9,
  "last_scoring_update": "2026-03-15T16:42:18.702Z",
  "game_stream": {
    "game_id": "3fa11cab-...",
    "opponent_id": "c47f1ca1-...",
    "home_away": "home",
    "scoring_user_id": "...",
    "game_status": "completed",
    ...
  },
  "sport_specific": {
    "bats": {
      "inning_details": {"half": "bottom", "inning": 5},
      "total_outs": 27
    }
  }
}
```

**Plan use (Phase 1b):** This is a much cleaner source for AE1's "lost 4-2"
recognition format than boxscore parsing. Single endpoint per team returns
all games with `opponent_team_score`, `owning_team_score`, `home_away`, and
`opponent_id`. Phase 1b should use this instead of extending the boxscore
parser as the original plan assumed.

## Bonus discovery — public game-stream details (line scores)

From SPA navigation capture earlier: `/public/game-stream-processing/{event_id}/details?include=line_scores`
returns inning-by-inning + final score data. Requires the Accept header
`application/vnd.gc.com.public_team_schedule_event_details+json; version=0.0.0`.

Per-game data shape: `{score: {team, opponent_team}, line_score: {team:
{scores, totals}, opponent_team: {scores, totals}}, opponent_team: {name,
avatar_url}, home_away, game_status}`. Alternative source for Phase 1b
score data — game-summaries (above) is likely the cleaner single-call shape.

## What this means for the plan

The Phase 1a brainstorm assumed `/teams/{opp_uuid}/players` or
`/teams/{my_team}/opponent/{opp_uuid}/players` would exist. **Neither
does.** Possible paths forward (decision belongs to /ce-brainstorm
re-engagement, not this discovery doc):

1. **Reshape Phase 1a as "matchup history scout"** — given an opponent
   name or UUID, surface all prior games against them with scores, W/L,
   and dates. No opposing-roster lookup. Drops AE2 (player-name match).
   The "who do we know" recognition narrative becomes "who have we played
   recently and what happened" — still pre-game-prep useful, smaller in
   scope.
2. **Mobile-app capture for opposing-roster endpoint** — would require
   mitmproxy + cert override on phone. Bigger lift; uncertain payoff.
3. **Park the scout tool** — accept that the API doesn't support the
   workflow as designed; focus on Phase 1b's score-data feature for the
   existing analytics commands instead.

## Probe details

- Team UUID probed: `b4ded52d-56a3-4429-974a-dc7485669a8c` (Plantation
  Stars 11U Blue)
- Opponent UUID probed: `006e1663-c91d-4d64-a5a4-5a25b31fe4d7` (11U
  Driftwood Dragons)
- Headers sent: `Accept: application/json`, `gc-token`, `gc-device-id`,
  `gc-app-name: web`, `Origin: https://web.gc.com`, `Referer:
  https://web.gc.com/`. All five endpoints accepted these unmodified.
- Probe binary: `cmd/scout-probe/main.go` — delete after planning
  decision lands.
