# frozen_string_literal: true

require 'spec_helper'
require 'tmpdir'
require 'yaml'

RSpec.describe Gamechanger::CLI, '#setup' do
  let(:tmp_dir)     { Dir.mktmpdir }
  let(:config_file) { File.join(tmp_dir, 'config.yml') }
  let(:real_config) { Gamechanger::Config.new(config_file: config_file) }

  before do
    allow(Gamechanger::Config).to receive(:new).with(no_args).and_return(real_config)

    # Stub interactive prompts. Commands::Setup calls shell.ask, so stub the
    # shell directly (not just the Thor instance). Thor::Shell::Color inherits
    # from Thor::Shell::Basic, so stubbing on Basic catches both.
    ask_stub = lambda do |_instance, prompt, *_args, **_opts|
      case prompt
      when 'Email:'    then 'coach@team.com'
      when /Password/  then 'secret'
      when /Which team/ then '1'
      else ''
      end
    end
    allow_any_instance_of(described_class).to receive(:ask, &ask_stub)
    allow_any_instance_of(Thor::Shell::Basic).to receive(:ask, &ask_stub)
  end

  after { FileUtils.rm_rf(tmp_dir) }

  # ── scenario 1: single-team success ──────────────────────────────────────

  context 'when authentication succeeds and one team is found' do
    let(:client_double) do
      instance_double(
        Gamechanger::Client,
        authenticate: 'token-abc',
        teams: [{ 'id' => 'team-uuid-1', 'name' => 'Mustangs', 'slug' => 'wGP47FexatoQ' }]
      )
    end

    before do
      allow(Gamechanger::Client).to receive(:new).and_return(client_double)
    end

    it 'writes config to disk and exits 0' do
      described_class.start(['setup'])
      expect(File.exist?(config_file)).to be true
    end

    it 'prints confirmation message' do
      expect { described_class.start(['setup']) }
        .to output(/Configuration saved/).to_stdout
    end

    it 'stores the team name in output' do
      expect { described_class.start(['setup']) }
        .to output(/Mustangs/).to_stdout
    end
  end

  # ── scenario 2: authentication failure ───────────────────────────────────

  context 'when authentication fails' do
    let(:client_double) do
      instance_double(Gamechanger::Client).tap do |d|
        allow(d).to receive(:authenticate)
          .and_raise(Gamechanger::AuthError, 'Invalid credentials')
      end
    end

    before do
      allow(Gamechanger::Client).to receive(:new).and_return(client_double)
    end

    it 'exits with code 2' do
      expect { described_class.start(['setup']) }.to raise_error(SystemExit) do |e|
        expect(e.status).to eq(2)
      end
    end

    it 'prints an authentication error message' do
      expect do
        begin
          described_class.start(['setup'])
        rescue SystemExit
        end
      end.to output(/Authentication failed/).to_stdout
    end
  end

  # ── scenario 3: multiple teams → prompts for selection ───────────────────

  context 'when multiple teams are returned' do
    let(:client_double) do
      instance_double(
        Gamechanger::Client,
        authenticate: 'token-abc',
        teams: [
          { 'id' => 'team-uuid-1', 'name' => 'Mustangs', 'slug' => 'slug1' },
          { 'id' => 'team-uuid-2', 'name' => 'Falcons',  'slug' => 'slug2' }
        ]
      )
    end

    before do
      allow(Gamechanger::Client).to receive(:new).and_return(client_double)
    end

    it 'lists all teams and prompts for selection' do
      expect { described_class.start(['setup']) }
        .to output(/Multiple teams found/).to_stdout
    end

    it 'saves the selected team and exits 0' do
      described_class.start(['setup'])
      # ask returns '1' → index 0 → Mustangs
      saved = YAML.safe_load(File.read(config_file))
      expect(saved['team_id']).to eq('team-uuid-1')
    end

    it 'prints configuration saved message' do
      expect { described_class.start(['setup']) }
        .to output(/Configuration saved/).to_stdout
    end
  end
end
