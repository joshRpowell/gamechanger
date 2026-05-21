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

  describe '#call season summary %IP column' do
    let(:rows) do
      [
        { 'pitcher_name' => 'Ace',    'games_pitched' => 3, 'total_pitches' => 100, 'total_strikes' => 60,
          'total_ip' => 8.0, 'avg_per_game' => 33.3, 'seven_day_total' => 0, 'last_outing' => '2026-05-10' },
        { 'pitcher_name' => 'Middle', 'games_pitched' => 2, 'total_pitches' => 50,  'total_strikes' => 30,
          'total_ip' => 4.0, 'avg_per_game' => 25.0, 'seven_day_total' => 0, 'last_outing' => '2026-05-08' },
        { 'pitcher_name' => 'Closer', 'games_pitched' => 4, 'total_pitches' => 80,  'total_strikes' => 50,
          'total_ip' => 8.0, 'avg_per_game' => 20.0, 'seven_day_total' => 0, 'last_outing' => '2026-05-12' }
      ]
    end

    before { allow(storage).to receive(:season_summary).and_return(rows) }

    it 'derives ip_share per row as total_ip / team_total_ip * 100' do
      formatter = instance_spy(Gamechanger::Formatters::Table, season_summary: '')
      allow(command).to receive(:build_formatter).and_return(formatter)
      command.call
      expect(formatter).to have_received(:season_summary) do |passed_rows|
        ace    = passed_rows.find { |r| r['pitcher_name'] == 'Ace' }
        middle = passed_rows.find { |r| r['pitcher_name'] == 'Middle' }
        expect(ace['ip_share']).to be_within(0.001).of(40.0)
        expect(middle['ip_share']).to be_within(0.001).of(20.0)
        # Sum across all rows ≈ 100%
        expect(passed_rows.sum { |r| r['ip_share'] }).to be_within(0.001).of(100.0)
      end
    end

    it 'sorts by ip_share descending with --sort ip_share --desc' do
      cmd = described_class.new(options: { format: 'table', sort: 'ip_share', desc: true }, shell: shell)
      formatter = instance_spy(Gamechanger::Formatters::Table, season_summary: '')
      allow(cmd).to receive(:build_formatter).and_return(formatter)
      cmd.call
      expect(formatter).to have_received(:season_summary) do |passed_rows|
        # Ace and Closer both 40%, Middle 20% — verify Middle is last
        expect(passed_rows.last['pitcher_name']).to eq('Middle')
      end
    end

    it 'sets ip_share to nil for every row when team_total_ip is 0' do
      zero_rows = [
        { 'pitcher_name' => 'NoIP', 'games_pitched' => 0, 'total_pitches' => 0, 'total_strikes' => 0,
          'total_ip' => 0, 'avg_per_game' => 0, 'seven_day_total' => 0, 'last_outing' => nil }
      ]
      allow(storage).to receive(:season_summary).and_return(zero_rows)
      formatter = instance_spy(Gamechanger::Formatters::Table, season_summary: '')
      allow(command).to receive(:build_formatter).and_return(formatter)
      command.call
      expect(formatter).to have_received(:season_summary) do |passed_rows|
        expect(passed_rows.first['ip_share']).to be_nil
      end
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
