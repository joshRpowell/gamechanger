# frozen_string_literal: true

require 'spec_helper'

RSpec.describe Gamechanger::Commands::Brief do
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

  it 'aggregates availability, lineup, arcs, and equity for the resolved target' do
    game   = { 'game_date' => '2026-03-21', 'opponent' => 'Eagles' }
    target = Date.parse('2026-03-21')
    allow(storage).to receive(:next_scheduled_game).and_return(game)
    allow(storage).to receive(:pitcher_availability_data).with(before_date: target).and_return([])
    allow(storage).to receive(:batter_lineup_data).with(before_date: target).and_return([])
    allow(storage).to receive(:all_player_development_summary).and_return([])
    allow(storage).to receive(:player_participation).and_return([])

    expect { command.call }.not_to raise_error
  end

  it 'exits 1 with yellow hint when no scheduled game and no --date' do
    allow(storage).to receive(:next_scheduled_game).and_return(nil)

    expect { command.call }.to raise_error(SystemExit) { |e| expect(e.status).to eq(1) }
    expect(shell).to have_received(:say).with(/No upcoming games.*gamechanger refresh/, :yellow)
  end

  it 'maps APIShapeError to stderr red+yellow and exits 3' do
    allow(storage).to receive(:next_scheduled_game).and_raise(Gamechanger::APIShapeError, 'shape')

    expect { command.call }.to raise_error(SystemExit) { |e| expect(e.status).to eq(3) }
    expect(shell).to have_received(:say_error).with(/Gamechanger API returned an unexpected format/, :red)
  end
end
