# frozen_string_literal: true

require 'spec_helper'

RSpec.describe Gamechanger::Commands::Availability do
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

  describe '#call' do
    it 'resolves the next scheduled game and renders availability' do
      game = { 'game_date' => '2026-03-21', 'opponent' => 'Eagles' }
      allow(storage).to receive(:next_scheduled_game).and_return(game)
      allow(storage).to receive(:pitcher_availability_data).with(before_date: Date.parse('2026-03-21')).and_return([])

      expect { command.call }.not_to raise_error
    end

    it 'exits 1 with yellow hint when no scheduled game and no --date' do
      allow(storage).to receive(:next_scheduled_game).and_return(nil)

      expect { command.call }.to raise_error(SystemExit) { |e| expect(e.status).to eq(1) }
      expect(shell).to have_received(:say).with(/No upcoming games.*gamechanger refresh/, :yellow)
    end

    it 'exits 1 with red error on invalid --date' do
      command = described_class.new(options: { date: 'not-a-date' }, shell: shell)

      expect { command.call }.to raise_error(SystemExit) { |e| expect(e.status).to eq(1) }
      expect(shell).to have_received(:say).with(/Invalid date 'not-a-date'/, :red)
    end
  end
end
