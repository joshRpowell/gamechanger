# frozen_string_literal: true

require 'webmock/rspec'
require 'gamechanger'

WebMock.disable_net_connect!(allow_localhost: true)

RSpec.shared_context 'seeded storage' do
  let(:storage) { Gamechanger::Storage.new(data_dir: ':memory:') }

  before do
    today = Date.today
    # Two final games
    storage.upsert_game(game_id: 'g1', game_date: (today - 14).to_s,
                        opponent: 'Eagles', home_away: 'home', status: 'final')
    storage.upsert_game(game_id: 'g2', game_date: (today - 7).to_s,
                        opponent: 'Hawks', home_away: 'away', status: 'final')
    # One upcoming game
    storage.upsert_game(game_id: 'g3', game_date: (today + 7).to_s,
                        opponent: 'Falcons', home_away: 'home', status: 'scheduled')

    storage.upsert_pitcher_stats(game_id: 'g1', stats: [
      { pitcher_name: 'Alice Smith', pitches_thrown: 65, strikes_thrown: 42, innings_pitched: 4.0 }
    ])
    storage.upsert_pitcher_stats(game_id: 'g2', stats: [
      { pitcher_name: 'Alice Smith', pitches_thrown: 55, strikes_thrown: 35, innings_pitched: 3.0 },
      { pitcher_name: 'Carlos Ruiz', pitches_thrown: 30, strikes_thrown: 20, innings_pitched: 2.0 }
    ])
    storage.upsert_batter_stats(game_id: 'g1', stats: [
      { batter_name: 'Bob Jones',   at_bats: 3, hits: 2, walks: 0, strikeouts: 1 },
      { batter_name: 'Carol White', at_bats: 3, hits: 1, walks: 1, strikeouts: 0 }
    ])
    storage.upsert_batter_stats(game_id: 'g2', stats: [
      { batter_name: 'Bob Jones',   at_bats: 3, hits: 1, walks: 1, strikeouts: 0 },
      { batter_name: 'Carol White', at_bats: 3, hits: 0, walks: 0, strikeouts: 2 }
    ])

    allow(Gamechanger::Storage).to receive(:new).and_return(storage)
    allow(Gamechanger::Config).to receive(:new).and_return(
      instance_double(Gamechanger::Config, configured?: true,
                      team_id: 'team-1', team_slug: 'abc123', season: Date.today.year)
    )
    allow(Gamechanger::Syncer).to receive(:new).and_return(
      instance_double(Gamechanger::Syncer, run: nil)
    )
  end
end

RSpec.configure do |config|
  config.expect_with :rspec do |expectations|
    expectations.include_chain_clauses_in_custom_matcher_descriptions = true
  end

  config.mock_with :rspec do |mocks|
    mocks.verify_partial_doubles = true
  end

  config.shared_context_metadata_behavior = :apply_to_host_groups
  config.filter_run_when_matching :focus
  config.disable_monkey_patching!
  config.warnings = true
  config.order = :random
  Kernel.srand config.seed
end
