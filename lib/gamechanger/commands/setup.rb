# frozen_string_literal: true

module Gamechanger
  module Commands
    # `gamechanger setup` — interactive credential + team configuration.
    #
    # Non-interactive mode: --email / --password / --team-slug flags or
    # GAMECHANGER_EMAIL / GAMECHANGER_PASSWORD / GAMECHANGER_TEAM_SLUG env vars
    # bypass the prompts (useful for CI and automated provisioning).
    #
    # Uses its own inner rescue pattern (not run_command) because setup has
    # different exit semantics: "Authentication failed" (vs the standard
    # "Authentication error"), and APIShapeError is a warning that lets the
    # user fall through to manual team_slug entry.
    class Setup < Base
      def call
        shell.say 'Gamechanger Setup', :cyan
        shell.say '─' * 40

        email    = options[:email]    || ENV['GAMECHANGER_EMAIL']    || shell.ask('Email:')
        password = options[:password] || ENV['GAMECHANGER_PASSWORD'] || shell.ask('Password:', echo: false)
        shell.say ''

        shell.say 'Authenticating...', :cyan
        cfg = Config.new
        cfg.save(email: email, password: password)

        client = Client.new(config: cfg)
        authenticate_or_exit(client)

        team_id, team_slug = discover_team(client)

        cfg.save(email: email, password: password, team_id: team_id, team_slug: team_slug)
        shell.say 'Configuration saved to ~/.gamechanger/config.yml', :green
        shell.say "Run `gamechanger pitches` to view this season's pitch counts."
      end

      private

      def authenticate_or_exit(client)
        client.authenticate
      rescue AuthError => e
        shell.say_error "Authentication failed: #{e.message}", :red
        exit 2
      rescue NetworkError => e
        shell.say_error "Network error: #{e.message}", :red
        exit 3
      end

      def discover_team(client)
        team_id   = nil
        team_slug = nil

        begin
          teams_response = client.teams
          teams_list     = extract_teams_list(teams_response)

          if teams_list.empty?
            shell.say 'No teams found for this account.', :yellow
          elsif teams_list.length == 1
            team      = teams_list.first
            team_id   = team['id']
            team_slug = team['slug'] || team['short_id']
            shell.say "Team: #{team['name']} (#{team_id})", :green
          else
            shell.say 'Multiple teams found:', :cyan
            teams_list.each.with_index(1) do |t, i|
              shell.say "  #{i}. #{t['name']} (#{t['id']})"
            end
            idx       = shell.ask('Which team? (enter number):').to_i - 1
            selected  = teams_list[idx]
            team_id   = selected&.dig('id')
            team_slug = selected&.dig('slug') || selected&.dig('short_id')
          end

          if team_slug.nil?
            cli_slug = options[:'team-slug'] || ENV['GAMECHANGER_TEAM_SLUG']
            if cli_slug
              team_slug = cli_slug
            else
              shell.say '', :yellow
              shell.say 'Could not auto-detect team slug. Check your team URL on web.gc.com:', :yellow
              shell.say '  https://web.gc.com/teams/SLUG/...', :yellow
              team_slug = shell.ask('Enter your team slug (e.g. wGP47FexatoQ):').strip
              team_slug = nil if team_slug.empty?
            end
          end
        rescue APIShapeError => e
          shell.say_error "Could not auto-detect team: #{e.message}", :yellow
          shell.say_error 'You can manually add team_id and team_slug to ~/.gamechanger/config.yml', :yellow
        end

        [team_id, team_slug]
      end

      def extract_teams_list(teams_response)
        case teams_response
        when Array then teams_response
        when Hash  then teams_response['teams'] || teams_response['data'] || []
        else            []
        end
      end
    end
  end
end
