---
status: complete
priority: p2
issue_id: "006"
tags: [code-review, quality, tests]
dependencies: []
---

# Clean up cargo-cult bootsnap config in spec_helper.rb

## Problem Statement

`spec/spec_helper.rb` has two cargo-culted bootsnap options copied from a Rails app template that are irrelevant (and potentially misleading) in a Ruby gem context.

## Findings

**Line 6:** `ignore_directories: ['node_modules']`
- This gem has no `node_modules`. This option exists for Rails/webpacker apps.
- Confuses future readers about what tools are in use.

**Line 7:** `development_mode: true`
- `development_mode: true` disables some Bootsnap optimizations (skips compilation cache for some Ruby versions in dev mode).
- Should be `false` or omitted (Bootsnap auto-detects based on `$LOAD_PATH` changes).
- Cargo-culted from Rails app template.

## Proposed Solutions

**Remove both options:**
```ruby
# Before
Bootsnap.setup(
  cache_dir: "#{__dir__}/../tmp/bootsnap",
  ignore_directories: ['node_modules'],
  development_mode: true,
  load_path_cache: true,
  compile_cache: true
)

# After
Bootsnap.setup(
  cache_dir: "#{__dir__}/../tmp/bootsnap",
  load_path_cache: true,
  compile_cache: true
)
```
- Effort: Small | Risk: None

## Acceptance Criteria

- [ ] `ignore_directories: ['node_modules']` removed from spec_helper.rb
- [ ] `development_mode` either removed or set to `ENV['CI'].nil?` if there's a reason to keep it
- [ ] Tests still pass after change

## Work Log

- 2026-03-19 — Identified by code-simplicity-reviewer during PR review
