# frozen_string_literal: true

module Gamechanger
  # Parses batting stats from the /game-stream-processing/{game_id}/boxscore response.
  #
  # The same response as BoxscoreParser, but reads the "lineup" group instead
  # of the "pitching" group. The lineup group's stats array contains per-player
  # batting totals for the game.
  #
  # Usage:
  #   BatterStatsParser.new(response, team_slug: 'wGP47FexatoQ').batter_stats
  #   # => [{ batter_name: "Mason Marrero", at_bats: 3, hits: 2, walks: 1, strikeouts: 0 }, ...]
  #
  # Returns [] when the lineup group is absent or its stats array is empty
  # (e.g. game not yet finalized in GameChanger's scoring system).
  class BatterStatsParser
    # Defensive position codes recognized in `lineup.stats[].player_text`.
    # Unknown codes are logged and skipped (see #fielding_stints).
    KNOWN_POSITIONS = %w[P C 1B 2B 3B SS LF CF RF DH EH].freeze

    def initialize(response, team_slug:)
      @data      = response[team_slug]
      @team_slug = team_slug
      raise APIShapeError, "Team '#{team_slug}' not found in boxscore response" if @data.nil?
    end

    # @return [Array<Hash>] batter stats with keys: batter_name, at_bats, hits, walks, strikeouts
    def batter_stats
      players = build_player_index
      lineup  = lineup_group
      return [] if lineup.nil?

      (lineup['stats'] || []).filter_map do |row|
        player = players[row['player_id']]
        next nil if player.nil?

        stats = row['stats'] || {}
        {
          batter_name: "#{player['first_name']} #{player['last_name']}".strip,
          at_bats:     stats['AB'].to_i,
          hits:        stats['H'].to_i,
          walks:       stats['BB'].to_i,
          strikeouts:  stats['K'].to_i
        }
      end
    end

    # @return [Array<Hash>] fielding stints with keys: player_id, player_name, positions
    #   positions is an ordered Array<String> of recognized position codes.
    #   Rows whose player_text is empty or yields no recognized codes are omitted —
    #   that player did not take the field in this game.
    def fielding_stints
      players = build_player_index
      lineup  = lineup_group
      return [] if lineup.nil?

      (lineup['stats'] || []).filter_map do |row|
        player = players[row['player_id']]
        next nil if player.nil?

        positions = parse_player_text(row['player_text'])
        next nil if positions.empty?

        {
          player_id:   row['player_id'],
          player_name: "#{player['first_name']} #{player['last_name']}".strip,
          positions:   positions
        }
      end
    end

    private

    # Parse a player_text like "(SS, P)" or "(1B, 2B, 1B, P)" into ["SS","P"] / ["1B","2B","1B","P"].
    # Strips the outer parens, splits on comma, trims whitespace, filters to KNOWN_POSITIONS.
    # Unknown tokens emit a warning and are dropped. Empty/nil input returns [].
    def parse_player_text(text)
      return [] if text.nil? || text.empty?

      inner = text.strip.delete_prefix('(').delete_suffix(')')
      return [] if inner.empty?

      inner.split(',').filter_map do |token|
        code = token.strip
        next nil if code.empty?

        if KNOWN_POSITIONS.include?(code)
          code
        else
          warn "BatterStatsParser: ignoring unknown position code #{code.inspect}"
          nil
        end
      end
    end


    def build_player_index
      (@data['players'] || []).each_with_object({}) do |p, idx|
        idx[p['id']] = p
      end
    end

    def lineup_group
      (@data['groups'] || []).find { |g| g['category'] == 'lineup' }
    end
  end
end
