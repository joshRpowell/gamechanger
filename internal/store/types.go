package store

import "database/sql"

// Game is a row in the games table.
type Game struct {
	GameID     string
	GameDate   string // ISO date YYYY-MM-DD
	Opponent   sql.NullString
	HomeAway   sql.NullString
	Status     sql.NullString
	FetchedAt  string
	FirstSeenAt sql.NullString
}

// PitcherStat is one row to upsert into game_pitcher_stats.
type PitcherStat struct {
	PitcherName    string
	PitchesThrown  int
	StrikesThrown  sql.NullInt64
	InningsPitched sql.NullFloat64
}

// BatterStat is one row to upsert into game_batter_stats.
type BatterStat struct {
	BatterName string
	AtBats     int
	Hits       int
	Walks      int
	Strikeouts int
}

// AvailabilityRow feeds PreGameBrief.PitcherPlan.
type AvailabilityRow struct {
	PitcherName   string
	LastOuting    sql.NullString
	LastPitches   sql.NullInt64
	SevenDayTotal int
}

// LineupRow feeds LineupOptimizer.
type LineupRow struct {
	BatterName     string
	SevenDayAB     int
	SevenDayHits   int
	SevenDayWalks  int
	SeasonAB       int
	SeasonHits     int
	SeasonWalks    int
}

// DevelopmentRow feeds DevelopmentArc.
type DevelopmentRow struct {
	PlayerName           string
	FirstHalfOBP         sql.NullFloat64
	SecondHalfOBP        sql.NullFloat64
	RecentOBP            sql.NullFloat64
	TotalGamesBatted     sql.NullInt64
	FirstHalfStrikePct   sql.NullFloat64
	SecondHalfStrikePct  sql.NullFloat64
	RecentStrikePct      sql.NullFloat64
	TotalGamesPitched    sql.NullInt64
}

// ParticipationRow feeds the equity flags. TotalGames is copied from the
// season-wide count into every row (matches Ruby's merge('total_games' => total)).
type ParticipationRow struct {
	PlayerName             string
	LastBatDate            sql.NullString
	GamesSinceLastBatted   sql.NullInt64
	TotalGamesBatted       sql.NullInt64
	LastPitchDate          sql.NullString
	GamesSinceLastPitched  sql.NullInt64
	TotalGamesPitched      sql.NullInt64
	TotalGames             int
}

// SyncResult is the return value of Syncer.Run, surfaced by `refresh --format json`.
type SyncResult struct {
	Games   int `json:"games"`
	Outings int `json:"outings"`
	AtBats  int `json:"at_bats"`
}
