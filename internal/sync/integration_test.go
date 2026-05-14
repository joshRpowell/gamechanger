package sync

import (
	"context"
	"encoding/json"
	"fmt"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"

	"github.com/joshrpowell/gamechanger-cli/internal/client"
	"github.com/joshrpowell/gamechanger-cli/internal/config"
	"github.com/joshrpowell/gamechanger-cli/internal/store"
)

// TestEndToEndAgainstFakeAPI spins up an httptest.Server that returns the
// shapes BoxscoreParser + Syncer expect, runs the full sync pipeline, and
// asserts that the resulting SQLite rows match. This is the smoke test
// substitute for live gc.com when credentials/auth aren't available.
func TestEndToEndAgainstFakeAPI(t *testing.T) {
	const (
		fakeToken   = "fake.jwt.token"
		teamID      = "team-uuid-1"
		teamSlug    = "wGP47FexatoQ"
		gameIDPast  = "game-past"
		gameIDToday = "game-today"
	)

	var (
		authCalls     int
		scheduleCalls int
		boxscoreCalls int
	)

	mux := http.NewServeMux()

	mux.HandleFunc("/auth", func(w http.ResponseWriter, r *http.Request) {
		authCalls++
		if r.Method != http.MethodPost {
			t.Errorf("/auth method = %s; want POST", r.Method)
		}
		if got := r.Header.Get("Content-Type"); got != "application/json" {
			t.Errorf("/auth Content-Type = %q", got)
		}
		var body map[string]string
		_ = json.NewDecoder(r.Body).Decode(&body)
		if body["email"] != "test@example.com" || body["password"] != "secret" {
			t.Errorf("/auth body = %+v", body)
		}
		writeJSON(w, map[string]any{
			"token":   fakeToken,
			"expires": time.Now().Add(time.Hour).Unix(),
		})
	})

	mux.HandleFunc(fmt.Sprintf("/teams/%s/schedule", teamID), func(w http.ResponseWriter, r *http.Request) {
		scheduleCalls++
		if got := r.Header.Get("gc-token"); got != fakeToken {
			t.Errorf("/schedule gc-token = %q", got)
		}
		if r.URL.Query().Get("fetch_place_details") != "true" {
			t.Errorf("/schedule missing fetch_place_details=true")
		}
		writeJSON(w, []any{
			// game in the past — should sync
			map[string]any{
				"event": map[string]any{
					"id":         gameIDPast,
					"event_type": "game",
					"start":      map[string]any{"datetime": "2026-04-01T18:30:00Z"},
					"status":     "Completed",
					"title":      "Past Game",
				},
				"pregame_data": map[string]any{
					"opponent_name": "Past Opp",
					"home_away":     "away",
				},
			},
			// game today — should sync
			map[string]any{
				"event": map[string]any{
					"id":         gameIDToday,
					"event_type": "game",
					"start":      map[string]any{"datetime": "2026-05-14T18:30:00Z"},
					"status":     "in_progress",
					"title":      "Today Game",
				},
				"pregame_data": map[string]any{
					"opponent_name": "Today Opp",
					"home_away":     "home",
				},
			},
			// game in the future — should be skipped
			map[string]any{
				"event": map[string]any{
					"id":         "game-future",
					"event_type": "game",
					"start":      map[string]any{"datetime": "2099-12-31T18:30:00Z"},
					"status":     "Scheduled",
				},
			},
			// practice — should be filtered out
			map[string]any{
				"event": map[string]any{
					"id":         "practice-1",
					"event_type": "practice",
					"start":      map[string]any{"datetime": "2026-04-15T18:00:00Z"},
				},
			},
			// canceled — should be filtered after parsing
			map[string]any{
				"event": map[string]any{
					"id":         "canceled-1",
					"event_type": "game",
					"start":      map[string]any{"datetime": "2026-04-20T18:00:00Z"},
					"status":     "canceled",
				},
			},
		})
	})

	mux.HandleFunc("/game-stream-processing/", func(w http.ResponseWriter, r *http.Request) {
		boxscoreCalls++
		if !strings.HasSuffix(r.URL.Path, "/boxscore") {
			http.Error(w, "not found", 404)
			return
		}
		writeJSON(w, boxscoreFixture(teamSlug))
	})

	srv := httptest.NewServer(mux)
	defer srv.Close()

	// Wire config + store + client against the fake server.
	dir := t.TempDir()
	cfg, err := config.LoadFrom(dir)
	if err != nil {
		t.Fatalf("config: %v", err)
	}
	cfg.Email = "test@example.com"
	cfg.Password = "secret"
	cfg.TeamID = teamID
	cfg.TeamSlug = teamSlug
	if err := cfg.Save(); err != nil {
		t.Fatalf("save config: %v", err)
	}

	st, err := store.OpenAt(context.Background(), dir, 2026)
	if err != nil {
		t.Fatalf("store: %v", err)
	}
	defer st.Close()

	cli := client.New(cfg).WithBaseURL(srv.URL)
	syncer := &Syncer{
		Config:    cfg,
		Client:    cli,
		Store:     st,
		RateLimit: time.Nanosecond,
		Now:       func() time.Time { return time.Date(2026, 5, 14, 23, 0, 0, 0, time.UTC) },
	}

	result, err := syncer.Run(context.Background(), true)
	if err != nil {
		t.Fatalf("syncer.Run: %v", err)
	}

	// 2 games hit the boxscore endpoint (past + today). Future + practice +
	// canceled are filtered before the API call.
	if boxscoreCalls != 2 {
		t.Errorf("boxscore calls = %d; want 2", boxscoreCalls)
	}
	if scheduleCalls != 1 {
		t.Errorf("schedule calls = %d; want 1", scheduleCalls)
	}
	if authCalls != 1 {
		t.Errorf("auth calls = %d; want 1 (cached after first)", authCalls)
	}

	// Both games yielded pitcher stats, so both got marked final.
	if result.Games != 2 {
		t.Errorf("result.Games = %d; want 2", result.Games)
	}
	// Each fixture has 2 pitchers, so 4 outings total.
	if result.Outings != 4 {
		t.Errorf("result.Outings = %d; want 4", result.Outings)
	}
	// Each fixture has 2 batter rows, ABs 3+4 = 7 per game * 2 games = 14.
	if result.AtBats != 14 {
		t.Errorf("result.AtBats = %d; want 14", result.AtBats)
	}

	// Verify the rows actually landed in SQLite.
	games, _ := st.AllGames(context.Background())
	if len(games) != 2 {
		t.Errorf("games in DB = %d; want 2", len(games))
	}
	var finalCount int
	_ = st.DB().QueryRow(`SELECT COUNT(*) FROM games WHERE status = 'final'`).Scan(&finalCount)
	if finalCount != 2 {
		t.Errorf("final games = %d; want 2", finalCount)
	}

	var pitcherRows, batterRows int
	_ = st.DB().QueryRow(`SELECT COUNT(*) FROM game_pitcher_stats`).Scan(&pitcherRows)
	_ = st.DB().QueryRow(`SELECT COUNT(*) FROM game_batter_stats`).Scan(&batterRows)
	if pitcherRows != 4 {
		t.Errorf("pitcher rows = %d; want 4", pitcherRows)
	}
	if batterRows != 4 {
		t.Errorf("batter rows = %d; want 4", batterRows)
	}

	// Token was cached: a second Run should NOT re-auth.
	authBefore := authCalls
	if _, err := syncer.Run(context.Background(), false); err != nil {
		t.Fatalf("second Run: %v", err)
	}
	if authCalls != authBefore {
		t.Errorf("auth re-called on second Run: %d -> %d", authBefore, authCalls)
	}
}

func writeJSON(w http.ResponseWriter, v any) {
	w.Header().Set("Content-Type", "application/json")
	_ = json.NewEncoder(w).Encode(v)
}

func boxscoreFixture(teamSlug string) map[string]any {
	return map[string]any{
		teamSlug: map[string]any{
			"players": []any{
				map[string]any{"id": "p1", "first_name": "Asher", "last_name": "Lima"},
				map[string]any{"id": "p2", "first_name": "Mason", "last_name": "Marrero"},
			},
			"groups": []any{
				map[string]any{
					"category": "pitching",
					"extra": []any{
						map[string]any{
							"stat_name": "#P",
							"stats": []any{
								map[string]any{"player_id": "p1", "value": float64(59)},
								map[string]any{"player_id": "p2", "value": float64(25)},
							},
						},
						map[string]any{
							"stat_name": "TS",
							"stats": []any{
								map[string]any{"player_id": "p1", "value": float64(38)},
								map[string]any{"player_id": "p2", "value": float64(14)},
							},
						},
					},
					"stats": []any{
						map[string]any{"player_id": "p1", "stats": map[string]any{"IP": float64(4.0)}},
						map[string]any{"player_id": "p2", "stats": map[string]any{"IP": float64(1.667)}},
					},
				},
				map[string]any{
					"category": "lineup",
					"stats": []any{
						map[string]any{
							"player_id": "p1",
							"stats":     map[string]any{"AB": float64(3), "H": float64(1), "BB": float64(1), "K": float64(1)},
						},
						map[string]any{
							"player_id": "p2",
							"stats":     map[string]any{"AB": float64(4), "H": float64(2), "BB": float64(0), "K": float64(1)},
						},
					},
				},
			},
		},
	}
}
