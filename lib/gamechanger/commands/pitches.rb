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
        'era'      => ->(r) { r['era'] },
        'whip'     => ->(r) { r['whip'] },
        'k9'       => ->(r) { r['k9'] },
        'bb9'      => ->(r) { r['bb9'] },
        'baa'      => ->(r) { r['baa'] },
        'p_ip'     => ->(r) { r['p_ip'] },
        'p_bf'     => ->(r) { r['p_bf'] },
        'avg'      => ->(r) { r['avg_per_game'].to_f },
        '7day'     => ->(r) { r['seven_day_total'].to_i },
        'last'     => ->(r) { r['last_outing'] }
      }.freeze

      def show_season(storage, formatter)
        rows = storage.season_summary
        team_total_ip = rows.sum { |r| r['total_ip'].to_f }
        rows.each do |r|
          r['ip_share'] = team_total_ip.positive? ? (r['total_ip'].to_f / team_total_ip * 100.0) : nil
          derive_rates!(r)
        end
        rows = apply_sort(rows, SEASON_SORT_KEYS)
        puts formatter.season_summary(rows, advanced: options[:advanced] ? true : false)
      end

      # Derive rate stats from raw totals on a season-summary row. Sets nil
      # whenever the denominator is non-positive — Sorting and formatters
      # already handle nil per existing %IP / strike% conventions.
      def derive_rates!(row)
        ip  = row['total_ip'].to_f
        bf  = row['total_bf'].to_i
        h   = row['total_h'].to_i
        er  = row['total_er'].to_i
        bb  = row['total_bb'].to_i
        so  = row['total_so'].to_i
        hbp = row['total_hbp'].to_i
        pit = row['total_pitches'].to_i

        row['era']  = ip.positive? ? er * 9.0 / ip : nil
        row['whip'] = ip.positive? ? (h + bb) / ip : nil
        row['k9']   = ip.positive? ? so * 9.0 / ip : nil
        row['bb9']  = ip.positive? ? bb * 9.0 / ip : nil
        baa_den     = bf - bb - hbp
        row['baa']  = baa_den.positive? ? h.to_f / baa_den : nil
        row['p_ip'] = ip.positive? ? pit / ip : nil
        row['p_bf'] = bf.positive? ? pit.to_f / bf : nil
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
        totals = cumulative_totals(result)
        puts formatter.pitcher_games(pitcher_name, result, totals: totals)
      end

      # Sum raw counts across outings and derive the same rates the season
      # summary derives. Reuses derive_rates! by aliasing total_* keys.
      def cumulative_totals(outings)
        sum_int   = ->(k) { outings.sum { |o| o[k].to_i } }
        sum_float = ->(k) { outings.sum { |o| o[k].to_f } }

        row = {
          'total_pitches' => sum_int.call('pitches_thrown'),
          'total_strikes' => sum_int.call('strikes_thrown'),
          'total_ip'      => sum_float.call('innings_pitched'),
          'total_bf'      => sum_int.call('batters_faced'),
          'total_h'       => sum_int.call('hits_allowed'),
          'total_r'       => sum_int.call('runs_allowed'),
          'total_er'      => sum_int.call('earned_runs'),
          'total_bb'      => sum_int.call('walks_issued'),
          'total_so'      => sum_int.call('strikeouts_recorded'),
          'total_wp'      => sum_int.call('wild_pitches'),
          'total_hbp'     => sum_int.call('hbp_allowed')
        }
        derive_rates!(row)
        row
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
