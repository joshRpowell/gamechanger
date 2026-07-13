# frozen_string_literal: true

require_relative 'gamechanger/version'
require_relative 'gamechanger/config'
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
  # Lazy-load the network + crypto stack. `net/http` (~170ms first load) and
  # `openssl` are pulled in by Client/Signer, but the majority of commands
  # (version, --help, and all read-only cache reads) never touch the network.
  # autoload keeps `Gamechanger::Client` / `Gamechanger::Signer` resolvable from
  # anywhere (including specs that `describe Gamechanger::Client`) while paying
  # the require cost only when a network command actually references them.
  # Syncer stays eagerly required: it has no heavy requires, references Client
  # only at call time, and defines the lightweight SyncResult struct that specs
  # reference directly.
  autoload :Signer, File.expand_path('gamechanger/signer', __dir__)
  autoload :Client, File.expand_path('gamechanger/client', __dir__)

  module Formatters
    # terminal-table (~87ms) is only needed when table output is rendered.
    autoload :Table, File.expand_path('gamechanger/formatters/table', __dir__)
  end

  class Error         < StandardError; end
  class AuthError     < Error; end
  class NetworkError  < Error; end
  class ConfigError   < Error; end
  class APIShapeError < Error; end
  class StorageError  < Error; end
end
