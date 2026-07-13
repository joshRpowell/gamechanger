# frozen_string_literal: true

require 'net/http'
require 'json'
require 'uri'
require 'openssl'

module Gamechanger
  # HTTP client for the Gamechanger internal JSON API.
  #
  # Auth: 5-step MFA flow over POST /auth, then `gc-token` header on
  # all subsequent calls. The token sequence is:
  #
  #   1. {type:"client-auth"}     → client JWT (used to authenticate the auth flow itself)
  #   2. {type:"user-auth"}       → triggers an OTP send to the registered email
  #   3. {type:"mfa-code"}        → submit the code the user pastes in
  #   4. {type:"password"}        → submit credentials, receive access + refresh JWTs
  #   5. {type:"refresh"}         → mint a new access JWT from a non-expired refresh JWT
  #
  # Every /auth call requires a chained gc-signature header (see Signer).
  # Subsequent /me/* and /games endpoints take only `gc-token` — no signature.
  # See docs/research/gc-api-notes.md for the full endpoint reference.
  class Client
    BASE_URL         = 'https://api.team-manager.gc.com'.freeze
    AUTH_PATH        = '/auth'.freeze
    TEAMS_PATH       = '/me/teams'.freeze
    GAMES_PATH       = '/teams/%s/schedule'.freeze
    GAME_STATS_PATH  = '/game-stream-processing/%s/boxscore'.freeze

    # Eden auth client credentials (embedded in the GC web bundle, treated as
    # public — they identify the web client, the per-request HMAC keys live
    # alongside them in the bundle's EDEN_AUTH_CLIENT_KEY constant).
    CLIENT_ID  = '7200841e-884d-4e23-825d-8a404a03b726'.freeze
    CLIENT_KEY = 'gFN+/LbESwNuvsEYWAIyTMh5tn92KEeU4Rhhvbrrb1w='.freeze
    APP_VERSION = '0.0.0'.freeze

    ACCEPT_TEAMS = 'application/vnd.gc.com.team:list+json; version=0.10.0'.freeze
    ACCEPT_JSON  = 'application/json'.freeze

    USER_AGENT = 'Mozilla/5.0 (Macintosh; Intel Mac OS X 10.15; rv:148.0) Gecko/20100101 Firefox/148.0'.freeze

    RATE_LIMIT_SLEEP = 0.5
    RETRY_SLEEP      = 5

    # @param config [Config] the configured account
    # @param otp_prompt [#call] called with no args during interactive auth to
    #   collect the 6-digit OTP. Defaults to a Kernel#gets prompt; tests/setup
    #   inject their own.
    def initialize(config:, otp_prompt: nil)
      @config     = config
      @uri        = URI.parse(BASE_URL)
      @otp_prompt = otp_prompt || ->(prompt = 'Enter the 6-digit code sent to your email: ') do
        print prompt
        $stdin.gets.to_s.strip
      end
      @previous_signature = nil
      @http               = nil
    end

    # Close the persistent HTTP connection, if one is open. Safe to call when no
    # connection exists. Callers that finish a batch of requests may invoke this
    # to release the socket promptly rather than waiting for GC.
    def close
      reset_connection
    end

    # Returns a valid user access JWT, running whatever subset of the auth
    # flow is needed: cached → refresh-only → full interactive.
    # @return [String] gc-token JWT for the authenticated user
    def authenticate
      cached = @config.cached_token
      return cached if cached

      refresh_token = @config.cached_refresh_token
      return refresh_access_token(refresh_token) if refresh_token

      run_interactive_auth_flow
    rescue AuthError
      @config.clear_token
      raise
    end

    def teams
      authenticate
      get(TEAMS_PATH, accept: ACCEPT_TEAMS)
    end

    def games(team_id:)
      authenticate
      get("#{GAMES_PATH % team_id}?fetch_place_details=true")
    end

    def game_pitcher_stats(game_id:)
      authenticate
      get(GAME_STATS_PATH % game_id)
    end

    private

    # Step 1-4 of the auth flow, interactive — requires user to paste an OTP.
    def run_interactive_auth_flow
      @previous_signature = nil

      client_token = client_auth
      user_auth_response = user_auth(email: @config.email, client_token: client_token)

      # Handle each documented user-auth response shape.
      case user_auth_response['type']
      when 'user-action-required'
        case user_auth_response['kind']
        when 'mfa'
          # Server sent an OTP to the registered email. Prompt and submit it.
          otp = @otp_prompt.call
          raise AuthError, 'No OTP code provided' if otp.nil? || otp.empty?

          mfa_response = submit_mfa_code(otp, client_token: client_token)
          unless mfa_response['type'] == 'password-required'
            raise APIShapeError, "Expected password-required after OTP, got: #{mfa_response.inspect}"
          end
        else
          raise APIShapeError, "Unhandled user-action-required kind: #{user_auth_response.inspect}"
        end
      when 'password-required'
        # Trusted device skips MFA and goes straight to password.
      else
        raise APIShapeError, "Unexpected user-auth response: #{user_auth_response.inspect}"
      end

      submit_password(@config.password, client_token: client_token)
    end

    # Step 1: client-auth — returns a short-lived client JWT bound to this device.
    def client_auth
      resp = signed_auth_post(body: { type: 'client-auth', client_id: CLIENT_ID }, gc_token: nil)
      raise APIShapeError, "client-auth missing token: #{resp.inspect}" if resp['token'].nil?

      resp['token']
    end

    # Step 2: user-auth — triggers the OTP email send. Response indicates
    # whether MFA is required (it always is, for fresh devices).
    def user_auth(email:, client_token:)
      signed_auth_post(body: { type: 'user-auth', email: email }, gc_token: client_token)
    end

    # Step 3: mfa-code — submit the code the user pasted.
    def submit_mfa_code(code, client_token:)
      signed_auth_post(body: { type: 'mfa-code', code: code }, gc_token: client_token)
    end

    # Step 4: password — final step, returns access + refresh tokens.
    def submit_password(password, client_token:)
      resp = signed_auth_post(body: { type: 'password', password: password }, gc_token: client_token)
      raise APIShapeError, "password response missing tokens: #{resp.inspect}" if resp['access'].nil?

      cache_token_response(resp)
      resp.dig('access', 'data')
    end

    # Step 5: refresh — mint a fresh access token from a still-valid refresh token.
    # Resets signature chain (fresh request, no prior context).
    def refresh_access_token(refresh_token)
      @previous_signature = nil
      resp = signed_auth_post(body: { type: 'refresh' }, gc_token: refresh_token)
      raise APIShapeError, "refresh response missing access: #{resp.inspect}" if resp['access'].nil?

      cache_token_response(resp)
      resp.dig('access', 'data')
    rescue AuthError
      # Refresh token expired or revoked — fall back to full interactive flow.
      run_interactive_auth_flow
    end

    def cache_token_response(resp)
      access  = resp['access']  || {}
      refresh = resp['refresh'] || {}
      @config.cache_tokens(
        access_token:    access['data'],
        access_expires:  access['expires'],
        refresh_token:   refresh['data'],
        refresh_expires: refresh['expires']
      )
    end

    # POST to /auth with a fresh chained signature. Updates @previous_signature
    # from the response header so the next signed call chains correctly.
    def signed_auth_post(body:, gc_token:)
      timestamp = Time.now.to_i.to_s
      nonce     = Signer.generate_nonce
      signature = Signer.sign(
        client_key:          CLIENT_KEY,
        timestamp:           timestamp,
        nonce:               nonce,
        body:                body,
        previous_signature:  @previous_signature
      )

      extra_headers = {
        'gc-app-version' => APP_VERSION,
        'gc-client-id'   => CLIENT_ID,
        'gc-timestamp'   => timestamp,
        'gc-signature'   => signature
      }
      extra_headers['gc-token'] = gc_token if gc_token

      response = raw_request(:post, AUTH_PATH,
                             body: JSON.generate(body),
                             accept: ACCEPT_JSON,
                             extra_headers: extra_headers,
                             include_session_token: false)

      @previous_signature = Signer.previous_signature_from_response(response[:headers]['gc-signature'])
      response[:json]
    end

    def get(path, accept: ACCEPT_JSON)
      raw_request(:get, path, accept: accept)[:json]
    end

    def raw_request(method, path, body: nil, accept: ACCEPT_JSON, attempt: 1,
                    extra_headers: {}, include_session_token: true, reconnect: true)
      http = http_connection
      req  = build_request(method, path, body, accept, extra_headers, include_session_token)
      handle_response(http.request(req),
                      path: path, method: method, body: body, accept: accept,
                      attempt: attempt, extra_headers: extra_headers,
                      include_session_token: include_session_token)
    rescue EOFError, IOError, Errno::ECONNRESET, Errno::EPIPE => e
      # The persistent connection was closed server-side (idle timeout) between
      # requests. Net::HTTP raises when it writes to a dead reused socket. Drop
      # the stale connection and, for idempotent GETs only, retry the request
      # exactly once on a fresh one. Non-GET requests (POST /auth) are never
      # resent — a mid-response failure could otherwise double-send (e.g. a
      # duplicate OTP email) — so they map straight to NetworkError.
      reset_connection
      raise NetworkError, "Connection error: #{e.message}" unless reconnect && method == :get

      raw_request(method, path, body: body, accept: accept, attempt: attempt,
                  extra_headers: extra_headers, include_session_token: include_session_token,
                  reconnect: false)
    rescue Net::OpenTimeout, Net::ReadTimeout => e
      raise NetworkError, "Request timed out: #{e.message}"
    rescue Errno::ECONNREFUSED, Errno::EHOSTUNREACH, SocketError => e
      raise NetworkError, "Unable to connect to Gamechanger API: #{e.message}"
    rescue OpenSSL::SSL::SSLError => e
      raise NetworkError, "SSL error: #{e.message}"
    end

    # Lazily open (and memoize) a single keep-alive HTTP connection to the API
    # host. Reused across every request for the life of the client so we pay the
    # TCP + TLS handshake once instead of once per request. A dropped connection
    # is transparently re-opened here on the next call (see reset_connection).
    def http_connection
      return @http if @http&.started?

      http = Net::HTTP.new(@uri.host, @uri.port)
      http.use_ssl          = true
      http.verify_mode      = OpenSSL::SSL::VERIFY_PEER
      http.open_timeout     = 10
      http.read_timeout     = 30
      http.keep_alive_timeout = 30
      http.start
      @http = http
    end

    # Finish and discard the memoized connection. Idempotent and safe to call
    # even if the socket is already closed.
    def reset_connection
      @http.finish if @http&.started?
    rescue IOError
      # Socket already torn down — nothing to finish.
    ensure
      @http = nil
    end

    def build_request(method, path, body, accept, extra_headers, include_session_token)
      klass = method == :post ? Net::HTTP::Post : Net::HTTP::Get
      req = klass.new(path)

      req['Accept']       = accept
      req['Content-Type'] = 'application/json; charset=utf-8'
      req['User-Agent']   = USER_AGENT
      req['Origin']       = 'https://web.gc.com'
      req['Referer']      = 'https://web.gc.com/'
      req['gc-app-name']  = 'web'
      req['gc-device-id'] = @config.device_id

      if include_session_token
        token = @config.cached_token
        req['gc-token'] = token if token
      end

      extra_headers.each { |k, v| req[k] = v }

      req.body = body if body
      req
    end

    def handle_response(response, path:, method:, body:, accept:, attempt:,
                        extra_headers: {}, include_session_token: true)
      case response
      when Net::HTTPSuccess, Net::HTTPNotModified
        { json: parse_json(response.body), headers: response_headers(response) }
      when Net::HTTPUnauthorized
        raise AuthError, 'Authentication failed — run `gamechanger setup` to reconfigure credentials'
      when Net::HTTPTooManyRequests
        if attempt == 1
          warn "Rate limited by Gamechanger API — waiting #{RETRY_SLEEP}s and retrying..."
          sleep RETRY_SLEEP
          raw_request(method, path, body: body, accept: accept, attempt: 2,
                      extra_headers: extra_headers, include_session_token: include_session_token)
        else
          raise NetworkError, 'Rate limited by Gamechanger API (429) — try again later'
        end
      else
        raise NetworkError, "Gamechanger API returned #{response.code}: #{response.message}"
      end
    end

    def response_headers(response)
      h = {}
      response.each_header { |k, v| h[k] = v }
      h
    end

    def parse_json(body)
      return {} if body.nil? || body.strip.empty?

      JSON.parse(body)
    rescue JSON::ParserError => e
      raise APIShapeError, "Unexpected API response (not JSON): #{e.message}"
    end
  end
end
