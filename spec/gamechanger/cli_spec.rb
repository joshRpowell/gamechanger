# frozen_string_literal: true

require 'spec_helper'

RSpec.describe Gamechanger::CLI do
  # Minimal smoke tests — the CLI delegates to Client and Storage,
  # both of which are tested separately.

  describe '#version' do
    it 'prints the gem version' do
      expect { described_class.start(['version']) }.to output(/gamechanger #{Gamechanger::VERSION}/).to_stdout
    end
  end

  describe '#availability' do
    context 'when not configured (no credentials)' do
      it 'does NOT exit 4 — availability is cache-only' do
        # With an empty in-memory store, next_scheduled_game returns nil → exits 1, not 4
        allow(Gamechanger::Storage).to receive(:new).and_return(
          instance_double(Gamechanger::Storage, next_scheduled_game: nil, close: nil)
        )
        expect { described_class.start(['availability']) }.to raise_error(SystemExit) do |e|
          expect(e.status).to eq(1)
        end
      end
    end

    context 'when no future games in cache' do
      it 'exits 1 with sync hint' do
        allow(Gamechanger::Storage).to receive(:new).and_return(
          instance_double(Gamechanger::Storage, next_scheduled_game: nil, close: nil)
        )
        expect { described_class.start(['availability']) }
          .to output(/gamechanger refresh/).to_stdout
          .and raise_error(SystemExit) { |e| expect(e.status).to eq(1) }
      end
    end

    context 'with an invalid --date' do
      it 'exits 1 with format error message' do
        expect { described_class.start(['availability', '--date', 'not-a-date']) }
          .to output(/Invalid date/).to_stdout
          .and raise_error(SystemExit) { |e| expect(e.status).to eq(1) }
      end
    end
  end

  describe '#plan' do
    context 'when no upcoming games in cache (no --from and no --games)' do
      it 'exits 1 with sync hint' do
        allow(Gamechanger::Storage).to receive(:new).and_return(
          instance_double(Gamechanger::Storage, next_scheduled_game: nil, close: nil)
        )
        expect { described_class.start(['plan']) }
          .to output(/gamechanger refresh/).to_stdout
          .and raise_error(SystemExit) { |e| expect(e.status).to eq(1) }
      end
    end

    context 'with --from and no games in that range' do
      it 'exits 1 with helpful message' do
        allow(Gamechanger::Storage).to receive(:new).and_return(
          instance_double(Gamechanger::Storage, scheduled_games_between: [], close: nil)
        )
        expect { described_class.start(['plan', '--from', '2026-03-21']) }
          .to output(/No scheduled games found/).to_stdout
          .and raise_error(SystemExit) { |e| expect(e.status).to eq(1) }
      end
    end

    context 'with an invalid --from date' do
      it 'exits 1 with format error' do
        expect { described_class.start(['plan', '--from', 'not-a-date']) }
          .to output(/Invalid --from date/).to_stdout
          .and raise_error(SystemExit) { |e| expect(e.status).to eq(1) }
      end
    end

    context 'with an invalid date in --games' do
      it 'exits 1 with format error' do
        expect { described_class.start(['plan', '--games', 'bad-date']) }
          .to output(/Invalid date/).to_stdout
          .and raise_error(SystemExit) { |e| expect(e.status).to eq(1) }
      end
    end

    context 'when cache has games but no pitcher data' do
      it 'exits 1 with sync hint' do
        storage_double = instance_double(
          Gamechanger::Storage,
          scheduled_games_between: [{ 'game_date' => '2026-03-21', 'opponent' => 'Eagles' }],
          pitcher_availability_data: [],
          next_scheduled_game: nil,
          close: nil
        )
        allow(Gamechanger::Storage).to receive(:new).and_return(storage_double)
        expect { described_class.start(['plan', '--from', '2026-03-21']) }
          .to output(/No pitcher data in cache/).to_stdout
          .and raise_error(SystemExit) { |e| expect(e.status).to eq(1) }
      end
    end
  end

  describe '#hitting' do
    context 'when no batting data in cache' do
      it 'exits 1 with sync hint' do
        allow(Gamechanger::Storage).to receive(:new).and_return(
          instance_double(Gamechanger::Storage, season_batting_summary: [], close: nil)
        )
        expect { described_class.start(['hitting']) }
          .to output(/gamechanger refresh/).to_stdout
          .and raise_error(SystemExit) { |e| expect(e.status).to eq(1) }
      end
    end
  end

  describe '#lineup' do
    context 'when no future games in cache (no --date)' do
      it 'exits 1 with sync hint' do
        allow(Gamechanger::Storage).to receive(:new).and_return(
          instance_double(Gamechanger::Storage, next_scheduled_game: nil, close: nil)
        )
        expect { described_class.start(['lineup']) }
          .to output(/gamechanger refresh/).to_stdout
          .and raise_error(SystemExit) { |e| expect(e.status).to eq(1) }
      end
    end

    context 'with an invalid --date' do
      it 'exits 1 with format error message' do
        expect { described_class.start(['lineup', '--date', 'not-a-date']) }
          .to output(/Invalid date/).to_stdout
          .and raise_error(SystemExit) { |e| expect(e.status).to eq(1) }
      end
    end
  end

  describe '#equity' do
    context 'when no player data in cache' do
      it 'exits 1 with sync hint' do
        allow(Gamechanger::Storage).to receive(:new).and_return(
          instance_double(Gamechanger::Storage, player_participation: [], close: nil)
        )
        expect { described_class.start(['equity']) }
          .to output(/gamechanger refresh/).to_stdout
          .and raise_error(SystemExit) { |e| expect(e.status).to eq(1) }
      end
    end

    context 'when not configured (no credentials)' do
      it 'does NOT exit 4 — equity is cache-only' do
        allow(Gamechanger::Storage).to receive(:new).and_return(
          instance_double(Gamechanger::Storage, player_participation: [], close: nil)
        )
        expect { described_class.start(['equity']) }.to raise_error(SystemExit) do |e|
          expect(e.status).to eq(1)  # 1 (empty cache), not 4 (auth)
        end
      end
    end
  end

  describe '#progress' do
    context 'when no player data in cache' do
      it 'exits 1 with sync hint' do
        allow(Gamechanger::Storage).to receive(:new).and_return(
          instance_double(Gamechanger::Storage, all_player_development_summary: [], close: nil)
        )
        expect { described_class.start(['progress']) }
          .to output(/gamechanger refresh/).to_stdout
          .and raise_error(SystemExit) { |e| expect(e.status).to eq(1) }
      end
    end

    context 'when not configured (no credentials)' do
      it 'does NOT exit 4 — progress is cache-only' do
        allow(Gamechanger::Storage).to receive(:new).and_return(
          instance_double(Gamechanger::Storage, all_player_development_summary: [], close: nil)
        )
        expect { described_class.start(['progress']) }.to raise_error(SystemExit) do |e|
          expect(e.status).to eq(1)  # 1 (empty cache), not 4 (auth)
        end
      end
    end

    context 'with --player and no matching data' do
      it 'exits 1 with player-not-found message' do
        allow(Gamechanger::Storage).to receive(:new).and_return(
          instance_double(Gamechanger::Storage, all_player_development_summary: [], close: nil)
        )
        expect { described_class.start(['progress', '--player', 'Unknown']) }
          .to output(/No data found for 'Unknown'/).to_stdout
          .and raise_error(SystemExit) { |e| expect(e.status).to eq(1) }
      end
    end
  end

  describe '#brief' do
    context 'when no future games in cache (no --date)' do
      it 'exits 1 with sync hint' do
        allow(Gamechanger::Storage).to receive(:new).and_return(
          instance_double(Gamechanger::Storage, next_scheduled_game: nil, close: nil)
        )
        expect { described_class.start(['brief']) }
          .to output(/gamechanger refresh/).to_stdout
          .and raise_error(SystemExit) { |e| expect(e.status).to eq(1) }
      end
    end

    context 'with an invalid --date' do
      it 'exits 1 with format error message' do
        expect { described_class.start(['brief', '--date', 'not-a-date']) }
          .to output(/Invalid date/).to_stdout
          .and raise_error(SystemExit) { |e| expect(e.status).to eq(1) }
      end
    end

    context 'when not configured (no credentials)' do
      it 'does NOT exit 4 — brief is cache-only' do
        # With an empty cache, next_scheduled_game returns nil → exits 1, not 4
        allow(Gamechanger::Storage).to receive(:new).and_return(
          instance_double(Gamechanger::Storage, next_scheduled_game: nil, close: nil)
        )
        expect { described_class.start(['brief']) }.to raise_error(SystemExit) do |e|
          expect(e.status).to eq(1)  # 1 (empty cache), not 4 (auth)
        end
      end
    end
  end

  describe '#refresh' do
    context 'when not configured' do
      before do
        allow(Gamechanger::Config).to receive(:new).and_return(
          instance_double(Gamechanger::Config, configured?: false)
        )
      end

      it 'exits with code 4' do
        expect { described_class.start(['refresh']) }.to raise_error(SystemExit) do |e|
          expect(e.status).to eq(4)
        end
      end
    end

    context 'when authentication fails' do
      before do
        allow(Gamechanger::Config).to receive(:new).and_return(
          instance_double(Gamechanger::Config, configured?: true, season: Date.today.year)
        )
        allow(Gamechanger::Storage).to receive(:new).and_return(
          instance_double(Gamechanger::Storage, close: nil)
        )
        allow(Gamechanger::Syncer).to receive(:new).and_return(
          instance_double(Gamechanger::Syncer).tap do |s|
            allow(s).to receive(:run).and_raise(Gamechanger::AuthError, 'bad token')
          end
        )
      end

      it 'exits with code 2' do
        expect { described_class.start(['refresh']) }
          .to output(/Authentication error/).to_stdout
          .and raise_error(SystemExit) { |e| expect(e.status).to eq(2) }
      end
    end

    context 'happy path' do
      include_context 'seeded storage'

      it 'prints a count summary' do
        allow(Gamechanger::Syncer).to receive(:new).and_return(
          instance_double(Gamechanger::Syncer,
                          run: Gamechanger::SyncResult.new(3, 8, 45))
        )
        expect { described_class.start(['refresh']) }
          .to output(/3 games.*8 outings.*45 at-bats/i).to_stdout
      end

      it 'uses force: true on the syncer' do
        syncer = instance_double(Gamechanger::Syncer,
                                 run: Gamechanger::SyncResult.new(0, 0, 0))
        allow(Gamechanger::Syncer).to receive(:new).and_return(syncer)
        described_class.start(['refresh'])
        expect(syncer).to have_received(:run).with(force: true)
      end
    end
  end

  describe '#pitches' do
    context 'when not configured' do
      before do
        allow(Gamechanger::Config).to receive(:new).and_return(
          instance_double(Gamechanger::Config, configured?: false)
        )
      end

      it 'exits with code 4' do
        expect { described_class.start(['pitches']) }.to raise_error(SystemExit) do |e|
          expect(e.status).to eq(4)
        end
      end
    end

    context 'happy path — season summary' do
      include_context 'seeded storage'

      it 'prints the pitcher table header and exits 0' do
        expect { described_class.start(['pitches']) }
          .to output(/Pitcher/).to_stdout
      end
    end
  end

  describe '#hitting' do
    context 'happy path — season batting summary' do
      include_context 'seeded storage'

      it 'prints the batting table header and exits 0' do
        expect { described_class.start(['hitting']) }
          .to output(/Batter/).to_stdout
      end
    end
  end

  describe '#availability' do
    context 'happy path — with a scheduled game in cache' do
      include_context 'seeded storage'

      it 'prints pitcher names and availability status' do
        expect { described_class.start(['availability']) }
          .to output(/Alice Smith/).to_stdout
      end
    end
  end

  describe '#brief' do
    context 'happy path — with a scheduled game in cache' do
      include_context 'seeded storage'

      it 'prints the Pre-Game Brief header' do
        expect { described_class.start(['brief']) }
          .to output(/Pre-Game Brief/).to_stdout
      end
    end
  end

  describe '#plan' do
    context 'happy path — with --games flag' do
      include_context 'seeded storage'

      it 'prints the Tournament Plan header' do
        future = (Date.today + 3).to_s
        expect { described_class.start(['plan', '--games', future]) }
          .to output(/Tournament Plan/).to_stdout
      end
    end
  end
end
