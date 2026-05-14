# frozen_string_literal: true

module Gamechanger
  module Commands
    # `gamechanger hitting` — season batting stats, or per-player game-by-game breakdown.
    class Hitting < Base
      def call
        run_command do
          with_storage do |storage|
            if options[:player]
              show_batter(options[:player], storage)
            else
              show_hitting(storage)
            end
          end
        end
      end

      private

      def show_hitting(storage)
        rows = storage.season_batting_summary
        if rows.empty?
          shell.say 'No batting data in cache. Run `gamechanger refresh` to sync.', :yellow
          exit 1
        end
        puts build_formatter.hitting(rows)
      end

      def show_batter(name, storage)
        result = storage.batter_games(name)

        if result.empty?
          shell.say "No batter matching '#{name}' found this season.", :yellow
          exit 1
        end

        if result.first.is_a?(String)
          shell.say 'Ambiguous name — did you mean:', :yellow
          result.each { |n| shell.say "  #{n}" }
          exit 1
        end

        batter_name = result.first&.dig('batter_name') || name
        puts build_formatter.batter_games(batter_name, result)
      end
    end
  end
end
