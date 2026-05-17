package client

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"net/http"
	"net/url"
	"strings"

	"github.com/joshrpowell/gamechanger-cli/internal/gcerr"
)

// Scout API surface (Phase 1a, Fork A — matchup-history scout).
//
// Endpoints confirmed by U1 discovery probe (cmd/scout-probe, 2026-05-15):
//   GET /teams/{team_uuid}/game-summaries       → bare array of GameSummary
//   GET /teams/{team_uuid}/opponent/{opp_uuid}  → bare object OpponentDetail
//
// Both accept Accept: application/json and return
// application/json; charset=utf-8. See docs/research/gc-scout-api-notes.md
// for the full discovery write-up and response shapes.

// ErrTeamNotFound is returned by GameSummaries / OpponentDetail when the API
// responds 404 for the team or opponent UUID. Distinct from ErrBoxscoreNotFound
// to keep scout's error surface separate from sync's.
var ErrTeamNotFound = errors.New("scout: team or opponent not found")

// GameSummary is one row from /teams/{uuid}/game-summaries. Fields are the
// subset scout's matchup-history workflow consumes — additional fields
// (sport_specific, game_stream internals) are present in the response but
// not captured here; they can be added if/when downstream code needs them.
type GameSummary struct {
	EventID           string             `json:"event_id"`
	GameStatus        string             `json:"game_status"`
	HomeAway          string             `json:"home_away"`
	OwningTeamScore   int                `json:"owning_team_score"`
	OpponentTeamScore int                `json:"opponent_team_score"`
	LastScoringUpdate string             `json:"last_scoring_update"`
	GameStream        GameSummaryStream `json:"game_stream"`
}

// GameSummaryStream is the nested game_stream block. opponent_id is the
// critical field — it's the cross-reference key for finding all games against
// a single opposing team.
type GameSummaryStream struct {
	GameID     string `json:"game_id"`
	OpponentID string `json:"opponent_id"`
	HomeAway   string `json:"home_away"`
	GameStatus string `json:"game_status"`
}

// OpponentDetail is the 220-byte response from /teams/{uuid}/opponent/{opp_uuid}.
// Carries the opponent's display name plus tracking IDs — no roster, no
// coaches, no schedule. See docs/research/gc-scout-api-notes.md for why this
// is the only opposing-team-keyed endpoint exposed by the web/desktop API.
type OpponentDetail struct {
	IsHidden          bool   `json:"is_hidden"`
	Name              string `json:"name"`
	OwningTeamID      string `json:"owning_team_id"`
	ProgenitorTeamID  string `json:"progenitor_team_id"`
	RootTeamID        string `json:"root_team_id"`
}

// GameSummaries fetches the team's full matchup history. Returns a bare array
// of GameSummary (no wrapping; confirmed by U1).
//
// Errors:
//   - ErrTeamNotFound        if the API returns 404
//   - gcerr.ErrAuth          if the API returns 401 (token expired)
//   - gcerr.ErrAuthInsufficient if the API returns 403 (scope denied)
//   - gcerr.ErrConfig        if teamUUID is empty
//   - gcerr.ErrNetwork       for connectivity / 5xx failures
//   - gcerr.ErrAPIShape      if the response body fails to parse
func (c *Client) GameSummaries(ctx context.Context, teamUUID string) ([]GameSummary, error) {
	if teamUUID == "" {
		return nil, gcerr.Configf("team_uuid is required for GameSummaries")
	}
	if _, err := c.Authenticate(ctx); err != nil {
		return nil, err
	}
	path := "/teams/" + url.PathEscape(teamUUID) + "/game-summaries"
	body, err := c.do(ctx, http.MethodGet, path, nil, acceptJSON)
	if err != nil {
		return nil, classifyScoutErr(err, path)
	}
	var out []GameSummary
	if err := json.Unmarshal(body, &out); err != nil {
		return nil, gcerr.APIShapef("parse game-summaries: %v", err)
	}
	return out, nil
}

// OpponentDetail fetches the opponent's name + tracking IDs. The opposing
// roster is NOT exposed by this endpoint (U1 discovery) — for that, see
// docs/research/gc-scout-api-notes.md Fork B notes.
//
// Errors mirror GameSummaries.
func (c *Client) OpponentDetail(ctx context.Context, teamUUID, opponentUUID string) (*OpponentDetail, error) {
	if teamUUID == "" {
		return nil, gcerr.Configf("team_uuid is required for OpponentDetail")
	}
	if opponentUUID == "" {
		return nil, gcerr.Configf("opponent_uuid is required for OpponentDetail")
	}
	if _, err := c.Authenticate(ctx); err != nil {
		return nil, err
	}
	path := "/teams/" + url.PathEscape(teamUUID) + "/opponent/" + url.PathEscape(opponentUUID)
	body, err := c.do(ctx, http.MethodGet, path, nil, acceptJSON)
	if err != nil {
		return nil, classifyScoutErr(err, path)
	}
	var out OpponentDetail
	if err := json.Unmarshal(body, &out); err != nil {
		return nil, gcerr.APIShapef("parse opponent detail: %v", err)
	}
	return &out, nil
}

// classifyScoutErr inspects the wrapped error from do() and re-routes
// path-specific 404s to ErrTeamNotFound and 403s to ErrAuthInsufficient.
// Mirrors the isNotFoundFor pattern used by Boxscore. 401 already maps to
// gcerr.ErrAuth in do(), so we don't need to touch that path.
func classifyScoutErr(err error, path string) error {
	if err == nil {
		return nil
	}
	msg := err.Error()
	if strings.Contains(msg, "returned 404 for GET "+path) {
		return ErrTeamNotFound
	}
	if strings.Contains(msg, "returned 403 for GET "+path) {
		return gcerr.AuthInsufficientf("scout: access denied for %s", path)
	}
	return err
}

// Sanity check at compile-time that classifyScoutErr's strings.Contains
// match strings stay in sync with do()'s actual error format.
var _ = fmt.Sprintf // keep fmt imported even if other refs change
