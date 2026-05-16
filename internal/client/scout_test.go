package client

import (
	"context"
	"errors"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"runtime"
	"strings"
	"sync"
	"testing"

	"github.com/joshrpowell/gamechanger-cli/internal/config"
	"github.com/joshrpowell/gamechanger-cli/internal/gcerr"
)

const (
	testTeamUUID = "b4ded52d-56a3-4429-974a-dc7485669a8c"
	testOppUUID  = "006e1663-c91d-4d64-a5a4-5a25b31fe4d7"
)

// loadFixture reads a HAR-captured JSON body from testdata/har/<name>.
// Returns the bytes plus a t.Skip-style ok=false if the fixture is absent
// (testdata/har/ is per-developer per the plan; missing fixture skips the
// test rather than failing it). ~5-LOC inline helper per eng-review D2.
func loadFixture(t *testing.T, name string) ([]byte, bool) {
	t.Helper()
	_, thisFile, _, _ := runtime.Caller(0)
	path := filepath.Join(filepath.Dir(thisFile), "..", "..", "testdata", "har", name)
	data, err := os.ReadFile(path)
	if err != nil {
		t.Skipf("fixture %s not available (run cmd/scout-probe first): %v", name, err)
		return nil, false
	}
	return data, true
}

// stubClient builds a *Client wired to an httptest.Server. Token + DeviceID
// are non-empty so the client passes its prechecks.
func stubClient(t *testing.T, srv *httptest.Server) *Client {
	t.Helper()
	dir := t.TempDir()
	cfg, err := config.LoadFrom(dir)
	if err != nil {
		t.Fatalf("LoadFrom: %v", err)
	}
	cfg.DeviceID = "test-device-id"
	// Cache a non-empty token so Authenticate() returns it without trying /auth.
	if err := cfg.CacheToken("test-token-value", 0); err != nil {
		t.Fatalf("CacheToken: %v", err)
	}
	c := New(cfg).WithBaseURL(srv.URL)
	t.Cleanup(srv.Close)
	return c
}

// --- GameSummaries -----------------------------------------------------------

func TestGameSummaries_HappyPath_Fixture(t *testing.T) {
	body, ok := loadFixture(t, "team_game_summaries.json")
	if !ok {
		return
	}
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path != "/teams/"+testTeamUUID+"/game-summaries" {
			t.Errorf("unexpected path: %s", r.URL.Path)
		}
		if gotTok := r.Header.Get("gc-token"); gotTok == "" {
			t.Errorf("gc-token header not set")
		}
		w.Header().Set("Content-Type", "application/json; charset=utf-8")
		w.WriteHeader(200)
		_, _ = w.Write(body)
	}))
	c := stubClient(t, srv)

	summaries, err := c.GameSummaries(context.Background(), testTeamUUID)
	if err != nil {
		t.Fatalf("GameSummaries: %v", err)
	}
	if len(summaries) == 0 {
		t.Fatalf("expected non-empty summaries from fixture")
	}
	// Spot-check the first row carries the expected fields.
	first := summaries[0]
	if first.EventID == "" {
		t.Errorf("first.EventID empty")
	}
	if first.GameStream.OpponentID == "" {
		t.Errorf("first.GameStream.OpponentID empty (cross-reference needs this)")
	}
	if first.HomeAway != "home" && first.HomeAway != "away" {
		t.Errorf("first.HomeAway = %q; expected home or away", first.HomeAway)
	}
}

func TestGameSummaries_HappyPath_Synthetic(t *testing.T) {
	// Synthetic minimal body covering the fields scout actually uses.
	body := `[
		{"event_id":"e1","game_status":"completed","home_away":"home",
		 "owning_team_score":8,"opponent_team_score":1,"last_scoring_update":"2026-02-07T22:00:00Z",
		 "game_stream":{"game_id":"e1","opponent_id":"opp-uuid-1","home_away":"home","game_status":"completed"}},
		{"event_id":"e2","game_status":"completed","home_away":"away",
		 "owning_team_score":4,"opponent_team_score":7,"last_scoring_update":"2026-03-15T20:00:00Z",
		 "game_stream":{"game_id":"e2","opponent_id":"opp-uuid-1","home_away":"away","game_status":"completed"}}
	]`
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		_, _ = w.Write([]byte(body))
	}))
	c := stubClient(t, srv)

	summaries, err := c.GameSummaries(context.Background(), testTeamUUID)
	if err != nil {
		t.Fatalf("GameSummaries: %v", err)
	}
	if len(summaries) != 2 {
		t.Fatalf("got %d summaries; want 2", len(summaries))
	}
	if summaries[0].OwningTeamScore != 8 || summaries[0].OpponentTeamScore != 1 {
		t.Errorf("first scores: got %d/%d; want 8/1",
			summaries[0].OwningTeamScore, summaries[0].OpponentTeamScore)
	}
	if summaries[1].GameStream.OpponentID != "opp-uuid-1" {
		t.Errorf("opponent_id missing")
	}
}

func TestGameSummaries_EmptyArray(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		_, _ = w.Write([]byte(`[]`))
	}))
	c := stubClient(t, srv)
	summaries, err := c.GameSummaries(context.Background(), testTeamUUID)
	if err != nil {
		t.Fatalf("empty array: %v", err)
	}
	if len(summaries) != 0 {
		t.Errorf("empty array should yield zero summaries; got %d", len(summaries))
	}
}

func TestGameSummaries_404_ErrTeamNotFound(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.WriteHeader(404)
	}))
	c := stubClient(t, srv)
	_, err := c.GameSummaries(context.Background(), testTeamUUID)
	if !errors.Is(err, ErrTeamNotFound) {
		t.Fatalf("404 should map to ErrTeamNotFound; got %v", err)
	}
}

func TestGameSummaries_403_ErrAuthInsufficient(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.WriteHeader(403)
	}))
	c := stubClient(t, srv)
	_, err := c.GameSummaries(context.Background(), testTeamUUID)
	if !errors.Is(err, gcerr.ErrAuthInsufficient) {
		t.Fatalf("403 should map to gcerr.ErrAuthInsufficient; got %v", err)
	}
}

func TestGameSummaries_401_ErrAuth(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.WriteHeader(401)
	}))
	c := stubClient(t, srv)
	_, err := c.GameSummaries(context.Background(), testTeamUUID)
	if !errors.Is(err, gcerr.ErrAuth) {
		t.Fatalf("401 should map to gcerr.ErrAuth; got %v", err)
	}
}

func TestGameSummaries_429_Retry(t *testing.T) {
	// Existing do() path retries 429 after retrySleep. Verify retry path
	// fires for this method too. Note: retrySleep is 5s — test will be slow.
	if testing.Short() {
		t.Skip("slow: 5s 429 retry sleep")
	}
	var calls int
	var mu sync.Mutex
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		mu.Lock()
		calls++
		c := calls
		mu.Unlock()
		if c == 1 {
			w.WriteHeader(429)
			return
		}
		_, _ = w.Write([]byte(`[]`))
	}))
	c := stubClient(t, srv)
	if _, err := c.GameSummaries(context.Background(), testTeamUUID); err != nil {
		t.Fatalf("after retry: %v", err)
	}
	mu.Lock()
	defer mu.Unlock()
	if calls != 2 {
		t.Errorf("expected 2 calls (429 then 200); got %d", calls)
	}
}

func TestGameSummaries_EmptyTeamUUID(t *testing.T) {
	c := stubClient(t, httptest.NewServer(http.HandlerFunc(func(http.ResponseWriter, *http.Request) {
		t.Error("server should not be hit on empty UUID")
	})))
	_, err := c.GameSummaries(context.Background(), "")
	if !errors.Is(err, gcerr.ErrConfig) {
		t.Fatalf("empty UUID should return gcerr.ErrConfig; got %v", err)
	}
}

func TestGameSummaries_MalformedJSON_ErrAPIShape(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		_, _ = w.Write([]byte("not a json"))
	}))
	c := stubClient(t, srv)
	_, err := c.GameSummaries(context.Background(), testTeamUUID)
	if !errors.Is(err, gcerr.ErrAPIShape) {
		t.Fatalf("malformed json should return gcerr.ErrAPIShape; got %v", err)
	}
}

// --- OpponentDetail ----------------------------------------------------------

func TestOpponentDetail_HappyPath_Fixture(t *testing.T) {
	body, ok := loadFixture(t, "opponent_detail.json")
	if !ok {
		return
	}
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if !strings.HasSuffix(r.URL.Path, "/opponent/"+testOppUUID) {
			t.Errorf("unexpected path: %s", r.URL.Path)
		}
		_, _ = w.Write(body)
	}))
	c := stubClient(t, srv)
	opp, err := c.OpponentDetail(context.Background(), testTeamUUID, testOppUUID)
	if err != nil {
		t.Fatalf("OpponentDetail: %v", err)
	}
	if opp.Name == "" {
		t.Errorf("Name empty")
	}
	if opp.OwningTeamID == "" {
		t.Errorf("OwningTeamID empty")
	}
}

func TestOpponentDetail_HappyPath_Synthetic(t *testing.T) {
	body := `{
		"is_hidden": false,
		"name": "11U Driftwood Dragons",
		"owning_team_id": "b4ded52d-56a3-4429-974a-dc7485669a8c",
		"progenitor_team_id": "ab77a075-d130-48a5-a359-c175bc7080be",
		"root_team_id": "006e1663-c91d-4d64-a5a4-5a25b31fe4d7"
	}`
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		_, _ = w.Write([]byte(body))
	}))
	c := stubClient(t, srv)
	opp, err := c.OpponentDetail(context.Background(), testTeamUUID, testOppUUID)
	if err != nil {
		t.Fatalf("OpponentDetail: %v", err)
	}
	if opp.Name != "11U Driftwood Dragons" {
		t.Errorf("Name = %q; want \"11U Driftwood Dragons\"", opp.Name)
	}
	if opp.IsHidden {
		t.Errorf("IsHidden should be false")
	}
}

func TestOpponentDetail_404_ErrTeamNotFound(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.WriteHeader(404)
	}))
	c := stubClient(t, srv)
	_, err := c.OpponentDetail(context.Background(), testTeamUUID, testOppUUID)
	if !errors.Is(err, ErrTeamNotFound) {
		t.Fatalf("404 should map to ErrTeamNotFound; got %v", err)
	}
}

func TestOpponentDetail_403_ErrAuthInsufficient(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.WriteHeader(403)
	}))
	c := stubClient(t, srv)
	_, err := c.OpponentDetail(context.Background(), testTeamUUID, testOppUUID)
	if !errors.Is(err, gcerr.ErrAuthInsufficient) {
		t.Fatalf("403 should map to gcerr.ErrAuthInsufficient; got %v", err)
	}
}

func TestOpponentDetail_EmptyUUIDs(t *testing.T) {
	c := stubClient(t, httptest.NewServer(http.HandlerFunc(func(http.ResponseWriter, *http.Request) {
		t.Error("server should not be hit on empty UUID")
	})))
	if _, err := c.OpponentDetail(context.Background(), "", testOppUUID); !errors.Is(err, gcerr.ErrConfig) {
		t.Errorf("empty teamUUID should return ErrConfig; got %v", err)
	}
	if _, err := c.OpponentDetail(context.Background(), testTeamUUID, ""); !errors.Is(err, gcerr.ErrConfig) {
		t.Errorf("empty oppUUID should return ErrConfig; got %v", err)
	}
}

func TestOpponentDetail_MalformedJSON_ErrAPIShape(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		_, _ = w.Write([]byte("nope"))
	}))
	c := stubClient(t, srv)
	_, err := c.OpponentDetail(context.Background(), testTeamUUID, testOppUUID)
	if !errors.Is(err, gcerr.ErrAPIShape) {
		t.Fatalf("malformed json should return gcerr.ErrAPIShape; got %v", err)
	}
}
