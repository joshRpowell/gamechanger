# frozen_string_literal: true

require 'spec_helper'

RSpec.describe Gamechanger::Formatters::Markdown do
  subject(:fmt) { described_class.new }

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
  end

  describe '#availability' do
    let(:rules)  { Gamechanger::PitchRules.new }
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
end
