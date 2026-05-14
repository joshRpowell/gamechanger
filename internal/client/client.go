// Package client speaks the Gamechanger internal JSON API.
//
// Auth: gc-token header (NOT Authorization: Bearer). Token comes from
// POST /auth with {email, password}; cached in config.SessionFile.
//
// All requests also send gc-app-name=web + gc-device-id (32-char hex)
// + Origin/Referer to https://web.gc.com, plus a browser User-Agent.
//
// See docs/research/gc-api-notes.md (Ruby project) for the full endpoint
// reference. The 4 endpoints we hit:
//   POST /auth                                           -> {token, expires}
//   GET  /me/teams                                       -> teams list
//   GET  /teams/{uuid}/schedule?fetch_place_details=true -> schedule
//   GET  /game-stream-processing/{uuid}/boxscore         -> boxscore
package client

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net"
	"net/http"
	"net/url"
	"strings"
	"time"

	"github.com/joshrpowell/gamechanger-cli/internal/config"
	"github.com/joshrpowell/gamechanger-cli/internal/gcerr"
)

// ErrBoxscoreNotFound is returned by Boxscore when the game's boxscore
// endpoint returns 404. This is expected for canceled, postponed, or
// scheduled-but-never-played games. Callers should skip the game rather
// than treat this as a sync failure.
var ErrBoxscoreNotFound = errors.New("boxscore not found")

const (
	defaultBaseURL = "https://api.team-manager.gc.com"
	authPath       = "/auth"
	teamsPath      = "/me/teams"
	schedulePath   = "/teams/%s/schedule"
	boxscorePath   = "/game-stream-processing/%s/boxscore"

	acceptTeams = "application/vnd.gc.com.team:list+json; version=0.10.0"
	acceptJSON  = "application/json"

	userAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10.15; rv:148.0) Gecko/20100101 Firefox/148.0"

	// RateLimitSleep is the pause between game-level requests during sync.
	RateLimitSleep = 500 * time.Millisecond
	// retrySleep is how long to wait after a 429 before the single retry.
	retrySleep = 5 * time.Second
)

// Client is goroutine-safe (it embeds an *http.Client). Use one per CLI run.
type Client struct {
	cfg     *config.Config
	http    *http.Client
	baseURL string
}

// New builds a Client wired to the production base URL.
func New(cfg *config.Config) *Client {
	return &Client{
		cfg:     cfg,
		baseURL: defaultBaseURL,
		http: &http.Client{
			Timeout: 35 * time.Second,
			Transport: &http.Transport{
				DialContext: (&net.Dialer{
					Timeout: 10 * time.Second,
				}).DialContext,
				TLSHandshakeTimeout:   10 * time.Second,
				ResponseHeaderTimeout: 30 * time.Second,
				ForceAttemptHTTP2:     true,
			},
		},
	}
}

// WithBaseURL returns a copy aimed at a different base URL (tests).
func (c *Client) WithBaseURL(url string) *Client {
	cp := *c
	cp.baseURL = url
	return &cp
}

// Authenticate returns a session token. If a cached token is present and
// not expired, returns it without hitting the network.
func (c *Client) Authenticate(ctx context.Context) (string, error) {
	if tok := c.cfg.CachedToken(); tok != "" {
		return tok, nil
	}
	body, err := json.Marshal(map[string]string{
		"email":    c.cfg.Email,
		"password": c.cfg.Password,
	})
	if err != nil {
		return "", gcerr.Authf("marshal credentials: %v", err)
	}
	resp, err := c.do(ctx, http.MethodPost, authPath, bytes.NewReader(body), acceptJSON)
	if err != nil {
		return "", err
	}
	var payload struct {
		Token   string      `json:"token"`
		Expires json.Number `json:"expires"`
	}
	if err := json.Unmarshal(resp, &payload); err != nil {
		return "", gcerr.APIShapef("parse auth response: %v", err)
	}
	if payload.Token == "" {
		return "", gcerr.APIShapef("auth response missing token field")
	}
	expiresUnix, _ := payload.Expires.Int64()
	if err := c.cfg.CacheToken(payload.Token, expiresUnix); err != nil {
		return "", err
	}
	return payload.Token, nil
}

// Teams returns the raw /me/teams response. Returned as a generic
// interface{} so callers can extract from either an array or a wrapped
// object shape (the API has both observed shapes).
func (c *Client) Teams(ctx context.Context) (any, error) {
	if _, err := c.Authenticate(ctx); err != nil {
		return nil, err
	}
	body, err := c.do(ctx, http.MethodGet, teamsPath, nil, acceptTeams)
	if err != nil {
		return nil, err
	}
	return parseAny(body)
}

// Schedule returns the team schedule (raw shape; the syncer extracts
// {event, pregame_data} entries from it).
func (c *Client) Schedule(ctx context.Context, teamID string) (any, error) {
	if _, err := c.Authenticate(ctx); err != nil {
		return nil, err
	}
	if teamID == "" {
		return nil, gcerr.Configf("team_id is required for Schedule")
	}
	path := fmt.Sprintf(schedulePath, url.PathEscape(teamID)) + "?fetch_place_details=true"
	body, err := c.do(ctx, http.MethodGet, path, nil, acceptJSON)
	if err != nil {
		return nil, err
	}
	return parseAny(body)
}

// Boxscore returns the raw /game-stream-processing/{game_id}/boxscore
// response — a map keyed by team_slug.
//
// Returns ErrBoxscoreNotFound when the API responds 404 for that game,
// which is expected for canceled, postponed, or never-played games.
func (c *Client) Boxscore(ctx context.Context, gameID string) (map[string]any, error) {
	if _, err := c.Authenticate(ctx); err != nil {
		return nil, err
	}
	if gameID == "" {
		return nil, gcerr.Configf("game_id is required for Boxscore")
	}
	path := fmt.Sprintf(boxscorePath, url.PathEscape(gameID))
	body, err := c.do(ctx, http.MethodGet, path, nil, acceptJSON)
	if err != nil {
		// Recognize the 404 from path-level error text. The do() path
		// keeps Networkf for all non-2xx so we string-match here rather
		// than refactor the whole error pipeline for one case.
		if isNotFoundFor(err, path) {
			return nil, ErrBoxscoreNotFound
		}
		return nil, err
	}
	var m map[string]any
	if err := json.Unmarshal(body, &m); err != nil {
		return nil, gcerr.APIShapef("parse boxscore: %v", err)
	}
	return m, nil
}

func isNotFoundFor(err error, path string) bool {
	return err != nil && strings.Contains(err.Error(), "returned 404 for GET "+path)
}

func (c *Client) do(ctx context.Context, method, path string, body io.Reader, accept string) ([]byte, error) {
	return c.doAttempt(ctx, method, path, body, accept, 1)
}

func (c *Client) doAttempt(ctx context.Context, method, path string, body io.Reader, accept string, attempt int) ([]byte, error) {
	// Re-buffer body if we may need to retry: the caller passed a
	// non-nil reader and this is the first attempt — we need to capture
	// the bytes so the retry can replay them.
	var bodyBytes []byte
	if body != nil {
		var err error
		bodyBytes, err = io.ReadAll(body)
		if err != nil {
			return nil, gcerr.Networkf("read request body: %v", err)
		}
	}

	req, err := http.NewRequestWithContext(ctx, method, c.baseURL+path, bytes.NewReader(bodyBytes))
	if err != nil {
		return nil, gcerr.Networkf("build request: %v", err)
	}
	req.Header.Set("Accept", accept)
	req.Header.Set("Content-Type", "application/json")
	req.Header.Set("User-Agent", userAgent)
	req.Header.Set("Origin", "https://web.gc.com")
	req.Header.Set("Referer", "https://web.gc.com/")
	req.Header.Set("gc-app-name", "web")
	if c.cfg.DeviceID != "" {
		req.Header.Set("gc-device-id", c.cfg.DeviceID)
	}
	if tok := c.cfg.CachedToken(); tok != "" {
		req.Header.Set("gc-token", tok)
	}
	if len(bodyBytes) > 0 {
		req.ContentLength = int64(len(bodyBytes))
	}

	resp, err := c.http.Do(req)
	if err != nil {
		var netErr net.Error
		if errors.As(err, &netErr) && netErr.Timeout() {
			return nil, gcerr.Networkf("request timed out: %v", err)
		}
		return nil, gcerr.Networkf("connect: %v", err)
	}
	defer resp.Body.Close()

	respBody, err := io.ReadAll(resp.Body)
	if err != nil {
		return nil, gcerr.Networkf("read response: %v", err)
	}

	switch {
	case resp.StatusCode >= 200 && resp.StatusCode < 300:
		return respBody, nil
	case resp.StatusCode == http.StatusUnauthorized:
		return nil, gcerr.Authf("authentication failed — run `gamechanger setup` to reconfigure")
	case resp.StatusCode == http.StatusTooManyRequests:
		if attempt == 1 {
			fmt.Fprintf(io.Discard, "rate limited\n") // placeholder; real warning surfaced by callers
			select {
			case <-ctx.Done():
				return nil, gcerr.Networkf("context cancelled while waiting on rate limit")
			case <-time.After(retrySleep):
			}
			return c.doAttempt(ctx, method, path, bytes.NewReader(bodyBytes), accept, 2)
		}
		return nil, gcerr.Networkf("rate limited by Gamechanger API (429) — try again later")
	default:
		return nil, gcerr.Networkf("Gamechanger API returned %d for %s %s: %s",
			resp.StatusCode, method, path, http.StatusText(resp.StatusCode))
	}
}

func parseAny(body []byte) (any, error) {
	if len(bytes.TrimSpace(body)) == 0 {
		return []any{}, nil
	}
	var out any
	if err := json.Unmarshal(body, &out); err != nil {
		return nil, gcerr.APIShapef("unexpected response (not JSON): %v", err)
	}
	return out, nil
}
