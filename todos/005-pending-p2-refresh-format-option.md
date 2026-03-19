---
status: pending
priority: p2
issue_id: "005"
tags: [code-review, agent-native, cli]
dependencies: []
---

# Add `--format` option to `refresh` command

## Problem Statement

`gamechanger refresh` outputs a human-readable sentence like `"3 games, 8 outings, 45 at-bats updated."` with no machine-readable alternative. Every other data-producing command accepts `--format json`. An agent orchestrating a sync-then-query workflow cannot programmatically confirm what was synced.

## Findings

- `lib/gamechanger/cli.rb` refresh command outputs: `"X games, Y outings, Z at-bats updated."`
- No `--format` option on the refresh command
- All other data commands have `class_option :format`

## Proposed Solutions

**Option A: Add format option with JSON output (Recommended)**
```ruby
option :format, type: :string, default: "human"
def refresh
  ...
  if options[:format] == "json"
    puts JSON.pretty_generate({ games: games, outings: outings, at_bats: at_bats })
  else
    say "#{games} games, #{outings} outings, #{at_bats} at-bats updated."
  end
end
```
- Effort: Small | Risk: Low

## Technical Details

- File: `lib/gamechanger/cli.rb` refresh command (~lines 135–165)

## Acceptance Criteria

- [ ] `gamechanger refresh --format json` outputs parseable JSON with game/outing/at_bat counts
- [ ] `gamechanger refresh` (no flag) still outputs human-readable string
- [ ] Test coverage for both paths

## Work Log

- 2026-03-19 — Identified by agent-native-reviewer during PR review
