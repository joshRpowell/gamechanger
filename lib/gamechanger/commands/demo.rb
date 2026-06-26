# frozen_string_literal: true

module Gamechanger
  module Commands
    # `gamechanger demo` — render anonymized sample reports with no credentials.
    class Demo < Base
      SAMPLE_AFTER_DATE = '2026-07-11'

      def call
        run_command do
          demo_dir = DemoFixture.stage
          storage = Storage.new(data_dir: demo_dir, season: 2026)

          case options[:report]
          when 'progress' then show_progress(storage)
          else                 show_brief(storage)
          end
        ensure
          storage&.close
          FileUtils.remove_entry_secure(demo_dir) if demo_dir && Dir.exist?(demo_dir)
        end
      end

      private

      def show_brief(storage)
        game_info = storage.next_scheduled_game(after_date: SAMPLE_AFTER_DATE)
        raise StorageError, 'demo fixture has no scheduled sample game' unless game_info

        target_date = Date.parse(game_info['game_date'])
        availability_rows = storage.pitcher_availability_data(before_date: target_date)
        lineup_rows       = storage.batter_lineup_data(before_date: target_date)
        arc_rows          = storage.all_player_development_summary
        equity_rows       = storage.player_participation

        brief_obj = PreGameBrief.new(
          target_date: target_date,
          availability_rows: availability_rows,
          lineup_rows: lineup_rows,
          arc_rows: arc_rows,
          equity_rows: equity_rows,
          rules: PitchRules.new
        )

        puts build_formatter.brief(target_date, game_info, brief_obj)
      end

      def show_progress(storage)
        arcs = DevelopmentArc.build_summary(storage.all_player_development_summary)
        puts build_formatter.progress(arcs)
      end
    end
  end
end
