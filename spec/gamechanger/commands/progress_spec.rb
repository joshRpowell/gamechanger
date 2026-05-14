# frozen_string_literal: true

require 'spec_helper'

RSpec.describe Gamechanger::Commands::Progress do
  let(:shell)   { instance_spy(Thor::Shell::Color) }
  let(:options) { { format: 'table' } }
  let(:command) { described_class.new(options: options, shell: shell) }

  let(:storage) { instance_double(Gamechanger::Storage, close: nil) }

  before do
    allow(Gamechanger::Storage).to receive(:new).and_return(storage)
    allow(Gamechanger::Config).to receive(:new).and_return(
      instance_double(Gamechanger::Config, season: 2026)
    )
  end

  it 'exits 1 with yellow hint when development summary is empty' do
    allow(storage).to receive(:all_player_development_summary).and_return([])

    expect { command.call }.to raise_error(SystemExit) { |e| expect(e.status).to eq(1) }
    expect(shell).to have_received(:say).with(/No player data cached.*gamechanger refresh/, :yellow)
  end

  describe 'with --player' do
    let(:command) { described_class.new(options: { player: 'Bob' }, shell: shell) }

    it 'exits 1 when no player matches' do
      allow(storage).to receive(:all_player_development_summary).and_return([])

      expect { command.call }.to raise_error(SystemExit) { |e| expect(e.status).to eq(1) }
      expect(shell).to have_received(:say).with(/No data found for 'Bob'/, :yellow)
    end

    it 'finds player by case-insensitive prefix match and pulls batting arc' do
      rows = [
        { 'player_name' => 'Bob Jones', 'bat_avg' => 0.300 },
        { 'player_name' => 'Carol White', 'bat_avg' => 0.250 }
      ]
      allow(storage).to receive(:all_player_development_summary).and_return(rows)
      allow(storage).to receive(:player_batting_arc).with(player_name: 'Bob Jones').and_return([])

      expect { command.call }.not_to raise_error
      expect(storage).to have_received(:player_batting_arc).with(player_name: 'Bob Jones')
    end
  end
end
