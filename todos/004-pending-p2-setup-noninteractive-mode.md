---
status: complete
priority: p2
issue_id: "004"
tags: [code-review, agent-native, cli]
dependencies: []
---

# Add non-interactive mode to `setup` command

## Problem Statement

`gamechanger setup` uses interactive `ask` prompts for email, password, and team slug with no way to pass credentials non-interactively. Agents and CI pipelines cannot run setup without a TTY.

## Findings

- `lib/gamechanger/cli.rb` setup command calls `ask` for all three credentials
- No CLI options exist to pass credentials as arguments
- An agent given fresh credentials cannot bootstrap the tool

## Proposed Solutions

**Option A: Add --email, --password, --team-slug options (Recommended)**
```ruby
desc "setup", "Configure gamechanger credentials"
option :email, type: :string, desc: "Account email"
option :password, type: :string, desc: "Account password"
option :"team-slug", type: :string, desc: "Team identifier"
def setup
  email = options[:email] || ask("Email:")
  password = options[:password] || ask("Password:", echo: false)
  team_slug = options[:"team-slug"] || ask("Team slug:")
  ...
end
```
- Pros: Backwards compatible; interactive still works; agents can pass flags
- Effort: Small | Risk: Low

**Option B: Read from environment variables**
`GAMECHANGER_EMAIL`, `GAMECHANGER_PASSWORD`, `GAMECHANGER_TEAM_SLUG`
- Pros: No secrets in shell history
- Effort: Small | Risk: Low

## Recommended Action

Option A (CLI flags) with Option B (env vars) as fallback chain: flags → env vars → interactive prompt.

## Technical Details

- File: `lib/gamechanger/cli.rb` setup command (~lines 16–87)

## Acceptance Criteria

- [ ] `gamechanger setup --email x --password y --team-slug z` works without a TTY
- [ ] Interactive mode still works when options are omitted
- [ ] Existing tests still pass

## Work Log

- 2026-03-19 — Identified by agent-native-reviewer during PR review
