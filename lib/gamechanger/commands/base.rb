# frozen_string_literal: true

require 'date'

module Gamechanger
  module Commands
    # Shared infrastructure for all CLI commands.
    #
    # Subclasses implement #call and wrap their work in #run_command, which applies
    # the 5-exception rescue chain that previously lived in every Thor command
    # method in cli.rb. All error output routes through shell.say_error → stderr.
    #
    # Usage:
    #   Commands::Pitches.new(options: opts, shell: shell).call
    #
    # Helpers:
    #   - Error handling:  run_command(&block)
    #   - Config:          load_config!, current_season
    #   - Storage:         with_storage(season:, &block)
    #   - Formatting:      build_formatter
    #   - Target dates:    resolve_target(date_opt, storage:)  # shared by availability/lineup/brief
    class Base
      attr_reader :options, :shell

      def initialize(options:, shell:)
        @options = options
        @shell   = shell
      end

      def call
        raise NotImplementedError, "#{self.class} must implement #call"
      end

      private

      def run_command
        yield
      rescue AuthError => e
        shell.say_error "Authentication error: #{e.message}", :red
        exit 2
      rescue NetworkError => e
        shell.say_error "Network error: #{e.message}", :red
        exit 3
      rescue ConfigError => e
        shell.say_error "Configuration error: #{e.message}", :red
        exit 4
      rescue APIShapeError => e
        shell.say_error "Gamechanger API returned an unexpected format: #{e.message}", :red
        shell.say_error 'The API may have changed. Check docs/research/gc-api-notes.md', :yellow
        exit 3
      rescue StorageError => e
        shell.say_error "Cache read failed — #{e.message}", :red
        shell.say_error 'Try deleting ~/.gamechanger/cache.db and re-running `gamechanger refresh`', :yellow
        exit 1
      end

      def with_storage(season: current_season)
        storage = Storage.new(season: season)
        yield storage
      ensure
        storage&.close
      end

      def current_season
        Config.new.season
      end

      def load_config!
        config = Config.new
        unless config.configured?
          shell.say_error 'Not configured. Run `gamechanger setup` first.', :red
          exit 4
        end
        config
      end

      def build_formatter
        case options[:format]
        when 'json'     then Formatters::Json.new
        when 'markdown' then Formatters::Markdown.new
        else                 Formatters::Table.new
        end
      end

      # Resolve [target_date, game_info] from an optional date string or the next scheduled game.
      # Shared by Commands::{Availability, Lineup, Brief}.
      def resolve_target(date_opt, storage:)
        if date_opt
          begin
            [Date.parse(date_opt), nil]
          rescue Date::Error
            shell.say "Invalid date '#{date_opt}' — expected YYYY-MM-DD", :red
            exit 1
          end
        else
          game = storage.next_scheduled_game
          if game.nil?
            shell.say 'No upcoming games in cache. Run `gamechanger refresh` to sync the schedule.', :yellow
            exit 1
          end
          [Date.parse(game['game_date']), game]
        end
      end
    end
  end
end
