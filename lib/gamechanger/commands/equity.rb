# frozen_string_literal: true

module Gamechanger
  module Commands
    # `gamechanger equity` — playing time participation for all players.
    class Equity < Base
      def call
        run_command do
          with_storage do |storage|
            rows = storage.player_participation
            if rows.empty?
              shell.say 'No player data in cache. Run `gamechanger refresh` to sync.', :yellow
              exit 1
            end
            puts build_formatter.equity(rows)
          end
        end
      end
    end
  end
end
