# frozen_string_literal: true

module Gamechanger
  module Commands
    # `gamechanger refresh` — force re-sync of latest game data.
    #
    # Calls Syncer with force: true to re-fetch non-final games,
    # then reports counts of games / outings / at-bats updated.
    class Refresh < Base
      def call
        run_command do
          config = load_config!
          with_storage(season: config.season) do |storage|
            shell.say 'Syncing games from Gamechanger...', :cyan
            result = Syncer.new(config, storage).run(force: true)
            shell.say format_result(result), :green
          end
        end
      end

      private

      def format_result(result)
        games   = result.games
        outings = result.outings
        at_bats = result.at_bats
        "#{games} game#{'s' unless games == 1}, " \
          "#{outings} outing#{'s' unless outings == 1}, " \
          "#{at_bats} at-bat#{'s' unless at_bats == 1} updated."
      end
    end
  end
end
