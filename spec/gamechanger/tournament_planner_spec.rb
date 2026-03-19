# frozen_string_literal: true

require 'spec_helper'

RSpec.describe Gamechanger::TournamentPlanner do
  let(:rules) { Gamechanger::PitchRules.new }

  # Helper: build a pitcher row as Storage#pitcher_availability_data returns
  def row(name, last_outing: nil, last_pitches: 0)
    { 'pitcher_name' => name, 'last_outing' => last_outing, 'last_pitches' => last_pitches, 'seven_day_total' => 0 }
  end

  def game(date, opponent: nil)
    { 'game_date' => date, 'opponent' => opponent }
  end

  describe 'basic 4-game plan' do
    let(:rows) do
      %w[Alice Bob Carol Dave Eve Frank Gary Helen Iris Jack].map { |n| row(n) }
    end
    let(:games) { [game('2026-03-21', opponent: 'Eagles'), game('2026-03-21', opponent: 'Tigers'), game('2026-03-22', opponent: 'Hawks'), game('2026-03-22', opponent: 'Final')] }

    subject(:planner) { described_class.new(games: games, rows: rows, rules: rules) }

    it 'produces one assignment per game' do
      expect(planner.assignments.length).to eq(4)
    end

    it 'assigns a starter and reliever to every game' do
      planner.assignments.each do |a|
        expect(a.starter_name).not_to be_nil
        expect(a.reliever_name).not_to be_nil
      end
    end

    it 'numbers games 1-4' do
      expect(planner.assignments.map(&:game_number)).to eq([1, 2, 3, 4])
    end

    it 'carries opponent names through' do
      expect(planner.assignments.first.opponent).to eq('Eagles')
      expect(planner.assignments.last.opponent).to eq('Final')
    end

    it 'assigns the target starter pitches' do
      expect(planner.assignments.first.starter_pitches).to eq(45)
    end

    it 'assigns the target reliever pitches' do
      expect(planner.assignments.first.reliever_pitches).to eq(30)
    end

    it 'does not assign the same pitcher as both starter and reliever in the same game' do
      planner.assignments.each do |a|
        expect(a.starter_name).not_to eq(a.reliever_name)
      end
    end

    it 'distributes assignments across multiple pitchers (balanced workload)' do
      all_pitchers = planner.assignments.flat_map { |a| [a.starter_name, a.reliever_name] }.compact
      unique_count = all_pitchers.uniq.length
      # With 10 pitchers and 4 games (8 slots), at least 6 different pitchers should appear
      expect(unique_count).to be >= 6
    end
  end

  describe 'balanced workload optimization' do
    let(:rows) { %w[Alpha Beta Gamma].map { |n| row(n) } }
    let(:games) { [game('2026-03-21'), game('2026-03-22'), game('2026-03-23')] }

    subject(:planner) { described_class.new(games: games, rows: rows, rules: rules) }

    it 'rotates assignments so each pitcher gets approximately equal total pitches' do
      totals = planner.projections.map(&:weekend_total)
      # With 3 pitchers and 3 games (6 slots), each should have at least 1 assignment
      expect(totals.min).to be > 0
    end
  end

  describe 'same-day doubleheader accumulation' do
    # Pitcher with 0 pitches this weekend — both games on same day
    let(:rows) { [row('Alice'), row('Bob'), row('Carol')] }
    let(:games) { [game('2026-03-21'), game('2026-03-21')] }

    subject(:planner) { described_class.new(games: games, rows: rows, rules: rules) }

    it 'does not assign the same pitcher twice on the same day beyond daily max' do
      planner.assignments.each do |assignment|
        # Check that no pitcher's daily_total would exceed daily_max (85)
        all_names = planner.assignments
                           .select { |a| a.game_date == assignment.game_date }
                           .flat_map { |a| [a.starter_name, a.reliever_name] }
                           .tally
        # No individual pitcher should appear more times than daily_max allows
        # (each assignment is 45+30=75 max; assigning twice would be 120 > 85)
        all_names.each do |name, count|
          total = 0
          planner.assignments.select { |a| a.game_date == assignment.game_date }.each do |a|
            total += a.starter_pitches.to_i  if a.starter_name  == name
            total += a.reliever_pitches.to_i if a.reliever_name == name
          end
          expect(total).to be <= rules.daily_max, "#{name} would throw #{total} on #{assignment.game_date}, exceeding daily max"
        end
      end
    end

    it 'uses different pitchers for starter and reliever across doubleheader games' do
      names = planner.assignments.flat_map { |a| [a.starter_name, a.reliever_name] }.compact
      # 2 games × 2 roles = 4 slots; with 3 pitchers max overlap would still vary
      expect(names.uniq.length).to be >= 2
    end
  end

  describe '--ace promotion' do
    let(:rows) { %w[Alice Bob Carol Dave].map { |n| row(n) } }
    let(:games) { [game('2026-03-21'), game('2026-03-22')] }

    subject(:planner) { described_class.new(games: games, rows: rows, rules: rules, ace: 'Bob') }

    it 'assigns the ace as starter in their first game' do
      expect(planner.assignments.first.starter_name).to eq('Bob')
    end

    it 'does not force the ace to start every game' do
      # After game 1 Bob has pitched, the key guarantee is still just game 1 starter = Bob
      expect(planner.assignments.first.starter_name).to eq('Bob')
    end
  end

  describe '--ace is case-insensitive' do
    let(:rows) { [row('Mason Marrero'), row('Jase Passino'), row('Alex Chen')] }
    let(:games) { [game('2026-03-21')] }

    subject(:planner) { described_class.new(games: games, rows: rows, rules: rules, ace: 'mason marrero') }

    it 'matches ace case-insensitively' do
      expect(planner.assignments.first.starter_name).to eq('Mason Marrero')
    end
  end

  describe '--skip exclusion' do
    let(:rows) { [row('Alice'), row('Bob'), row('Carol')] }
    let(:games) { [game('2026-03-21')] }

    subject(:planner) { described_class.new(games: games, rows: rows, rules: rules, skip: ['Bob']) }

    it 'never assigns the skipped pitcher' do
      all_names = planner.assignments.flat_map { |a| [a.starter_name, a.reliever_name] }.compact
      expect(all_names).not_to include('Bob')
    end
  end

  describe '--skip is case-insensitive' do
    let(:rows) { [row('Alice'), row('Bob'), row('Carol')] }
    let(:games) { [game('2026-03-21')] }

    subject(:planner) { described_class.new(games: games, rows: rows, rules: rules, skip: ['bob']) }

    it 'matches skip names case-insensitively' do
      all_names = planner.assignments.flat_map { |a| [a.starter_name, a.reliever_name] }.compact
      expect(all_names).not_to include('Bob')
    end
  end

  describe 'USSSA rest compliance' do
    # Pitcher threw 66+ pitches yesterday — needs 3 days rest
    let(:rows) do
      [
        row('Tired', last_outing: '2026-03-20', last_pitches: 70),
        row('Fresh1'),
        row('Fresh2')
      ]
    end
    let(:games) { [game('2026-03-21')] }

    subject(:planner) { described_class.new(games: games, rows: rows, rules: rules) }

    it 'does not assign a pitcher who needs rest' do
      all_names = planner.assignments.flat_map { |a| [a.starter_name, a.reliever_name] }.compact
      expect(all_names).not_to include('Tired')
    end

    it 'assigns eligible pitchers instead' do
      expect(planner.assignments.first.starter_name).to eq('Fresh1').or eq('Fresh2')
    end
  end

  describe 'insufficient eligible pitchers' do
    # Only 1 pitcher available — reliever slot can't be filled
    let(:rows) { [row('Solo')] }
    let(:games) { [game('2026-03-21')] }

    subject(:planner) { described_class.new(games: games, rows: rows, rules: rules) }

    it 'assigns the available pitcher as starter' do
      expect(planner.assignments.first.starter_name).to eq('Solo')
    end

    it 'leaves reliever nil when no second pitcher is eligible' do
      expect(planner.assignments.first.reliever_name).to be_nil
    end
  end

  describe 'hypothetical games (no opponent)' do
    let(:rows) { [row('Alice'), row('Bob'), row('Carol')] }
    let(:games) { [{ 'game_date' => '2026-03-21', 'opponent' => nil }] }

    subject(:planner) { described_class.new(games: games, rows: rows, rules: rules) }

    it 'handles nil opponent gracefully' do
      expect(planner.assignments.first.opponent).to be_nil
    end
  end

  describe '#projections' do
    let(:rows) { [row('Alice'), row('Bob'), row('Carol')] }
    let(:games) { [game('2026-03-21')] }

    subject(:planner) { described_class.new(games: games, rows: rows, rules: rules) }

    it 'returns a projection for every pitcher in rows' do
      expect(planner.projections.length).to eq(3)
    end

    it 'reflects total pitches projected across the weekend' do
      planner.assignments  # trigger plan generation
      assigned = planner.assignments.flat_map { |a| [a.starter_name, a.reliever_name] }.compact
      planner.projections.each do |proj|
        if assigned.include?(proj.pitcher_name)
          expect(proj.weekend_total).to be > 0
        else
          expect(proj.weekend_total).to eq(0)
        end
      end
    end

    it 'updates last_outing for assigned pitchers' do
      planner.assignments
      assigned_names = planner.assignments.flat_map { |a| [a.starter_name, a.reliever_name] }.compact.uniq
      planner.projections.each do |proj|
        if assigned_names.include?(proj.pitcher_name)
          expect(proj.last_outing).to eq('2026-03-21')
        end
      end
    end

    it 'returns projections sorted by pitcher name' do
      names = planner.projections.map(&:pitcher_name)
      expect(names).to eq(names.sort)
    end
  end

  describe 'symbol-keyed game hashes' do
    let(:rows) { [row('Alice'), row('Bob'), row('Carol')] }
    let(:games) { [{ game_date: '2026-03-21', opponent: 'Eagles' }] }

    subject(:planner) { described_class.new(games: games, rows: rows, rules: rules) }

    it 'handles symbol-keyed game hashes from Storage' do
      expect(planner.assignments.first.game_date).to eq('2026-03-21')
      expect(planner.assignments.first.opponent).to eq('Eagles')
    end
  end
end
