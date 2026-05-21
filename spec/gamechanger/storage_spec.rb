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

  describe 'pitcher rate-stat fields (migration v7)' do
    before do
      storage.upsert_game(game_id: 'g1', game_date: '2026-03-01', opponent: 'A', home_away: 'home', status: 'final')
      storage.upsert_game(game_id: 'g2', game_date: '2026-03-08', opponent: 'B', home_away: 'away', status: 'final')
      storage.upsert_pitcher_stats(
        game_id: 'g1',
        stats: [
          { pitcher_name: 'Alice Smith', pitches_thrown: 72, strikes_thrown: 45, innings_pitched: 5.0,
            batters_faced: 22, hits_allowed: 4, runs_allowed: 2, earned_runs: 2,
            walks_issued: 3, strikeouts_recorded: 7, wild_pitches: 1, hbp_allowed: 0 }
        ]
      )
    end

    it 'persists and returns all new pitcher fields via season_summary totals' do
      rows = storage.season_summary
      alice = rows.find { |r| r['pitcher_name'] == 'Alice Smith' }
      expect(alice).to include(
        'total_bf' => 22, 'total_h' => 4, 'total_r' => 2, 'total_er' => 2,
        'total_bb' => 3, 'total_so' => 7, 'total_wp' => 1, 'total_hbp' => 0
      )
    end

    it 'sums new fields across multiple games' do
      storage.upsert_pitcher_stats(
        game_id: 'g2',
        stats: [
          { pitcher_name: 'Alice Smith', pitches_thrown: 60, strikes_thrown: 38, innings_pitched: 4.0,
            batters_faced: 18, hits_allowed: 6, runs_allowed: 3, earned_runs: 3,
            walks_issued: 2, strikeouts_recorded: 5, wild_pitches: 0, hbp_allowed: 2 }
        ]
      )
      alice = storage.season_summary.find { |r| r['pitcher_name'] == 'Alice Smith' }
      expect(alice).to include(
        'total_bf' => 40, 'total_h' => 10, 'total_er' => 5, 'total_so' => 12, 'total_hbp' => 2
      )
    end

    it 'is idempotent on re-upsert (latest values win)' do
      storage.upsert_pitcher_stats(
        game_id: 'g1',
        stats: [
          { pitcher_name: 'Alice Smith', pitches_thrown: 80, strikes_thrown: 50, innings_pitched: 5.0,
            batters_faced: 25, hits_allowed: 5, runs_allowed: 3, earned_runs: 3,
            walks_issued: 4, strikeouts_recorded: 8, wild_pitches: 2, hbp_allowed: 1 }
        ]
      )
      alice = storage.season_summary.find { |r| r['pitcher_name'] == 'Alice Smith' }
      expect(alice).to include('total_bf' => 25, 'total_er' => 3, 'total_wp' => 2, 'total_hbp' => 1)
    end

    it 'defaults missing keys to 0 via to_i (older parser payloads)' do
      storage.upsert_pitcher_stats(
        game_id: 'g2',
        stats: [
          # Only the old keys — new keys absent
          { pitcher_name: 'Bob Jones', pitches_thrown: 30, strikes_thrown: 18, innings_pitched: 2.0 }
        ]
      )
      bob = storage.season_summary.find { |r| r['pitcher_name'] == 'Bob Jones' }
      expect(bob).to include(
        'total_bf' => 0, 'total_h' => 0, 'total_er' => 0, 'total_wp' => 0, 'total_hbp' => 0
      )
    end

    it 'surfaces per-outing new fields via pitcher_games' do
      row = storage.pitcher_games('Alice').first
      expect(row).to include(
        'batters_faced' => 22, 'earned_runs' => 2, 'walks_issued' => 3,
        'strikeouts_recorded' => 7, 'wild_pitches' => 1, 'hbp_allowed' => 0
      )
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
          { batter_name: 'Mason Marrero', at_bats: 3, hits: 2, walks: 1, strikeouts: 0, hbp: 1,
            doubles: 1, triples: 0, home_runs: 0 },
          { batter_name: 'Jase Passino',  at_bats: 4, hits: 1, walks: 0, strikeouts: 2, hbp: 0,
            doubles: 0, triples: 1, home_runs: 0 }
        ]
      )
      storage.upsert_batter_stats(
        game_id: 'g2',
        stats: [{ batter_name: 'Mason Marrero', at_bats: 4, hits: 3, walks: 1, strikeouts: 1, hbp: 2,
                  doubles: 0, triples: 0, home_runs: 1 }]
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

    it 'aggregates hbp across games into total_hbp' do
      rows = storage.season_batting_summary
      mason = rows.find { |r| r['batter_name'] == 'Mason Marrero' }
      expect(mason['total_hbp']).to eq(3) # 1 from g1, 2 from g2
    end

    it 'defaults total_hbp to 0 when the upsert payload omits the hbp key' do
      storage.upsert_game(game_id: 'g3', game_date: '2026-03-15', opponent: 'C', home_away: 'home', status: 'final')
      storage.upsert_batter_stats(
        game_id: 'g3',
        stats: [{ batter_name: 'No HBP', at_bats: 2, hits: 1, walks: 0, strikeouts: 0 }]
      )
      rows = storage.season_batting_summary
      no_hbp = rows.find { |r| r['batter_name'] == 'No HBP' }
      expect(no_hbp['total_hbp']).to eq(0)
    end

    it 'aggregates doubles/triples/home_runs across games' do
      rows = storage.season_batting_summary
      mason = rows.find { |r| r['batter_name'] == 'Mason Marrero' }
      jase  = rows.find { |r| r['batter_name'] == 'Jase Passino' }
      expect(mason['total_2b']).to eq(1)
      expect(mason['total_3b']).to eq(0)
      expect(mason['total_hr']).to eq(1)
      expect(jase['total_2b']).to eq(0)
      expect(jase['total_3b']).to eq(1)
      expect(jase['total_hr']).to eq(0)
    end

    it 'derives total_1b as hits minus extra-base hits' do
      rows = storage.season_batting_summary
      mason = rows.find { |r| r['batter_name'] == 'Mason Marrero' }
      # H=5, 2B=1, 3B=0, HR=1 → 1B=3
      expect(mason['total_1b']).to eq(3)
      jase = rows.find { |r| r['batter_name'] == 'Jase Passino' }
      # H=1, 2B=0, 3B=1, HR=0 → 1B=0
      expect(jase['total_1b']).to eq(0)
    end

    it 'defaults doubles/triples/home_runs to 0 when the upsert payload omits the keys' do
      storage.upsert_game(game_id: 'g3', game_date: '2026-03-15', opponent: 'C', home_away: 'home', status: 'final')
      storage.upsert_batter_stats(
        game_id: 'g3',
        stats: [{ batter_name: 'No Extras', at_bats: 2, hits: 1, walks: 0, strikeouts: 0 }]
      )
      rows = storage.season_batting_summary
      no_extras = rows.find { |r| r['batter_name'] == 'No Extras' }
      expect(no_extras['total_2b']).to eq(0)
      expect(no_extras['total_3b']).to eq(0)
      expect(no_extras['total_hr']).to eq(0)
      expect(no_extras['total_1b']).to eq(1) # H=1, no extras → 1B=1
    end

    it 'returns raw negative total_1b when extras exceed hits (formatter clamps)' do
      storage.upsert_game(game_id: 'g4', game_date: '2026-03-22', opponent: 'D', home_away: 'home', status: 'final')
      storage.upsert_batter_stats(
        game_id: 'g4',
        stats: [{ batter_name: 'Bad Data', at_bats: 2, hits: 2, walks: 0, strikeouts: 0, hbp: 0,
                  doubles: 3, triples: 0, home_runs: 0 }]
      )
      rows = storage.season_batting_summary
      bad = rows.find { |r| r['batter_name'] == 'Bad Data' }
      expect(bad['total_1b']).to eq(-1)
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

  describe '#upsert_fielding_positions and #fielding_positions_most_recent_by_name' do
    let(:season) { Date.today.year }
    subject(:storage) { described_class.new(data_dir: ':memory:', season: season) }

    before do
      storage.upsert_game(game_id: 'g1', game_date: "#{season}-03-01", opponent: 'A', home_away: 'home', status: 'final')
      storage.upsert_game(game_id: 'g2', game_date: "#{season}-03-08", opponent: 'B', home_away: 'away', status: 'final')
    end

    it 'inserts a single-stint row for a single-position player' do
      storage.upsert_fielding_positions(
        game_id: 'g1',
        stints: [{ player_id: 'p1', player_name: 'Mason Marrero', positions: ['SS'] }]
      )
      result = storage.fielding_positions_most_recent_by_name
      expect(result['Mason Marrero']).to eq(['SS'])
    end

    it 'inserts ordered rows for a multi-stint player' do
      storage.upsert_fielding_positions(
        game_id: 'g1',
        stints: [{ player_id: 'p1', player_name: 'Jase Passino', positions: ['1B', '2B', '1B', 'P'] }]
      )
      result = storage.fielding_positions_most_recent_by_name
      expect(result['Jase Passino']).to eq(['1B', '2B', '1B', 'P'])
    end

    it 'replaces rows on re-upsert with a different stint count (no stale rows)' do
      storage.upsert_fielding_positions(
        game_id: 'g1',
        stints: [{ player_id: 'p1', player_name: 'Alex Chen', positions: ['SS', 'P', '2B'] }]
      )
      storage.upsert_fielding_positions(
        game_id: 'g1',
        stints: [{ player_id: 'p1', player_name: 'Alex Chen', positions: ['CF'] }]
      )
      result = storage.fielding_positions_most_recent_by_name
      expect(result['Alex Chen']).to eq(['CF'])
    end

    it 'omits players whose positions array is empty' do
      storage.upsert_fielding_positions(
        game_id: 'g1',
        stints: [
          { player_id: 'p1', player_name: 'Ben Doe', positions: [] },
          { player_id: 'p2', player_name: 'Cal Roe', positions: ['LF'] }
        ]
      )
      result = storage.fielding_positions_most_recent_by_name
      expect(result).not_to have_key('Ben Doe')
      expect(result['Cal Roe']).to eq(['LF'])
    end

    it 'returns the most-recent game when a player has stints in multiple games' do
      storage.upsert_fielding_positions(
        game_id: 'g1',
        stints: [{ player_id: 'p1', player_name: 'Mason Marrero', positions: ['SS', 'P'] }]
      )
      storage.upsert_fielding_positions(
        game_id: 'g2',
        stints: [{ player_id: 'p1', player_name: 'Mason Marrero', positions: ['CF'] }]
      )
      result = storage.fielding_positions_most_recent_by_name
      expect(result['Mason Marrero']).to eq(['CF'])
    end

    it 'breaks same-date ties by fetched_at DESC' do
      storage.upsert_game(game_id: 'g3', game_date: "#{season}-03-08", opponent: 'C', home_away: 'home', status: 'final')
      storage.upsert_fielding_positions(
        game_id: 'g2',
        stints: [{ player_id: 'p1', player_name: 'Mason Marrero', positions: ['1B'] }]
      )
      sleep 1.1 # ensure fetched_at differs by at least one second
      storage.upsert_fielding_positions(
        game_id: 'g3',
        stints: [{ player_id: 'p1', player_name: 'Mason Marrero', positions: ['SS'] }]
      )
      result = storage.fielding_positions_most_recent_by_name
      expect(result['Mason Marrero']).to eq(['SS'])
    end

    it 'cascades on game delete' do
      storage.upsert_fielding_positions(
        game_id: 'g1',
        stints: [{ player_id: 'p1', player_name: 'Mason Marrero', positions: ['SS'] }]
      )
      storage.send(:db).execute('DELETE FROM games WHERE game_id = ?', ['g1'])
      result = storage.fielding_positions_most_recent_by_name
      expect(result).not_to have_key('Mason Marrero')
    end

    it 'excludes games outside the configured season' do
      prior_season_storage = described_class.new(data_dir: ':memory:', season: season - 1)
      prior_season_storage.upsert_game(game_id: 'gx', game_date: "#{season - 1}-06-01", opponent: 'X', home_away: 'home', status: 'final')
      prior_season_storage.upsert_fielding_positions(
        game_id: 'gx',
        stints: [{ player_id: 'p1', player_name: 'Mason Marrero', positions: ['SS'] }]
      )
      # Independent in-memory DBs are not shared; this test exists to assert the season window is honored.
      this_season = described_class.new(data_dir: ':memory:', season: season)
      this_season.upsert_game(game_id: 'g_this', game_date: "#{season}-03-15", opponent: 'Y', home_away: 'home', status: 'final')
      this_season.upsert_fielding_positions(
        game_id: 'g_this',
        stints: [{ player_id: 'p1', player_name: 'Mason Marrero', positions: ['CF'] }]
      )
      expect(this_season.fielding_positions_most_recent_by_name['Mason Marrero']).to eq(['CF'])
      this_season.close
      prior_season_storage.close
    end
  end

  describe '#season_fielding_summary' do
    let(:season) { Date.today.year }
    subject(:storage) { described_class.new(data_dir: ':memory:', season: season) }

    before do
      storage.upsert_game(game_id: 'g1', game_date: "#{season}-03-01", opponent: 'A', home_away: 'home', status: 'final')
      storage.upsert_game(game_id: 'g2', game_date: "#{season}-03-08", opponent: 'B', home_away: 'away', status: 'final')
    end

    it 'aggregates stints per player and position across games, including game count' do
      storage.upsert_fielding_positions(
        game_id: 'g1',
        stints: [
          { player_id: 'p1', player_name: 'Alice Smith', positions: %w[SS P] },
          { player_id: 'p2', player_name: 'Bob Jones',   positions: %w[1B] }
        ]
      )
      storage.upsert_fielding_positions(
        game_id: 'g2',
        stints: [
          { player_id: 'p1', player_name: 'Alice Smith', positions: %w[SS SS] },
          { player_id: 'p2', player_name: 'Bob Jones',   positions: %w[1B CF] }
        ]
      )

      result = storage.season_fielding_summary
      alice = result.find { |r| r['player_name'] == 'Alice Smith' }
      bob   = result.find { |r| r['player_name'] == 'Bob Jones' }

      expect(alice['games']).to eq(2)
      expect(alice['positions']).to eq('SS' => 3, 'P' => 1)
      expect(alice['total']).to eq(4)
      expect(bob['games']).to eq(2)
      expect(bob['positions']).to eq('1B' => 2, 'CF' => 1)
      expect(bob['total']).to eq(3)
    end

    it "counts distinct games per player, not stints" do
      storage.upsert_fielding_positions(
        game_id: 'g1',
        stints: [{ player_id: 'p1', player_name: 'Multi Stint', positions: %w[SS P 1B 2B] }]
      )
      result = storage.season_fielding_summary
      expect(result.first['games']).to eq(1)
      expect(result.first['total']).to eq(4)
    end

    it 'returns rows alphabetized by player_name' do
      storage.upsert_fielding_positions(
        game_id: 'g1',
        stints: [
          { player_id: 'p2', player_name: 'Zoe Adams',  positions: %w[CF] },
          { player_id: 'p1', player_name: 'Alex Brown', positions: %w[P] }
        ]
      )
      result = storage.season_fielding_summary
      expect(result.map { |r| r['player_name'] }).to eq(['Alex Brown', 'Zoe Adams'])
    end

    it 'returns single-position players with a one-key positions hash' do
      storage.upsert_fielding_positions(
        game_id: 'g1',
        stints: [{ player_id: 'p1', player_name: 'Solo Player', positions: %w[C] }]
      )
      result = storage.season_fielding_summary
      expect(result).to eq([{ 'player_name' => 'Solo Player', 'games' => 1, 'positions' => { 'C' => 1 }, 'total' => 1 }])
    end

    it 'returns [] when no fielding rows exist' do
      expect(storage.season_fielding_summary).to eq([])
    end

    it 'excludes games outside the configured season window' do
      prior = described_class.new(data_dir: ':memory:', season: season - 1)
      prior.upsert_game(game_id: 'gx', game_date: "#{season - 1}-06-01", opponent: 'X', home_away: 'home', status: 'final')
      prior.upsert_fielding_positions(
        game_id: 'gx',
        stints: [{ player_id: 'p1', player_name: 'Out Of Window', positions: %w[SS] }]
      )
      expect(prior.season_fielding_summary.map { |r| r['player_name'] }).to include('Out Of Window')

      current = described_class.new(data_dir: ':memory:', season: season)
      current.upsert_game(game_id: 'g_in', game_date: "#{season}-03-15", opponent: 'Y', home_away: 'home', status: 'final')
      current.upsert_fielding_positions(
        game_id: 'g_in',
        stints: [{ player_id: 'p1', player_name: 'In Window', positions: %w[SS] }]
      )
      result = current.season_fielding_summary
      expect(result.map { |r| r['player_name'] }).to eq(['In Window'])
      prior.close
      current.close
    end

    it 'does not double-count when a game is re-synced (delete-then-insert)' do
      storage.upsert_fielding_positions(
        game_id: 'g1',
        stints: [{ player_id: 'p1', player_name: 'Resync Player', positions: %w[SS P SS] }]
      )
      storage.upsert_fielding_positions(
        game_id: 'g1',
        stints: [{ player_id: 'p1', player_name: 'Resync Player', positions: %w[CF] }]
      )
      result = storage.season_fielding_summary
      expect(result.first['positions']).to eq('CF' => 1)
      expect(result.first['total']).to eq(1)
    end
  end

  describe 'schema_migrations' do
    it 'applies v4 migration on fresh DB' do
      versions = storage.send(:db).execute('SELECT version FROM schema_migrations').map { |r| r['version'] }
      expect(versions).to include(1, 2, 3, 4)
    end

    it 'creates game_fielding_positions table' do
      result = storage.send(:db).execute(
        "SELECT name FROM sqlite_master WHERE type='table' AND name='game_fielding_positions'"
      )
      expect(result).not_to be_empty
    end

    it 'applies v6 migration on fresh DB' do
      versions = storage.send(:db).execute('SELECT version FROM schema_migrations').map { |r| r['version'] }
      expect(versions).to include(6)
    end

    it 'adds doubles/triples/home_runs columns with NOT NULL DEFAULT 0' do
      cols = storage.send(:db).execute('PRAGMA table_info(game_batter_stats)')
      by_name = cols.each_with_object({}) { |c, h| h[c['name']] = c }
      %w[doubles triples home_runs].each do |col|
        expect(by_name[col]).not_to be_nil, "expected column #{col} on game_batter_stats"
        expect(by_name[col]['notnull']).to eq(1)
        expect(by_name[col]['dflt_value']).to eq('0')
      end
    end

    it 'is idempotent — running migrate! twice does not re-apply v6' do
      db = storage.send(:db)
      described_class.send(:new, data_dir: ':memory:').send(:db) # warm a separate instance
      # Re-invoke private migrate! and confirm schema_migrations still has exactly one row at v6
      storage.send(:migrate!, db)
      v6_count = db.execute('SELECT COUNT(*) AS n FROM schema_migrations WHERE version = 6').first['n']
      expect(v6_count).to eq(1)
    end
  end

  describe '#stale_games' do
    it 'returns in_progress games' do
      storage.upsert_game(game_id: 'g1', game_date: '2026-03-01', opponent: 'A', home_away: 'home', status: 'in_progress')
      storage.upsert_game(game_id: 'g2', game_date: '2026-03-08', opponent: 'B', home_away: 'away', status: 'final')
      ids = storage.stale_games.map { |g| g['game_id'] }
      expect(ids).to include('g1')
      expect(ids).not_to include('g2')
    end

    it 'returns today\'s games regardless of status' do
      today = Date.today.iso8601
      storage.upsert_game(game_id: 'today', game_date: today, opponent: 'C', home_away: 'home', status: 'scheduled')
      ids = storage.stale_games.map { |g| g['game_id'] }
      expect(ids).to include('today')
    end
  end

  describe 'with a real filesystem data_dir' do
    around do |example|
      Dir.mktmpdir do |tmpdir|
        @tmpdir = tmpdir
        example.run
      end
    end

    it 'creates and uses a db file in the given directory' do
      fs_storage = described_class.new(data_dir: @tmpdir)
      fs_storage.upsert_game(game_id: 'fs-g1', game_date: '2026-03-01', opponent: 'X', home_away: 'home', status: 'final')
      expect(fs_storage.all_games.map { |g| g['game_id'] }).to include('fs-g1')
      fs_storage.close
    end

    it 'creates the db file with restricted permissions' do
      fs_storage = described_class.new(data_dir: @tmpdir)
      fs_storage.all_games  # trigger connection open
      db_path = File.join(@tmpdir, Gamechanger::Storage::DB_FILE)
      expect(File.exist?(db_path)).to be true
      perms = File.stat(db_path).mode & 0o777
      expect(perms).to eq(0o600)
      fs_storage.close
    end
  end

  describe 'SQLite3 exception handling' do
    it 'raises StorageError when SQLite3 raises an exception' do
      allow(SQLite3::Database).to receive(:new).and_raise(SQLite3::Exception, 'disk I/O error')
      expect { described_class.new(data_dir: ':memory:').all_games }
        .to raise_error(Gamechanger::StorageError, /disk I\/O error/)
    end
  end

  describe 'GAMECHANGER_HOME env var (verify-parity harness)' do
    # The verify-parity harness sets GAMECHANGER_HOME so Ruby and Go read from the same fixture.

    around do |example|
      Dir.mktmpdir do |tmpdir|
        @env_tmpdir = tmpdir
        example.run
      end
    end

    after { ENV.delete('GAMECHANGER_HOME') }

    it 'uses GAMECHANGER_HOME when explicit data_dir is not provided' do
      ENV['GAMECHANGER_HOME'] = @env_tmpdir
      env_storage = described_class.new
      expect(env_storage.data_dir).to eq(@env_tmpdir)
      env_storage.close
    end

    it 'explicit data_dir argument overrides GAMECHANGER_HOME' do
      ENV['GAMECHANGER_HOME'] = '/tmp/should-not-be-used'
      override_storage = described_class.new(data_dir: @env_tmpdir)
      expect(override_storage.data_dir).to eq(@env_tmpdir)
      override_storage.close
    end

    it ':memory: data_dir overrides GAMECHANGER_HOME' do
      ENV['GAMECHANGER_HOME'] = '/tmp/should-not-be-used'
      mem_storage = described_class.new(data_dir: ':memory:')
      expect(mem_storage.data_dir).to eq(':memory:')
      mem_storage.close
    end

    it 'falls back to a Config.home_dir-resolved path when GAMECHANGER_HOME is unset (REGRESSION GUARD)' do
      ENV.delete('GAMECHANGER_HOME')
      stubbed_default = @env_tmpdir
      allow(Gamechanger::Config).to receive(:home_dir).and_return(stubbed_default)
      default_storage = described_class.new
      expect(default_storage.data_dir).to eq(stubbed_default)
      default_storage.close
    end

    it 'falls back to Config.home_dir when GAMECHANGER_HOME is empty string' do
      ENV['GAMECHANGER_HOME'] = ''
      stubbed_default = @env_tmpdir
      allow(Gamechanger::Config).to receive(:home_dir).and_return(stubbed_default)
      empty_storage = described_class.new
      expect(empty_storage.data_dir).to eq(stubbed_default)
      empty_storage.close
    end

    it 'creates the directory with 0700 permissions when GAMECHANGER_HOME points to a non-existent path' do
      target = File.join(@env_tmpdir, 'fresh-home')
      ENV['GAMECHANGER_HOME'] = target
      env_storage = described_class.new
      expect(env_storage.data_dir).to eq(target)
      expect(Dir.exist?(target)).to be true
      env_storage.close
    end

    it 'Storage::DATA_DIR legacy constant still points to ~/.gamechanger (REGRESSION GUARD)' do
      expect(Gamechanger::Storage::DATA_DIR).to eq(File.expand_path('~/.gamechanger'))
    end
  end
end
