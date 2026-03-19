---
status: complete
priority: p1
issue_id: "003"
tags: [code-review, agent-native, cli, architecture]
dependencies: []
---

# Route error messages to stderr, not stdout

## Problem Statement

All error messages, warnings, and banners in `lib/gamechanger/cli.rb` use Thor's `say` which writes to **stdout**. This means when an agent runs `gamechanger pitches --format json`, any error path mixes human-prose onto the same stream as the JSON payload — making the output unparseable.

This is an existing bug exposed by the agent-native review; not introduced by this PR.

## Findings

- `say` in Thor writes to stdout (`stdout.print(buffer)`)
- All rescue blocks (lines 115–130, 148–162, etc.) use `say` for error messages
- Only the progress banner at line 101 has a tty guard
- An agent piping `gamechanger pitches --format json | jq .` will get a JSON parse error if any error fires

## Proposed Solutions

**Option A: Replace `say` with `say_error` in error paths (Recommended)**

Thor's `say_error` writes to stderr. Replace in all rescue/error blocks:
```ruby
# Before
say "Error: couldn't connect to API"

# After
say_error "Error: couldn't connect to API"
```
- Pros: Minimal change; stdout stays clean for structured data
- Effort: Small | Risk: Low

**Option B: Check `options[:format]` and emit JSON error objects**

When `--format json`, emit `{ "error": "...", "code": N }` to stdout and nothing else. More agent-friendly but more work.
- Effort: Medium | Risk: Low

## Recommended Action

Option A as immediate fix; Option B as enhancement (todo 007).

## Technical Details

- File: `lib/gamechanger/cli.rb`
- Affected: All `say` calls in rescue blocks throughout the file
- Thor docs: `say_error(message, color = nil, force_new_line = true)` — writes to `$stderr`

## Acceptance Criteria

- [ ] All error/warning messages in rescue blocks use `say_error`
- [ ] `gamechanger pitches --format json 2>/dev/null` outputs valid JSON even on error paths
- [ ] `gamechanger pitches --format json 2>&1 | jq .` shows the error in a structured way

## Work Log

- 2026-03-19 — Identified by agent-native-reviewer during PR review
