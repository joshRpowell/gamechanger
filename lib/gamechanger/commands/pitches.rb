# frozen_string_literal: true

module Gamechanger
  module Commands
    # `gamechanger pitches` — pitcher workload summary for the season.
    # Supports filtering to a single pitcher, a single game by date, or showing
    # the season-wide summary. Syncs from the API on every invocation.
    class Pitches < Base
      def call
        run_command do
          config = load_config!
          with_storage(season: config.season) do |storage|
            shell.say 'Syncing games from Gamechanger...', :cyan if $stdout.tty?
            Syncer.new(config, storage).run(force: options[:refresh])
            shell.say 'Done.', :green if $stdout.tty?

            formatter = build_formatter

            if options[:game]
              show_game(options[:game], options[:game_number], storage, formatter)
            elsif options[:pitcher]
              show_pitcher(options[:pitcher], storage, formatter)
            else
              show_season(storage, formatter)
            end
          end
        end
      end

      private

      SEASON_SORT_KEYS = {
        'name'     => ->(r) { r['pitcher_name'] },
        'gp'       => ->(r) { r['games_pitched'].to_i },
        'pitches'  => ->(r) { r['total_pitches'].to_i },
        'strikes'  => ->(r) { r['total_strikes'].to_i },
        'balls'    => ->(r) { r['total_pitches'].to_i - r['total_strikes'].to_i },
        'pct'      => lambda do |r|
          pitches = r['total_pitches'].to_i
          pitches.positive? ? r['total_strikes'].to_f / pitches : nil
        end,
        'ip_share' => ->(r) { r['ip_share'] },
        'avg'      => ->(r) { r['avg_per_game'].to_f },
        '7day'     => ->(r) { r['seven_day_total'].to_i },
        'last'     => ->(r) { r['last_outing'] }
      }.freeze

      def show_season(storage, formatter)
        rows = storage.season_summary
        team_total_ip = rows.sum { |r| r['total_ip'].to_f }
        rows.each do |r|
          r['ip_share'] = team_total_ip.positive? ? (r['total_ip'].to_f / team_total_ip * 100.0) : nil
        end
        rows = apply_sort(rows, SEASON_SORT_KEYS)
        puts formatter.season_summary(rows)
      end

      def apply_sort(rows, key_map)
        Sorting.apply(rows, options[:sort], key_map, desc: options[:desc])
      rescue Sorting::InvalidSortKey => e
        shell.say_error e.message, :red
        exit 1
      end

      def show_pitcher(name, storage, formatter)
        result = storage.pitcher_games(name)

        if result.empty?
          shell.say "No pitcher matching '#{name}' found this season.", :yellow
          exit 1
        end

        if result.first.is_a?(String)
          shell.say 'Ambiguous name — did you mean:', :yellow
          result.each { |n| shell.say "  #{n}" }
          exit 1
        end

        pitcher_name = result.first&.dig('pitcher_name') || name
        puts formatter.pitcher_games(pitcher_name, result)
      end

      def show_game(date, game_number, storage, formatter)
        unless date.match?(/\A\d{4}-\d{2}-\d{2}\z/)
          shell.say "Invalid date format '#{date}' — expected YYYY-MM-DD", :red
          exit 1
        end

        games = storage.game_by_date(date)

        if games.empty?
          shell.say "No game found for #{date}.", :yellow
          exit 1
        end

        if games.length > 1
          idx = game_number.to_i - 1
          unless idx.between?(0, games.length - 1)
            shell.say "#{games.length} games found on #{date}. Use --game-number 1 or --game-number 2.", :yellow
            exit 1
          end
          games = [games[idx]]
        end

        puts formatter.game_breakdown(games)
      end
    end
  end
end
