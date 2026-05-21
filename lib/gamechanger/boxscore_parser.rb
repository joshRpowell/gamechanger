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
  #             { "stat_name": "BF",  "stats": [...] },
  #             { "stat_name": "WP",  "stats": [...] },   # sparse
  #             { "stat_name": "HBP", "stats": [...] }    # sparse
  #           ],
  #           "stats": [{ "player_id", "stats": { "IP", "H", "R", "ER", "BB", "SO" } }]
  #         }
  #       ]
  #     }
  #   }
  class BoxscoreParser
    def initialize(response, team_slug:)
      @data      = response[team_slug]
      @team_slug = team_slug
      raise APIShapeError, "Team '#{team_slug}' not found in boxscore response" if @data.nil?
    end

    # @return [Array<Hash>] pitcher stats with keys:
    #   pitcher_name, pitches_thrown, strikes_thrown, innings_pitched,
    #   batters_faced, wild_pitches, hbp_allowed,
    #   hits_allowed, runs_allowed, earned_runs, walks_issued, strikeouts_recorded
    def pitcher_stats
      players   = build_player_index
      pitching  = pitching_group
      return [] if pitching.nil?

      pitch_counts = extract_extra(pitching, '#P')
      strike_map   = value_map(pitching, 'TS')
      bf_map       = value_map(pitching, 'BF')
      wp_map       = value_map(pitching, 'WP')
      hbp_map      = value_map(pitching, 'HBP')
      stats_map    = build_pitcher_stats_map(pitching)

      pitch_counts.map do |entry|
        player_id = entry['player_id']
        player    = players[player_id]
        next nil if player.nil?

        per = stats_map[player_id] || {}

        {
          pitcher_name:        "#{player['first_name']} #{player['last_name']}".strip,
          pitches_thrown:      entry['value'].to_i,
          strikes_thrown:      strike_map[player_id].to_i,
          innings_pitched:     per['IP'],
          batters_faced:       bf_map[player_id].to_i,
          wild_pitches:        wp_map[player_id].to_i,
          hbp_allowed:         hbp_map[player_id].to_i,
          hits_allowed:        per['H'].to_i,
          runs_allowed:        per['R'].to_i,
          earned_runs:         per['ER'].to_i,
          walks_issued:        per['BB'].to_i,
          strikeouts_recorded: per['SO'].to_i
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

    # Build a player_id → value map from an extra[] entry. Returns {} when the
    # stat is absent (sparse-event fields like WP, HBP).
    def value_map(group, stat_name)
      extract_extra(group, stat_name).each_with_object({}) do |e, h|
        h[e['player_id']] = e['value'].to_i
      end
    end

    # Build a player_id → per-pitcher stats hash ({IP, H, R, ER, BB, SO}).
    def build_pitcher_stats_map(group)
      (group['stats'] || []).each_with_object({}) do |row, map|
        map[row['player_id']] = row['stats'] || {}
      end
    end
  end
end
