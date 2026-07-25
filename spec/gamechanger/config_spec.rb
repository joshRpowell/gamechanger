# frozen_string_literal: true

require 'spec_helper'
require 'open3'

RSpec.describe Gamechanger::Config do
  subject(:config) { described_class.new(config_file: config_file) }

  around do |example|
    Dir.mktmpdir do |tmpdir|
      @tmpdir = tmpdir
      example.run
    end
  end

  let(:config_file) { File.join(@tmpdir, 'config.yml') }
  let(:session_file) { File.join(File.dirname(config_file), 'session') }

  before do
    # Point GAMECHANGER_HOME at the tempdir so session_file_path resolves there.
    ENV['GAMECHANGER_HOME'] = @tmpdir
  end

  after do
    ENV.delete('GAMECHANGER_HOME')
  end

  describe '#configured?' do
    it 'returns false when config file does not exist' do
      expect(config.configured?).to be false
    end

    it 'defaults season to the current year when config file does not exist' do
      expect(config.season).to eq(Time.now.year)
    end

    it 'returns true when email and password are set' do
      config.save(email: 'a@b.com', password: 'pass')
      expect(config.configured?).to be true
    end

    it 'returns false when email is empty string' do
      File.write(config_file, YAML.dump('email' => '', 'password' => 'pass'))
      cfg = described_class.new(config_file: config_file)
      expect(cfg.configured?).to be false
    end

    it 'returns false when password is nil' do
      File.write(config_file, YAML.dump('email' => 'a@b.com', 'password' => nil))
      cfg = described_class.new(config_file: config_file)
      expect(cfg.configured?).to be false
    end
  end

  describe '#save' do
    it 'preserves team fields and season when saving updated credentials' do
      config.save(email: 'coach@example.com', password: 'old-pass',
                  team_id: 'team-uuid', team_slug: 'team-slug', season: 2026)

      config.save(email: 'coach@example.com', password: 'new-pass')

      expect(config.team_id).to eq('team-uuid')
      expect(config.team_slug).to eq('team-slug')
      expect(config.season).to eq(2026)
      expect(config.password).to eq('new-pass')
    end

    it 'allows team-only updates when credentials already exist' do
      config.save(email: 'coach@example.com', password: 'pass')

      config.save(email: 'coach@example.com', team_id: 'team-uuid', team_slug: 'team-slug')

      expect(config.configured?).to be true
      expect(config.team_id).to eq('team-uuid')
      expect(config.team_slug).to eq('team-slug')
      expect(config.password).to eq('pass')
    end

    it 'preserves the existing device_id across partial saves' do
      config.save(email: 'coach@example.com', password: 'pass')
      original_device_id = config.device_id

      config.save(email: 'coach@example.com', password: 'new-pass')

      expect(config.device_id).to eq(original_device_id)
    end

    it 'removes stale plaintext password when switching to a 1Password reference' do
      config.save(email: 'coach@example.com', password: 'plain')

      config.save(email: 'coach@example.com', password_op_ref: 'op://Vault/Item/password')

      data = YAML.safe_load(File.read(config_file))
      expect(data).not_to have_key('password')
      expect(config.password_op_ref).to eq('op://Vault/Item/password')
    end
  end

  describe '#cached_token' do
    it 'returns nil when session file does not exist' do
      expect(config.cached_token).to be_nil
    end

    it 'returns the token when valid and not expired' do
      future = Time.now.to_i + 3600
      File.write(session_file, "my-token|#{future}")
      File.chmod(0o600, session_file)
      expect(config.cached_token).to eq('my-token')
    end

    it 'returns nil when token is expired' do
      past = Time.now.to_i - 1
      File.write(session_file, "expired-token|#{past}")
      File.chmod(0o600, session_file)
      expect(config.cached_token).to be_nil
    end

    it 'returns nil when token field is empty' do
      File.write(session_file, '|12345')
      expect(config.cached_token).to be_nil
    end

    it 'returns token when no expiry is set (no pipe)' do
      File.write(session_file, 'token-no-expiry')
      expect(config.cached_token).to eq('token-no-expiry')
    end

    it 'returns nil and does not raise on unreadable/corrupt session file' do
      File.write(session_file, "bad\x00data")
      # StandardError rescue returns nil
      allow(File).to receive(:read).with(session_file).and_raise(StandardError, 'boom')
      expect(config.cached_token).to be_nil
    end
  end

  describe '#cache_token' do
    it 'persists the token so cached_token reads it back' do
      config.cache_token('abc123', expires_at: 9999999999)
      expect(config.cached_token).to eq('abc123')
    end

    it 'uses a default TTL when expires_at is nil' do
      config.cache_token('abc123')
      expect(config.cached_token).to eq('abc123')
    end

    it 'creates session file with 0600 permissions' do
      config.cache_token('abc123', expires_at: 9999999999)
      perms = File.stat(session_file).mode & 0o777
      expect(perms).to eq(0o600)
    end
  end

  describe '#cache_tokens / #cached_refresh_token' do
    it 'stores access + refresh tokens and reads them back' do
      config.cache_tokens(
        access_token: 'a-tok', access_expires: 9999999999,
        refresh_token: 'r-tok', refresh_expires: 9999999999
      )
      expect(config.cached_token).to eq('a-tok')
      expect(config.cached_refresh_token).to eq('r-tok')
    end

    it 'preserves prior refresh token when caching only access' do
      config.cache_tokens(access_token: 'a1', access_expires: 9999999999,
                          refresh_token: 'r1', refresh_expires: 9999999999)
      config.cache_tokens(access_token: 'a2', access_expires: 9999999999)
      expect(config.cached_token).to eq('a2')
      expect(config.cached_refresh_token).to eq('r1')
    end

    it 'returns nil for expired refresh token' do
      config.cache_tokens(access_token: 'a', access_expires: 9999999999,
                          refresh_token: 'r', refresh_expires: Time.now.to_i - 1)
      expect(config.cached_refresh_token).to be_nil
    end

    it 'reads legacy single-token text format for backwards compat' do
      File.write(session_file, "legacy-tok|#{Time.now.to_i + 3600}")
      expect(config.cached_token).to eq('legacy-tok')
      expect(config.cached_refresh_token).to be_nil
    end
  end

  describe '#clear_token' do
    it 'deletes session file when it exists' do
      File.write(session_file, 'token|12345')
      config.clear_token
      expect(File.exist?(session_file)).to be false
    end

    it 'does nothing when session file does not exist' do
      expect { config.clear_token }.not_to raise_error
    end
  end

  # PERF: load_session is hit 2-3x per API request (Client#authenticate +
  # Client#build_request), so the parsed session is memoized per Config
  # instance. These specs pin both the memoization and every invalidation path.
  describe 'session memoization' do
    let(:future) { Time.now.to_i + 3600 }

    def session_reads
      # Count only reads of the session file; the config file is read too.
      @session_reads
    end

    before do
      @session_reads = 0
      allow(File).to receive(:read).and_wrap_original do |orig, path, *args|
        @session_reads += 1 if path == session_file
        orig.call(path, *args)
      end
    end

    it 'reads and parses the session file only once across repeated reads' do
      File.write(session_file, YAML.dump('access_token' => 'fake-access',
                                         'access_expires' => future,
                                         'refresh_token' => 'fake-refresh',
                                         'refresh_expires' => future))

      expect(config.cached_token).to eq('fake-access')
      5.times { config.cached_token }
      config.cached_refresh_token

      expect(session_reads).to eq(1)
    end

    it 'returns identical data on every call' do
      File.write(session_file, YAML.dump('access_token' => 'fake-access',
                                         'access_expires' => future))
      first = config.cached_token
      expect(config.cached_token).to eq(first)
      expect(config.cached_refresh_token).to be_nil
    end

    it 'memoizes the absence of a session file without re-reading' do
      expect(config.cached_token).to be_nil
      expect(config.cached_token).to be_nil
      expect(session_reads).to eq(0)
    end

    it 'serves the new token after cache_tokens writes mid-process (no stale read)' do
      File.write(session_file, YAML.dump('access_token' => 'fake-old',
                                         'access_expires' => future))
      expect(config.cached_token).to eq('fake-old')

      config.cache_tokens(access_token: 'fake-refreshed', access_expires: future)

      expect(config.cached_token).to eq('fake-refreshed')
      expect(session_reads).to eq(2)
    end

    it 'serves the new token after cache_token writes mid-process' do
      File.write(session_file, YAML.dump('access_token' => 'fake-old',
                                         'access_expires' => future))
      expect(config.cached_token).to eq('fake-old')

      config.cache_token('fake-rotated', expires_at: future)

      expect(config.cached_token).to eq('fake-rotated')
    end

    it 'preserves the refresh token across a cached access-only refresh' do
      config.cache_tokens(access_token: 'fake-a1', access_expires: future,
                          refresh_token: 'fake-r1', refresh_expires: future)
      expect(config.cached_refresh_token).to eq('fake-r1')

      config.cache_tokens(access_token: 'fake-a2', access_expires: future)

      expect(config.cached_token).to eq('fake-a2')
      expect(config.cached_refresh_token).to eq('fake-r1')
    end

    it 'returns nil after clear_token rather than the memoized token' do
      File.write(session_file, YAML.dump('access_token' => 'fake-access',
                                         'access_expires' => future))
      expect(config.cached_token).to eq('fake-access')

      config.clear_token

      expect(config.cached_token).to be_nil
      expect(config.cached_refresh_token).to be_nil
    end

    it 'returns nil after clear_token even when no session file existed' do
      expect(config.cached_token).to be_nil
      config.clear_token
      expect(config.cached_token).to be_nil
    end

    it 'ignores the memoized session when GAMECHANGER_HOME changes mid-process' do
      File.write(session_file, YAML.dump('access_token' => 'fake-home-a',
                                         'access_expires' => future))
      expect(config.cached_token).to eq('fake-home-a')

      Dir.mktmpdir do |other_home|
        File.write(File.join(other_home, 'session'),
                   YAML.dump('access_token' => 'fake-home-b', 'access_expires' => future))
        ENV['GAMECHANGER_HOME'] = other_home

        expect(config.cached_token).to eq('fake-home-b')
      end
    end
  end

  describe '1Password password resolution' do
    it 'is configured when only password_op_ref is set' do
      config.save(email: 'a@b.com', password_op_ref: 'op://Vault/Item/password')
      expect(config.configured?).to be true
    end

    it 'raises when neither password nor password_op_ref is given' do
      expect { config.save(email: 'a@b.com') }
        .to raise_error(Gamechanger::ConfigError, /Either password or password_op_ref/)
    end

    it 'resolves password via `op read` when only op ref is set' do
      config.save(email: 'a@b.com', password_op_ref: 'op://Vault/Item/password')
      allow(Open3).to receive(:capture3)
        .with('op', 'read', '--no-newline', 'op://Vault/Item/password')
        .and_return(['secret-from-op', '', instance_double(Process::Status, success?: true)])
      expect(config.password).to eq('secret-from-op')
    end

    it 'memoizes the resolved password (only one `op read` call)' do
      config.save(email: 'a@b.com', password_op_ref: 'op://Vault/Item/password')
      expect(Open3).to receive(:capture3).once
        .and_return(['secret', '', instance_double(Process::Status, success?: true)])
      2.times { config.password }
    end

    it 'prefers inline password over op ref when both are present' do
      config.save(email: 'a@b.com', password: 'inline', password_op_ref: 'op://Vault/Item/password')
      expect(Open3).not_to receive(:capture3)
      expect(config.password).to eq('inline')
    end

    it 'raises ConfigError when op CLI fails' do
      config.save(email: 'a@b.com', password_op_ref: 'op://Vault/Item/password')
      allow(Open3).to receive(:capture3)
        .and_return(['', 'not signed in', instance_double(Process::Status, success?: false)])
      expect { config.password }.to raise_error(Gamechanger::ConfigError, /not signed in/)
    end

    it 'raises ConfigError when op CLI is not installed' do
      config.save(email: 'a@b.com', password_op_ref: 'op://Vault/Item/password')
      allow(Open3).to receive(:capture3).and_raise(Errno::ENOENT)
      expect { config.password }.to raise_error(Gamechanger::ConfigError, /not found in PATH/)
    end
  end

  describe 'malformed config file' do
    it 'raises ConfigError on YAML parse failure' do
      File.write(config_file, "key: {\n  bad yaml: [\n")
      expect { described_class.new(config_file: config_file) }
        .to raise_error(Gamechanger::ConfigError, /Malformed config/)
    end
  end

  describe '.home_dir + GAMECHANGER_HOME env var (verify-parity harness)' do
    # The verify-parity harness sets GAMECHANGER_HOME so Ruby and Go read from the same fixture.

    it 'returns the env-var path when GAMECHANGER_HOME is set' do
      ENV['GAMECHANGER_HOME'] = '/tmp/custom-gc-home'
      expect(described_class.home_dir).to eq('/tmp/custom-gc-home')
    end

    it 'expands ~ when GAMECHANGER_HOME contains a tilde' do
      ENV['GAMECHANGER_HOME'] = '~/custom-gc-home'
      expect(described_class.home_dir).to eq(File.expand_path('~/custom-gc-home'))
    end

    it 'falls back to ~/.gamechanger when GAMECHANGER_HOME is unset (REGRESSION GUARD)' do
      ENV.delete('GAMECHANGER_HOME')
      expect(described_class.home_dir).to eq(File.expand_path('~/.gamechanger'))
    end

    it 'falls back to ~/.gamechanger when GAMECHANGER_HOME is empty string' do
      ENV['GAMECHANGER_HOME'] = ''
      expect(described_class.home_dir).to eq(File.expand_path('~/.gamechanger'))
    end

    it 'session_file_path uses the env-var directory' do
      ENV['GAMECHANGER_HOME'] = @tmpdir
      expect(described_class.session_file_path).to eq(File.join(@tmpdir, 'session'))
    end

    it 'config_file_path uses the env-var directory' do
      ENV['GAMECHANGER_HOME'] = @tmpdir
      expect(described_class.config_file_path).to eq(File.join(@tmpdir, 'config.yml'))
    end

    it 'CONFIG_FILE legacy constant still points to ~/.gamechanger (REGRESSION GUARD)' do
      # External callers may still reference the constant; it never reflected runtime ENV.
      expect(Gamechanger::Config::CONFIG_FILE).to eq(File.expand_path('~/.gamechanger/config.yml'))
    end
  end
end
