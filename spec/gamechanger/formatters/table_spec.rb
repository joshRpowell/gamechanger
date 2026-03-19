# frozen_string_literal: true

require 'spec_helper'

RSpec.describe Gamechanger::Formatters::Table do
  subject(:fmt) { described_class.new }

  let(:rules) { Gamechanger::PitchRules.new }
  let(:today) { Date.today }

  # ── season_summary ────────────────────────────────────────────────────────

  describe '#season_summary' do
    it 'returns plain text when no rows' do
      expect(fmt.season_summary([])).to include('No pitch data found')
    end

    it 'renders a table with pitcher column' do
      rows = [{
        'pitcher_name' => 'Alice Smith', 'games_pitched' => 2,
        'total_pitches' => 120, 'total_strikes' => 78,
        'avg_per_game' => 60, 'seven_day_total' => 65,
        'last_outing' => '2026-03-05'
      }]
      output = fmt.season_summary(rows)
      expect(output).to include('Alice Smith')
      expect(output).to include('Pitcher')
    end

    it 'handles nil last_outing by rendering dash' do
      rows = [{
        'pitcher_name' => 'Bob', 'games_pitched' => 0,
        'total_pitches' => 0, 'total_strikes' => 0,
        'avg_per_game' => 0, 'seven_day_total' => 0,
        'last_outing' => nil
      }]
      output = fmt.season_summary(rows)
      expect(output).to include('—')
    end

    it 'computes strike percentage for non-zero pitches' do
      rows = [{
        'pitcher_name' => 'Alice', 'games_pitched' => 1,
        'total_pitches' => 100, 'total_strikes' => 65,
        'avg_per_game' => 100, 'seven_day_total' => 100,
        'last_outing' => '2026-03-10'
      }]
      output = fmt.season_summary(rows)
      expect(output).to include('65%')
    end

    it 'renders dash for strike% when zero pitches' do
      rows = [{
        'pitcher_name' => 'New', 'games_pitched' => 0,
        'total_pitches' => 0, 'total_strikes' => 0,
        'avg_per_game' => 0, 'seven_day_total' => 0,
        'last_outing' => nil
      }]
      output = fmt.season_summary(rows)
      expect(output).to include('—')
    end
  end

  # ── pitcher_games ─────────────────────────────────────────────────────────

  describe '#pitcher_games' do
    it 'returns plain text when no games' do
      expect(fmt.pitcher_games('Alice', [])).to include('No games found for pitcher: Alice')
    end

    it 'renders a table with date and opponent' do
      rows = [{
        'game_date' => '2026-03-15', 'opponent' => 'Eagles', 'home_away' => 'home',
        'status' => 'final', 'pitches_thrown' => 60, 'strikes_thrown' => 40,
        'innings_pitched' => 3.0
      }]
      output = fmt.pitcher_games('Alice', rows)
      expect(output).to include('2026-03-15')
      expect(output).to include('Eagles')
    end

    it 'shows "(live)" for in_progress status' do
      rows = [{
        'game_date' => '2026-03-19', 'opponent' => 'Hawks', 'home_away' => 'away',
        'status' => 'in_progress', 'pitches_thrown' => 30, 'strikes_thrown' => 20,
        'innings_pitched' => nil
      }]
      output = fmt.pitcher_games('Bob', rows)
      expect(output).to include('(live)')
    end

    it 'handles nil innings_pitched with dash' do
      rows = [{
        'game_date' => '2026-03-15', 'opponent' => nil, 'home_away' => nil,
        'status' => 'final', 'pitches_thrown' => 0, 'strikes_thrown' => 0,
        'innings_pitched' => nil
      }]
      output = fmt.pitcher_games('Bob', rows)
      expect(output).to include('—')
    end
  end

  # ── availability ──────────────────────────────────────────────────────────

  describe '#availability' do
    it 'includes game info header when game_info present' do
      game_info = { 'game_date' => '2026-03-21', 'opponent' => 'Eagles', 'home_away' => 'home' }
      output = fmt.availability(today + 3, game_info, [], rules)
      expect(output).to include('vs Eagles')
    end

    it 'falls back to target_date header when no game_info' do
      output = fmt.availability(today + 3, nil, [], rules)
      expect(output).to include('Availability for:')
    end

    it 'shows empty message when no pitch data' do
      output = fmt.availability(today + 3, nil, [], rules)
      expect(output).to include('No pitch data found')
    end

    it 'shows green check for available pitcher' do
      rows = [{ 'pitcher_name' => 'Alice', 'last_outing' => (today - 5).to_s,
                'last_pitches' => '20', 'seven_day_total' => '20' }]
      output = fmt.availability(today + 3, nil, rows, rules)
      expect(output).to include('✅')
      expect(output).to include('Alice')
    end

    it 'shows red dot for unavailable pitcher' do
      rows = [{ 'pitcher_name' => 'Tired', 'last_outing' => (today - 1).to_s,
                'last_pitches' => '70', 'seven_day_total' => '70' }]
      output = fmt.availability(today + 2, nil, rows, rules)
      expect(output).to include('🔴')
      expect(output).to include('rest day')
    end

    it 'shows warning for high load pitcher' do
      rows = [{ 'pitcher_name' => 'Heavy', 'last_outing' => (today - 5).to_s,
                'last_pitches' => '30', 'seven_day_total' => '80' }]
      output = fmt.availability(today + 3, nil, rows, rules)
      expect(output).to include('⚠️')
      expect(output).to include('high 7-day load')
    end

    it 'shows "available" without remaining when full daily_max remains' do
      rows = [{ 'pitcher_name' => 'Fresh', 'last_outing' => nil,
                'last_pitches' => '0', 'seven_day_total' => '0' }]
      output = fmt.availability(today + 3, nil, rows, rules)
      expect(output).to include('available')
    end

    it 'shows remaining pitches when less than daily_max' do
      rows = [{ 'pitcher_name' => 'Alice', 'last_outing' => (today - 5).to_s,
                'last_pitches' => '50', 'seven_day_total' => '50' }]
      output = fmt.availability(today + 3, nil, rows, rules)
      expect(output).to include('pitches remaining')
    end

    it 'uses dash for last outing when nil' do
      rows = [{ 'pitcher_name' => 'NewPitcher', 'last_outing' => nil,
                'last_pitches' => '0', 'seven_day_total' => '0' }]
      output = fmt.availability(today + 1, nil, rows, rules)
      expect(output).to include('—')
    end

    it 'shows singular "rest day" when exactly 1 day needed' do
      # 36-50 pitches = 1 rest day, pitched yesterday → needs 1 more rest day
      rows = [{ 'pitcher_name' => 'Alice', 'last_outing' => (today - 1).to_s,
                'last_pitches' => '40', 'seven_day_total' => '40' }]
      output = fmt.availability(today, nil, rows, rules)
      # avail_date = yesterday + 1 + 1 = today+1, so needs 1 day
      expect(output).to include('rest day')
    end
  end

  # ── plan ──────────────────────────────────────────────────────────────────

  describe '#plan' do
    it 'returns plain text when no assignments' do
      expect(fmt.plan([], [], nil, rules)).to include('No games to plan.')
    end

    let(:assignment) do
      Gamechanger::GameAssignment.new(
        game_number: 1, game_date: '2026-03-21', opponent: 'Eagles',
        starter_name: 'Alice', starter_pitches: 45,
        reliever_name: 'Bob', reliever_pitches: 30
      )
    end

    it 'renders tournament table with game info' do
      output = fmt.plan([assignment], [], nil, rules)
      expect(output).to include('Alice')
      expect(output).to include('Tournament Plan')
    end

    it 'handles single-date range label' do
      output = fmt.plan([assignment], [], nil, rules)
      expect(output).to include('3/21')
    end

    it 'handles multi-date range label' do
      a2 = Gamechanger::GameAssignment.new(
        game_number: 2, game_date: '2026-03-22', opponent: 'Hawks',
        starter_name: 'Bob', starter_pitches: 45,
        reliever_name: nil, reliever_pitches: nil
      )
      output = fmt.plan([assignment, a2], [], nil, rules)
      expect(output).to include('–')
    end

    it 'includes post-tournament availability when provided' do
      proj = Gamechanger::PitcherProjection.new(
        pitcher_name: 'Alice', weekend_total: 45,
        last_outing: '2026-03-21', last_pitches: 45
      )
      output = fmt.plan([assignment], [proj], today + 7, rules)
      expect(output).to include('Post-tournament availability')
      expect(output).to include('Alice')
    end

    it 'shows unavailable pitcher in post-tournament availability' do
      proj = Gamechanger::PitcherProjection.new(
        pitcher_name: 'Tired', weekend_total: 80,
        last_outing: (today + 7 - 1).to_s, last_pitches: 70
      )
      output = fmt.plan([assignment], [proj], today + 7, rules)
      expect(output).to include('🔴')
    end

    it 'handles nil starter or reliever' do
      no_reliever = Gamechanger::GameAssignment.new(
        game_number: 1, game_date: '2026-03-21', opponent: nil,
        starter_name: nil, starter_pitches: nil,
        reliever_name: nil, reliever_pitches: nil
      )
      output = fmt.plan([no_reliever], [], nil, rules)
      expect(output).to include('(none eligible)')
    end

    it 'does not render post-tournament section when no projections' do
      output = fmt.plan([assignment], [], today + 7, rules)
      expect(output).not_to include('Post-tournament availability')
    end

    it 'does not render post-tournament section when next_game_date is nil' do
      proj = Gamechanger::PitcherProjection.new(
        pitcher_name: 'Alice', weekend_total: 45,
        last_outing: '2026-03-21', last_pitches: 45
      )
      output = fmt.plan([assignment], [proj], nil, rules)
      expect(output).not_to include('Post-tournament availability')
    end
  end

  # ── hitting ────────────────────────────────────────────────────────────────

  describe '#hitting' do
    it 'returns plain text when no rows' do
      expect(fmt.hitting([])).to include('No batting data found')
    end

    it 'renders table with batter column' do
      rows = [{
        'batter_name' => 'Bob', 'games' => 2,
        'total_ab' => 6, 'total_hits' => 2, 'total_walks' => 1, 'total_k' => 1,
        'seven_day_ab' => 3, 'seven_day_hits' => 1, 'seven_day_walks' => 0
      }]
      output = fmt.hitting(rows)
      expect(output).to include('Bob')
      expect(output).to include('Batter')
    end

    it 'computes avg and obp correctly for non-zero at-bats' do
      rows = [{
        'batter_name' => 'Bob', 'games' => 1,
        'total_ab' => 4, 'total_hits' => 2, 'total_walks' => 1, 'total_k' => 0,
        'seven_day_ab' => 0, 'seven_day_hits' => 0, 'seven_day_walks' => 0
      }]
      output = fmt.hitting(rows)
      expect(output).to include('.500')  # avg: 2/4
      expect(output).to include('.600')  # obp: 3/5
    end

    it 'renders .000 for zero at-bats' do
      rows = [{
        'batter_name' => 'New', 'games' => 0,
        'total_ab' => 0, 'total_hits' => 0, 'total_walks' => 0, 'total_k' => 0,
        'seven_day_ab' => 0, 'seven_day_hits' => 0, 'seven_day_walks' => 0
      }]
      output = fmt.hitting(rows)
      expect(output).to include('.000')
    end
  end

  # ── batter_games ──────────────────────────────────────────────────────────

  describe '#batter_games' do
    it 'returns plain text when no games' do
      expect(fmt.batter_games('Bob', [])).to include('No games found for batter: Bob')
    end

    it 'renders table with game data' do
      rows = [{
        'game_date' => '2026-03-15', 'opponent' => 'Eagles', 'home_away' => 'home',
        'at_bats' => 3, 'hits' => 1, 'walks' => 1, 'strikeouts' => 0
      }]
      output = fmt.batter_games('Bob', rows)
      expect(output).to include('2026-03-15')
      expect(output).to include('Eagles')
    end

    it 'handles nil opponent and home_away with dash' do
      rows = [{
        'game_date' => '2026-03-15', 'opponent' => nil, 'home_away' => nil,
        'at_bats' => 0, 'hits' => 0, 'walks' => 0, 'strikeouts' => 0
      }]
      output = fmt.batter_games('Bob', rows)
      expect(output).to include('—')
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

    it 'renders "no batting data" when both ranked and unranked empty' do
      optimizer = instance_double(Gamechanger::LineupOptimizer, ranked: [], unranked: [])
      output = fmt.lineup(today + 3, nil, optimizer)
      expect(output).to include('No batting data')
    end

    it 'renders lineup table with ranked batters' do
      optimizer = instance_double(Gamechanger::LineupOptimizer, ranked: [slot], unranked: [])
      output = fmt.lineup(today + 3, nil, optimizer)
      expect(output).to include('Bob')
      expect(output).to include('7-Day OBP')
    end

    it 'shows unranked batters section' do
      optimizer = instance_double(Gamechanger::LineupOptimizer, ranked: [slot], unranked: [unranked_slot])
      output = fmt.lineup(today + 3, nil, optimizer)
      expect(output).to include('Unranked')
      expect(output).to include('Carlos')
    end

    it 'includes game info in header when provided' do
      game_info = { 'game_date' => '2026-03-21', 'opponent' => 'Eagles' }
      optimizer = instance_double(Gamechanger::LineupOptimizer, ranked: [slot], unranked: [])
      output = fmt.lineup(today + 3, game_info, optimizer)
      expect(output).to include('vs Eagles')
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
      instance_double(Gamechanger::LineupOptimizer::PlayerSlot,
                      batter_name: 'Carlos')
    end
    let(:arc) do
      Gamechanger::PlayerArc.new(
        player_name: 'Bob',
        bat_trend: '↑', bat_narrative: 'Improving',
        first_half_obp: 0.3, recent_obp: 0.45, second_half_obp: 0.4,
        bat_sparkline: [], pitch_sparkline: [],
        pitch_trend: '→', pitch_narrative: 'Steady',
        first_half_strike_pct: nil, second_half_strike_pct: nil,
        recent_strike_pct: nil,
        total_games_batted: 5, total_games_pitched: 0
      )
    end

    let(:brief_obj) do
      instance_double(
        Gamechanger::PreGameBrief,
        pitcher_plan: [
          {
            'pitcher_name' => 'Alice', 'seven_day_total' => '40',
            'remaining' => 45, 'available' => true, 'high_load' => false,
            'avail_date' => today
          }
        ],
        lineup: instance_double(Gamechanger::LineupOptimizer,
                                ranked: [slot], unranked: [unranked_slot]),
        equity_flags: [
          { 'player_name' => 'Danny', 'total_games' => '5', 'total_games_batted' => '2' }
        ],
        development_spotlights: [arc]
      )
    end

    it 'includes Pre-Game Brief header' do
      output = fmt.brief(today, nil, brief_obj)
      expect(output).to include('Pre-Game Brief')
    end

    it 'includes pitcher plan table' do
      output = fmt.brief(today, nil, brief_obj)
      expect(output).to include('Alice')
      expect(output).to include('Pitcher Plan')
    end

    it 'includes suggested lineup section' do
      output = fmt.brief(today, nil, brief_obj)
      expect(output).to include('Suggested Lineup')
      expect(output).to include('Bob')
    end

    it 'includes equity flags' do
      output = fmt.brief(today, nil, brief_obj)
      expect(output).to include('Equity')
      expect(output).to include('Danny')
    end

    it 'includes development spotlights' do
      output = fmt.brief(today, nil, brief_obj)
      expect(output).to include('Development')
      expect(output).to include('Bob')
    end

    it 'includes game info in header when provided' do
      game_info = { 'game_date' => '2026-03-21', 'opponent' => 'Eagles', 'home_away' => 'home' }
      output = fmt.brief(today, game_info, brief_obj)
      expect(output).to include('vs Eagles')
    end

    it 'renders resting pitcher with red dot' do
      resting_obj = instance_double(
        Gamechanger::PreGameBrief,
        pitcher_plan: [
          {
            'pitcher_name' => 'Tired', 'seven_day_total' => '70',
            'remaining' => 0, 'available' => false, 'high_load' => false,
            'avail_date' => today + 2
          }
        ],
        lineup: instance_double(Gamechanger::LineupOptimizer, ranked: [], unranked: []),
        equity_flags: [], development_spotlights: []
      )
      output = fmt.brief(today, nil, resting_obj)
      expect(output).to include('🔴')
    end

    it 'renders high load warning' do
      heavy_obj = instance_double(
        Gamechanger::PreGameBrief,
        pitcher_plan: [
          {
            'pitcher_name' => 'Heavy', 'seven_day_total' => '80',
            'remaining' => 45, 'available' => true, 'high_load' => true,
            'avail_date' => today
          }
        ],
        lineup: instance_double(Gamechanger::LineupOptimizer, ranked: [], unranked: []),
        equity_flags: [], development_spotlights: []
      )
      output = fmt.brief(today, nil, heavy_obj)
      expect(output).to include('⚠️')
    end

    it 'renders spotlight with bat_narrative when no OBP data' do
      arc_no_obp = Gamechanger::PlayerArc.new(
        player_name: 'New', bat_trend: '↑', bat_narrative: 'Early season',
        first_half_obp: nil, recent_obp: nil, second_half_obp: nil,
        bat_sparkline: [], pitch_sparkline: [],
        pitch_trend: '→', pitch_narrative: nil,
        first_half_strike_pct: nil, second_half_strike_pct: nil,
        recent_strike_pct: nil,
        total_games_batted: 3, total_games_pitched: 0
      )
      no_obp_brief = instance_double(
        Gamechanger::PreGameBrief,
        pitcher_plan: [],
        lineup: instance_double(Gamechanger::LineupOptimizer, ranked: [], unranked: []),
        equity_flags: [], development_spotlights: [arc_no_obp]
      )
      output = fmt.brief(today, nil, no_obp_brief)
      expect(output).to include('Early season')
    end

    it 'renders unranked batters in brief' do
      output = fmt.brief(today, nil, brief_obj)
      expect(output).to include('Carlos')
    end
  end

  # ── game_breakdown ────────────────────────────────────────────────────────

  describe '#game_breakdown' do
    it 'returns plain text when no games' do
      expect(fmt.game_breakdown([])).to include('No game found for that date.')
    end

    it 'renders game header and pitcher stats' do
      games = [{
        'game_date' => '2026-03-15', 'opponent' => 'Eagles', 'home_away' => 'home',
        'status' => 'final',
        'pitcher_stats' => [{
          'pitcher_name' => 'Alice', 'pitches_thrown' => 60,
          'strikes_thrown' => 40, 'innings_pitched' => 3.0
        }]
      }]
      output = fmt.game_breakdown(games)
      expect(output).to include('Eagles')
      expect(output).to include('Alice')
    end

    it 'shows "No pitch data recorded" when stats empty' do
      games = [{
        'game_date' => '2026-03-15', 'opponent' => 'Eagles', 'home_away' => 'home',
        'status' => 'final', 'pitcher_stats' => []
      }]
      output = fmt.game_breakdown(games)
      expect(output).to include('No pitch data recorded.')
    end

    it 'shows "(live)" for in_progress status' do
      games = [{
        'game_date' => '2026-03-19', 'opponent' => 'Hawks', 'home_away' => 'away',
        'status' => 'in_progress', 'pitcher_stats' => []
      }]
      output = fmt.game_breakdown(games)
      expect(output).to include('(live)')
    end

    it 'shows game index labels when multiple games' do
      games = [
        { 'game_date' => '2026-03-19', 'opponent' => 'Eagles', 'home_away' => 'home',
          'status' => 'final', 'pitcher_stats' => [] },
        { 'game_date' => '2026-03-19', 'opponent' => 'Hawks', 'home_away' => 'away',
          'status' => 'final', 'pitcher_stats' => [] }
      ]
      output = fmt.game_breakdown(games)
      expect(output).to include('[Game 1]')
      expect(output).to include('[Game 2]')
    end

    it 'handles nil pitcher_stats gracefully' do
      games = [{
        'game_date' => '2026-03-19', 'opponent' => 'Hawks', 'home_away' => 'away',
        'status' => 'final', 'pitcher_stats' => nil
      }]
      output = fmt.game_breakdown(games)
      expect(output).to include('No pitch data recorded.')
    end
  end

  # ── equity ─────────────────────────────────────────────────────────────────

  describe '#equity' do
    it 'returns plain text when no rows' do
      expect(fmt.equity([])).to include('No player data found')
    end

    it 'renders table with player names' do
      rows = [{
        'player_name' => 'Bob', 'total_games' => '5',
        'last_bat_date' => '2026-03-15', 'games_since_last_batted' => 1,
        'total_games_batted' => '4',
        'last_pitch_date' => nil, 'games_since_last_pitched' => nil
      }]
      output = fmt.equity(rows)
      expect(output).to include('Bob')
      expect(output).to include('Player')
    end

    it 'handles nil last_bat_date and last_pitch_date' do
      rows = [{
        'player_name' => 'Alice', 'total_games' => '3',
        'last_bat_date' => nil, 'games_since_last_batted' => nil,
        'total_games_batted' => nil,
        'last_pitch_date' => nil, 'games_since_last_pitched' => nil
      }]
      output = fmt.equity(rows)
      expect(output).to include('—')
    end
  end

  # ── progress ───────────────────────────────────────────────────────────────

  describe '#progress' do
    it 'returns plain text when no arcs' do
      expect(fmt.progress([])).to include('No player data cached')
    end

    it 'renders table with player arcs' do
      arcs = [
        Gamechanger::PlayerArc.new(
          player_name: 'Bob',
          first_half_obp: 0.3, second_half_obp: 0.4, recent_obp: 0.45,
          total_games_batted: 10,
          bat_trend: '↗', bat_sparkline: [], bat_narrative: 'Improving',
          first_half_strike_pct: 0.6, second_half_strike_pct: 0.65, recent_strike_pct: 0.7,
          total_games_pitched: 3,
          pitch_trend: '↗', pitch_sparkline: [], pitch_narrative: 'Improving',
          pitch_narrative: 'Good'
        )
      ]
      output = fmt.progress(arcs)
      expect(output).to include('Bob')
      expect(output).to include('Player')
    end

    it 'handles nil batting and pitching arcs' do
      arcs = [
        Gamechanger::PlayerArc.new(
          player_name: 'New',
          first_half_obp: nil, second_half_obp: nil, recent_obp: nil,
          total_games_batted: 0,
          bat_trend: '→', bat_sparkline: [], bat_narrative: 'N/A',
          first_half_strike_pct: nil, second_half_strike_pct: nil, recent_strike_pct: nil,
          total_games_pitched: 0,
          pitch_trend: '→', pitch_sparkline: [], pitch_narrative: 'N/A'
        )
      ]
      output = fmt.progress(arcs)
      expect(output).to include('—')
    end
  end

  # ── progress_player ────────────────────────────────────────────────────────

  describe '#progress_player' do
    it 'renders player name and batting arc' do
      arc = Gamechanger::PlayerArc.new(
        player_name: 'Alice',
        first_half_obp: 0.25, second_half_obp: 0.35, recent_obp: 0.4,
        total_games_batted: 8,
        bat_trend: '↗', bat_sparkline: ['▁', '▄', '█'], bat_narrative: 'Improving',
        first_half_strike_pct: 0.55, second_half_strike_pct: 0.6, recent_strike_pct: 0.65,
        total_games_pitched: 4,
        pitch_trend: '↗', pitch_sparkline: ['▁', '▄', '█'], pitch_narrative: 'Improving'
      )
      output = fmt.progress_player(arc)
      expect(output).to include('Alice')
      expect(output).to include('Batting Arc')
      expect(output).to include('Pitching Arc')
    end

    it 'shows (no sparkline data) when sparkline empty' do
      arc = Gamechanger::PlayerArc.new(
        player_name: 'Bob',
        first_half_obp: 0.3, second_half_obp: 0.4, recent_obp: 0.35,
        total_games_batted: 5,
        bat_trend: '→', bat_sparkline: [], bat_narrative: 'Steady',
        first_half_strike_pct: nil, second_half_strike_pct: nil, recent_strike_pct: nil,
        total_games_pitched: 0,
        pitch_trend: '→', pitch_sparkline: [], pitch_narrative: 'N/A'
      )
      output = fmt.progress_player(arc)
      expect(output).to include('(no sparkline data)')
    end

    it 'skips batting section when no batting games' do
      arc = Gamechanger::PlayerArc.new(
        player_name: 'PitcherOnly',
        first_half_obp: nil, second_half_obp: nil, recent_obp: nil,
        total_games_batted: 0,
        bat_trend: '→', bat_sparkline: [], bat_narrative: nil,
        first_half_strike_pct: 0.6, second_half_strike_pct: 0.65, recent_strike_pct: 0.7,
        total_games_pitched: 4,
        pitch_trend: '↗', pitch_sparkline: [], pitch_narrative: 'Good'
      )
      output = fmt.progress_player(arc)
      expect(output).not_to include('Batting Arc')
      expect(output).to include('Pitching Arc')
    end

    it 'skips pitching section when no pitching games' do
      arc = Gamechanger::PlayerArc.new(
        player_name: 'BatterOnly',
        first_half_obp: 0.3, second_half_obp: 0.4, recent_obp: 0.35,
        total_games_batted: 5,
        bat_trend: '↗', bat_sparkline: [], bat_narrative: 'Good',
        first_half_strike_pct: nil, second_half_strike_pct: nil, recent_strike_pct: nil,
        total_games_pitched: 0,
        pitch_trend: '→', pitch_sparkline: [], pitch_narrative: nil
      )
      output = fmt.progress_player(arc)
      expect(output).to include('Batting Arc')
      expect(output).not_to include('Pitching Arc')
    end
  end
end
