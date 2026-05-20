# frozen_string_literal: true

module Gamechanger
  # Sort report rows by a user-specified column key.
  #
  # Each command defines a key_map: { 'col_key' => ->(row) { sortable_value } }.
  # The lambda returns the value to sort on — either a direct field or a
  # computed metric like AVG/OBP/Strike%.
  #
  # Nils sort to the end regardless of direction so missing data doesn't
  # masquerade as a leader or laggard.
  module Sorting
    InvalidSortKey = Class.new(StandardError)

    module_function

    def apply(rows, sort_key, key_map, desc: false)
      return rows if sort_key.nil? || sort_key.empty?

      normalized = sort_key.to_s.downcase
      accessor = key_map[normalized]
      raise InvalidSortKey, build_error(normalized, key_map) unless accessor

      present, missing = rows.partition { |row| present?(accessor.call(row)) }
      sorted = present.sort_by { |row| sort_tuple(accessor.call(row)) }
      sorted.reverse! if desc
      sorted + missing
    end

    def present?(value)
      return false if value.nil?
      return false if value.respond_to?(:empty?) && value.empty?

      true
    end

    def sort_tuple(value)
      # type-tag before value so numerics and strings compare cleanly within their kind.
      case value
      when Numeric then [0, value]
      else              [1, value.to_s]
      end
    end

    def build_error(key, key_map)
      keys = key_map.keys.sort.join(', ')
      "Unknown sort key '#{key}'. Available: #{keys}"
    end
  end
end
