# frozen_string_literal: true

module Gamechanger
  # Represents a single game's pitcher assignment in the tournament plan.
  GameAssignment = Struct.new(
    :game_number, :game_date, :opponent,
    :starter_name, :starter_pitches,
    :reliever_name, :reliever_pitches,
    keyword_init: true
  )

  # Post-tournament projected state for a single pitcher.
  PitcherProjection = Struct.new(
    :pitcher_name, :weekend_total, :last_outing, :last_pitches,
    keyword_init: true
  )

  # Plans pitcher deployment across a multi-game tournament weekend.
  #
  # Pure value object — no I/O. Accepts pitcher state from Storage and
  # PitchRules, runs a forward-simulation constraint-satisfaction algorithm,
  # and produces an ordered list of GameAssignment structs.
  #
  # Algorithm: for each game in chronological order, build the eligible
  # pitcher pool (USSSA-compliant given projections so far), sort by
  # lowest projected weekend total, optionally promote the ace, and assign
  # starter (45 pitches) and reliever (30 pitches). Pitch counts accumulate
  # within a calendar day to correctly handle same-day doubleheaders.
  class TournamentPlanner
    STARTER_PITCHES  = 45
    RELIEVER_PITCHES = 30

    # @param games [Array<Hash>] ordered list of {game_date:, opponent:} (string or sym keys)
    # @param rows [Array<Hash>] from Storage#pitcher_availability_data (string keys)
    # @param rules [PitchRules]
    # @param ace [String, nil] pitcher name to promote to starter of first eligible game
    # @param skip [Array<String>] pitcher names to exclude entirely
    def initialize(games:, rows:, rules:, ace: nil, skip: [])
      @games = games
      @rules = rules
      @ace   = ace&.downcase
      @skip  = (skip || []).map(&:downcase)
      @state = build_initial_state(rows)
    end

    # @return [Array<GameAssignment>]
    def assignments
      @assignments ||= generate_plan
    end

    # @return [Array<PitcherProjection>]
    def projections
      @projections ||= begin
        generate_plan unless @assignments
        @state.map do |name, s|
          PitcherProjection.new(
            pitcher_name:  name,
            weekend_total: s[:weekend_total],
            last_outing:   s[:last_outing],
            last_pitches:  s[:last_pitches]
          )
        end.sort_by(&:pitcher_name)
      end
    end

    private

    def build_initial_state(rows)
      rows.each_with_object({}) do |row, h|
        name = row['pitcher_name']
        h[name] = {
          last_outing:   row['last_outing'],       # String date or nil
          last_pitches:  row['last_pitches'].to_i, # same-day total as of last outing
          weekend_total: 0,                        # pitches projected this weekend
          daily_total:   Hash.new(0),              # date_string => pitches this weekend
          ace_used:      false                     # ace has been assigned as starter
        }
      end
    end

    def generate_plan
      result = []

      @games.each.with_index(1) do |game, number|
        game_date = normalize_date(game)
        opponent  = game['opponent'] || game[:opponent]

        # Parsed once per game and threaded through the eligibility predicates —
        # can_pitch? runs O(games × pitchers) times per plan.
        parsed_date = @rules.parse_date(game_date)

        eligible = eligible_pitchers(game_date, parsed_date)

        starter_name, starter_pitches = pick_pitcher(eligible, game_date, parsed_date, STARTER_PITCHES, exclude: [])
        reliever_name, reliever_pitches = pick_pitcher(eligible, game_date, parsed_date, RELIEVER_PITCHES,
                                                       exclude: [starter_name].compact)

        assign!(starter_name, game_date, starter_pitches)  if starter_name
        assign!(reliever_name, game_date, reliever_pitches) if reliever_name

        result << GameAssignment.new(
          game_number:      number,
          game_date:        game_date,
          opponent:         opponent,
          starter_name:     starter_name,
          starter_pitches:  starter_name ? starter_pitches : nil,
          reliever_name:    reliever_name,
          reliever_pitches: reliever_name ? reliever_pitches : nil
        )
      end

      result
    end

    # Build the eligible pitcher list for a game, sorted by weekend_total ASC.
    # Applies ace promotion: ace goes first if eligible and not yet used as starter.
    def eligible_pitchers(game_date, parsed_date)
      list = @state.reject { |name, _| @skip.include?(name.downcase) }
                   .select { |name, _| can_pitch?(name, game_date, parsed_date, 1) }
                   .sort_by { |_, s| s[:weekend_total] }
                   .map { |name, _| name }

      # Ace promotion: move ace to front if eligible and not yet used
      if @ace
        ace_name = list.find { |n| n.downcase == @ace }
        if ace_name && !@state[ace_name][:ace_used]
          list = [ace_name] + list.reject { |n| n == ace_name }
        end
      end

      list
    end

    # Pick a pitcher for a role, checking they can absorb target_pitches within daily max.
    def pick_pitcher(eligible, game_date, parsed_date, target_pitches, exclude:)
      # NOTE: this re-check is load-bearing — it must observe state mutated by
      # a preceding assign! (e.g. the starter's same-day pitch count).
      candidate = eligible.reject { |n| exclude.include?(n) }
                          .find { |n| can_pitch?(n, game_date, parsed_date, target_pitches) }
      return [nil, nil] unless candidate

      actual_pitches = actual_pitches_for(candidate, game_date, target_pitches)
      [candidate, actual_pitches]
    end

    # Whether pitcher can absorb at least `min_pitches` on game_date given current state.
    def can_pitch?(name, game_date, parsed_date, min_pitches)
      s = @state[name]
      return false unless s
      return false unless @rules.available_on?(parsed_date, s[:last_outing], s[:last_pitches])

      remaining_daily = @rules.daily_max - s[:daily_total][game_date]
      remaining_daily >= min_pitches
    end

    # Actual pitches to assign — capped by remaining daily capacity.
    def actual_pitches_for(name, game_date, target)
      remaining = @rules.daily_max - @state[name][:daily_total][game_date]
      [target, remaining].min
    end

    # Update pitcher state after assignment.
    def assign!(name, game_date, pitches)
      s = @state[name]
      s[:daily_total][game_date] += pitches
      s[:weekend_total]          += pitches
      s[:last_outing]   = game_date
      s[:last_pitches]  = s[:daily_total][game_date]  # same-day total drives rest calc
      s[:ace_used]      = true if @ace && name.downcase == @ace
    end

    def normalize_date(game)
      (game['game_date'] || game[:game_date]).to_s
    end
  end
end
