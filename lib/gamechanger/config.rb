# frozen_string_literal: true

require 'yaml'
require 'fileutils'

module Gamechanger
  class Config
    CONFIG_DIR  = File.expand_path('~/.gamechanger').freeze
    CONFIG_FILE = File.join(CONFIG_DIR, 'config.yml').freeze
    SESSION_FILE = File.join(CONFIG_DIR, 'session').freeze

    attr_reader :email, :password, :team_id, :team_slug, :season, :device_id

    def initialize(config_file: CONFIG_FILE)
      @config_file = config_file
      FileUtils.mkdir_p(File.dirname(@config_file), mode: 0o700)
      load_config
    end

    def configured?
      !email.nil? && !email.empty? && !password.nil? && !password.empty?
    end

    def save(email:, password:, team_id: nil, team_slug: nil, season: nil)
      raise ConfigError, 'Email cannot be empty'    if email.to_s.strip.empty?
      raise ConfigError, 'Password cannot be empty' if password.to_s.strip.empty?

      data = { 'email' => email.strip, 'password' => password.strip }
      data['team_id']   = team_id.to_s   if team_id
      data['team_slug'] = team_slug.to_s if team_slug
      data['season']    = season.to_i    if season
      data['device_id'] = @device_id     # preserve existing device_id across saves

      write_config(data)
      load_config
    end

    def cached_token
      return nil unless File.exist?(SESSION_FILE)

      token, expires_at = File.read(SESSION_FILE).strip.split('|', 2)
      return nil if token.nil? || token.empty?
      return nil if expires_at && Time.now.to_i > expires_at.to_i

      token
    rescue StandardError
      nil
    end

    def cache_token(token, expires_at: nil)
      expires_at ||= Time.now.to_i + 3600  # fallback TTL if API doesn't provide expiry
      File.open(SESSION_FILE, File::WRONLY | File::CREAT | File::TRUNC, 0o600) do |f|
        f.write("#{token}|#{expires_at}")
      end
    end

    def clear_token
      File.delete(SESSION_FILE) if File.exist?(SESSION_FILE)
    end

    private

    def load_config
      unless File.exist?(@config_file)
        @email = @password = @team_id = @season = nil
        return
      end

      data = YAML.safe_load(File.read(@config_file), symbolize_names: false) || {}
      @email     = data['email']
      @password  = data['password']
      @team_id   = data['team_id']
      @team_slug = data['team_slug']  # short slug used as boxscore response key (e.g. wGP47FexatoQ)
      @season    = data['season'] || Time.now.year
      # device_id is a persistent random hex UUID sent as gc-device-id on every request.
      # Generate once and persist; never changes for this installation.
      @device_id = data['device_id'] || generate_device_id
    rescue Psych::Exception => e
      raise ConfigError, "Malformed config at #{@config_file}: #{e.message}"
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
