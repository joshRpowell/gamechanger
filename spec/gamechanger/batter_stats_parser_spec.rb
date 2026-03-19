# frozen_string_literal: true

require 'spec_helper'

RSpec.describe Gamechanger::BatterStatsParser do
  let(:response) do
    {
      'wGP47FexatoQ' => {
        'players' => [
          { 'id' => 'player-1', 'first_name' => 'Mason',  'last_name' => 'Marrero',  'number' => '7' },
          { 'id' => 'player-2', 'first_name' => 'Jase',   'last_name' => 'Passino',  'number' => '12' },
          { 'id' => 'player-3', 'first_name' => 'Alex',   'last_name' => 'Chen',     'number' => '22' }
        ],
        'groups' => [
          {
            'category' => 'lineup',
            'stats' => [
              { 'player_id' => 'player-1', 'stats' => { 'AB' => 3, 'H' => 2, 'BB' => 1, 'K' => 0 } },
              { 'player_id' => 'player-2', 'stats' => { 'AB' => 4, 'H' => 1, 'BB' => 0, 'K' => 2 } },
              { 'player_id' => 'player-3', 'stats' => { 'AB' => 3, 'H' => 0, 'BB' => 0, 'K' => 1 } }
            ]
          }
        ]
      }
    }
  end

  subject(:parser) { described_class.new(response, team_slug: 'wGP47FexatoQ') }

  describe '#batter_stats' do
    it 'returns one entry per batter in the lineup group' do
      expect(parser.batter_stats.length).to eq(3)
    end

    it 'extracts batter name from players array' do
      names = parser.batter_stats.map { |s| s[:batter_name] }
      expect(names).to contain_exactly('Mason Marrero', 'Jase Passino', 'Alex Chen')
    end

    it 'extracts at_bats correctly' do
      mason = parser.batter_stats.find { |s| s[:batter_name] == 'Mason Marrero' }
      expect(mason[:at_bats]).to eq(3)
    end

    it 'extracts hits correctly' do
      mason = parser.batter_stats.find { |s| s[:batter_name] == 'Mason Marrero' }
      expect(mason[:hits]).to eq(2)
    end

    it 'extracts walks correctly' do
      mason = parser.batter_stats.find { |s| s[:batter_name] == 'Mason Marrero' }
      expect(mason[:walks]).to eq(1)
    end

    it 'extracts strikeouts correctly' do
      jase = parser.batter_stats.find { |s| s[:batter_name] == 'Jase Passino' }
      expect(jase[:strikeouts]).to eq(2)
    end

    it 'skips entries where player_id is not in the players array' do
      response['wGP47FexatoQ']['groups'].first['stats'] << { 'player_id' => 'unknown-id', 'stats' => { 'AB' => 2 } }
      expect(parser.batter_stats.length).to eq(3)
    end
  end

  describe 'when lineup group is absent' do
    before { response['wGP47FexatoQ']['groups'] = [] }

    it 'returns empty array' do
      expect(parser.batter_stats).to be_empty
    end
  end

  describe 'when lineup stats array is empty (unfinalized game)' do
    before { response['wGP47FexatoQ']['groups'].first['stats'] = [] }

    it 'returns empty array' do
      expect(parser.batter_stats).to be_empty
    end
  end

  describe 'when stats hash is nil for a player' do
    before do
      response['wGP47FexatoQ']['groups'].first['stats'].first['stats'] = nil
    end

    it 'returns zero values instead of crashing' do
      mason = parser.batter_stats.find { |s| s[:batter_name] == 'Mason Marrero' }
      expect(mason[:at_bats]).to eq(0)
      expect(mason[:hits]).to eq(0)
    end
  end

  describe 'error handling' do
    it 'raises APIShapeError when team slug is not in response' do
      expect {
        described_class.new(response, team_slug: 'wrong-slug')
      }.to raise_error(Gamechanger::APIShapeError, /wrong-slug/)
    end
  end
end
