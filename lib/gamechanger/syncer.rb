# frozen_string_literal: true

module Gamechanger
  # Fetches and persists games + pitcher/batter stats from the Gamechanger API.
  #
  # Extracted from CLI so sync logic can be unit-tested and reused
  # without Thor internals. Errors propagate to the caller.
  #
  # Usage:
  #   Syncer.new(config, storage).run(force: true)
  class Syncer
    def initialize(config, storage)
      @config  = config
      @storage = storage
    end

    # Sync all past games and their pitcher/batter stats into storage.
    # @param force [Boolean] re-fetch games even if already cached as final
    # @raise [ConfigError]   if team_id or team_slug is not configured
    # @raise [AuthError]     on invalid credentials
    # @raise [NetworkError]  on connection failures or HTTP errors
    # @raise [APIShapeError] if the API response shape is unexpected
    def run(force: false)
      @storage.clear_non_final if force

      team_id   = @config.team_id
      team_slug = @config.team_slug

      if team_id.nil? || team_id.to_s.empty?
        raise ConfigError, 'No team_id configured. Run `gamechanger setup` again.'
      end

      if team_slug.nil? || team_slug.to_s.empty?
        raise ConfigError,
              'No team_slug configured. Run `gamechanger setup` again. ' \
              'Or add team_slug to ~/.gamechanger/config.yml (the short ID from your team URL).'
      end

      client     = Client.new(config: @config)
      raw_games  = client.games(team_id: team_id)
      games_list = extract_games(raw_games)
      today      = Date.today.to_s

      games_list.each do |game|
        parsed = parse_game(game)
        next if parsed[:status] == 'canceled'
        next if parsed[:game_date].nil? || parsed[:game_date] > today

        @storage.upsert_game(parsed)

        cached = @storage.all_games.find { |g| g['game_id'] == parsed[:game_id] }
        next if cached && cached['status'] == 'final' && !force

        sleep Client::RATE_LIMIT_SLEEP
        raw_boxscore = client.game_pitcher_stats(game_id: parsed[:game_id])
        stats        = BoxscoreParser.new(raw_boxscore, team_slug: team_slug).pitcher_stats
        @storage.upsert_pitcher_stats(game_id: parsed[:game_id], stats: stats)

        batter_stats = BatterStatsParser.new(raw_boxscore, team_slug: team_slug).batter_stats
        @storage.upsert_batter_stats(game_id: parsed[:game_id], stats: batter_stats) if batter_stats.any?

        @storage.upsert_game(parsed.merge(status: 'final')) if stats.any?
      end
    end

    private

    # Confirmed from /teams/{uuid}/schedule?fetch_place_details=true response.
    # Returns a bare array of {event:, pregame_data:} objects (practices and games mixed).
    # Filters to event_type=="game" only.
    def extract_games(response)
      list = if response.is_a?(Array)
               response
             elsif response.is_a?(Hash)
               response['schedule'] || response['events'] || response['data'] || []
             else
               raise APIShapeError, "Unexpected schedule response shape: #{response.class}"
             end

      list.select { |item| item.dig('event', 'event_type') == 'game' }
    end

    # Confirmed field names from /teams/{uuid}/schedule response.
    # Each item is {event: {...}, pregame_data: {...}}.
    def parse_game(raw)
      event   = raw['event']
      pregame = raw['pregame_data']

      game_date = event.dig('start', 'datetime')&.split('T')&.first ||
                  event.dig('start', 'date')

      {
        game_id:   event['id'],
        game_date: game_date,
        opponent:  pregame&.dig('opponent_name') || event['title'],
        home_away: pregame&.dig('home_away'),
        status:    normalize_status(event['status'])
      }
    end

    def normalize_status(raw_status)
      case raw_status.to_s.downcase
      when /completed|final|ended/ then 'final'
      when /progress|live|active/  then 'in_progress'
      when /scheduled|upcoming/    then 'scheduled'
      else raw_status.to_s.downcase
      end
    end
  end
end
