# frozen_string_literal: true

require 'fileutils'
require 'sqlite3'
require 'tmpdir'

module Gamechanger
  # Stages the committed anonymized cache anchor as a writable Ruby cache.
  # The anchor intentionally has no schema_migrations table; seed the versions
  # matching its schema so Storage can apply later additive migrations normally.
  class DemoFixture
    ANCHOR_PATH = File.expand_path('../../internal/parity/testdata/cache-anchor.db', __dir__).freeze

    def self.stage
      new.stage
    end

    def stage
      raise ConfigError, "Demo fixture not found at #{ANCHOR_PATH}" unless File.exist?(ANCHOR_PATH)

      dir = Dir.mktmpdir('gamechanger-demo-')
      FileUtils.cp(ANCHOR_PATH, File.join(dir, Storage::DB_FILE))
      File.chmod(0o600, File.join(dir, Storage::DB_FILE))
      seed_migration_metadata(File.join(dir, Storage::DB_FILE))
      dir
    rescue StandardError => e
      FileUtils.remove_entry_secure(dir) if dir && Dir.exist?(dir)
      raise e
    end

    private

    def seed_migration_metadata(path)
      db = SQLite3::Database.new(path)
      db.execute(<<~SQL)
        CREATE TABLE IF NOT EXISTS schema_migrations (
          version    INTEGER PRIMARY KEY NOT NULL,
          applied_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%SZ', 'now'))
        )
      SQL
      [1, 2, 3].each do |version|
        db.execute('INSERT OR IGNORE INTO schema_migrations (version) VALUES (?)', [version])
      end
    ensure
      db&.close
    end
  end
end
