# frozen_string_literal: true

require 'spec_helper'

RSpec.describe Gamechanger::Commands::Lineup do
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
    it 'resolves the next scheduled game and renders the lineup' do
      game = { 'game_date' => '2026-03-21', 'opponent' => 'Eagles' }
      allow(storage).to receive(:next_scheduled_game).and_return(game)
      allow(storage).to receive(:batter_lineup_data).with(before_date: Date.parse('2026-03-21')).and_return([])

      # Renders something (empty lineup is still valid output).
      expect { command.call }.not_to raise_error
    end

    it 'uses options[:date] when explicitly provided' do
      command = described_class.new(options: { date: '2026-04-15' }, shell: shell)
      allow(storage).to receive(:batter_lineup_data).with(before_date: Date.parse('2026-04-15')).and_return([])

      expect { command.call }.not_to raise_error
      expect(storage).to have_received(:batter_lineup_data).with(before_date: Date.parse('2026-04-15'))
    end

    it 'exits 1 when StorageError propagates' do
      allow(storage).to receive(:next_scheduled_game).and_raise(Gamechanger::StorageError, 'db locked')

      expect { command.call }.to raise_error(SystemExit) { |e| expect(e.status).to eq(1) }
    end
  end
end
