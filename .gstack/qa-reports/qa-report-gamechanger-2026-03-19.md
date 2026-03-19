# QA Report: gamechanger CLI gem
**Date:** 2026-03-19
**Branch:** main
**Mode:** CLI/library QA (no web interface)
**Test Framework:** RSpec — 258 examples
**Duration:** ~15 minutes

---

## Summary

| Category | Score |
|----------|-------|
| Test Suite Health | 100 |
| Build Health | 100 |
| CLI Correctness | 100 |
| Formatter Parity | 100 |
| **Overall** | **100** |

**3 issues found. 3 fixed. Health: 60 → 100.**

---

## Issues Found & Fixed

### ISSUE-001 — Critical — Flaky test suite (SystemExit escapes RSpec)
**Status:** verified ✅ | **Commit:** fix(qa): ISSUE-001
**Symptom:** Running `bundle exec rspec` without arguments produced wildly inconsistent example counts (7–257) across runs depending on random seed — some runs exited after only 7 examples.
**Root cause:** In `spec/gamechanger/cli_setup_spec.rb:80`, the pattern `expect { ... rescue nil }` uses Ruby's postfix-rescue which only catches `StandardError` and subclasses. `SystemExit` inherits from `Exception`, not `StandardError`, so it escaped the block and killed the RSpec process mid-run. Any seed that placed this test early in the randomized order would terminate the suite prematurely.
**Fix:** Changed `rescue nil` to an explicit `begin/rescue SystemExit` inside the block. Also added `--pattern "spec/**/*_spec.rb"` to `.rspec` for deterministic file discovery.
**Before:** Example count varied 7–257 per run. **After:** 258 examples on every seed tested.
**Files changed:** `spec/gamechanger/cli_setup_spec.rb`, `.rspec`

### ISSUE-002 — High — `PitchRules#available_date` crashes when `last_outing` is nil
**Status:** verified ✅ | **Commit:** fix(qa): ISSUE-002
**Symptom:** Calling the `availability` formatter with a pitcher who has never pitched (nil `last_outing`) raises `Date::Error: invalid date`.
**Root cause:** `available_on?` correctly short-circuits to `true` when `last_outing_date` is nil, but both `Formatters::Table#availability` and `Formatters::Markdown#availability` call `available_date` unconditionally before checking availability — so when `last_outing` is nil, `Date.parse(nil.to_s)` → `Date.parse("")` → `Date::Error`.
**Fix:** Added `return Date.today if last_outing_date.nil?` guard to `PitchRules#available_date`. A pitcher who has never pitched is always available starting today.
**Files changed:** `lib/gamechanger/pitch_rules.rb`, `spec/gamechanger/pitch_rules_spec.rb` (regression test added)

### ISSUE-003 — Medium — Gemspec duplicate URI build warning
**Status:** verified ✅ | **Commit:** fix(qa): ISSUE-003
**Symptom:** `gem build` warns "You have specified the uri ... for all of the following keys: homepage_uri, source_code_uri". RubyGems.org only shows the first.
**Root cause:** Both `homepage_uri` and `source_code_uri` were set to `spec.homepage` (same URL).
**Fix:** Removed redundant `source_code_uri`. Added `changelog_uri` pointing to CHANGELOG.md instead, which is a distinct and useful RubyGems metadata entry.
**Files changed:** `gamechanger.gemspec`

---

## Test Coverage Against Test Plan

| Test Plan Item | Coverage | Notes |
|----------------|----------|-------|
| `setup` single-team success | ✅ covered | cli_setup_spec.rb |
| `setup` auth failure → exit 2 | ✅ covered | cli_setup_spec.rb |
| `setup` multiple teams → prompt | ✅ covered | cli_setup_spec.rb |
| `pitches` season summary table | ✅ covered | cli_spec.rb + seeded storage |
| `pitches --pitcher` ambiguous match | ✅ passes | Storage returns String array |
| `brief --date` all 4 sections | ✅ passes | Manual verification |
| `plan --games` no eligible pitcher | ✅ passes | Manual verification |
| `availability` nil last_outing | ✅ fixed (ISSUE-002) | was crashing |
| `hitting` batting table | ✅ covered | cli_spec.rb |
| `refresh` count reporting | ✅ covered | cli_spec.rb |
| All 3 format outputs (table/json/markdown) | ✅ passes | Manual verification |

---

## Top 3 Fixes

1. **ISSUE-001** — Flaky test suite from `rescue nil` not catching `SystemExit`. This was silently hiding a broken test isolation that could mask regressions.
2. **ISSUE-002** — Crash in availability formatter for first-time pitchers with no game history. This is a real user-facing crash that would occur when a new player is added to the roster.
3. **ISSUE-003** — Gemspec build warning. Minor but affects gem discoverability on RubyGems.org.

---

## Final State

- **258 examples, 0 failures** — consistent across all seeds tested
- **`gem build` clean** — no warnings
- **All 3 formatters exercised** — table, json, markdown all produce valid output
- **Nil last_outing edge case** — handled gracefully, pitcher shown as available
