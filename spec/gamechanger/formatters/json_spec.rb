# frozen_string_literal: true

require 'spec_helper'
require 'json'

RSpec.describe Gamechanger::Formatters::Json do
  subject(:fmt) { described_class.new }

  let(:rules) { Gamechanger::PitchRules.new }
  let(:today) { Date.today }

  # ── season_summary ────────────────────────────────────────────────────────

  describe '#season_summary' do
    it 'returns valid JSON array' do
      rows = [{ pitcher_name: 'Alice', games_pitched: 2 }]
      result = JSON.parse(fmt.season_summary(rows))
      expect(result).to be_an(Array)
      expect(result.first['pitcher_name']).to eq('Alice')
    end

    it 'returns empty array for no rows' do
      result = JSON.parse(fmt.season_summary([]))
      expect(result).to eq([])
    end

    it 'stringifies symbol keys' do
      rows = [{ pitcher_name: 'Bob', total_pitches: 100 }]
      result = JSON.parse(fmt.season_summary(rows))
      expect(result.first.keys).to all(be_a(String))
    end
  end

  # ── pitcher_games ─────────────────────────────────────────────────────────

  describe '#pitcher_games' do
    it 'returns valid JSON object with pitcher and games keys' do
      rows = [{ game_date: '2026-03-15', pitches_thrown: 60 }]
      result = JSON.parse(fmt.pitcher_games('Alice Smith', rows))
      expect(result['pitcher']).to eq('Alice Smith')
      expect(result['games']).to be_an(Array)
      expect(result['games'].first['game_date']).to eq('2026-03-15')
    end

    it 'handles empty games array' do
      result = JSON.parse(fmt.pitcher_games('Alice Smith', []))
      expect(result['games']).to eq([])
    end
  end

  # ── game_breakdown ────────────────────────────────────────────────────────

  describe '#game_breakdown' do
    it 'returns valid JSON array with stringified keys' do
      games = [{ game_date: '2026-03-15', opponent: 'Eagles' }]
      result = JSON.parse(fmt.game_breakdown(games))
      expect(result).to be_an(Array)
      expect(result.first['game_date']).to eq('2026-03-15')
    end
  end

  # ── plan ──────────────────────────────────────────────────────────────────

  describe '#plan' do
    let(:assignment) do
      Gamechanger::GameAssignment.new(
        game_number:     1,
        game_date:       '2026-03-21',
        opponent:        'Eagles',
        starter_name:    'Alice',
        starter_pitches: 45,
        reliever_name:   'Bob',
        reliever_pitches: 30
      )
    end

    let(:projection) do
      Gamechanger::PitcherProjection.new(
        pitcher_name:  'Alice',
        weekend_total: 45,
        last_outing:   '2026-03-21',
        last_pitches:  45
      )
    end

    it 'returns valid JSON with tournament structure' do
      result = JSON.parse(fmt.plan([assignment], [projection], today + 7, rules))
      expect(result['tournament']).to be_a(Hash)
      expect(result['tournament']['games']).to be_an(Array)
    end

    it 'includes starter and reliever info in game' do
      result = JSON.parse(fmt.plan([assignment], [projection], today + 7, rules))
      game = result['tournament']['games'].first
      expect(game['starter']['name']).to eq('Alice')
      expect(game['reliever']['name']).to eq('Bob')
    end

    it 'includes post-tournament availability when next_game_date and projections present' do
      result = JSON.parse(fmt.plan([assignment], [projection], today + 7, rules))
      avail = result['tournament']['post_tournament_availability']
      expect(avail).not_to be_nil
      expect(avail['pitchers']).to be_an(Array)
    end

    it 'handles nil starter or reliever' do
      no_reliever = Gamechanger::GameAssignment.new(
        game_number: 1, game_date: '2026-03-21', opponent: 'Eagles',
        starter_name: 'Alice', starter_pitches: 45,
        reliever_name: nil, reliever_pitches: nil
      )
      result = JSON.parse(fmt.plan([no_reliever], [], nil, rules))
      game = result['tournament']['games'].first
      expect(game['reliever']).to be_nil
      expect(result['tournament']['post_tournament_availability']).to be_nil
    end

    it 'returns nil post_avail when next_game_date is nil' do
      result = JSON.parse(fmt.plan([assignment], [projection], nil, rules))
      expect(result['tournament']['post_tournament_availability']).to be_nil
    end

    it 'returns nil post_avail when projections is empty' do
      result = JSON.parse(fmt.plan([assignment], [], today + 7, rules))
      expect(result['tournament']['post_tournament_availability']).to be_nil
    end
  end

  # ── brief ──────────────────────────────────────────────────────────────────

  describe '#brief' do
    let(:slot) do
      instance_double(
        Gamechanger::LineupOptimizer::PlayerSlot,
        position: 1, batter_name: 'Bob',
        seven_day_obp: 0.5, season_obp: 0.4, trend: '↗'
      )
    end

    let(:unranked_slot) do
      instance_double(
        Gamechanger::LineupOptimizer::PlayerSlot,
        batter_name: 'Carlos', season_obp: 0.3
      )
    end

    let(:arc) do
      Gamechanger::PlayerArc.new(
        player_name: 'Bob',
        bat_trend: '↗', bat_narrative: 'Improving',
        first_half_obp: 0.3, recent_obp: 0.45,
        bat_sparkline: [], pitch_sparkline: [],
        pitch_trend: '→', pitch_narrative: 'Steady',
        first_half_strike_pct: nil, second_half_strike_pct: nil,
        recent_strike_pct: nil, second_half_obp: nil,
        total_games_batted: 5, total_games_pitched: 0
      )
    end

    let(:brief_obj) do
      instance_double(
        Gamechanger::PreGameBrief,
        pitcher_plan: [
          {
            'pitcher_name' => 'Alice', 'last_outing' => (today - 5).to_s,
            'last_pitches' => '40', 'seven_day_total' => '40',
            'available' => true, 'remaining' => 45,
            'avail_date' => today.to_s, 'high_load' => false
          }
        ],
        lineup:                 instance_double(Gamechanger::LineupOptimizer,
                                                ranked: [slot], unranked: [unranked_slot]),
        equity_flags:           [
          { 'player_name' => 'Bob', 'total_games' => '5', 'total_games_batted' => '5' }
        ],
        development_spotlights: [arc]
      )
    end

    it 'returns valid JSON with all top-level keys' do
      result = JSON.parse(fmt.brief(today, { opponent: 'Eagles' }, brief_obj))
      expect(result.keys).to include('pitcher_plan', 'suggested_lineup', 'equity_flags', 'development_spotlights')
    end

    it 'includes pitcher plan entries' do
      result = JSON.parse(fmt.brief(today, nil, brief_obj))
      expect(result['pitcher_plan'].first['pitcher_name']).to eq('Alice')
    end

    it 'includes ranked lineup slots' do
      result = JSON.parse(fmt.brief(today, nil, brief_obj))
      expect(result['suggested_lineup']['ranked'].first['batter_name']).to eq('Bob')
    end

    it 'includes unranked slots' do
      result = JSON.parse(fmt.brief(today, nil, brief_obj))
      expect(result['suggested_lineup']['unranked'].first['batter_name']).to eq('Carlos')
    end

    it 'includes equity flags' do
      result = JSON.parse(fmt.brief(today, nil, brief_obj))
      expect(result['equity_flags'].first['player_name']).to eq('Bob')
    end

    it 'includes development spotlights' do
      result = JSON.parse(fmt.brief(today, nil, brief_obj))
      spotlight = result['development_spotlights'].first
      expect(spotlight['player_name']).to eq('Bob')
      expect(spotlight['bat_narrative']).to eq('Improving')
    end

    it 'handles nil first_half_obp in spotlight' do
      arc_nil = Gamechanger::PlayerArc.new(
        player_name: 'Zoe', bat_trend: '→', bat_narrative: 'Steady',
        first_half_obp: nil, recent_obp: nil,
        bat_sparkline: [], pitch_sparkline: [],
        pitch_trend: '→', pitch_narrative: 'Steady',
        first_half_strike_pct: nil, second_half_strike_pct: nil,
        recent_strike_pct: nil, second_half_obp: nil,
        total_games_batted: 0, total_games_pitched: 0
      )
      brief_nil = instance_double(Gamechanger::PreGameBrief,
                                  pitcher_plan: [], lineup: instance_double(Gamechanger::LineupOptimizer, ranked: [], unranked: []),
                                  equity_flags: [], development_spotlights: [arc_nil])
      result = JSON.parse(fmt.brief(today, nil, brief_nil))
      expect(result['development_spotlights'].first['first_half_obp']).to be_nil
    end
  end

  # ── hitting ────────────────────────────────────────────────────────────────

  describe '#hitting' do
    it 'returns valid JSON array' do
      rows = [{
        'batter_name' => 'Bob', 'games' => 2,
        'total_ab' => 6, 'total_hits' => 2, 'total_walks' => 1, 'total_k' => 1,
        'seven_day_ab' => 3, 'seven_day_hits' => 1, 'seven_day_walks' => 0
      }]
      result = JSON.parse(fmt.hitting(rows))
      expect(result.first['batter_name']).to eq('Bob')
    end

    it 'computes season_obp correctly' do
      rows = [{
        'batter_name' => 'Bob', 'games' => 1,
        'total_ab' => 4, 'total_hits' => 2, 'total_walks' => 1, 'total_k' => 0,
        'seven_day_ab' => 4, 'seven_day_hits' => 2, 'seven_day_walks' => 1
      }]
      result = JSON.parse(fmt.hitting(rows))
      expect(result.first['obp']).to be_within(0.001).of(0.6)
    end

    it 'handles zero at-bats without crashing' do
      rows = [{
        'batter_name' => 'New', 'games' => 0,
        'total_ab' => 0, 'total_hits' => 0, 'total_walks' => 0, 'total_k' => 0,
        'seven_day_ab' => 0, 'seven_day_hits' => 0, 'seven_day_walks' => 0
      }]
      result = JSON.parse(fmt.hitting(rows))
      expect(result.first['obp']).to eq(0.0)
      expect(result.first['seven_day_obp']).to be_nil
    end

    it 'sets trending up arrow when 7-day OBP significantly better' do
      rows = [{
        'batter_name' => 'Hot', 'games' => 5,
        'total_ab' => 20, 'total_hits' => 4, 'total_walks' => 0, 'total_k' => 2,
        'seven_day_ab' => 4, 'seven_day_hits' => 3, 'seven_day_walks' => 0
      }]
      result = JSON.parse(fmt.hitting(rows))
      expect(result.first['trend']).to eq('↗')
    end

    it 'sets trending down arrow when 7-day OBP significantly worse' do
      rows = [{
        'batter_name' => 'Cold', 'games' => 5,
        'total_ab' => 4, 'total_hits' => 3, 'total_walks' => 0, 'total_k' => 0,
        'seven_day_ab' => 20, 'seven_day_hits' => 2, 'seven_day_walks' => 0
      }]
      result = JSON.parse(fmt.hitting(rows))
      expect(result.first['trend']).to eq('↘')
    end

    it 'sets flat arrow when 7-day OBP is nil (no recent games)' do
      rows = [{
        'batter_name' => 'NoRecent', 'games' => 2,
        'total_ab' => 6, 'total_hits' => 2, 'total_walks' => 0, 'total_k' => 0,
        'seven_day_ab' => 0, 'seven_day_hits' => 0, 'seven_day_walks' => 0
      }]
      result = JSON.parse(fmt.hitting(rows))
      expect(result.first['trend']).to eq('→')
    end

    it 'emits positions as an array of strings' do
      rows = [{
        'batter_name' => 'Bob', 'games' => 1, 'total_ab' => 1,
        'total_hits' => 0, 'total_walks' => 0, 'total_k' => 0,
        'positions' => ['SS', 'P']
      }]
      result = JSON.parse(fmt.hitting(rows))
      expect(result.first['positions']).to eq(['SS', 'P'])
    end

    it 'emits positions as an empty array when missing or empty' do
      rows = [{
        'batter_name' => 'Bench', 'games' => 1, 'total_ab' => 1,
        'total_hits' => 0, 'total_walks' => 0, 'total_k' => 0
      }]
      result = JSON.parse(fmt.hitting(rows))
      expect(result.first['positions']).to eq([])
    end
  end

  # ── batter_games ──────────────────────────────────────────────────────────

  describe '#batter_games' do
    it 'returns valid JSON with batter and games keys' do
      rows = [{ game_date: '2026-03-15', at_bats: 3 }]
      result = JSON.parse(fmt.batter_games('Bob Jones', rows))
      expect(result['batter']).to eq('Bob Jones')
      expect(result['games']).to be_an(Array)
    end
  end

  # ── lineup ─────────────────────────────────────────────────────────────────

  describe '#lineup' do
    let(:slot) do
      instance_double(
        Gamechanger::LineupOptimizer::PlayerSlot,
        position: 1, batter_name: 'Bob',
        seven_day_obp: 0.5, season_obp: 0.4, trend: '↗'
      )
    end
    let(:unranked_slot) do
      instance_double(
        Gamechanger::LineupOptimizer::PlayerSlot,
        batter_name: 'Carlos', season_obp: 0.3
      )
    end
    let(:optimizer) do
      instance_double(Gamechanger::LineupOptimizer, ranked: [slot], unranked: [unranked_slot])
    end

    it 'returns valid JSON with ranked and unranked keys' do
      result = JSON.parse(fmt.lineup(today + 3, nil, optimizer))
      expect(result['ranked'].first['batter_name']).to eq('Bob')
      expect(result['unranked'].first['batter_name']).to eq('Carlos')
    end

    it 'includes target_date' do
      result = JSON.parse(fmt.lineup(today + 3, { opponent: 'Eagles' }, optimizer))
      expect(result['target_date']).to eq((today + 3).to_s)
    end
  end

  # ── equity ─────────────────────────────────────────────────────────────────

  describe '#equity' do
    it 'returns valid JSON with total_team_games and players' do
      rows = [
        {
          'player_name' => 'Bob', 'total_games' => '5',
          'last_bat_date' => '2026-03-15', 'games_since_last_batted' => 1,
          'total_games_batted' => '5',
          'last_pitch_date' => nil, 'games_since_last_pitched' => nil,
          'total_games_pitched' => nil
        }
      ]
      result = JSON.parse(fmt.equity(rows))
      expect(result['total_team_games']).to eq(5)
      expect(result['players'].first['player_name']).to eq('Bob')
    end

    it 'handles empty rows' do
      result = JSON.parse(fmt.equity([]))
      expect(result['total_team_games']).to eq(0)
    end

    it 'handles nil batting_participation when total_games_batted is nil' do
      rows = [{
        'player_name' => 'Bob', 'total_games' => '5',
        'last_bat_date' => nil, 'games_since_last_batted' => nil,
        'total_games_batted' => nil,
        'last_pitch_date' => nil, 'games_since_last_pitched' => nil,
        'total_games_pitched' => nil
      }]
      result = JSON.parse(fmt.equity(rows))
      expect(result['players'].first['batting_participation']).to be_nil
    end
  end

  # ── progress ───────────────────────────────────────────────────────────────

  describe '#progress' do
    let(:arc) do
      Gamechanger::PlayerArc.new(
        player_name: 'Bob',
        first_half_obp: 0.3, second_half_obp: 0.4, recent_obp: 0.45,
        total_games_batted: 10,
        bat_trend: '↗', bat_sparkline: ['▁', '▃', '▆'], bat_narrative: 'Improving',
        first_half_strike_pct: 0.6, second_half_strike_pct: 0.65, recent_strike_pct: 0.7,
        total_games_pitched: 3,
        pitch_trend: '↗', pitch_sparkline: ['▁', '▄', '█'], pitch_narrative: 'Improving',
        second_half_obp: nil
      )
    end

    it 'returns valid JSON array with player arcs' do
      result = JSON.parse(fmt.progress([arc]))
      expect(result.first['player']).to eq('Bob')
      expect(result.first['batting']['trend']).to eq('↗')
      expect(result.first['pitching']['trend']).to eq('↗')
    end

    it 'handles empty sparkline as nil' do
      empty_sparkline_arc = Gamechanger::PlayerArc.new(
        player_name: 'Empty',
        first_half_obp: nil, second_half_obp: nil, recent_obp: nil,
        total_games_batted: 0, bat_trend: '→', bat_sparkline: [], bat_narrative: 'N/A',
        first_half_strike_pct: nil, second_half_strike_pct: nil, recent_strike_pct: nil,
        total_games_pitched: 0, pitch_trend: '→', pitch_sparkline: [], pitch_narrative: 'N/A'
      )
      result = JSON.parse(fmt.progress([empty_sparkline_arc]))
      expect(result.first['batting']['sparkline']).to be_nil
      expect(result.first['pitching']['sparkline']).to be_nil
    end
  end

  # ── progress_player ────────────────────────────────────────────────────────

  describe '#progress_player' do
    let(:arc) do
      Gamechanger::PlayerArc.new(
        player_name: 'Alice',
        first_half_obp: 0.25, second_half_obp: 0.35, recent_obp: 0.4,
        total_games_batted: 8,
        bat_trend: '↗', bat_sparkline: [], bat_narrative: 'Improving',
        first_half_strike_pct: 0.55, second_half_strike_pct: 0.6, recent_strike_pct: 0.65,
        total_games_pitched: 4,
        pitch_trend: '↗', pitch_sparkline: [], pitch_narrative: 'Improving'
      )
    end

    it 'returns valid JSON object with batting and pitching sections' do
      result = JSON.parse(fmt.progress_player(arc))
      expect(result['player']).to eq('Alice')
      expect(result['batting']).to be_a(Hash)
      expect(result['pitching']).to be_a(Hash)
    end

    it 'handles empty sparkline as nil' do
      result = JSON.parse(fmt.progress_player(arc))
      expect(result['batting']['sparkline']).to be_nil
    end
  end

  # ── availability ───────────────────────────────────────────────────────────

  describe '#availability' do
    let(:target) { today + 3 }

    it 'returns valid JSON with target_date, game, and pitchers keys' do
      rows = [{
        'pitcher_name' => 'Alice', 'last_outing' => (target - 5).to_s,
        'last_pitches' => '40', 'seven_day_total' => '40'
      }]
      result = JSON.parse(fmt.availability(target, { opponent: 'Eagles' }, rows, rules))
      expect(result['target_date']).to eq(target.to_s)
      expect(result['pitchers']).to be_an(Array)
    end

    it 'marks available pitcher correctly' do
      rows = [{
        'pitcher_name' => 'Alice', 'last_outing' => (target - 5).to_s,
        'last_pitches' => '20', 'seven_day_total' => '20'
      }]
      result = JSON.parse(fmt.availability(target, nil, rows, rules))
      pitcher = result['pitchers'].first
      expect(pitcher['available']).to be true
      expect(pitcher['pitches_remaining']).to eq(65)
    end

    it 'marks unavailable pitcher and sets pitches_remaining to 0' do
      rows = [{
        'pitcher_name' => 'Tired', 'last_outing' => (target - 1).to_s,
        'last_pitches' => '70', 'seven_day_total' => '70'
      }]
      result = JSON.parse(fmt.availability(target, nil, rows, rules))
      pitcher = result['pitchers'].first
      expect(pitcher['available']).to be false
      expect(pitcher['pitches_remaining']).to eq(0)
    end

    it 'sets high_load_warning when seven_day_total > 75' do
      rows = [{
        'pitcher_name' => 'Heavy', 'last_outing' => (target - 5).to_s,
        'last_pitches' => '30', 'seven_day_total' => '80'
      }]
      result = JSON.parse(fmt.availability(target, nil, rows, rules))
      expect(result['pitchers'].first['high_load_warning']).to be true
    end
  end
end
