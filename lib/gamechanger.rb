# frozen_string_literal: true

require_relative 'gamechanger/version'
require_relative 'gamechanger/config'
require_relative 'gamechanger/client'
require_relative 'gamechanger/storage'
require_relative 'gamechanger/boxscore_parser'
require_relative 'gamechanger/batter_stats_parser'
require_relative 'gamechanger/pitch_rules'
require_relative 'gamechanger/tournament_planner'
require_relative 'gamechanger/lineup_optimizer'
require_relative 'gamechanger/development_arc'
require_relative 'gamechanger/pre_game_brief'
require_relative 'gamechanger/syncer'
require_relative 'gamechanger/formatters/table'
require_relative 'gamechanger/formatters/json'
require_relative 'gamechanger/cli'

module Gamechanger
  class Error         < StandardError; end
  class AuthError     < Error; end
  class NetworkError  < Error; end
  class ConfigError   < Error; end
  class APIShapeError < Error; end
  class StorageError  < Error; end
end
