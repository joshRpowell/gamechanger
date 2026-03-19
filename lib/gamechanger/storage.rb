# frozen_string_literal: true

require 'sqlite3'
require 'fileutils'

module Gamechanger
  # SQLite-backed cache for Gamechanger game and pitcher data.
  #
  # Modeled on sundance/lib/sundance/database_storage.rb.
  #
  # Testing: pass data_dir: ':memory:' for an in-memory database.
  class Storage
    DATA_DIR  = File.expand_path('~/.gamechanger').freeze
    DB_FILE   = 'cache.db'.freeze

    # Additive migrations only (ALTER TABLE ADD COLUMN for new columns).
    # schema_migrations table is created by migrate! and NOT listed here.
    MIGRATIONS = [
      [1, <<~SQL],
        CREATE TABLE games (
          id            INTEGER PRIMARY KEY,
          game_id       TEXT NOT NULL UNIQUE,
          game_date     TEXT NOT NULL,
          opponent      TEXT,
          home_away     TEXT,
          status        TEXT,
          fetched_at    TEXT NOT NULL,
          first_seen_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%SZ', 'now'))
        );
        CREATE INDEX idx_games_date   ON games (game_date DESC);
        CREATE INDEX idx_games_status ON games (status);

        CREATE TABLE game_pitcher_stats (
          id              INTEGER PRIMARY KEY,
          game_id         TEXT NOT NULL REFERENCES games(game_id) ON DELETE CASCADE,
          pitcher_name    TEXT NOT NULL,
          pitches_thrown  INTEGER NOT NULL DEFAULT 0,
          innings_pitched REAL,
          fetched_at      TEXT NOT NULL,
          first_seen_at   TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%SZ', 'now')),
          UNIQUE(game_id, pitcher_name)
        );
        CREATE INDEX idx_gps_pitcher ON game_pitcher_stats (pitcher_name);
        CREATE INDEX idx_gps_game    ON game_pitcher_stats (game_id);
      SQL
      [2, <<~SQL],
        ALTER TABLE game_pitcher_stats ADD COLUMN strikes_thrown INTEGER;
      SQL
      [3, <<~SQL]
        CREATE TABLE game_batter_stats (
          id          INTEGER PRIMARY KEY,
          game_id     TEXT NOT NULL REFERENCES games(game_id) ON DELETE CASCADE,
          batter_name TEXT NOT NULL,
          at_bats     INTEGER NOT NULL DEFAULT 0,
          hits        INTEGER NOT NULL DEFAULT 0,
          walks       INTEGER NOT NULL DEFAULT 0,
          strikeouts  INTEGER NOT NULL DEFAULT 0,
          fetched_at  TEXT NOT NULL,
          UNIQUE(game_id, batter_name)
        );
        CREATE INDEX idx_gbs_batter ON game_batter_stats (batter_name);
        CREATE INDEX idx_gbs_game   ON game_batter_stats (game_id);
      SQL
    ].freeze

    def initialize(data_dir: nil)
      @data_dir = data_dir
    end

    def data_dir
      @resolved_data_dir ||=
        if @data_dir == ':memory:'
          ':memory:'
        else
          dir = @data_dir || DATA_DIR
          FileUtils.mkdir_p(dir, mode: 0o700)
          dir
        end
    end

    def db_path
      return ':memory:' if data_dir == ':memory:'

      File.join(data_dir, DB_FILE)
    end

    # Upsert a game record. Does not overwrite final games to save API calls.
    # @param game [Hash] keys: game_id, game_date, opponent, home_away, status
    def upsert_game(game)
      now = iso_now
      db.execute(<<~SQL, [game[:game_id], game[:game_date], game[:opponent],
        INSERT INTO games (game_id, game_date, opponent, home_away, status, fetched_at)
        VALUES (?, ?, ?, ?, ?, ?)
        ON CONFLICT(game_id) DO UPDATE SET
          game_date  = excluded.game_date,
          opponent   = excluded.opponent,
          home_away  = excluded.home_away,
          status     = excluded.status,
          fetched_at = excluded.fetched_at
        WHERE games.status != 'final'
      SQL
                         game[:home_away], game[:status], now])
    end

    # Upsert pitcher stats for a game. Safe to call repeatedly.
    # @param game_id [String] Gamechanger game ID (must already exist in games table)
    # @param stats [Array<Hash>] each with keys: pitcher_name, pitches_thrown, innings_pitched
    def upsert_pitcher_stats(game_id:, stats:)
      now = iso_now
      db.transaction(:immediate) do
        stats.each do |stat|
          db.execute(<<~SQL, [game_id, stat[:pitcher_name], stat[:pitches_thrown].to_i,
            INSERT INTO game_pitcher_stats (game_id, pitcher_name, pitches_thrown, strikes_thrown, innings_pitched, fetched_at)
            VALUES (?, ?, ?, ?, ?, ?)
            ON CONFLICT(game_id, pitcher_name) DO UPDATE SET
              pitches_thrown  = excluded.pitches_thrown,
              strikes_thrown  = excluded.strikes_thrown,
              innings_pitched = excluded.innings_pitched,
              fetched_at      = excluded.fetched_at
          SQL
                           stat[:strikes_thrown], stat[:innings_pitched], now])
        end
      end
    end

    # Upsert batter stats for a game. Safe to call repeatedly.
    # @param game_id [String] must already exist in games table
    # @param stats [Array<Hash>] each with keys: batter_name, at_bats, hits, walks, strikeouts
    def upsert_batter_stats(game_id:, stats:)
      now = iso_now
      db.transaction(:immediate) do
        stats.each do |stat|
          db.execute(<<~SQL, [game_id, stat[:batter_name], stat[:at_bats].to_i,
            INSERT INTO game_batter_stats (game_id, batter_name, at_bats, hits, walks, strikeouts, fetched_at)
            VALUES (?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(game_id, batter_name) DO UPDATE SET
              at_bats    = excluded.at_bats,
              hits       = excluded.hits,
              walks      = excluded.walks,
              strikeouts = excluded.strikeouts,
              fetched_at = excluded.fetched_at
          SQL
                           stat[:hits].to_i, stat[:walks].to_i, stat[:strikeouts].to_i, now])
        end
      end
    end

    # Season batting summary: all batters with totals and 7-day window.
    # Sorted by season OBP descending.
    # @return [Array<Hash>] one row per batter
    def season_batting_summary
      db.execute(<<~SQL)
        SELECT
          gbs.batter_name,
          COUNT(DISTINCT gbs.game_id)                                AS games,
          SUM(gbs.at_bats)                                           AS total_ab,
          SUM(gbs.hits)                                              AS total_hits,
          SUM(gbs.walks)                                             AS total_walks,
          SUM(gbs.strikeouts)                                        AS total_k,
          SUM(CASE WHEN g.game_date >= date('now', '-7 days')
                   THEN gbs.at_bats  ELSE 0 END)                    AS seven_day_ab,
          SUM(CASE WHEN g.game_date >= date('now', '-7 days')
                   THEN gbs.hits     ELSE 0 END)                    AS seven_day_hits,
          SUM(CASE WHEN g.game_date >= date('now', '-7 days')
                   THEN gbs.walks    ELSE 0 END)                    AS seven_day_walks
        FROM game_batter_stats gbs
        JOIN games g ON g.game_id = gbs.game_id
        WHERE gbs.at_bats > 0
        GROUP BY gbs.batter_name
        ORDER BY
          CASE WHEN (SUM(gbs.at_bats) + SUM(gbs.walks)) > 0
               THEN CAST(SUM(gbs.hits) + SUM(gbs.walks) AS REAL) / (SUM(gbs.at_bats) + SUM(gbs.walks))
               ELSE 0 END DESC
      SQL
    end

    # Per-game breakdown for a single batter (case-insensitive substring match).
    # @param name [String] batter name (or partial name)
    # @return [Array<String>] matching names if multiple, or Array<Hash> game rows if exactly one match
    def batter_games(name)
      matches = db.execute(
        "SELECT DISTINCT batter_name FROM game_batter_stats WHERE LOWER(batter_name) LIKE LOWER(?)",
        ["%#{name}%"]
      ).map { |r| r['batter_name'] }
      return matches unless matches.length == 1

      db.execute(<<~SQL, [matches.first])
        SELECT g.game_date, g.opponent, g.home_away, g.status,
               gbs.at_bats, gbs.hits, gbs.walks, gbs.strikeouts
        FROM game_batter_stats gbs
        JOIN games g ON g.game_id = gbs.game_id
        WHERE gbs.batter_name = ?
        ORDER BY g.game_date ASC
      SQL
    end

    # Per-batter 7-day and season aggregates for lineup planning.
    # Anchors 7-day window to before_date (same as pitcher_availability_data).
    # Only includes batters with at least 1 AB.
    # @param before_date [String, Date] exclusive upper bound on game_date
    # @return [Array<Hash>] one row per batter
    def batter_lineup_data(before_date:)
      db.execute(<<~SQL, [before_date.to_s, before_date.to_s, before_date.to_s, before_date.to_s])
        SELECT
          gbs.batter_name,
          SUM(CASE WHEN g.game_date >= date(?, '-7 days') AND gbs.at_bats > 0
                   THEN gbs.at_bats  ELSE 0 END)  AS seven_day_ab,
          SUM(CASE WHEN g.game_date >= date(?, '-7 days') AND gbs.at_bats > 0
                   THEN gbs.hits     ELSE 0 END)  AS seven_day_hits,
          SUM(CASE WHEN g.game_date >= date(?, '-7 days') AND gbs.at_bats > 0
                   THEN gbs.walks    ELSE 0 END)  AS seven_day_walks,
          SUM(gbs.at_bats)   AS season_ab,
          SUM(gbs.hits)      AS season_hits,
          SUM(gbs.walks)     AS season_walks
        FROM game_batter_stats gbs
        JOIN games g ON g.game_id = gbs.game_id
        WHERE g.game_date < ?
          AND gbs.at_bats > 0
        GROUP BY gbs.batter_name
        ORDER BY gbs.batter_name ASC
      SQL
    end

    # Per-player participation: last batting/pitching appearance and season counts.
    # Unions all known players from game_batter_stats + game_pitcher_stats.
    # Games-ago counts only final games (same logic as pitcher_availability_data).
    # Sorted by batting inactivity descending (most overdue first); NULLS LAST for
    # players who have never batted.
    # Each row also carries total_games (total final games in the season) so the
    # formatter can compute n/m participation rates without a second query.
    # @return [Array<Hash>] one row per player
    def player_participation
      total_games = db.execute(
        "SELECT COUNT(*) AS n FROM games WHERE status = 'final'"
      ).first['n'].to_i

      rows = db.execute(<<~SQL)
        WITH all_players AS (
          SELECT DISTINCT batter_name AS player_name FROM game_batter_stats
          UNION
          SELECT DISTINCT pitcher_name FROM game_pitcher_stats
        ),
        batting AS (
          SELECT gbs.batter_name,
                 MAX(g.game_date)            AS last_bat_date,
                 COUNT(DISTINCT gbs.game_id) AS total_games_batted
          FROM game_batter_stats gbs
          JOIN games g ON g.game_id = gbs.game_id
          WHERE gbs.at_bats > 0
            AND g.status = 'final'
          GROUP BY gbs.batter_name
        ),
        pitching AS (
          SELECT gps.pitcher_name,
                 MAX(g.game_date)             AS last_pitch_date,
                 COUNT(DISTINCT gps.game_id)  AS total_games_pitched
          FROM game_pitcher_stats gps
          JOIN games g ON g.game_id = gps.game_id
          WHERE gps.pitches_thrown > 0
            AND g.status = 'final'
          GROUP BY gps.pitcher_name
        )
        SELECT
          p.player_name,
          bat.last_bat_date,
          (SELECT COUNT(*) FROM games g4
           WHERE g4.game_date > bat.last_bat_date
             AND g4.status = 'final')  AS games_since_last_batted,
          bat.total_games_batted,
          pit.last_pitch_date,
          (SELECT COUNT(*) FROM games g5
           WHERE g5.game_date > pit.last_pitch_date
             AND g5.status = 'final')  AS games_since_last_pitched,
          pit.total_games_pitched
        FROM all_players p
        LEFT JOIN batting  bat ON bat.batter_name  = p.player_name
        LEFT JOIN pitching pit ON pit.pitcher_name = p.player_name
        ORDER BY games_since_last_batted DESC NULLS LAST,
                 p.player_name ASC
      SQL

      rows.map { |r| r.merge('total_games' => total_games) }
    end

    # Per-player development summary: first-half and second-half OBP/strike% aggregates.
    # Season midpoint is the N/2th final game by chronological count (not calendar date).
    # Players with fewer than 3 appearances in a dimension are excluded from that dimension.
    # Uses SQLite window functions (ROW_NUMBER) — requires SQLite 3.25+.
    # @return [Array<Hash>] one row per player with batting and pitching arc data
    def all_player_development_summary
      db.execute(<<~SQL)
        WITH total_games AS (
          SELECT COUNT(*) AS n FROM games WHERE status = 'final'
        ),
        ordered_games AS (
          SELECT game_id, game_date,
                 ROW_NUMBER() OVER (ORDER BY game_date ASC) AS seq
          FROM games
          WHERE status = 'final'
        ),
        batting_per_game AS (
          SELECT gbs.batter_name,
                 og.seq,
                 CAST(gbs.hits + gbs.walks AS REAL) / NULLIF(gbs.at_bats + gbs.walks, 0) AS obp
          FROM game_batter_stats gbs
          JOIN ordered_games og ON og.game_id = gbs.game_id
          WHERE gbs.at_bats + gbs.walks > 0
        ),
        batting_recent AS (
          SELECT sub.batter_name, AVG(sub.obp) AS recent_obp
          FROM (
            SELECT batter_name, obp,
                   ROW_NUMBER() OVER (PARTITION BY batter_name ORDER BY seq DESC) AS recency
            FROM batting_per_game
          ) sub
          WHERE sub.recency <= 5
          GROUP BY sub.batter_name
        ),
        batting_summary AS (
          SELECT bpg.batter_name,
                 AVG(CASE WHEN bpg.seq <= (SELECT n/2 FROM total_games) THEN bpg.obp END) AS first_half_obp,
                 AVG(CASE WHEN bpg.seq >  (SELECT n/2 FROM total_games) THEN bpg.obp END) AS second_half_obp,
                 COUNT(DISTINCT bpg.seq) AS total_games_batted
          FROM batting_per_game bpg
          GROUP BY bpg.batter_name
          HAVING COUNT(DISTINCT bpg.seq) >= 3
        ),
        pitching_per_game AS (
          SELECT gps.pitcher_name,
                 og.seq,
                 CAST(gps.strikes_thrown AS REAL) / NULLIF(gps.pitches_thrown, 0) AS strike_pct
          FROM game_pitcher_stats gps
          JOIN ordered_games og ON og.game_id = gps.game_id
          WHERE gps.pitches_thrown > 0
        ),
        pitching_recent AS (
          SELECT sub.pitcher_name, AVG(sub.strike_pct) AS recent_strike_pct
          FROM (
            SELECT pitcher_name, strike_pct,
                   ROW_NUMBER() OVER (PARTITION BY pitcher_name ORDER BY seq DESC) AS recency
            FROM pitching_per_game
          ) sub
          WHERE sub.recency <= 5
          GROUP BY sub.pitcher_name
        ),
        pitching_summary AS (
          SELECT ppg.pitcher_name,
                 AVG(CASE WHEN ppg.seq <= (SELECT n/2 FROM total_games) THEN ppg.strike_pct END) AS first_half_strike_pct,
                 AVG(CASE WHEN ppg.seq >  (SELECT n/2 FROM total_games) THEN ppg.strike_pct END) AS second_half_strike_pct,
                 COUNT(DISTINCT ppg.seq) AS total_games_pitched
          FROM pitching_per_game ppg
          GROUP BY ppg.pitcher_name
          HAVING COUNT(DISTINCT ppg.seq) >= 3
        ),
        all_players AS (
          SELECT DISTINCT batter_name AS player_name FROM game_batter_stats
          UNION
          SELECT DISTINCT pitcher_name FROM game_pitcher_stats
        )
        SELECT
          p.player_name,
          bat.first_half_obp,
          bat.second_half_obp,
          br.recent_obp,
          bat.total_games_batted,
          pit.first_half_strike_pct,
          pit.second_half_strike_pct,
          pr.recent_strike_pct,
          pit.total_games_pitched
        FROM all_players p
        LEFT JOIN batting_summary  bat ON bat.batter_name  = p.player_name
        LEFT JOIN batting_recent   br  ON br.batter_name   = p.player_name
        LEFT JOIN pitching_summary pit ON pit.pitcher_name = p.player_name
        LEFT JOIN pitching_recent  pr  ON pr.pitcher_name  = p.player_name
        WHERE bat.batter_name IS NOT NULL OR pit.pitcher_name IS NOT NULL
        ORDER BY p.player_name ASC
      SQL
    end

    # Per-game OBP rows for a single batter, chronologically ordered.
    # Used to compute sparklines in the gc progress --player deep-dive.
    # @param player_name [String] exact batter name
    # @return [Array<Hash>] one row per game the batter appeared in
    def player_batting_arc(player_name:)
      db.execute(<<~SQL, [player_name])
        SELECT g.game_date,
               ROW_NUMBER() OVER (ORDER BY g.game_date ASC) AS game_seq,
               gbs.hits, gbs.walks, gbs.at_bats
        FROM game_batter_stats gbs
        JOIN games g ON g.game_id = gbs.game_id
        WHERE gbs.batter_name = ?
          AND g.status = 'final'
          AND gbs.at_bats + gbs.walks > 0
        ORDER BY g.game_date ASC
      SQL
    end

    # Per-outing strike% rows for a single pitcher, chronologically ordered.
    # Used to compute sparklines in the gc progress --pitcher deep-dive.
    # @param pitcher_name [String] exact pitcher name
    # @return [Array<Hash>] one row per outing
    def player_pitching_arc(pitcher_name:)
      db.execute(<<~SQL, [pitcher_name])
        SELECT g.game_date,
               ROW_NUMBER() OVER (ORDER BY g.game_date ASC) AS game_seq,
               gps.pitches_thrown, gps.strikes_thrown, gps.innings_pitched
        FROM game_pitcher_stats gps
        JOIN games g ON g.game_id = gps.game_id
        WHERE gps.pitcher_name = ?
          AND g.status = 'final'
          AND gps.pitches_thrown > 0
        ORDER BY g.game_date ASC
      SQL
    end

    # Returns all games, ordered by date ascending.
    def all_games
      db.execute('SELECT * FROM games ORDER BY game_date ASC')
    end

    # Returns games that need re-fetching (in_progress or today's games).
    def stale_games
      today = Date.today.iso8601
      db.execute(
        "SELECT * FROM games WHERE status = 'in_progress' OR game_date = ? ORDER BY game_date ASC",
        [today]
      )
    end

    # Season summary: all pitchers with totals, per-game average, and 7-day total.
    # @return [Array<Hash>] one row per pitcher
    def season_summary
      db.execute(<<~SQL)
        SELECT
          gps.pitcher_name,
          COUNT(DISTINCT gps.game_id)                                  AS games_pitched,
          SUM(gps.pitches_thrown)                                      AS total_pitches,
          SUM(gps.strikes_thrown)                                      AS total_strikes,
          ROUND(AVG(gps.pitches_thrown), 1)                            AS avg_per_game,
          SUM(CASE WHEN g.game_date >= date('now', '-7 days')
                   THEN gps.pitches_thrown ELSE 0 END)                 AS seven_day_total,
          MAX(g.game_date)                                             AS last_outing
        FROM game_pitcher_stats gps
        JOIN games g ON g.game_id = gps.game_id
        GROUP BY gps.pitcher_name
        ORDER BY total_pitches DESC
      SQL
    end

    # Per-game breakdown for a single pitcher (case-insensitive substring match).
    # @param name [String] pitcher name (or partial name)
    # @return [Array<Hash>] matching pitcher names, or game rows if exactly one match
    def pitcher_games(name)
      matches = db.execute(
        "SELECT DISTINCT pitcher_name FROM game_pitcher_stats WHERE LOWER(pitcher_name) LIKE LOWER(?)",
        ["%#{name}%"]
      ).map { |r| r['pitcher_name'] }
      return matches unless matches.length == 1

      db.execute(<<~SQL, [matches.first])
        SELECT g.game_date, g.opponent, g.home_away, g.status,
               gps.pitches_thrown, gps.strikes_thrown, gps.innings_pitched
        FROM game_pitcher_stats gps
        JOIN games g ON g.game_id = gps.game_id
        WHERE gps.pitcher_name = ?
        ORDER BY g.game_date ASC
      SQL
    end

    # All pitcher stats for a specific game date.
    # @param date [String] ISO 8601 date, e.g. "2026-03-10"
    # @return [Array<Hash>] game rows (multiple if doubleheader), each with pitcher_stats key
    def game_by_date(date)
      games = db.execute(
        "SELECT * FROM games WHERE game_date = ? ORDER BY game_id ASC",
        [date]
      )
      games.map do |game|
        stats = db.execute(
          "SELECT pitcher_name, pitches_thrown, strikes_thrown, innings_pitched FROM game_pitcher_stats WHERE game_id = ? ORDER BY pitches_thrown DESC",
          [game['game_id']]
        )
        game.merge('pitcher_stats' => stats)
      end
    end

    # Nearest game with game_date strictly after after_date, or nil if none.
    def next_scheduled_game(after_date: Date.today.to_s)
      db.execute(
        "SELECT game_id, game_date, opponent, home_away FROM games WHERE game_date > ? ORDER BY game_date ASC LIMIT 1",
        [after_date.to_s]
      ).first
    end

    # Returns one row per pitcher with last outing date, last outing pitches
    # (summed across doubleheader), and 7-day total anchored to before_date.
    # Excludes rows where pitches_thrown = 0.
    def pitcher_availability_data(before_date:)
      db.execute(<<~SQL, [before_date.to_s, before_date.to_s])
        SELECT
          sub.pitcher_name,
          sub.last_outing,
          (
            SELECT SUM(gps2.pitches_thrown)
            FROM game_pitcher_stats gps2
            JOIN games g2 ON g2.game_id = gps2.game_id
            WHERE gps2.pitcher_name = sub.pitcher_name
              AND g2.game_date = sub.last_outing
              AND gps2.pitches_thrown > 0
          ) AS last_pitches,
          sub.seven_day_total
        FROM (
          SELECT
            gps.pitcher_name,
            MAX(g.game_date)     AS last_outing,
            SUM(CASE
              WHEN g.game_date >= date(?, '-7 days') AND gps.pitches_thrown > 0
              THEN gps.pitches_thrown ELSE 0
            END)                 AS seven_day_total
          FROM game_pitcher_stats gps
          JOIN games g ON g.game_id = gps.game_id
          WHERE g.game_date < ?
            AND gps.pitches_thrown > 0
          GROUP BY gps.pitcher_name
        ) sub
        ORDER BY sub.pitcher_name ASC
      SQL
    end

    # Returns all non-canceled games in a date range, ordered by date then game_id.
    # @param from_date [String, Date] inclusive start date
    # @param to_date [String, Date] inclusive end date
    # @return [Array<Hash>]
    def scheduled_games_between(from_date:, to_date:)
      db.execute(
        "SELECT * FROM games WHERE game_date >= ? AND game_date <= ? AND status != 'canceled' ORDER BY game_date ASC, game_id ASC",
        [from_date.to_s, to_date.to_s]
      )
    end

    # Delete all cached data for non-final games (forces re-fetch).
    def clear_non_final
      db.execute("DELETE FROM games WHERE status != 'final'")
    end

    def close
      @conn&.close
      @conn = nil
    end

    private

    def db
      @conn ||= open_connection(db_path).tap { |conn| migrate!(conn) }
    end

    def open_connection(path)
      if path != ':memory:' && !File.exist?(path)
        File.open(path, File::WRONLY | File::CREAT | File::EXCL, 0o600) {}
      end

      conn = SQLite3::Database.new(path)
      conn.results_as_hash = true
      conn.busy_timeout = 5000

      conn.execute('PRAGMA foreign_keys = ON')
      conn.execute('PRAGMA synchronous = NORMAL')
      conn.execute('PRAGMA cache_size = -10000')
      conn.execute('PRAGMA journal_mode = WAL') unless path == ':memory:'

      if path != ':memory:'
        ["#{path}-wal", "#{path}-shm"].each do |sidecar|
          File.chmod(0o600, sidecar) if File.exist?(sidecar)
        end
      end

      conn
    end

    def migrate!(conn)
      conn.execute(<<~SQL)
        CREATE TABLE IF NOT EXISTS schema_migrations (
          version    INTEGER PRIMARY KEY NOT NULL,
          applied_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%SZ', 'now'))
        )
      SQL

      applied = conn.execute('SELECT version FROM schema_migrations').map { |r| r['version'] }.to_set

      MIGRATIONS.reject { |v, _| applied.include?(v) }.each do |version, sql|
        conn.transaction do
          conn.execute_batch(sql)
          conn.execute('INSERT INTO schema_migrations (version) VALUES (?)', [version])
        end
      end
    end

    def iso_now
      Time.now.utc.strftime('%Y-%m-%dT%H:%M:%SZ')
    end
  end
end
