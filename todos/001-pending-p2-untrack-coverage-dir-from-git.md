---
status: complete
priority: p2
issue_id: "001"
tags: [code-review, security, git]
dependencies: []
---

# Untrack coverage/ directory from git

## Problem Statement

The `coverage/` directory was committed before the `.gitignore` entry was added (commit `1fd61e5`). Adding a path to `.gitignore` does not untrack already-committed files. As a result, 42 coverage output files (HTML, JSON, images, JS, CSS) are tracked in git despite the intent to ignore them.

`coverage/.resultset.json` contains absolute filesystem paths disclosing the developer's username and directory structure:
```
"/Users/joshuapowell/gems/gamechanger/lib/gamechanger/config.rb"
```

## Findings

- All `coverage/` files are tracked despite `.gitignore` listing them
- `coverage/.resultset.json` discloses local username (`joshuapowell`) and path structure
- 42 unnecessary binary/generated files bloat the repo

## Proposed Solutions

**Option A: Remove and commit (Recommended)**
```bash
git rm -r --cached coverage/
git commit -m "chore: untrack coverage/ output (already in .gitignore)"
```
- Pros: Clean, permanent fix; coverage/ re-generates locally on next run
- Cons: None
- Effort: Small | Risk: None

**Option B: Squash/rebase the offending commits**
- Pros: Cleaner git history
- Cons: Destructive rewrite of already-pushed branch; not worth it for a dev artifact
- Effort: Medium | Risk: Medium

## Recommended Action

Option A — run `git rm -r --cached coverage/` before merge.

## Technical Details

- Affected files: `coverage/` (all 42 files)
- Root cause: SimpleCov was added in commit `1fd61e5` before `.gitignore` was updated in `f8dd3f3`

## Acceptance Criteria

- [ ] `git ls-files coverage/` returns empty
- [ ] `coverage/` is in `.gitignore`
- [ ] Coverage still generates locally with `COVERAGE=1 bundle exec rspec`

## Work Log

- 2026-03-19 — Identified by security-sentinel agent during PR review
