# frozen_string_literal: true

require 'spec_helper'

RSpec.describe Gamechanger::BoxscoreParser do
  # Real response shape from DevTools capture (2026-03-15), extended with
  # the 2026-05-21 probe findings (BF/WP/HBP in extra[], full per-pitcher stats).
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
              },
              { 'stat_name' => 'BF', 'stats' => [
                  { 'player_id' => 'player-1', 'value' => 18 },
                  { 'player_id' => 'player-2', 'value' => 6 }
                ]
              },
              # WP and HBP are sparse — only Asher has them this game
              { 'stat_name' => 'WP', 'stats' => [
                  { 'player_id' => 'player-1', 'value' => 2 }
                ]
              },
              { 'stat_name' => 'HBP', 'stats' => [
                  { 'player_id' => 'player-1', 'value' => 1 }
                ]
              }
            ],
            'stats' => [
              { 'player_id' => 'player-1',
                'stats' => { 'IP' => 4.0, 'H' => 5, 'R' => 3, 'ER' => 2, 'BB' => 4, 'SO' => 6 } },
              { 'player_id' => 'player-2',
                'stats' => { 'IP' => 1.0, 'H' => 5, 'R' => 4, 'ER' => 4, 'BB' => 0, 'SO' => 1 } }
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

    it 'extracts batters faced from BF extra stat' do
      asher = parser.pitcher_stats.find { |s| s[:pitcher_name] == 'Asher Lima' }
      clayton = parser.pitcher_stats.find { |s| s[:pitcher_name] == 'Clayton Meyerson' }
      expect(asher[:batters_faced]).to eq(18)
      expect(clayton[:batters_faced]).to eq(6)
    end

    it 'extracts hits/runs/earned_runs/walks/strikeouts from per-pitcher stats' do
      asher = parser.pitcher_stats.find { |s| s[:pitcher_name] == 'Asher Lima' }
      expect(asher).to include(
        hits_allowed: 5,
        runs_allowed: 3,
        earned_runs: 2,
        walks_issued: 4,
        strikeouts_recorded: 6
      )
    end

    it 'extracts WP and HBP when present in extra[]' do
      asher = parser.pitcher_stats.find { |s| s[:pitcher_name] == 'Asher Lima' }
      expect(asher[:wild_pitches]).to eq(2)
      expect(asher[:hbp_allowed]).to eq(1)
    end

    it 'defaults WP and HBP to 0 for pitchers without entries (sparse event)' do
      clayton = parser.pitcher_stats.find { |s| s[:pitcher_name] == 'Clayton Meyerson' }
      expect(clayton[:wild_pitches]).to eq(0)
      expect(clayton[:hbp_allowed]).to eq(0)
    end

    it 'defaults WP and HBP to 0 when the extra entries are entirely absent' do
      pitching = response['wGP47FexatoQ']['groups'].find { |g| g['category'] == 'pitching' }
      pitching['extra'].reject! { |e| %w[WP HBP].include?(e['stat_name']) }
      parser.pitcher_stats.each do |s|
        expect(s[:wild_pitches]).to eq(0)
        expect(s[:hbp_allowed]).to eq(0)
      end
    end

    it 'silently ignores extra[] entries for player_ids not in the roster' do
      pitching = response['wGP47FexatoQ']['groups'].find { |g| g['category'] == 'pitching' }
      pitching['extra'].find { |e| e['stat_name'] == 'WP' }['stats'] <<
        { 'player_id' => 'ghost-player', 'value' => 99 }
      # No row for ghost-player (not in #P), so it's never emitted.
      expect(parser.pitcher_stats.map { |s| s[:pitcher_name] }).not_to include('ghost-player')
    end

    it 'defaults per-pitcher stats to 0 when keys are missing from the stats hash' do
      pitching = response['wGP47FexatoQ']['groups'].find { |g| g['category'] == 'pitching' }
      pitching['stats'].find { |r| r['player_id'] == 'player-2' }['stats'] = { 'IP' => 1.0 }
      clayton = parser.pitcher_stats.find { |s| s[:pitcher_name] == 'Clayton Meyerson' }
      expect(clayton).to include(
        hits_allowed: 0,
        runs_allowed: 0,
        earned_runs: 0,
        walks_issued: 0,
        strikeouts_recorded: 0
      )
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
