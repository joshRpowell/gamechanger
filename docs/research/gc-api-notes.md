# Gamechanger API Notes

Reverse-engineered from `lib/gamechanger/client.rb` and the parser files.
The API is not publicly documented — update this file whenever you discover
new behavior or confirm uncertain shapes.

**Base URL:** `https://api.team-manager.gc.com`

**See also:** [`gc-scout-api-notes.md`](./gc-scout-api-notes.md) — scout-specific
endpoint inventory documented during U1 of the scout Phase 1a plan
(2026-05-15). Covers `/teams/{uuid}/players`, `/teams/{uuid}/users`,
`/teams/{uuid}/opponent/{opp_uuid}`, `/teams/{uuid}/game-summaries`, and
the discovery that the web/desktop API does not expose opposing-team
rosters (only the mobile app does).

---

## Authentication

### `POST /auth`

Authenticates with email + password. Returns a short-lived JWT stored as
`gc-token` (not a standard `Authorization: Bearer` token).

**Request headers:**

```
Content-Type: application/json
gc-app-name: web
gc-device-id: <32-char hex string, generated once per installation>
Origin: https://web.gc.com
Referer: https://web.gc.com/
User-Agent: Mozilla/5.0 (Macintosh; ...)
```

**Request body:**

```json
{ "email": "coach@example.com", "password": "secret" }
```

**Response (200):**

```json
{
  "token": "<jwt>",
  "expires": 1234567890
}
```

- `token` is a JWT string used in subsequent requests as the `gc-token` header.
- `expires` is a Unix timestamp (seconds). The gem caches the token in
  `~/.gamechanger/session` as `<token>|<expires>` and reuses it until expired.

**Error (401):** Authentication failed — token is cleared from cache.

**Rate limiting (429):** The gem waits 5 seconds and retries once before
raising `NetworkError`.

---

## Teams

### `GET /me/teams`

Returns all teams for the authenticated user.

**Accept header (required):**

```
application/vnd.gc.com.team:list+json; version=0.10.0
```

Using `application/json` here returns a different (or empty) response shape.

**Response shape — UNCONFIRMED:**

The response shape has not been confirmed against a live API response. The gem
handles three defensive cases:

```ruby
# Case 1: bare array
[{ "id": "uuid", "name": "Mustangs", "slug": "wGP47FexatoQ" }, ...]

# Case 2: wrapped in { "teams": [...] }
{ "teams": [...] }

# Case 3: wrapped in { "data": [...] }
{ "data": [...] }
```

**Team object field names — UNCONFIRMED:**

The short identifier used as the boxscore response key is accessed as:

```ruby
team['slug'] || team['short_id']
```

It is not confirmed whether the field is `slug`, `short_id`, or another name.
This value is stored in config as `team_slug` and must match the key returned
by the boxscore endpoint (see below).

> **TODO:** Confirm the `/me/teams` response shape and the slug field name by
> inspecting a live response. Update `setup` in `lib/gamechanger/cli.rb`
> and document the confirmed shape here.

---

## Schedule

### `GET /teams/:team_uuid/schedule?fetch_place_details=true`

Returns all scheduled events for the team. Confirmed — this is the primary
sync endpoint called on every `gamechanger pitches` or `gamechanger refresh`.

**Response (200) — confirmed bare array:**

```json
[
  {
    "event": {
      "id": "game-uuid",
      "event_type": "game",
      "status": "completed",
      "title": "vs Eagles",
      "start": {
        "datetime": "2026-03-01T14:00:00Z",
        "date": "2026-03-01"
      }
    },
    "pregame_data": {
      "opponent_name": "Eagles",
      "home_away": "home"
    }
  },
  {
    "event": {
      "id": "practice-uuid",
      "event_type": "practice",
      ...
    },
    "pregame_data": null
  }
]
```

**Notes:**
- The array mixes games and practices. Filter with `event.event_type == "game"`.
- `event.start.datetime` is ISO 8601. The date is extracted by splitting on `T`.
  Full-day events may use `event.start.date` instead.
- `event.status` values seen: `"completed"`, `"scheduled"`, `"canceled"`.
  The gem normalizes these — see `Syncer#normalize_status`.
- `pregame_data` may be `null` for practices or events without a scheduled opponent.

**Wrapped hash shape** (defensive fallback, not confirmed in prod):

```json
{ "schedule": [...] }   // or
{ "events":   [...] }   // or
{ "data":     [...] }
```

---

## Boxscore

### `GET /game-stream-processing/:game_uuid/boxscore`

Returns pitcher and batter stats for a single completed game. The response is
keyed by **team slug** (the short identifier stored in `config.yml` as
`team_slug`).

**Response (200) — confirmed structure:**

```json
{
  "<team_slug>": {
    "players": [
      {
        "id": "player-uuid",
        "first_name": "Alice",
        "last_name": "Smith",
        "number": "12"
      }
    ],
    "groups": [
      {
        "category": "pitching",
        "extra": [
          {
            "stat_name": "#P",
            "stats": [{ "player_id": "player-uuid", "value": 65 }]
          },
          {
            "stat_name": "TS",
            "stats": [{ "player_id": "player-uuid", "value": 42 }]
          },
          {
            "stat_name": "BF",
            "stats": [{ "player_id": "player-uuid", "value": 19 }]
          }
        ],
        "stats": [
          {
            "player_id": "player-uuid",
            "stats": { "IP": 4.333, "H": 2, "R": 1, "ER": 1, "BB": 1, "SO": 5 }
          }
        ]
      },
      {
        "category": "lineup",
        "stats": [
          {
            "player_id": "player-uuid",
            "stats": { "AB": 3, "H": 2, "BB": 0, "K": 1 }
          }
        ]
      }
    ]
  }
}
```

**Pitching group — `extra` stat names:**

| `stat_name` | Meaning | Used by |
|-------------|---------|---------|
| `#P` | Total pitches thrown | `BoxscoreParser` |
| `TS` | Total strikes | `BoxscoreParser` |
| `BF` | Batters faced | Not currently used |

**Pitching group — `stats` array:**

| Field | Type | Notes |
|-------|------|-------|
| `IP` | Float | Innings pitched as decimal (4.333 = 4⅓). Stored as-is. |
| `H`, `R`, `ER`, `BB`, `SO` | Integer | Not currently stored. |

**Lineup group — `stats` array:**

| Field | Type | Notes |
|-------|------|-------|
| `AB` | Integer | At-bats. Used to filter `at_bats > 0`. |
| `H` | Integer | Hits |
| `BB` | Integer | Walks (base on balls) |
| `K` | Integer | Strikeouts |

**Notes:**
- The response is keyed by `team_slug`. If the slug is wrong the gem raises
  `APIShapeError`.
- Players not in `players[]` are silently skipped.
- The `lineup` group may be absent for games not yet scored in GC's system —
  `BatterStatsParser` returns `[]` in that case.

---

## Rate limiting

- The gem sleeps 0.5 seconds between boxscore requests (`Client::RATE_LIMIT_SLEEP`).
- On a 429 response the gem waits 5 seconds and retries once (`Client::RETRY_SLEEP`).

---

## Headers sent on every request

| Header | Value |
|--------|-------|
| `gc-token` | JWT from `/auth` (omitted if unauthenticated) |
| `gc-app-name` | `web` |
| `gc-device-id` | 32-char hex, generated once per install, persisted in `config.yml` |
| `Origin` | `https://web.gc.com` |
| `Referer` | `https://web.gc.com/` |
| `User-Agent` | Firefox/macOS UA string |
| `Content-Type` | `application/json` |

---

## Known unknowns

- `/me/teams` response shape (bare array vs wrapped) — needs live verification
- Team object slug field name (`slug` vs `short_id`)
- Whether `/teams/:uuid/schedule` accepts a `season=YYYY` query param
- All fields in the `event` object beyond what's currently used
- Full shape of the `pregame_data` object

---

## Boxscore additional groups (probe 2026-05-20)

**Probed:** one completed game (final state), via `GET /game-stream-processing/{game_id}/boxscore` with the standard `gc-token` + `gc-app-name: web` headers. Probe artifact: `testdata/har/boxscore-probe-1.json` (gitignored).

**Disposition: (b) — present in unexpected shape.**

Fielding/defensive position data **is** in the boxscore response we already consume. It is **not** in a separate `fielding` group as initially hypothesized. It is in the `player_text` field on each row of the existing `lineup` group's `stats[]` array. The `BoxscoreParser` currently parses everything else on these rows (`AB`, `H`, `BB`, `SO`) but discards `player_text`.

### Groups inventory

The top-level response is keyed by `team_slug`. Each team object has exactly two keys: `groups` and `players`. The `groups[]` array contains exactly two entries:

| `category` | Notes |
|---|---|
| `lineup` | Batter stats per player; `player_text` carries position-stint history. |
| `pitching` | Pitcher stats per player; `extra[]` carries `WP`, `#P`, `TS`, `BF`. |

No other categories appear. There is no `fielding`, `defense`, `defensive_innings`, or `position` group.

### `lineup.stats[].player_text` shape

Comma-separated position codes in parentheses, in the **order** the player occupied them across innings. Standard baseball codes: `P, C, 1B, 2B, 3B, SS, LF, CF, RF, DH, EH`.

Examples (sanitized from probe):

| `player_text` | Meaning |
|---|---|
| `(2B)` | Played 2B the entire game (single stint). |
| `(SS, P)` | Started at SS, moved to P (one position change). |
| `(1B, 2B, 1B, P)` | 1B → 2B → 1B → P across four stints. |
| `(LF, RF, 3B)` | LF → RF → 3B. |
| `` (empty) | Did not take the field — bench / non-starter / pinch hitter. |

**Granularity:** position-stint, not per-inning. The response does not carry inning numbers per stint. The number of comma-separated values is the number of position changes plus one. Two stints does not necessarily mean innings 1–3 then 4–6 — the timing is unrecoverable from this field alone.

**Per-row fields confirmed:**

```jsonc
{
  "player_id": "<uuid>",
  "player_text": "(SS, P)",   // ← position stint history
  "is_primary": true,          // appears on lineup rows only; semantics unconfirmed
  "stats": { "AB": 3, "R": 0, "H": 0, "RBI": 1, "BB": 0, "SO": 0 }
}
```

### Other findings from the same probe

- `pitching.extra[]` carries pitch-count aggregates (`#P`, `TS`, `BF`, `WP`) as a sibling of `stats[]` — already consumed by the existing parser for `#P` and `TS`. No `defensive_innings` field anywhere; this answers item 3 of the Phase 0 watch-probe TODO negatively for the completed-game case.
- `players[]` carries `{first_name, last_name, id, number}` only — no position field on the roster object.
- `pitching.stats[].player_text` is always `""` — position data does not appear in the pitching group.
- Response is keyed by `team_slug` for both teams in the game (own team UUID and opponent slug), so positions for both sides are available from a single boxscore call. This is the same channel the dormant `opposing_roster.position` column (Go side) could be backfilled from.

### Implications

- **No new endpoint is needed** to acquire per-game fielding positions. Extend `BoxscoreParser` to surface `player_text` on lineup rows.
- **Per-inning fielding is still unknown.** This probe was a completed game; the live-state question (whether `player_text` updates incrementally during a game, or only finalizes) is still open and belongs to the Phase 0 watch probe.
- **Multi-position players are first-class** in the source data. Storage and formatters should not assume one player → one position per game.
- **Follow-up brainstorm should now fire** for the parser extension + storage decision (per-stint list vs primary-position-only) + first formatter unlock. See parent ideation `docs/ideation/2026-05-20-fielding-positions-data-acquisition.md` — disposition (b) routes there.
