# frozen_string_literal: true

require 'spec_helper'

RSpec.describe Gamechanger::Client do
  def config_double(cached_token: nil, cached_refresh_token: nil, password: 'secret')
    instance_double(
      Gamechanger::Config,
      email:                'test@example.com',
      password:             password,
      cached_token:         cached_token,
      cached_refresh_token: cached_refresh_token,
      team_id:              'team-123',
      season:               2026,
      device_id:            'abc123def456abc123def456abc123de'
    )
  end

  describe '#authenticate' do
    context 'with a cached non-expired access token' do
      let(:config) { config_double(cached_token: 'cached-access-jwt') }
      subject(:client) { described_class.new(config: config) }

      it 'returns the cached token without hitting the network' do
        expect(client.authenticate).to eq('cached-access-jwt')
        expect(a_request(:post, /#{Regexp.escape(Gamechanger::Client::BASE_URL)}/)).not_to have_been_made
      end
    end

    context 'with a cached refresh token (no access token)' do
      let(:config) { config_double(cached_refresh_token: 'refresh-jwt') }
      subject(:client) { described_class.new(config: config) }

      before do
        allow(config).to receive(:cache_tokens)
        stub_request(:post, "#{Gamechanger::Client::BASE_URL}#{Gamechanger::Client::AUTH_PATH}")
          .to_return(
            status: 200,
            body: JSON.generate(
              'type'    => 'token',
              'access'  => { 'data' => 'fresh-access', 'expires' => 9999999999 },
              'refresh' => { 'data' => 'rotated-refresh', 'expires' => 9999999999 }
            ),
            headers: { 'Content-Type' => 'application/json' }
          )
      end

      it 'calls /auth with type=refresh and returns the new access token' do
        expect(client.authenticate).to eq('fresh-access')
        expect(WebMock).to have_requested(:post, "#{Gamechanger::Client::BASE_URL}/auth")
          .with(body: hash_including('type' => 'refresh'))
      end

      it 'caches both the new access and rotated refresh tokens' do
        expect(config).to receive(:cache_tokens).with(
          access_token: 'fresh-access', access_expires: 9999999999,
          refresh_token: 'rotated-refresh', refresh_expires: 9999999999
        )
        client.authenticate
      end
    end

    context 'with no cached tokens (full interactive flow)' do
      let(:config) { config_double }
      subject(:client) do
        described_class.new(config: config, otp_prompt: -> { '123456' })
      end

      before do
        allow(config).to receive(:cache_tokens)
        allow(config).to receive(:clear_token)

        # Sequence 4 POSTs to /auth in flow order
        stub_request(:post, "#{Gamechanger::Client::BASE_URL}#{Gamechanger::Client::AUTH_PATH}")
          .to_return(
            # 1. client-auth
            { status: 200, body: JSON.generate('type' => 'client-token', 'token' => 'client-jwt', 'expires' => 9999999999),
              headers: { 'Content-Type' => 'application/json' } },
            # 2. user-auth
            { status: 200, body: JSON.generate('type' => 'user-action-required', 'kind' => 'mfa'),
              headers: { 'Content-Type' => 'application/json' } },
            # 3. mfa-code
            { status: 200, body: JSON.generate('type' => 'password-required'),
              headers: { 'Content-Type' => 'application/json' } },
            # 4. password
            { status: 200, body: JSON.generate(
              'type' => 'token',
              'access'  => { 'data' => 'user-access-jwt', 'expires' => 9999999999 },
              'refresh' => { 'data' => 'user-refresh-jwt', 'expires' => 9999999999 }
            ), headers: { 'Content-Type' => 'application/json' } }
          )
      end

      context 'on a trusted device (user-auth returns password-required immediately)' do
        before do
          stub_request(:post, "#{Gamechanger::Client::BASE_URL}#{Gamechanger::Client::AUTH_PATH}")
            .to_return(
              { status: 200, body: JSON.generate('token' => 'client-jwt', 'expires' => 9999999999),
                headers: { 'Content-Type' => 'application/json' } },
              { status: 200, body: JSON.generate('type' => 'password-required'),
                headers: { 'Content-Type' => 'application/json' } },
              { status: 200, body: JSON.generate(
                'access'  => { 'data' => 'trusted-access', 'expires' => 9999999999 },
                'refresh' => { 'data' => 'trusted-refresh', 'expires' => 9999999999 }
              ), headers: { 'Content-Type' => 'application/json' } }
            )
        end

        it 'skips the MFA prompt and goes straight to password' do
          c = described_class.new(config: config, otp_prompt: -> { raise 'should not prompt' })
          expect(c.authenticate).to eq('trusted-access')
        end
      end

      it 'runs all four /auth POSTs and returns the user access token' do
        expect(client.authenticate).to eq('user-access-jwt')
        expect(WebMock).to have_requested(:post, "#{Gamechanger::Client::BASE_URL}/auth").times(4)
      end

      it 'sends the OTP code from the prompt callable' do
        client.authenticate
        expect(WebMock).to have_requested(:post, "#{Gamechanger::Client::BASE_URL}/auth")
          .with(body: hash_including('type' => 'mfa-code', 'code' => '123456'))
      end

      it 'sends a chained gc-signature header on every signed call' do
        client.authenticate
        expect(WebMock).to have_requested(:post, "#{Gamechanger::Client::BASE_URL}/auth")
          .with { |req| req.headers['Gc-Signature']&.include?('.') }
          .times(4)
      end

      it 'raises AuthError if no OTP is provided' do
        c = described_class.new(config: config, otp_prompt: -> { '' })
        expect { c.authenticate }.to raise_error(Gamechanger::AuthError, /No OTP/)
      end
    end

    context 'when the API returns 401 mid-flow' do
      let(:config) { config_double(cached_refresh_token: 'expired-refresh') }
      subject(:client) do
        described_class.new(config: config, otp_prompt: -> { '999999' })
      end

      before do
        allow(config).to receive(:cache_tokens)
        allow(config).to receive(:clear_token)
        # First call (refresh) → 401, then full 4-step flow succeeds
        stub_request(:post, "#{Gamechanger::Client::BASE_URL}#{Gamechanger::Client::AUTH_PATH}")
          .to_return(
            { status: 401, body: '' },
            { status: 200, body: JSON.generate('token' => 'c'), headers: { 'Content-Type' => 'application/json' } },
            { status: 200, body: JSON.generate('type' => 'user-action-required', 'kind' => 'mfa'), headers: { 'Content-Type' => 'application/json' } },
            { status: 200, body: JSON.generate('type' => 'password-required'), headers: { 'Content-Type' => 'application/json' } },
            { status: 200, body: JSON.generate('access' => { 'data' => 'recovered', 'expires' => 9999999999 }),
              headers: { 'Content-Type' => 'application/json' } }
          )
      end

      it 'falls back from refresh failure to full interactive flow' do
        expect(client.authenticate).to eq('recovered')
      end
    end

    context 'when the network is unavailable' do
      let(:config) { config_double }
      subject(:client) { described_class.new(config: config) }

      before do
        stub_request(:post, /#{Regexp.escape(Gamechanger::Client::BASE_URL)}/).to_raise(Errno::ECONNREFUSED)
      end

      it 'raises NetworkError' do
        expect { client.authenticate }.to raise_error(Gamechanger::NetworkError)
      end
    end

    context 'when the request times out' do
      let(:config) { config_double }
      subject(:client) { described_class.new(config: config) }

      before do
        stub_request(:post, /#{Regexp.escape(Gamechanger::Client::BASE_URL)}/).to_raise(Net::OpenTimeout)
      end

      it 'raises NetworkError' do
        expect { client.authenticate }.to raise_error(Gamechanger::NetworkError)
      end
    end
  end

  describe '#game_pitcher_stats' do
    let(:config) { config_double(cached_token: 'valid-token') }
    subject(:client) { described_class.new(config: config) }

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
    let(:config) { config_double(cached_token: 'valid-token') }
    subject(:client) { described_class.new(config: config) }

    before do
      allow(client).to receive(:sleep)
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

  describe 'persistent HTTP connection' do
    let(:config) { config_double(cached_token: 'valid-token') }
    subject(:client) { described_class.new(config: config) }

    before do
      stub_request(:get, "#{Gamechanger::Client::BASE_URL}#{Gamechanger::Client::TEAMS_PATH}")
        .to_return(status: 200, body: JSON.generate([]), headers: { 'Content-Type' => 'application/json' })
    end

    it 'reuses a single started Net::HTTP connection across requests' do
      first  = client.send(:http_connection)
      second = client.send(:http_connection)
      expect(second).to be(first)
      expect(first).to be_started
    end

    it 'makes multiple sequential requests over the reused connection' do
      client.teams
      client.teams
      expect(WebMock).to have_requested(:get, "#{Gamechanger::Client::BASE_URL}#{Gamechanger::Client::TEAMS_PATH}").twice
    end

    describe '#close' do
      it 'finishes an open connection and clears it' do
        conn = client.send(:http_connection)
        expect(conn).to be_started
        client.close
        expect(client.instance_variable_get(:@http)).to be_nil
      end

      it 'is a no-op when no connection is open' do
        expect { client.close }.not_to raise_error
      end

      it 'swallows IOError raised while finishing an already-dead socket' do
        conn = client.send(:http_connection)
        allow(conn).to receive(:finish).and_raise(IOError, 'already closed')
        expect { client.close }.not_to raise_error
        expect(client.instance_variable_get(:@http)).to be_nil
      end
    end

    context 'when the persistent socket was closed server-side (idle timeout)' do
      it 'reconnects once on EOFError and completes the request' do
        stub_request(:get, "#{Gamechanger::Client::BASE_URL}#{Gamechanger::Client::TEAMS_PATH}")
          .to_raise(EOFError.new('end of file reached'))
          .then
          .to_return(status: 200, body: JSON.generate([]), headers: { 'Content-Type' => 'application/json' })

        expect { client.teams }.not_to raise_error
        expect(WebMock).to have_requested(:get, "#{Gamechanger::Client::BASE_URL}#{Gamechanger::Client::TEAMS_PATH}").twice
      end

      it 'raises NetworkError if the reconnected request also fails' do
        stub_request(:get, "#{Gamechanger::Client::BASE_URL}#{Gamechanger::Client::TEAMS_PATH}")
          .to_raise(Errno::ECONNRESET)

        expect { client.teams }.to raise_error(Gamechanger::NetworkError, /Connection error/)
      end

      it 'never resends a non-GET request (POST /auth must not double-send an OTP email)' do
        auth_config = config_double(cached_refresh_token: 'refresh-jwt')
        auth_client = described_class.new(config: auth_config)
        allow(auth_config).to receive(:cache_tokens)
        allow(auth_config).to receive(:clear_token)

        stub_request(:post, "#{Gamechanger::Client::BASE_URL}#{Gamechanger::Client::AUTH_PATH}")
          .to_raise(EOFError.new('end of file reached'))
          .then
          .to_return(status: 200, body: JSON.generate('access' => { 'data' => 'x' }),
                     headers: { 'Content-Type' => 'application/json' })

        expect { auth_client.authenticate }.to raise_error(Gamechanger::NetworkError, /Connection error/)
        expect(WebMock).to have_requested(:post, "#{Gamechanger::Client::BASE_URL}/auth").once
      end
    end
  end

  describe 'error handling edge cases' do
    let(:config) { config_double(cached_token: 'valid-token') }
    subject(:client) { described_class.new(config: config) }

    it 'raises NetworkError on SSL error' do
      stub_request(:get, "#{Gamechanger::Client::BASE_URL}#{Gamechanger::Client::TEAMS_PATH}")
        .to_raise(OpenSSL::SSL::SSLError.new('certificate verify failed'))
      expect { client.teams }.to raise_error(Gamechanger::NetworkError, /SSL error/)
    end

    it 'raises NetworkError when rate limited on second attempt (429 twice)' do
      allow(client).to receive(:sleep)
      stub_request(:get, "#{Gamechanger::Client::BASE_URL}#{Gamechanger::Client::TEAMS_PATH}")
        .to_return(
          { status: 429, body: 'Too Many Requests' },
          { status: 429, body: 'Too Many Requests' }
        )
      expect { client.teams }.to raise_error(Gamechanger::NetworkError, /Rate limited/)
    end

    it 'raises NetworkError on unexpected HTTP status (500)' do
      stub_request(:get, "#{Gamechanger::Client::BASE_URL}#{Gamechanger::Client::TEAMS_PATH}")
        .to_return(status: 500, body: 'Internal Server Error')
      expect { client.teams }.to raise_error(Gamechanger::NetworkError, /500/)
    end

    it 'raises APIShapeError on malformed JSON response' do
      stub_request(:get, "#{Gamechanger::Client::BASE_URL}#{Gamechanger::Client::TEAMS_PATH}")
        .to_return(status: 200, body: 'not { valid json }}}', headers: { 'Content-Type' => 'application/json' })
      expect { client.teams }.to raise_error(Gamechanger::APIShapeError, /not JSON/)
    end
  end
end
