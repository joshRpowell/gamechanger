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
          .to output(/Authentication error/).to_stderr
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

    context 'with --format json' do
      include_context 'seeded storage'

      it 'outputs JSON with games, outings, and at_bats keys' do
        allow(Gamechanger::Syncer).to receive(:new).and_return(
          instance_double(Gamechanger::Syncer,
                          run: Gamechanger::SyncResult.new(2, 5, 30))
        )
        expect { described_class.start(['refresh', '--format', 'json']) }
          .to output(/"games":2.*"outings":5.*"at_bats":30/m).to_stdout
      end

      it 'outputs valid JSON' do
        allow(Gamechanger::Syncer).to receive(:new).and_return(
          instance_double(Gamechanger::Syncer,
                          run: Gamechanger::SyncResult.new(1, 3, 10))
        )
        expect { described_class.start(['refresh', '--format', 'json']) }
          .to output(/\{.*\}/m).to_stdout
      end

      it 'does not output human text when --format json is used' do
        allow(Gamechanger::Syncer).to receive(:new).and_return(
          instance_double(Gamechanger::Syncer,
                          run: Gamechanger::SyncResult.new(1, 3, 10))
        )
        expect { described_class.start(['refresh', '--format', 'json']) }
          .not_to output(/\d+ game/).to_stdout
      end
    end

    context 'with default format (human)' do
      include_context 'seeded storage'

      it 'outputs human-readable text by default' do
        allow(Gamechanger::Syncer).to receive(:new).and_return(
          instance_double(Gamechanger::Syncer,
                          run: Gamechanger::SyncResult.new(1, 2, 10))
        )
        expect { described_class.start(['refresh']) }
          .to output(/1 game,/).to_stdout
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

  # ─── setup error paths ───────────────────────────────────────────────────

  describe '#setup' do
    let(:cfg_double) { instance_double(Gamechanger::Config, save: nil, clear_token: nil, email: nil, password_op_ref: nil) }
    let(:client_double) { instance_double(Gamechanger::Client) }

    before do
      # Commands::Setup calls shell.ask, so stub on Thor::Shell::Basic as well.
      allow_any_instance_of(described_class).to receive(:ask)
        .with('Email:').and_return('coach@example.com')
      allow_any_instance_of(described_class).to receive(:ask)
        .with('Password:', echo: false).and_return('secret')
      allow_any_instance_of(Thor::Shell::Basic).to receive(:ask)
        .with('Email:').and_return('coach@example.com')
      allow_any_instance_of(Thor::Shell::Basic).to receive(:ask)
        .with('Password:', echo: false).and_return('secret')
      allow(Gamechanger::Config).to receive(:new).and_return(cfg_double)
      allow(Gamechanger::Client).to receive(:new).and_return(client_double)
    end

    context 'when authentication fails (AuthError)' do
      before do
        allow(client_double).to receive(:authenticate)
          .and_raise(Gamechanger::AuthError, 'bad credentials')
      end

      it 'exits 2 with authentication failed message' do
        expect { described_class.start(['setup']) }
          .to output(/Authentication failed/).to_stderr
          .and raise_error(SystemExit) { |e| expect(e.status).to eq(2) }
      end
    end

    context 'when network fails during authentication (NetworkError)' do
      before do
        allow(client_double).to receive(:authenticate)
          .and_raise(Gamechanger::NetworkError, 'connection refused')
      end

      it 'exits 3 with network error message' do
        expect { described_class.start(['setup']) }
          .to output(/Network error/).to_stderr
          .and raise_error(SystemExit) { |e| expect(e.status).to eq(3) }
      end
    end

    context 'when teams API returns unexpected shape (APIShapeError)' do
      before do
        allow(client_double).to receive(:authenticate)
        allow(client_double).to receive(:teams)
          .and_raise(Gamechanger::APIShapeError, 'unexpected shape')
      end

      it 'warns and continues with nil team info' do
        expect { described_class.start(['setup']) }
          .to output(/Could not auto-detect team/).to_stderr
      end
    end

    context 'when teams returned as Hash with teams key' do
      before do
        allow(client_double).to receive(:authenticate)
        allow(client_double).to receive(:teams)
          .and_return({ 'teams' => [{ 'id' => 'abc', 'name' => 'Red Sox', 'slug' => 'rsox' }] })
      end

      it 'extracts team from hash and prints team name' do
        expect { described_class.start(['setup']) }
          .to output(/Red Sox/).to_stdout
      end
    end

    context 'when teams returned as Hash with data key' do
      before do
        allow(client_double).to receive(:authenticate)
        allow(client_double).to receive(:teams)
          .and_return({ 'data' => [{ 'id' => 'xyz', 'name' => 'Cubs', 'slug' => 'cubs' }] })
      end

      it 'extracts team from data key and prints team name' do
        expect { described_class.start(['setup']) }
          .to output(/Cubs/).to_stdout
      end
    end

    context 'when teams response is neither Array nor Hash' do
      before do
        allow_any_instance_of(described_class).to receive(:ask)
          .with(/slug/).and_return('manual-team')
        allow_any_instance_of(Thor::Shell::Basic).to receive(:ask)
          .with(/slug/).and_return('manual-team')
        allow(client_double).to receive(:authenticate)
        allow(client_double).to receive(:teams).and_return(42)
      end

      it 'treats unknown shape as empty and asks for manual slug' do
        expect { described_class.start(['setup']) }
          .to output(/No teams found|Could not auto-detect|slug/).to_stdout
      end
    end

    context 'when teams list is empty' do
      before do
        allow_any_instance_of(described_class).to receive(:ask)
          .with(/slug/).and_return('manual-slug')
        allow_any_instance_of(Thor::Shell::Basic).to receive(:ask)
          .with(/slug/).and_return('manual-slug')
        allow(client_double).to receive(:authenticate)
        allow(client_double).to receive(:teams).and_return([])
      end

      it 'warns about no teams found and asks for manual slug' do
        expect { described_class.start(['setup']) }
          .to output(/No teams found/).to_stdout
      end
    end

    context 'when multiple teams found' do
      before do
        allow_any_instance_of(described_class).to receive(:ask)
          .with(/Which team/).and_return('1')
        allow_any_instance_of(Thor::Shell::Basic).to receive(:ask)
          .with(/Which team/).and_return('1')
        allow(client_double).to receive(:authenticate)
        allow(client_double).to receive(:teams).and_return([
          { 'id' => 'abc', 'name' => 'Red Sox', 'slug' => 'rsox' },
          { 'id' => 'def', 'name' => 'Cubs', 'slug' => 'cubs' }
        ])
      end

      it 'lists teams and asks for selection' do
        expect { described_class.start(['setup']) }
          .to output(/Multiple teams found/).to_stdout
      end
    end

    context 'when single team has no slug field' do
      before do
        allow_any_instance_of(described_class).to receive(:ask)
          .with(/slug/).and_return('my-slug')
        allow_any_instance_of(Thor::Shell::Basic).to receive(:ask)
          .with(/slug/).and_return('my-slug')
        allow(client_double).to receive(:authenticate)
        allow(client_double).to receive(:teams)
          .and_return([{ 'id' => 'abc', 'name' => 'Red Sox' }])
      end

      it 'asks for manual slug when team has no slug' do
        expect { described_class.start(['setup']) }
          .to output(/Could not auto-detect team slug/).to_stdout
      end
    end

    context 'non-interactive mode via CLI flags' do
      let(:client_double) do
        instance_double(
          Gamechanger::Client,
          authenticate: 'token-abc',
          teams: [{ 'id' => 'team-1', 'name' => 'Eagles', 'slug' => 'eagles' }]
        )
      end

      before do
        allow(Gamechanger::Client).to receive(:new).and_return(client_double)
      end

      it 'uses --email flag instead of interactive prompt' do
        # ask should NOT be called for email when flag is provided
        expect_any_instance_of(described_class).not_to receive(:ask).with('Email:')
        expect { described_class.start(['setup', '--email', 'agent@ci.com', '--password', 'secret']) }
          .to output(/Eagles/).to_stdout
      end

      it 'uses --password flag instead of interactive prompt' do
        expect_any_instance_of(described_class).not_to receive(:ask).with('Password:', echo: false)
        expect { described_class.start(['setup', '--email', 'agent@ci.com', '--password', 'secret']) }
          .to output(/Configuration saved/).to_stdout
      end

      it 'uses --team-slug flag to skip slug prompt when team has no slug' do
        allow(client_double).to receive(:teams)
          .and_return([{ 'id' => 'team-1', 'name' => 'Eagles' }])
        expect_any_instance_of(described_class).not_to receive(:ask).with(/slug/)
        expect { described_class.start(['setup', '--email', 'a@b.com', '--password', 'pw', '--team-slug', 'my-slug']) }
          .to output(/Configuration saved/).to_stdout
      end
    end

    context 'non-interactive mode via environment variables' do
      let(:client_double) do
        instance_double(
          Gamechanger::Client,
          authenticate: 'token-abc',
          teams: [{ 'id' => 'team-1', 'name' => 'Eagles', 'slug' => 'eagles' }]
        )
      end

      before do
        allow(Gamechanger::Client).to receive(:new).and_return(client_double)
        stub_const('ENV', ENV.to_hash.merge(
          'GAMECHANGER_EMAIL'    => 'env@ci.com',
          'GAMECHANGER_PASSWORD' => 'envpass'
        ))
      end

      it 'uses GAMECHANGER_EMAIL env var instead of interactive prompt' do
        expect_any_instance_of(described_class).not_to receive(:ask).with('Email:')
        expect { described_class.start(['setup']) }
          .to output(/Eagles/).to_stdout
      end

      it 'uses GAMECHANGER_PASSWORD env var instead of interactive prompt' do
        expect_any_instance_of(described_class).not_to receive(:ask).with('Password:', echo: false)
        expect { described_class.start(['setup']) }
          .to output(/Configuration saved/).to_stdout
      end
    end
  end

  # ─── pitches error paths ─────────────────────────────────────────────────

  describe '#pitches (error paths)' do
    let(:cfg_double) do
      instance_double(Gamechanger::Config, configured?: true, season: Date.today.year)
    end
    let(:storage_double) { instance_double(Gamechanger::Storage, close: nil) }
    let(:syncer_double) { instance_double(Gamechanger::Syncer) }

    before do
      allow(Gamechanger::Config).to receive(:new).and_return(cfg_double)
      allow(Gamechanger::Storage).to receive(:new).and_return(storage_double)
      allow(Gamechanger::Syncer).to receive(:new).and_return(syncer_double)
    end

    it 'exits 2 on AuthError' do
      allow(syncer_double).to receive(:run).and_raise(Gamechanger::AuthError, 'expired')
      expect { described_class.start(['pitches']) }
        .to output(/Authentication error/).to_stderr
        .and raise_error(SystemExit) { |e| expect(e.status).to eq(2) }
    end

    it 'exits 3 on NetworkError' do
      allow(syncer_double).to receive(:run).and_raise(Gamechanger::NetworkError, 'timeout')
      expect { described_class.start(['pitches']) }
        .to output(/Network error/).to_stderr
        .and raise_error(SystemExit) { |e| expect(e.status).to eq(3) }
    end

    it 'exits 4 on ConfigError' do
      allow(syncer_double).to receive(:run).and_raise(Gamechanger::ConfigError, 'bad config')
      expect { described_class.start(['pitches']) }
        .to output(/Configuration error/).to_stderr
        .and raise_error(SystemExit) { |e| expect(e.status).to eq(4) }
    end

    it 'exits 3 on APIShapeError' do
      allow(syncer_double).to receive(:run).and_raise(Gamechanger::APIShapeError, 'changed')
      expect { described_class.start(['pitches']) }
        .to output(/unexpected format/).to_stderr
        .and raise_error(SystemExit) { |e| expect(e.status).to eq(3) }
    end

    it 'exits 1 on StorageError' do
      allow(syncer_double).to receive(:run).and_raise(Gamechanger::StorageError, 'db error')
      expect { described_class.start(['pitches']) }
        .to output(/Cache read failed/).to_stderr
        .and raise_error(SystemExit) { |e| expect(e.status).to eq(1) }
    end

    context 'with --game option' do
      context 'with invalid date format' do
        it 'exits 1 with date format error' do
          allow(syncer_double).to receive(:run)
          allow(storage_double).to receive(:game_by_date)
          expect { described_class.start(['pitches', '--game', 'not-a-date']) }
            .to output(/Invalid date format/).to_stdout
            .and raise_error(SystemExit) { |e| expect(e.status).to eq(1) }
        end
      end

      context 'when no game found for date' do
        it 'exits 1 with no game message' do
          allow(syncer_double).to receive(:run)
          allow(storage_double).to receive(:game_by_date).and_return([])
          expect { described_class.start(['pitches', '--game', '2026-01-01']) }
            .to output(/No game found/).to_stdout
            .and raise_error(SystemExit) { |e| expect(e.status).to eq(1) }
        end
      end

      context 'when multiple games on date with invalid game number' do
        let(:game_row) { { 'game_date' => '2026-03-19', 'opponent' => 'Eagles', 'status' => 'final', 'pitcher_stats' => [] } }

        it 'exits 1 with game number guidance' do
          allow(syncer_double).to receive(:run)
          allow(storage_double).to receive(:game_by_date).and_return([game_row, game_row])
          expect { described_class.start(['pitches', '--game', '2026-03-19', '--game-number', '5']) }
            .to output(/games found on/).to_stdout
            .and raise_error(SystemExit) { |e| expect(e.status).to eq(1) }
        end
      end

      context 'when single game found' do
        it 'prints game breakdown' do
          past = (Date.today - 7).to_s
          game_row = { 'game_date' => past, 'opponent' => 'Hawks', 'home_away' => 'away',
                       'status' => 'final', 'pitcher_stats' => [
                         { 'pitcher_name' => 'Alice', 'pitches_thrown' => 55,
                           'strikes_thrown' => 35, 'innings_pitched' => 3.0 }
                       ] }
          allow(syncer_double).to receive(:run)
          allow(storage_double).to receive(:game_by_date).and_return([game_row])
          expect { described_class.start(['pitches', '--game', past]) }
            .to output(/Alice|Hawks/i).to_stdout
        end
      end
    end

    context 'with --pitcher option' do
      context 'when pitcher not found' do
        it 'exits 1 with not found message' do
          allow(syncer_double).to receive(:run)
          allow(storage_double).to receive(:pitcher_games).and_return([])
          expect { described_class.start(['pitches', '--pitcher', 'Zara']) }
            .to output(/No pitcher matching/).to_stdout
            .and raise_error(SystemExit) { |e| expect(e.status).to eq(1) }
        end
      end

      context 'when pitcher name is ambiguous (multiple matches)' do
        it 'exits 1 with ambiguous name message' do
          allow(syncer_double).to receive(:run)
          allow(storage_double).to receive(:pitcher_games).and_return(['Alice Smith', 'Alice Jones'])
          expect { described_class.start(['pitches', '--pitcher', 'Alice']) }
            .to output(/Ambiguous name/).to_stdout
            .and raise_error(SystemExit) { |e| expect(e.status).to eq(1) }
        end
      end

      context 'with valid single pitcher match' do
        it 'prints pitcher game breakdown' do
          game_row = { 'pitcher_name' => 'Alice Smith', 'game_date' => '2026-03-12',
                       'opponent' => 'Eagles', 'home_away' => 'home',
                       'status' => 'final', 'pitches_thrown' => 55, 'strikes_thrown' => 35,
                       'innings_pitched' => 3.0 }
          allow(syncer_double).to receive(:run)
          allow(storage_double).to receive(:pitcher_games).and_return([game_row])
          expect { described_class.start(['pitches', '--pitcher', 'Alice Smith']) }
            .to output(/Alice Smith/).to_stdout
        end
      end
    end
  end

  # ─── refresh error paths ──────────────────────────────────────────────────

  describe '#refresh (error paths)' do
    let(:cfg_double) do
      instance_double(Gamechanger::Config, configured?: true, season: Date.today.year)
    end
    let(:storage_double) { instance_double(Gamechanger::Storage, close: nil) }
    let(:syncer_double) { instance_double(Gamechanger::Syncer) }

    before do
      allow(Gamechanger::Config).to receive(:new).and_return(cfg_double)
      allow(Gamechanger::Storage).to receive(:new).and_return(storage_double)
      allow(Gamechanger::Syncer).to receive(:new).and_return(syncer_double)
    end

    it 'exits 3 on NetworkError' do
      allow(syncer_double).to receive(:run).and_raise(Gamechanger::NetworkError, 'timeout')
      expect { described_class.start(['refresh']) }
        .to output(/Network error/).to_stderr
        .and raise_error(SystemExit) { |e| expect(e.status).to eq(3) }
    end

    it 'exits 4 on ConfigError' do
      allow(syncer_double).to receive(:run).and_raise(Gamechanger::ConfigError, 'bad config')
      expect { described_class.start(['refresh']) }
        .to output(/Configuration error/).to_stderr
        .and raise_error(SystemExit) { |e| expect(e.status).to eq(4) }
    end

    it 'exits 3 on APIShapeError' do
      allow(syncer_double).to receive(:run).and_raise(Gamechanger::APIShapeError, 'changed')
      expect { described_class.start(['refresh']) }
        .to output(/unexpected format/).to_stderr
        .and raise_error(SystemExit) { |e| expect(e.status).to eq(3) }
    end

    it 'exits 1 on StorageError' do
      allow(syncer_double).to receive(:run).and_raise(Gamechanger::StorageError, 'db gone')
      expect { described_class.start(['refresh']) }
        .to output(/Cache read failed/).to_stderr
        .and raise_error(SystemExit) { |e| expect(e.status).to eq(1) }
    end
  end

  # ─── StorageError rescues ─────────────────────────────────────────────────

  describe 'StorageError rescue paths' do
    let(:bad_storage) do
      instance_double(Gamechanger::Storage, close: nil).tap do |s|
        allow(s).to receive(:next_scheduled_game).and_raise(Gamechanger::StorageError, 'db bad')
        allow(s).to receive(:pitcher_availability_data).and_raise(Gamechanger::StorageError, 'db bad')
        allow(s).to receive(:batter_lineup_data).and_raise(Gamechanger::StorageError, 'db bad')
        allow(s).to receive(:player_participation).and_raise(Gamechanger::StorageError, 'db bad')
        allow(s).to receive(:all_player_development_summary).and_raise(Gamechanger::StorageError, 'db bad')
        allow(s).to receive(:season_batting_summary).and_raise(Gamechanger::StorageError, 'db bad')
      end
    end

    before do
      allow(Gamechanger::Storage).to receive(:new).and_return(bad_storage)
    end

    it 'availability exits 1 on StorageError' do
      future = (Date.today + 3).to_s
      expect { described_class.start(['availability', '--date', future]) }
        .to output(/Cache read failed/).to_stderr
        .and raise_error(SystemExit) { |e| expect(e.status).to eq(1) }
    end

    it 'lineup exits 1 on StorageError' do
      future = (Date.today + 3).to_s
      expect { described_class.start(['lineup', '--date', future]) }
        .to output(/Cache read failed/).to_stderr
        .and raise_error(SystemExit) { |e| expect(e.status).to eq(1) }
    end

    it 'equity exits 1 on StorageError' do
      expect { described_class.start(['equity']) }
        .to output(/Cache read failed/).to_stderr
        .and raise_error(SystemExit) { |e| expect(e.status).to eq(1) }
    end

    it 'progress exits 1 on StorageError' do
      expect { described_class.start(['progress']) }
        .to output(/Cache read failed/).to_stderr
        .and raise_error(SystemExit) { |e| expect(e.status).to eq(1) }
    end

    it 'hitting exits 1 on StorageError' do
      expect { described_class.start(['hitting']) }
        .to output(/Cache read failed/).to_stderr
        .and raise_error(SystemExit) { |e| expect(e.status).to eq(1) }
    end
  end

  describe '#plan and #brief StorageError' do
    it 'plan exits 1 on StorageError' do
      plan_bad = instance_double(Gamechanger::Storage, close: nil).tap do |s|
        allow(s).to receive(:next_scheduled_game).and_raise(Gamechanger::StorageError, 'bad')
      end
      allow(Gamechanger::Storage).to receive(:new).and_return(plan_bad)
      expect { described_class.start(['plan']) }
        .to output(/Cache read failed/).to_stderr
        .and raise_error(SystemExit) { |e| expect(e.status).to eq(1) }
    end

    it 'brief exits 1 on StorageError' do
      brief_bad = instance_double(Gamechanger::Storage, close: nil).tap do |s|
        allow(s).to receive(:next_scheduled_game).and_raise(Gamechanger::StorageError, 'bad')
      end
      allow(Gamechanger::Storage).to receive(:new).and_return(brief_bad)
      expect { described_class.start(['brief']) }
        .to output(/Cache read failed/).to_stderr
        .and raise_error(SystemExit) { |e| expect(e.status).to eq(1) }
    end
  end

  # ─── format flag ─────────────────────────────────────────────────────────

  describe '--format flag' do
    context 'with --format json' do
      include_context 'seeded storage'

      it 'outputs JSON format for pitches' do
        expect { described_class.start(['pitches', '--format', 'json']) }
          .to output(/\[|\{/).to_stdout
      end
    end

    context 'with --format markdown' do
      include_context 'seeded storage'

      it 'outputs Markdown format for pitches' do
        expect { described_class.start(['pitches', '--format', 'markdown']) }
          .to output(/\|/).to_stdout
      end
    end
  end

  # ─── hitting with --player ────────────────────────────────────────────────

  describe '#hitting with --player' do
    context 'when player not found' do
      include_context 'seeded storage'

      it 'exits 1 with not found message' do
        expect { described_class.start(['hitting', '--player', 'Zara']) }
          .to output(/No batter matching/).to_stdout
          .and raise_error(SystemExit) { |e| expect(e.status).to eq(1) }
      end
    end

    context 'when player name is ambiguous' do
      let(:bad_storage) do
        instance_double(Gamechanger::Storage, close: nil).tap do |s|
          allow(s).to receive(:batter_games).and_return(['Bob Jones', 'Bob Smith'])
        end
      end

      before { allow(Gamechanger::Storage).to receive(:new).and_return(bad_storage) }

      it 'exits 1 with ambiguous name message' do
        expect { described_class.start(['hitting', '--player', 'Bob']) }
          .to output(/Ambiguous name/).to_stdout
          .and raise_error(SystemExit) { |e| expect(e.status).to eq(1) }
      end
    end

    context 'happy path with single batter match' do
      include_context 'seeded storage'

      it 'prints batter game-by-game breakdown' do
        expect { described_class.start(['hitting', '--player', 'Bob']) }
          .to output(/Bob/).to_stdout
      end
    end
  end

  # ─── lineup happy path ────────────────────────────────────────────────────

  describe '#lineup' do
    context 'happy path — with a scheduled game in cache' do
      include_context 'seeded storage'

      it 'prints the lineup section' do
        expect { described_class.start(['lineup']) }
          .to output(/Batter|Lineup|OBP/i).to_stdout
      end
    end
  end

  # ─── equity happy path ────────────────────────────────────────────────────

  describe '#equity' do
    context 'happy path — with player data in cache' do
      include_context 'seeded storage'

      it 'prints player participation table' do
        expect { described_class.start(['equity']) }
          .to output(/Bob|Carol|Player/i).to_stdout
      end
    end
  end

  # ─── progress with --pitcher option ──────────────────────────────────────

  describe '#progress' do
    context 'with --pitcher option for single pitcher arc' do
      it 'prints pitcher arc for Alice' do
        storage_double = instance_double(Gamechanger::Storage, close: nil)
        allow(Gamechanger::Storage).to receive(:new).and_return(storage_double)
        allow(storage_double).to receive(:all_player_development_summary).and_return([
          { 'player_name' => 'Alice Smith', 'total_pitches' => 120 }
        ])
        allow(storage_double).to receive(:player_pitching_arc).and_return([
          { 'pitcher_name' => 'Alice Smith', 'game_date' => '2026-03-12',
            'pitches_thrown' => 60, 'strikes_thrown' => 40, 'innings_pitched' => 3.0 }
        ])
        allow(storage_double).to receive(:player_batting_arc).and_return([])
        expect { described_class.start(['progress', '--pitcher', 'Alice']) }
          .to output(/Alice/).to_stdout
      end
    end

    context 'with --pitcher and no matching data' do
      it 'exits 1 with not found message' do
        storage_double = instance_double(Gamechanger::Storage,
                                         all_player_development_summary: [], close: nil)
        allow(Gamechanger::Storage).to receive(:new).and_return(storage_double)
        expect { described_class.start(['progress', '--pitcher', 'Zara']) }
          .to output(/No data found for 'Zara'/).to_stdout
          .and raise_error(SystemExit) { |e| expect(e.status).to eq(1) }
      end
    end
  end

  # ─── plan with --to and --next-game options ───────────────────────────────

  describe '#plan' do
    context 'with invalid --to date' do
      it 'exits 1 with format error' do
        expect { described_class.start(['plan', '--from', '2026-03-21', '--to', 'bad-date']) }
          .to output(/Invalid --to date/).to_stdout
          .and raise_error(SystemExit) { |e| expect(e.status).to eq(1) }
      end
    end

    context 'with invalid --next-game date' do
      it 'exits 1 with format error' do
        next_game_date = (Date.today + 7).to_s
        pitcher_row = { 'pitcher_name' => 'Alice', 'last_outing' => '2026-03-01',
                        'last_pitches' => 55, 'seven_day_total' => 55 }
        storage_double = instance_double(Gamechanger::Storage, close: nil)
        allow(Gamechanger::Config).to receive(:new).and_return(
          instance_double(Gamechanger::Config, season: 2026, configured?: true,
                          email: 'a@b.com', password: 'pass',
                          team_id: nil, team_slug: nil, cached_token: nil, device_id: 'abc')
        )
        allow(Gamechanger::Storage).to receive(:new).and_return(storage_double)
        allow(storage_double).to receive(:pitcher_availability_data).and_return([pitcher_row])
        allow(storage_double).to receive(:next_scheduled_game).and_return(nil)
        planner_double = instance_double(Gamechanger::TournamentPlanner,
                                         assignments: [], projections: [])
        allow(Gamechanger::TournamentPlanner).to receive(:new).and_return(planner_double)
        expect { described_class.start(['plan', '--games', next_game_date, '--next-game', 'bad-date']) }
          .to output(/Invalid --next-game date/).to_stdout
          .and raise_error(SystemExit) { |e| expect(e.status).to eq(1) }
      end
    end

    context 'with no --from/--games (default next scheduled game)' do
      it 'uses next scheduled game when no date options given' do
        game_date = (Date.today + 5).to_s
        next_game = { 'game_date' => game_date, 'opponent' => 'Ravens' }
        # plan exits early with "No pitcher data" because pitcher_availability_data is empty
        storage_double = instance_double(Gamechanger::Storage, close: nil)
        allow(Gamechanger::Config).to receive(:new).and_return(
          instance_double(Gamechanger::Config, season: 2026, configured?: true,
                          email: 'a@b.com', password: 'pass',
                          team_id: nil, team_slug: nil, cached_token: nil, device_id: 'abc')
        )
        allow(Gamechanger::Storage).to receive(:new).and_return(storage_double)
        allow(storage_double).to receive(:next_scheduled_game).and_return(next_game)
        allow(storage_double).to receive(:pitcher_availability_data).and_return([])
        expect { described_class.start(['plan']) }
          .to output(/No pitcher data/).to_stdout
          .and raise_error(SystemExit) { |e| expect(e.status).to eq(1) }
      end
    end
  end

  # ─── pitches with valid game_number (multiple games on same date) ─────────

  describe '#pitches' do
    context 'with multiple games and valid game_number' do
      let(:cfg_double) do
        instance_double(Gamechanger::Config,
                        team_id: 'team-123', team_slug: 'slug', email: 'a@b.com',
                        password: 'pass', cached_token: 'tok', device_id: 'abc',
                        season: 2026, configured?: true)
      end
      let(:storage_double) { instance_double(Gamechanger::Storage, close: nil) }
      let(:syncer_double)  { instance_double(Gamechanger::Syncer) }

      before do
        allow(Gamechanger::Config).to receive(:new).and_return(cfg_double)
        allow(Gamechanger::Storage).to receive(:new).and_return(storage_double)
        allow(Gamechanger::Syncer).to receive(:new).and_return(syncer_double)
        allow(syncer_double).to receive(:run)
      end

      it 'selects the correct game when game-number is valid' do
        past = (Date.today - 7).to_s
        game_row = { 'game_date' => past, 'opponent' => 'Hawks', 'home_away' => 'away',
                     'status' => 'final', 'pitcher_stats' => [] }
        allow(storage_double).to receive(:game_by_date).and_return([game_row, game_row])
        expect { described_class.start(['pitches', '--game', past, '--game-number', '1']) }
          .not_to raise_error
      end
    end
  end

  # ─── progress happy path (non-empty rows) ────────────────────────────────

  describe '#progress (happy path)' do
    it 'prints progress table when player data exists' do
      row = {
        'player_name' => 'Jayden', 'first_half_obp' => 0.271, 'second_half_obp' => 0.338,
        'recent_obp' => 0.400, 'total_games_batted' => 12,
        'first_half_strike_pct' => nil, 'second_half_strike_pct' => nil,
        'recent_strike_pct' => nil, 'total_games_pitched' => nil
      }
      storage_double = instance_double(Gamechanger::Storage,
                                       all_player_development_summary: [row], close: nil)
      allow(Gamechanger::Storage).to receive(:new).and_return(storage_double)
      expect { described_class.start(['progress']) }
        .to output(/Jayden/).to_stdout
    end
  end
end
