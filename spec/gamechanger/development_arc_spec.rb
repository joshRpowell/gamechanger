# frozen_string_literal: true

require 'spec_helper'

RSpec.describe Gamechanger::DevelopmentArc do
  describe '.sparkline_for' do
    it 'returns empty string for empty values' do
      expect(described_class.sparkline_for([])).to eq('')
    end

    it 'uses middle bucket (▄) for flat values' do
      expect(described_class.sparkline_for([0.3, 0.3, 0.3])).to eq('▄▄▄')
    end

    it 'encodes rising trend — first char lowest, last char highest' do
      sparkline = described_class.sparkline_for([0.1, 0.3, 0.5, 0.7, 0.9])
      expect(sparkline[0]).to eq('▁')
      expect(sparkline[-1]).to eq('█')
    end

    it 'encodes falling trend — first char highest, last char lowest' do
      sparkline = described_class.sparkline_for([0.9, 0.7, 0.5, 0.3, 0.1])
      expect(sparkline[0]).to eq('█')
      expect(sparkline[-1]).to eq('▁')
    end

    it 'returns a string with length equal to the input array length' do
      values = [0.2, 0.4, 0.3, 0.5, 0.4, 0.6]
      expect(described_class.sparkline_for(values).length).to eq(6)
    end

    it 'uses only characters from the SPARKLINE_CHARS constant' do
      values = Array.new(10) { rand }
      sparkline = described_class.sparkline_for(values)
      sparkline.chars.each do |c|
        expect(Gamechanger::DevelopmentArc::SPARKLINE_CHARS).to include(c)
      end
    end
  end

  describe '.build_summary' do
    let(:improving_row) do
      {
        'player_name'            => 'Jayden',
        'first_half_obp'         => 0.271,
        'second_half_obp'        => 0.338,
        'recent_obp'             => 0.400,
        'total_games_batted'     => 12,
        'first_half_strike_pct'  => nil,
        'second_half_strike_pct' => nil,
        'recent_strike_pct'      => nil,
        'total_games_pitched'    => nil
      }
    end

    let(:declining_row) do
      improving_row.merge('player_name' => 'Marcus', 'first_half_obp' => 0.380, 'second_half_obp' => 0.210)
    end

    let(:flat_row) do
      improving_row.merge('player_name' => 'Sofia', 'first_half_obp' => 0.300, 'second_half_obp' => 0.310, 'recent_obp' => 0.305)
    end

    it 'returns one PlayerArc per row' do
      arcs = described_class.build_summary([improving_row, declining_row])
      expect(arcs.length).to eq(2)
      expect(arcs.all? { |a| a.is_a?(Gamechanger::PlayerArc) }).to be true
    end

    it 'sets bat_trend to ↑ when second half OBP > first half by 0.050+' do
      arc = described_class.build_summary([improving_row]).first
      expect(arc.bat_trend).to eq('↑')
    end

    it 'sets bat_trend to ↓ when second half OBP < first half by 0.050+' do
      arc = described_class.build_summary([declining_row]).first
      expect(arc.bat_trend).to eq('↓')
    end

    it 'sets bat_trend to → when delta is within threshold' do
      arc = described_class.build_summary([flat_row]).first
      expect(arc.bat_trend).to eq('→')
    end

    it 'sets bat_narrative to peaking archetype for improving player' do
      arc = described_class.build_summary([improving_row]).first
      expect(arc.bat_narrative).to match(/Peaking at the right time/)
    end

    it 'sets bat_narrative to steady contributor for flat player' do
      arc = described_class.build_summary([flat_row]).first
      expect(arc.bat_narrative).to match(/Steady contributor/)
    end

    it 'returns nil pitch_trend when player has no pitching data' do
      arc = described_class.build_summary([improving_row]).first
      expect(arc.pitch_trend).to be_nil
    end

    it 'returns nil pitch_narrative when player has no pitching data' do
      arc = described_class.build_summary([improving_row]).first
      expect(arc.pitch_narrative).to be_nil
    end

    it 'sets empty bat_sparkline (sparklines require per-game data from build_player)' do
      arc = described_class.build_summary([improving_row]).first
      expect(arc.bat_sparkline).to eq('')
    end
  end

  describe '.build_player' do
    let(:summary_row) do
      {
        'player_name'            => 'Jayden',
        'first_half_obp'         => 0.271,
        'second_half_obp'        => 0.338,
        'recent_obp'             => 0.400,
        'total_games_batted'     => 6,
        'first_half_strike_pct'  => 0.58,
        'second_half_strike_pct' => 0.67,
        'recent_strike_pct'      => 0.70,
        'total_games_pitched'    => 4
      }
    end

    let(:bat_rows) do
      [
        { 'hits' => 1, 'walks' => 1, 'at_bats' => 4 },
        { 'hits' => 2, 'walks' => 0, 'at_bats' => 3 },
        { 'hits' => 1, 'walks' => 2, 'at_bats' => 4 },
        { 'hits' => 2, 'walks' => 1, 'at_bats' => 3 },
        { 'hits' => 3, 'walks' => 1, 'at_bats' => 4 },
        { 'hits' => 3, 'walks' => 2, 'at_bats' => 4 }
      ]
    end

    let(:pitch_rows) do
      [
        { 'pitches_thrown' => 40, 'strikes_thrown' => 24 },
        { 'pitches_thrown' => 45, 'strikes_thrown' => 28 },
        { 'pitches_thrown' => 50, 'strikes_thrown' => 33 },
        { 'pitches_thrown' => 48, 'strikes_thrown' => 32 }
      ]
    end

    it 'populates bat_sparkline with the correct length' do
      arc = described_class.build_player(summary_row, bat_rows, pitch_rows)
      expect(arc.bat_sparkline.length).to eq(bat_rows.length)
    end

    it 'populates pitch_sparkline with the correct length' do
      arc = described_class.build_player(summary_row, bat_rows, pitch_rows)
      expect(arc.pitch_sparkline.length).to eq(pitch_rows.length)
    end

    it 'uses only sparkline characters in bat_sparkline' do
      arc = described_class.build_player(summary_row, bat_rows, pitch_rows)
      arc.bat_sparkline.chars.each do |c|
        expect(Gamechanger::DevelopmentArc::SPARKLINE_CHARS).to include(c)
      end
    end

    it 'sets empty bat_sparkline when no bat_rows given' do
      arc = described_class.build_player(summary_row, [], pitch_rows)
      expect(arc.bat_sparkline).to eq('')
    end
  end

  describe '.narrative_for (via build_summary)' do
    def narrative(first, second, recent, total, type: :bat)
      row = {
        'player_name'        => 'Test',
        'first_half_obp'     => type == :bat ? first : nil,
        'second_half_obp'    => type == :bat ? second : nil,
        'recent_obp'         => type == :bat ? recent : nil,
        'total_games_batted' => type == :bat ? total  : nil,
        'first_half_strike_pct'  => type == :pitch ? first  : nil,
        'second_half_strike_pct' => type == :pitch ? second : nil,
        'recent_strike_pct'      => type == :pitch ? recent : nil,
        'total_games_pitched'    => type == :pitch ? total  : nil
      }
      arc = described_class.build_summary([row]).first
      type == :bat ? arc.bat_narrative : arc.pitch_narrative
    end

    it 'returns limited sample narrative when total_games < 5' do
      expect(narrative(0.3, 0.4, 0.4, 3)).to match(/Building their game/)
    end

    it 'returns steady contributor when delta is within threshold' do
      expect(narrative(0.300, 0.310, 0.305, 10)).to match(/Steady contributor/)
    end

    it 'returns finding their groove when recent >> first_half but halves are similar' do
      expect(narrative(0.280, 0.290, 0.410, 10)).to match(/Finding their groove/)
    end

    it 'returns peaking at the right time for strong second half' do
      expect(narrative(0.270, 0.340, 0.400, 10)).to match(/Peaking at the right time/)
    end

    it 'returns strong starter when first half significantly better than second' do
      expect(narrative(0.380, 0.290, 0.280, 10)).to match(/Strong starter/)
    end

    it 'returns building their game for pitchers with < 5 outings' do
      expect(narrative(0.58, 0.67, 0.70, 3, type: :pitch)).to match(/Building their game/)
    end

    it 'returns strike command sharpening for improving pitcher' do
      expect(narrative(0.58, 0.67, 0.70, 8, type: :pitch)).to match(/Strike command sharpening/)
    end
  end
end
