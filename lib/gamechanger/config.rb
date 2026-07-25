# frozen_string_literal: true

require 'yaml'
require 'fileutils'

module Gamechanger
  class Config
    DEFAULT_HOME = '~/.gamechanger'

    # Legacy constants — frozen to the default home at gem load. Do NOT consult
    # GAMECHANGER_HOME. Kept for back-compat; new callers prefer the class methods below.
    CONFIG_DIR   = File.expand_path(DEFAULT_HOME).freeze
    CONFIG_FILE  = File.join(CONFIG_DIR, 'config.yml').freeze
    SESSION_FILE = File.join(CONFIG_DIR, 'session').freeze

    # Resolves the gamechanger home directory at call time, honoring GAMECHANGER_HOME.
    # Used by the verify-parity harness to point Ruby and Go at the same fixture.
    def self.home_dir
      env = ENV['GAMECHANGER_HOME']
      File.expand_path(env && !env.empty? ? env : DEFAULT_HOME)
    end

    def self.config_file_path
      File.join(home_dir, 'config.yml')
    end

    def self.session_file_path
      File.join(home_dir, 'session')
    end

    attr_reader :email, :team_id, :team_slug, :season, :device_id, :password_op_ref

    def initialize(config_file: self.class.config_file_path)
      @config_file = config_file
      FileUtils.mkdir_p(File.dirname(@config_file), mode: 0o700)
      load_config
    end

    def configured?
      return false if email.nil? || email.empty?

      !(@password.nil? || @password.empty?) || !(password_op_ref.nil? || password_op_ref.empty?)
    end

    # Returns the password, resolving via 1Password CLI if a `password_op_ref`
    # is configured. Resolution is memoized per Config instance.
    def password
      return @password if @password && !@password.empty?
      return nil if password_op_ref.nil? || password_op_ref.empty?

      @resolved_op_password ||= resolve_op_password(password_op_ref)
    end

    def save(email:, password: nil, password_op_ref: nil, team_id: nil, team_slug: nil, season: nil)
      raise ConfigError, 'Email cannot be empty' if email.to_s.strip.empty?

      existing = existing_config_data
      if password.to_s.strip.empty? && password_op_ref.to_s.strip.empty? &&
         existing['password'].to_s.strip.empty? && existing['password_op_ref'].to_s.strip.empty?
        raise ConfigError, 'Either password or password_op_ref must be provided'
      end

      data = existing.dup
      data['email'] = email.strip
      if password.to_s.strip.empty?
        unless password_op_ref.to_s.strip.empty?
          data.delete('password')
          data['password_op_ref'] = password_op_ref.strip
        end
      else
        data['password'] = password.strip
        data.delete('password_op_ref')
      end
      data['team_id']   = team_id.to_s   if team_id
      data['team_slug'] = team_slug.to_s if team_slug
      data['season']    = season.to_i    if season
      data['device_id'] = @device_id || existing['device_id'] || generate_device_id

      write_config(data)
      load_config
    end

    # Returns the access JWT if cached and not yet expired, else nil.
    # Backwards-compatible with the legacy `<token>|<expires>` format from
    # the pre-MFA auth flow; new sessions are YAML with separate access +
    # refresh fields.
    def cached_token
      session = load_session
      return nil if session.nil?

      token   = session['access_token']
      expires = session['access_expires']
      return nil if token.nil? || token.empty?
      return nil if expires && Time.now.to_i > expires.to_i

      token
    end

    # Returns the refresh JWT if cached and not yet expired, else nil.
    # Used to mint a fresh access token without re-running the full
    # client-auth → user-auth → mfa-code → password flow.
    def cached_refresh_token
      session = load_session
      return nil if session.nil?

      token   = session['refresh_token']
      expires = session['refresh_expires']
      return nil if token.nil? || token.empty?
      return nil if expires && Time.now.to_i > expires.to_i

      token
    end

    # Persist the access token (and optionally a refresh token) returned by
    # the auth flow. Existing refresh credentials are preserved when only
    # an access token is supplied (e.g., after a refresh call that returned
    # only access).
    def cache_tokens(access_token:, access_expires:, refresh_token: nil, refresh_expires: nil)
      existing = load_session || {}
      data = {
        'access_token'   => access_token,
        'access_expires' => access_expires.to_i
      }
      data['refresh_token']   = refresh_token   || existing['refresh_token']
      data['refresh_expires'] = (refresh_expires || existing['refresh_expires'])&.to_i
      write_session(data)
    end

    # Back-compat shim for the old single-token API.
    def cache_token(token, expires_at: nil)
      cache_tokens(access_token: token, access_expires: expires_at || (Time.now.to_i + 3600))
    end

    def clear_token
      session = self.class.session_file_path
      File.delete(session) if File.exist?(session)
      invalidate_session_cache
    end

    private

    def existing_config_data
      return {} unless File.exist?(@config_file)

      YAML.safe_load(File.read(@config_file), symbolize_names: false) || {}
    rescue Psych::Exception => e
      raise ConfigError, "Malformed config at #{@config_file}: #{e.message}"
    end

    def load_config
      unless File.exist?(@config_file)
        @email = @password = @password_op_ref = @team_id = @team_slug = nil
        @season = Time.now.year
        @resolved_op_password = nil
        return
      end

      data = YAML.safe_load(File.read(@config_file), symbolize_names: false) || {}
      @email           = data['email']
      @password        = data['password']
      @password_op_ref = data['password_op_ref']
      @resolved_op_password = nil
      @team_id   = data['team_id']
      @team_slug = data['team_slug']  # short slug used as boxscore response key (e.g. wGP47FexatoQ)
      @season    = data['season'] || Time.now.year
      # device_id is a persistent random hex UUID sent as gc-device-id on every request.
      # Generate once and persist; never changes for this installation.
      @device_id = data['device_id'] || generate_device_id
    rescue Psych::Exception => e
      raise ConfigError, "Malformed config at #{@config_file}: #{e.message}"
    end

    # Parses the session file, memoized per Config instance (see also
    # `@resolved_op_password`). `cached_token` / `cached_refresh_token` are hit
    # 2-3x per API request (Client#authenticate + Client#build_request), so
    # without this a 40-game sync paid ~80 File.read + Psych parses of the same
    # tiny file. Every in-process mutation path (`write_session`, `clear_token`)
    # invalidates the cache, so a mid-run token refresh is never served stale.
    #
    # The cache is keyed on the resolved session path, which depends on
    # GAMECHANGER_HOME at call time — if that env var changes mid-process the
    # next read goes back to disk rather than returning another home's session.
    def load_session
      session = self.class.session_file_path
      return @session_cache if @session_cache_key == session

      @session_cache_key = session
      @session_cache = read_session(session)
    end

    def invalidate_session_cache
      @session_cache_key = nil
      @session_cache = nil
    end

    def read_session(session)
      return nil unless File.exist?(session)

      raw = File.read(session).strip
      return nil if raw.empty?

      # New YAML format
      if raw.start_with?('---') || raw.include?("\n")
        YAML.safe_load(raw) || nil
      # Legacy `<token>|<expires>` single-line format from pre-MFA auth.
      # Treat as access-only with no refresh available.
      else
        token, expires_at = raw.split('|', 2)
        { 'access_token' => token, 'access_expires' => expires_at&.to_i }
      end
    rescue StandardError
      nil
    end

    def write_session(data)
      session = self.class.session_file_path
      FileUtils.mkdir_p(File.dirname(session), mode: 0o700)
      File.open(session, File::WRONLY | File::CREAT | File::TRUNC, 0o600) do |f|
        f.write(YAML.dump(data))
      end
      invalidate_session_cache
    end

    def resolve_op_password(ref)
      require 'open3'
      stdout, stderr, status = Open3.capture3('op', 'read', '--no-newline', ref)
      unless status.success?
        raise ConfigError, "1Password CLI failed to read #{ref}: #{stderr.strip}"
      end

      stdout
    rescue Errno::ENOENT
      raise ConfigError, "1Password CLI (`op`) not found in PATH but password_op_ref is set"
    end

    def generate_device_id
      require 'securerandom'
      SecureRandom.hex(16)  # 32-char hex string matching GC's format
    end

    def write_config(data)
      File.open(@config_file, File::WRONLY | File::CREAT | File::TRUNC, 0o600) do |f|
        f.write(YAML.dump(data))
      end
    end
  end
end
