# frozen_string_literal: true

module Gamechanger
  module Formatters
    class Markdown
      def season_summary(rows)
        return "_No pitch data found for this season._" if rows.empty?

        headings = ['Pitcher', 'GP', 'Pitches', 'Strikes', 'Balls', 'Strike%', 'Avg/Game', '7-Day', 'Last Outing']
        data = rows.map do |r|
          strikes = r['total_strikes'].to_i
          pitches = r['total_pitches'].to_i
          balls   = pitches - strikes
          pct     = pitches > 0 ? format('%.0f%%', strikes * 100.0 / pitches) : '—'
          [
            r['pitcher_name'],
            r['games_pitched'],
            pitches,
            strikes,
            balls,
            pct,
            r['avg_per_game'],
            r['seven_day_total'],
            r['last_outing'] || '—'
          ]
        end

        md_table(headings, data)
      end

      def pitcher_games(pitcher_name, rows)
        return "_No games found for pitcher: #{pitcher_name}_" if rows.empty?

        lines = ["## #{pitcher_name}", ""]
        headings = ['Date', 'Opponent', 'H/A', 'Status', 'Pitches', 'Strikes', 'Balls', 'Strike%', 'IP']
        data = rows.map do |r|
          status  = r['status'] == 'in_progress' ? '(live)' : r['status']
          pitches = r['pitches_thrown'].to_i
          strikes = r['strikes_thrown'].to_i
          balls   = pitches - strikes
          pct     = pitches > 0 ? format('%.0f%%', strikes * 100.0 / pitches) : '—'
          [
            r['game_date'],
            r['opponent'] || '—',
            r['home_away'] || '—',
            status,
            pitches,
            strikes,
            balls,
            pct,
            r['innings_pitched'] ? format('%.1f', r['innings_pitched']) : '—'
          ]
        end

        lines << md_table(headings, data)
        lines.join("\n")
      end

      def availability(target_date, game_info, rows, rules)
        header = if game_info
          opponent  = game_info['opponent'] || '—'
          home_away = game_info['home_away'] || '—'
          "Next game: #{game_info['game_date']} vs #{opponent} (#{home_away})"
        else
          "Availability for: #{target_date}"
        end

        lines = ["## #{header}", ""]

        if rows.empty?
          lines << "_No pitch data found. Sync first with `gamechanger pitches`._"
          return lines.join("\n")
        end

        rows.each do |row|
          pitcher      = row['pitcher_name']
          last_outing  = row['last_outing']
          last_pitches = row['last_pitches'].to_i
          seven_day    = row['seven_day_total'].to_i
          avail        = rules.available_on?(target_date, last_outing, last_pitches)
          avail_date   = rules.available_date(last_outing, last_pitches)
          remaining    = rules.pitches_remaining(last_pitches)
          high_load    = seven_day > 75

          date_label = last_outing ? Date.parse(last_outing).strftime('%-m/%-d') : '—'

          if avail && high_load
            status = "⚠️"
            note   = "available · high 7-day load: #{seven_day}"
          elsif avail
            status = "✅"
            note   = remaining < rules.daily_max ? "available · #{remaining} pitches remaining" : "available"
          else
            days_left = (avail_date - target_date).to_i.abs
            status = "🔴"
            note   = "needs #{days_left} more rest day#{'s' if days_left != 1} (avail #{avail_date.strftime('%-m/%-d')})"
          end

          lines << "- #{status} **#{pitcher}** — Last: #{date_label} (#{last_pitches}) · #{note}"
        end

        lines << ""
        lines.join("\n")
      end

      def plan(assignments, projections, next_game_date, rules)
        return "_No games to plan._" if assignments.empty?

        dates = assignments.map(&:game_date).uniq
        date_range = if dates.length == 1
          Date.parse(dates.first).strftime('%-m/%-d')
        else
          "#{Date.parse(dates.first).strftime('%-m/%-d')}–#{Date.parse(dates.last).strftime('%-m/%-d')}"
        end

        lines = ["## Tournament Plan: #{assignments.length} game#{'s' if assignments.length != 1}  #{date_range}", ""]

        headings = ['#', 'Date', 'Opponent', 'Starter', 'Pitches', 'Reliever', 'Pitches']
        data = assignments.map do |a|
          [
            a.game_number,
            Date.parse(a.game_date).strftime('%-m/%-d'),
            a.opponent || '(TBD)',
            a.starter_name  || '(none eligible)',
            a.starter_pitches  ? "~#{a.starter_pitches}" : '—',
            a.reliever_name || '(none eligible)',
            a.reliever_pitches ? "~#{a.reliever_pitches}" : '—'
          ]
        end

        lines << md_table(headings, data)

        if next_game_date && projections.any?
          lines << ""
          lines << "### Post-tournament availability (for #{next_game_date.strftime('%-m/%-d')})"
          lines << ""
          projections.each do |proj|
            avail      = rules.available_on?(next_game_date, proj.last_outing, proj.last_pitches)
            avail_date = rules.available_date(proj.last_outing, proj.last_pitches)
            remaining  = rules.pitches_remaining(proj.last_pitches)

            if avail
              status = "✅"
              note   = remaining < rules.daily_max ? "available · #{remaining} pitches remaining (#{proj.weekend_total} projected)" : "available (#{proj.weekend_total} projected)"
            else
              days_left = (avail_date - next_game_date).to_i.abs
              status = "🔴"
              note   = "needs #{days_left} more rest day#{'s' if days_left != 1} (avail #{avail_date.strftime('%-m/%-d')}) · #{proj.weekend_total} projected"
            end

            lines << "- #{status} **#{proj.pitcher_name}** — #{note}"
          end
        end

        lines << ""
        lines.join("\n")
      end

      def hitting(rows)
        return "_No batting data found for this season._" if rows.empty?

        headings = ['Batter', 'G', 'PA', 'AB', 'H', 'BB', 'K', 'AVG', 'OBP', 'Trend', 'Pos']
        data = rows.map do |r|
          ab    = r['total_ab'].to_i
          hits  = r['total_hits'].to_i
          walks = r['total_walks'].to_i
          k     = r['total_k'].to_i
          pa    = r['pa'].to_i
          avg   = ab > 0 ? format('.%03d', (hits.to_f / ab * 1000).round) : '.000'
          obp   = (ab + walks) > 0 ? format('.%03d', ((hits + walks).to_f / (ab + walks) * 1000).round) : '.000'
          pos   = Array(r['positions']).join(', ')
          [r['batter_name'], r['games'], pa, ab, hits, walks, k, avg, obp, trend_arrow(r), pos]
        end

        md_table(headings, data)
      end

      def fielding(rows, columns)
        return "_No fielding data found for this season._" if rows.empty?

        headings = ['Player', 'G'] + columns + ['Total']
        data = rows.map do |r|
          cells = columns.map { |code| r['positions'][code].to_i.positive? ? r['positions'][code] : '.' }
          [r['player_name'], r['games'].to_i] + cells + [r['total']]
        end
        md_table(headings, data)
      end

      def batter_games(batter_name, rows)
        return "_No games found for batter: #{batter_name}_" if rows.empty?

        lines = ["## #{batter_name}", ""]
        headings = ['Date', 'Opponent', 'H/A', 'AB', 'H', 'BB', 'K', 'AVG', 'OBP']
        data = rows.map do |r|
          ab    = r['at_bats'].to_i
          hits  = r['hits'].to_i
          walks = r['walks'].to_i
          k     = r['strikeouts'].to_i
          avg   = ab > 0 ? format('.%03d', (hits.to_f / ab * 1000).round) : '.000'
          obp   = (ab + walks) > 0 ? format('.%03d', ((hits + walks).to_f / (ab + walks) * 1000).round) : '.000'
          [r['game_date'], r['opponent'] || '—', r['home_away'] || '—', ab, hits, walks, k, avg, obp]
        end

        lines << md_table(headings, data)
        lines.join("\n")
      end

      def lineup(target_date, game_info, optimizer)
        header = if game_info
          "Suggested Lineup for: #{game_info['game_date']} vs #{game_info['opponent'] || '—'}"
        else
          "Suggested Lineup for: #{target_date}"
        end

        lines = ["## #{header}", "_Based on last 7 days OBP_", ""]

        if optimizer.ranked.empty? && optimizer.unranked.empty?
          lines << "_No batting data in cache. Run `gamechanger pitches --refresh` to sync._"
          lines << ""
          return lines.join("\n")
        end

        unless optimizer.ranked.empty?
          headings = ['#', 'Batter', '7-Day OBP', 'Season OBP', 'Trend']
          data = optimizer.ranked.map do |slot|
            [
              slot.position,
              slot.batter_name,
              format('.%03d', (slot.seven_day_obp * 1000).round),
              format('.%03d', (slot.season_obp * 1000).round),
              slot.trend
            ]
          end
          lines << md_table(headings, data)
        end

        unless optimizer.unranked.empty?
          lines << ""
          lines << "**Unranked** (no at-bats in last 7 days):"
          optimizer.unranked.each do |slot|
            season = format('.%03d', (slot.season_obp * 1000).round)
            lines << "- #{slot.batter_name} — Season OBP: #{season}"
          end
        end

        lines << ""
        lines.join("\n")
      end

      def brief(target_date, game_info, brief_obj)
        header = if game_info
          opponent  = game_info['opponent'] || '—'
          home_away = game_info['home_away'] || '—'
          "#{game_info['game_date']} vs #{opponent} (#{home_away})"
        else
          target_date.to_s
        end

        lines = ["# Pre-Game Brief: #{header}", ""]

        # ── Pitcher Plan ────────────────────────────────────────────────
        unless brief_obj.pitcher_plan.empty?
          lines << "## Pitcher Plan"
          lines << ""
          headings = ['Pitcher', '7-Day', 'Remaining', 'Status']
          data = brief_obj.pitcher_plan.map do |r|
            seven_day = r['seven_day_total'].to_i
            status = if !r['available']
              days_left = r['avail_date'] ? (r['avail_date'] - target_date).to_i.abs : '?'
              "🔴 Rest (#{days_left}d)"
            elsif r['high_load']
              "⚠️  High load"
            else
              "✅ Available"
            end
            [r['pitcher_name'], seven_day, r['remaining'] > 0 ? r['remaining'].to_s : '—', status]
          end
          lines << md_table(headings, data)
          lines << ""
        end

        # ── Suggested Lineup ────────────────────────────────────────────
        optimizer = brief_obj.lineup
        unless optimizer.ranked.empty? && optimizer.unranked.empty?
          lines << "## Suggested Lineup"
          lines << "_Last 7 days OBP_"
          lines << ""
          unless optimizer.ranked.empty?
            headings = ['#', 'Batter', '7-Day OBP', 'Season OBP', 'Trend']
            data = optimizer.ranked.map do |slot|
              [
                slot.position,
                slot.batter_name,
                format('.%03d', (slot.seven_day_obp * 1000).round),
                format('.%03d', (slot.season_obp * 1000).round),
                slot.trend
              ]
            end
            lines << md_table(headings, data)
          end
          unless optimizer.unranked.empty?
            lines << ""
            lines << "**Unranked** (no 7-day at-bats): #{optimizer.unranked.map(&:batter_name).join(', ')}"
          end
          lines << ""
        end

        # ── Equity Flags ────────────────────────────────────────────────
        unless brief_obj.equity_flags.empty?
          total = brief_obj.equity_flags.first['total_games'].to_i
          lines << "## Equity Flags"
          lines << "_Players with less than 60% participation_"
          lines << ""
          brief_obj.equity_flags.each do |r|
            games_batted = r['total_games_batted'].to_i
            pct = total > 0 ? "#{(games_batted * 100 / total).round}%" : '—'
            lines << "- ⚠️  **#{r['player_name']}** — #{games_batted}/#{total} games (#{pct})"
          end
          lines << ""
        end

        # ── Development Spotlights ───────────────────────────────────────
        unless brief_obj.development_spotlights.empty?
          lines << "## Development Spotlights"
          lines << ""
          brief_obj.development_spotlights.each do |arc|
            arrow  = arc.bat_trend == '↑' ? '↑' : '↓'
            detail = if arc.first_half_obp && arc.recent_obp
              "OBP #{format_obp(arc.first_half_obp)} → #{format_obp(arc.recent_obp)} recently"
            elsif arc.bat_narrative
              arc.bat_narrative
            else
              ''
            end
            lines << "- #{arrow} **#{arc.player_name}** — #{detail}"
          end
          lines << ""
        end

        lines.join("\n")
      end

      def game_breakdown(games)
        return "_No game found for that date._" if games.empty?

        output = []
        games.each.with_index(1) do |game, idx|
          label  = games.length > 1 ? " [Game #{idx}]" : ''
          status = game['status'] == 'in_progress' ? ' _(live)_' : ''
          output << "## #{game['game_date']}#{label} vs #{game['opponent']} (#{game['home_away']})#{status}"
          output << ""

          stats = game['pitcher_stats'] || []
          if stats.empty?
            output << "_No pitch data recorded._"
          else
            headings = ['Pitcher', 'Pitches', 'Strikes', 'Balls', 'Strike%', 'IP']
            data = stats.map do |s|
              pitches = s['pitches_thrown'].to_i
              strikes = s['strikes_thrown'].to_i
              balls   = pitches - strikes
              pct     = pitches > 0 ? format('%.0f%%', strikes * 100.0 / pitches) : '—'
              [
                s['pitcher_name'],
                pitches,
                strikes,
                balls,
                pct,
                s['innings_pitched'] ? format('%.1f', s['innings_pitched']) : '—'
              ]
            end
            output << md_table(headings, data)
          end
          output << ''
        end
        output.join("\n")
      end

      def equity(rows)
        return "_No player data found. Run `gamechanger pitches --refresh` to sync._" if rows.empty?

        total = rows.first['total_games'].to_i
        headings = ['Player', 'Last Batted', 'G-Ago', 'Batted', 'Last Pitched', 'G-Ago']
        data = rows.map do |r|
          bat_date = r['last_bat_date']   ? Date.parse(r['last_bat_date']).strftime('%-m/%-d')   : '—'
          pit_date = r['last_pitch_date'] ? Date.parse(r['last_pitch_date']).strftime('%-m/%-d') : '—'
          bat_ago  = r['games_since_last_batted'].nil?  ? '—' : r['games_since_last_batted']
          pit_ago  = r['games_since_last_pitched'].nil? ? '—' : r['games_since_last_pitched']
          bat_rate = r['total_games_batted'] ? "#{r['total_games_batted']}/#{total}" : '—'
          [r['player_name'], bat_date, bat_ago, bat_rate, pit_date, pit_ago]
        end

        md_table(headings, data)
      end

      def progress(arcs)
        return "_No player data cached. Run `gc pitches --refresh` to sync._" if arcs.empty?

        headings = ['Player', 'Batting Arc', '↑↓', 'Bat Last 5', 'Pitching Arc', '↑↓', 'Pitch Last 5']
        data = arcs.map do |arc|
          bat_arc   = arc.first_half_obp        ? "#{format_obp(arc.first_half_obp)} → #{format_obp(arc.second_half_obp)}"               : '—'
          pitch_arc = arc.first_half_strike_pct ? "#{format_pct(arc.first_half_strike_pct)} → #{format_pct(arc.second_half_strike_pct)}" : '—'
          [
            arc.player_name,
            bat_arc,   arc.bat_trend   || '',  arc.recent_obp        ? format_obp(arc.recent_obp)        : '—',
            pitch_arc, arc.pitch_trend || '',  arc.recent_strike_pct ? format_pct(arc.recent_strike_pct) : '—'
          ]
        end

        md_table(headings, data)
      end

      def progress_player(arc)
        lines = ["## #{arc.player_name} — Season Development", ""]

        if arc.total_games_batted&.positive?
          sparkline = arc.bat_sparkline.empty? ? '_(no sparkline data)_' : arc.bat_sparkline
          lines << "### Batting Arc (#{arc.total_games_batted} games)"
          lines << sparkline
          lines << ""
          lines << "| | |"
          lines << "|---|---|"
          lines << "| First half OBP | #{format_obp(arc.first_half_obp)} |"
          lines << "| Second half OBP | #{format_obp(arc.second_half_obp)} #{arc.bat_trend || ''} #{format_delta_obp(arc)} |"
          lines << "| Last 5 games | #{arc.recent_obp ? format_obp(arc.recent_obp) : '—'} |"
          lines << ""
          lines << "> #{arc.bat_narrative}"
          lines << ""
        end

        if arc.total_games_pitched&.positive?
          sparkline = arc.pitch_sparkline.empty? ? '_(no sparkline data)_' : arc.pitch_sparkline
          lines << "### Pitching Arc (#{arc.total_games_pitched} outings)"
          lines << sparkline
          lines << ""
          lines << "| | |"
          lines << "|---|---|"
          lines << "| First half K% | #{format_pct(arc.first_half_strike_pct)} |"
          lines << "| Second half K% | #{format_pct(arc.second_half_strike_pct)} #{arc.pitch_trend || ''} #{format_delta_pct(arc)} |"
          lines << "| Last 5 outings | #{arc.recent_strike_pct ? format_pct(arc.recent_strike_pct) : '—'} |"
          lines << ""
          lines << "> #{arc.pitch_narrative}"
        end

        lines.join("\n")
      end

      private

      def md_table(headings, rows)
        col_widths = headings.each_with_index.map do |h, i|
          [h.to_s.length, rows.map { |r| r[i].to_s.length }.max || 0].max
        end

        header_row = "| " + headings.each_with_index.map { |h, i| h.to_s.ljust(col_widths[i]) }.join(" | ") + " |"
        divider    = "| " + col_widths.map { |w| "-" * w }.join(" | ") + " |"
        data_rows  = rows.map do |row|
          "| " + row.each_with_index.map { |cell, i| cell.to_s.ljust(col_widths[i]) }.join(" | ") + " |"
        end

        ([header_row, divider] + data_rows).join("\n")
      end

      def format_obp(v)
        v ? format('.%03d', (v * 1000).round) : '—'
      end

      def format_pct(v)
        v ? "#{(v * 100).round}%" : '—'
      end

      def format_delta_obp(arc)
        return '' unless arc.first_half_obp && arc.second_half_obp

        delta = arc.second_half_obp - arc.first_half_obp
        sign  = delta >= 0 ? '+' : ''
        format('%s.%03d', sign, (delta.abs * 1000).round)
      end

      def format_delta_pct(arc)
        return '' unless arc.first_half_strike_pct && arc.second_half_strike_pct

        delta = arc.second_half_strike_pct - arc.first_half_strike_pct
        sign  = delta >= 0 ? '+' : '-'
        "#{sign}#{(delta.abs * 100).round} pts"
      end

      def trend_arrow(row)
        ab    = row['total_ab'].to_i
        hits  = row['total_hits'].to_i
        walks = row['total_walks'].to_i
        s7_ab = row['seven_day_ab'].to_i
        s7_h  = row['seven_day_hits'].to_i
        s7_bb = row['seven_day_walks'].to_i

        return '→' if (s7_ab + s7_bb).zero?

        season_obp = (ab + walks) > 0 ? (hits + walks).to_f / (ab + walks) : 0.0
        s7_obp     = (s7_h + s7_bb).to_f / (s7_ab + s7_bb)
        diff       = s7_obp - season_obp

        if diff > 0.05
          '↗'
        elsif diff < -0.05
          '↘'
        else
          '→'
        end
      end
    end
  end
end
