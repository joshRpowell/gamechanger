# frozen_string_literal: true

require 'spec_helper'

RSpec.describe Gamechanger::Commands::Setup do
  let(:shell)   { instance_spy(Thor::Shell::Color) }
  let(:options) { {} }
  let(:command) { described_class.new(options: options, shell: shell) }

  describe 'extract_teams_list (private helper)' do
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
      expect(command.send(:extract_teams_list, { 'other' => 'value' })).to eq([])
    end

    it 'returns an empty array for non-Array/Hash inputs' do
      expect(command.send(:extract_teams_list, 'string')).to eq([])
      expect(command.send(:extract_teams_list, 42)).to eq([])
      expect(command.send(:extract_teams_list, nil)).to eq([])
    end
  end

  describe 'authenticate_or_exit' do
    let(:client) { instance_double(Gamechanger::Client) }

    it 'returns silently when authenticate succeeds' do
      allow(client).to receive(:authenticate).and_return('token')
      expect { command.send(:authenticate_or_exit, client) }.not_to raise_error
    end

    it 'exits 2 with "Authentication failed:" on stderr for AuthError' do
      allow(client).to receive(:authenticate).and_raise(Gamechanger::AuthError, 'Invalid')

      expect { command.send(:authenticate_or_exit, client) }.to raise_error(SystemExit) { |e| expect(e.status).to eq(2) }
      expect(shell).to have_received(:say_error).with('Authentication failed: Invalid', :red)
    end

    it 'exits 3 with "Network error:" on stderr for NetworkError' do
      allow(client).to receive(:authenticate).and_raise(Gamechanger::NetworkError, 'timeout')

      expect { command.send(:authenticate_or_exit, client) }.to raise_error(SystemExit) { |e| expect(e.status).to eq(3) }
      expect(shell).to have_received(:say_error).with('Network error: timeout', :red)
    end
  end

  describe '#call (regression: stale session token)' do
    # Bug: re-running `gamechanger setup` after credentials change would
    # reuse the stale cached session token, causing the discover_team
    # call to 401 even when the new password was correct.
    it 'clears the cached session token before authenticating' do
      cfg    = instance_double(Gamechanger::Config)
      client = instance_double(Gamechanger::Client)
      allow(Gamechanger::Config).to receive(:new).and_return(cfg)
      allow(Gamechanger::Client).to receive(:new).and_return(client)
      allow(cfg).to receive(:save)
      allow(cfg).to receive(:clear_token)
      allow(cfg).to receive(:email).and_return(nil)
      allow(cfg).to receive(:password_op_ref).and_return(nil)
      allow(client).to receive(:authenticate)
      allow(client).to receive(:teams).and_return(
        [{ 'id' => 't1', 'name' => 'Mustangs', 'slug' => 'abc' }]
      )

      cmd = described_class.new(
        options: { email: 'a@b.com', password: 'pw' },
        shell:   shell
      )
      cmd.call

      expect(cfg).to have_received(:clear_token).ordered
      expect(client).to have_received(:authenticate).ordered
    end
  end

  describe 'discover_team' do
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

    it 'falls back to short_id when slug is missing on the team object' do
      allow(client).to receive(:teams).and_return(
        [{ 'id' => 't1', 'name' => 'Mustangs', 'short_id' => 'xyz' }]
      )

      _team_id, team_slug = command.send(:discover_team, client)

      expect(team_slug).to eq('xyz')
    end

    it 'uses --team-slug option to skip the manual slug prompt' do
      # Thor's options hash uses indifferent-access. Tests pass a plain Hash,
      # so use the symbol key form that Commands::Setup actually reads.
      cmd = described_class.new(options: { :'team-slug' => 'env-slug' }, shell: shell)
      allow(client).to receive(:teams).and_return(
        [{ 'id' => 't1', 'name' => 'Mustangs' }]  # no slug field
      )

      _team_id, team_slug = cmd.send(:discover_team, client)

      expect(team_slug).to eq('env-slug')
    end

    it 'rescues APIShapeError and prints yellow recovery hint to stderr' do
      allow(client).to receive(:teams).and_raise(Gamechanger::APIShapeError, 'shape mismatch')

      team_id, team_slug = command.send(:discover_team, client)

      expect(team_id).to be_nil
      expect(team_slug).to be_nil
      expect(shell).to have_received(:say_error).with('Could not auto-detect team: shape mismatch', :yellow)
    end
  end
end
