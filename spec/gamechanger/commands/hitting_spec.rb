# frozen_string_literal: true

require 'spec_helper'

RSpec.describe Gamechanger::Commands::Hitting do
  let(:shell)   { instance_spy(Thor::Shell::Color) }
  let(:options) { { format: 'table' } }
  let(:command) { described_class.new(options: options, shell: shell) }

  let(:storage) { instance_double(Gamechanger::Storage, close: nil) }

  before do
    allow(Gamechanger::Storage).to receive(:new).and_return(storage)
    allow(storage).to receive(:fielding_positions_most_recent_by_name).and_return({})
    allow(Gamechanger::Config).to receive(:new).and_return(
      instance_double(Gamechanger::Config, season: 2026)
    )
  end

  describe '#call without --player' do
    it 'renders the season summary' do
      rows = [{ 'batter_name' => 'Bob', 'avg' => 0.300, 'obp' => 0.400 }]
      allow(storage).to receive(:season_batting_summary).and_return(rows)

      expect { command.call }.not_to raise_error
    end

    it 'exits 1 with yellow hint when summary is empty' do
      allow(storage).to receive(:season_batting_summary).and_return([])

      expect { command.call }.to raise_error(SystemExit) { |e| expect(e.status).to eq(1) }
      expect(shell).to have_received(:say).with(/No batting data in cache.*gamechanger refresh/, :yellow)
    end

    context 'with --sort' do
      let(:rows) do
        [
          { 'batter_name' => 'Charlie', 'games' => 5, 'total_ab' => 10, 'total_hits' => 3, 'total_walks' => 1, 'total_k' => 2 },
          { 'batter_name' => 'Alice',   'games' => 5, 'total_ab' => 8,  'total_hits' => 4, 'total_walks' => 0, 'total_k' => 1 }
        ]
      end

      before { allow(storage).to receive(:season_batting_summary).and_return(rows) }

      it 'sorts ascending by avg' do
        cmd = described_class.new(options: { format: 'table', sort: 'avg' }, shell: shell)
        formatter = instance_spy(Gamechanger::Formatters::Table, hitting: '')
        allow(cmd).to receive(:build_formatter).and_return(formatter)
        cmd.call
        expect(formatter).to have_received(:hitting) do |passed_rows|
          expect(passed_rows.map { |r| r['batter_name'] }).to eq(%w[Charlie Alice])
        end
      end

      it 'sorts descending when --desc is set' do
        cmd = described_class.new(options: { format: 'table', sort: 'avg', desc: true }, shell: shell)
        formatter = instance_spy(Gamechanger::Formatters::Table, hitting: '')
        allow(cmd).to receive(:build_formatter).and_return(formatter)
        cmd.call
        expect(formatter).to have_received(:hitting) do |passed_rows|
          expect(passed_rows.map { |r| r['batter_name'] }).to eq(%w[Alice Charlie])
        end
      end

      it 'exits 1 with red error for unknown sort key' do
        cmd = described_class.new(options: { format: 'table', sort: 'bogus' }, shell: shell)
        expect { cmd.call }.to raise_error(SystemExit) { |e| expect(e.status).to eq(1) }
        expect(shell).to have_received(:say_error).with(/Unknown sort key 'bogus'/, :red)
      end
    end

    context 'positions column' do
      let(:rows) { [{ 'batter_name' => 'Bob', 'games' => 1, 'total_ab' => 3, 'total_hits' => 1, 'total_walks' => 0, 'total_k' => 1 }] }

      before { allow(storage).to receive(:season_batting_summary).and_return(rows) }

      it "merges the player's most-recent positions onto each row" do
        allow(storage).to receive(:fielding_positions_most_recent_by_name)
          .and_return({ 'Bob' => ['SS', 'P'] })
        formatter = instance_spy(Gamechanger::Formatters::Table, hitting: '')
        allow(command).to receive(:build_formatter).and_return(formatter)

        command.call

        expect(formatter).to have_received(:hitting) do |passed_rows|
          expect(passed_rows.first['positions']).to eq(['SS', 'P'])
        end
      end

      it 'sets positions to an empty array when the player has no recent fielding' do
        allow(storage).to receive(:fielding_positions_most_recent_by_name).and_return({})
        formatter = instance_spy(Gamechanger::Formatters::Table, hitting: '')
        allow(command).to receive(:build_formatter).and_return(formatter)

        command.call

        expect(formatter).to have_received(:hitting) do |passed_rows|
          expect(passed_rows.first['positions']).to eq([])
        end
      end
    end
  end

  describe '#call with --player' do
    let(:command) { described_class.new(options: { player: 'Bob' }, shell: shell) }

    it 'exits 1 with disambiguation list when multiple names match' do
      allow(storage).to receive(:batter_games).with('Bob').and_return(['Bob Jones', 'Bob Smith'])

      expect { command.call }.to raise_error(SystemExit) { |e| expect(e.status).to eq(1) }
      expect(shell).to have_received(:say).with('Ambiguous name — did you mean:', :yellow)
      expect(shell).to have_received(:say).with('  Bob Jones')
      expect(shell).to have_received(:say).with('  Bob Smith')
    end

    it 'exits 1 with yellow message when no batter matches' do
      allow(storage).to receive(:batter_games).with('Bob').and_return([])

      expect { command.call }.to raise_error(SystemExit) { |e| expect(e.status).to eq(1) }
      expect(shell).to have_received(:say).with("No batter matching 'Bob' found this season.", :yellow)
    end
  end
end
