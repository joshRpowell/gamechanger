# frozen_string_literal: true

require 'spec_helper'

RSpec.describe Gamechanger::PreGameBrief do
  let(:rules)       { Gamechanger::PitchRules.new }
  let(:target_date) { Date.parse('2026-04-01') }

  # ── row helpers ────────────────────────────────────────────────────────────

  def avail_row(name, last_outing: nil, last_pitches: 0, seven_day: 0)
    {
      'pitcher_name'   => name,
      'last_outing'    => last_outing,
      'last_pitches'   => last_pitches,
      'seven_day_total' => seven_day
    }
  end

  def batter_row(name, seven_day_ab: 4, seven_day_hits: 2, seven_day_walks: 0,
                 season_ab: 20, season_hits: 6, season_walks: 2)
    {
      'batter_name'     => name,
      'seven_day_ab'    => seven_day_ab,
      'seven_day_hits'  => seven_day_hits,
      'seven_day_walks' => seven_day_walks,
      'season_ab'       => season_ab,
      'season_hits'     => season_hits,
      'season_walks'    => season_walks
    }
  end

  def arc_row(name, first_half_obp: nil, second_half_obp: nil, recent_obp: nil,
              total_games_batted: nil, first_half_strike_pct: nil,
              second_half_strike_pct: nil, recent_strike_pct: nil,
              total_games_pitched: nil)
    {
      'player_name'            => name,
      'first_half_obp'         => first_half_obp,
      'second_half_obp'        => second_half_obp,
      'recent_obp'             => recent_obp,
      'total_games_batted'     => total_games_batted,
      'first_half_strike_pct'  => first_half_strike_pct,
      'second_half_strike_pct' => second_half_strike_pct,
      'recent_strike_pct'      => recent_strike_pct,
      'total_games_pitched'    => total_games_pitched
    }
  end

  def equity_row(name, total_games_batted: 0, total_games: 10)
    {
      'player_name'        => name,
      'total_games_batted' => total_games_batted,
      'total_games'        => total_games,
      'last_bat_date'      => nil,
      'games_since_last_batted' => nil
    }
  end

  # ── subject ─────────────────────────────────────────────────────────────────

  subject(:brief) do
    described_class.new(
      target_date:       target_date,
      availability_rows: availability_rows,
      lineup_rows:       lineup_rows,
      arc_rows:          arc_rows,
      equity_rows:       equity_rows,
      rules:             rules
    )
  end

  let(:availability_rows) { [] }
  let(:lineup_rows)       { [] }
  let(:arc_rows)          { [] }
  let(:equity_rows)       { [] }

  # ── #pitcher_plan ────────────────────────────────────────────────────────────

  describe '#pitcher_plan' do
    context 'when all pitchers are eligible' do
      let(:availability_rows) do
        [
          avail_row('Alice', last_outing: '2026-03-25', last_pitches: 30, seven_day: 30),
          avail_row('Bob',   last_outing: '2026-03-24', last_pitches: 60, seven_day: 60)
        ]
      end

      it 'marks both available' do
        expect(brief.pitcher_plan.map { |r| r['available'] }).to all(be true)
      end

      it 'sorts by remaining pitches descending (most capacity first)' do
        names = brief.pitcher_plan.map { |r| r['pitcher_name'] }
        # Alice threw 30 → 55 remaining; Bob threw 60 → 25 remaining
        expect(names).to eq(['Alice', 'Bob'])
      end

      it 'enriches rows with remaining and high_load keys' do
        plan = brief.pitcher_plan
        expect(plan.first['remaining']).to eq(55)
        expect(plan.first['high_load']).to be false
      end
    end

    context 'when a pitcher needs rest' do
      let(:availability_rows) do
        [
          avail_row('Alice', last_outing: '2026-03-31', last_pitches: 70, seven_day: 70),
          avail_row('Bob',   last_outing: '2026-03-25', last_pitches: 20, seven_day: 20)
        ]
      end

      it 'marks Alice unavailable (needs 2 rest days after 70 pitches, pitched yesterday)' do
        alice = brief.pitcher_plan.find { |r| r['pitcher_name'] == 'Alice' }
        expect(alice['available']).to be false
      end

      it 'places unavailable pitchers after available ones' do
        names = brief.pitcher_plan.map { |r| r['pitcher_name'] }
        available_names   = brief.pitcher_plan.select { |r| r['available'] }.map { |r| r['pitcher_name'] }
        unavailable_names = brief.pitcher_plan.reject { |r| r['available'] }.map { |r| r['pitcher_name'] }
        expect(names).to eq(available_names + unavailable_names)
      end
    end

    context 'when a pitcher has high 7-day load' do
      let(:availability_rows) { [avail_row('Alice', last_outing: '2026-03-28', last_pitches: 40, seven_day: 80)] }

      it 'flags high_load' do
        expect(brief.pitcher_plan.first['high_load']).to be true
      end
    end

    context 'when availability_rows is empty' do
      it 'returns an empty array' do
        expect(brief.pitcher_plan).to be_empty
      end
    end
  end

  # ── #lineup ─────────────────────────────────────────────────────────────────

  describe '#lineup' do
    context 'with batter data' do
      let(:lineup_rows) { [batter_row('Alice'), batter_row('Bob', seven_day_ab: 0)] }

      it 'returns a LineupOptimizer' do
        expect(brief.lineup).to be_a(Gamechanger::LineupOptimizer)
      end

      it 'has ranked and unranked batters' do
        optimizer = brief.lineup
        expect(optimizer.ranked.map(&:batter_name)).to include('Alice')
        expect(optimizer.unranked.map(&:batter_name)).to include('Bob')
      end
    end

    context 'with empty lineup_rows' do
      it 'returns an empty LineupOptimizer' do
        expect(brief.lineup.ranked).to be_empty
        expect(brief.lineup.unranked).to be_empty
      end
    end
  end

  # ── #development_spotlights ─────────────────────────────────────────────────

  describe '#development_spotlights' do
    context 'when arc_rows is empty' do
      it 'returns empty array' do
        expect(brief.development_spotlights).to be_empty
      end
    end

    context 'with improving and declining players' do
      let(:arc_rows) do
        [
          arc_row('Alice', first_half_obp: 0.200, second_half_obp: 0.400, recent_obp: 0.400, total_games_batted: 8),
          arc_row('Bob',   first_half_obp: 0.350, second_half_obp: 0.180, recent_obp: 0.180, total_games_batted: 8),
          arc_row('Carol', first_half_obp: 0.220, second_half_obp: 0.380, recent_obp: 0.370, total_games_batted: 8)
        ]
      end

      it 'includes up to 2 improving batters' do
        spotlights = brief.development_spotlights
        improving  = spotlights.select { |a| a.bat_trend == '↑' }
        expect(improving.length).to be <= 2
      end

      it 'includes up to 1 declining batter' do
        spotlights = brief.development_spotlights
        declining  = spotlights.select { |a| a.bat_trend == '↓' }
        expect(declining.length).to be <= 1
      end

      it 'returns at most 3 spotlights total' do
        expect(brief.development_spotlights.length).to be <= 3
      end

      it 'returns PlayerArc structs' do
        brief.development_spotlights.each do |arc|
          expect(arc).to be_a(Gamechanger::PlayerArc)
        end
      end
    end

    context 'with only steady players (no trend)' do
      let(:arc_rows) do
        [arc_row('Alice', first_half_obp: 0.300, second_half_obp: 0.310, recent_obp: 0.305, total_games_batted: 8)]
      end

      it 'returns empty array when no notable trends' do
        expect(brief.development_spotlights).to be_empty
      end
    end
  end

  # ── #equity_flags ────────────────────────────────────────────────────────────

  describe '#equity_flags' do
    context 'when equity_rows is empty' do
      it 'returns empty array' do
        expect(brief.equity_flags).to be_empty
      end
    end

    context 'when total_games is zero' do
      let(:equity_rows) { [equity_row('Alice', total_games_batted: 0, total_games: 0)] }

      it 'returns empty array' do
        expect(brief.equity_flags).to be_empty
      end
    end

    context 'with a mix of participation levels' do
      let(:equity_rows) do
        [
          equity_row('Alice', total_games_batted: 4,  total_games: 10),  # 40% — flagged
          equity_row('Bob',   total_games_batted: 7,  total_games: 10),  # 70% — ok
          equity_row('Carol', total_games_batted: 5,  total_games: 10)   # 50% — flagged
        ]
      end

      it 'flags players below 60% participation' do
        names = brief.equity_flags.map { |r| r['player_name'] }
        expect(names).to include('Alice', 'Carol')
        expect(names).not_to include('Bob')
      end

      it 'sorts ascending by games batted (most underplayed first)' do
        names = brief.equity_flags.map { |r| r['player_name'] }
        expect(names.first).to eq('Alice')
      end
    end

    context 'when all players are above threshold' do
      let(:equity_rows) { [equity_row('Alice', total_games_batted: 8, total_games: 10)] }

      it 'returns empty array' do
        expect(brief.equity_flags).to be_empty
      end
    end
  end
  # PERF: `available` is derived from avail_date, which is nil when the pitcher
  # has never pitched — that case must stay unconditionally available even when
  # target_date is in the past.
  describe '#pitcher_plan nil last_outing semantics' do
    subject(:brief) do
      described_class.new(
        target_date: Date.today - 30,
        availability_rows: [avail_row('Pitcher One')],
        lineup_rows: [], arc_rows: [], equity_rows: [], rules: rules
      )
    end

    it 'marks a never-pitched pitcher available with a nil avail_date' do
      row = brief.pitcher_plan.first
      expect(row['available']).to be true
      expect(row['avail_date']).to be_nil
    end

    it 'marks a pitcher inside their rest window unavailable' do
      resting = described_class.new(
        target_date: Date.today,
        availability_rows: [avail_row('Pitcher Two', last_outing: Date.today.to_s, last_pitches: 70)],
        lineup_rows: [], arc_rows: [], equity_rows: [], rules: rules
      )
      row = resting.pitcher_plan.first
      expect(row['available']).to be false
      expect(row['avail_date']).to eq(Date.today + 4)
    end
  end
end
