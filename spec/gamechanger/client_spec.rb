# frozen_string_literal: true

require 'spec_helper'

RSpec.describe Gamechanger::Client do
  let(:config) do
    instance_double(
      Gamechanger::Config,
      email:        'test@example.com',
      password:     'secret',
      cached_token: nil,
      team_id:      'team-123',
      season:       2026,
      device_id:    'abc123def456abc123def456abc123de'
    )
  end
  subject(:client) { described_class.new(config: config) }

  # NOTE: All endpoint paths below must be updated after Phase 0 spike
  # to match the real Gamechanger API. See docs/research/gc-api-notes.md.

  describe '#authenticate' do
    context 'when credentials are valid' do
      before do
        allow(config).to receive(:cache_token)
        stub_request(:post, "#{Gamechanger::Client::BASE_URL}#{Gamechanger::Client::AUTH_PATH}")
          .to_return(
            status: 200,
            body: JSON.generate({ 'token' => 'jwt-token-abc' }),
            headers: { 'Content-Type' => 'application/json' }
          )
      end

      it 'returns a token' do
        expect(client.authenticate).to eq('jwt-token-abc')
      end

      it 'caches the token' do
        expect(config).to receive(:cache_token).with('jwt-token-abc', expires_at: nil)
        client.authenticate
      end
    end

    context 'when credentials are invalid (401)' do
      before do
        allow(config).to receive(:clear_token)
        stub_request(:post, "#{Gamechanger::Client::BASE_URL}#{Gamechanger::Client::AUTH_PATH}")
          .to_return(status: 401, body: JSON.generate({ 'error' => 'invalid credentials' }))
      end

      it 'raises AuthError' do
        expect { client.authenticate }.to raise_error(Gamechanger::AuthError)
      end
    end

    context 'when using a cached token' do
      let(:config) do
        instance_double(
          Gamechanger::Config,
          email:        'test@example.com',
          password:     'secret',
          cached_token: 'cached-token-xyz',
          team_id:      'team-123',
          season:       2026,
          device_id:    'abc123def456abc123def456abc123de'
        )
      end

      it 'returns the cached token without making a request' do
        expect(client.authenticate).to eq('cached-token-xyz')
        expect(a_request(:post, /#{Regexp.escape(Gamechanger::Client::BASE_URL)}/)).not_to have_been_made
      end
    end

    context 'when network is unavailable' do
      before do
        stub_request(:post, /#{Regexp.escape(Gamechanger::Client::BASE_URL)}/).to_raise(Errno::ECONNREFUSED)
      end

      it 'raises NetworkError' do
        expect { client.authenticate }.to raise_error(Gamechanger::NetworkError)
      end
    end

    context 'when request times out' do
      before do
        stub_request(:post, /#{Regexp.escape(Gamechanger::Client::BASE_URL)}/).to_raise(Net::OpenTimeout)
      end

      it 'raises NetworkError' do
        expect { client.authenticate }.to raise_error(Gamechanger::NetworkError)
      end
    end
  end

  describe '#game_pitcher_stats' do
    let(:config) do
      instance_double(
        Gamechanger::Config,
        email:        'test@example.com',
        password:     'secret',
        cached_token: 'valid-token',
        team_id:      'team-123',
        season:       2026,
        device_id:    'abc123def456abc123def456abc123de'
      )
    end

    let(:stats_response) do
      [
        { 'name' => 'Alice Smith', 'pitches_thrown' => 72, 'innings_pitched' => 5.0 },
        { 'name' => 'Bob Jones',   'pitches_thrown' => 24, 'innings_pitched' => 2.0 }
      ]
    end

    before do
      stub_request(:get, "#{Gamechanger::Client::BASE_URL}#{Gamechanger::Client::GAME_STATS_PATH % 'game-001'}")
        .to_return(
          status: 200,
          body: JSON.generate(stats_response),
          headers: { 'Content-Type' => 'application/json' }
        )
    end

    it 'returns parsed pitcher stats' do
      result = client.game_pitcher_stats(game_id: 'game-001')
      expect(result.length).to eq(2)
      expect(result.first['pitches_thrown']).to eq(72)
    end
  end

  describe 'rate limit handling' do
    let(:config) do
      instance_double(
        Gamechanger::Config,
        email:        'test@example.com',
        password:     'secret',
        cached_token: 'valid-token',
        team_id:      'team-123',
        season:       2026,
        device_id:    'abc123def456abc123def456abc123de'
      )
    end

    before do
      allow(client).to receive(:sleep)  # prevent actual sleeping in tests
      stub_request(:get, "#{Gamechanger::Client::BASE_URL}#{Gamechanger::Client::TEAMS_PATH}")
        .to_return(
          { status: 429, body: 'Too Many Requests' },
          { status: 200, body: JSON.generate([]), headers: { 'Content-Type' => 'application/json' } }
        )
    end

    it 'retries once on 429 and succeeds' do
      expect { client.teams }.not_to raise_error
    end
  end
end
