// Package anonymize generates a privacy-preserving SQLite fixture from a real
// gamechanger cache.db so the verify-parity harness can commit it to a public
// repo without leaking youth-baseball PII.
//
// PIPELINE
//
//	source.db ──▶ open (read-only)
//	            │
//	            ├── schema check (games.game_date column) ──[fail]──▶ ErrSourceSchema
//	            │
//	            ▼
//	    seed = crypto/rand bytes (or caller-supplied for tests)
//	            │
//	            ▼
//	    name substitution maps built from a static pool, seeded by `seed`
//	    date shift offsets generated from `seed` (0-365 days, no day-of-week preserve)
//	    stat perturbations ±3 within constraints (AB≥H, AB≥K, pitches≥strikes)
//	            │
//	            ▼
//	    output.db ◀── write games / game_pitcher_stats / game_batter_stats with
//	                  substituted names + shifted dates + perturbed stats + fresh game_ids
//	            │
//	            ▼
//	    map.yml ◀── real_name → synthetic_name (audit trail; lives outside the repo)
//
// THREAT MODEL: see README.md in this directory.
package anonymize

import (
	"context"
	"crypto/rand"
	"crypto/sha256"
	"database/sql"
	"encoding/binary"
	"encoding/hex"
	"errors"
	"fmt"
	"math/big"
	"os"
	"path/filepath"
	"sort"
	"time"

	_ "modernc.org/sqlite"
	"gopkg.in/yaml.v3"
)

// Sentinel errors. Surfaces via errors.Is on the result of Run.
var (
	ErrSourceMissing = errors.New("anonymize: source database file not found")
	ErrSourceCorrupt = errors.New("anonymize: source database is corrupt or unreadable")
	ErrSourceSchema  = errors.New("anonymize: source database schema mismatch")
)

// Options drives a single anonymization run.
type Options struct {
	SourcePath string // required — path to a real cache.db
	OutputPath string // required — where the anonymized fixture lands
	MapDir     string // required — directory for the substitution map (typically ~/.gamechanger)
	Seed       []byte // optional — if nil, a fresh 32-byte seed is generated via crypto/rand
}

// Result describes a successful run.
type Result struct {
	OutputPath        string
	MapPath           string
	Seed              []byte // the seed actually used (echo of opts.Seed or freshly generated)
	GamesAnonymized   int
	PlayersAnonymized int
}

// substitutionMap is the YAML shape persisted to MapDir.
type substitutionMap struct {
	GeneratedAt  string            `yaml:"generated_at"`
	SourceHash   string            `yaml:"source_hash"`
	SeedHex      string            `yaml:"seed_hex"`
	PlayerNames  map[string]string `yaml:"player_names"`
	OpponentNames map[string]string `yaml:"opponent_names"`
}

// Run performs the anonymization. See package doc for the pipeline.
func Run(ctx context.Context, opts Options) (*Result, error) {
	if opts.SourcePath == "" || opts.OutputPath == "" || opts.MapDir == "" {
		return nil, fmt.Errorf("anonymize: SourcePath, OutputPath, and MapDir are required")
	}

	// 1. Source-missing check (fail fast with the typed error).
	if _, err := os.Stat(opts.SourcePath); err != nil {
		if os.IsNotExist(err) {
			return nil, fmt.Errorf("%w: %s", ErrSourceMissing, opts.SourcePath)
		}
		return nil, fmt.Errorf("%w: %v", ErrSourceCorrupt, err)
	}

	// 2. Open source. modernc.org/sqlite will accept the open even on garbage;
	// the failure surfaces on the first query.
	src, err := sql.Open("sqlite", "file:"+opts.SourcePath+"?mode=ro&immutable=1")
	if err != nil {
		return nil, fmt.Errorf("%w: open: %v", ErrSourceCorrupt, err)
	}
	defer src.Close()
	if err := src.PingContext(ctx); err != nil {
		return nil, fmt.Errorf("%w: ping: %v", ErrSourceCorrupt, err)
	}

	// 3. Schema check. If `games.game_date` doesn't exist, this is the wrong shape.
	if err := requireSchema(ctx, src); err != nil {
		return nil, err
	}

	// 4. Seed handling.
	seed := opts.Seed
	if len(seed) == 0 {
		seed = make([]byte, 32)
		if _, err := rand.Read(seed); err != nil {
			return nil, fmt.Errorf("anonymize: generate seed: %v", err)
		}
	}
	r := newSeededRand(seed)

	// 5. Read all games + collect distinct names.
	games, err := loadGames(ctx, src)
	if err != nil {
		return nil, fmt.Errorf("%w: load games: %v", ErrSourceCorrupt, err)
	}
	pitcherRows, err := loadPitcherStats(ctx, src)
	if err != nil {
		return nil, fmt.Errorf("%w: load pitcher stats: %v", ErrSourceCorrupt, err)
	}
	batterRows, err := loadBatterStats(ctx, src)
	if err != nil {
		return nil, fmt.Errorf("%w: load batter stats: %v", ErrSourceCorrupt, err)
	}

	// 6. Build substitution maps (player names, opponent names, game_ids, date offsets).
	playerMap := substitutePlayers(distinctPlayerNames(pitcherRows, batterRows), r)
	opponentMap := substituteOpponents(distinctOpponents(games), r)
	gameIDMap := newGameIDMap(games, r)
	dateOffsets := newDateOffsets(games, r) // one offset per source game_id

	// 7. Write output SQLite (delete if exists).
	if err := os.Remove(opts.OutputPath); err != nil && !os.IsNotExist(err) {
		return nil, fmt.Errorf("anonymize: remove output: %v", err)
	}
	if err := os.MkdirAll(filepath.Dir(opts.OutputPath), 0o700); err != nil {
		return nil, fmt.Errorf("anonymize: mkdir output dir: %v", err)
	}
	out, err := sql.Open("sqlite", opts.OutputPath)
	if err != nil {
		return nil, fmt.Errorf("anonymize: open output: %v", err)
	}
	defer out.Close()
	if err := createSchema(ctx, out); err != nil {
		return nil, fmt.Errorf("anonymize: create output schema: %v", err)
	}
	if err := writeAnonymized(ctx, out, games, pitcherRows, batterRows, playerMap, opponentMap, gameIDMap, dateOffsets, r); err != nil {
		return nil, fmt.Errorf("anonymize: write output: %v", err)
	}

	// 8. Write substitution map.
	mapPath, err := writeSubstitutionMap(opts.MapDir, seed, opts.SourcePath, playerMap, opponentMap)
	if err != nil {
		return nil, fmt.Errorf("anonymize: write map: %v", err)
	}

	return &Result{
		OutputPath:        opts.OutputPath,
		MapPath:           mapPath,
		Seed:              seed,
		GamesAnonymized:   len(games),
		PlayersAnonymized: len(playerMap),
	}, nil
}

// ─── schema validation ──────────────────────────────────────────────────────

func requireSchema(ctx context.Context, db *sql.DB) error {
	// PRAGMA table_info returns columns for the table. Empty result = table doesn't exist.
	rows, err := db.QueryContext(ctx, "PRAGMA table_info(games)")
	if err != nil {
		return fmt.Errorf("%w: pragma games: %v", ErrSourceCorrupt, err)
	}
	defer rows.Close()
	cols := map[string]bool{}
	for rows.Next() {
		var cid int
		var name, ctype string
		var notnull, pk int
		var dflt any
		if err := rows.Scan(&cid, &name, &ctype, &notnull, &dflt, &pk); err != nil {
			return fmt.Errorf("%w: scan: %v", ErrSourceCorrupt, err)
		}
		cols[name] = true
	}
	if len(cols) == 0 {
		return fmt.Errorf("%w: games table missing", ErrSourceSchema)
	}
	for _, required := range []string{"game_id", "game_date", "opponent", "home_away", "status"} {
		if !cols[required] {
			return fmt.Errorf("%w: games.%s column missing", ErrSourceSchema, required)
		}
	}
	return nil
}

// ─── source readers ─────────────────────────────────────────────────────────

type gameRow struct {
	GameID, GameDate, Opponent, HomeAway, Status string
}

type pitcherStatRow struct {
	GameID, PitcherName    string
	PitchesThrown, Strikes int
	InningsPitched         float64
}

type batterStatRow struct {
	GameID, BatterName                 string
	AtBats, Hits, Walks, Strikeouts    int
}

func loadGames(ctx context.Context, db *sql.DB) ([]gameRow, error) {
	rows, err := db.QueryContext(ctx, "SELECT game_id, game_date, COALESCE(opponent,''), COALESCE(home_away,''), COALESCE(status,'') FROM games ORDER BY id ASC")
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	var out []gameRow
	for rows.Next() {
		var g gameRow
		if err := rows.Scan(&g.GameID, &g.GameDate, &g.Opponent, &g.HomeAway, &g.Status); err != nil {
			return nil, err
		}
		out = append(out, g)
	}
	return out, rows.Err()
}

func loadPitcherStats(ctx context.Context, db *sql.DB) ([]pitcherStatRow, error) {
	rows, err := db.QueryContext(ctx, "SELECT game_id, pitcher_name, pitches_thrown, COALESCE(strikes_thrown,0), COALESCE(innings_pitched,0) FROM game_pitcher_stats ORDER BY id ASC")
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	var out []pitcherStatRow
	for rows.Next() {
		var r pitcherStatRow
		if err := rows.Scan(&r.GameID, &r.PitcherName, &r.PitchesThrown, &r.Strikes, &r.InningsPitched); err != nil {
			return nil, err
		}
		out = append(out, r)
	}
	return out, rows.Err()
}

func loadBatterStats(ctx context.Context, db *sql.DB) ([]batterStatRow, error) {
	rows, err := db.QueryContext(ctx, "SELECT game_id, batter_name, at_bats, hits, walks, strikeouts FROM game_batter_stats ORDER BY id ASC")
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	var out []batterStatRow
	for rows.Next() {
		var r batterStatRow
		if err := rows.Scan(&r.GameID, &r.BatterName, &r.AtBats, &r.Hits, &r.Walks, &r.Strikeouts); err != nil {
			return nil, err
		}
		out = append(out, r)
	}
	return out, rows.Err()
}

// ─── substitution-map construction ──────────────────────────────────────────

// Static name pools. Sized to cover plausible team rosters + opponent counts.
// Names chosen for deliberate non-overlap with the user's real roster.
var syntheticPlayerNames = []string{
	"Alex Brennan", "Cameron Dunlap", "Dylan Falconer", "Ethan Garber", "Felix Hoult",
	"Gavin Iverson", "Henry Janssen", "Ian Klemm", "Jonah Lassiter", "Kai Mordent",
	"Leo Nordquist", "Milo Okafor", "Noah Pemberton", "Owen Quinto", "Parker Ravenel",
	"Quinn Saltzman", "Rowan Tellman", "Sawyer Updike", "Theo Velazquez", "Uri Wexler",
	"Vincent Xandra", "Wyatt Yardley", "Xavier Zoll", "Yusuf Abrams", "Zane Bowyer",
	"Asher Crandall", "Beau Dilworth", "Caleb Eastland", "Declan Farrow", "Eli Gunning",
	"Finn Hannigan", "Grant Inglewood", "Hugo Joffrion", "Isaac Karp", "Jasper Lindow",
	"Kieran Manville", "Logan Northcote", "Mason Oberlin", "Nate Pickle", "Oscar Quaintance",
	"Pierce Rambo", "Quincy Stentz", "Reese Trumbull", "Silas Uppal", "Tobias Voss",
	"Ulrich Westmore", "Valor Xanthos", "Wesley Yarbrough", "Xander Zucker", "Yves Aaronson",
}

var syntheticOpponentNames = []string{
	"Ridgemont Raptors", "Pinecreek Pioneers", "Driftwood Drillers", "Solstice Surge",
	"Bayshore Buccaneers", "Coppermine Crushers", "Foxglen Flyers", "Hollowbrook Hawks",
	"Ivybridge Ironclads", "Juniper Jets", "Kestrel Knights", "Lighthouse Lancers",
	"Meadowlark Mustangs", "Northridge Nighthawks", "Oakvale Outlaws", "Pacific Pikes",
	"Quicksilver Quakers", "Riverstone Renegades", "Stormcrest Stallions", "Twin Pines Titans",
	"Underwood Unicorns", "Vineyard Vipers", "Willowbank Wolves", "Yarrow Yacht Club",
	"Zephyr Zealots", "Arroyo Archers", "Bluestone Battalion", "Cypress Cosmonauts",
	"Driftless Defenders", "Elmwood Eagles", "Fernridge Falcons", "Greylock Gladiators",
}

func substitutePlayers(realNames []string, r *seededRand) map[string]string {
	return mapFromPool(realNames, syntheticPlayerNames, r)
}

func substituteOpponents(realOpponents []string, r *seededRand) map[string]string {
	return mapFromPool(realOpponents, syntheticOpponentNames, r)
}

// mapFromPool assigns each real name a deterministic-but-shuffled-by-seed
// synthetic from the pool. If real names outnumber pool entries, indices wrap
// modulo pool size and a numeric suffix is appended for uniqueness.
func mapFromPool(realNames, pool []string, r *seededRand) map[string]string {
	sort.Strings(realNames) // stable iteration order regardless of source DB row order
	shuffled := make([]string, len(pool))
	copy(shuffled, pool)
	r.Shuffle(len(shuffled), func(i, j int) { shuffled[i], shuffled[j] = shuffled[j], shuffled[i] })

	out := make(map[string]string, len(realNames))
	for i, real := range realNames {
		base := shuffled[i%len(shuffled)]
		if i < len(shuffled) {
			out[real] = base
		} else {
			out[real] = fmt.Sprintf("%s %d", base, i/len(shuffled)+1)
		}
	}
	return out
}

func distinctPlayerNames(pitchers []pitcherStatRow, batters []batterStatRow) []string {
	set := map[string]bool{}
	for _, p := range pitchers {
		set[p.PitcherName] = true
	}
	for _, b := range batters {
		set[b.BatterName] = true
	}
	out := make([]string, 0, len(set))
	for name := range set {
		out = append(out, name)
	}
	return out
}

func distinctOpponents(games []gameRow) []string {
	set := map[string]bool{}
	for _, g := range games {
		if g.Opponent != "" {
			set[g.Opponent] = true
		}
	}
	out := make([]string, 0, len(set))
	for name := range set {
		out = append(out, name)
	}
	return out
}

func newGameIDMap(games []gameRow, r *seededRand) map[string]string {
	out := make(map[string]string, len(games))
	for i, g := range games {
		// Synthetic IDs preserve order via prefix; suffix derives from seed for unpredictability.
		out[g.GameID] = fmt.Sprintf("anon-%04d-%s", i+1, r.HexBytes(4))
	}
	return out
}

func newDateOffsets(games []gameRow, r *seededRand) map[string]int {
	// Independent random offset per game in [0, 365]. Day-of-week is NOT preserved.
	out := make(map[string]int, len(games))
	for _, g := range games {
		out[g.GameID] = r.Intn(366) // 0..365 inclusive
	}
	return out
}

// ─── output writer ──────────────────────────────────────────────────────────

func createSchema(ctx context.Context, db *sql.DB) error {
	stmts := []string{
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
	}
	for _, s := range stmts {
		if _, err := db.ExecContext(ctx, s); err != nil {
			return err
		}
	}
	return nil
}

func writeAnonymized(
	ctx context.Context, out *sql.DB,
	games []gameRow, pitchers []pitcherStatRow, batters []batterStatRow,
	playerMap, opponentMap, gameIDMap map[string]string,
	dateOffsets map[string]int,
	r *seededRand,
) error {
	tx, err := out.BeginTx(ctx, nil)
	if err != nil {
		return err
	}
	defer tx.Rollback()

	for _, g := range games {
		newDate, err := shiftDate(g.GameDate, dateOffsets[g.GameID])
		if err != nil {
			return fmt.Errorf("shift date for %s: %v", g.GameID, err)
		}
		newOpponent := opponentMap[g.Opponent]
		if newOpponent == "" {
			newOpponent = "Unknown Opponent"
		}
		_, err = tx.ExecContext(ctx,
			`INSERT INTO games (game_id, game_date, opponent, home_away, status, fetched_at) VALUES (?, ?, ?, ?, ?, ?)`,
			gameIDMap[g.GameID], newDate, newOpponent, g.HomeAway, g.Status, "2026-01-01T00:00:00Z",
		)
		if err != nil {
			return fmt.Errorf("insert game: %v", err)
		}
	}

	for _, p := range pitchers {
		newPT, newST := perturbPitcherStats(p.PitchesThrown, p.Strikes, r)
		_, err := tx.ExecContext(ctx,
			`INSERT INTO game_pitcher_stats (game_id, pitcher_name, pitches_thrown, strikes_thrown, innings_pitched, fetched_at) VALUES (?, ?, ?, ?, ?, ?)`,
			gameIDMap[p.GameID], playerMap[p.PitcherName], newPT, newST, p.InningsPitched, "2026-01-01T00:00:00Z",
		)
		if err != nil {
			return fmt.Errorf("insert pitcher: %v", err)
		}
	}

	for _, b := range batters {
		newAB, newH, newBB, newK := perturbBatterStats(b.AtBats, b.Hits, b.Walks, b.Strikeouts, r)
		_, err := tx.ExecContext(ctx,
			`INSERT INTO game_batter_stats (game_id, batter_name, at_bats, hits, walks, strikeouts, fetched_at) VALUES (?, ?, ?, ?, ?, ?, ?)`,
			gameIDMap[b.GameID], playerMap[b.BatterName], newAB, newH, newBB, newK, "2026-01-01T00:00:00Z",
		)
		if err != nil {
			return fmt.Errorf("insert batter: %v", err)
		}
	}

	return tx.Commit()
}

func shiftDate(srcDate string, days int) (string, error) {
	td, err := time.Parse("2006-01-02", srcDate)
	if err != nil {
		return "", err
	}
	return td.AddDate(0, 0, days).Format("2006-01-02"), nil
}

// perturbPitcherStats applies ±3 to pitches and strikes while preserving
// pitches >= strikes >= 0.
func perturbPitcherStats(pitches, strikes int, r *seededRand) (int, int) {
	newP := clipNonNeg(pitches + r.IntInRange(-3, 3))
	newS := clipNonNeg(strikes + r.IntInRange(-3, 3))
	if newS > newP {
		newS = newP
	}
	return newP, newS
}

// perturbBatterStats applies ±3 to each stat while preserving baseball constraints:
// AB >= H, AB >= K, all non-negative. Walks are independent.
func perturbBatterStats(ab, h, bb, k int, r *seededRand) (int, int, int, int) {
	newAB := clipNonNeg(ab + r.IntInRange(-3, 3))
	newH := clipNonNeg(h + r.IntInRange(-3, 3))
	newBB := clipNonNeg(bb + r.IntInRange(-3, 3))
	newK := clipNonNeg(k + r.IntInRange(-3, 3))
	if newH > newAB {
		newH = newAB
	}
	if newK > newAB {
		newK = newAB
	}
	return newAB, newH, newBB, newK
}

func clipNonNeg(n int) int {
	if n < 0 {
		return 0
	}
	return n
}

// ─── substitution map persistence ───────────────────────────────────────────

func writeSubstitutionMap(mapDir string, seed []byte, sourcePath string, playerMap, opponentMap map[string]string) (string, error) {
	if err := os.MkdirAll(mapDir, 0o700); err != nil {
		return "", err
	}
	// Filename hash derives from the seed so different seeds → different filenames
	// (cross-version unlinkability via separate map files).
	digest := sha256.Sum256(seed)
	suffix := hex.EncodeToString(digest[:6])
	mapPath := filepath.Join(mapDir, "parity-substitution-"+suffix+".yml")

	srcHash := sha256.Sum256([]byte(sourcePath))
	doc := substitutionMap{
		GeneratedAt:   time.Now().UTC().Format(time.RFC3339),
		SourceHash:    hex.EncodeToString(srcHash[:8]),
		SeedHex:       hex.EncodeToString(seed),
		PlayerNames:   playerMap,
		OpponentNames: opponentMap,
	}
	b, err := yaml.Marshal(doc)
	if err != nil {
		return "", err
	}
	// 0o600 — map contains real-name mappings; user-only.
	if err := os.WriteFile(mapPath, b, 0o600); err != nil {
		return "", err
	}
	return mapPath, nil
}

// ─── seeded RNG (deterministic from `seed` bytes) ────────────────────────────

// seededRand wraps a chacha8-style PRNG derived from a 32-byte seed via SHA-256.
// We avoid math/rand/v2's exported chacha8 to keep this code Go 1.21+ compatible
// without requiring 1.22; instead we do a stretched-key Linear Feedback variant
// that is deterministic for tests.
type seededRand struct {
	state []byte
	pos   int
}

func newSeededRand(seed []byte) *seededRand {
	// Stretch the seed deterministically into a pool we draw from.
	// 8192 bytes is plenty for ~hundreds of names + dates + perturbations.
	pool := make([]byte, 0, 8192)
	for round := 0; len(pool) < 8192; round++ {
		var buf [4]byte
		binary.BigEndian.PutUint32(buf[:], uint32(round))
		h := sha256.Sum256(append(append([]byte{}, seed...), buf[:]...))
		pool = append(pool, h[:]...)
	}
	return &seededRand{state: pool, pos: 0}
}

func (s *seededRand) next() byte {
	b := s.state[s.pos%len(s.state)]
	s.pos++
	return b
}

func (s *seededRand) Intn(n int) int {
	if n <= 0 {
		return 0
	}
	// Pull 8 bytes, treat as uint64, mod n. Bias is acceptable for our scale
	// (max n = 366 vs 2^64) — gamechanger has no statistical use of the seed.
	var v big.Int
	bytes := make([]byte, 8)
	for i := range bytes {
		bytes[i] = s.next()
	}
	v.SetBytes(bytes)
	return int(v.Uint64() % uint64(n))
}

func (s *seededRand) IntInRange(lo, hi int) int {
	if hi < lo {
		lo, hi = hi, lo
	}
	return lo + s.Intn(hi-lo+1)
}

func (s *seededRand) Shuffle(n int, swap func(i, j int)) {
	// Fisher-Yates with our deterministic source.
	for i := n - 1; i > 0; i-- {
		j := s.Intn(i + 1)
		swap(i, j)
	}
}

func (s *seededRand) HexBytes(n int) string {
	b := make([]byte, n)
	for i := range b {
		b[i] = s.next()
	}
	return hex.EncodeToString(b)
}
