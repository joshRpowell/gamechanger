# frozen_string_literal: true

require_relative 'lib/gamechanger/version'

Gem::Specification.new do |spec|
  spec.name    = 'gamechanger'
  spec.version = Gamechanger::VERSION
  spec.authors = ['Joshua Powell']
  spec.email   = ['joshua@joshuapowell.com']

  spec.summary     = 'Pre-game coaching analytics suite for youth baseball coaches'
  spec.description = 'Command-line tool for youth baseball coaches that connects to Gamechanger and delivers a complete pre-game brief: pitcher availability, batting lineup, equity flags, and player development arcs — all in one command.'
  spec.homepage    = 'https://github.com/joshuapowell/gamechanger'
  spec.license     = 'MIT'
  spec.required_ruby_version = '>= 3.2.0'

  spec.metadata['homepage_uri']    = spec.homepage
  spec.metadata['changelog_uri']   = 'https://github.com/joshuapowell/gamechanger/blob/main/CHANGELOG.md'
  spec.metadata['rubygems_mfa_required'] = 'true'

  spec.files = Dir.chdir(__dir__) do
    `git ls-files -z`.split("\x0").reject do |f|
      (File.expand_path(f) == __FILE__) ||
        f.start_with?(*%w[bin/ test/ spec/ features/ .git .github appveyor Gemfile])
    end
  end
  spec.bindir      = 'exe'
  spec.executables = ['gamechanger']
  spec.require_paths = ['lib']

  spec.add_dependency 'sqlite3',        '~> 1.7'
  spec.add_dependency 'terminal-table', '~> 3.0'
  spec.add_dependency 'thor',           '~> 1.3'
end
