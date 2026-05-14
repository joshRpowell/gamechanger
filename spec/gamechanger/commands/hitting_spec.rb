# frozen_string_literal: true

require 'spec_helper'

RSpec.describe Gamechanger::Commands::Hitting do
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

  describe '#call without --player (season summary)' do
    it 'renders the season batting summary when rows exist' do
      rows = [{ 'batter_name' => 'Bob', 'avg' => 0.300, 'obp' => 0.400 }]
      allow(storage).to receive(:season_batting_summary).and_return(rows)

      expect { command.call }.not_to raise_error
    end

    it 'exits 1 with yellow hint when summary is empty' do
      allow(storage).to receive(:season_batting_summary).and_return([])

      expect { command.call }.to raise_error(SystemExit) { |e| expect(e.status).to eq(1) }
      expect(shell).to have_received(:say).with(/No batting data in cache.*gamechanger refresh/, :yellow)
    end
  end

  describe '#call with --player (batter breakdown)' do
    let(:command) { described_class.new(options: { player: 'Bob' }, shell: shell) }

    it 'renders game-by-game breakdown for a unique match' do
      games = [{ 'batter_name' => 'Bob Jones', 'game_date' => '2026-03-21', 'at_bats' => 3, 'hits' => 2 }]
      allow(storage).to receive(:batter_games).with('Bob').and_return(games)

      expect { command.call }.not_to raise_error
    end

    it 'exits 1 with yellow message when no batter matches' do
      allow(storage).to receive(:batter_games).with('Bob').and_return([])

      expect { command.call }.to raise_error(SystemExit) { |e| expect(e.status).to eq(1) }
      expect(shell).to have_received(:say).with("No batter matching 'Bob' found this season.", :yellow)
    end

    it 'exits 1 with disambiguation list when multiple names match' do
      # When result is a list of strings, it represents ambiguous matches.
      allow(storage).to receive(:batter_games).with('Bob').and_return(['Bob Jones', 'Bob Smith'])

      expect { command.call }.to raise_error(SystemExit) { |e| expect(e.status).to eq(1) }
      expect(shell).to have_received(:say).with('Ambiguous name — did you mean:', :yellow)
      expect(shell).to have_received(:say).with('  Bob Jones')
      expect(shell).to have_received(:say).with('  Bob Smith')
    end
  end
end
