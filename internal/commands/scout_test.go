package commands

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"io"
	"strings"
	"testing"

	"github.com/joshrpowell/gamechanger-cli/internal/client"
	"github.com/joshrpowell/gamechanger-cli/internal/gcerr"
	"github.com/joshrpowell/gamechanger-cli/internal/scout"
)

const (
	myTeamUUID = "my-team-uuid"
	oppEagles  = "opp-eagles-uuid"
	oppTigers  = "opp-tigers-uuid"
)

// fakeScoutClient implements scout.ScoutClient with scripted responses.
type fakeScoutClient struct {
	games      []client.GameSummary
	gamesErr   error
	details    map[string]*client.OpponentDetail
	detailsErr map[string]error
}

func (f *fakeScoutClient) GameSummaries(ctx context.Context, _ string) ([]client.GameSummary, error) {
	if f.gamesErr != nil {
		return nil, f.gamesErr
	}
	return f.games, nil
}

func (f *fakeScoutClient) OpponentDetail(ctx context.Context, _, oppUUID string) (*client.OpponentDetail, error) {
	if err, ok := f.detailsErr[oppUUID]; ok && err != nil {
		return nil, err
	}
	if d, ok := f.details[oppUUID]; ok {
		return d, nil
	}
	return nil, client.ErrTeamNotFound
}

func gs(eventID, oppID, ha, ts string, mine, theirs int, status string) client.GameSummary {
	return client.GameSummary{
		EventID: eventID, GameStatus: status, HomeAway: ha,
		OwningTeamScore: mine, OpponentTeamScore: theirs, LastScoringUpdate: ts,
		GameStream: client.GameSummaryStream{GameID: eventID, OpponentID: oppID, HomeAway: ha, GameStatus: status},
	}
}

// runScoutTest builds a runScout call wired to an in-memory store + scripted
// fake client. Returns (exit code, stdout, stderr).
func runScoutTest(t *testing.T, fake *fakeScoutClient, opponent string, format string, isTTY bool) (int, string, string) {
	t.Helper()
	home := t.TempDir()
	t.Setenv("GAMECHANGER_HOME", home)
	ro := &rootOpts{configDir: home, format: "table"}
	so := &scoutOpts{
		format:      format,
		detectTTY:   func(io.Writer) bool { return isTTY },
		newClient:   func(*scoutOpts, *rootOpts) (scout.ScoutClient, error) { return fake, nil },
		resolveTeam: func(context.Context, scout.ScoutClient, string) (string, error) { return myTeamUUID, nil },
	}
	var stdout, stderr bytes.Buffer
	err := runScout(context.Background(), &stdout, &stderr, opponent, ro, so)
	if err == nil {
		return ExitScoutPass, stdout.String(), stderr.String()
	}
	return exitCodeFor(err), stdout.String(), stderr.String() + err.Error()
}

// --- Happy paths -----------------------------------------------------------

func TestScoutCmd_PlainPaste(t *testing.T) {
	fake := &fakeScoutClient{
		games: []client.GameSummary{
			gs("e1", oppEagles, "home", "2026-04-15T22:00:00Z", 4, 7, "completed"),
			gs("e2", oppEagles, "away", "2026-03-22T20:00:00Z", 8, 3, "completed"),
		},
		details: map[string]*client.OpponentDetail{oppEagles: {Name: "Eagles 12U"}},
	}
	code, stdout, _ := runScoutTest(t, fake, "Eagles 12U", "human", false /* non-TTY */)
	if code != ExitScoutPass {
		t.Fatalf("exit code = %d; want %d", code, ExitScoutPass)
	}
	if !strings.Contains(stdout, "Matchup vs Eagles 12U (2 games)") {
		t.Errorf("header missing: %q", stdout)
	}
	if !strings.Contains(stdout, "2026-04-15") || !strings.Contains(stdout, "L 4-7") {
		t.Errorf("first game missing: %q", stdout)
	}
	if !strings.Contains(stdout, "W 8-3") {
		t.Errorf("second game outcome missing: %q", stdout)
	}
	// AE3: plain output capped at 500 chars + no ANSI.
	if len(stdout) > 500 {
		t.Errorf("plain output exceeded 500 chars: %d", len(stdout))
	}
	if strings.Contains(stdout, "\033[") {
		t.Errorf("plain output contains ANSI escapes: %q", stdout)
	}
}

func TestScoutCmd_TTYColored(t *testing.T) {
	fake := &fakeScoutClient{
		games:   []client.GameSummary{gs("e1", oppEagles, "home", "2026-04-15T22:00:00Z", 8, 3, "completed")},
		details: map[string]*client.OpponentDetail{oppEagles: {Name: "Eagles 12U"}},
	}
	code, stdout, _ := runScoutTest(t, fake, "Eagles 12U", "human", true /* TTY */)
	if code != ExitScoutPass {
		t.Fatalf("exit code = %d", code)
	}
	if !strings.Contains(stdout, "\033[") {
		t.Errorf("TTY output should contain ANSI escapes: %q", stdout)
	}
}

func TestScoutCmd_JSONRoundTrip(t *testing.T) {
	fake := &fakeScoutClient{
		games:   []client.GameSummary{gs("e1", oppEagles, "home", "2026-04-15T22:00:00Z", 4, 7, "completed")},
		details: map[string]*client.OpponentDetail{oppEagles: {Name: "Eagles 12U"}},
	}
	code, stdout, _ := runScoutTest(t, fake, "Eagles 12U", "json", false)
	if code != ExitScoutPass {
		t.Fatalf("exit code = %d", code)
	}
	var got struct {
		Opponent struct {
			UUID string `json:"UUID"`
			Name string `json:"Name"`
		} `json:"Opponent"`
		Games []map[string]any `json:"Games"`
	}
	if err := json.Unmarshal([]byte(stdout), &got); err != nil {
		t.Fatalf("invalid JSON: %v\n%s", err, stdout)
	}
	if got.Opponent.Name != "Eagles 12U" || got.Opponent.UUID != oppEagles {
		t.Errorf("opponent unmarshalled wrong: %+v", got.Opponent)
	}
	if len(got.Games) != 1 {
		t.Errorf("games len = %d; want 1", len(got.Games))
	}
}

// --- Error paths -----------------------------------------------------------

func TestScoutCmd_OpponentNotResolvable(t *testing.T) {
	fake := &fakeScoutClient{
		games:   []client.GameSummary{gs("e1", oppEagles, "home", "2026-04-15T22:00:00Z", 4, 7, "completed")},
		details: map[string]*client.OpponentDetail{oppEagles: {Name: "Eagles 12U"}},
	}
	code, _, stderr := runScoutTest(t, fake, "Phantom Team", "human", false)
	if code != ExitScoutTeamNotFound {
		t.Fatalf("expected ExitScoutTeamNotFound (%d); got %d", ExitScoutTeamNotFound, code)
	}
	if !strings.Contains(stderr, "Phantom Team") {
		t.Errorf("error should name the unresolved opponent: %q", stderr)
	}
}

func TestScoutCmd_CacheEmpty(t *testing.T) {
	fake := &fakeScoutClient{games: nil}
	code, _, stderr := runScoutTest(t, fake, "anyone", "human", false)
	if code != ExitScoutCacheEmpty {
		t.Fatalf("expected ExitScoutCacheEmpty (%d); got %d", ExitScoutCacheEmpty, code)
	}
	if !strings.Contains(stderr, "refresh") {
		t.Errorf("error hint should mention refresh: %q", stderr)
	}
}

func TestScoutCmd_AuthExpired(t *testing.T) {
	fake := &fakeScoutClient{gamesErr: gcerr.Authf("token expired")}
	code, _, stderr := runScoutTest(t, fake, "x", "human", false)
	if code != ExitScoutAuthExpired {
		t.Fatalf("expected ExitScoutAuthExpired (%d); got %d", ExitScoutAuthExpired, code)
	}
	if !strings.Contains(stderr, "auth import") {
		t.Errorf("auth-expired hint should mention `auth import`: %q", stderr)
	}
}

func TestScoutCmd_AuthInsufficient(t *testing.T) {
	fake := &fakeScoutClient{gamesErr: gcerr.AuthInsufficientf("forbidden")}
	code, _, stderr := runScoutTest(t, fake, "x", "human", false)
	if code != ExitScoutAuthInsufficient {
		t.Fatalf("expected ExitScoutAuthInsufficient (%d); got %d", ExitScoutAuthInsufficient, code)
	}
	if !strings.Contains(stderr, "403") {
		t.Errorf("403 hint expected: %q", stderr)
	}
}

func TestScoutCmd_NetworkError(t *testing.T) {
	fake := &fakeScoutClient{gamesErr: gcerr.Networkf("connect: refused")}
	code, _, stderr := runScoutTest(t, fake, "x", "human", false)
	if code != ExitScoutNetworkError {
		t.Fatalf("expected ExitScoutNetworkError (%d); got %d", ExitScoutNetworkError, code)
	}
	if !strings.Contains(stderr, "connectivity") {
		t.Errorf("network hint should mention connectivity: %q", stderr)
	}
}

func TestScoutCmd_ClientTeamNotFound(t *testing.T) {
	fake := &fakeScoutClient{gamesErr: client.ErrTeamNotFound}
	code, _, _ := runScoutTest(t, fake, "x", "human", false)
	if code != ExitScoutTeamNotFound {
		t.Fatalf("expected ExitScoutTeamNotFound; got %d", code)
	}
}

func TestScoutCmd_UnknownFormat(t *testing.T) {
	fake := &fakeScoutClient{
		games:   []client.GameSummary{gs("e1", oppEagles, "home", "2026-04-15T22:00:00Z", 4, 7, "completed")},
		details: map[string]*client.OpponentDetail{oppEagles: {Name: "Eagles 12U"}},
	}
	code, _, stderr := runScoutTest(t, fake, "Eagles 12U", "xml", false)
	if code == ExitScoutPass {
		t.Errorf("unknown format should fail; got pass")
	}
	if !strings.Contains(stderr, "xml") {
		t.Errorf("error should name the bad format: %q", stderr)
	}
}

// --- firstActiveTeamUUID helper --------------------------------------------

func TestFirstActiveTeamUUID(t *testing.T) {
	resp := []any{
		map[string]any{"id": "old-archived", "name": "Stars 9U", "archived": true},
		map[string]any{"id": "current-id", "name": "Plantation Stars 11U Blue", "archived": false},
	}
	uuid, name := firstActiveTeamUUID(resp)
	if uuid != "current-id" {
		t.Errorf("uuid = %q; want current-id", uuid)
	}
	if name != "Plantation Stars 11U Blue" {
		t.Errorf("name = %q", name)
	}
}

func TestFirstActiveTeamUUID_WrappedShapes(t *testing.T) {
	for _, key := range []string{"teams", "data"} {
		v := map[string]any{key: []any{
			map[string]any{"id": "x", "name": "X", "archived": false},
		}}
		uuid, _ := firstActiveTeamUUID(v)
		if uuid != "x" {
			t.Errorf("%s wrapper not parsed: got %q", key, uuid)
		}
	}
}

func TestFirstActiveTeamUUID_NoneActive(t *testing.T) {
	resp := []any{
		map[string]any{"id": "x", "archived": true},
	}
	uuid, _ := firstActiveTeamUUID(resp)
	if uuid != "" {
		t.Errorf("all-archived should yield empty; got %q", uuid)
	}
}

// --- Sentinel mapping double-check ------------------------------------------

func TestClassifyScoutCmdErr_DirectMapping(t *testing.T) {
	cases := []struct {
		name string
		in   error
		want int
	}{
		{"cache-empty", scout.ErrCacheEmpty, ExitScoutCacheEmpty},
		{"unresolvable", scout.ErrOpponentNotResolvable, ExitScoutTeamNotFound},
		{"team-not-found", client.ErrTeamNotFound, ExitScoutTeamNotFound},
		{"auth", gcerr.Authf("x"), ExitScoutAuthExpired},
		{"auth-insufficient", gcerr.AuthInsufficientf("x"), ExitScoutAuthInsufficient},
		{"network", gcerr.Networkf("x"), ExitScoutNetworkError},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			err := classifyScoutCmdErr(tc.in, "any")
			var sex *scoutExit
			if !errors.As(err, &sex) {
				t.Fatalf("expected scoutExit; got %T", err)
			}
			if sex.Code() != tc.want {
				t.Errorf("code = %d; want %d", sex.Code(), tc.want)
			}
		})
	}
}
