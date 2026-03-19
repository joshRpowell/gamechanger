---
status: pending
priority: p3
issue_id: "009"
tags: [code-review, quality, tests]
dependencies: []
---

# Remove redundant `let(:rules)` shadow in markdown_spec.rb

## Problem Statement

`spec/gamechanger/formatters/markdown_spec.rb` defines `let(:rules) { Gamechanger::PitchRules.new }` at file scope (line 8) and then redefines the identical value inside `describe '#availability'` (line 51). The inner `let` shadows the outer with exactly the same value — it does nothing.

## Findings

- Line 8: `let(:rules) { Gamechanger::PitchRules.new }` (file scope)
- Line 51: `let(:rules) { Gamechanger::PitchRules.new }` (inside describe '#availability')
- The inner definition is a copy-paste artifact with zero effect

## Proposed Solutions

**Remove line 51:**
- Delete the duplicate `let(:rules)` inside `#availability`
- The file-scope `let` is inherited by all nested groups

Effort: Tiny | Risk: None

## Acceptance Criteria

- [ ] Only one `let(:rules)` in markdown_spec.rb (at file scope)
- [ ] Tests still pass

## Work Log

- 2026-03-19 — Identified by code-simplicity-reviewer during PR review
