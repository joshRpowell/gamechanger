# frozen_string_literal: true

module Gamechanger
  module Commands
    # `gamechanger lineup` — suggested batting order for the next game based on recent OBP.
    class Lineup < Base
      def call
        run_command do
          with_storage do |storage|
            target_date, game_info = resolve_target(options[:date], storage: storage)
            rows      = storage.batter_lineup_data(before_date: target_date)
            optimizer = LineupOptimizer.new(rows)
            puts build_formatter.lineup(target_date, game_info, optimizer)
          end
        end
      end
    end
  end
end
