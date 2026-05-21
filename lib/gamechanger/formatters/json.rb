# frozen_string_literal: true

require 'json'

module Gamechanger
  module Formatters
    class Json
      # JSON output always includes all derived rate fields; the `advanced:`
      # kwarg is accepted for signature parity with the table/markdown
      # formatters but does not gate any fields.
      def season_summary(rows, advanced: false)
        _ = advanced
        JSON.pretty_generate(rows.map { |r| stringify_keys(r) })
      end

      def pitcher_games(pitcher_name, rows, totals: nil)
        payload = {
          pitcher: pitcher_name,
          games: rows.map { |r| stringify_keys(r) }
        }
        payload[:totals] = stringify_keys(totals) if totals
        JSON.pretty_generate(payload)
      end

      def game_breakdown(games)
        JSON.pretty_generate(games.map { |g| stringify_keys(g) })
      end

      def plan(assignments, projections, next_game_date, rules)
        games_json = assignments.map do |a|
          {
            game_number:      a.game_number,
            game_date:        a.game_date,
            opponent:         a.opponent,
            starter:  a.starter_name  ? { name: a.starter_name,  projected_pitches: a.starter_pitches }  : nil,
            reliever: a.reliever_name ? { name: a.reliever_name, projected_pitches: a.reliever_pitches } : nil
          }
        end

        post_avail = if next_game_date && projections.any?
          {
            target_date: next_game_date.to_s,
            pitchers: projections.map do |proj|
              avail      = rules.available_on?(next_game_date, proj.last_outing, proj.last_pitches)
              avail_date = rules.available_date(proj.last_outing, proj.last_pitches)
              {
                pitcher_name:       proj.pitcher_name,
                weekend_total:      proj.weekend_total,
                available:          avail,
                available_date:     avail_date.to_s,
                rest_days_required: rules.rest_days_required(proj.last_pitches)
              }
            end
          }
        end

        JSON.pretty_generate({
          tournament: {
            games:                      games_json,
            post_tournament_availability: post_avail
          }
        })
      end

      def brief(target_date, game_info, brief_obj)
        pitcher_plan = brief_obj.pitcher_plan.map do |r|
          {
            pitcher_name:        r['pitcher_name'],
            last_outing_date:    r['last_outing'],
            last_outing_pitches: r['last_pitches'].to_i,
            seven_day_total:     r['seven_day_total'].to_i,
            available:           r['available'],
            remaining:           r['remaining'],
            available_date:      r['avail_date']&.to_s,
            high_load_warning:   r['high_load']
          }
        end

        optimizer = brief_obj.lineup
        lineup = {
          ranked: optimizer.ranked.map do |slot|
            {
              position:      slot.position,
              batter_name:   slot.batter_name,
              seven_day_obp: slot.seven_day_obp.round(3),
              season_obp:    slot.season_obp.round(3),
              trend:         slot.trend
            }
          end,
          unranked: optimizer.unranked.map do |slot|
            { batter_name: slot.batter_name, season_obp: slot.season_obp.round(3) }
          end
        }

        equity = brief_obj.equity_flags.map do |r|
          total = r['total_games'].to_i
          {
            player_name:        r['player_name'],
            total_games_batted: r['total_games_batted'].to_i,
            total_team_games:   total,
            participation_pct:  total > 0 ? (r['total_games_batted'].to_i.to_f / total).round(3) : 0.0
          }
        end

        spotlights = brief_obj.development_spotlights.map do |arc|
          {
            player_name:     arc.player_name,
            bat_trend:       arc.bat_trend,
            first_half_obp:  arc.first_half_obp&.round(3),
            recent_obp:      arc.recent_obp&.round(3),
            bat_narrative:   arc.bat_narrative
          }
        end

        JSON.pretty_generate({
          target_date:             target_date.to_s,
          game:                    game_info,
          pitcher_plan:            pitcher_plan,
          suggested_lineup:        lineup,
          equity_flags:            equity,
          development_spotlights:  spotlights
        })
      end

      def hitting(rows)
        data = rows.map do |r|
          ab    = r['total_ab'].to_i
          hits  = r['total_hits'].to_i
          walks = r['total_walks'].to_i
          k     = r['total_k'].to_i
          s7_ab = r['seven_day_ab'].to_i
          s7_h  = r['seven_day_hits'].to_i
          s7_bb = r['seven_day_walks'].to_i

          season_obp = (ab + walks) > 0 ? (hits + walks).to_f / (ab + walks) : 0.0
          s7_obp     = (s7_ab + s7_bb) > 0 ? (s7_h + s7_bb).to_f / (s7_ab + s7_bb) : nil

          diff  = s7_obp ? s7_obp - season_obp : 0.0
          trend = if s7_obp.nil? then '→'
                 elsif diff > 0.05 then '↗'
                 elsif diff < -0.05 then '↘'
                 else '→'
                 end

          {
            batter_name:   r['batter_name'],
            games:         r['games'],
            pa:            r['pa'].to_i,
            at_bats:       ab,
            hits:          hits,
            singles:       [r['total_1b'].to_i, 0].max,
            doubles:       r['total_2b'].to_i,
            triples:       r['total_3b'].to_i,
            home_runs:     r['total_hr'].to_i,
            walks:         walks,
            strikeouts:    k,
            avg:           ab > 0 ? (hits.to_f / ab).round(3) : 0.0,
            obp:           (ab + walks) > 0 ? ((hits + walks).to_f / (ab + walks)).round(3) : 0.0,
            seven_day_obp: s7_obp&.round(3),
            trend:         trend,
            positions:     Array(r['positions'])
          }
        end
        JSON.pretty_generate(data)
      end

      def batter_games(batter_name, rows)
        JSON.pretty_generate({
          batter: batter_name,
          games:  rows.map { |r| stringify_keys(r) }
        })
      end

      def fielding(rows, _columns)
        data = rows.map do |r|
          positions = (r['positions'] || {}).reject { |_, count| count.to_i.zero? }
          { player_name: r['player_name'], games: r['games'].to_i, positions: positions, total: r['total'].to_i }
        end
        JSON.pretty_generate(data)
      end

      def lineup(target_date, game_info, optimizer)
        JSON.pretty_generate({
          target_date: target_date.to_s,
          game:        game_info,
          ranked: optimizer.ranked.map do |slot|
            {
              position:      slot.position,
              batter_name:   slot.batter_name,
              seven_day_obp: slot.seven_day_obp.round(3),
              season_obp:    slot.season_obp.round(3),
              trend:         slot.trend
            }
          end,
          unranked: optimizer.unranked.map do |slot|
            {
              batter_name: slot.batter_name,
              season_obp:  slot.season_obp.round(3)
            }
          end
        })
      end

      def equity(rows)
        total = rows.first&.dig('total_games').to_i
        data = rows.map do |r|
          {
            player_name:               r['player_name'],
            last_batted_date:          r['last_bat_date'],
            games_since_last_batted:   r['games_since_last_batted'],
            total_games_batted:        r['total_games_batted'],
            batting_participation:     r['total_games_batted'] ? "#{r['total_games_batted']}/#{total}" : nil,
            last_pitched_date:         r['last_pitch_date'],
            games_since_last_pitched:  r['games_since_last_pitched'],
            total_games_pitched:       r['total_games_pitched']
          }
        end
        JSON.pretty_generate({ total_team_games: total, players: data })
      end

      def progress(arcs)
        JSON.pretty_generate(
          arcs.map do |arc|
            {
              player:   arc.player_name,
              batting: {
                first_half_obp:  arc.first_half_obp&.round(3),
                second_half_obp: arc.second_half_obp&.round(3),
                recent_obp:      arc.recent_obp&.round(3),
                total_games:     arc.total_games_batted,
                trend:           arc.bat_trend,
                sparkline:       arc.bat_sparkline.empty? ? nil : arc.bat_sparkline,
                narrative:       arc.bat_narrative
              },
              pitching: {
                first_half_strike_pct:  arc.first_half_strike_pct&.round(3),
                second_half_strike_pct: arc.second_half_strike_pct&.round(3),
                recent_strike_pct:      arc.recent_strike_pct&.round(3),
                total_outings:          arc.total_games_pitched,
                trend:                  arc.pitch_trend,
                sparkline:              arc.pitch_sparkline.empty? ? nil : arc.pitch_sparkline,
                narrative:              arc.pitch_narrative
              }
            }
          end
        )
      end

      def progress_player(arc)
        JSON.pretty_generate({
          player:   arc.player_name,
          batting: {
            first_half_obp:  arc.first_half_obp&.round(3),
            second_half_obp: arc.second_half_obp&.round(3),
            recent_obp:      arc.recent_obp&.round(3),
            total_games:     arc.total_games_batted,
            trend:           arc.bat_trend,
            sparkline:       arc.bat_sparkline.empty? ? nil : arc.bat_sparkline,
            narrative:       arc.bat_narrative
          },
          pitching: {
            first_half_strike_pct:  arc.first_half_strike_pct&.round(3),
            second_half_strike_pct: arc.second_half_strike_pct&.round(3),
            recent_strike_pct:      arc.recent_strike_pct&.round(3),
            total_outings:          arc.total_games_pitched,
            trend:                  arc.pitch_trend,
            sparkline:              arc.pitch_sparkline.empty? ? nil : arc.pitch_sparkline,
            narrative:              arc.pitch_narrative
          }
        })
      end

      def availability(target_date, game_info, rows, rules)
        pitchers = rows.map do |row|
          last_pitches = row['last_pitches'].to_i
          avail        = rules.available_on?(target_date, row['last_outing'], last_pitches)
          avail_date   = rules.available_date(row['last_outing'], last_pitches)
          {
            pitcher_name:        row['pitcher_name'],
            last_outing_date:    row['last_outing'],
            last_outing_pitches: last_pitches,
            seven_day_total:     row['seven_day_total'].to_i,
            available:           avail,
            available_date:      avail_date.to_s,
            pitches_remaining:   avail ? rules.pitches_remaining(last_pitches) : 0,
            rest_days_required:  rules.rest_days_required(last_pitches),
            high_load_warning:   row['seven_day_total'].to_i > 75
          }
        end

        JSON.pretty_generate({
          target_date: target_date.to_s,
          game:        game_info,
          pitchers:    pitchers
        })
      end

      private

      def stringify_keys(hash)
        hash.transform_keys(&:to_s)
      end
    end
  end
end
