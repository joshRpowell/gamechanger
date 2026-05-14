# frozen_string_literal: true

require 'spec_helper'

RSpec.describe Gamechanger::Commands::Setup do
  let(:shell)   { instance_spy(Thor::Shell::Color) }
  let(:options) { {} }
  let(:command) { described_class.new(options: options, shell: shell) }

  describe 'extract_teams_list (private helper)' do
    # Expose via send for direct testing.

    it 'returns an array as-is' do
      result = command.send(:extract_teams_list, [{ 'id' => '1', 'name' => 'X' }])
      expect(result).to eq([{ 'id' => '1', 'name' => 'X' }])
    end

    it 'unwraps a hash with a "teams" key' do
      result = command.send(:extract_teams_list, { 'teams' => [{ 'id' => '1' }] })
      expect(result).to eq([{ 'id' => '1' }])
    end

    it 'unwraps a hash with a "data" key when "teams" is absent' do
      result = command.send(:extract_teams_list, { 'data' => [{ 'id' => '2' }] })
      expect(result).to eq([{ 'id' => '2' }])
    end

    it 'returns an empty array for a hash with neither key' do
      result = command.send(:extract_teams_list, { 'other' => 'value' })
      expect(result).to eq([])
    end

    it 'returns an empty array for non-Array/Hash inputs' do
      expect(command.send(:extract_teams_list, 'string')).to eq([])
      expect(command.send(:extract_teams_list, 42)).to eq([])
      expect(command.send(:extract_teams_list, nil)).to eq([])
    end
  end

  describe 'authenticate_or_exit (private helper)' do
    let(:client) { instance_double(Gamechanger::Client) }

    it 'returns silently when authenticate succeeds' do
      allow(client).to receive(:authenticate).and_return('token')
      expect { command.send(:authenticate_or_exit, client) }.not_to raise_error
    end

    it 'exits 2 with red message on AuthError' do
      allow(client).to receive(:authenticate).and_raise(Gamechanger::AuthError, 'Invalid')

      expect { command.send(:authenticate_or_exit, client) }.to raise_error(SystemExit) do |e|
        expect(e.status).to eq(2)
      end
      expect(shell).to have_received(:say).with('Authentication failed: Invalid', :red)
    end

    it 'exits 3 with red message on NetworkError' do
      allow(client).to receive(:authenticate).and_raise(Gamechanger::NetworkError, 'timeout')

      expect { command.send(:authenticate_or_exit, client) }.to raise_error(SystemExit) do |e|
        expect(e.status).to eq(3)
      end
      expect(shell).to have_received(:say).with('Network error: timeout', :red)
    end
  end

  describe 'discover_team (private helper)' do
    let(:client) { instance_double(Gamechanger::Client) }

    it 'auto-selects when exactly one team is found' do
      allow(client).to receive(:teams).and_return(
        [{ 'id' => 't1', 'name' => 'Mustangs', 'slug' => 'abc' }]
      )

      team_id, team_slug = command.send(:discover_team, client)

      expect(team_id).to eq('t1')
      expect(team_slug).to eq('abc')
      expect(shell).to have_received(:say).with('Team: Mustangs (t1)', :green)
    end

    it 'yields nil team_id and yellow message when no teams are returned' do
      allow(client).to receive(:teams).and_return([])
      allow(shell).to receive(:ask).and_return('manual-slug-from-user')

      team_id, team_slug = command.send(:discover_team, client)

      expect(team_id).to be_nil
      expect(team_slug).to eq('manual-slug-from-user')
      expect(shell).to have_received(:say).with('No teams found for this account.', :yellow)
    end

    it 'falls back to short_id when slug is missing on the team object' do
      allow(client).to receive(:teams).and_return(
        [{ 'id' => 't1', 'name' => 'Mustangs', 'short_id' => 'xyz' }]
      )

      _team_id, team_slug = command.send(:discover_team, client)

      expect(team_slug).to eq('xyz')
    end

    it 'rescues APIShapeError and prints yellow recovery hint' do
      allow(client).to receive(:teams).and_raise(Gamechanger::APIShapeError, 'shape mismatch')

      team_id, team_slug = command.send(:discover_team, client)

      expect(team_id).to be_nil
      expect(team_slug).to be_nil
      expect(shell).to have_received(:say).with('Could not auto-detect team: shape mismatch', :yellow)
    end
  end
end
