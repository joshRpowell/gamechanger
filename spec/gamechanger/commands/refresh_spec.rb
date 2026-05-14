# frozen_string_literal: true

require 'spec_helper'

RSpec.describe Gamechanger::Commands::Refresh do
  let(:shell)   { instance_spy(Thor::Shell::Color) }
  let(:options) { {} }
  let(:command) { described_class.new(options: options, shell: shell) }

  let(:config)  { instance_double(Gamechanger::Config, configured?: true, season: 2026) }
  let(:storage) { instance_double(Gamechanger::Storage, close: nil) }

  before do
    allow(Gamechanger::Config).to receive(:new).and_return(config)
    allow(Gamechanger::Storage).to receive(:new).and_return(storage)
  end

  describe '#call (default human format)' do
    it 'syncs with force: true and prints a human count line in green' do
      result = Gamechanger::SyncResult.new(3, 8, 45)
      syncer = instance_double(Gamechanger::Syncer, run: result)
      allow(Gamechanger::Syncer).to receive(:new).with(config, storage).and_return(syncer)

      command.call

      expect(syncer).to have_received(:run).with(force: true)
      expect(shell).to have_received(:say).with('3 games, 8 outings, 45 at-bats updated.', :green)
    end

    it 'uses singular pluralization for counts of 1' do
      syncer = instance_double(Gamechanger::Syncer, run: Gamechanger::SyncResult.new(1, 1, 1))
      allow(Gamechanger::Syncer).to receive(:new).and_return(syncer)

      command.call

      expect(shell).to have_received(:say).with('1 game, 1 outing, 1 at-bat updated.', :green)
    end
  end

  describe '#call --format json' do
    let(:command) { described_class.new(options: { format: 'json' }, shell: shell) }

    it 'emits a JSON object on stdout instead of the human line' do
      syncer = instance_double(Gamechanger::Syncer, run: Gamechanger::SyncResult.new(2, 5, 30))
      allow(Gamechanger::Syncer).to receive(:new).and_return(syncer)

      expect { command.call }.to output(/"games":2.*"outings":5.*"at_bats":30/m).to_stdout
      expect(shell).not_to have_received(:say).with(/games?.*outings?.*at-bats?/, :green)
    end
  end

  describe '#call error paths' do
    it 'maps AuthError to red stderr + exit 2' do
      allow(Gamechanger::Syncer).to receive(:new).and_raise(Gamechanger::AuthError, 'bad creds')

      expect { command.call }.to raise_error(SystemExit) { |e| expect(e.status).to eq(2) }
      expect(shell).to have_received(:say_error).with('Authentication error: bad creds', :red)
    end

    it 'exits 4 when not configured' do
      allow(Gamechanger::Config).to receive(:new).and_return(
        instance_double(Gamechanger::Config, configured?: false)
      )

      expect { command.call }.to raise_error(SystemExit) { |e| expect(e.status).to eq(4) }
    end
  end
end
