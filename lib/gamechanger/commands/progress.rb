# frozen_string_literal: true

module Gamechanger
  module Commands
    # `gamechanger progress` — player development arcs across the season.
    class Progress < Base
      def call
        run_command do
          with_storage do |storage|
            if options[:player]
              show_progress_player(options[:player], :bat, storage)
            elsif options[:pitcher]
              show_progress_player(options[:pitcher], :pitch, storage)
            else
              show_progress(storage)
            end
          end
        end
      end

      private

      def show_progress(storage)
        rows = storage.all_player_development_summary
        if rows.empty?
          shell.say 'No player data cached. Run `gamechanger refresh` to sync.', :yellow
          exit 1
        end
        arcs = DevelopmentArc.build_summary(rows)
        puts build_formatter.progress(arcs)
      end

      def show_progress_player(name, type, storage)
        rows    = storage.all_player_development_summary
        summary = rows.find { |r| r['player_name'].downcase.start_with?(name.downcase) }
        unless summary
          shell.say "No data found for '#{name}'. Run `gamechanger refresh` to sync.", :yellow
          exit 1
        end

        bat_rows   = type == :bat   ? storage.player_batting_arc(player_name: summary['player_name'])   : []
        pitch_rows = type == :pitch ? storage.player_pitching_arc(pitcher_name: summary['player_name']) : []
        arc = DevelopmentArc.build_player(summary, bat_rows, pitch_rows)
        puts build_formatter.progress_player(arc)
      end
    end
  end
end
