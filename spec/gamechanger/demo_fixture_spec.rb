# frozen_string_literal: true

require 'spec_helper'

RSpec.describe Gamechanger::DemoFixture do
  it 'stages the anchor as cache.db with migration metadata' do
    dir = described_class.stage
    db = SQLite3::Database.new(File.join(dir, Gamechanger::Storage::DB_FILE))

    versions = db.execute('SELECT version FROM schema_migrations ORDER BY version').flatten
    expect(versions).to include(1, 2, 3)
  ensure
    db&.close
    FileUtils.remove_entry_secure(dir) if dir && Dir.exist?(dir)
  end
end
