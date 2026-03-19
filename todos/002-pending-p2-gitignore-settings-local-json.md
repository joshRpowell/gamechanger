---
status: complete
priority: p2
issue_id: "002"
tags: [code-review, security, git]
dependencies: []
---

# Gitignore and untrack .claude/settings.local.json

## Problem Statement

`.claude/settings.local.json` is a machine-local Claude Code artifact containing session-specific permission allowlists. It is committed to the repo and included in this PR. While no secrets are present today, committing it establishes a pattern that could accidentally expose sensitive allow-rules in future sessions. It also discloses local filesystem paths.

## Findings

- `.claude/settings.local.json` is in the PR diff
- File contains `joshuapowell` username in path references
- `settings.local.json` is explicitly "local" — it should never be committed
- Pattern risk: future sessions could accumulate sensitive shell rules in this file

## Proposed Solutions

**Option A: Gitignore and untrack (Recommended)**
```bash
echo ".claude/settings.local.json" >> .gitignore
git rm --cached .claude/settings.local.json
git commit -m "chore: gitignore .claude/settings.local.json (machine-local artifact)"
```
- Pros: Permanent fix; other contributors won't accidentally commit their own
- Effort: Small | Risk: None

**Option B: Leave it**
- Cons: Sets a bad precedent; discloses path structure

## Recommended Action

Option A.

## Technical Details

- File: `.claude/settings.local.json`
- Contains: Bash permission allowlist (bundle exec, git, rspec, etc.) — no secrets currently

## Acceptance Criteria

- [ ] `.claude/settings.local.json` is in `.gitignore`
- [ ] `git ls-files .claude/settings.local.json` returns empty
- [ ] File still functions locally (gitignore doesn't affect working copy)

## Work Log

- 2026-03-19 — Identified by security-sentinel agent during PR review
