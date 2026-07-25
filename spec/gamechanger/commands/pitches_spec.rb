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

    it 'passes cumulative totals with derived rates to the formatter' do
      outings = [
        { 'game_date' => '2026-05-01', 'opponent' => 'A', 'home_away' => 'home', 'status' => 'final',
          'pitcher_name' => 'Alice', 'pitches_thrown' => 60, 'strikes_thrown' => 38,
          'innings_pitched' => 4.0, 'batters_faced' => 15, 'hits_allowed' => 3,
          'runs_allowed' => 2, 'earned_runs' => 2, 'walks_issued' => 1,
          'strikeouts_recorded' => 5, 'wild_pitches' => 0, 'hbp_allowed' => 0 },
        { 'game_date' => '2026-05-08', 'opponent' => 'B', 'home_away' => 'away', 'status' => 'final',
          'pitcher_name' => 'Alice', 'pitches_thrown' => 45, 'strikes_thrown' => 28,
          'innings_pitched' => 3.0, 'batters_faced' => 12, 'hits_allowed' => 2,
          'runs_allowed' => 1, 'earned_runs' => 1, 'walks_issued' => 2,
          'strikeouts_recorded' => 4, 'wild_pitches' => 1, 'hbp_allowed' => 0 }
      ]
      allow(storage).to receive(:pitcher_games).with('Alice').and_return(outings)
      formatter = instance_spy(Gamechanger::Formatters::Table, pitcher_games: '')
      allow(command).to receive(:build_formatter).and_return(formatter)
      command.call
      expect(formatter).to have_received(:pitcher_games) do |_name, _rows, totals:|
        expect(totals['total_ip']).to eq(7.0)
        expect(totals['total_er']).to eq(3)
        expect(totals['total_bf']).to eq(27)
        expect(totals['total_so']).to eq(9)
        expect(totals['era']).to  be_within(0.01).of(3 * 9.0 / 7)
        expect(totals['whip']).to be_within(0.01).of((5 + 3) / 7.0)
        expect(totals['k9']).to   be_within(0.01).of(9 * 9.0 / 7)
        expect(totals['baa']).to  be_within(0.001).of(5.0 / (27 - 3 - 0))
      end
    end

    it 'sets cumulative rates to nil when total IP is 0' do
      outings = [
        { 'game_date' => '2026-05-01', 'opponent' => 'A', 'home_away' => 'home', 'status' => 'final',
          'pitcher_name' => 'Alice', 'pitches_thrown' => 8, 'strikes_thrown' => 3,
          'innings_pitched' => 0.0, 'batters_faced' => 2, 'hits_allowed' => 1,
          'runs_allowed' => 1, 'earned_runs' => 1, 'walks_issued' => 1,
          'strikeouts_recorded' => 0, 'wild_pitches' => 0, 'hbp_allowed' => 0 }
      ]
      allow(storage).to receive(:pitcher_games).with('Alice').and_return(outings)
      formatter = instance_spy(Gamechanger::Formatters::Table, pitcher_games: '')
      allow(command).to receive(:build_formatter).and_return(formatter)
      command.call
      expect(formatter).to have_received(:pitcher_games) do |_name, _rows, totals:|
        expect(totals['era']).to be_nil
        expect(totals['whip']).to be_nil
        expect(totals['k9']).to be_nil
      end
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

    it 'derives ERA/WHIP/K/9/BAA/BB9/P-IP/P-BF on each row' do
      rate_rows = [
        { 'pitcher_name' => 'Ace', 'games_pitched' => 1,
          'total_pitches' => 85, 'total_strikes' => 55,
          'total_ip' => 6.0, 'total_bf' => 24, 'total_h' => 5, 'total_r' => 2,
          'total_er' => 2, 'total_bb' => 2, 'total_so' => 8, 'total_wp' => 0,
          'total_hbp' => 0, 'avg_per_game' => 85, 'seven_day_total' => 0,
          'last_outing' => '2026-05-10' }
      ]
      allow(storage).to receive(:season_summary).and_return(rate_rows)
      formatter = instance_spy(Gamechanger::Formatters::Table, season_summary: '')
      allow(command).to receive(:build_formatter).and_return(formatter)
      command.call
      expect(formatter).to have_received(:season_summary) do |passed_rows, **|
        ace = passed_rows.first
        expect(ace['era']).to  be_within(0.01).of(3.00)
        expect(ace['whip']).to be_within(0.01).of(1.17)
        expect(ace['k9']).to   be_within(0.01).of(12.00)
        expect(ace['bb9']).to  be_within(0.01).of(3.00)
        expect(ace['baa']).to  be_within(0.001).of(5.0 / 22)  # H / (BF - BB - HBP) = 5/22
        expect(ace['p_ip']).to be_within(0.01).of(14.17)
        expect(ace['p_bf']).to be_within(0.01).of(85.0 / 24)
      end
    end

    it 'sets all rate stats to nil when IP is 0' do
      ip_zero = [
        { 'pitcher_name' => 'Reliever', 'games_pitched' => 1,
          'total_pitches' => 8, 'total_strikes' => 3, 'total_ip' => 0,
          'total_bf' => 2, 'total_h' => 1, 'total_r' => 0, 'total_er' => 0,
          'total_bb' => 1, 'total_so' => 0, 'total_wp' => 0, 'total_hbp' => 0,
          'avg_per_game' => 8, 'seven_day_total' => 0, 'last_outing' => '2026-05-10' }
      ]
      allow(storage).to receive(:season_summary).and_return(ip_zero)
      formatter = instance_spy(Gamechanger::Formatters::Table, season_summary: '')
      allow(command).to receive(:build_formatter).and_return(formatter)
      command.call
      expect(formatter).to have_received(:season_summary) do |passed_rows, **|
        r = passed_rows.first
        expect(r['era']).to be_nil
        expect(r['whip']).to be_nil
        expect(r['k9']).to be_nil
        expect(r['p_ip']).to be_nil
      end
    end

    it 'sets BAA to nil when (BF - BB - HBP) is non-positive' do
      no_ab = [
        { 'pitcher_name' => 'Wild', 'games_pitched' => 1,
          'total_pitches' => 20, 'total_strikes' => 5, 'total_ip' => 1.0,
          'total_bf' => 3, 'total_h' => 0, 'total_r' => 1, 'total_er' => 1,
          'total_bb' => 3, 'total_so' => 0, 'total_wp' => 0, 'total_hbp' => 0,
          'avg_per_game' => 20, 'seven_day_total' => 0, 'last_outing' => '2026-05-10' }
      ]
      allow(storage).to receive(:season_summary).and_return(no_ab)
      formatter = instance_spy(Gamechanger::Formatters::Table, season_summary: '')
      allow(command).to receive(:build_formatter).and_return(formatter)
      command.call
      expect(formatter).to have_received(:season_summary) do |passed_rows, **|
        expect(passed_rows.first['baa']).to be_nil
      end
    end

    it 'passes advanced: true to the formatter when --advanced is set' do
      cmd = described_class.new(options: { format: 'table', advanced: true }, shell: shell)
      formatter = instance_spy(Gamechanger::Formatters::Table, season_summary: '')
      allow(cmd).to receive(:build_formatter).and_return(formatter)
      cmd.call
      expect(formatter).to have_received(:season_summary).with(anything, advanced: true)
    end

    it 'passes advanced: false to the formatter by default' do
      formatter = instance_spy(Gamechanger::Formatters::Table, season_summary: '')
      allow(command).to receive(:build_formatter).and_return(formatter)
      command.call
      expect(formatter).to have_received(:season_summary).with(anything, advanced: false)
    end

    it 'sorts by --sort era ascending' do
      multi_rows = [
        { 'pitcher_name' => 'High', 'games_pitched' => 1, 'total_pitches' => 50, 'total_strikes' => 30,
          'total_ip' => 3.0, 'total_bf' => 12, 'total_h' => 5, 'total_r' => 6, 'total_er' => 6,
          'total_bb' => 2, 'total_so' => 2, 'total_wp' => 0, 'total_hbp' => 0,
          'avg_per_game' => 50, 'seven_day_total' => 0, 'last_outing' => '2026-05-10' },
        { 'pitcher_name' => 'Low', 'games_pitched' => 1, 'total_pitches' => 60, 'total_strikes' => 42,
          'total_ip' => 6.0, 'total_bf' => 22, 'total_h' => 3, 'total_r' => 1, 'total_er' => 1,
          'total_bb' => 1, 'total_so' => 8, 'total_wp' => 0, 'total_hbp' => 0,
          'avg_per_game' => 60, 'seven_day_total' => 0, 'last_outing' => '2026-05-10' }
      ]
      allow(storage).to receive(:season_summary).and_return(multi_rows)
      cmd = described_class.new(options: { format: 'table', sort: 'era' }, shell: shell)
      formatter = instance_spy(Gamechanger::Formatters::Table, season_summary: '')
      allow(cmd).to receive(:build_formatter).and_return(formatter)
      cmd.call
      expect(formatter).to have_received(:season_summary) do |passed_rows, **|
        expect(passed_rows.map { |r| r['pitcher_name'] }).to eq(%w[Low High])
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

  # PERF: `pitches` used to sync on every invocation, paying an HTTP round trip
  # plus the syncer's 0.5s-per-non-final-game rate-limit sleep before printing
  # an otherwise cached table. Syncing is now opt-in via --refresh.
  describe 'sync behaviour' do
    let(:formatter) { instance_spy(Gamechanger::Formatters::Table, season_summary: '') }

    before do
      allow(storage).to receive(:season_summary).and_return([])
      allow(storage).to receive(:stale_games).and_return([])
    end

    it 'does not sync by default (cache-only read)' do
      cmd = described_class.new(options: { format: 'table' }, shell: shell)
      allow(cmd).to receive(:build_formatter).and_return(formatter)

      cmd.call

      expect(Gamechanger::Syncer).not_to have_received(:new)
      expect(syncer).not_to have_received(:run)
      expect(formatter).to have_received(:season_summary)
    end

    it 'syncs with force: true before displaying when --refresh is passed' do
      cmd = described_class.new(options: { format: 'table', refresh: true }, shell: shell)
      allow(cmd).to receive(:build_formatter).and_return(formatter)

      cmd.call

      expect(Gamechanger::Syncer).to have_received(:new).with(config, storage)
      expect(syncer).to have_received(:run).with(force: true)
      expect(formatter).to have_received(:season_summary)
    end

    it 'announces the sync on a TTY when --refresh is passed' do
      allow($stdout).to receive(:tty?).and_return(true)
      cmd = described_class.new(options: { format: 'table', refresh: true }, shell: shell)
      allow(cmd).to receive(:build_formatter).and_return(formatter)

      cmd.call

      expect(shell).to have_received(:say).with('Syncing games from Gamechanger...', :cyan)
      expect(shell).to have_received(:say).with('Done.', :green)
    end

    it 'warns on a TTY when the cache holds in-progress or same-day games' do
      allow($stdout).to receive(:tty?).and_return(true)
      allow(storage).to receive(:stale_games).and_return([{ 'game_id' => 'g1' }])
      cmd = described_class.new(options: { format: 'table' }, shell: shell)
      allow(cmd).to receive(:build_formatter).and_return(formatter)

      cmd.call

      expect(shell).to have_received(:say).with(/Cached data may be stale/, :yellow)
      expect(syncer).not_to have_received(:run)
    end

    it 'does not warn on a TTY when no cached games are stale' do
      allow($stdout).to receive(:tty?).and_return(true)
      cmd = described_class.new(options: { format: 'table' }, shell: shell)
      allow(cmd).to receive(:build_formatter).and_return(formatter)

      cmd.call

      expect(shell).not_to have_received(:say).with(/Cached data may be stale/, :yellow)
    end

    it 'skips the staleness check entirely when output is not a TTY' do
      allow($stdout).to receive(:tty?).and_return(false)
      cmd = described_class.new(options: { format: 'table' }, shell: shell)
      allow(cmd).to receive(:build_formatter).and_return(formatter)

      cmd.call

      expect(storage).not_to have_received(:stale_games)
      expect(shell).not_to have_received(:say).with(/Cached data may be stale/, :yellow)
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
