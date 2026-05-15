package parity

import (
	"context"
	"os"
	"path/filepath"
	"testing"
)

// AnchorFixturePath returns the path to the committed anchor fixture relative
// to this package directory (where go test runs from).
const AnchorFixturePath = "testdata/cache-anchor.db"

func TestOpen_AnchorFixtureExists(t *testing.T) {
	if _, err := os.Stat(AnchorFixturePath); err != nil {
		t.Fatalf("anchor fixture missing at %s — regenerate with `go run ./cmd/anonymize-fixture --source ~/.gamechanger/cache.db --out internal/parity/testdata/cache-anchor.db`: %v", AnchorFixturePath, err)
	}
}

func TestOpen_AnchorFixtureOpens(t *testing.T) {
	db, err := Open(context.Background(), AnchorFixturePath)
	if err != nil {
		t.Fatalf("Open: %v", err)
	}
	defer db.Close()
	if err := db.PingContext(context.Background()); err != nil {
		t.Errorf("Ping: %v", err)
	}
}

func TestOpen_AnchorHasAtLeast5Games(t *testing.T) {
	db, err := Open(context.Background(), AnchorFixturePath)
	if err != nil {
		t.Fatalf("Open: %v", err)
	}
	defer db.Close()

	var n int
	if err := db.QueryRow("SELECT COUNT(*) FROM games").Scan(&n); err != nil {
		t.Fatalf("count games: %v", err)
	}
	if n < 5 {
		t.Errorf("game count: want >=5, got %d", n)
	}
}

func TestOpen_AnchorHasAtLeast3DistinctPlayers(t *testing.T) {
	db, err := Open(context.Background(), AnchorFixturePath)
	if err != nil {
		t.Fatalf("Open: %v", err)
	}
	defer db.Close()

	var n int
	err = db.QueryRow(`
		SELECT COUNT(*) FROM (
			SELECT DISTINCT pitcher_name AS name FROM game_pitcher_stats
			UNION
			SELECT DISTINCT batter_name FROM game_batter_stats
		)
	`).Scan(&n)
	if err != nil {
		t.Fatalf("count players: %v", err)
	}
	if n < 3 {
		t.Errorf("distinct player count: want >=3, got %d", n)
	}
}

// TestOpen_AnchorHasEnoughFinalGames checks that the analytics-relevant slice
// of the fixture is large enough to exercise U5's engine. The fixture
// faithfully copies the source schema, which may include scheduled (not yet
// played) games — those are invisible to analytics queries (every Ruby/Go
// analytics SQL filters `WHERE status = 'final'`), so their presence is
// harmless. What matters is having enough final-status games for the harness
// to do real work against.
func TestOpen_AnchorHasEnoughFinalGames(t *testing.T) {
	db, err := Open(context.Background(), AnchorFixturePath)
	if err != nil {
		t.Fatalf("Open: %v", err)
	}
	defer db.Close()

	var finalCount int
	if err := db.QueryRow("SELECT COUNT(*) FROM games WHERE status = 'final'").Scan(&finalCount); err != nil {
		t.Fatalf("count final games: %v", err)
	}
	if finalCount < 5 {
		t.Errorf("final-status game count: want >=5, got %d", finalCount)
	}

	// Guard against null/empty status sneaking in.
	var unknownCount int
	if err := db.QueryRow("SELECT COUNT(*) FROM games WHERE status IS NULL OR status = ''").Scan(&unknownCount); err != nil {
		t.Fatalf("count unknown status: %v", err)
	}
	if unknownCount > 0 {
		t.Errorf("found %d games with null/empty status — schema invariant violated", unknownCount)
	}
}

// TestOpen_NoSidecarsCreated guards the U4 feasibility fix: the anchor must be
// opened read-only/immutable so SQLite does NOT create -wal or -shm sidecar
// files next to the committed binary. If sidecars appear in testdata/ after a
// test run, every contributor's working tree gets noisy untracked files and CI
// fails on dirty-tree checks.
func TestOpen_NoSidecarsCreated(t *testing.T) {
	beforeWal, _ := os.Stat(AnchorFixturePath + "-wal")
	beforeShm, _ := os.Stat(AnchorFixturePath + "-shm")
	if beforeWal != nil {
		t.Fatalf("precondition failed: %s-wal exists before Open; delete it and re-run", AnchorFixturePath)
	}
	if beforeShm != nil {
		t.Fatalf("precondition failed: %s-shm exists before Open; delete it and re-run", AnchorFixturePath)
	}

	db, err := Open(context.Background(), AnchorFixturePath)
	if err != nil {
		t.Fatalf("Open: %v", err)
	}
	// Exercise a few reads to give SQLite a chance to create sidecars if it would.
	if _, err := db.Query("SELECT * FROM games LIMIT 1"); err != nil {
		t.Fatalf("query games: %v", err)
	}
	if _, err := db.Query("SELECT * FROM game_pitcher_stats LIMIT 1"); err != nil {
		t.Fatalf("query pitcher_stats: %v", err)
	}
	db.Close()

	if _, err := os.Stat(AnchorFixturePath + "-wal"); err == nil {
		t.Errorf("Open created %s-wal — DSN should be mode=ro&immutable=1", AnchorFixturePath)
	}
	if _, err := os.Stat(AnchorFixturePath + "-shm"); err == nil {
		t.Errorf("Open created %s-shm — DSN should be mode=ro&immutable=1", AnchorFixturePath)
	}
}

func TestOpen_MissingFile(t *testing.T) {
	dir := t.TempDir()
	missing := filepath.Join(dir, "nope.db")
	_, err := Open(context.Background(), missing)
	if err == nil {
		t.Errorf("Open(nonexistent) returned nil error")
	}
}
