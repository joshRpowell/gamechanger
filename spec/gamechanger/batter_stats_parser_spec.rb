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
              { 'player_id' => 'player-1', 'stats' => { 'AB' => 3, 'H' => 2, 'BB' => 1, 'SO' => 0 } },
              { 'player_id' => 'player-2', 'stats' => { 'AB' => 4, 'H' => 1, 'BB' => 0, 'SO' => 2 } },
              { 'player_id' => 'player-3', 'stats' => { 'AB' => 3, 'H' => 0, 'BB' => 0, 'SO' => 1 } }
            ],
            'extra' => [
              {
                'stat_name' => 'HBP',
                'stats' => [
                  { 'player_id' => 'player-1', 'value' => 1 },
                  { 'player_id' => 'player-3', 'value' => 2 }
                ]
              },
              {
                'stat_name' => '2B',
                'stats' => [
                  { 'player_id' => 'player-1', 'value' => 1 }
                ]
              },
              {
                'stat_name' => '3B',
                'stats' => [
                  { 'player_id' => 'player-2', 'value' => 1 }
                ]
              },
              {
                'stat_name' => 'HR',
                'stats' => [
                  { 'player_id' => 'player-1', 'value' => 1 }
                ]
              }
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

    it 'extracts strikeouts correctly from the SO key' do
      jase = parser.batter_stats.find { |s| s[:batter_name] == 'Jase Passino' }
      expect(jase[:strikeouts]).to eq(2)
    end

    it 'extracts hbp from the lineup extra[] array, joined by player_id' do
      mason = parser.batter_stats.find { |s| s[:batter_name] == 'Mason Marrero' }
      alex  = parser.batter_stats.find { |s| s[:batter_name] == 'Alex Chen' }
      jase  = parser.batter_stats.find { |s| s[:batter_name] == 'Jase Passino' }
      expect(mason[:hbp]).to eq(1)
      expect(alex[:hbp]).to eq(2)
      expect(jase[:hbp]).to eq(0) # no HBP entry for player-2
    end

    it 'defaults hbp to 0 when the extra[] array has no HBP entry' do
      response['wGP47FexatoQ']['groups'].first['extra'] = []
      expect(parser.batter_stats.map { |s| s[:hbp] }).to all(eq(0))
    end

    it 'defaults hbp to 0 when the extra[] array is absent entirely' do
      response['wGP47FexatoQ']['groups'].first.delete('extra')
      expect(parser.batter_stats.map { |s| s[:hbp] }).to all(eq(0))
    end

    it 'silently ignores HBP entries for unknown player_ids' do
      response['wGP47FexatoQ']['groups'].first['extra'].first['stats'] << {
        'player_id' => 'unknown-id', 'value' => 5
      }
      expect(parser.batter_stats.length).to eq(3)
      expect(parser.batter_stats.map { |s| s[:hbp] }).to contain_exactly(1, 0, 2)
    end

    it 'defaults strikeouts to 0 when the SO key is absent from stats hash' do
      response['wGP47FexatoQ']['groups'].first['stats'].first['stats'].delete('SO')
      mason = parser.batter_stats.find { |s| s[:batter_name] == 'Mason Marrero' }
      expect(mason[:strikeouts]).to eq(0)
    end

    it 'skips entries where player_id is not in the players array' do
      response['wGP47FexatoQ']['groups'].first['stats'] << { 'player_id' => 'unknown-id', 'stats' => { 'AB' => 2 } }
      expect(parser.batter_stats.length).to eq(3)
    end

    it 'extracts 2B/3B/HR from extra[], joined by player_id' do
      mason = parser.batter_stats.find { |s| s[:batter_name] == 'Mason Marrero' }
      jase  = parser.batter_stats.find { |s| s[:batter_name] == 'Jase Passino' }
      alex  = parser.batter_stats.find { |s| s[:batter_name] == 'Alex Chen' }
      expect(mason[:doubles]).to eq(1)
      expect(mason[:triples]).to eq(0)
      expect(mason[:home_runs]).to eq(1)
      expect(jase[:doubles]).to eq(0)
      expect(jase[:triples]).to eq(1)
      expect(jase[:home_runs]).to eq(0)
      expect(alex[:doubles]).to eq(0)
      expect(alex[:triples]).to eq(0)
      expect(alex[:home_runs]).to eq(0)
    end

    it 'defaults 2B/3B/HR to 0 when their extra[] entries are absent' do
      response['wGP47FexatoQ']['groups'].first['extra'] = []
      stats = parser.batter_stats
      expect(stats.map { |s| s[:doubles] }).to all(eq(0))
      expect(stats.map { |s| s[:triples] }).to all(eq(0))
      expect(stats.map { |s| s[:home_runs] }).to all(eq(0))
    end

    it 'defaults 2B/3B/HR to 0 when extra[] is absent entirely' do
      response['wGP47FexatoQ']['groups'].first.delete('extra')
      stats = parser.batter_stats
      expect(stats.map { |s| s[:doubles] }).to all(eq(0))
      expect(stats.map { |s| s[:triples] }).to all(eq(0))
      expect(stats.map { |s| s[:home_runs] }).to all(eq(0))
    end

    it 'silently ignores 2B/3B/HR entries for unknown player_ids' do
      response['wGP47FexatoQ']['groups'].first['extra'].find { |e| e['stat_name'] == '2B' }['stats'] << {
        'player_id' => 'ghost-id', 'value' => 9
      }
      expect(parser.batter_stats.length).to eq(3)
      expect(parser.batter_stats.map { |s| s[:doubles] }).to contain_exactly(1, 0, 0)
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

  describe '#fielding_stints' do
    let(:response) do
      {
        'wGP47FexatoQ' => {
          'players' => [
            { 'id' => 'p1', 'first_name' => 'Mason',  'last_name' => 'Marrero', 'number' => '7' },
            { 'id' => 'p2', 'first_name' => 'Jase',   'last_name' => 'Passino', 'number' => '12' },
            { 'id' => 'p3', 'first_name' => 'Alex',   'last_name' => 'Chen',    'number' => '22' },
            { 'id' => 'p4', 'first_name' => 'Ben',    'last_name' => 'Doe',     'number' => '5' },
            { 'id' => 'p5', 'first_name' => 'Cal',    'last_name' => 'Roe',     'number' => '6' }
          ],
          'groups' => [
            {
              'category' => 'lineup',
              'stats' => [
                { 'player_id' => 'p1', 'player_text' => '(SS)',           'stats' => { 'AB' => 3 } },
                { 'player_id' => 'p2', 'player_text' => '(1B, 2B, 1B, P)', 'stats' => { 'AB' => 4 } },
                { 'player_id' => 'p3', 'player_text' => '( SS , P )',     'stats' => { 'AB' => 3 } },
                { 'player_id' => 'p4', 'player_text' => '',               'stats' => { 'AB' => 0 } },
                { 'player_id' => 'p5', 'player_text' => '(SS, ZZ, P)',    'stats' => { 'AB' => 2 } }
              ]
            }
          ]
        }
      }
    end

    subject(:parser) { described_class.new(response, team_slug: 'wGP47FexatoQ') }

    it 'parses a single-position player into one stint' do
      mason = parser.fielding_stints.find { |s| s[:player_id] == 'p1' }
      expect(mason[:positions]).to eq(['SS'])
      expect(mason[:player_name]).to eq('Mason Marrero')
    end

    it 'preserves stint order for multi-position players' do
      jase = parser.fielding_stints.find { |s| s[:player_id] == 'p2' }
      expect(jase[:positions]).to eq(['1B', '2B', '1B', 'P'])
    end

    it 'tolerates whitespace around tokens and parens' do
      alex = parser.fielding_stints.find { |s| s[:player_id] == 'p3' }
      expect(alex[:positions]).to eq(['SS', 'P'])
    end

    it 'omits players whose player_text is empty' do
      expect(parser.fielding_stints.map { |s| s[:player_id] }).not_to include('p4')
    end

    it 'logs and drops unknown position codes, keeping known ones' do
      expect { @result = parser.fielding_stints }.to output(/ignoring unknown position code "ZZ"/).to_stderr
      cal = @result.find { |s| s[:player_id] == 'p5' }
      expect(cal[:positions]).to eq(['SS', 'P'])
    end

    it 'omits players whose tokens are all unknown' do
      response['wGP47FexatoQ']['groups'].first['stats'] << {
        'player_id' => 'p6', 'player_text' => '(ZZ, YY)', 'stats' => { 'AB' => 0 }
      }
      response['wGP47FexatoQ']['players'] << { 'id' => 'p6', 'first_name' => 'No', 'last_name' => 'One', 'number' => '99' }

      expect { @result = parser.fielding_stints }.to output(/unknown position code/).to_stderr
      expect(@result.map { |s| s[:player_id] }).not_to include('p6')
    end

    it 'returns empty array when lineup group is absent' do
      response['wGP47FexatoQ']['groups'] = []
      expect(parser.fielding_stints).to eq([])
    end

    it 'returns empty array when lineup stats are empty' do
      response['wGP47FexatoQ']['groups'].first['stats'] = []
      expect(parser.fielding_stints).to eq([])
    end

    it 'skips rows whose player_id is not in the players array' do
      response['wGP47FexatoQ']['groups'].first['stats'] << {
        'player_id' => 'unknown', 'player_text' => '(SS)', 'stats' => {}
      }
      ids = parser.fielding_stints.map { |s| s[:player_id] }
      expect(ids).not_to include('unknown')
    end

    it 'recognizes DH and EH codes' do
      response['wGP47FexatoQ']['groups'].first['stats'] << {
        'player_id' => 'p4', 'player_text' => '(DH, EH)', 'stats' => {}
      }
      # p4 already exists in players; just override player_text via the new row
      result = parser.fielding_stints.find { |s| s[:player_id] == 'p4' }
      expect(result[:positions]).to eq(['DH', 'EH'])
    end
  end
end
