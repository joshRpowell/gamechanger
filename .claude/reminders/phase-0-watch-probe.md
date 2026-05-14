🚨 BLOCKING TODO — Run before any `watch` implementation

Phase 0 of the watch plan requires validating the live Gamechanger boxscore
API contract against a real in-progress game. This MUST complete before any
code is written for the watch bundle.

During the next live game you have access to, run:

  TOKEN=$(awk '{print $1}' ~/.gamechanger/session | cut -d'|' -f1)
  GAME_ID=<the in-progress game UUID>
  curl -H "gc-token: $TOKEN" \
       -H "gc-app-name: web" \
       -H "Accept: application/json" \
       "https://api.team-manager.gc.com/game-stream-processing/$GAME_ID/boxscore" \
       | jq . > /tmp/probe-1.json
  sleep 30
  curl -H "gc-token: $TOKEN" \
       -H "gc-app-name: web" \
       -H "Accept: application/json" \
       "https://api.team-manager.gc.com/game-stream-processing/$GAME_ID/boxscore" \
       | jq . > /tmp/probe-2.json
  diff /tmp/probe-1.json /tmp/probe-2.json

Confirm these 6 fields/behaviors and update docs/research/gc-api-notes.md
with a new section "## Live boxscore (live-game state)":

  [ ] 1. `status` (top-level) — exposes `in_progress` / `final` during live
         polling? Or only `final` after game ends?
  [ ] 2. `<team_slug>.lineup` — populated with batter rows during live play?
         Or absent until final?  (BatterStatsParser comment says it may be
         absent until finalized — confirm or refute.)
  [ ] 3. `<team_slug>.pitching[].defensive_innings` (or whatever field name)
         — per-pitcher defensive innings populated live? Field name?
  [ ] 4. `<team_slug>.pitching[].player_id` — present? Stable across the
         two 30s-apart polls?
  [ ] 5. Top-level `updated_at` / `fetched_at` / response timestamp for
         staleness detection?
  [ ] 6. `current_inning` / `inning_number` available for the "past inning 3"
         equity-nudge gate?

When each field is confirmed, document the field name + payload example in
docs/research/gc-api-notes.md.

When all 6 are documented, DELETE this file:

  rm .claude/reminders/phase-0-watch-probe.md

Then begin Phase 1 implementation per:
  ~/.gstack/projects/joshRpowell-gamechanger/joshuapowell-main-plan-20260514-065904.md
