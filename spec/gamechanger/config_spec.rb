# frozen_string_literal: true

require 'spec_helper'

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
    it 'writes token and expiry to session file' do
      config.cache_token('abc123', expires_at: 9999999999)
      content = File.read(session_file)
      expect(content).to eq('abc123|9999999999')
    end

    it 'uses a default TTL when expires_at is nil' do
      config.cache_token('abc123')
      content = File.read(session_file)
      token, expiry = content.split('|')
      expect(token).to eq('abc123')
      expect(expiry.to_i).to be > Time.now.to_i
    end

    it 'creates session file with 0600 permissions' do
      config.cache_token('abc123', expires_at: 9999999999)
      perms = File.stat(session_file).mode & 0o777
      expect(perms).to eq(0o600)
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
