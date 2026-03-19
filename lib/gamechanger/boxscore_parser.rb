# frozen_string_literal: true

module Gamechanger
  # Parses the /game-stream-processing/{game_id}/boxscore response.
  #
  # Response shape:
  #   {
  #     "{team_slug}": {
  #       "players": [{ "id", "first_name", "last_name", "number" }],
  #       "groups": [
  #         {
  #           "category": "pitching",
  #           "extra": [
  #             { "stat_name": "#P",  "stats": [{ "player_id", "value" }] },
  #             { "stat_name": "TS",  "stats": [...] },
  #             { "stat_name": "BF",  "stats": [...] }
  #           ],
  #           "stats": [{ "player_id", "stats": { "IP", "H", "R", "ER", "BB", "SO" } }]
  #         }
  #       ]
  #     }
  #   }
  #
  # Usage:
  #   BoxscoreParser.new(response, team_slug: 'wGP47FexatoQ').pitcher_stats
  #   # => [{ pitcher_name: "Asher Lima", pitches_thrown: 59, innings_pitched: 4.0 }, ...]
  class BoxscoreParser
    def initialize(response, team_slug:)
      @data      = response[team_slug]
      @team_slug = team_slug
      raise APIShapeError, "Team '#{team_slug}' not found in boxscore response" if @data.nil?
    end

    # @return [Array<Hash>] pitcher stats with keys: pitcher_name, pitches_thrown, strikes_thrown, innings_pitched
    def pitcher_stats
      players   = build_player_index
      pitching  = pitching_group
      return [] if pitching.nil?

      pitch_counts = extract_extra(pitching, '#P')   # total pitches
      strike_map   = extract_extra(pitching, 'TS').each_with_object({}) do |e, h|
        h[e['player_id']] = e['value'].to_i
      end
      innings_map  = build_ip_map(pitching)

      pitch_counts.map do |entry|
        player_id = entry['player_id']
        player    = players[player_id]
        next nil if player.nil?

        {
          pitcher_name:    "#{player['first_name']} #{player['last_name']}".strip,
          pitches_thrown:  entry['value'].to_i,
          strikes_thrown:  strike_map[player_id],
          innings_pitched: innings_map[player_id]
        }
      end.compact
    end

    private

    def build_player_index
      (@data['players'] || []).each_with_object({}) do |p, idx|
        idx[p['id']] = p
      end
    end

    def pitching_group
      (@data['groups'] || []).find { |g| g['category'] == 'pitching' }
    end

    # Pull stat values for a given stat_name from the extra array.
    # Returns array of { player_id, value } hashes.
    def extract_extra(group, stat_name)
      entry = (group['extra'] || []).find { |e| e['stat_name'] == stat_name }
      entry ? (entry['stats'] || []) : []
    end

    # Build a player_id → innings_pitched map from the pitching stats array.
    # IP is stored as a float (e.g. 4.333 for 4⅓ innings).
    def build_ip_map(group)
      (group['stats'] || []).each_with_object({}) do |row, map|
        map[row['player_id']] = row.dig('stats', 'IP')
      end
    end
  end
end
