# frozen_string_literal: true

module Gamechanger
  # Value object representing a single player's development trajectory across the season.
  PlayerArc = Struct.new(
    :player_name,
    :first_half_obp, :second_half_obp, :recent_obp, :total_games_batted,
    :first_half_strike_pct, :second_half_strike_pct, :recent_strike_pct, :total_games_pitched,
    :bat_sparkline, :pitch_sparkline,
    :bat_trend, :pitch_trend,
    :bat_narrative, :pitch_narrative,
    keyword_init: true
  )

  # Translates raw storage rows into PlayerArc structs with sparklines and narrative summaries.
  #
  # Sparklines normalize to each player's own min/max range so variation is visible
  # regardless of absolute performance level.
  #
  # Narrative archetypes (5 total):
  #   - strong arc:        second half significantly better than first
  #   - recent surge:      last 5 games significantly better than season avg
  #   - consistent:        delta < threshold in either direction
  #   - early-season strong: first half significantly better than second
  #   - limited sample:    fewer than MIN_RECENT_GAMES appearances
  class DevelopmentArc
    SPARKLINE_CHARS    = '▁▂▃▄▅▆▇█'.chars.freeze
    NARRATIVE_THRESHOLD = 0.050  # 50 OBP points or 5 strike% points
    MIN_RECENT_GAMES    = 5

    def self.build_summary(rows)
      rows.map { |r| build_arc(r) }
    end

    def self.build_player(summary_row, bat_rows, pitch_rows)
      arc = build_arc(summary_row)
      arc.bat_sparkline   = sparkline_for(bat_rows.map   { |r| per_game_obp(r) })
      arc.pitch_sparkline = sparkline_for(pitch_rows.map { |r| per_outing_strike_pct(r) })
      arc
    end

    private_class_method def self.build_arc(r)
      bat_trend   = trend_indicator(r['first_half_obp']&.to_f,        r['second_half_obp']&.to_f)
      pitch_trend = trend_indicator(r['first_half_strike_pct']&.to_f, r['second_half_strike_pct']&.to_f)

      PlayerArc.new(
        player_name:            r['player_name'],
        first_half_obp:         r['first_half_obp']&.to_f,
        second_half_obp:        r['second_half_obp']&.to_f,
        recent_obp:             r['recent_obp']&.to_f,
        total_games_batted:     r['total_games_batted']&.to_i,
        first_half_strike_pct:  r['first_half_strike_pct']&.to_f,
        second_half_strike_pct: r['second_half_strike_pct']&.to_f,
        recent_strike_pct:      r['recent_strike_pct']&.to_f,
        total_games_pitched:    r['total_games_pitched']&.to_i,
        bat_sparkline:          '',
        pitch_sparkline:        '',
        bat_trend:              bat_trend,
        pitch_trend:            pitch_trend,
        bat_narrative:          narrative_for(
                                  r['first_half_obp']&.to_f, r['second_half_obp']&.to_f,
                                  r['recent_obp']&.to_f,     r['total_games_batted']&.to_i,
                                  type: :bat
                                ),
        pitch_narrative:        narrative_for(
                                  r['first_half_strike_pct']&.to_f, r['second_half_strike_pct']&.to_f,
                                  r['recent_strike_pct']&.to_f,     r['total_games_pitched']&.to_i,
                                  type: :pitch
                                )
      )
    end

    private_class_method def self.trend_indicator(first, second)
      return nil unless first && second

      delta = second - first
      if delta > NARRATIVE_THRESHOLD
        '↑'
      elsif delta < -NARRATIVE_THRESHOLD
        '↓'
      else
        '→'
      end
    end

    private_class_method def self.narrative_for(first_half, second_half, recent, total_games, type:)
      return nil unless first_half || second_half

      if (total_games || 0) < MIN_RECENT_GAMES
        return type == :bat ? "Building their game — more at-bats will tell the full story" \
                            : "Building their game — more outings will tell the full story"
      end

      delta = (second_half || first_half).to_f - (first_half || second_half).to_f

      if type == :bat
        if delta > NARRATIVE_THRESHOLD
          format("Peaking at the right time — OBP up .%03d in the second half", (delta * 1000).round)
        elsif delta < -NARRATIVE_THRESHOLD
          "Strong starter — coaching opportunity to recapture early-season form"
        elsif recent && first_half && (recent - first_half) > NARRATIVE_THRESHOLD
          format("Finding their groove — .%03d OBP over last 5 games", (recent * 1000).round)
        else
          season_avg = ((first_half.to_f + (second_half || first_half).to_f) / 2.0)
          format("Steady contributor — .%03d OBP all season", (season_avg * 1000).round)
        end
      else
        if delta > NARRATIVE_THRESHOLD
          format("Strike command sharpening — %d percentage points gained this half", (delta * 100).round)
        elsif delta < -NARRATIVE_THRESHOLD
          "Strong start — coaching opportunity to recapture early-season command"
        elsif recent && first_half && (recent - first_half) > NARRATIVE_THRESHOLD
          format("Finding their groove — %d%% strike rate over last 5 outings", (recent * 100).round)
        else
          season_avg = ((first_half.to_f + (second_half || first_half).to_f) / 2.0)
          format("Consistent command — %d%% strike rate all season", (season_avg * 100).round)
        end
      end
    end

    def self.sparkline_for(values)
      return '' if values.empty?

      min  = values.min
      max  = values.max
      span = max - min

      values.map do |v|
        idx = span.zero? ? 3 : ((v - min) / span * 7).round.clamp(0, 7)
        SPARKLINE_CHARS[idx]
      end.join
    end

    private_class_method def self.per_game_obp(r)
      denom = r['at_bats'].to_f + r['walks'].to_f
      denom.zero? ? 0.0 : (r['hits'].to_f + r['walks'].to_f) / denom
    end

    private_class_method def self.per_outing_strike_pct(r)
      pitches = r['pitches_thrown'].to_f
      pitches.zero? ? 0.0 : r['strikes_thrown'].to_f / pitches
    end
  end
end
