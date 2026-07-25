# frozen_string_literal: true

module Gamechanger
  class PitchRules
    DEFAULT_DAILY_MAX = 85
    # [min_pitches, rest_days_required] — checked in order, first match wins
    DEFAULT_REST_THRESHOLDS = [
      [66, 3],
      [51, 2],
      [36, 1],
      [0,  0]
    ].freeze

    def initialize(daily_max: DEFAULT_DAILY_MAX, rest_thresholds: DEFAULT_REST_THRESHOLDS)
      @daily_max       = daily_max
      @rest_thresholds = rest_thresholds
      @parsed_dates    = {}
    end

    def rest_days_required(pitches)
      @rest_thresholds.find { |min, _| pitches >= min }&.last || 0
    end

    # Memoized Date.parse — the heuristic parser is expensive and the same
    # handful of date strings are parsed repeatedly on hot paths (tournament
    # simulation, availability tables).
    #
    # @param value [String, Date, nil]
    # @return [Date, nil] nil only when value is nil
    def parse_date(value)
      return nil if value.nil?
      return value if value.instance_of?(Date)

      key = value.to_s
      @parsed_dates[key] ||= Date.parse(key)
    end

    def available_date(last_outing_date, pitches)
      return Date.today if last_outing_date.nil?

      parse_date(last_outing_date) + rest_days_required(pitches) + 1
    end

    def available_on?(target_date, last_outing_date, pitches)
      return true if last_outing_date.nil?

      target_date >= available_date(last_outing_date, pitches)
    end

    def pitches_remaining(last_outing_pitches)
      [@daily_max - last_outing_pitches, 0].max
    end

    attr_reader :daily_max
  end
end
