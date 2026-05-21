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

      HITTING_SORT_KEYS = {
        'name' => ->(r) { r['batter_name'] },
        'g'    => ->(r) { r['games'].to_i },
        'pa'   => ->(r) { r['pa'].to_i },
        'ab'   => ->(r) { r['total_ab'].to_i },
        'h'    => ->(r) { r['total_hits'].to_i },
        'bb'   => ->(r) { r['total_walks'].to_i },
        'k'    => ->(r) { r['total_k'].to_i },
        'avg'  => lambda do |r|
          ab = r['total_ab'].to_i
          ab.positive? ? r['total_hits'].to_f / ab : nil
        end,
        'obp'  => lambda do |r|
          denom = r['total_ab'].to_i + r['total_walks'].to_i
          denom.positive? ? (r['total_hits'].to_i + r['total_walks'].to_i).to_f / denom : nil
        end
      }.freeze

      def show_hitting(storage)
        rows = storage.season_batting_summary
        if rows.empty?
          shell.say 'No batting data in cache. Run `gamechanger refresh` to sync.', :yellow
          exit 1
        end
        positions_map = storage.fielding_positions_most_recent_by_name
        rows.each do |r|
          r['positions'] = positions_map[r['batter_name']] || []
          r['pa']        = r['total_ab'].to_i + r['total_walks'].to_i + r['total_hbp'].to_i
        end
        rows = apply_sort(rows, HITTING_SORT_KEYS)
        puts build_formatter.hitting(rows)
      end

      def apply_sort(rows, key_map)
        Sorting.apply(rows, options[:sort], key_map, desc: options[:desc])
      rescue Sorting::InvalidSortKey => e
        shell.say_error e.message, :red
        exit 1
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
