# frozen_string_literal: true

require 'spec_helper'

RSpec.describe Gamechanger::Sorting do
  let(:key_map) do
    {
      'name' => ->(r) { r['name'] },
      'ab'   => ->(r) { r['ab'].to_i },
      'avg'  => lambda do |r|
        ab = r['ab'].to_i
        ab.positive? ? r['hits'].to_f / ab : nil
      end
    }
  end

  let(:rows) do
    [
      { 'name' => 'Charlie', 'ab' => 10, 'hits' => 3 },
      { 'name' => 'Alice',   'ab' => 8,  'hits' => 4 },
      { 'name' => 'Bob',     'ab' => 0,  'hits' => 0 }
    ]
  end

  describe '.apply' do
    it 'returns rows unchanged when sort_key is nil' do
      expect(described_class.apply(rows, nil, key_map)).to eq(rows)
    end

    it 'returns rows unchanged when sort_key is empty string' do
      expect(described_class.apply(rows, '', key_map)).to eq(rows)
    end

    it 'sorts by a direct string column ascending' do
      result = described_class.apply(rows, 'name', key_map)
      expect(result.map { |r| r['name'] }).to eq(%w[Alice Bob Charlie])
    end

    it 'sorts by a direct numeric column ascending' do
      result = described_class.apply(rows, 'ab', key_map)
      expect(result.map { |r| r['ab'] }).to eq([0, 8, 10])
    end

    it 'reverses order when desc: true' do
      result = described_class.apply(rows, 'ab', key_map, desc: true)
      expect(result.map { |r| r['ab'] }).to eq([10, 8, 0])
    end

    it 'sorts by a computed column, with nil values last' do
      result = described_class.apply(rows, 'avg', key_map)
      # Charlie .300, Alice .500, Bob nil (no AB) → ascending: Charlie, Alice, Bob
      expect(result.map { |r| r['name'] }).to eq(%w[Charlie Alice Bob])
    end

    it 'keeps nil values last even when descending' do
      result = described_class.apply(rows, 'avg', key_map, desc: true)
      # Alice .500, Charlie .300, then Bob (no AB) last regardless of direction.
      expect(result.map { |r| r['name'] }).to eq(%w[Alice Charlie Bob])
    end

    it 'raises InvalidSortKey with available keys for unknown column' do
      expect { described_class.apply(rows, 'zzz', key_map) }
        .to raise_error(Gamechanger::Sorting::InvalidSortKey, /Unknown sort key 'zzz'.*ab, avg, name/)
    end

    it 'is case-insensitive on the sort key' do
      result = described_class.apply(rows, 'NAME', key_map)
      expect(result.map { |r| r['name'] }).to eq(%w[Alice Bob Charlie])
    end
  end
end
