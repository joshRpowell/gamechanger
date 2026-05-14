# frozen_string_literal: true

require 'spec_helper'

RSpec.describe Gamechanger::Commands::Pitches do
  let(:shell)   { instance_spy(Thor::Shell::Color) }
  let(:options) { { format: 'table' } }
  let(:command) { described_class.new(options: options, shell: shell) }

  let(:config)  { instance_double(Gamechanger::Config, configured?: true, season: 2026) }
  let(:storage) { instance_double(Gamechanger::Storage, close: nil) }
  let(:syncer)  { instance_double(Gamechanger::Syncer, run: Gamechanger::SyncResult.new(0, 0, 0)) }

  before do
    allow(Gamechanger::Config).to receive(:new).and_return(config)
    allow(Gamechanger::Storage).to receive(:new).and_return(storage)
    allow(Gamechanger::Syncer).to receive(:new).and_return(syncer)
  end

  it 'exits 4 when not configured' do
    allow(Gamechanger::Config).to receive(:new).and_return(
      instance_double(Gamechanger::Config, configured?: false)
    )

    expect { command.call }.to raise_error(SystemExit) { |e| expect(e.status).to eq(4) }
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
    it 'rejects malformed date strings to stdout and exits 1' do
      cmd = described_class.new(options: { game: 'bad', game_number: 1 }, shell: shell)

      expect { cmd.call }.to raise_error(SystemExit) { |e| expect(e.status).to eq(1) }
      expect(shell).to have_received(:say).with("Invalid date format 'bad' — expected YYYY-MM-DD", :red)
    end

    it 'exits 1 when no game found for date' do
      cmd = described_class.new(options: { game: '2026-03-21', game_number: 1 }, shell: shell)
      allow(storage).to receive(:game_by_date).with('2026-03-21').and_return([])

      expect { cmd.call }.to raise_error(SystemExit) { |e| expect(e.status).to eq(1) }
      expect(shell).to have_received(:say).with('No game found for 2026-03-21.', :yellow)
    end
  end
end
