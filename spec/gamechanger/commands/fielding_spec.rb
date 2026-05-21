# frozen_string_literal: true

require 'spec_helper'

RSpec.describe Gamechanger::Commands::Fielding do
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

  let(:rows) do
    [
      { 'player_name' => 'Alice Smith', 'games' => 2, 'positions' => { 'SS' => 3, 'P' => 1 }, 'total' => 4 },
      { 'player_name' => 'Bob Jones',   'games' => 3, 'positions' => { '1B' => 2, 'CF' => 1 }, 'total' => 3 },
      { 'player_name' => 'Carla Diaz',  'games' => 4, 'positions' => { 'SS' => 4 },           'total' => 4 }
    ]
  end

  describe '#call' do
    it 'exits 1 with yellow hint when no fielding data' do
      allow(storage).to receive(:season_fielding_summary).and_return([])
      expect { command.call }.to raise_error(SystemExit) { |e| expect(e.status).to eq(1) }
      expect(shell).to have_received(:say).with(/No fielding data in cache.*gamechanger refresh/, :yellow)
    end

    it 'renders a fielding pivot from storage rows' do
      allow(storage).to receive(:season_fielding_summary).and_return(rows)
      expect { command.call }.not_to raise_error
    end

    it 'defaults to sorting by total desc with player_name asc tiebreak' do
      allow(storage).to receive(:season_fielding_summary).and_return(rows)
      formatter = instance_spy(Gamechanger::Formatters::Table, fielding: '')
      allow(command).to receive(:build_formatter).and_return(formatter)

      command.call

      expect(formatter).to have_received(:fielding) do |passed_rows, _cols|
        # Alice (total 4, A...) before Carla (total 4, C...) before Bob (total 3)
        expect(passed_rows.map { |r| r['player_name'] }).to eq(['Alice Smith', 'Carla Diaz', 'Bob Jones'])
      end
    end

    it 'passes columns in canonical order (P, C, 1B, 2B, 3B, SS, LF, CF, RF, DH, EH), present only' do
      allow(storage).to receive(:season_fielding_summary).and_return(rows)
      formatter = instance_spy(Gamechanger::Formatters::Table, fielding: '')
      allow(command).to receive(:build_formatter).and_return(formatter)

      command.call

      expect(formatter).to have_received(:fielding) do |_passed_rows, cols|
        expect(cols).to eq(%w[P 1B SS CF])
      end
    end

    context 'with --sort games' do
      it 'sorts ascending by game count' do
        cmd = described_class.new(options: { format: 'table', sort: 'games' }, shell: shell)
        allow(storage).to receive(:season_fielding_summary).and_return(rows)
        formatter = instance_spy(Gamechanger::Formatters::Table, fielding: '')
        allow(cmd).to receive(:build_formatter).and_return(formatter)

        cmd.call
        expect(formatter).to have_received(:fielding) do |passed_rows, _|
          expect(passed_rows.map { |r| r['games'] }).to eq([2, 3, 4])
        end
      end

      it "accepts 'g' alias" do
        cmd = described_class.new(options: { format: 'table', sort: 'g', desc: true }, shell: shell)
        allow(storage).to receive(:season_fielding_summary).and_return(rows)
        formatter = instance_spy(Gamechanger::Formatters::Table, fielding: '')
        allow(cmd).to receive(:build_formatter).and_return(formatter)

        cmd.call
        expect(formatter).to have_received(:fielding) do |passed_rows, _|
          expect(passed_rows.map { |r| r['games'] }).to eq([4, 3, 2])
        end
      end
    end

    context 'with --sort' do
      it 'sorts by player ascending by default' do
        cmd = described_class.new(options: { format: 'table', sort: 'player' }, shell: shell)
        allow(storage).to receive(:season_fielding_summary).and_return(rows)
        formatter = instance_spy(Gamechanger::Formatters::Table, fielding: '')
        allow(cmd).to receive(:build_formatter).and_return(formatter)

        cmd.call
        expect(formatter).to have_received(:fielding) do |passed_rows, _|
          expect(passed_rows.map { |r| r['player_name'] }).to eq(['Alice Smith', 'Bob Jones', 'Carla Diaz'])
        end
      end

      it 'reverses sort when --desc is set' do
        cmd = described_class.new(options: { format: 'table', sort: 'player', desc: true }, shell: shell)
        allow(storage).to receive(:season_fielding_summary).and_return(rows)
        formatter = instance_spy(Gamechanger::Formatters::Table, fielding: '')
        allow(cmd).to receive(:build_formatter).and_return(formatter)

        cmd.call
        expect(formatter).to have_received(:fielding) do |passed_rows, _|
          expect(passed_rows.map { |r| r['player_name'] }).to eq(['Carla Diaz', 'Bob Jones', 'Alice Smith'])
        end
      end

      it 'accepts uppercase position codes (--sort SS)' do
        cmd = described_class.new(options: { format: 'table', sort: 'SS', desc: true }, shell: shell)
        allow(storage).to receive(:season_fielding_summary).and_return(rows)
        formatter = instance_spy(Gamechanger::Formatters::Table, fielding: '')
        allow(cmd).to receive(:build_formatter).and_return(formatter)

        cmd.call
        expect(formatter).to have_received(:fielding) do |passed_rows, _|
          # Carla SS=4, Alice SS=3, Bob SS=0
          expect(passed_rows.map { |r| r['player_name'] }).to eq(['Carla Diaz', 'Alice Smith', 'Bob Jones'])
        end
      end

      it 'accepts lowercase position codes (--sort ss)' do
        cmd = described_class.new(options: { format: 'table', sort: 'ss', desc: true }, shell: shell)
        allow(storage).to receive(:season_fielding_summary).and_return(rows)
        formatter = instance_spy(Gamechanger::Formatters::Table, fielding: '')
        allow(cmd).to receive(:build_formatter).and_return(formatter)

        cmd.call
        expect(formatter).to have_received(:fielding) do |passed_rows, _|
          expect(passed_rows.map { |r| r['player_name'] }).to eq(['Carla Diaz', 'Alice Smith', 'Bob Jones'])
        end
      end

      it 'exits 1 with red error for unknown sort key' do
        cmd = described_class.new(options: { format: 'table', sort: 'bogus' }, shell: shell)
        allow(storage).to receive(:season_fielding_summary).and_return(rows)
        expect { cmd.call }.to raise_error(SystemExit) { |e| expect(e.status).to eq(1) }
        expect(shell).to have_received(:say_error).with(/Unknown sort key 'bogus'/, :red)
      end
    end

    context 'with --format json' do
      it 'emits JSON that parses to the expected array shape' do
        cmd = described_class.new(options: { format: 'json' }, shell: shell)
        allow(storage).to receive(:season_fielding_summary).and_return(rows)

        output = capture_stdout { cmd.call }
        parsed = JSON.parse(output)
        expect(parsed).to be_an(Array)
        expect(parsed.first).to include('player_name', 'positions', 'total')
      end
    end
  end

  def capture_stdout
    original = $stdout
    $stdout = StringIO.new
    yield
    $stdout.string
  ensure
    $stdout = original
  end
end
