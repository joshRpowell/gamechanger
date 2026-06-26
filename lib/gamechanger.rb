# frozen_string_literal: true

require_relative 'gamechanger/version'
require_relative 'gamechanger/config'
require_relative 'gamechanger/signer'
require_relative 'gamechanger/client'
require_relative 'gamechanger/storage'
require_relative 'gamechanger/demo_fixture'
require_relative 'gamechanger/boxscore_parser'
require_relative 'gamechanger/batter_stats_parser'
require_relative 'gamechanger/pitch_rules'
require_relative 'gamechanger/tournament_planner'
require_relative 'gamechanger/lineup_optimizer'
require_relative 'gamechanger/development_arc'
require_relative 'gamechanger/pre_game_brief'
require_relative 'gamechanger/sorting'
require_relative 'gamechanger/syncer'
require_relative 'gamechanger/formatters/table'
require_relative 'gamechanger/formatters/json'
require_relative 'gamechanger/formatters/markdown'
require_relative 'gamechanger/commands/base'
require_relative 'gamechanger/commands/setup'
require_relative 'gamechanger/commands/refresh'
require_relative 'gamechanger/commands/pitches'
require_relative 'gamechanger/commands/availability'
require_relative 'gamechanger/commands/plan'
require_relative 'gamechanger/commands/hitting'
require_relative 'gamechanger/commands/fielding'
require_relative 'gamechanger/commands/lineup'
require_relative 'gamechanger/commands/equity'
require_relative 'gamechanger/commands/progress'
require_relative 'gamechanger/commands/brief'
require_relative 'gamechanger/commands/demo'
require_relative 'gamechanger/cli'

module Gamechanger
  class Error         < StandardError; end
  class AuthError     < Error; end
  class NetworkError  < Error; end
  class ConfigError   < Error; end
  class APIShapeError < Error; end
  class StorageError  < Error; end
end
