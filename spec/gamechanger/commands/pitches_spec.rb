# frozen_string_literal: true

require 'spec_helper'

RSpec.describe Gamechanger::Commands::Pitches do
  let(:shell)   { instance_spy(Thor::Shell::Color) }
  let(:options) { { format: 'table' } }
  let(:command) { described_class.new(options: options, shell: shell) }

  let(:config) do
    instance_double(Gamechanger::Config, configured?: true, season: 2026)
  end
  let(:storage) { instance_double(Gamechanger::Storage, close: nil) }
  let(:syncer)  { instance_double(Gamechanger::Syncer, run: Gamechanger::SyncResult.new(0, 0, 0)) }

  before do
    allow(Gamechanger::Config).to receive(:new).and_return(config)
    allow(Gamechanger::Storage).to receive(:new).and_return(storage)
    allow(Gamechanger::Syncer).to receive(:new).and_return(syncer)
  end

  describe '#call without filters (season summary)' do
    it 'syncs with the configured force flag and renders the season summary' do
      allow(storage).to receive(:season_summary).and_return([])

      expect { command.call }.not_to raise_error
      expect(syncer).to have_received(:run).with(force: nil)
    end

    it 'passes --refresh through to Syncer as force: true' do
      command = described_class.new(options: { refresh: true }, shell: shell)
      allow(storage).to receive(:season_summary).and_return([])

      command.call
      expect(syncer).to have_received(:run).with(force: true)
    end
  end

  describe '#call with --pitcher' do
    let(:command) { described_class.new(options: { pitcher: 'Alice' }, shell: shell) }

    it 'exits 1 when no matching pitcher' do
      allow(storage).to receive(:pitcher_games).with('Alice').and_return([])

      expect { command.call }.to raise_error(SystemExit) { |e| expect(e.status).to eq(1) }
      expect(shell).to have_received(:say).with("No pitcher matching 'Alice' found this season.", :yellow)
    end

    it 'exits 1 with disambiguation list when names are ambiguous' do
      allow(storage).to receive(:pitcher_games).with('Alice').and_return(['Alice Smith', 'Alice Brown'])

      expect { command.call }.to raise_error(SystemExit) { |e| expect(e.status).to eq(1) }
      expect(shell).to have_received(:say).with('Ambiguous name — did you mean:', :yellow)
    end
  end

  describe '#call with --game' do
    let(:command) { described_class.new(options: { game: '2026-03-21', game_number: 1 }, shell: shell) }

    it 'rejects malformed date strings' do
      command = described_class.new(options: { game: 'bad', game_number: 1 }, shell: shell)

      expect { command.call }.to raise_error(SystemExit) { |e| expect(e.status).to eq(1) }
      expect(shell).to have_received(:say).with("Invalid date format 'bad' — expected YYYY-MM-DD", :red)
    end

    it 'exits 1 when no game found for date' do
      allow(storage).to receive(:game_by_date).with('2026-03-21').and_return([])

      expect { command.call }.to raise_error(SystemExit) { |e| expect(e.status).to eq(1) }
      expect(shell).to have_received(:say).with('No game found for 2026-03-21.', :yellow)
    end
  end

  describe '#call when not configured' do
    it 'exits 4' do
      allow(Gamechanger::Config).to receive(:new).and_return(
        instance_double(Gamechanger::Config, configured?: false)
      )

      expect { command.call }.to raise_error(SystemExit) { |e| expect(e.status).to eq(4) }
    end
  end
end
