package scout

import (
	"context"
	"errors"
	"testing"
	"time"

	"github.com/joshrpowell/gamechanger-cli/internal/client"
	"github.com/joshrpowell/gamechanger-cli/internal/gcerr"
	"github.com/joshrpowell/gamechanger-cli/internal/store"
)

const (
	myTeam = "my-team-uuid"
	oppA   = "opp-A-uuid"
	oppB   = "opp-B-uuid"
)

// mockClient implements ScoutClient with scripted responses + call counters.
type mockClient struct {
	games         []client.GameSummary
	gamesErr      error
	gamesCalls    int
	details       map[string]*client.OpponentDetail // keyed by opponent UUID
	detailsErr    map[string]error
	detailsCalls  map[string]int
}

func newMock() *mockClient {
	return &mockClient{
		details:      map[string]*client.OpponentDetail{},
		detailsErr:   map[string]error{},
		detailsCalls: map[string]int{},
	}
}

func (m *mockClient) GameSummaries(ctx context.Context, _ string) ([]client.GameSummary, error) {
	m.gamesCalls++
	if m.gamesErr != nil {
		return nil, m.gamesErr
	}
	return m.games, nil
}

func (m *mockClient) OpponentDetail(ctx context.Context, _, oppUUID string) (*client.OpponentDetail, error) {
	m.detailsCalls[oppUUID]++
	if err, ok := m.detailsErr[oppUUID]; ok && err != nil {
		return nil, err
	}
	if d, ok := m.details[oppUUID]; ok {
		return d, nil
	}
	return nil, client.ErrTeamNotFound
}

// gs is a tiny helper for building scripted GameSummary entries.
func gs(eventID, oppID, homeAway, ts string, mine, theirs int, status string) client.GameSummary {
	return client.GameSummary{
		EventID:           eventID,
		GameStatus:        status,
		HomeAway:          homeAway,
		OwningTeamScore:   mine,
		OpponentTeamScore: theirs,
		LastScoringUpdate: ts,
		GameStream:        client.GameSummaryStream{GameID: eventID, OpponentID: oppID, HomeAway: homeAway, GameStatus: status},
	}
}

func newStore(t *testing.T) *store.Store {
	t.Helper()
	s, err := store.OpenAt(context.Background(), "", 2026)
	if err != nil {
		t.Fatalf("OpenAt: %v", err)
	}
	t.Cleanup(func() { _ = s.Close() })
	return s
}

func TestScout_HappyPath_ByName(t *testing.T) {
	st := newStore(t)
	mock := newMock()
	mock.games = []client.GameSummary{
		gs("e1", oppA, "home", "2026-04-15T22:00:00Z", 4, 7, "completed"),
		gs("e2", oppA, "away", "2026-03-22T20:00:00Z", 8, 3, "completed"),
		gs("e3", oppB, "home", "2026-02-08T18:00:00Z", 9, 8, "completed"),
	}
	mock.details[oppA] = &client.OpponentDetail{Name: "Eagles 12U"}
	mock.details[oppB] = &client.OpponentDetail{Name: "Tigers 12U"}

	h, err := Scout(context.Background(), st, mock, myTeam, "Eagles 12U", Options{})
	if err != nil {
		t.Fatalf("Scout: %v", err)
	}
	if h.Opponent.Name != "Eagles 12U" || h.Opponent.UUID != oppA {
		t.Errorf("opponent: %+v", h.Opponent)
	}
	if len(h.Games) != 2 {
		t.Fatalf("games: got %d; want 2 (only oppA games)", len(h.Games))
	}
	// DESC by date.
	if h.Games[0].Date != "2026-04-15" || h.Games[1].Date != "2026-03-22" {
		t.Errorf("DESC date sort failed: %s, %s", h.Games[0].Date, h.Games[1].Date)
	}
	// Outcome derivation.
	if h.Games[0].Outcome != "L" || h.Games[1].Outcome != "W" {
		t.Errorf("outcome: got %s, %s; want L, W", h.Games[0].Outcome, h.Games[1].Outcome)
	}
	// Both opponents got fetched + cached.
	if mock.detailsCalls[oppA] != 1 || mock.detailsCalls[oppB] != 1 {
		t.Errorf("detail calls: A=%d B=%d; want each=1", mock.detailsCalls[oppA], mock.detailsCalls[oppB])
	}
}

func TestScout_HappyPath_ByUUID(t *testing.T) {
	st := newStore(t)
	mock := newMock()
	mock.games = []client.GameSummary{gs("e1", oppA, "home", "2026-04-15T22:00:00Z", 4, 7, "completed")}
	mock.details[oppA] = &client.OpponentDetail{Name: "Eagles 12U"}

	h, err := Scout(context.Background(), st, mock, myTeam, oppA, Options{})
	if err != nil {
		t.Fatalf("Scout: %v", err)
	}
	if h.Opponent.UUID != oppA || h.Opponent.Name != "Eagles 12U" {
		t.Errorf("UUID-input resolve: %+v", h.Opponent)
	}
}

func TestScout_CaseInsensitiveName(t *testing.T) {
	st := newStore(t)
	mock := newMock()
	mock.games = []client.GameSummary{gs("e1", oppA, "home", "2026-04-15T22:00:00Z", 4, 7, "completed")}
	mock.details[oppA] = &client.OpponentDetail{Name: "Eagles 12U"}
	h, err := Scout(context.Background(), st, mock, myTeam, "eagles 12u", Options{})
	if err != nil {
		t.Fatalf("Scout: %v", err)
	}
	if h.Opponent.UUID != oppA {
		t.Errorf("case-insensitive name lookup failed: %+v", h.Opponent)
	}
}

func TestScout_OpponentNotResolvable(t *testing.T) {
	st := newStore(t)
	mock := newMock()
	mock.games = []client.GameSummary{gs("e1", oppA, "home", "2026-04-15T22:00:00Z", 4, 7, "completed")}
	mock.details[oppA] = &client.OpponentDetail{Name: "Eagles 12U"}
	_, err := Scout(context.Background(), st, mock, myTeam, "Phantom Team", Options{})
	if !errors.Is(err, ErrOpponentNotResolvable) {
		t.Fatalf("expected ErrOpponentNotResolvable; got %v", err)
	}
}

func TestScout_CacheEmpty(t *testing.T) {
	st := newStore(t)
	mock := newMock()
	mock.games = nil
	_, err := Scout(context.Background(), st, mock, myTeam, "anything", Options{})
	if !errors.Is(err, ErrCacheEmpty) {
		t.Fatalf("expected ErrCacheEmpty; got %v", err)
	}
}

func TestScout_CacheHitSkipsOpponentDetail(t *testing.T) {
	st := newStore(t)
	mock := newMock()
	mock.games = []client.GameSummary{gs("e1", oppA, "home", "2026-04-15T22:00:00Z", 4, 7, "completed")}
	// Pre-populate the cache with a fresh entry.
	fresh := time.Now().UTC().Format(time.RFC3339)
	_ = st.UpsertOpposingTeam(context.Background(), store.OpposingTeam{TeamUUID: oppA, TeamName: "Eagles 12U", LastFetchedAt: fresh})

	_, err := Scout(context.Background(), st, mock, myTeam, "Eagles 12U", Options{})
	if err != nil {
		t.Fatalf("Scout: %v", err)
	}
	if mock.detailsCalls[oppA] != 0 {
		t.Errorf("fresh cache should skip OpponentDetail; got %d calls", mock.detailsCalls[oppA])
	}
}

func TestScout_RefreshForcesReFetch(t *testing.T) {
	st := newStore(t)
	mock := newMock()
	mock.games = []client.GameSummary{gs("e1", oppA, "home", "2026-04-15T22:00:00Z", 4, 7, "completed")}
	mock.details[oppA] = &client.OpponentDetail{Name: "Eagles 12U Updated"}
	fresh := time.Now().UTC().Format(time.RFC3339)
	_ = st.UpsertOpposingTeam(context.Background(), store.OpposingTeam{TeamUUID: oppA, TeamName: "Eagles 12U OLD", LastFetchedAt: fresh})

	h, err := Scout(context.Background(), st, mock, myTeam, oppA, Options{Refresh: true})
	if err != nil {
		t.Fatalf("Scout: %v", err)
	}
	if mock.detailsCalls[oppA] != 1 {
		t.Errorf("--refresh should force OpponentDetail call; got %d", mock.detailsCalls[oppA])
	}
	if h.Opponent.Name != "Eagles 12U Updated" {
		t.Errorf("name not refreshed: %q", h.Opponent.Name)
	}
}

func TestScout_StaleCacheTriggersReFetch(t *testing.T) {
	st := newStore(t)
	mock := newMock()
	mock.games = []client.GameSummary{gs("e1", oppA, "home", "2026-04-15T22:00:00Z", 4, 7, "completed")}
	mock.details[oppA] = &client.OpponentDetail{Name: "Eagles 12U"}
	// Pre-populate with an OLD timestamp.
	old := time.Now().Add(-48 * time.Hour).UTC().Format(time.RFC3339)
	_ = st.UpsertOpposingTeam(context.Background(), store.OpposingTeam{TeamUUID: oppA, TeamName: "Eagles 12U", LastFetchedAt: old})

	_, err := Scout(context.Background(), st, mock, myTeam, oppA, Options{})
	if err != nil {
		t.Fatalf("Scout: %v", err)
	}
	if mock.detailsCalls[oppA] != 1 {
		t.Errorf("stale (>24h) cache should trigger re-fetch; got %d calls", mock.detailsCalls[oppA])
	}
}

func TestScout_GameSummariesError(t *testing.T) {
	st := newStore(t)
	mock := newMock()
	mock.gamesErr = client.ErrTeamNotFound
	_, err := Scout(context.Background(), st, mock, myTeam, "any", Options{})
	if !errors.Is(err, client.ErrTeamNotFound) {
		t.Fatalf("expected client.ErrTeamNotFound; got %v", err)
	}
}

func TestScout_OpponentDetailError_PropagatesAuthInsufficient(t *testing.T) {
	st := newStore(t)
	mock := newMock()
	mock.games = []client.GameSummary{gs("e1", oppA, "home", "2026-04-15T22:00:00Z", 4, 7, "completed")}
	mock.detailsErr[oppA] = gcerr.AuthInsufficientf("scope denied")
	_, err := Scout(context.Background(), st, mock, myTeam, oppA, Options{})
	if !errors.Is(err, gcerr.ErrAuthInsufficient) {
		t.Fatalf("expected gcerr.ErrAuthInsufficient; got %v", err)
	}
}

func TestScout_EmptyInputs(t *testing.T) {
	st := newStore(t)
	mock := newMock()
	if _, err := Scout(context.Background(), st, mock, "", "x", Options{}); !errors.Is(err, gcerr.ErrConfig) {
		t.Errorf("empty teamUUID should return ErrConfig; got %v", err)
	}
	if _, err := Scout(context.Background(), st, mock, myTeam, "", Options{}); !errors.Is(err, gcerr.ErrConfig) {
		t.Errorf("empty opponent should return ErrConfig; got %v", err)
	}
}

func TestScout_LimitGames(t *testing.T) {
	st := newStore(t)
	mock := newMock()
	mock.games = []client.GameSummary{
		gs("e1", oppA, "home", "2026-04-15T22:00:00Z", 4, 7, "completed"),
		gs("e2", oppA, "away", "2026-03-22T20:00:00Z", 8, 3, "completed"),
		gs("e3", oppA, "home", "2026-02-08T18:00:00Z", 9, 8, "completed"),
	}
	mock.details[oppA] = &client.OpponentDetail{Name: "Eagles 12U"}
	h, err := Scout(context.Background(), st, mock, myTeam, oppA, Options{LimitGames: 2})
	if err != nil {
		t.Fatalf("Scout: %v", err)
	}
	if len(h.Games) != 2 {
		t.Fatalf("LimitGames=2; got %d games", len(h.Games))
	}
	if h.Games[0].Date != "2026-04-15" || h.Games[1].Date != "2026-03-22" {
		t.Errorf("LimitGames kept wrong games: %v, %v", h.Games[0].Date, h.Games[1].Date)
	}
}

func TestScout_InProgressGameNoOutcome(t *testing.T) {
	st := newStore(t)
	mock := newMock()
	mock.games = []client.GameSummary{gs("e1", oppA, "home", "2026-04-15T22:00:00Z", 4, 4, "in_progress")}
	mock.details[oppA] = &client.OpponentDetail{Name: "Eagles 12U"}
	h, err := Scout(context.Background(), st, mock, myTeam, oppA, Options{})
	if err != nil {
		t.Fatalf("Scout: %v", err)
	}
	if h.Games[0].Outcome != "" {
		t.Errorf("non-completed game should have empty Outcome; got %q", h.Games[0].Outcome)
	}
}

func TestScout_TieOutcome(t *testing.T) {
	st := newStore(t)
	mock := newMock()
	mock.games = []client.GameSummary{gs("e1", oppA, "home", "2026-04-15T22:00:00Z", 5, 5, "completed")}
	mock.details[oppA] = &client.OpponentDetail{Name: "Eagles 12U"}
	h, err := Scout(context.Background(), st, mock, myTeam, oppA, Options{})
	if err != nil {
		t.Fatalf("Scout: %v", err)
	}
	if h.Games[0].Outcome != "T" {
		t.Errorf("tie game outcome: got %q; want T", h.Games[0].Outcome)
	}
}
