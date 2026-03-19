# frozen_string_literal: true

require 'spec_helper'

RSpec.describe Gamechanger::PitchRules do
  subject(:rules) { described_class.new }

  describe '#rest_days_required' do
    it('returns 0 for 0 pitches')  { expect(rules.rest_days_required(0)).to eq(0) }
    it('returns 0 for 35 pitches') { expect(rules.rest_days_required(35)).to eq(0) }
    it('returns 1 for 36 pitches') { expect(rules.rest_days_required(36)).to eq(1) }
    it('returns 1 for 50 pitches') { expect(rules.rest_days_required(50)).to eq(1) }
    it('returns 2 for 51 pitches') { expect(rules.rest_days_required(51)).to eq(2) }
    it('returns 2 for 65 pitches') { expect(rules.rest_days_required(65)).to eq(2) }
    it('returns 3 for 66 pitches') { expect(rules.rest_days_required(66)).to eq(3) }
    it('returns 3 for 96 pitches') { expect(rules.rest_days_required(96)).to eq(3) }
  end

  describe '#available_date' do
    it 'is last_outing + rest_days + 1 (off-by-one)' do
      # 66 pitches → 3 days rest → available on day 4, i.e. +4 from outing date
      expect(rules.available_date('2026-03-15', 66)).to eq(Date.new(2026, 3, 19))
    end

    it 'is next calendar day for 0-35 pitches (rest=0)' do
      expect(rules.available_date('2026-03-15', 20)).to eq(Date.new(2026, 3, 16))
    end

    it 'handles Date object for last_outing_date' do
      expect(rules.available_date(Date.new(2026, 3, 15), 51)).to eq(Date.new(2026, 3, 18))
    end
  end

  describe '#available_on?' do
    it 'returns true when last_outing_date is nil' do
      expect(rules.available_on?(Date.today, nil, 0)).to be true
    end

    it 'returns true when target_date >= available_date' do
      # 50 pitches on 3/15 → available 3/17 → available on 3/17
      expect(rules.available_on?(Date.new(2026, 3, 17), '2026-03-15', 50)).to be true
    end

    it 'returns false when target_date < available_date' do
      # 66 pitches on 3/15 → available 3/19 → NOT available on 3/18
      expect(rules.available_on?(Date.new(2026, 3, 18), '2026-03-15', 66)).to be false
    end

    it 'returns true on the exact available date' do
      # 66 pitches on 3/15 → available 3/19
      expect(rules.available_on?(Date.new(2026, 3, 19), '2026-03-15', 66)).to be true
    end
  end

  describe '#pitches_remaining' do
    it('returns daily_max for 0 pitches')               { expect(rules.pitches_remaining(0)).to eq(85) }
    it('returns 35 for 50 pitches')                     { expect(rules.pitches_remaining(50)).to eq(35) }
    it('returns 0 for 85 pitches')                      { expect(rules.pitches_remaining(85)).to eq(0) }
    it('floors at 0 for pitches above max (96 pitches)') { expect(rules.pitches_remaining(96)).to eq(0) }
  end
end
