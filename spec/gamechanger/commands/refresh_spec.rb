# frozen_string_literal: true

require 'spec_helper'

RSpec.describe Gamechanger::Commands::Refresh do
  let(:shell)   { instance_spy(Thor::Shell::Color) }
  let(:options) { {} }
  let(:command) { described_class.new(options: options, shell: shell) }

  let(:config) do
    instance_double(Gamechanger::Config, configured?: true, season: 2026)
  end

  let(:storage) { instance_double(Gamechanger::Storage, close: nil) }

  before do
    allow(Gamechanger::Config).to receive(:new).and_return(config)
    allow(Gamechanger::Storage).to receive(:new).and_return(storage)
  end

  describe '#call' do
    it 'syncs with force: true and reports counts on success' do
      result = Gamechanger::SyncResult.new(3, 8, 45)
      syncer = instance_double(Gamechanger::Syncer, run: result)
      allow(Gamechanger::Syncer).to receive(:new).with(config, storage).and_return(syncer)

      command.call

      expect(syncer).to have_received(:run).with(force: true)
      expect(shell).to have_received(:say).with('Syncing games from Gamechanger...', :cyan)
      expect(shell).to have_received(:say).with('3 games, 8 outings, 45 at-bats updated.', :green)
      expect(storage).to have_received(:close)
    end

    it 'uses singular pluralization for counts of 1' do
      result = Gamechanger::SyncResult.new(1, 1, 1)
      syncer = instance_double(Gamechanger::Syncer, run: result)
      allow(Gamechanger::Syncer).to receive(:new).and_return(syncer)

      command.call

      expect(shell).to have_received(:say).with('1 game, 1 outing, 1 at-bat updated.', :green)
    end

    it 'opens storage with the config season' do
      result = Gamechanger::SyncResult.new(0, 0, 0)
      allow(Gamechanger::Syncer).to receive(:new).and_return(
        instance_double(Gamechanger::Syncer, run: result)
      )

      command.call

      expect(Gamechanger::Storage).to have_received(:new).with(season: 2026)
    end

    it 'closes storage even when Syncer raises' do
      syncer = instance_double(Gamechanger::Syncer)
      allow(syncer).to receive(:run).and_raise(Gamechanger::NetworkError, 'timeout')
      allow(Gamechanger::Syncer).to receive(:new).and_return(syncer)

      expect { command.call }.to raise_error(SystemExit) { |e| expect(e.status).to eq(3) }
      expect(storage).to have_received(:close)
    end

    it 'exits 4 when the config is not configured' do
      allow(Gamechanger::Config).to receive(:new).and_return(
        instance_double(Gamechanger::Config, configured?: false)
      )

      expect { command.call }.to raise_error(SystemExit) { |e| expect(e.status).to eq(4) }
      expect(shell).to have_received(:say).with('Not configured. Run `gamechanger setup` first.', :red)
    end

    it 'maps AuthError to red + exit 2' do
      allow(Gamechanger::Syncer).to receive(:new).and_raise(Gamechanger::AuthError, 'bad creds')

      expect { command.call }.to raise_error(SystemExit) { |e| expect(e.status).to eq(2) }
      expect(shell).to have_received(:say).with('Authentication error: bad creds', :red)
    end

    it 'maps APIShapeError to red + yellow + exit 3' do
      allow(Gamechanger::Syncer).to receive(:new).and_raise(Gamechanger::APIShapeError, 'unexpected')

      expect { command.call }.to raise_error(SystemExit) { |e| expect(e.status).to eq(3) }
      expect(shell).to have_received(:say).with('Gamechanger API returned an unexpected format: unexpected', :red)
      expect(shell).to have_received(:say).with('The API may have changed. Check docs/research/gc-api-notes.md', :yellow)
    end
  end
end
