---
status: complete
priority: p3
issue_id: "007"
tags: [code-review, quality, tests]
dependencies: []
---

# Consolidate scattered describe groups in cli_spec.rb

## Problem Statement

`spec/gamechanger/cli_spec.rb` (974 lines) has multiple separate `describe` blocks for the same CLI commands scattered throughout the file. A reader cannot see all behavior for a given command in one place.

## Findings

Commands with fragmented describe groups:
- `#availability` — appears at lines 15, 325, 700, 730
- `#hitting` — appears at lines 104, 314
- `#brief` — appears at lines 197, 336
- `#plan` — appears at lines 48, 347, 871, 928
- `#pitches` — appears in multiple sections

The group at line 730 is named `describe '#availability StorageError (with plan rescue)'` but tests `plan` and `brief` — the name is actively misleading.

## Proposed Solutions

**Consolidate into one describe per command with context blocks:**
```ruby
describe '#availability' do
  context 'error paths' do ... end
  context 'happy path' do ... end
  context 'StorageError' do ... end
end
```

This is standard RSpec organization. The current scattered structure grew incrementally — consolidating it is a refactor, not a behavior change.

Estimated reduction: ~30 lines of describe headers/comment banners; more importantly, makes the 974-line file navigable.

## Acceptance Criteria

- [ ] Each CLI command has exactly one `describe` block with context sub-groups
- [ ] The misleading `'#availability StorageError (with plan rescue)'` group is renamed/merged
- [ ] All tests still pass (zero behavior change)

## Work Log

- 2026-03-19 — Identified by code-simplicity-reviewer during PR review
