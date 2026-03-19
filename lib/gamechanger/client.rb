# frozen_string_literal: true

require 'net/http'
require 'json'
require 'uri'
require 'openssl'

module Gamechanger
  # HTTP client for the Gamechanger internal JSON API.
  #
  # Auth: uses custom gc-token header (NOT Authorization: Bearer).
  # Token is cached in ~/.gamechanger/session (mode 0600).
  # See docs/research/gc-api-notes.md for the full endpoint reference.
  class Client
    BASE_URL         = 'https://api.team-manager.gc.com'.freeze
    AUTH_PATH        = '/auth'.freeze                                      # confirmed — POST with {email, password}
    TEAMS_PATH       = '/me/teams'.freeze                                 # confirmed
    GAMES_PATH       = '/teams/%s/schedule'.freeze                        # confirmed — %s = team UUID
    GAME_STATS_PATH  = '/game-stream-processing/%s/boxscore'.freeze      # confirmed — %s = game UUID
    GAME_DETAIL_PATH = '/public/game-stream-processing/%s/details'.freeze # confirmed — %s = game UUID, public (no auth needed)

    # Versioned Accept headers per endpoint (GC uses content negotiation)
    ACCEPT_TEAMS = 'application/vnd.gc.com.team:list+json; version=0.10.0'.freeze
    ACCEPT_JSON  = 'application/json'.freeze                              # fallback for unconfirmed endpoints

    USER_AGENT = 'Mozilla/5.0 (Macintosh; Intel Mac OS X 10.15; rv:148.0) Gecko/20100101 Firefox/148.0'.freeze

    RATE_LIMIT_SLEEP = 0.5  # seconds between game-level requests
    RETRY_SLEEP      = 5    # seconds to wait on 429 before retrying

    def initialize(config:)
      @config = config
      @uri    = URI.parse(BASE_URL)
    end

    # Authenticate and return a session token.
    # Caches the token in ~/.gamechanger/session.
    # @return [String] gc-token JWT
    # @raise [AuthError] on invalid credentials
    # @raise [NetworkError] on connection failure
    def authenticate
      cached = @config.cached_token
      return cached if cached

      body = JSON.generate({ email: @config.email, password: @config.password })
      response = request(:post, AUTH_PATH, body: body)

      token     = response&.dig('token')
      expires   = response&.dig('expires')
      raise APIShapeError, 'Auth response missing token field' if token.nil?

      @config.cache_token(token, expires_at: expires)
      token
    rescue AuthError
      @config.clear_token
      raise
    end

    # Return all teams for the authenticated user.
    # @return [Array<Hash>] team objects with :id, :name, :team_type
    def teams
      authenticate
      get(TEAMS_PATH, accept: ACCEPT_TEAMS)
    end

    # Return all games for the configured team and season.
    # @return [Array<Hash>] game records
    def games(team_id:)
      authenticate
      get("#{GAMES_PATH % team_id}?fetch_place_details=true")
    end

    # Return pitcher stats (boxscore) for a single game.
    # @param game_id [String] Gamechanger game UUID
    # @return [Hash] boxscore keyed by team slug
    def game_pitcher_stats(game_id:)
      authenticate
      get(GAME_STATS_PATH % game_id)
    end

    # Return details for a single game (public endpoint — no auth required).
    # @param game_id [String] Gamechanger game UUID
    # @return [Hash] game details with id, game_status, start_ts, home_away, opponent_team
    def game_detail(game_id:)
      get("#{GAME_DETAIL_PATH % game_id}?include=line_scores")
    end

    private

    def get(path, accept: ACCEPT_JSON)
      request(:get, path, accept: accept)
    end

    def request(method, path, body: nil, accept: ACCEPT_JSON, attempt: 1)
      http_opts = {
        use_ssl:      true,
        verify_mode:  OpenSSL::SSL::VERIFY_PEER,
        open_timeout: 10,
        read_timeout: 30
      }

      Net::HTTP.start(@uri.host, @uri.port, **http_opts) do |http|
        req = build_request(method, path, body, accept)
        handle_response(http.request(req), path: path, method: method, body: body, accept: accept, attempt: attempt)
      end
    rescue Net::OpenTimeout, Net::ReadTimeout => e
      raise NetworkError, "Request timed out: #{e.message}"
    rescue Errno::ECONNREFUSED, Errno::EHOSTUNREACH, SocketError => e
      raise NetworkError, "Unable to connect to Gamechanger API: #{e.message}"
    rescue OpenSSL::SSL::SSLError => e
      raise NetworkError, "SSL error: #{e.message}"
    end

    def build_request(method, path, body, accept)
      klass = method == :post ? Net::HTTP::Post : Net::HTTP::Get
      req = klass.new(path)

      req['Accept']       = accept
      req['Content-Type'] = 'application/json'
      req['User-Agent']   = USER_AGENT
      req['Origin']       = 'https://web.gc.com'
      req['Referer']      = 'https://web.gc.com/'
      req['gc-app-name']  = 'web'
      req['gc-device-id'] = @config.device_id

      # GC uses gc-token header, NOT Authorization: Bearer
      token = @config.cached_token
      req['gc-token'] = token if token

      req.body = body if body
      req
    end

    def handle_response(response, path:, method:, body:, accept:, attempt:)
      case response
      when Net::HTTPSuccess, Net::HTTPNotModified
        parse_json(response.body)
      when Net::HTTPUnauthorized
        raise AuthError, 'Authentication failed — run `gamechanger setup` to reconfigure credentials'
      when Net::HTTPTooManyRequests
        if attempt == 1
          warn "Rate limited by Gamechanger API — waiting #{RETRY_SLEEP}s and retrying..."
          sleep RETRY_SLEEP
          request(method, path, body: body, accept: accept, attempt: 2)
        else
          raise NetworkError, 'Rate limited by Gamechanger API (429) — try again later'
        end
      else
        raise NetworkError, "Gamechanger API returned #{response.code}: #{response.message}"
      end
    end

    def parse_json(body)
      return [] if body.nil? || body.strip.empty?

      JSON.parse(body)
    rescue JSON::ParserError => e
      raise APIShapeError, "Unexpected API response (not JSON): #{e.message}"
    end

  end
end
