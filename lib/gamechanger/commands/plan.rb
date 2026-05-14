# frozen_string_literal: true

module Gamechanger
  module Commands
    # `gamechanger plan` — tournament pitcher deployment plan.
    # Game slots come from --games (explicit), --from/--to (range), or the next
    # scheduled game (default).
    class Plan < Base
      def call
        run_command do
          with_storage do |storage|
            game_slots = resolve_plan_games(storage: storage)
            first_date = game_slots.first && (game_slots.first['game_date'] || game_slots.first[:game_date])
            rows       = storage.pitcher_availability_data(before_date: first_date)

            if rows.empty?
              shell.say 'No pitcher data in cache. Run `gamechanger refresh` to sync.', :yellow
              exit 1
            end

            skip_list = options[:skip] ? options[:skip].split(',').map(&:strip) : []
            rules     = PitchRules.new
            planner   = TournamentPlanner.new(
              games: game_slots,
              rows:  rows,
              rules: rules,
              ace:   options[:ace],
              skip:  skip_list
            )

            next_date = resolve_next_game_date(storage)
            puts build_formatter.plan(planner.assignments, planner.projections, next_date, rules)
          end
        end
      end

      private

      # Resolve game slots from --games, --from/--to, or next scheduled game.
      # --games takes precedence over --from/--to.
      def resolve_plan_games(storage:)
        if options[:games]
          dates = options[:games].split(',').map(&:strip)
          dates.map do |d|
            parsed = parse_required_date!(d, '--games')
            { 'game_date' => parsed.to_s, 'opponent' => nil }
          end
        elsif options[:from]
          from_date = parse_required_date!(options[:from], '--from')
          to_date   = options[:to] ? parse_required_date!(options[:to], '--to') : from_date

          games = storage.scheduled_games_between(from_date: from_date, to_date: to_date)
          if games.empty?
            shell.say "No scheduled games found between #{from_date} and #{to_date}. Run `gamechanger refresh` to sync the schedule.", :yellow
            exit 1
          end
          games
        else
          game = storage.next_scheduled_game
          if game.nil?
            shell.say 'No upcoming games in cache. Run `gamechanger refresh` to sync the schedule.', :yellow
            exit 1
          end
          [game]
        end
      end

      def resolve_next_game_date(storage)
        if options[:next_game]
          parse_required_date!(options[:next_game], '--next-game')
        else
          game = storage.next_scheduled_game
          game ? Date.parse(game['game_date']) : nil
        end
      end

      def parse_required_date!(value, flag_name)
        Date.parse(value)
      rescue Date::Error
        # Match the historical error message formats so existing tests stay green.
        message = if flag_name == '--games'
          "Invalid date '#{value}' in --games — expected YYYY-MM-DD"
        else
          "Invalid #{flag_name} date '#{value}' — expected YYYY-MM-DD"
        end
        shell.say message, :red
        exit 1
      end
    end
  end
end
