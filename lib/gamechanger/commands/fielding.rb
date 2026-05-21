# frozen_string_literal: true

module Gamechanger
  module Commands
    # `gamechanger fielding` — season-wide pivot of fielding stints per player per position.
    # Rows: players. Columns: position codes with at least one stint, in canonical order.
    # Cells: integer stint counts. Total column is sum across positions.
    class Fielding < Base
      STATIC_SORT_KEYS = {
        'player' => ->(r) { r['player_name'] },
        'g'      => ->(r) { r['games'].to_i },
        'games'  => ->(r) { r['games'].to_i },
        'total'  => ->(r) { r['total'].to_i }
      }.freeze

      def call
        run_command do
          with_storage do |storage|
            show_fielding(storage)
          end
        end
      end

      private

      def show_fielding(storage)
        rows = storage.season_fielding_summary
        if rows.empty?
          shell.say 'No fielding data in cache. Run `gamechanger refresh` to sync.', :yellow
          exit 1
        end

        columns = canonical_columns(rows)
        rows = default_sort(rows) if options[:sort].nil? || options[:sort].empty?
        rows = apply_sort(rows, sort_key_map(columns))

        puts build_formatter.fielding(rows, columns)
      end

      # Canonical position order from BatterStatsParser::KNOWN_POSITIONS, intersected with
      # positions actually present in the data set. Single source of truth.
      def canonical_columns(rows)
        present = rows.flat_map { |r| (r['positions'] || {}).keys }.uniq
        BatterStatsParser::KNOWN_POSITIONS & present
      end

      # Lowercase sort keys because Sorting.apply downcases user input before lookup.
      # Position codes are stored uppercase; the sort accessor uppercases the lookup.
      def sort_key_map(columns)
        STATIC_SORT_KEYS.merge(
          columns.each_with_object({}) do |code, h|
            h[code.downcase] = ->(r) { (r['positions'] || {})[code].to_i }
          end
        )
      end

      def default_sort(rows)
        rows.sort_by { |r| [-r['total'].to_i, r['player_name'].to_s] }
      end

      def apply_sort(rows, key_map)
        Sorting.apply(rows, options[:sort], key_map, desc: options[:desc])
      rescue Sorting::InvalidSortKey => e
        shell.say_error e.message, :red
        exit 1
      end
    end
  end
end
