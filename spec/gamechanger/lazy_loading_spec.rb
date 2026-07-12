# frozen_string_literal: true

require 'spec_helper'
require 'open3'

# Regression guard for the lazy-load perf fix: requiring the gem must NOT pull
# in the network stack (net/http, openssl via Client/Signer) or terminal-table,
# but the deferred constants must still resolve on first reference from
# anywhere. Runs in a subprocess because the current process has already
# loaded everything.
RSpec.describe 'lazy loading of the network stack' do
  lib_dir = File.expand_path('../../lib', __dir__)

  def run_ruby(lib_dir, script)
    out, err, status = Open3.capture3(RbConfig.ruby, '-I', lib_dir, '-e', script)
    expect(status).to be_success, "subprocess failed: #{err}"
    out
  end

  it "does not load net/http or terminal-table when only requiring 'gamechanger'" do
    out = run_ruby(lib_dir, <<~RUBY)
      require 'gamechanger'
      net  = $LOADED_FEATURES.any? { |f| f.end_with?('net/http.rb') }
      tt   = $LOADED_FEATURES.any? { |f| f.include?('terminal-table') }
      puts "net/http=\#{net} terminal-table=\#{tt}"
    RUBY
    expect(out).to include('net/http=false terminal-table=false')
  end

  it 'resolves Client, Signer, and Formatters::Table via autoload on first reference' do
    out = run_ruby(lib_dir, <<~RUBY)
      require 'gamechanger'
      puts Gamechanger::Signer.generate_nonce.bytesize.positive?
      puts Gamechanger::Client.instance_method(:authenticate).name
      puts Gamechanger::Formatters::Table.instance_method(:season_summary).name
      puts $LOADED_FEATURES.any? { |f| f.end_with?('net/http.rb') }
    RUBY
    expect(out).to eq("true\nauthenticate\nseason_summary\ntrue\n")
  end
end
