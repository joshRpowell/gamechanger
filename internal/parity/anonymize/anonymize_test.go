package anonymize

import (
	"context"
	"database/sql"
	"errors"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	_ "modernc.org/sqlite"
)

// fixedSeed is a deterministic 32-byte seed for tests that need byte-identical regeneration.
var fixedSeed = []byte{
	0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07, 0x08,
	0x09, 0x0a, 0x0b, 0x0c, 0x0d, 0x0e, 0x0f, 0x10,
	0x11, 0x12, 0x13, 0x14, 0x15, 0x16, 0x17, 0x18,
	0x19, 0x1a, 0x1b, 0x1c, 0x1d, 0x1e, 0x1f, 0x20,
}
var otherSeed = []byte{
	0xff, 0xfe, 0xfd, 0xfc, 0xfb, 0xfa, 0xf9, 0xf8,
	0xf7, 0xf6, 0xf5, 0xf4, 0xf3, 0xf2, 0xf1, 0xf0,
	0xef, 0xee, 0xed, 0xec, 0xeb, 0xea, 0xe9, 0xe8,
	0xe7, 0xe6, 0xe5, 0xe4, 0xe3, 0xe2, 0xe1, 0xe0,
}

// sampleSource describes a deterministic source SQLite fixture for tests.
type sampleSource struct {
	games        []sampleGame
	pitcherNames []string
	batterNames  []string
}

type sampleGame struct {
	gameID   string
	date     string // YYYY-MM-DD
	opponent string
	homeAway string
	status   string
	pitchers []samplePitcher
	batters  []sampleBatter
}

type samplePitcher struct {
	name           string
	pitchesThrown  int
	strikesThrown  int
	inningsPitched float64
}

type sampleBatter struct {
	name       string
	atBats     int
	hits       int
	walks      int
	strikeouts int
}

// buildSourceDB writes a source SQLite at `path` containing the data in `s`.
// Schema mirrors internal/store/migrations.go up to migration 3.
func buildSourceDB(t *testing.T, path string, s sampleSource) {
	t.Helper()
	db, err := sql.Open("sqlite", path)
	if err != nil {
		t.Fatalf("open source: %v", err)
	}
	defer db.Close()

	for _, stmt := range []string{
		`CREATE TABLE games (
			id INTEGER PRIMARY KEY,
			game_id TEXT NOT NULL UNIQUE,
			game_date TEXT NOT NULL,
			opponent TEXT,
			home_away TEXT,
			status TEXT,
			fetched_at TEXT NOT NULL,
			first_seen_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%SZ', 'now'))
		)`,
		`CREATE TABLE game_pitcher_stats (
			id INTEGER PRIMARY KEY,
			game_id TEXT NOT NULL REFERENCES games(game_id) ON DELETE CASCADE,
			pitcher_name TEXT NOT NULL,
			pitches_thrown INTEGER NOT NULL DEFAULT 0,
			innings_pitched REAL,
			fetched_at TEXT NOT NULL,
			first_seen_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%SZ', 'now')),
			strikes_thrown INTEGER,
			UNIQUE(game_id, pitcher_name)
		)`,
		`CREATE TABLE game_batter_stats (
			id INTEGER PRIMARY KEY,
			game_id TEXT NOT NULL REFERENCES games(game_id) ON DELETE CASCADE,
			batter_name TEXT NOT NULL,
			at_bats INTEGER NOT NULL DEFAULT 0,
			hits INTEGER NOT NULL DEFAULT 0,
			walks INTEGER NOT NULL DEFAULT 0,
			strikeouts INTEGER NOT NULL DEFAULT 0,
			fetched_at TEXT NOT NULL,
			UNIQUE(game_id, batter_name)
		)`,
	} {
		if _, err := db.Exec(stmt); err != nil {
			t.Fatalf("create schema: %v\n%s", err, stmt)
		}
	}

	for _, g := range s.games {
		_, err := db.Exec(`INSERT INTO games (game_id, game_date, opponent, home_away, status, fetched_at) VALUES (?, ?, ?, ?, ?, ?)`,
			g.gameID, g.date, g.opponent, g.homeAway, g.status, "2026-01-01T00:00:00Z")
		if err != nil {
			t.Fatalf("insert game: %v", err)
		}
		for _, p := range g.pitchers {
			_, err := db.Exec(`INSERT INTO game_pitcher_stats (game_id, pitcher_name, pitches_thrown, strikes_thrown, innings_pitched, fetched_at) VALUES (?, ?, ?, ?, ?, ?)`,
				g.gameID, p.name, p.pitchesThrown, p.strikesThrown, p.inningsPitched, "2026-01-01T00:00:00Z")
			if err != nil {
				t.Fatalf("insert pitcher_stats: %v", err)
			}
		}
		for _, b := range g.batters {
			_, err := db.Exec(`INSERT INTO game_batter_stats (game_id, batter_name, at_bats, hits, walks, strikeouts, fetched_at) VALUES (?, ?, ?, ?, ?, ?, ?)`,
				g.gameID, b.name, b.atBats, b.hits, b.walks, b.strikeouts, "2026-01-01T00:00:00Z")
			if err != nil {
				t.Fatalf("insert batter_stats: %v", err)
			}
		}
	}
}

// defaultSource returns a 5-game, 3-player sample fixture.
func defaultSource() sampleSource {
	return sampleSource{
		games: []sampleGame{
			{
				gameID: "real-uuid-001", date: "2026-04-04", opponent: "SF Bulls 11U Select", homeAway: "home", status: "final",
				pitchers: []samplePitcher{
					{name: "Bobby Grace", pitchesThrown: 32, strikesThrown: 18, inningsPitched: 1.0},
					{name: "Clayton Meyerson", pitchesThrown: 65, strikesThrown: 42, inningsPitched: 4.0},
				},
				batters: []sampleBatter{
					{name: "Asher Lima", atBats: 3, hits: 1, walks: 1, strikeouts: 1},
					{name: "Mason Marrero", atBats: 2, hits: 0, walks: 1, strikeouts: 1},
					{name: "Chris Freitas", atBats: 4, hits: 2, walks: 0, strikeouts: 1},
				},
			},
			{
				gameID: "real-uuid-002", date: "2026-04-05", opponent: "Diablo Crush", homeAway: "away", status: "final",
				pitchers: []samplePitcher{{name: "Bobby Grace", pitchesThrown: 28, strikesThrown: 16, inningsPitched: 1.0}},
				batters: []sampleBatter{
					{name: "Asher Lima", atBats: 3, hits: 2, walks: 0, strikeouts: 0},
					{name: "Mason Marrero", atBats: 3, hits: 1, walks: 0, strikeouts: 1},
				},
			},
			{
				gameID: "real-uuid-003", date: "2026-04-11", opponent: "Norcal Mavericks", homeAway: "home", status: "final",
				pitchers: []samplePitcher{{name: "Clayton Meyerson", pitchesThrown: 70, strikesThrown: 45, inningsPitched: 4.5}},
				batters: []sampleBatter{
					{name: "Asher Lima", atBats: 4, hits: 1, walks: 1, strikeouts: 1},
					{name: "Chris Freitas", atBats: 3, hits: 1, walks: 0, strikeouts: 1},
				},
			},
			{
				gameID: "real-uuid-004", date: "2026-04-12", opponent: "SF Bulls 11U Select", homeAway: "home", status: "final",
				pitchers: []samplePitcher{{name: "Bobby Grace", pitchesThrown: 35, strikesThrown: 22, inningsPitched: 1.5}},
				batters: []sampleBatter{
					{name: "Mason Marrero", atBats: 3, hits: 1, walks: 0, strikeouts: 0},
				},
			},
			{
				gameID: "real-uuid-005", date: "2026-04-18", opponent: "Bay Area Sox", homeAway: "away", status: "final",
				pitchers: []samplePitcher{{name: "Clayton Meyerson", pitchesThrown: 55, strikesThrown: 30, inningsPitched: 3.0}},
				batters: []sampleBatter{
					{name: "Asher Lima", atBats: 2, hits: 0, walks: 1, strikeouts: 1},
					{name: "Chris Freitas", atBats: 3, hits: 2, walks: 0, strikeouts: 0},
				},
			},
		},
		pitcherNames: []string{"Bobby Grace", "Clayton Meyerson"},
		batterNames:  []string{"Asher Lima", "Mason Marrero", "Chris Freitas"},
	}
}

// runAnon is a test helper that anonymizes a default source into a temp dir.
func runAnon(t *testing.T, seed []byte) (sourcePath, outPath, mapDir string, res *Result) {
	t.Helper()
	dir := t.TempDir()
	sourcePath = filepath.Join(dir, "source.db")
	outPath = filepath.Join(dir, "fixture.db")
	mapDir = filepath.Join(dir, "map")
	if err := os.MkdirAll(mapDir, 0o700); err != nil {
		t.Fatalf("mkdir map: %v", err)
	}

	buildSourceDB(t, sourcePath, defaultSource())

	res, err := Run(context.Background(), Options{
		SourcePath: sourcePath,
		OutputPath: outPath,
		MapDir:     mapDir,
		Seed:       seed,
	})
	if err != nil {
		t.Fatalf("Run: %v", err)
	}
	return sourcePath, outPath, mapDir, res
}

// ───── Happy path ────────────────────────────────────────────────────────────

func TestRun_HappyPath_GameCountPreserved(t *testing.T) {
	_, outPath, _, _ := runAnon(t, fixedSeed)
	got := countRows(t, outPath, "games")
	if got != 5 {
		t.Errorf("game count: want 5, got %d", got)
	}
}

func TestRun_HappyPath_OutingCountPreserved(t *testing.T) {
	src := defaultSource()
	wantOutings := 0
	for _, g := range src.games {
		wantOutings += len(g.pitchers)
	}
	_, outPath, _, _ := runAnon(t, fixedSeed)
	got := countRows(t, outPath, "game_pitcher_stats")
	if got != wantOutings {
		t.Errorf("outings: want %d, got %d", wantOutings, got)
	}
}

func TestRun_HappyPath_BatterRowCountPreserved(t *testing.T) {
	src := defaultSource()
	wantBatterRows := 0
	for _, g := range src.games {
		wantBatterRows += len(g.batters)
	}
	_, outPath, _, _ := runAnon(t, fixedSeed)
	got := countRows(t, outPath, "game_batter_stats")
	if got != wantBatterRows {
		t.Errorf("batter rows: want %d, got %d", wantBatterRows, got)
	}
}

func TestRun_HappyPath_NoRealNamesPresent(t *testing.T) {
	_, outPath, _, _ := runAnon(t, fixedSeed)
	src := defaultSource()
	realNames := []string{}
	for _, g := range src.games {
		realNames = append(realNames, g.opponent)
		for _, p := range g.pitchers {
			realNames = append(realNames, p.name)
		}
		for _, b := range g.batters {
			realNames = append(realNames, b.name)
		}
	}
	for _, real := range realNames {
		if found, where := nameAppears(t, outPath, real); found {
			t.Errorf("real name %q leaked into output (column %q)", real, where)
		}
	}
}

// ───── R8c: day-of-week NOT preserved ────────────────────────────────────────

func TestRun_R8c_DayOfWeekNotPreserved(t *testing.T) {
	// The plan deliberately drops day-of-week preservation (eng review SEC-ANON-01).
	// Random 0-365 day offset scrambles weekday alignment for most seeds.
	_, outPath, _, _ := runAnon(t, fixedSeed)
	src := defaultSource()

	srcDates := make(map[time.Weekday]int)
	for _, g := range src.games {
		td, _ := time.Parse("2006-01-02", g.date)
		srcDates[td.Weekday()]++
	}

	outDates := getGameDates(t, outPath)
	outWeekdays := make(map[time.Weekday]int)
	for _, td := range outDates {
		outWeekdays[td.Weekday()]++
	}

	// They could match by coincidence with a particular seed. The invariant we
	// CAN assert reliably: there is no single uniform date-shift in days that
	// would explain every source→output pair (which a day-of-week-preserving
	// shift would produce). i.e., shifts are heterogeneous.
	// For the simpler test: assert at least one game's weekday differs from its source.
	shifted := 0
	for i, td := range outDates {
		srcTd, _ := time.Parse("2006-01-02", src.games[i].date)
		if td.Weekday() != srcTd.Weekday() {
			shifted++
		}
	}
	if shifted == 0 {
		t.Errorf("R8c violation: every output game weekday matched source weekday (no shift). Output dates: %v", outDates)
	}
}

func TestRun_R8c_AllShiftsWithinYear(t *testing.T) {
	// Each game_date shifts by 0-365 days. Output dates fall within ±366 days of source.
	_, outPath, _, _ := runAnon(t, fixedSeed)
	src := defaultSource()
	outDates := getGameDates(t, outPath)
	for i, td := range outDates {
		srcTd, _ := time.Parse("2006-01-02", src.games[i].date)
		diff := td.Sub(srcTd).Hours() / 24
		if diff < -366 || diff > 366 {
			t.Errorf("game %d shifted %f days; want within ±366", i, diff)
		}
	}
}

// ───── R8e: substitution map written outside repo ────────────────────────────

func TestRun_R8e_MapWrittenToMapDir(t *testing.T) {
	_, _, mapDir, res := runAnon(t, fixedSeed)
	if res.MapPath == "" {
		t.Fatal("MapPath empty in Result")
	}
	if !strings.HasPrefix(res.MapPath, mapDir) {
		t.Errorf("MapPath %q not under MapDir %q", res.MapPath, mapDir)
	}
	info, err := os.Stat(res.MapPath)
	if err != nil {
		t.Fatalf("stat map: %v", err)
	}
	if info.Size() == 0 {
		t.Error("map file is empty")
	}
	if info.Mode().Perm() != 0o600 {
		t.Errorf("map permissions: want 0600, got %o (must be user-only — contains real-name mappings)", info.Mode().Perm())
	}
}

func TestRun_R8e_MapContainsRealAndSyntheticNames(t *testing.T) {
	_, _, _, res := runAnon(t, fixedSeed)
	mapBytes, err := os.ReadFile(res.MapPath)
	if err != nil {
		t.Fatalf("read map: %v", err)
	}
	src := defaultSource()
	mapStr := string(mapBytes)
	// Every real player name must appear in the map (as a key).
	for _, name := range append(src.pitcherNames, src.batterNames...) {
		if !strings.Contains(mapStr, name) {
			t.Errorf("substitution map missing real name %q", name)
		}
	}
}

// ───── R9: determinism + cross-version unlinkability ─────────────────────────

func TestRun_R9_SameSeedProducesIdenticalOutput(t *testing.T) {
	// Two separate runs with the same source and the same seed should produce
	// byte-identical fixture SQLite files. (Modulo SQLite internal byte-level
	// ordering — we compare canonical content via SELECT *, not raw bytes.)
	dir := t.TempDir()
	source := filepath.Join(dir, "source.db")
	buildSourceDB(t, source, defaultSource())

	run := func(out, mapDir string) {
		if err := os.MkdirAll(mapDir, 0o700); err != nil {
			t.Fatalf("mkdir: %v", err)
		}
		_, err := Run(context.Background(), Options{
			SourcePath: source, OutputPath: out, MapDir: mapDir, Seed: fixedSeed,
		})
		if err != nil {
			t.Fatalf("Run: %v", err)
		}
	}

	run(filepath.Join(dir, "out1.db"), filepath.Join(dir, "map1"))
	run(filepath.Join(dir, "out2.db"), filepath.Join(dir, "map2"))

	c1 := canonicalSnapshot(t, filepath.Join(dir, "out1.db"))
	c2 := canonicalSnapshot(t, filepath.Join(dir, "out2.db"))
	if c1 != c2 {
		t.Errorf("non-deterministic output for fixed seed.\nrun1:\n%s\nrun2:\n%s", c1, c2)
	}
}

func TestRun_R9_DifferentSeedProducesDifferentMapping(t *testing.T) {
	dir := t.TempDir()
	source := filepath.Join(dir, "source.db")
	buildSourceDB(t, source, defaultSource())

	run := func(seed []byte, suffix string) []string {
		mapDir := filepath.Join(dir, "map-"+suffix)
		out := filepath.Join(dir, "out-"+suffix+".db")
		if err := os.MkdirAll(mapDir, 0o700); err != nil {
			t.Fatalf("mkdir: %v", err)
		}
		_, err := Run(context.Background(), Options{
			SourcePath: source, OutputPath: out, MapDir: mapDir, Seed: seed,
		})
		if err != nil {
			t.Fatalf("Run: %v", err)
		}
		return playerNamesIn(t, out)
	}

	a := run(fixedSeed, "a")
	b := run(otherSeed, "b")

	// Cross-version linkability test: <5% name overlap.
	overlap := 0
	aset := map[string]bool{}
	for _, n := range a {
		aset[n] = true
	}
	for _, n := range b {
		if aset[n] {
			overlap++
		}
	}
	total := len(a)
	if total == 0 {
		t.Fatal("seed-a produced no synthetic names")
	}
	pct := float64(overlap) / float64(total) * 100
	if pct >= 5.0 {
		t.Errorf("cross-seed name overlap %.1f%% (>5%%) — substitution map is linkable across regenerations", pct)
	}
}

// ───── Stat perturbation constraints ─────────────────────────────────────────

func TestRun_StatConstraints_BatterAtBatsGeHits(t *testing.T) {
	_, outPath, _, _ := runAnon(t, fixedSeed)
	rows := allBatterStats(t, outPath)
	for i, r := range rows {
		if r.atBats < r.hits {
			t.Errorf("batter row %d: at_bats (%d) < hits (%d)", i, r.atBats, r.hits)
		}
		if r.atBats < 0 || r.hits < 0 || r.walks < 0 || r.strikeouts < 0 {
			t.Errorf("batter row %d: negative stat (ab=%d, h=%d, bb=%d, k=%d)", i, r.atBats, r.hits, r.walks, r.strikeouts)
		}
		if r.strikeouts > r.atBats {
			t.Errorf("batter row %d: strikeouts (%d) > at_bats (%d)", i, r.strikeouts, r.atBats)
		}
	}
}

func TestRun_StatConstraints_PitcherPitchesGeStrikes(t *testing.T) {
	_, outPath, _, _ := runAnon(t, fixedSeed)
	rows := allPitcherStats(t, outPath)
	for i, r := range rows {
		if r.pitchesThrown < r.strikesThrown {
			t.Errorf("pitcher row %d: pitches_thrown (%d) < strikes_thrown (%d)", i, r.pitchesThrown, r.strikesThrown)
		}
		if r.pitchesThrown < 0 || r.strikesThrown < 0 {
			t.Errorf("pitcher row %d: negative count (pt=%d, st=%d)", i, r.pitchesThrown, r.strikesThrown)
		}
	}
}

// ───── Same player → same synthetic name within a fixture ────────────────────

func TestRun_NameSubstitution_StableWithinFixture(t *testing.T) {
	_, outPath, _, _ := runAnon(t, fixedSeed)
	// All rows for the same source pitcher should map to the SAME synthetic name.
	// We can verify by counting: source has Bobby Grace in 3 games. If the
	// substitution is stable, the output should have exactly one synthetic name
	// across those 3 games. (Pre-anonymization there were 5 pitcher rows for
	// 2 real pitchers; post-anonymization there should be 5 rows for 2 synthetic
	// pitchers — same multiset structure.)
	pitchers := allPitcherStats(t, outPath)
	uniqueNames := map[string]int{}
	for _, p := range pitchers {
		uniqueNames[p.name]++
	}
	if len(uniqueNames) != 2 {
		t.Errorf("expected 2 unique synthetic pitcher names (matching 2 real pitchers), got %d: %v", len(uniqueNames), uniqueNames)
	}
}

// ───── Error paths (per /plan-eng-review D8) ─────────────────────────────────

func TestRun_ErrSourceMissing(t *testing.T) {
	dir := t.TempDir()
	_, err := Run(context.Background(), Options{
		SourcePath: filepath.Join(dir, "nope.db"),
		OutputPath: filepath.Join(dir, "out.db"),
		MapDir:     dir,
		Seed:       fixedSeed,
	})
	if !errors.Is(err, ErrSourceMissing) {
		t.Errorf("want ErrSourceMissing, got %v", err)
	}
}

func TestRun_ErrSourceCorrupt(t *testing.T) {
	dir := t.TempDir()
	source := filepath.Join(dir, "corrupt.db")
	// Write garbage that isn't a valid SQLite header.
	if err := os.WriteFile(source, []byte("this is not a sqlite file at all"), 0o600); err != nil {
		t.Fatalf("write garbage: %v", err)
	}
	_, err := Run(context.Background(), Options{
		SourcePath: source,
		OutputPath: filepath.Join(dir, "out.db"),
		MapDir:     dir,
		Seed:       fixedSeed,
	})
	if !errors.Is(err, ErrSourceCorrupt) {
		t.Errorf("want ErrSourceCorrupt, got %v", err)
	}
}

func TestRun_ErrSourceSchema(t *testing.T) {
	dir := t.TempDir()
	source := filepath.Join(dir, "wrong-schema.db")
	// Build a valid SQLite but with a games table that lacks the game_date column.
	db, err := sql.Open("sqlite", source)
	if err != nil {
		t.Fatalf("open: %v", err)
	}
	if _, err := db.Exec(`CREATE TABLE games (id INTEGER PRIMARY KEY, game_id TEXT)`); err != nil {
		t.Fatalf("create wrong schema: %v", err)
	}
	db.Close()

	_, err = Run(context.Background(), Options{
		SourcePath: source,
		OutputPath: filepath.Join(dir, "out.db"),
		MapDir:     dir,
		Seed:       fixedSeed,
	})
	if !errors.Is(err, ErrSourceSchema) {
		t.Errorf("want ErrSourceSchema, got %v", err)
	}
}

// ───── Fresh-seed generation when none provided ──────────────────────────────

func TestRun_NoSeedProvided_GeneratesFreshSeed(t *testing.T) {
	dir := t.TempDir()
	source := filepath.Join(dir, "source.db")
	buildSourceDB(t, source, defaultSource())

	run := func(suffix string) []byte {
		mapDir := filepath.Join(dir, "map-"+suffix)
		out := filepath.Join(dir, "out-"+suffix+".db")
		if err := os.MkdirAll(mapDir, 0o700); err != nil {
			t.Fatalf("mkdir: %v", err)
		}
		res, err := Run(context.Background(), Options{
			SourcePath: source, OutputPath: out, MapDir: mapDir,
			// Seed: nil → generate fresh
		})
		if err != nil {
			t.Fatalf("Run: %v", err)
		}
		if len(res.Seed) == 0 {
			t.Fatal("Result.Seed empty after fresh generation")
		}
		return res.Seed
	}

	a := run("a")
	b := run("b")

	if equalBytes(a, b) {
		t.Errorf("fresh seeds collided across two runs: %x", a)
	}
}

// ───── Helpers ───────────────────────────────────────────────────────────────

func countRows(t *testing.T, dbPath, table string) int {
	t.Helper()
	db, err := sql.Open("sqlite", dbPath)
	if err != nil {
		t.Fatalf("open %s: %v", dbPath, err)
	}
	defer db.Close()
	var n int
	if err := db.QueryRow("SELECT COUNT(*) FROM " + table).Scan(&n); err != nil {
		t.Fatalf("count %s: %v", table, err)
	}
	return n
}

func nameAppears(t *testing.T, dbPath, name string) (bool, string) {
	t.Helper()
	db, err := sql.Open("sqlite", dbPath)
	if err != nil {
		t.Fatalf("open: %v", err)
	}
	defer db.Close()
	for _, q := range []struct {
		col, table string
	}{
		{"opponent", "games"},
		{"pitcher_name", "game_pitcher_stats"},
		{"batter_name", "game_batter_stats"},
	} {
		var found int
		err := db.QueryRow("SELECT COUNT(*) FROM "+q.table+" WHERE "+q.col+" = ?", name).Scan(&found)
		if err != nil {
			t.Fatalf("scan %s.%s: %v", q.table, q.col, err)
		}
		if found > 0 {
			return true, q.table + "." + q.col
		}
	}
	return false, ""
}

func getGameDates(t *testing.T, dbPath string) []time.Time {
	t.Helper()
	db, err := sql.Open("sqlite", dbPath)
	if err != nil {
		t.Fatalf("open: %v", err)
	}
	defer db.Close()
	rows, err := db.Query("SELECT game_date FROM games ORDER BY id ASC")
	if err != nil {
		t.Fatalf("query: %v", err)
	}
	defer rows.Close()
	var out []time.Time
	for rows.Next() {
		var s string
		if err := rows.Scan(&s); err != nil {
			t.Fatalf("scan: %v", err)
		}
		td, err := time.Parse("2006-01-02", s)
		if err != nil {
			t.Fatalf("parse date %q: %v", s, err)
		}
		out = append(out, td)
	}
	return out
}

type pitcherRow struct {
	name                       string
	pitchesThrown, strikesThrown int
}

func allPitcherStats(t *testing.T, dbPath string) []pitcherRow {
	t.Helper()
	db, err := sql.Open("sqlite", dbPath)
	if err != nil {
		t.Fatalf("open: %v", err)
	}
	defer db.Close()
	rows, err := db.Query("SELECT pitcher_name, pitches_thrown, COALESCE(strikes_thrown, 0) FROM game_pitcher_stats ORDER BY id ASC")
	if err != nil {
		t.Fatalf("query: %v", err)
	}
	defer rows.Close()
	var out []pitcherRow
	for rows.Next() {
		var p pitcherRow
		if err := rows.Scan(&p.name, &p.pitchesThrown, &p.strikesThrown); err != nil {
			t.Fatalf("scan: %v", err)
		}
		out = append(out, p)
	}
	return out
}

type batterRow struct {
	name                                    string
	atBats, hits, walks, strikeouts int
}

func allBatterStats(t *testing.T, dbPath string) []batterRow {
	t.Helper()
	db, err := sql.Open("sqlite", dbPath)
	if err != nil {
		t.Fatalf("open: %v", err)
	}
	defer db.Close()
	rows, err := db.Query("SELECT batter_name, at_bats, hits, walks, strikeouts FROM game_batter_stats ORDER BY id ASC")
	if err != nil {
		t.Fatalf("query: %v", err)
	}
	defer rows.Close()
	var out []batterRow
	for rows.Next() {
		var b batterRow
		if err := rows.Scan(&b.name, &b.atBats, &b.hits, &b.walks, &b.strikeouts); err != nil {
			t.Fatalf("scan: %v", err)
		}
		out = append(out, b)
	}
	return out
}

func playerNamesIn(t *testing.T, dbPath string) []string {
	t.Helper()
	db, err := sql.Open("sqlite", dbPath)
	if err != nil {
		t.Fatalf("open: %v", err)
	}
	defer db.Close()
	rows, err := db.Query(`
		SELECT DISTINCT pitcher_name FROM game_pitcher_stats
		UNION
		SELECT DISTINCT batter_name FROM game_batter_stats
	`)
	if err != nil {
		t.Fatalf("query: %v", err)
	}
	defer rows.Close()
	var out []string
	for rows.Next() {
		var s string
		if err := rows.Scan(&s); err != nil {
			t.Fatalf("scan: %v", err)
		}
		out = append(out, s)
	}
	return out
}

// canonicalSnapshot returns a stable string representation of the fixture for
// determinism tests. Excludes timestamp columns and the meta seed (which depends
// on absolute time of the run, not the seed itself).
func canonicalSnapshot(t *testing.T, dbPath string) string {
	t.Helper()
	db, err := sql.Open("sqlite", dbPath)
	if err != nil {
		t.Fatalf("open: %v", err)
	}
	defer db.Close()
	var sb strings.Builder

	// Games (omit fetched_at, first_seen_at).
	rows, err := db.Query("SELECT game_id, game_date, opponent, home_away, status FROM games ORDER BY id ASC")
	if err != nil {
		t.Fatalf("query games: %v", err)
	}
	for rows.Next() {
		var a, b, c, d, e string
		rows.Scan(&a, &b, &c, &d, &e)
		sb.WriteString("G|" + a + "|" + b + "|" + c + "|" + d + "|" + e + "\n")
	}
	rows.Close()

	// Pitcher stats.
	rows, err = db.Query("SELECT game_id, pitcher_name, pitches_thrown, COALESCE(strikes_thrown,0), innings_pitched FROM game_pitcher_stats ORDER BY id ASC")
	if err != nil {
		t.Fatalf("query pitchers: %v", err)
	}
	for rows.Next() {
		var gid, name string
		var pt, st int
		var ip float64
		rows.Scan(&gid, &name, &pt, &st, &ip)
		sb.WriteString("P|" + gid + "|" + name + "|" + itoa(pt) + "|" + itoa(st) + "|" + ftoa(ip) + "\n")
	}
	rows.Close()

	// Batter stats.
	rows, err = db.Query("SELECT game_id, batter_name, at_bats, hits, walks, strikeouts FROM game_batter_stats ORDER BY id ASC")
	if err != nil {
		t.Fatalf("query batters: %v", err)
	}
	for rows.Next() {
		var gid, name string
		var ab, h, bb, k int
		rows.Scan(&gid, &name, &ab, &h, &bb, &k)
		sb.WriteString("B|" + gid + "|" + name + "|" + itoa(ab) + "|" + itoa(h) + "|" + itoa(bb) + "|" + itoa(k) + "\n")
	}
	rows.Close()
	return sb.String()
}

func equalBytes(a, b []byte) bool {
	if len(a) != len(b) {
		return false
	}
	for i := range a {
		if a[i] != b[i] {
			return false
		}
	}
	return true
}

func itoa(n int) string {
	if n == 0 {
		return "0"
	}
	neg := n < 0
	if neg {
		n = -n
	}
	var b [20]byte
	i := len(b)
	for n > 0 {
		i--
		b[i] = byte('0' + n%10)
		n /= 10
	}
	s := string(b[i:])
	if neg {
		s = "-" + s
	}
	return s
}

func ftoa(f float64) string {
	// Stable decimal-1 representation for determinism comparisons.
	i := int(f)
	frac := int((f - float64(i)) * 10)
	if frac < 0 {
		frac = -frac
	}
	return itoa(i) + "." + itoa(frac)
}
