# frozen_string_literal: true

require 'spec_helper'

RSpec.describe Gamechanger::Commands::Demo do
  let(:shell) { instance_double(Thor::Shell::Basic, say: nil, say_error: nil) }
  let(:options) { { format: 'table', report: 'brief' } }

  it 'renders the anonymized sample pre-game brief without configuration' do
    expect { described_class.new(options: options, shell: shell).call }
      .to output(/Pre-Game Brief: 2026-07-16 vs Bayshore Buccaneers/).to_stdout
  end

  it 'renders a ranked lineup action in the sample brief' do
    expect { described_class.new(options: options, shell: shell).call }
      .to output(/Lineup: start with .* based on 7-day OBP.*Suggested Lineup/m).to_stdout
  end

  it 'renders the anonymized sample progress report' do
    expect do
      described_class.new(options: options.merge(report: 'progress'), shell: shell).call
    end.to output(/Batting Arc/).to_stdout
  end

  it 'cleans up the staged demo directory after rendering' do
    staged_dir = nil
    allow(Gamechanger::DemoFixture).to receive(:stage).and_wrap_original do |method|
      staged_dir = method.call
    end

    described_class.new(options: options, shell: shell).call

    expect(Dir.exist?(staged_dir)).to be false
  end
end
