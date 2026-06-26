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

  it 'renders availability for the resolved target date' do
    game = { 'game_date' => '2026-03-21', 'opponent' => 'Eagles' }
    allow(storage).to receive(:next_scheduled_game).and_return(game)
    allow(storage).to receive(:pitcher_availability_data).with(before_date: Date.parse('2026-03-21')).and_return([])

    expect { command.call }.not_to raise_error
  end

  it 'exits 1 with yellow hint when no scheduled game and no --date' do
    allow(storage).to receive(:next_scheduled_game).and_return(nil)

    expect { command.call }.to raise_error(SystemExit) { |e| expect(e.status).to eq(1) }
    expect(shell).to have_received(:say).with('No upcoming games in cache.', :yellow)
    expect(shell).to have_received(:say).with(/gamechanger demo.*gamechanger setup.*gamechanger refresh/, :yellow)
  end

  it 'prints invalid date error on stdout and exits 1' do
    cmd = described_class.new(options: { date: 'not-a-date' }, shell: shell)

    expect { cmd.call }.to raise_error(SystemExit) { |e| expect(e.status).to eq(1) }
    expect(shell).to have_received(:say).with(/Invalid date 'not-a-date'/, :red)
  end
end
