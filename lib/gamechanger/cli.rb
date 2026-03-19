# frozen_string_literal: true

require 'thor'

module Gamechanger
  class CLI < Thor
    def self.exit_on_failure? = true

    class_option :format, type: :string, default: 'table', enum: %w[table json],
                           desc: 'Output format'

    # ─── setup ────────────────────────────────────────────────────────────────

    desc 'setup', 'Configure Gamechanger credentials and team'
    def setup
      say 'Gamechanger Setup', :cyan
      say '─' * 40

      email    = ask('Email:')
      password = ask('Password:', echo: false)
      say ''

      say 'Authenticating...', :cyan
      cfg = Config.new
      cfg.save(email: email, password: password)

      client = Client.new(config: cfg)
      begin
        client.authenticate
      rescue AuthError => e
        say "Authentication failed: #{e.message}", :red
        exit 2
      rescue NetworkError => e
        say "Network error: #{e.message}", :red
        exit 3
      end

      # Discover team_id from the API
      team_id = nil
      begin
        teams_response = client.teams
        # TODO: Update extraction logic after Phase 0 spike confirms response shape
        # Common shapes: array of teams, or { teams: [...] }, or { data: [...] }
        teams_list = if teams_response.is_a?(Array)
                       teams_response
                     elsif teams_response.is_a?(Hash)
                       teams_response['teams'] || teams_response['data'] || []
                     else
                       []
                     end

        if teams_list.empty?
          say 'No teams found for this account.', :yellow
        elsif teams_list.length == 1
          team = teams_list.first
          team_id   = team['id']
          team_slug = team['slug'] || team['short_id']  # TODO: confirm field name from teams response
          say "Team: #{team['name']} (#{team_id})", :green
        else
          say 'Multiple teams found:', :cyan
          teams_list.each.with_index(1) do |t, i|
            say "  #{i}. #{t['name']} (#{t['id']})"
          end
          idx = ask('Which team? (enter number):').to_i - 1
          selected  = teams_list[idx]
          team_id   = selected&.dig('id')
          team_slug = selected&.dig('slug') || selected&.dig('short_id')
        end

        if team_slug.nil?
          say '', :yellow
          say 'Could not auto-detect team slug. Check your team URL on web.gc.com:', :yellow
          say '  https://web.gc.com/teams/SLUG/...', :yellow
          team_slug = ask('Enter your team slug (e.g. wGP47FexatoQ):').strip
          team_slug = nil if team_slug.empty?
        end
      rescue APIShapeError => e
        say "Could not auto-detect team: #{e.message}", :yellow
        say "You can manually add team_id and team_slug to ~/.gamechanger/config.yml", :yellow
      end

      cfg.save(email: email, password: password, team_id: team_id, team_slug: team_slug)
      say 'Configuration saved to ~/.gamechanger/config.yml', :green
      say "Run `gamechanger pitches` to view this season's pitch counts."
    end

    # ─── pitches ──────────────────────────────────────────────────────────────

    desc 'pitches', 'Show pitcher workload for this season'
    option :pitcher, type: :string, desc: 'Filter to a single pitcher (substring match)'
    option :game,    type: :string, desc: 'Show a single game by date (YYYY-MM-DD)'
    option :game_number, type: :numeric, default: 1,
                         desc: 'Game number for doubleheaders (1 or 2)'
    option :refresh, type: :boolean, default: false,
                     desc: 'Force re-fetch of non-final games from Gamechanger'
    def pitches
      config = load_config!
      storage = Storage.new
      sync_data(config, storage, force: options[:refresh])

      formatter = options[:format] == 'json' ? Formatters::Json.new : Formatters::Table.new

      if options[:game]
        show_game(options[:game], options[:game_number], storage, formatter)
      elsif options[:pitcher]
        show_pitcher(options[:pitcher], storage, formatter)
      else
        show_season(storage, formatter)
      end
    rescue AuthError => e
      say "Authentication error: #{e.message}", :red
      exit 2
    rescue NetworkError => e
      say "Network error: #{e.message}", :red
      exit 3
    rescue ConfigError => e
      say "Configuration error: #{e.message}", :red
      exit 4
    rescue APIShapeError => e
      say "Gamechanger API returned an unexpected format: #{e.message}", :red
      say "The API may have changed. Check docs/research/gc-api-notes.md", :yellow
      exit 3
    end

    # ─── availability ─────────────────────────────────────────────────────────

    desc 'availability', 'Show pitcher availability for the next game'
    option :date, type: :string, desc: 'Target game date (YYYY-MM-DD, default: next scheduled game)'
    def availability
      target_date, game_info = resolve_target(options[:date])
      storage   = Storage.new
      rules     = PitchRules.new
      rows      = storage.pitcher_availability_data(before_date: target_date)
      formatter = options[:format] == 'json' ? Formatters::Json.new : Formatters::Table.new
      show_availability(target_date, game_info, rows, rules, formatter)
    end

    # ─── plan ─────────────────────────────────────────────────────────────────

    desc 'plan', 'Generate pitcher deployment plan for a tournament weekend'
    option :from,      type: :string, desc: 'First game date (YYYY-MM-DD)'
    option :to,        type: :string, desc: 'Last game date (YYYY-MM-DD, defaults to --from)'
    option :games,     type: :string, desc: 'Comma-separated game dates for a hypothetical schedule'
    option :ace,       type: :string, desc: 'Pitcher name to use as starter first when eligible'
    option :skip,      type: :string, desc: 'Comma-separated pitcher names to exclude'
    option :next_game, type: :string, desc: 'Next regular-season date for post-tournament projection (YYYY-MM-DD)'
    def plan
      game_slots   = resolve_plan_games
      first_date   = game_slots.first && (game_slots.first['game_date'] || game_slots.first[:game_date])
      storage      = Storage.new
      rows         = storage.pitcher_availability_data(before_date: first_date)

      if rows.empty?
        say 'No pitcher data in cache. Run `gamechanger pitches --refresh` first.', :yellow
        exit 1
      end

      skip_list = options[:skip] ? options[:skip].split(',').map(&:strip) : []
      rules     = PitchRules.new
      planner   = TournamentPlanner.new(
        games: game_slots,
        rows:  rows,
        rules: rules,
        ace:   options[:ace],
        skip:  skip_list
      )

      next_date = resolve_next_game_date(storage)
      formatter = options[:format] == 'json' ? Formatters::Json.new : Formatters::Table.new
      puts formatter.plan(planner.assignments, planner.projections, next_date, rules)
    end

    # ─── hitting ──────────────────────────────────────────────────────────────

    desc 'hitting', 'Show season batting stats'
    option :player, type: :string, desc: 'Single player game-by-game breakdown (substring match)'
    def hitting
      storage   = Storage.new
      formatter = options[:format] == 'json' ? Formatters::Json.new : Formatters::Table.new

      if options[:player]
        show_batter(options[:player], storage, formatter)
      else
        show_hitting(storage, formatter)
      end
    end

    # ─── lineup ───────────────────────────────────────────────────────────────

    desc 'lineup', 'Suggest batting order for the next game based on recent OBP'
    option :date, type: :string, desc: 'Target game date (YYYY-MM-DD, default: next scheduled game)'
    def lineup
      target_date, game_info = resolve_target(options[:date])
      storage   = Storage.new
      rows      = storage.batter_lineup_data(before_date: target_date)
      optimizer = LineupOptimizer.new(rows)
      formatter = options[:format] == 'json' ? Formatters::Json.new : Formatters::Table.new
      puts formatter.lineup(target_date, game_info, optimizer)
    end

    # ─── equity ───────────────────────────────────────────────────────────────

    desc 'equity', 'Show playing time participation for all players'
    def equity
      storage   = Storage.new
      formatter = options[:format] == 'json' ? Formatters::Json.new : Formatters::Table.new
      show_equity(storage, formatter)
    end

    # ─── progress ─────────────────────────────────────────────────────────────

    desc 'progress', 'Show player development arcs across the season'
    option :player,  type: :string, desc: 'Deep-dive arc for a single batter (prefix match)'
    option :pitcher, type: :string, desc: 'Deep-dive arc for a single pitcher (prefix match)'
    def progress
      storage   = Storage.new
      formatter = options[:format] == 'json' ? Formatters::Json.new : Formatters::Table.new
      if options[:player]
        show_progress_player(options[:player], :bat, storage, formatter)
      elsif options[:pitcher]
        show_progress_player(options[:pitcher], :pitch, storage, formatter)
      else
        show_progress(storage, formatter)
      end
    end

    # ─── brief ────────────────────────────────────────────────────────────────

    desc 'brief', 'Pre-game intelligence brief (pitcher plan, lineup, equity, development)'
    option :date, type: :string, desc: 'Target game date YYYY-MM-DD (default: next scheduled game)'
    def brief
      target_date, game_info = resolve_target(options[:date])
      storage = Storage.new

      availability_rows = storage.pitcher_availability_data(before_date: target_date)
      lineup_rows       = storage.batter_lineup_data(before_date: target_date)
      arc_rows          = storage.all_player_development_summary
      equity_rows       = storage.player_participation

      brief_obj = PreGameBrief.new(
        target_date:       target_date,
        availability_rows: availability_rows,
        lineup_rows:       lineup_rows,
        arc_rows:          arc_rows,
        equity_rows:       equity_rows,
        rules:             PitchRules.new
      )

      formatter = options[:format] == 'json' ? Formatters::Json.new : Formatters::Table.new
      puts formatter.brief(target_date, game_info, brief_obj)
    end

    # ─── version ──────────────────────────────────────────────────────────────

    desc 'version', 'Print version'
    def version
      say "gamechanger #{VERSION}"
    end

    private

    def load_config!
      config = Config.new
      unless config.configured?
        say 'Not configured. Run `gamechanger setup` first.', :red
        exit 4
      end
      config
    end

    def sync_data(config, storage, force: false)
      storage.clear_non_final if force

      client     = Client.new(config: config)
      team_id    = config.team_id
      team_slug  = config.team_slug

      if team_id.nil? || team_id.empty?
        say 'No team_id configured. Run `gamechanger setup` again.', :yellow
        say 'Or manually add team_id to ~/.gamechanger/config.yml', :yellow
        exit 4
      end

      if team_slug.nil? || team_slug.empty?
        say 'No team_slug configured. Run `gamechanger setup` again.', :yellow
        say 'Or add team_slug to ~/.gamechanger/config.yml (the short ID from your team URL).', :yellow
        exit 4
      end

      say 'Syncing games from Gamechanger...', :cyan if $stdout.tty?

      raw_games  = client.games(team_id: team_id)
      games_list = extract_games(raw_games)

      today = Date.today.to_s

      games_list.each do |game|
        parsed = parse_game(game)
        next if parsed[:status] == 'canceled'
        next if parsed[:game_date].nil? || parsed[:game_date] > today  # skip future games

        storage.upsert_game(parsed)

        # Skip final games already cached (save API calls)
        cached = storage.all_games.find { |g| g['game_id'] == parsed[:game_id] }
        next if cached && cached['status'] == 'final' && !force

        sleep Client::RATE_LIMIT_SLEEP
        raw_boxscore = client.game_pitcher_stats(game_id: parsed[:game_id])
        stats = BoxscoreParser.new(raw_boxscore, team_slug: team_slug).pitcher_stats
        storage.upsert_pitcher_stats(game_id: parsed[:game_id], stats: stats)

        batter_stats = BatterStatsParser.new(raw_boxscore, team_slug: team_slug).batter_stats
        storage.upsert_batter_stats(game_id: parsed[:game_id], stats: batter_stats) if batter_stats.any?

        # Mark as final if boxscore has data (schedule always shows "scheduled")
        storage.upsert_game(parsed.merge(status: 'final')) if stats.any?
      end

      say 'Done.', :green if $stdout.tty?
    end

    def show_season(storage, formatter)
      rows = storage.season_summary
      puts formatter.season_summary(rows)
    end

    def show_pitcher(name, storage, formatter)
      result = storage.pitcher_games(name)

      if result.empty?
        say "No pitcher matching '#{name}' found this season.", :yellow
        exit 1
      end

      # Multiple name matches — storage returns plain strings, not game rows
      if result.first.is_a?(String)
        say "Ambiguous name — did you mean:", :yellow
        result.each { |n| say "  #{n}" }
        exit 1
      end

      # Single match — result is game rows
      pitcher_name = result.first&.dig('pitcher_name') || name
      puts formatter.pitcher_games(pitcher_name, result)
    end

    def show_game(date, game_number, storage, formatter)
      unless date.match?(/\A\d{4}-\d{2}-\d{2}\z/)
        say "Invalid date format '#{date}' — expected YYYY-MM-DD", :red
        exit 1
      end

      games = storage.game_by_date(date)

      if games.empty?
        say "No game found for #{date}.", :yellow
        exit 1
      end

      if games.length > 1
        idx = game_number.to_i - 1
        unless idx.between?(0, games.length - 1)
          say "#{games.length} games found on #{date}. Use --game-number 1 or --game-number 2.", :yellow
          exit 1
        end
        games = [games[idx]]
      end

      puts formatter.game_breakdown(games)
    end

    # Confirmed from /teams/{uuid}/schedule?fetch_place_details=true response.
    # Returns a bare array of {event:, pregame_data:} objects (practices and games mixed).
    # Filters to event_type=="game" only.
    def extract_games(response)
      list = if response.is_a?(Array)
               response
             elsif response.is_a?(Hash)
               response['schedule'] || response['events'] || response['data'] || []
             else
               raise APIShapeError, "Unexpected schedule response shape: #{response.class}"
             end

      list.select { |item| item.dig('event', 'event_type') == 'game' }
    end

    # Confirmed field names from /teams/{uuid}/schedule response.
    # Each item is {event: {...}, pregame_data: {...}}.
    def parse_game(raw)
      event   = raw['event']
      pregame = raw['pregame_data']

      # start.datetime is ISO 8601 — extract date; full_day events use start.date
      game_date = event.dig('start', 'datetime')&.split('T')&.first ||
                  event.dig('start', 'date')

      {
        game_id:   event['id'],
        game_date: game_date,
        opponent:  pregame&.dig('opponent_name') || event['title'],
        home_away: pregame&.dig('home_away'),
        status:    normalize_status(event['status'])
      }
    end

    def resolve_target(date_opt)
      if date_opt
        begin
          [Date.parse(date_opt), nil]
        rescue Date::Error
          say "Invalid date '#{date_opt}' — expected YYYY-MM-DD", :red
          exit 1
        end
      else
        storage = Storage.new
        game    = storage.next_scheduled_game
        if game.nil?
          say "No upcoming games in cache. Run `gamechanger pitches --refresh` to sync the schedule.", :yellow
          exit 1
        end
        [Date.parse(game['game_date']), game]
      end
    end

    # Resolve the list of game slots for the `plan` command.
    # --games takes precedence over --from/--to; falls back to next scheduled game.
    def resolve_plan_games
      if options[:games]
        dates = options[:games].split(',').map(&:strip)
        dates.map do |d|
          begin
            parsed = Date.parse(d)
          rescue Date::Error
            say "Invalid date '#{d}' in --games — expected YYYY-MM-DD", :red
            exit 1
          end
          { 'game_date' => parsed.to_s, 'opponent' => nil }
        end
      elsif options[:from]
        begin
          from_date = Date.parse(options[:from])
        rescue Date::Error
          say "Invalid --from date '#{options[:from]}' — expected YYYY-MM-DD", :red
          exit 1
        end

        to_date = if options[:to]
          begin
            Date.parse(options[:to])
          rescue Date::Error
            say "Invalid --to date '#{options[:to]}' — expected YYYY-MM-DD", :red
            exit 1
          end
        else
          from_date
        end

        storage = Storage.new
        games   = storage.scheduled_games_between(from_date: from_date, to_date: to_date)
        if games.empty?
          say "No scheduled games found between #{from_date} and #{to_date}. Run `gamechanger pitches --refresh` to sync the schedule.", :yellow
          exit 1
        end
        games
      else
        # Default: use next scheduled game only
        storage = Storage.new
        game    = storage.next_scheduled_game
        if game.nil?
          say "No upcoming games in cache. Run `gamechanger pitches --refresh` to sync the schedule.", :yellow
          exit 1
        end
        [game]
      end
    end

    # Resolve the date for the post-tournament availability projection.
    def resolve_next_game_date(storage)
      if options[:next_game]
        begin
          Date.parse(options[:next_game])
        rescue Date::Error
          say "Invalid --next-game date '#{options[:next_game]}' — expected YYYY-MM-DD", :red
          exit 1
        end
      else
        game = storage.next_scheduled_game
        game ? Date.parse(game['game_date']) : nil
      end
    end

    def show_progress(storage, formatter)
      rows = storage.all_player_development_summary
      if rows.empty?
        say 'No player data cached. Run `gc pitches --refresh` to sync.', :yellow
        exit 1
      end
      arcs = DevelopmentArc.build_summary(rows)
      puts formatter.progress(arcs)
    end

    def show_progress_player(name, type, storage, formatter)
      rows    = storage.all_player_development_summary
      summary = rows.find { |r| r['player_name'].downcase.start_with?(name.downcase) }
      unless summary
        say "No data found for '#{name}'. Run `gc pitches --refresh` to sync.", :yellow
        exit 1
      end

      bat_rows   = type == :bat   ? storage.player_batting_arc(player_name: summary['player_name'])   : []
      pitch_rows = type == :pitch ? storage.player_pitching_arc(pitcher_name: summary['player_name']) : []
      arc = DevelopmentArc.build_player(summary, bat_rows, pitch_rows)
      puts formatter.progress_player(arc)
    end

    def show_equity(storage, formatter)
      rows = storage.player_participation
      if rows.empty?
        say 'No player data in cache. Run `gamechanger pitches --refresh` to sync.', :yellow
        exit 1
      end
      puts formatter.equity(rows)
    end

    def show_hitting(storage, formatter)
      rows = storage.season_batting_summary
      if rows.empty?
        say 'No batting data in cache. Run `gamechanger pitches --refresh` to sync.', :yellow
        exit 1
      end
      puts formatter.hitting(rows)
    end

    def show_batter(name, storage, formatter)
      result = storage.batter_games(name)

      if result.empty?
        say "No batter matching '#{name}' found this season.", :yellow
        exit 1
      end

      if result.first.is_a?(String)
        say 'Ambiguous name — did you mean:', :yellow
        result.each { |n| say "  #{n}" }
        exit 1
      end

      batter_name = result.first&.dig('batter_name') || name
      puts formatter.batter_games(batter_name, result)
    end

    def show_availability(target_date, game_info, rows, rules, formatter)
      puts formatter.availability(target_date, game_info, rows, rules)
    end

    def normalize_status(raw_status)
      case raw_status.to_s.downcase
      when /completed|final|ended/ then 'final'
      when /progress|live|active/  then 'in_progress'
      when /scheduled|upcoming/    then 'scheduled'
      else raw_status.to_s.downcase
      end
    end
  end
end
