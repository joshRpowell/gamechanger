# frozen_string_literal: true

module Gamechanger
  module Commands
    # `gamechanger setup` — interactive credential + team configuration.
    # Doesn't touch storage; uses its own inner rescue pattern for the
    # authenticate / team-discovery flow (not run_command, because the user
    # messages and exit codes differ from the standard chain).
    class Setup < Base
      def call
        shell.say 'Gamechanger Setup', :cyan
        shell.say '─' * 40

        email    = shell.ask('Email:')
        password = shell.ask('Password:', echo: false)
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
        shell.say "Authentication failed: #{e.message}", :red
        exit 2
      rescue NetworkError => e
        shell.say "Network error: #{e.message}", :red
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
            shell.say '', :yellow
            shell.say 'Could not auto-detect team slug. Check your team URL on web.gc.com:', :yellow
            shell.say '  https://web.gc.com/teams/SLUG/...', :yellow
            team_slug = shell.ask('Enter your team slug (e.g. wGP47FexatoQ):').strip
            team_slug = nil if team_slug.empty?
          end
        rescue APIShapeError => e
          shell.say "Could not auto-detect team: #{e.message}", :yellow
          shell.say 'You can manually add team_id and team_slug to ~/.gamechanger/config.yml', :yellow
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
