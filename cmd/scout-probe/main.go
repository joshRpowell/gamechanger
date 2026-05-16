// cmd/scout-probe — U1 discovery throwaway. Probes GameChanger API endpoints
// using the user's cached gc-token to confirm response shapes for the scout
// Phase 1a plan. Dumps each response to testdata/har/<name>.json then exits.
//
// Delete this file after U1 doc lands. Endpoint inventory from network capture:
//   /me/teams
//   /teams/{team_uuid}/players
//   /teams/{team_uuid}/opponent/{opp_uuid}
//   /teams/{team_uuid}/users
//   /teams/{team_uuid}/game-summaries
package main

import (
	"context"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"os"
	"path/filepath"
	"time"

	"github.com/joshrpowell/gamechanger-cli/internal/config"
)

const (
	apiBase = "https://api.team-manager.gc.com"
	// Observed from network capture against this user's account.
	knownTeamUUID     = "b4ded52d-56a3-4429-974a-dc7485669a8c"
	knownOpponentUUID = "006e1663-c91d-4d64-a5a4-5a25b31fe4d7"
)

type probeTarget struct {
	name    string
	path    string
	accept  string
	include string // appended as ?include=...
}

var targets = []probeTarget{
	{name: "me_teams", path: "/me/teams", accept: "application/json"},
	{name: "team_players", path: "/teams/" + knownTeamUUID + "/players", accept: "application/json"},
	{name: "opponent_detail", path: "/teams/" + knownTeamUUID + "/opponent/" + knownOpponentUUID, accept: "application/json"},
	{name: "team_users", path: "/teams/" + knownTeamUUID + "/users", accept: "application/json"},
	{name: "team_game_summaries", path: "/teams/" + knownTeamUUID + "/game-summaries", accept: "application/json"},
}

func main() {
	ctx := context.Background()
	cfg, err := config.Load()
	if err != nil {
		die("load config: " + err.Error())
	}
	token := cfg.CachedToken()
	if token == "" {
		die("no cached gc-token in ~/.gamechanger/session — run `gamechanger auth import` first")
	}
	if cfg.DeviceID == "" {
		die("no device_id in config")
	}

	outDir := "testdata/har"
	if err := os.MkdirAll(outDir, 0o755); err != nil {
		die("mkdir " + outDir + ": " + err.Error())
	}

	httpC := &http.Client{Timeout: 30 * time.Second}
	fmt.Println("scout-probe: using token, device_id, against", apiBase)
	fmt.Println()

	for _, t := range targets {
		probe(ctx, httpC, cfg, t, outDir)
	}
}

func probe(ctx context.Context, httpC *http.Client, cfg *config.Config, t probeTarget, outDir string) {
	url := apiBase + t.path
	if t.include != "" {
		url += "?include=" + t.include
	}
	req, err := http.NewRequestWithContext(ctx, "GET", url, nil)
	if err != nil {
		fmt.Printf("[%s] build request: %v\n", t.name, err)
		return
	}
	req.Header.Set("Accept", t.accept)
	req.Header.Set("User-Agent", "Mozilla/5.0 (Macintosh; Intel Mac OS X 10.15; rv:148.0) Gecko/20100101 Firefox/148.0")
	req.Header.Set("Origin", "https://web.gc.com")
	req.Header.Set("Referer", "https://web.gc.com/")
	req.Header.Set("gc-app-name", "web")
	req.Header.Set("gc-device-id", cfg.DeviceID)
	req.Header.Set("gc-token", cfg.CachedToken())

	resp, err := httpC.Do(req)
	if err != nil {
		fmt.Printf("[%s] http: %v\n", t.name, err)
		return
	}
	defer resp.Body.Close()
	body, _ := io.ReadAll(resp.Body)

	outPath := filepath.Join(outDir, t.name+".json")
	if err := os.WriteFile(outPath, body, 0o644); err != nil {
		fmt.Printf("[%s] write %s: %v\n", t.name, outPath, err)
		return
	}

	// Try pretty-print to a sibling file for easy reading.
	var pretty interface{}
	if err := json.Unmarshal(body, &pretty); err == nil {
		if b, err := json.MarshalIndent(pretty, "", "  "); err == nil {
			_ = os.WriteFile(filepath.Join(outDir, t.name+".pretty.json"), b, 0o644)
		}
	}

	ct := resp.Header.Get("Content-Type")
	fmt.Printf("[%s] %s %s → %d (%dB, %s)\n  -> %s\n",
		t.name, "GET", t.path, resp.StatusCode, len(body), ct, outPath)
}

func die(msg string) {
	fmt.Fprintln(os.Stderr, "scout-probe:", msg)
	os.Exit(1)
}
