# frozen_string_literal: true

require 'spec_helper'

RSpec.describe Gamechanger::Commands::Base do
  let(:shell) { instance_spy(Thor::Shell::Color) }
  let(:options) { { format: 'table' } }

  let(:test_command_class) do
    Class.new(described_class) do
      def call
        run_command { :ok }
      end

      public :run_command, :with_storage, :current_season, :load_config!, :build_formatter, :resolve_target
    end
  end

  let(:command) { test_command_class.new(options: options, shell: shell) }

  describe '#initialize' do
    it 'captures options and shell' do
      expect(command.options).to eq(options)
      expect(command.shell).to eq(shell)
    end
  end

  describe '#call' do
    it 'raises NotImplementedError on the abstract base' do
      base = described_class.new(options: options, shell: shell)
      expect { base.call }.to raise_error(NotImplementedError, /Gamechanger::Commands::Base must implement #call/)
    end
  end

  describe '#run_command' do
    it 'returns the block result when no exception is raised' do
      expect(command.run_command { 42 }).to eq(42)
    end

    it 'rescues AuthError, prints to stderr, and exits 2' do
      expect {
        command.run_command { raise Gamechanger::AuthError, 'bad creds' }
      }.to raise_error(SystemExit) { |e| expect(e.status).to eq(2) }
      expect(shell).to have_received(:say_error).with('Authentication error: bad creds', :red)
    end

    it 'rescues NetworkError, prints to stderr, and exits 3' do
      expect {
        command.run_command { raise Gamechanger::NetworkError, 'timeout' }
      }.to raise_error(SystemExit) { |e| expect(e.status).to eq(3) }
      expect(shell).to have_received(:say_error).with('Network error: timeout', :red)
    end

    it 'rescues ConfigError, prints to stderr, and exits 4' do
      expect {
        command.run_command { raise Gamechanger::ConfigError, 'no team_id' }
      }.to raise_error(SystemExit) { |e| expect(e.status).to eq(4) }
      expect(shell).to have_received(:say_error).with('Configuration error: no team_id', :red)
    end

    it 'rescues APIShapeError with red + yellow stderr lines, and exits 3' do
      expect {
        command.run_command { raise Gamechanger::APIShapeError, 'unexpected shape' }
      }.to raise_error(SystemExit) { |e| expect(e.status).to eq(3) }
      expect(shell).to have_received(:say_error).with('Gamechanger API returned an unexpected format: unexpected shape', :red)
      expect(shell).to have_received(:say_error).with('The API may have changed. Check docs/research/gc-api-notes.md', :yellow)
    end

    it 'rescues StorageError with stderr hint pointing at `gamechanger refresh`, and exits 1' do
      expect {
        command.run_command { raise Gamechanger::StorageError, 'db locked' }
      }.to raise_error(SystemExit) { |e| expect(e.status).to eq(1) }
      expect(shell).to have_received(:say_error).with('Cache read failed — db locked', :red)
      expect(shell).to have_received(:say_error).with(
        'Try deleting ~/.gamechanger/cache.db and re-running `gamechanger refresh`',
        :yellow
      )
    end

    it 'lets unrecognized errors propagate' do
      expect {
        command.run_command { raise RuntimeError, 'something else' }
      }.to raise_error(RuntimeError, 'something else')
    end
  end

  describe '#current_season' do
    it 'reads from Config.new.season' do
      allow(Gamechanger::Config).to receive(:new).and_return(
        instance_double(Gamechanger::Config, season: 2026)
      )
      expect(command.current_season).to eq(2026)
    end
  end

  describe '#build_formatter' do
    it 'returns Json for format=json' do
      cmd = test_command_class.new(options: { format: 'json' }, shell: shell)
      expect(cmd.build_formatter).to be_a(Gamechanger::Formatters::Json)
    end

    it 'returns Markdown for format=markdown' do
      cmd = test_command_class.new(options: { format: 'markdown' }, shell: shell)
      expect(cmd.build_formatter).to be_a(Gamechanger::Formatters::Markdown)
    end

    it 'returns Table for format=table' do
      cmd = test_command_class.new(options: { format: 'table' }, shell: shell)
      expect(cmd.build_formatter).to be_a(Gamechanger::Formatters::Table)
    end

    it 'returns Table when format is missing or unknown' do
      cmd = test_command_class.new(options: {}, shell: shell)
      expect(cmd.build_formatter).to be_a(Gamechanger::Formatters::Table)
    end
  end

  describe '#load_config!' do
    it 'returns the config when configured' do
      cfg = instance_double(Gamechanger::Config, configured?: true)
      allow(Gamechanger::Config).to receive(:new).and_return(cfg)
      expect(command.load_config!).to eq(cfg)
    end

    it 'prints to stderr and exits 4 when not configured' do
      allow(Gamechanger::Config).to receive(:new).and_return(
        instance_double(Gamechanger::Config, configured?: false)
      )
      expect { command.load_config! }.to raise_error(SystemExit) { |e| expect(e.status).to eq(4) }
      expect(shell).to have_received(:say_error).with('Not configured. Run `gamechanger setup` first.', :red)
    end
  end

  describe '#with_storage' do
    let(:storage_double) { instance_double(Gamechanger::Storage, close: nil) }

    before do
      allow(Gamechanger::Storage).to receive(:new).and_return(storage_double)
    end

    it 'opens storage for the given season, yields it, and closes after the block' do
      yielded = nil
      command.with_storage(season: 2026) { |s| yielded = s }
      expect(Gamechanger::Storage).to have_received(:new).with(season: 2026)
      expect(yielded).to eq(storage_double)
      expect(storage_double).to have_received(:close)
    end

    it 'closes storage even when the block raises' do
      expect {
        command.with_storage(season: 2026) { raise 'boom' }
      }.to raise_error('boom')
      expect(storage_double).to have_received(:close)
    end

    it 'defaults to current_season when none provided' do
      allow(Gamechanger::Config).to receive(:new).and_return(
        instance_double(Gamechanger::Config, season: 2027)
      )
      command.with_storage { |_| }
      expect(Gamechanger::Storage).to have_received(:new).with(season: 2027)
    end
  end

  describe '#resolve_target' do
    let(:storage) { instance_double(Gamechanger::Storage) }

    it 'returns [parsed_date, nil] for an explicit valid date' do
      date, info = command.resolve_target('2026-03-21', storage: storage)
      expect(date).to eq(Date.parse('2026-03-21'))
      expect(info).to be_nil
    end

    it 'prints to stdout (red) and exits 1 for an unparseable date string' do
      expect {
        command.resolve_target('not-a-date', storage: storage)
      }.to raise_error(SystemExit) { |e| expect(e.status).to eq(1) }
      expect(shell).to have_received(:say).with("Invalid date 'not-a-date' — expected YYYY-MM-DD", :red)
    end

    it 'returns [parsed_date, game_hash] when no date and a next game exists' do
      game = { 'game_date' => '2026-03-21', 'opponent' => 'Eagles' }
      allow(storage).to receive(:next_scheduled_game).and_return(game)
      date, info = command.resolve_target(nil, storage: storage)
      expect(date).to eq(Date.parse('2026-03-21'))
      expect(info).to eq(game)
    end

    it 'prints to stdout (yellow) and exits 1 when no date and no next game' do
      allow(storage).to receive(:next_scheduled_game).and_return(nil)
      expect {
        command.resolve_target(nil, storage: storage)
      }.to raise_error(SystemExit) { |e| expect(e.status).to eq(1) }
      expect(shell).to have_received(:say).with(
        'No upcoming games in cache. Run `gamechanger refresh` to sync the schedule.',
        :yellow
      )
    end
  end
end
