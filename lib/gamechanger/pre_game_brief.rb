# frozen_string_literal: true

module Gamechanger
  # Coordinator value object for the `gc brief` pre-game intelligence brief.
  #
  # Receives raw storage rows and delegates computation to existing value objects
  # (LineupOptimizer, DevelopmentArc, PitchRules). No I/O — pure computation.
  #
  # Usage:
  #   brief = PreGameBrief.new(target_date:, availability_rows:, lineup_rows:,
  #                            arc_rows:, equity_rows:, rules:)
  #   brief.pitcher_plan          # => Array<Hash> enriched with availability
  #   brief.lineup                # => LineupOptimizer
  #   brief.development_spotlights # => Array<PlayerArc>
  #   brief.equity_flags          # => Array<Hash>
  class PreGameBrief
    def initialize(target_date:, availability_rows:, lineup_rows:, arc_rows:, equity_rows:, rules:)
      @target_date       = target_date
      @availability_rows = availability_rows
      @lineup_rows       = lineup_rows
      @arc_rows          = arc_rows
      @equity_rows       = equity_rows
      @rules             = rules
    end

    # All pitchers enriched with availability status.
    # Sorted: available first (by remaining pitches desc), then unavailable.
    # @return [Array<Hash>] rows from pitcher_availability_data plus 'available', 'remaining',
    #                       'avail_date', 'high_load' keys
    def pitcher_plan
      @pitcher_plan ||= @availability_rows.map do |r|
        last_pitches = r['last_pitches'].to_i
        avail        = @rules.available_on?(@target_date, r['last_outing'], last_pitches)
        remaining    = @rules.pitches_remaining(last_pitches)
        avail_date   = r['last_outing'] ? @rules.available_date(r['last_outing'], last_pitches) : nil
        seven_day    = r['seven_day_total'].to_i

        r.merge(
          'available'  => avail,
          'remaining'  => remaining,
          'avail_date' => avail_date,
          'high_load'  => seven_day > 75
        )
      end.sort_by { |r| [r['available'] ? 0 : 1, -r['remaining'], r['pitcher_name'].to_s] }
    end

    # @return [LineupOptimizer]
    def lineup
      @lineup ||= LineupOptimizer.new(@lineup_rows)
    end

    # Up to 3 notable development trajectories: improving batters (max 2) + declining (max 1).
    # @return [Array<PlayerArc>]
    def development_spotlights
      return [] if @arc_rows.empty?

      all        = DevelopmentArc.build_summary(@arc_rows)
      improving  = all.select { |a| a.bat_trend == '↑' }.first(2)
      needs_attn = all.select { |a| a.bat_trend == '↓' }.first(1)
      (improving + needs_attn).uniq
    end

    # Players with below-threshold batting participation (< 60% of team games).
    # Sorted ascending by games batted (most underplayed first).
    # @return [Array<Hash>]
    def equity_flags
      return [] if @equity_rows.empty?

      total = @equity_rows.first['total_games'].to_i
      return [] if total.zero?

      @equity_rows.select do |r|
        r['total_games_batted'].to_i.to_f / total < 0.6
      end.sort_by { |r| r['total_games_batted'].to_i }
    end
  end
end
