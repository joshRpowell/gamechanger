# frozen_string_literal: true

require 'spec_helper'

RSpec.describe Gamechanger::BoxscoreParser do
  # Real response shape from DevTools capture (2026-03-15)
  let(:response) do
    {
      'wGP47FexatoQ' => {
        'players' => [
          { 'id' => 'player-1', 'first_name' => 'Asher',   'last_name' => 'Lima',     'number' => '3' },
          { 'id' => 'player-2', 'first_name' => 'Clayton', 'last_name' => 'Meyerson', 'number' => '44' }
        ],
        'groups' => [
          {
            'category' => 'lineup',
            'team_stats' => { 'AB' => 19, 'R' => 9 },
            'stats' => []
          },
          {
            'category' => 'pitching',
            'team_stats' => { 'IP' => 5 },
            'extra' => [
              { 'stat_name' => '#P', 'stats' => [
                  { 'player_id' => 'player-1', 'value' => 59 },
                  { 'player_id' => 'player-2', 'value' => 24 }
                ]
              },
              { 'stat_name' => 'TS', 'stats' => [
                  { 'player_id' => 'player-1', 'value' => 30 },
                  { 'player_id' => 'player-2', 'value' => 15 }
                ]
              }
            ],
            'stats' => [
              { 'player_id' => 'player-1', 'stats' => { 'IP' => 4.0, 'H' => 5, 'BB' => 4 } },
              { 'player_id' => 'player-2', 'stats' => { 'IP' => 1.0, 'H' => 5, 'BB' => 0 } }
            ]
          }
        ]
      }
    }
  end

  subject(:parser) { described_class.new(response, team_slug: 'wGP47FexatoQ') }

  describe '#pitcher_stats' do
    it 'returns one entry per pitcher' do
      expect(parser.pitcher_stats.length).to eq(2)
    end

    it 'extracts pitcher name from players array' do
      names = parser.pitcher_stats.map { |s| s[:pitcher_name] }
      expect(names).to contain_exactly('Asher Lima', 'Clayton Meyerson')
    end

    it 'extracts pitch count from #P extra stat' do
      asher = parser.pitcher_stats.find { |s| s[:pitcher_name] == 'Asher Lima' }
      expect(asher[:pitches_thrown]).to eq(59)
    end

    it 'extracts innings pitched from stats array' do
      asher = parser.pitcher_stats.find { |s| s[:pitcher_name] == 'Asher Lima' }
      expect(asher[:innings_pitched]).to eq(4.0)
    end

    it 'returns stats ordered by pitch count from the #P extra array' do
      counts = parser.pitcher_stats.map { |s| s[:pitches_thrown] }
      expect(counts).to eq([59, 24])
    end
  end

  describe 'error handling' do
    it 'raises APIShapeError when team slug is not in response' do
      expect {
        described_class.new(response, team_slug: 'wrong-slug')
      }.to raise_error(Gamechanger::APIShapeError, /wrong-slug/)
    end

    it 'returns empty array when pitching group is absent' do
      response['wGP47FexatoQ']['groups'] = []
      expect(parser.pitcher_stats).to be_empty
    end

    it 'returns empty array when #P extra stat is absent' do
      pitching = response['wGP47FexatoQ']['groups'].find { |g| g['category'] == 'pitching' }
      pitching['extra'] = []
      expect(parser.pitcher_stats).to be_empty
    end
  end
end
