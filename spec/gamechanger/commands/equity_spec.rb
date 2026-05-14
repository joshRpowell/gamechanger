# frozen_string_literal: true

require 'spec_helper'

RSpec.describe Gamechanger::Commands::Equity do
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

  it 'renders the equity table when player_participation returns rows' do
    rows = [{ 'player_name' => 'Bob', 'total_games' => 10, 'total_games_batted' => 8, 'total_games_pitched' => 0 }]
    allow(storage).to receive(:player_participation).and_return(rows)

    expect { command.call }.not_to raise_error
  end

  it 'exits 1 with a yellow hint when player_participation is empty' do
    allow(storage).to receive(:player_participation).and_return([])

    expect { command.call }.to raise_error(SystemExit) { |e| expect(e.status).to eq(1) }
    expect(shell).to have_received(:say).with(/No player data in cache.*gamechanger refresh/, :yellow)
  end
end
