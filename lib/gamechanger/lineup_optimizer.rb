# frozen_string_literal: true

module Gamechanger
  # Translates batter rows from Storage#batter_lineup_data into a ranked batting order.
  #
  # Players with 7-day AB > 0 are ranked by 7-day OBP descending.
  # Players with no 7-day data are returned as "unranked" (position nil).
  #
  # OBP = (hits + walks) / (at_bats + walks). Guard against zero denominator.
  #
  # Usage:
  #   optimizer = LineupOptimizer.new(rows)
  #   optimizer.ranked   # => [PlayerSlot(position: 1, ...), ...]
  #   optimizer.unranked # => [PlayerSlot(position: nil, ...), ...]
  class LineupOptimizer
    PlayerSlot = Struct.new(
      :position, :batter_name, :seven_day_obp, :season_obp, :trend,
      keyword_init: true
    )

    TREND_THRESHOLD = 0.05

    def initialize(rows)
      @rows = rows
    end

    def ranked
      @ranked ||= rows_with_data
        .sort_by { |r| -seven_day_obp(r) }
        .each_with_index
        .map { |r, i| build_slot(r, position: i + 1) }
    end

    def unranked
      @unranked ||= rows_without_data.map { |r| build_slot(r, position: nil) }
    end

    private

    def rows_with_data
      @rows.select { |r| r['seven_day_ab'].to_i > 0 }
    end

    def rows_without_data
      @rows.reject { |r| r['seven_day_ab'].to_i > 0 }
    end

    def seven_day_obp(row)
      denom = row['seven_day_ab'].to_i + row['seven_day_walks'].to_i
      return 0.0 if denom.zero?

      (row['seven_day_hits'].to_i + row['seven_day_walks'].to_i).to_f / denom
    end

    def season_obp(row)
      denom = row['season_ab'].to_i + row['season_walks'].to_i
      return 0.0 if denom.zero?

      (row['season_hits'].to_i + row['season_walks'].to_i).to_f / denom
    end

    def trend(row)
      s7  = seven_day_obp(row)
      sea = season_obp(row)
      diff = s7 - sea
      if diff > TREND_THRESHOLD
        '↗'
      elsif diff < -TREND_THRESHOLD
        '↘'
      else
        '→'
      end
    end

    def build_slot(row, position:)
      PlayerSlot.new(
        position:      position,
        batter_name:   row['batter_name'],
        seven_day_obp: seven_day_obp(row),
        season_obp:    season_obp(row),
        trend:         trend(row)
      )
    end
  end
end
