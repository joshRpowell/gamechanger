# frozen_string_literal: true

require 'spec_helper'

RSpec.describe Gamechanger::Commands::Plan do
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

  describe '#call with --games' do
    let(:command) { described_class.new(options: { games: '2026-03-21,2026-03-22' }, shell: shell) }

    it 'parses comma-separated dates and looks up pitcher availability' do
      allow(storage).to receive(:pitcher_availability_data).and_return([])

      expect { command.call }.to raise_error(SystemExit) { |e| expect(e.status).to eq(1) }
      expect(shell).to have_received(:say).with(/No pitcher data in cache/, :yellow)
    end

    it 'prints stdout error on malformed --games date and exits 1' do
      cmd = described_class.new(options: { games: 'bad-date' }, shell: shell)

      expect { cmd.call }.to raise_error(SystemExit) { |e| expect(e.status).to eq(1) }
      expect(shell).to have_received(:say).with(/Invalid date 'bad-date' in --games/, :red)
    end
  end

  describe '#call with --from' do
    let(:command) { described_class.new(options: { from: '2026-03-21', to: '2026-03-22' }, shell: shell) }

    it 'queries storage.scheduled_games_between with the parsed range' do
      allow(storage).to receive(:scheduled_games_between).and_return([])

      expect { command.call }.to raise_error(SystemExit) { |e| expect(e.status).to eq(1) }
      expect(storage).to have_received(:scheduled_games_between).with(
        from_date: Date.parse('2026-03-21'),
        to_date:   Date.parse('2026-03-22')
      )
    end

    it 'defaults --to to --from when --to is omitted' do
      cmd = described_class.new(options: { from: '2026-03-21' }, shell: shell)
      allow(storage).to receive(:scheduled_games_between).and_return([])

      expect { cmd.call }.to raise_error(SystemExit)
      expect(storage).to have_received(:scheduled_games_between).with(
        from_date: Date.parse('2026-03-21'),
        to_date:   Date.parse('2026-03-21')
      )
    end

    it 'prints stdout error on malformed --from date and exits 1' do
      cmd = described_class.new(options: { from: 'bad' }, shell: shell)

      expect { cmd.call }.to raise_error(SystemExit) { |e| expect(e.status).to eq(1) }
      expect(shell).to have_received(:say).with(/Invalid --from date 'bad'/, :red)
    end
  end

  describe '#call default (no options)' do
    it 'falls back to next_scheduled_game' do
      game = { 'game_date' => '2026-03-21', 'opponent' => 'Eagles' }
      allow(storage).to receive(:next_scheduled_game).and_return(game)
      allow(storage).to receive(:pitcher_availability_data).and_return([])

      expect { command.call }.to raise_error(SystemExit) { |e| expect(e.status).to eq(1) }
      expect(storage).to have_received(:next_scheduled_game)
    end

    it 'exits 1 when no upcoming games' do
      allow(storage).to receive(:next_scheduled_game).and_return(nil)

      expect { command.call }.to raise_error(SystemExit) { |e| expect(e.status).to eq(1) }
      expect(shell).to have_received(:say).with(/No upcoming games.*gamechanger refresh/, :yellow)
    end
  end
end
