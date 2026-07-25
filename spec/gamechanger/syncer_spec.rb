# frozen_string_literal: true

require 'spec_helper'

RSpec.describe Gamechanger::Syncer do
  let(:storage) { Gamechanger::Storage.new(data_dir: ':memory:') }

  let(:config) do
    instance_double(
      Gamechanger::Config,
      team_id:      'team-uuid-123',
      team_slug:    'wGP47FexatoQ',
      email:        'test@example.com',
      password:     'secret',
      cached_token: 'gc-token-abc',
      device_id:    'device-hex-123'
    )
  end

  let(:syncer) { described_class.new(config, storage) }

  # ── schedule fixture ────────────────────────────────────────────────────────

  let(:past_game_event) do
    {
      'event' => {
        'id'         => 'game-uuid-1',
        'event_type' => 'game',
        'start'      => { 'datetime' => '2026-03-01T14:00:00Z' },
        'status'     => 'in_progress',   # not 'final' so skip-logic doesn't short-circuit
        'title'      => 'vs Eagles'
      },
      'pregame_data' => {
        'opponent_name' => 'Eagles',
        'home_away'     => 'home'
      }
    }
  end

  let(:future_game_event) do
    {
      'event' => {
        'id'         => 'game-uuid-2',
        'event_type' => 'game',
        'start'      => { 'datetime' => (Date.today + 7).iso8601 + 'T14:00:00Z' },
        'status'     => 'scheduled',
        'title'      => 'vs Hawks'
      },
      'pregame_data' => {
        'opponent_name' => 'Hawks',
        'home_away'     => 'away'
      }
    }
  end

  let(:practice_event) do
    {
      'event' => {
        'id'         => 'practice-uuid-1',
        'event_type' => 'practice',
        'start'      => { 'datetime' => '2026-03-05T10:00:00Z' },
        'status'     => 'completed',
        'title'      => 'Practice'
      },
      'pregame_data' => nil
    }
  end

  # ── boxscore fixture ─────────────────────────────────────────────────────────

  let(:boxscore_response) do
    {
      'wGP47FexatoQ' => {
        'players' => [
          { 'id' => 'p1', 'first_name' => 'Alice', 'last_name' => 'Smith', 'number' => '1' },
          { 'id' => 'p2', 'first_name' => 'Bob',   'last_name' => 'Jones', 'number' => '3' }
        ],
        'groups' => [
          {
            'category' => 'pitching',
            'extra' => [
              { 'stat_name' => '#P', 'stats' => [{ 'player_id' => 'p1', 'value' => 65 }] },
              { 'stat_name' => 'TS', 'stats' => [{ 'player_id' => 'p1', 'value' => 42 }] }
            ],
            'stats' => [
              { 'player_id' => 'p1', 'stats' => { 'IP' => 4.0 } }
            ]
          },
          {
            'category' => 'lineup',
            'stats' => [
              { 'player_id' => 'p2', 'player_text' => '(SS, P)', 'stats' => { 'AB' => 3, 'H' => 2, 'BB' => 0, 'SO' => 1 } }
            ],
            'extra' => [
              { 'stat_name' => '2B', 'stats' => [{ 'player_id' => 'p2', 'value' => 1 }] },
              { 'stat_name' => 'HR', 'stats' => [{ 'player_id' => 'p2', 'value' => 1 }] }
            ]
          }
        ]
      }
    }
  end

  before do
    stub_request(:get, "https://api.team-manager.gc.com/teams/team-uuid-123/schedule?fetch_place_details=true")
      .to_return(status: 200, body: [past_game_event, future_game_event, practice_event].to_json)

    stub_request(:get, "https://api.team-manager.gc.com/game-stream-processing/game-uuid-1/boxscore")
      .to_return(status: 200, body: boxscore_response.to_json)
  end

  # A game the syncer has genuinely finished with: final status *and* cached stats.
  def cache_final_game_with_stats
    storage.upsert_game(
      game_id: 'game-uuid-1', game_date: '2026-03-01',
      opponent: 'Eagles', home_away: 'home', status: 'final'
    )
    storage.upsert_pitcher_stats(
      game_id: 'game-uuid-1',
      stats: [{ pitcher_name: 'Alice Smith', pitches_thrown: 65, strikes_thrown: 42, innings_pitched: 4.0 }]
    )
  end

  describe '#run' do
    context 'when team_id is not configured' do
      let(:config) do
        instance_double(Gamechanger::Config, team_id: nil, team_slug: 'wGP47FexatoQ')
      end

      it 'raises ConfigError' do
        expect { syncer.run }.to raise_error(Gamechanger::ConfigError, /team_id/)
      end
    end

    context 'when team_slug is not configured' do
      let(:config) do
        instance_double(Gamechanger::Config, team_id: 'team-uuid-123', team_slug: nil)
      end

      it 'raises ConfigError' do
        expect { syncer.run }.to raise_error(Gamechanger::ConfigError, /team_slug/)
      end
    end

    context 'with valid config and stubbed API' do
      before { allow(syncer).to receive(:sleep) }

      it 'upserts the past game into storage' do
        syncer.run
        expect(storage.all_games.map { |g| g['game_id'] }).to include('game-uuid-1')
      end

      it 'skips future games' do
        syncer.run
        expect(storage.all_games.map { |g| g['game_id'] }).not_to include('game-uuid-2')
      end

      it 'skips practice events' do
        syncer.run
        expect(storage.all_games.length).to eq(1)
      end

      it 'stores pitcher stats' do
        syncer.run
        rows = storage.season_summary
        expect(rows.length).to eq(1)
        expect(rows.first['pitcher_name']).to eq('Alice Smith')
        expect(rows.first['total_pitches']).to eq(65)
      end

      it 'stores batter stats' do
        syncer.run
        rows = storage.season_batting_summary
        expect(rows.length).to eq(1)
        expect(rows.first['batter_name']).to eq('Bob Jones')
      end

      it 'stores doubles/triples/home_runs from lineup.extra[]' do
        syncer.run
        row = storage.season_batting_summary.first
        # H=2, 2B=1, HR=1 → 1B=0
        expect(row['total_2b']).to eq(1)
        expect(row['total_3b']).to eq(0)
        expect(row['total_hr']).to eq(1)
        expect(row['total_1b']).to eq(0)
      end

      it 'stores fielding positions parsed from player_text' do
        syncer.run
        positions = storage.fielding_positions_most_recent_by_name
        expect(positions['Bob Jones']).to eq(['SS', 'P'])
      end

      it 'does not crash when no players have player_text populated' do
        empty_field_boxscore = boxscore_response.dup
        empty_field_boxscore['wGP47FexatoQ'] = empty_field_boxscore['wGP47FexatoQ'].dup
        empty_field_boxscore['wGP47FexatoQ']['groups'] = empty_field_boxscore['wGP47FexatoQ']['groups'].map do |g|
          next g unless g['category'] == 'lineup'

          g.merge('stats' => g['stats'].map { |s| s.merge('player_text' => '') })
        end
        stub_request(:get, "https://api.team-manager.gc.com/game-stream-processing/game-uuid-1/boxscore")
          .to_return(status: 200, body: empty_field_boxscore.to_json)

        expect { syncer.run }.not_to raise_error
        expect(storage.fielding_positions_most_recent_by_name).to be_empty
      end

      it 'marks games with stats as final' do
        syncer.run
        game = storage.all_games.find { |g| g['game_id'] == 'game-uuid-1' }
        expect(game['status']).to eq('final')
      end

      it 'skips re-fetching final games when force is false' do
        cache_final_game_with_stats
        syncer.run(force: false)
        # game is already final — boxscore should NOT be re-fetched
        expect(WebMock).not_to have_requested(:get, /boxscore/)
      end
    end

    context 'with force: true' do
      before { allow(syncer).to receive(:sleep) }

      it 'clears non-final games before syncing' do
        storage.upsert_game(
          game_id: 'old-game', game_date: '2026-02-01',
          opponent: 'Dodgers', home_away: 'away', status: 'scheduled'
        )
        syncer.run(force: true)
        expect(storage.all_games.map { |g| g['game_id'] }).not_to include('old-game')
      end

      # PERF-003 regression: `force: true` used to disable the final-game skip, so
      # every `gamechanger refresh` re-downloaded every immutable final boxscore
      # (one request + one RATE_LIMIT_SLEEP each). clear_non_final already removes
      # the rows that legitimately need re-fetching.
      it 'still skips games already cached as final' do
        cache_final_game_with_stats
        syncer.run(force: true)
        expect(WebMock).not_to have_requested(:get, /boxscore/)
      end

      it 'does not sleep for a skipped final game' do
        cache_final_game_with_stats
        syncer.run(force: true)
        expect(syncer).not_to have_received(:sleep)
      end

      it 're-fetches a final game whose boxscore was never parsed into stats' do
        # Schedule feed can report a game as completed before its boxscore exists,
        # leaving a 'final' row with no stats. Those must not be skipped.
        storage.upsert_game(
          game_id: 'game-uuid-1', game_date: '2026-03-01',
          opponent: 'Eagles', home_away: 'home', status: 'final'
        )
        syncer.run(force: true)
        expect(WebMock).to have_requested(:get, /game-uuid-1\/boxscore/).once
      end
    end

    context 'with refetch_final: true' do
      before { allow(syncer).to receive(:sleep) }

      it 're-downloads boxscores for games already cached as final' do
        cache_final_game_with_stats
        syncer.run(force: true, refetch_final: true)
        expect(WebMock).to have_requested(:get, /game-uuid-1\/boxscore/).once
      end

      it 'sleeps once per re-downloaded final game' do
        cache_final_game_with_stats
        syncer.run(force: true, refetch_final: true)
        expect(syncer).to have_received(:sleep).with(Gamechanger::Client::RATE_LIMIT_SLEEP).once
      end
    end

    context 'when the schedule response is a Hash (wrapped shape)' do
      before do
        stub_request(:get, /schedule/)
          .to_return(status: 200, body: { 'schedule' => [past_game_event] }.to_json)
        allow(syncer).to receive(:sleep)
      end

      it 'extracts games from the wrapped hash' do
        syncer.run
        expect(storage.all_games.length).to eq(1)
      end
    end

    context 'when the schedule response is an unexpected shape' do
      before do
        stub_request(:get, /schedule/).to_return(status: 200, body: '"unexpected string"')
      end

      it 'raises APIShapeError' do
        expect { syncer.run }.to raise_error(Gamechanger::APIShapeError, /Unexpected schedule/)
      end
    end

    context 'when an event has a completed/final status' do
      before do
        final_event = past_game_event.merge(
          'event' => past_game_event['event'].merge('status' => 'completed')
        )
        stub_request(:get, /schedule/)
          .to_return(status: 200, body: [final_event].to_json)
        allow(syncer).to receive(:sleep)
      end

      it 'normalizes completed status to final' do
        syncer.run
        game = storage.all_games.first
        expect(game['status']).to eq('final')
      end
    end

    context 'when an event has an unrecognized status' do
      before do
        unknown_event = past_game_event.merge(
          'event' => past_game_event['event'].merge('status' => 'unknown_xyz')
        )
        stub_request(:get, /schedule/)
          .to_return(status: 200, body: [unknown_event].to_json)
        # Return empty boxscore so stats.any? is false and status isn't overwritten to 'final'
        stub_request(:get, /boxscore/)
          .to_return(status: 200, body: { 'wGP47FexatoQ' => { 'players' => [], 'groups' => [] } }.to_json)
        allow(syncer).to receive(:sleep)
      end

      it 'preserves unrecognized status as-is (downcased)' do
        syncer.run
        game = storage.all_games.first
        expect(game['status']).to eq('unknown_xyz')
      end
    end
  end
end
