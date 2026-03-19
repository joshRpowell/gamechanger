# frozen_string_literal: true

require 'spec_helper'

RSpec.describe Gamechanger::LineupOptimizer do
  def row(name, seven_day_ab: 0, seven_day_hits: 0, seven_day_walks: 0,
          season_ab: 0, season_hits: 0, season_walks: 0)
    {
      'batter_name'     => name,
      'seven_day_ab'    => seven_day_ab,
      'seven_day_hits'  => seven_day_hits,
      'seven_day_walks' => seven_day_walks,
      'season_ab'       => season_ab,
      'season_hits'     => season_hits,
      'season_walks'    => season_walks
    }
  end

  describe '#ranked' do
    context 'with players who have 7-day at-bats' do
      let(:rows) do
        [
          row('Alice', seven_day_ab: 4, seven_day_hits: 3, seven_day_walks: 1),  # OBP = 4/5 = .800
          row('Bob',   seven_day_ab: 4, seven_day_hits: 1, seven_day_walks: 1),  # OBP = 2/5 = .400
          row('Carol', seven_day_ab: 4, seven_day_hits: 2, seven_day_walks: 0)   # OBP = 2/4 = .500
        ]
      end

      subject(:optimizer) { described_class.new(rows) }

      it 'ranks players by 7-day OBP descending' do
        names = optimizer.ranked.map(&:batter_name)
        expect(names).to eq(['Alice', 'Carol', 'Bob'])
      end

      it 'assigns positions starting at 1' do
        positions = optimizer.ranked.map(&:position)
        expect(positions).to eq([1, 2, 3])
      end

      it 'returns no unranked players' do
        expect(optimizer.unranked).to be_empty
      end

      it 'computes seven_day_obp correctly' do
        alice = optimizer.ranked.find { |s| s.batter_name == 'Alice' }
        expect(alice.seven_day_obp).to be_within(0.001).of(0.800)
      end
    end

    context 'with no players having 7-day at-bats' do
      let(:rows) { [row('Alice', season_ab: 10, season_hits: 3)] }

      subject(:optimizer) { described_class.new(rows) }

      it 'returns empty ranked list' do
        expect(optimizer.ranked).to be_empty
      end

      it 'returns all players as unranked' do
        expect(optimizer.unranked.length).to eq(1)
      end
    end
  end

  describe '#unranked' do
    let(:rows) do
      [
        row('Alice', seven_day_ab: 3, seven_day_hits: 1, season_ab: 10, season_hits: 3),
        row('Bob',   season_ab: 8, season_hits: 2)   # no 7-day data
      ]
    end

    subject(:optimizer) { described_class.new(rows) }

    it 'includes only players with no 7-day at-bats' do
      expect(optimizer.unranked.map(&:batter_name)).to contain_exactly('Bob')
    end

    it 'assigns nil position to unranked players' do
      expect(optimizer.unranked.first.position).to be_nil
    end

    it 'computes season_obp for unranked players' do
      bob = optimizer.unranked.first
      # OBP = (2 + 0) / (8 + 0) = .250
      expect(bob.season_obp).to be_within(0.001).of(0.250)
    end
  end

  describe 'trend calculation' do
    subject(:optimizer) { described_class.new(rows) }

    context 'when 7-day OBP exceeds season OBP by more than 5pp' do
      let(:rows) { [row('Alice', seven_day_ab: 4, seven_day_hits: 3, season_ab: 20, season_hits: 8)] }
      # 7day: 3/4=.750, season: 8/20=.400 → diff=.350 > .05

      it 'returns ↗' do
        expect(optimizer.ranked.first.trend).to eq('↗')
      end
    end

    context 'when 7-day OBP is below season OBP by more than 5pp' do
      let(:rows) { [row('Bob', seven_day_ab: 4, seven_day_hits: 0, season_ab: 20, season_hits: 10)] }
      # 7day: 0/4=.000, season: 10/20=.500 → diff=-.500 < -.05

      it 'returns ↘' do
        expect(optimizer.ranked.first.trend).to eq('↘')
      end
    end

    context 'when 7-day OBP is within 5pp of season OBP' do
      let(:rows) { [row('Carol', seven_day_ab: 4, seven_day_hits: 2, season_ab: 20, season_hits: 10)] }
      # 7day: 2/4=.500, season: 10/20=.500 → diff=0.0

      it 'returns →' do
        expect(optimizer.ranked.first.trend).to eq('→')
      end
    end

    context 'when player has no season data (zero denominator)' do
      let(:rows) { [row('Dave', seven_day_ab: 4, seven_day_hits: 2)] }
      # season_obp = 0.0, 7day = .500, diff=.500 > .05

      it 'does not raise and returns ↗' do
        expect { optimizer.ranked.first.trend }.not_to raise_error
        expect(optimizer.ranked.first.trend).to eq('↗')
      end
    end
  end

  describe 'with empty rows' do
    subject(:optimizer) { described_class.new([]) }

    it 'returns empty ranked' do
      expect(optimizer.ranked).to be_empty
    end

    it 'returns empty unranked' do
      expect(optimizer.unranked).to be_empty
    end
  end
end
