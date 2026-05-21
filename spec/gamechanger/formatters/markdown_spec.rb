# frozen_string_literal: true

require 'spec_helper'

RSpec.describe Gamechanger::Formatters::Markdown do
  subject(:fmt) { described_class.new }

  let(:rules) { Gamechanger::PitchRules.new }

  describe '#season_summary' do
    it 'returns italic empty message when no rows' do
      expect(fmt.season_summary([])).to include('_No pitch data found')
    end

    it 'produces a markdown table with Pitcher column' do
      rows = [
        {
          'pitcher_name' => 'Alice Smith', 'games_pitched' => 2,
          'total_pitches' => 120, 'total_strikes' => 78,
          'avg_per_game' => 60, 'seven_day_total' => 65,
          'last_outing' => '2026-03-05'
        }
      ]
      output = fmt.season_summary(rows)
      expect(output).to include('| Pitcher')
      expect(output).to include('Alice Smith')
      expect(output).to include('65%')
    end
  end

  describe '#hitting' do
    it 'returns italic empty message when no rows' do
      expect(fmt.hitting([])).to include('_No batting data found')
    end

    it 'produces a markdown table with Batter column' do
      rows = [
        {
          'batter_name' => 'Bob Jones', 'games' => 2,
          'total_ab' => 6, 'total_hits' => 3, 'total_walks' => 1, 'total_k' => 1,
          'seven_day_ab' => 3, 'seven_day_hits' => 2, 'seven_day_walks' => 0
        }
      ]
      output = fmt.hitting(rows)
      expect(output).to include('| Batter')
      expect(output).to include('Bob Jones')
    end

    it 'renders the Pos column with joined position string' do
      rows = [{
        'batter_name' => 'Bob', 'games' => 1, 'total_ab' => 1,
        'total_hits' => 0, 'total_walks' => 0, 'total_k' => 0,
        'positions' => ['SS', 'P']
      }]
      output = fmt.hitting(rows)
      expect(output).to include('Pos')
      expect(output).to include('SS, P')
    end

    it 'renders an empty Pos cell when positions is empty' do
      rows = [{
        'batter_name' => 'Bench', 'games' => 1, 'total_ab' => 1,
        'total_hits' => 0, 'total_walks' => 0, 'total_k' => 0,
        'positions' => []
      }]
      output = fmt.hitting(rows)
      expect(output).to include('Pos')
      expect(output).to include('Bench')
    end
  end

  describe '#availability' do
    let(:target) { Date.today + 3 }

    it 'returns italic message when no rows' do
      output = fmt.availability(target, nil, [], rules)
      expect(output).to include('_No pitch data found')
    end

    it 'includes ## header and pitcher status bullets' do
      rows = [
        {
          'pitcher_name' => 'Alice Smith',
          'last_outing'  => (target - 5).to_s,
          'last_pitches' => 40,
          'seven_day_total' => 40
        }
      ]
      output = fmt.availability(target, nil, rows, rules)
      expect(output).to include('## ')
      expect(output).to include('Alice Smith')
      expect(output).to include('- ')
    end
  end

  describe '#lineup' do
    let(:optimizer) do
      instance_double(
        Gamechanger::LineupOptimizer,
        ranked: [
          instance_double(Gamechanger::LineupOptimizer::PlayerSlot,
                          position: 1, batter_name: 'Bob Jones',
                          seven_day_obp: 0.5, season_obp: 0.4, trend: '↗')
        ],
        unranked: []
      )
    end

    it 'includes ## header' do
      output = fmt.lineup(Date.today + 3, nil, optimizer)
      expect(output).to include('## Suggested Lineup')
    end

    it 'produces a markdown table with Batter column' do
      output = fmt.lineup(Date.today + 3, nil, optimizer)
      expect(output).to include('Bob Jones')
      expect(output).to include('| #')
    end
  end

  describe '#brief' do
    let(:target)   { Date.today + 3 }
    let(:brief_obj) do
      instance_double(
        Gamechanger::PreGameBrief,
        pitcher_plan:           [],
        lineup:                 instance_double(Gamechanger::LineupOptimizer,
                                                ranked: [], unranked: []),
        equity_flags:           [],
        development_spotlights: []
      )
    end

    it 'produces a # h1 header' do
      output = fmt.brief(target, nil, brief_obj)
      expect(output).to start_with('# Pre-Game Brief')
    end
  end

  describe '#equity' do
    it 'returns italic message when no rows' do
      expect(fmt.equity([])).to include('_No player data found')
    end

    it 'produces a markdown table with Player column' do
      rows = [
        {
          'player_name' => 'Bob Jones', 'total_games' => 2,
          'last_bat_date' => '2026-03-05', 'games_since_last_batted' => 1,
          'total_games_batted' => 2,
          'last_pitch_date' => nil, 'games_since_last_pitched' => nil
        }
      ]
      output = fmt.equity(rows)
      expect(output).to include('| Player')
      expect(output).to include('Bob Jones')
    end
  end

  describe 'md_table (via season_summary)' do
    it 'generates valid markdown table with header and divider rows' do
      rows = [
        {
          'pitcher_name' => 'Alice', 'games_pitched' => 1,
          'total_pitches' => 10, 'total_strikes' => 7,
          'avg_per_game' => 10, 'seven_day_total' => 10,
          'last_outing' => '2026-03-01'
        }
      ]
      output = fmt.season_summary(rows)
      lines = output.split("\n")
      expect(lines[0]).to start_with('|')
      expect(lines[1]).to include('---')
      expect(lines[2]).to start_with('|')
    end
  end

  # ── pitcher_games ─────────────────────────────────────────────────────────

  describe '#pitcher_games' do
    it 'returns italic message when no games' do
      expect(fmt.pitcher_games('Alice', [])).to include('_No games found for pitcher: Alice_')
    end

    it 'produces ## header and markdown table' do
      rows = [{
        'game_date' => '2026-03-15', 'opponent' => 'Eagles', 'home_away' => 'home',
        'status' => 'final', 'pitches_thrown' => 60, 'strikes_thrown' => 40,
        'innings_pitched' => 3.0
      }]
      output = fmt.pitcher_games('Alice', rows)
      expect(output).to include('## Alice')
      expect(output).to include('Eagles')
    end

    it 'renders (live) for in_progress status' do
      rows = [{
        'game_date' => '2026-03-19', 'opponent' => 'Hawks', 'home_away' => 'away',
        'status' => 'in_progress', 'pitches_thrown' => 30, 'strikes_thrown' => 20,
        'innings_pitched' => nil
      }]
      output = fmt.pitcher_games('Bob', rows)
      expect(output).to include('(live)')
    end

    it 'renders dash for nil innings and nil opponent' do
      rows = [{
        'game_date' => '2026-03-15', 'opponent' => nil, 'home_away' => nil,
        'status' => 'final', 'pitches_thrown' => 0, 'strikes_thrown' => 0,
        'innings_pitched' => nil
      }]
      output = fmt.pitcher_games('Bob', rows)
      expect(output).to include('—')
    end
  end

  # ── availability (extended) ────────────────────────────────────────────────

  describe '#availability (extended)' do
    let(:target) { Date.today + 3 }

    it 'shows high load warning for seven_day_total > 75' do
      rows = [{ 'pitcher_name' => 'Heavy', 'last_outing' => (target - 5).to_s,
                'last_pitches' => '30', 'seven_day_total' => '80' }]
      output = fmt.availability(target, nil, rows, rules)
      expect(output).to include('⚠️')
      expect(output).to include('high 7-day load')
    end

    it 'shows unavailable pitcher with rest days' do
      rows = [{ 'pitcher_name' => 'Tired', 'last_outing' => (target - 1).to_s,
                'last_pitches' => '70', 'seven_day_total' => '70' }]
      output = fmt.availability(target, nil, rows, rules)
      expect(output).to include('🔴')
      expect(output).to include('rest day')
    end

    it 'shows available with pitches remaining when below daily_max' do
      rows = [{ 'pitcher_name' => 'Alice', 'last_outing' => (target - 5).to_s,
                'last_pitches' => '50', 'seven_day_total' => '50' }]
      output = fmt.availability(target, nil, rows, rules)
      expect(output).to include('pitches remaining')
    end

    it 'shows full available when no remaining limit' do
      rows = [{ 'pitcher_name' => 'Fresh', 'last_outing' => nil,
                'last_pitches' => '0', 'seven_day_total' => '0' }]
      output = fmt.availability(target, nil, rows, rules)
      expect(output).to include('available')
    end

    it 'includes game info in header' do
      game_info = { 'game_date' => '2026-03-21', 'opponent' => 'Eagles', 'home_away' => 'home' }
      output = fmt.availability(target, game_info, [], rules)
      expect(output).to include('vs Eagles')
    end

    it 'uses dash for nil last_outing' do
      rows = [{ 'pitcher_name' => 'New', 'last_outing' => nil,
                'last_pitches' => '0', 'seven_day_total' => '0' }]
      output = fmt.availability(target, nil, rows, rules)
      expect(output).to include('—')
    end

    it 'renders singular "rest day" when exactly 1 day needed' do
      rows = [{ 'pitcher_name' => 'Alice', 'last_outing' => (Date.today - 1).to_s,
                'last_pitches' => '40', 'seven_day_total' => '40' }]
      output = fmt.availability(Date.today, nil, rows, rules)
      expect(output).to include('rest day')
    end
  end

  # ── plan ──────────────────────────────────────────────────────────────────

  describe '#plan' do
    it 'returns italic message when no assignments' do
      expect(fmt.plan([], [], nil, rules)).to include('_No games to plan._')
    end

    let(:assignment) do
      Gamechanger::GameAssignment.new(
        game_number: 1, game_date: '2026-03-21', opponent: 'Eagles',
        starter_name: 'Alice', starter_pitches: 45,
        reliever_name: 'Bob', reliever_pitches: 30
      )
    end

    it 'renders ## Tournament Plan header with table' do
      output = fmt.plan([assignment], [], nil, rules)
      expect(output).to include('## Tournament Plan')
      expect(output).to include('Alice')
    end

    it 'renders single-date range' do
      output = fmt.plan([assignment], [], nil, rules)
      expect(output).to include('3/21')
    end

    it 'renders multi-date range with dash' do
      a2 = Gamechanger::GameAssignment.new(
        game_number: 2, game_date: '2026-03-22', opponent: 'Hawks',
        starter_name: 'Bob', starter_pitches: 45,
        reliever_name: nil, reliever_pitches: nil
      )
      output = fmt.plan([assignment, a2], [], nil, rules)
      expect(output).to include('–')
    end

    it 'includes post-tournament availability section' do
      proj = Gamechanger::PitcherProjection.new(
        pitcher_name: 'Alice', weekend_total: 45,
        last_outing: '2026-03-21', last_pitches: 45
      )
      output = fmt.plan([assignment], [proj], Date.today + 7, rules)
      expect(output).to include('Post-tournament availability')
      expect(output).to include('Alice')
    end

    it 'marks unavailable pitcher in post-tournament with red dot' do
      proj = Gamechanger::PitcherProjection.new(
        pitcher_name: 'Tired', weekend_total: 80,
        last_outing: (Date.today + 7 - 1).to_s, last_pitches: 70
      )
      output = fmt.plan([assignment], [proj], Date.today + 7, rules)
      expect(output).to include('🔴')
    end

    it 'marks available pitcher in post-tournament with checkmark' do
      proj = Gamechanger::PitcherProjection.new(
        pitcher_name: 'Rested', weekend_total: 20,
        last_outing: '2026-03-21', last_pitches: 20
      )
      output = fmt.plan([assignment], [proj], Date.today + 14, rules)
      expect(output).to include('✅')
    end

    it 'shows available with remaining pitches when below daily_max' do
      proj = Gamechanger::PitcherProjection.new(
        pitcher_name: 'Alice', weekend_total: 45,
        last_outing: '2026-03-21', last_pitches: 45
      )
      output = fmt.plan([assignment], [proj], Date.today + 14, rules)
      expect(output).to include('pitches remaining')
    end

    it 'skips post-tournament section when no projections' do
      output = fmt.plan([assignment], [], Date.today + 7, rules)
      expect(output).not_to include('Post-tournament availability')
    end

    it 'skips post-tournament section when next_game_date nil' do
      proj = Gamechanger::PitcherProjection.new(
        pitcher_name: 'Alice', weekend_total: 45,
        last_outing: '2026-03-21', last_pitches: 45
      )
      output = fmt.plan([assignment], [proj], nil, rules)
      expect(output).not_to include('Post-tournament availability')
    end
  end

  # ── batter_games ──────────────────────────────────────────────────────────

  describe '#batter_games' do
    it 'returns italic message when no games' do
      expect(fmt.batter_games('Bob', [])).to include('_No games found for batter: Bob_')
    end

    it 'renders ## header and markdown table' do
      rows = [{
        'game_date' => '2026-03-15', 'opponent' => 'Eagles', 'home_away' => 'home',
        'at_bats' => 3, 'hits' => 1, 'walks' => 1, 'strikeouts' => 0
      }]
      output = fmt.batter_games('Bob Jones', rows)
      expect(output).to include('## Bob Jones')
      expect(output).to include('Eagles')
    end

    it 'handles nil opponent with dash' do
      rows = [{
        'game_date' => '2026-03-15', 'opponent' => nil, 'home_away' => nil,
        'at_bats' => 0, 'hits' => 0, 'walks' => 0, 'strikeouts' => 0
      }]
      output = fmt.batter_games('Alice', rows)
      expect(output).to include('—')
    end
  end

  # ── lineup (extended) ──────────────────────────────────────────────────────

  describe '#lineup (extended)' do
    it 'returns empty data message when no ranked or unranked' do
      optimizer = instance_double(Gamechanger::LineupOptimizer, ranked: [], unranked: [])
      output = fmt.lineup(Date.today + 3, nil, optimizer)
      expect(output).to include('_No batting data in cache')
    end

    it 'shows unranked batters section' do
      ranked_slot = instance_double(
        Gamechanger::LineupOptimizer::PlayerSlot,
        position: 1, batter_name: 'Bob',
        seven_day_obp: 0.5, season_obp: 0.4, trend: '↗'
      )
      unranked_slot = instance_double(
        Gamechanger::LineupOptimizer::PlayerSlot,
        batter_name: 'Carlos', season_obp: 0.3
      )
      optimizer = instance_double(Gamechanger::LineupOptimizer,
                                  ranked: [ranked_slot], unranked: [unranked_slot])
      output = fmt.lineup(Date.today + 3, nil, optimizer)
      expect(output).to include('Unranked')
      expect(output).to include('Carlos')
    end

    it 'includes game_info in header' do
      ranked_slot = instance_double(
        Gamechanger::LineupOptimizer::PlayerSlot,
        position: 1, batter_name: 'Bob',
        seven_day_obp: 0.5, season_obp: 0.4, trend: '→'
      )
      optimizer = instance_double(Gamechanger::LineupOptimizer, ranked: [ranked_slot], unranked: [])
      game_info = { 'game_date' => '2026-03-21', 'opponent' => 'Eagles' }
      output = fmt.lineup(Date.today + 3, game_info, optimizer)
      expect(output).to include('vs Eagles')
    end
  end

  # ── brief (extended) ──────────────────────────────────────────────────────

  describe '#brief (extended)' do
    let(:today) { Date.today }
    let(:slot) do
      instance_double(
        Gamechanger::LineupOptimizer::PlayerSlot,
        position: 1, batter_name: 'Bob',
        seven_day_obp: 0.5, season_obp: 0.4, trend: '↗'
      )
    end
    let(:unranked_slot) do
      instance_double(Gamechanger::LineupOptimizer::PlayerSlot, batter_name: 'Carlos')
    end
    let(:arc) do
      Gamechanger::PlayerArc.new(
        player_name: 'Bob', bat_trend: '↑', bat_narrative: 'Improving',
        first_half_obp: 0.3, recent_obp: 0.45, second_half_obp: 0.4,
        bat_sparkline: [], pitch_sparkline: [],
        pitch_trend: '→', pitch_narrative: 'Steady',
        first_half_strike_pct: nil, second_half_strike_pct: nil, recent_strike_pct: nil,
        total_games_batted: 5, total_games_pitched: 0
      )
    end

    it 'renders resting pitcher with red dot in brief' do
      resting_brief = instance_double(
        Gamechanger::PreGameBrief,
        pitcher_plan: [{
          'pitcher_name' => 'Tired', 'seven_day_total' => '70',
          'remaining' => 0, 'available' => false, 'high_load' => false,
          'avail_date' => today + 2
        }],
        lineup: instance_double(Gamechanger::LineupOptimizer, ranked: [], unranked: []),
        equity_flags: [], development_spotlights: []
      )
      output = fmt.brief(today, nil, resting_brief)
      expect(output).to include('🔴')
    end

    it 'renders high load warning in brief' do
      heavy_brief = instance_double(
        Gamechanger::PreGameBrief,
        pitcher_plan: [{
          'pitcher_name' => 'Heavy', 'seven_day_total' => '80',
          'remaining' => 45, 'available' => true, 'high_load' => true,
          'avail_date' => today
        }],
        lineup: instance_double(Gamechanger::LineupOptimizer, ranked: [], unranked: []),
        equity_flags: [], development_spotlights: []
      )
      output = fmt.brief(today, nil, heavy_brief)
      expect(output).to include('⚠️')
    end

    it 'renders equity flags section' do
      equity_brief = instance_double(
        Gamechanger::PreGameBrief,
        pitcher_plan: [],
        lineup: instance_double(Gamechanger::LineupOptimizer, ranked: [], unranked: []),
        equity_flags: [{ 'player_name' => 'Danny', 'total_games' => '5', 'total_games_batted' => '2' }],
        development_spotlights: []
      )
      output = fmt.brief(today, nil, equity_brief)
      expect(output).to include('## Equity Flags')
      expect(output).to include('Danny')
    end

    it 'renders development spotlights with OBP trend' do
      spotlight_brief = instance_double(
        Gamechanger::PreGameBrief,
        pitcher_plan: [],
        lineup: instance_double(Gamechanger::LineupOptimizer, ranked: [], unranked: []),
        equity_flags: [],
        development_spotlights: [arc]
      )
      output = fmt.brief(today, nil, spotlight_brief)
      expect(output).to include('## Development Spotlights')
      expect(output).to include('Bob')
    end

    it 'renders spotlight with bat_narrative when no OBP' do
      arc_no_obp = Gamechanger::PlayerArc.new(
        player_name: 'New', bat_trend: '↑', bat_narrative: 'Early season',
        first_half_obp: nil, recent_obp: nil, second_half_obp: nil,
        bat_sparkline: [], pitch_sparkline: [],
        pitch_trend: '→', pitch_narrative: nil,
        first_half_strike_pct: nil, second_half_strike_pct: nil, recent_strike_pct: nil,
        total_games_batted: 2, total_games_pitched: 0
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

    it 'renders spotlight with empty detail when no OBP and no narrative' do
      arc_empty = Gamechanger::PlayerArc.new(
        player_name: 'Blank', bat_trend: '↑', bat_narrative: nil,
        first_half_obp: nil, recent_obp: nil, second_half_obp: nil,
        bat_sparkline: [], pitch_sparkline: [],
        pitch_trend: '→', pitch_narrative: nil,
        first_half_strike_pct: nil, second_half_strike_pct: nil, recent_strike_pct: nil,
        total_games_batted: 2, total_games_pitched: 0
      )
      empty_brief = instance_double(
        Gamechanger::PreGameBrief,
        pitcher_plan: [],
        lineup: instance_double(Gamechanger::LineupOptimizer, ranked: [], unranked: []),
        equity_flags: [], development_spotlights: [arc_empty]
      )
      output = fmt.brief(today, nil, empty_brief)
      expect(output).to include('Blank')
    end

    it 'includes unranked batters in brief lineup section' do
      full_brief = instance_double(
        Gamechanger::PreGameBrief,
        pitcher_plan: [],
        lineup: instance_double(Gamechanger::LineupOptimizer, ranked: [slot], unranked: [unranked_slot]),
        equity_flags: [], development_spotlights: []
      )
      output = fmt.brief(today, nil, full_brief)
      expect(output).to include('Carlos')
    end

    it 'uses game info for header' do
      game_info = { 'game_date' => '2026-03-21', 'opponent' => 'Eagles', 'home_away' => 'home' }
      empty_brief = instance_double(
        Gamechanger::PreGameBrief,
        pitcher_plan: [],
        lineup: instance_double(Gamechanger::LineupOptimizer, ranked: [], unranked: []),
        equity_flags: [], development_spotlights: []
      )
      output = fmt.brief(today, game_info, empty_brief)
      expect(output).to include('vs Eagles')
    end

    it 'renders avail_date nil path for resting pitcher (uses ?)' do
      nil_avail_brief = instance_double(
        Gamechanger::PreGameBrief,
        pitcher_plan: [{
          'pitcher_name' => 'Tired', 'seven_day_total' => '70',
          'remaining' => 0, 'available' => false, 'high_load' => false,
          'avail_date' => nil
        }],
        lineup: instance_double(Gamechanger::LineupOptimizer, ranked: [], unranked: []),
        equity_flags: [], development_spotlights: []
      )
      output = fmt.brief(today, nil, nil_avail_brief)
      expect(output).to include('?d')
    end
  end

  # ── game_breakdown ────────────────────────────────────────────────────────

  describe '#game_breakdown' do
    it 'returns italic message when no games' do
      expect(fmt.game_breakdown([])).to include('_No game found for that date._')
    end

    it 'renders ## game header with pitcher stats table' do
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

    it 'shows "No pitch data recorded" for empty stats' do
      games = [{
        'game_date' => '2026-03-15', 'opponent' => 'Eagles', 'home_away' => 'home',
        'status' => 'final', 'pitcher_stats' => []
      }]
      output = fmt.game_breakdown(games)
      expect(output).to include('_No pitch data recorded._')
    end

    it 'shows "(live)" label for in_progress games' do
      games = [{
        'game_date' => '2026-03-19', 'opponent' => 'Hawks', 'home_away' => 'away',
        'status' => 'in_progress', 'pitcher_stats' => []
      }]
      output = fmt.game_breakdown(games)
      expect(output).to include('_(live)_')
    end

    it 'shows [Game N] labels for multiple games' do
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
      expect(output).to include('_No pitch data recorded._')
    end
  end

  # ── progress ───────────────────────────────────────────────────────────────

  describe '#progress' do
    it 'returns italic message when no arcs' do
      expect(fmt.progress([])).to include('_No player data cached')
    end

    it 'renders markdown table with player arcs' do
      arcs = [
        Gamechanger::PlayerArc.new(
          player_name: 'Bob',
          first_half_obp: 0.3, second_half_obp: 0.4, recent_obp: 0.45,
          total_games_batted: 10,
          bat_trend: '↗', bat_sparkline: [], bat_narrative: 'Improving',
          first_half_strike_pct: 0.6, second_half_strike_pct: 0.65, recent_strike_pct: 0.7,
          total_games_pitched: 3,
          pitch_trend: '↗', pitch_sparkline: [], pitch_narrative: 'Improving'
        )
      ]
      output = fmt.progress(arcs)
      expect(output).to include('Bob')
      expect(output).to include('| Player')
    end

    it 'handles nil batting and pitching arcs with dashes' do
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
    it 'renders player header and batting arc' do
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
      expect(output).to include('## Alice')
      expect(output).to include('### Batting Arc')
      expect(output).to include('### Pitching Arc')
    end

    it 'shows (no sparkline data) when sparkline empty' do
      arc = Gamechanger::PlayerArc.new(
        player_name: 'Bob',
        first_half_obp: 0.3, second_half_obp: 0.4, recent_obp: 0.35,
        total_games_batted: 5,
        bat_trend: '→', bat_sparkline: [], bat_narrative: 'Steady',
        first_half_strike_pct: nil, second_half_strike_pct: nil, recent_strike_pct: nil,
        total_games_pitched: 0,
        pitch_trend: '→', pitch_sparkline: [], pitch_narrative: nil
      )
      output = fmt.progress_player(arc)
      expect(output).to include('_(no sparkline data)_')
    end

    it 'skips batting section when zero batting games' do
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
  end

  # ── hitting (trend arrows via markdown) ───────────────────────────────────

  describe '#hitting trend arrows' do
    it 'renders ↗ for hot batter' do
      rows = [{
        'batter_name' => 'Hot', 'games' => 5,
        'total_ab' => 20, 'total_hits' => 4, 'total_walks' => 0, 'total_k' => 2,
        'seven_day_ab' => 4, 'seven_day_hits' => 3, 'seven_day_walks' => 0
      }]
      output = fmt.hitting(rows)
      expect(output).to include('↗')
    end

    it 'renders → for flat batter (identical 7-day and season OBP)' do
      rows = [{
        'batter_name' => 'Steady', 'games' => 5,
        'total_ab' => 8, 'total_hits' => 4, 'total_walks' => 0, 'total_k' => 1,
        'seven_day_ab' => 4, 'seven_day_hits' => 2, 'seven_day_walks' => 0
      }]
      output = fmt.hitting(rows)
      expect(output).to include('→')
    end

    it 'renders ↘ for cold batter (7-day OBP well below season OBP)' do
      rows = [{
        'batter_name' => 'Cold', 'games' => 10,
        'total_ab' => 20, 'total_hits' => 16, 'total_walks' => 0, 'total_k' => 1,
        'seven_day_ab' => 4, 'seven_day_hits' => 1, 'seven_day_walks' => 0
      }]
      output = fmt.hitting(rows)
      expect(output).to include('↘')
    end
  end

  describe '#brief (pitcher plan ✅ Available)' do
    it 'renders ✅ Available for fully rested pitcher' do
      today = Date.today
      fresh_brief = instance_double(
        Gamechanger::PreGameBrief,
        pitcher_plan: [{
          'pitcher_name' => 'Fresh', 'seven_day_total' => '20',
          'remaining' => 85, 'available' => true, 'high_load' => false,
          'avail_date' => nil
        }],
        lineup: instance_double(Gamechanger::LineupOptimizer, ranked: [], unranked: []),
        equity_flags: [], development_spotlights: []
      )
      output = fmt.brief(today, nil, fresh_brief)
      expect(output).to include('✅ Available')
    end
  end

  describe '#fielding' do
    it 'returns an italic no-data message when rows are empty' do
      expect(fmt.fielding([], %w[P SS])).to include('_No fielding data found')
    end

    it 'renders a markdown table with Player, G, position columns, and Total' do
      rows = [
        { 'player_name' => 'Alice Smith', 'games' => 2, 'positions' => { 'SS' => 3, 'P' => 1 }, 'total' => 4 },
        { 'player_name' => 'Bob Jones',   'games' => 1, 'positions' => { '1B' => 2 }, 'total' => 2 }
      ]
      output = fmt.fielding(rows, %w[P SS 1B])
      expect(output).to include('| Player')
      expect(output).to include('| G ')
      expect(output).to include('Total')
      expect(output).to include('Alice Smith')
      expect(output).to include('Bob Jones')
    end

    it "renders zero counts as '.' in markdown cells" do
      rows = [{ 'player_name' => 'Solo', 'games' => 1, 'positions' => { 'SS' => 1 }, 'total' => 1 }]
      output = fmt.fielding(rows, %w[P SS])
      expect(output).to include('| .')
    end
  end
end
