# frozen_string_literal: true

module Gamechanger
  module Commands
    # `gamechanger refresh` — force re-sync of latest game data.
    #
    # Output respects --format: 'human' (default) prints a green count line,
    # 'json' prints a parseable JSON object for piping into other tools.
    class Refresh < Base
      def call
        run_command do
          config = load_config!
          with_storage(season: config.season) do |storage|
            shell.say 'Syncing games from Gamechanger...', :cyan
            result = Syncer.new(config, storage).run(force: true)
            if options[:format] == 'json'
              require 'json' # opt-in output format; keep json off the startup path
              puts JSON.generate({ games: result.games, outings: result.outings, at_bats: result.at_bats })
            else
              shell.say format_human(result), :green
            end
          end
        end
      end

      private

      def format_human(result)
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
