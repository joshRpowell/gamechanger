# frozen_string_literal: true

require 'thor'

module Gamechanger
  # Thor routing layer.
  #
  # Each command delegates to a Commands::X class that owns the command's
  # body and unit tests. Shared infrastructure (error handling, storage,
  # config, formatter selection) lives on Commands::Base.
  class CLI < Thor
    def self.exit_on_failure? = true

    default_task :brief

    class_option :format, type: :string, default: 'table', enum: %w[table json markdown],
                          desc: 'Output format'

    desc 'setup', 'Configure Gamechanger credentials and team'
    option :email,       type: :string, desc: 'Account email'
    option :password,    type: :string, desc: 'Account password (inline)'
    option :'op-ref',    type: :string, desc: '1Password secret reference for password (e.g. op://Vault/Item/password)'
    option :'team-slug', type: :string, desc: 'Team identifier'
    def setup
      Commands::Setup.new(options: options, shell: shell).call
    end

    desc 'pitches', 'Show pitcher workload for this season'
    option :pitcher,     type: :string,  desc: 'Filter to a single pitcher (substring match)'
    option :game,        type: :string,  desc: 'Show a single game by date (YYYY-MM-DD)'
    option :game_number, type: :numeric, default: 1, desc: 'Game number for doubleheaders (1 or 2)'
    option :refresh,     type: :boolean, default: false, desc: 'Force re-fetch of non-final games from Gamechanger'
    option :sort,        type: :string,  desc: 'Sort season summary by column key (name, gp, pitches, strikes, balls, pct, ip_share, era, whip, k9, bb9, baa, p_ip, p_bf, avg, 7day, last)'
    option :desc,        type: :boolean, default: false, desc: 'Sort descending'
    option :advanced,    type: :boolean, default: false, desc: 'Show advanced rate columns (BB/9, BAA, P/IP)'
    def pitches
      Commands::Pitches.new(options: options, shell: shell).call
    end

    desc 'refresh', 'Sync latest game data from Gamechanger'
    option :format, type: :string, default: 'human', desc: 'Output format (human, json)'
    def refresh
      Commands::Refresh.new(options: options, shell: shell).call
    end

    desc 'availability', 'Show pitcher availability for the next game'
    option :date, type: :string, desc: 'Target game date (YYYY-MM-DD, default: next scheduled game)'
    def availability
      Commands::Availability.new(options: options, shell: shell).call
    end

    desc 'plan', 'Generate pitcher deployment plan for a tournament weekend'
    option :from,      type: :string, desc: 'First game date (YYYY-MM-DD)'
    option :to,        type: :string, desc: 'Last game date (YYYY-MM-DD, defaults to --from)'
    option :games,     type: :string, desc: 'Comma-separated game dates for a hypothetical schedule'
    option :ace,       type: :string, desc: 'Pitcher name to use as starter first when eligible'
    option :skip,      type: :string, desc: 'Comma-separated pitcher names to exclude'
    option :next_game, type: :string, desc: 'Next regular-season date for post-tournament projection (YYYY-MM-DD)'
    def plan
      Commands::Plan.new(options: options, shell: shell).call
    end

    desc 'hitting', 'Show season batting stats'
    option :player, type: :string, desc: 'Single player game-by-game breakdown (substring match)'
    option :sort,   type: :string, desc: 'Sort season stats by column key (name, g, ab, h, bb, k, avg, obp)'
    option :desc,   type: :boolean, default: false, desc: 'Sort descending'
    def hitting
      Commands::Hitting.new(options: options, shell: shell).call
    end

    desc 'fielding', 'Show season fielding position usage (player x position pivot)'
    option :sort, type: :string,  desc: 'Sort by column key (player, total, or a position code present in the table — case-insensitive)'
    option :desc, type: :boolean, default: false, desc: 'Sort descending'
    def fielding
      Commands::Fielding.new(options: options, shell: shell).call
    end

    desc 'lineup', 'Suggest batting order for the next game based on recent OBP'
    option :date, type: :string, desc: 'Target game date (YYYY-MM-DD, default: next scheduled game)'
    def lineup
      Commands::Lineup.new(options: options, shell: shell).call
    end

    desc 'equity', 'Show playing time participation for all players'
    option :sort, type: :string,  desc: 'Sort by column key (name, bat, batago, batted, pitch, pitchago)'
    option :desc, type: :boolean, default: false, desc: 'Sort descending'
    def equity
      Commands::Equity.new(options: options, shell: shell).call
    end

    desc 'progress', 'Show player development arcs across the season'
    option :player,  type: :string, desc: 'Deep-dive arc for a single batter (prefix match)'
    option :pitcher, type: :string, desc: 'Deep-dive arc for a single pitcher (prefix match)'
    def progress
      Commands::Progress.new(options: options, shell: shell).call
    end

    desc 'brief', 'Pre-game intelligence brief (pitcher plan, lineup, equity, development)'
    option :date, type: :string, desc: 'Target game date YYYY-MM-DD (default: next scheduled game)'
    def brief
      Commands::Brief.new(options: options, shell: shell).call
    end

    desc 'version', 'Print version'
    def version
      say "gamechanger #{VERSION}"
    end
  end
end
