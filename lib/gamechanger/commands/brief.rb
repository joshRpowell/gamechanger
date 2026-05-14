# frozen_string_literal: true

module Gamechanger
  module Commands
    # `gamechanger brief` — pre-game intelligence brief (pitcher plan, lineup, equity, development).
    class Brief < Base
      def call
        run_command do
          with_storage do |storage|
            target_date, game_info = resolve_target(options[:date], storage: storage)

            availability_rows = storage.pitcher_availability_data(before_date: target_date)
            lineup_rows       = storage.batter_lineup_data(before_date: target_date)
            arc_rows          = storage.all_player_development_summary
            equity_rows       = storage.player_participation

            brief_obj = PreGameBrief.new(
              target_date:       target_date,
              availability_rows: availability_rows,
              lineup_rows:       lineup_rows,
              arc_rows:          arc_rows,
              equity_rows:       equity_rows,
              rules:             PitchRules.new
            )

            puts build_formatter.brief(target_date, game_info, brief_obj)
          end
        end
      end
    end
  end
end
