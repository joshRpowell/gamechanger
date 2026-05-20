# frozen_string_literal: true

module Gamechanger
  module Commands
    # `gamechanger equity` — playing time participation for all players.
    class Equity < Base
      EQUITY_SORT_KEYS = {
        'name'     => ->(r) { r['player_name'] },
        'bat'      => ->(r) { r['last_bat_date'] },
        'batago'   => ->(r) { r['games_since_last_batted']&.to_i },
        'batted'   => ->(r) { r['total_games_batted']&.to_i },
        'pitch'    => ->(r) { r['last_pitch_date'] },
        'pitchago' => ->(r) { r['games_since_last_pitched']&.to_i }
      }.freeze

      def call
        run_command do
          with_storage do |storage|
            rows = storage.player_participation
            if rows.empty?
              shell.say 'No player data in cache. Run `gamechanger refresh` to sync.', :yellow
              exit 1
            end
            rows = Sorting.apply(rows, options[:sort], EQUITY_SORT_KEYS, desc: options[:desc])
            puts build_formatter.equity(rows)
          end
        end
      rescue Sorting::InvalidSortKey => e
        shell.say_error e.message, :red
        exit 1
      end
    end
  end
end
