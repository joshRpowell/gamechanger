# frozen_string_literal: true

module Gamechanger
  module Commands
    # `gamechanger availability` — pitcher availability and rest status for the next game.
    class Availability < Base
      def call
        run_command do
          with_storage do |storage|
            target_date, game_info = resolve_target(options[:date], storage: storage)
            rows  = storage.pitcher_availability_data(before_date: target_date)
            rules = PitchRules.new
            puts build_formatter.availability(target_date, game_info, rows, rules)
          end
        end
      end
    end
  end
end
