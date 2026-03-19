# frozen_string_literal: true

require 'spec_helper'

RSpec.describe Gamechanger::Storage do
  subject(:storage) { described_class.new(data_dir: ':memory:') }

  after { storage.close }

  describe '#upsert_game and #all_games' do
    let(:game) do
      {
        game_id:   'game-001',
        game_date: '2026-03-10',
        opponent:  'Blue Jays',
        home_away: 'home',
        status:    'final'
      }
    end

    it 'stores and retrieves a game' do
      storage.upsert_game(game)
      games = storage.all_games
      expect(games.length).to eq(1)
      expect(games.first['game_id']).to eq('game-001')
      expect(games.first['status']).to eq('final')
    end

    it 'does not overwrite a final game on re-upsert' do
      storage.upsert_game(game)
      storage.upsert_game(game.merge(opponent: 'CHANGED'))
      expect(storage.all_games.first['opponent']).to eq('Blue Jays')
    end

    it 'overwrites a non-final game on re-upsert' do
      storage.upsert_game(game.merge(status: 'in_progress'))
      storage.upsert_game(game.merge(status: 'final', opponent: 'Updated'))
      expect(storage.all_games.first['opponent']).to eq('Updated')
    end
  end

  describe '#upsert_pitcher_stats and #season_summary' do
    before do
      storage.upsert_game(game_id: 'g1', game_date: '2026-03-01', opponent: 'A', home_away: 'home', status: 'final')
      storage.upsert_game(game_id: 'g2', game_date: '2026-03-08', opponent: 'B', home_away: 'away', status: 'final')
      storage.upsert_pitcher_stats(
        game_id: 'g1',
        stats: [
          { pitcher_name: 'Alice Smith', pitches_thrown: 72, innings_pitched: 5.0 },
          { pitcher_name: 'Bob Jones',   pitches_thrown: 24, innings_pitched: 2.0 }
        ]
      )
      storage.upsert_pitcher_stats(
        game_id: 'g2',
        stats: [{ pitcher_name: 'Alice Smith', pitches_thrown: 65, innings_pitched: 4.1 }]
      )
    end

    it 'returns season totals ordered by total pitches descending' do
      rows = storage.season_summary
      expect(rows.first['pitcher_name']).to eq('Alice Smith')
      expect(rows.first['total_pitches']).to eq(137)
      expect(rows.first['games_pitched']).to eq(2)
    end

    it 'includes 7-day total based on today minus 7 days' do
      rows = storage.season_summary
      alice = rows.find { |r| r['pitcher_name'] == 'Alice Smith' }
      # Both games are in the past, so 7-day total depends on today's date.
      # We just verify the column exists and is numeric.
      expect(alice['seven_day_total']).to be_a(Integer).or be_a(Float)
    end
  end

  describe '#pitcher_games' do
    before do
      storage.upsert_game(game_id: 'g1', game_date: '2026-03-01', opponent: 'A', home_away: 'home', status: 'final')
      storage.upsert_pitcher_stats(
        game_id: 'g1',
        stats: [{ pitcher_name: 'Alice Smith', pitches_thrown: 72, innings_pitched: 5.0 }]
      )
    end

    it 'returns game rows for an exact substring match' do
      result = storage.pitcher_games('Alice')
      expect(result.length).to eq(1)
      expect(result.first['pitches_thrown']).to eq(72)
    end

    it 'is case insensitive' do
      result = storage.pitcher_games('alice smith')
      expect(result.length).to eq(1)
    end

    it 'returns an empty array when no match' do
      expect(storage.pitcher_games('Nonexistent')).to be_empty
    end

    it 'returns a plain string array when multiple pitchers match' do
      storage.upsert_game(game_id: 'g2', game_date: '2026-03-08', opponent: 'B', home_away: 'away', status: 'final')
      storage.upsert_pitcher_stats(
        game_id: 'g2',
        stats: [{ pitcher_name: 'Alice Brown', pitches_thrown: 50, innings_pitched: 3.2 }]
      )
      result = storage.pitcher_games('alice')
      # Two matches — returns array of name strings, not game row hashes
      expect(result).to contain_exactly('Alice Smith', 'Alice Brown')
    end
  end

  describe '#game_by_date' do
    before do
      storage.upsert_game(game_id: 'g1', game_date: '2026-03-10', opponent: 'A', home_away: 'home', status: 'final')
      storage.upsert_pitcher_stats(
        game_id: 'g1',
        stats: [{ pitcher_name: 'Alice Smith', pitches_thrown: 72, innings_pitched: 5.0 }]
      )
    end

    it 'returns game with embedded pitcher_stats' do
      games = storage.game_by_date('2026-03-10')
      expect(games.length).to eq(1)
      expect(games.first['pitcher_stats'].length).to eq(1)
      expect(games.first['pitcher_stats'].first['pitches_thrown']).to eq(72)
    end

    it 'returns empty array for a date with no game' do
      expect(storage.game_by_date('2000-01-01')).to be_empty
    end
  end

  describe '#next_scheduled_game' do
    before do
      storage.upsert_game(game_id: 'past',   game_date: '2026-03-01', opponent: 'Past',   home_away: 'home', status: 'final')
      storage.upsert_game(game_id: 'future1', game_date: '2026-04-01', opponent: 'Future1', home_away: 'home', status: 'scheduled')
      storage.upsert_game(game_id: 'future2', game_date: '2026-04-15', opponent: 'Future2', home_away: 'away', status: 'scheduled')
    end

    it 'returns the nearest future game' do
      result = storage.next_scheduled_game(after_date: '2026-03-16')
      expect(result['game_id']).to eq('future1')
      expect(result['game_date']).to eq('2026-04-01')
    end

    it 'returns nil when no future games exist' do
      expect(storage.next_scheduled_game(after_date: '2030-01-01')).to be_nil
    end
  end

  describe '#pitcher_availability_data' do
    before do
      storage.upsert_game(game_id: 'g1', game_date: '2026-03-01', opponent: 'A', home_away: 'home', status: 'final')
      storage.upsert_game(game_id: 'g2', game_date: '2026-03-15', opponent: 'B', home_away: 'away', status: 'final')
      # Doubleheader — two games on the same date
      storage.upsert_game(game_id: 'g3a', game_date: '2026-03-10', opponent: 'C', home_away: 'home', status: 'final')
      storage.upsert_game(game_id: 'g3b', game_date: '2026-03-10', opponent: 'D', home_away: 'away', status: 'final')
    end

    it 'returns correct last_pitches sum across a doubleheader' do
      storage.upsert_pitcher_stats(game_id: 'g3a', stats: [{ pitcher_name: 'Mason M', pitches_thrown: 40, innings_pitched: 3.0 }])
      storage.upsert_pitcher_stats(game_id: 'g3b', stats: [{ pitcher_name: 'Mason M', pitches_thrown: 30, innings_pitched: 2.0 }])

      rows = storage.pitcher_availability_data(before_date: '2026-03-21')
      mason = rows.find { |r| r['pitcher_name'] == 'Mason M' }
      expect(mason['last_outing']).to eq('2026-03-10')
      expect(mason['last_pitches']).to eq(70)
    end

    it 'excludes 0-pitch outing rows from last outing calculation' do
      storage.upsert_pitcher_stats(game_id: 'g1', stats: [{ pitcher_name: 'Bobby G', pitches_thrown: 0, innings_pitched: nil }])
      storage.upsert_pitcher_stats(game_id: 'g2', stats: [{ pitcher_name: 'Bobby G', pitches_thrown: 50, innings_pitched: 3.0 }])

      rows = storage.pitcher_availability_data(before_date: '2026-03-21')
      bobby = rows.find { |r| r['pitcher_name'] == 'Bobby G' }
      expect(bobby['last_outing']).to eq('2026-03-15')
      expect(bobby['last_pitches']).to eq(50)
    end

    it 'anchors 7-day window to before_date, not today' do
      storage.upsert_pitcher_stats(game_id: 'g1', stats: [{ pitcher_name: 'Chris F', pitches_thrown: 60, innings_pitched: 4.0 }])
      storage.upsert_pitcher_stats(game_id: 'g2', stats: [{ pitcher_name: 'Chris F', pitches_thrown: 55, innings_pitched: 4.0 }])

      # before_date = 2026-03-16 → 7-day window = 2026-03-09 to 2026-03-15
      # g1 is 2026-03-01, g2 is 2026-03-15 → only g2 in window
      rows = storage.pitcher_availability_data(before_date: '2026-03-16')
      chris = rows.find { |r| r['pitcher_name'] == 'Chris F' }
      expect(chris['seven_day_total']).to eq(55)
    end
  end

  describe '#scheduled_games_between' do
    before do
      storage.upsert_game(game_id: 'before', game_date: '2026-03-19', opponent: 'Before',  home_away: 'home', status: 'final')
      storage.upsert_game(game_id: 'g1',     game_date: '2026-03-21', opponent: 'Eagles',  home_away: 'home', status: 'scheduled')
      storage.upsert_game(game_id: 'g2',     game_date: '2026-03-21', opponent: 'Tigers',  home_away: 'away', status: 'scheduled')
      storage.upsert_game(game_id: 'g3',     game_date: '2026-03-22', opponent: 'Hawks',   home_away: 'home', status: 'scheduled')
      storage.upsert_game(game_id: 'after',  game_date: '2026-03-25', opponent: 'After',   home_away: 'home', status: 'scheduled')
    end

    it 'returns games within the date range inclusive' do
      results = storage.scheduled_games_between(from_date: '2026-03-21', to_date: '2026-03-22')
      ids = results.map { |r| r['game_id'] }
      expect(ids).to contain_exactly('g1', 'g2', 'g3')
    end

    it 'excludes games outside the date range' do
      results = storage.scheduled_games_between(from_date: '2026-03-21', to_date: '2026-03-22')
      ids = results.map { |r| r['game_id'] }
      expect(ids).not_to include('before', 'after')
    end

    it 'returns results ordered by date then game_id' do
      results = storage.scheduled_games_between(from_date: '2026-03-21', to_date: '2026-03-22')
      expect(results.first['game_id']).to eq('g1')
      expect(results.last['game_id']).to eq('g3')
    end

    it 'returns an empty array when no games in range' do
      expect(storage.scheduled_games_between(from_date: '2027-01-01', to_date: '2027-01-02')).to be_empty
    end

    it 'accepts Date objects as well as strings' do
      results = storage.scheduled_games_between(from_date: Date.new(2026, 3, 21), to_date: Date.new(2026, 3, 22))
      expect(results.length).to eq(3)
    end
  end

  describe '#upsert_batter_stats and #season_batting_summary' do
    before do
      storage.upsert_game(game_id: 'g1', game_date: '2026-03-01', opponent: 'A', home_away: 'home', status: 'final')
      storage.upsert_game(game_id: 'g2', game_date: '2026-03-08', opponent: 'B', home_away: 'away', status: 'final')
      storage.upsert_batter_stats(
        game_id: 'g1',
        stats: [
          { batter_name: 'Mason Marrero', at_bats: 3, hits: 2, walks: 1, strikeouts: 0 },
          { batter_name: 'Jase Passino',  at_bats: 4, hits: 1, walks: 0, strikeouts: 2 }
        ]
      )
      storage.upsert_batter_stats(
        game_id: 'g2',
        stats: [{ batter_name: 'Mason Marrero', at_bats: 4, hits: 3, walks: 1, strikeouts: 1 }]
      )
    end

    it 'returns season totals sorted by OBP descending' do
      rows = storage.season_batting_summary
      expect(rows.first['batter_name']).to eq('Mason Marrero')
    end

    it 'aggregates at_bats across games' do
      rows = storage.season_batting_summary
      mason = rows.find { |r| r['batter_name'] == 'Mason Marrero' }
      expect(mason['total_ab']).to eq(7)
    end

    it 'counts distinct games' do
      rows = storage.season_batting_summary
      mason = rows.find { |r| r['batter_name'] == 'Mason Marrero' }
      expect(mason['games']).to eq(2)
    end

    it 'upserts existing batter stats (idempotent)' do
      storage.upsert_batter_stats(
        game_id: 'g1',
        stats: [{ batter_name: 'Mason Marrero', at_bats: 3, hits: 2, walks: 1, strikeouts: 0 }]
      )
      rows = storage.season_batting_summary
      mason = rows.find { |r| r['batter_name'] == 'Mason Marrero' }
      expect(mason['total_ab']).to eq(7)  # not doubled
    end

    it 'excludes batters with zero at_bats' do
      storage.upsert_batter_stats(
        game_id: 'g1',
        stats: [{ batter_name: 'Zero Hitter', at_bats: 0, hits: 0, walks: 0, strikeouts: 0 }]
      )
      names = storage.season_batting_summary.map { |r| r['batter_name'] }
      expect(names).not_to include('Zero Hitter')
    end
  end

  describe '#batter_games' do
    before do
      storage.upsert_game(game_id: 'g1', game_date: '2026-03-01', opponent: 'A', home_away: 'home', status: 'final')
      storage.upsert_batter_stats(
        game_id: 'g1',
        stats: [{ batter_name: 'Mason Marrero', at_bats: 3, hits: 2, walks: 1, strikeouts: 0 }]
      )
    end

    it 'returns game rows for an exact substring match' do
      result = storage.batter_games('Mason')
      expect(result.length).to eq(1)
      expect(result.first['at_bats']).to eq(3)
    end

    it 'is case insensitive' do
      result = storage.batter_games('mason marrero')
      expect(result.length).to eq(1)
    end

    it 'returns an empty array when no match' do
      expect(storage.batter_games('Nonexistent')).to be_empty
    end

    it 'returns a plain string array when multiple batters match the substring' do
      storage.upsert_game(game_id: 'g2', game_date: '2026-03-08', opponent: 'B', home_away: 'away', status: 'final')
      storage.upsert_batter_stats(
        game_id: 'g2',
        stats: [{ batter_name: 'Mason Chen', at_bats: 2, hits: 1, walks: 0, strikeouts: 0 }]
      )
      result = storage.batter_games('mason')
      expect(result).to contain_exactly('Mason Marrero', 'Mason Chen')
    end
  end

  describe '#batter_lineup_data' do
    before do
      storage.upsert_game(game_id: 'g1', game_date: '2026-03-01', opponent: 'A', home_away: 'home', status: 'final')
      storage.upsert_game(game_id: 'g2', game_date: '2026-03-15', opponent: 'B', home_away: 'away', status: 'final')
      storage.upsert_batter_stats(
        game_id: 'g1',
        stats: [{ batter_name: 'Alice', at_bats: 3, hits: 1, walks: 1, strikeouts: 0 }]
      )
      storage.upsert_batter_stats(
        game_id: 'g2',
        stats: [{ batter_name: 'Alice', at_bats: 4, hits: 2, walks: 1, strikeouts: 1 }]
      )
    end

    it 'excludes games on or after before_date' do
      rows = storage.batter_lineup_data(before_date: '2026-03-15')
      alice = rows.find { |r| r['batter_name'] == 'Alice' }
      expect(alice['season_ab']).to eq(3)  # only g1
    end

    it 'anchors 7-day window to before_date' do
      # before_date = 2026-03-16, 7-day window = 2026-03-09..
      # g1 = 2026-03-01 (outside), g2 = 2026-03-15 (inside)
      rows = storage.batter_lineup_data(before_date: '2026-03-16')
      alice = rows.find { |r| r['batter_name'] == 'Alice' }
      expect(alice['seven_day_ab']).to eq(4)   # only g2
      expect(alice['seven_day_hits']).to eq(2)
      expect(alice['season_ab']).to eq(7)      # both games
    end

    it 'returns empty array when no batter data exists' do
      expect(storage.batter_lineup_data(before_date: '2020-01-01')).to be_empty
    end
  end

  describe '#player_participation' do
    before do
      storage.upsert_game(game_id: 'g1',  game_date: '2026-03-01', opponent: 'A', home_away: 'home', status: 'final')
      storage.upsert_game(game_id: 'g2',  game_date: '2026-03-08', opponent: 'B', home_away: 'away', status: 'final')
      storage.upsert_game(game_id: 'g3',  game_date: '2026-03-15', opponent: 'C', home_away: 'home', status: 'final')
      storage.upsert_batter_stats(
        game_id: 'g1',
        stats: [
          { batter_name: 'Alice', at_bats: 3, hits: 1, walks: 0, strikeouts: 1 },
          { batter_name: 'Bob',   at_bats: 2, hits: 0, walks: 1, strikeouts: 0 }
        ]
      )
      storage.upsert_batter_stats(
        game_id: 'g2',
        stats: [{ batter_name: 'Alice', at_bats: 3, hits: 2, walks: 1, strikeouts: 0 }]
      )
      storage.upsert_batter_stats(
        game_id: 'g3',
        stats: [{ batter_name: 'Alice', at_bats: 4, hits: 1, walks: 0, strikeouts: 2 }]
      )
      # Bob last batted in g1; Alice batted through g3. Carol only pitches (no batting).
      storage.upsert_pitcher_stats(game_id: 'g2', stats: [{ pitcher_name: 'Carol', pitches_thrown: 45, innings_pitched: 3.0 }])
      storage.upsert_pitcher_stats(game_id: 'g3', stats: [{ pitcher_name: 'Bob',   pitches_thrown: 30, innings_pitched: 2.0 }])
    end

    it 'returns one row per known player across both stat tables' do
      names = storage.player_participation.map { |r| r['player_name'] }
      expect(names).to contain_exactly('Alice', 'Bob', 'Carol')
    end

    it 'sorts by games since last batted descending (most inactive first)' do
      rows = storage.player_participation
      # Bob last batted g1 (2 games ago), Alice last batted g3 (0 games ago)
      expect(rows.first['player_name']).to eq('Bob')
    end

    it 'places players who have never batted last (NULLS LAST)' do
      rows = storage.player_participation
      carol = rows.last
      expect(carol['player_name']).to eq('Carol')
      expect(carol['last_bat_date']).to be_nil
    end

    it 'computes games_since_last_batted as team final games after last appearance' do
      rows = storage.player_participation
      bob = rows.find { |r| r['player_name'] == 'Bob' }
      # Bob last batted g1 (2026-03-01); g2 and g3 are final games after that = 2
      expect(bob['games_since_last_batted']).to eq(2)
    end

    it 'returns 0 games_since_last_batted for player who batted in the most recent game' do
      rows = storage.player_participation
      alice = rows.find { |r| r['player_name'] == 'Alice' }
      expect(alice['games_since_last_batted']).to eq(0)
    end

    it 'counts total_games_batted correctly across games' do
      rows = storage.player_participation
      alice = rows.find { |r| r['player_name'] == 'Alice' }
      expect(alice['total_games_batted']).to eq(3)
    end

    it 'appends total_games (total final games in season) to every row' do
      rows = storage.player_participation
      expect(rows.map { |r| r['total_games'] }.uniq).to eq([3])
    end

    it 'shows pitching data for players who have pitched' do
      rows = storage.player_participation
      bob = rows.find { |r| r['player_name'] == 'Bob' }
      expect(bob['last_pitch_date']).to eq('2026-03-15')
      expect(bob['total_games_pitched']).to eq(1)
    end

    it 'shows nil pitching fields for pure batters' do
      rows = storage.player_participation
      alice = rows.find { |r| r['player_name'] == 'Alice' }
      expect(alice['last_pitch_date']).to be_nil
      expect(alice['total_games_pitched']).to be_nil
    end

    it 'shows nil batting fields for pure pitchers' do
      rows = storage.player_participation
      carol = rows.find { |r| r['player_name'] == 'Carol' }
      expect(carol['last_bat_date']).to be_nil
      expect(carol['total_games_batted']).to be_nil
    end

    it 'returns empty array when no player data exists' do
      empty_storage = described_class.new(data_dir: ':memory:')
      expect(empty_storage.player_participation).to be_empty
      empty_storage.close
    end
  end

  describe '#all_player_development_summary' do
    before do
      (1..10).each do |i|
        storage.upsert_game(
          game_id: "g#{i}", game_date: "2026-01-#{i.to_s.rjust(2, '0')}",
          opponent: 'Team B', home_away: 'home', status: 'final'
        )
      end
      # Jayden: 6 games (qualifies, appears in first and second half)
      (1..6).each do |i|
        storage.upsert_batter_stats(game_id: "g#{i}", stats: [
          { batter_name: 'Jayden', at_bats: 3, hits: i - 1, walks: 1, strikeouts: 0 }
        ])
      end
      # Benchwarmer: only 2 games (below the 3-game threshold)
      [1, 2].each do |i|
        storage.upsert_batter_stats(game_id: "g#{i}", stats: [
          { batter_name: 'Benchwarmer', at_bats: 2, hits: 0, walks: 0, strikeouts: 1 }
        ])
      end
    end

    it 'includes players with 3+ game appearances' do
      names = storage.all_player_development_summary.map { |r| r['player_name'] }
      expect(names).to include('Jayden')
    end

    it 'excludes players with fewer than 3 game appearances' do
      names = storage.all_player_development_summary.map { |r| r['player_name'] }
      expect(names).not_to include('Benchwarmer')
    end

    it 'computes first_half_obp as a Float' do
      row = storage.all_player_development_summary.find { |r| r['player_name'] == 'Jayden' }
      expect(row['first_half_obp']).to be_a(Float)
    end

    it 'computes second_half_obp when player appears in second-half games' do
      # Midpoint = game 5; Jayden appeared through game 6 (seq 6 > 5)
      row = storage.all_player_development_summary.find { |r| r['player_name'] == 'Jayden' }
      expect(row['second_half_obp']).to be_a(Float)
    end

    it 'returns nil second_half_obp for players with only first-half appearances' do
      (1..3).each do |i|
        storage.upsert_batter_stats(game_id: "g#{i}", stats: [
          { batter_name: 'First Half Only', at_bats: 2, hits: 1, walks: 0, strikeouts: 0 }
        ])
      end
      row = storage.all_player_development_summary.find { |r| r['player_name'] == 'First Half Only' }
      expect(row['second_half_obp']).to be_nil
    end

    it 'computes recent_obp from the player last 5 appearances' do
      row = storage.all_player_development_summary.find { |r| r['player_name'] == 'Jayden' }
      expect(row['recent_obp']).to be_a(Float)
    end

    it 'returns results sorted alphabetically by player name' do
      (1..4).each do |i|
        storage.upsert_batter_stats(game_id: "g#{i}", stats: [
          { batter_name: 'Zara', at_bats: 3, hits: 1, walks: 1, strikeouts: 0 }
        ])
      end
      rows  = storage.all_player_development_summary
      names = rows.map { |r| r['player_name'] }
      expect(names).to eq(names.sort)
    end

    it 'includes pitching columns as nil for pure batters' do
      row = storage.all_player_development_summary.find { |r| r['player_name'] == 'Jayden' }
      expect(row['first_half_strike_pct']).to be_nil
      expect(row['total_games_pitched']).to be_nil
    end

    it 'returns empty array when no data meets the threshold' do
      empty = described_class.new(data_dir: ':memory:')
      expect(empty.all_player_development_summary).to be_empty
      empty.close
    end
  end

  describe '#player_batting_arc' do
    before do
      (1..5).each do |i|
        storage.upsert_game(
          game_id: "g#{i}", game_date: "2026-03-0#{i}",
          opponent: 'X', home_away: 'home', status: 'final'
        )
        storage.upsert_batter_stats(game_id: "g#{i}", stats: [
          { batter_name: 'Jayden', at_bats: 3, hits: i - 1, walks: 1, strikeouts: 0 }
        ])
      end
    end

    it 'returns one row per game the player appeared in' do
      expect(storage.player_batting_arc(player_name: 'Jayden').length).to eq(5)
    end

    it 'numbers rows starting at 1 in chronological order' do
      rows = storage.player_batting_arc(player_name: 'Jayden')
      expect(rows.first['game_seq']).to eq(1)
      expect(rows.last['game_seq']).to eq(5)
    end

    it 'returns rows in ascending date order' do
      rows  = storage.player_batting_arc(player_name: 'Jayden')
      dates = rows.map { |r| r['game_date'] }
      expect(dates).to eq(dates.sort)
    end

    it 'returns empty array for unknown player' do
      expect(storage.player_batting_arc(player_name: 'Nobody')).to be_empty
    end
  end

  describe '#player_pitching_arc' do
    before do
      (1..4).each do |i|
        storage.upsert_game(
          game_id: "g#{i}", game_date: "2026-03-0#{i}",
          opponent: 'X', home_away: 'home', status: 'final'
        )
        storage.upsert_pitcher_stats(game_id: "g#{i}", stats: [
          { pitcher_name: 'Sofia', pitches_thrown: 40 + i * 3, strikes_thrown: 26 + i * 2, innings_pitched: 2.0 }
        ])
      end
    end

    it 'returns one row per outing' do
      expect(storage.player_pitching_arc(pitcher_name: 'Sofia').length).to eq(4)
    end

    it 'numbers rows starting at 1 in chronological order' do
      rows = storage.player_pitching_arc(pitcher_name: 'Sofia')
      expect(rows.first['game_seq']).to eq(1)
      expect(rows.last['game_seq']).to eq(4)
    end

    it 'returns empty array for unknown pitcher' do
      expect(storage.player_pitching_arc(pitcher_name: 'Nobody')).to be_empty
    end
  end

  describe '#clear_non_final' do
    it 'removes non-final games but keeps final games' do
      storage.upsert_game(game_id: 'g1', game_date: '2026-03-01', opponent: 'A', home_away: 'home', status: 'final')
      storage.upsert_game(game_id: 'g2', game_date: '2026-03-08', opponent: 'B', home_away: 'away', status: 'in_progress')
      storage.clear_non_final
      ids = storage.all_games.map { |g| g['game_id'] }
      expect(ids).to contain_exactly('g1')
    end
  end
end
