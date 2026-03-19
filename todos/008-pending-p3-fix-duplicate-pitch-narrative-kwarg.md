---
status: complete
priority: p3
issue_id: "008"
tags: [code-review, quality, tests, bug]
dependencies: []
---

# Fix duplicate `pitch_narrative` keyword argument in table_spec.rb

## Problem Statement

`spec/gamechanger/formatters/table_spec.rb` lines 659–660 have a duplicate keyword argument in a `PlayerArc.new` call. Ruby silently uses the last value; the first is dead code.

## Findings

```ruby
# table_spec.rb ~line 659
PlayerArc.new(
  ...,
  pitch_narrative: 'Improving',  # DEAD — shadowed by next line
  pitch_narrative: 'Good',       # This one wins
  ...
)
```

This is a latent bug: the test author intended to set `pitch_narrative: 'Improving'` but the actual value used is `'Good'`. The test may be passing for the wrong reason.

## Proposed Solutions

**Remove the duplicate:**
- Determine which value was intended (`'Improving'` or `'Good'`)
- Remove the other occurrence
- Verify the test still tests what it claims to test

Effort: Small | Risk: Low

## Acceptance Criteria

- [ ] Only one `pitch_narrative:` kwarg in the affected `PlayerArc.new` call
- [ ] Test still passes and is testing the correct value

## Work Log

- 2026-03-19 — Identified by code-simplicity-reviewer during PR review
