# frozen_string_literal: true

require_relative 'lib/gamechanger/version'

Gem::Specification.new do |spec|
  spec.name    = 'gamechanger'
  spec.version = Gamechanger::VERSION
  spec.authors = ['Joshua Powell']
  spec.email   = ['joshua@joshuapowell.com']

  spec.summary     = 'CLI for tracking pitcher workload from Gamechanger'
  spec.description = 'Fetches pitch count data from the Gamechanger baseball app and presents season workload analysis from the command line'
  spec.homepage    = 'https://github.com/joshuapowell/gamechanger'
  spec.license     = 'MIT'
  spec.required_ruby_version = '>= 3.2.0'

  spec.metadata['homepage_uri']        = spec.homepage
  spec.metadata['source_code_uri']     = spec.homepage
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
