---
title: Canonical CLI Transition Plan
status: active
date: "2026-06-06"
origin: docs/research/canonical-cli-decision.md
owner: unassigned
---

# Canonical CLI Transition Plan

## Problem Frame

GameChanger has two CLI implementations. Ruby is the complete coach-facing product today; Go is the future target but does not yet carry the full first-run and game-day experience.

The plan is to make that state explicit, then move Go through promotion gates until it can replace Ruby for the product hero: an action-first pre-game `brief`.

## Scope

In scope:

- Document Ruby as canonical today and Go as the migration target.
- Align onboarding, README, and help language around a single user-facing path.
- Add Go parity gates for `demo` and `brief`.
- Promote Go only after product-surface parity is proven or accepted differences are documented.

Out of scope:

- Full Ruby removal.
- A Go wrapper that shells out to Ruby.
- Redesigning the analytics model outside what `brief` parity requires.

## Decisions

- Ruby remains canonical until Go passes `brief` parity.
- `brief` is the promotion gate because it is the highest-value user-facing workflow.
- Go-native workflows like `scout`, `auth`, and `verify` can continue in Go while Ruby owns coach reports.
- Parity can allow documented accepted differences, but undocumented drift blocks promotion.

## Implementation Units

### U1: Decision Artifact And README Alignment

Files:

- `docs/research/canonical-cli-decision.md`
- `docs/solutions/tooling-decisions/canonical-cli-transition-gate.md`
- `README.md`

Work:

- Add the decision record and compounded learning.
- Update README language so first-time coaches are routed to Ruby as the current canonical CLI.
- Keep Go positioned as the migration target and developer/parity surface until promotion gates pass.

Tests and checks:

- Review README command examples for ambiguous Ruby/Go entry points.
- Smoke `bundle exec exe/gamechanger help`.
- Smoke `go run ./cmd/gamechanger --help`.

Acceptance:

- A first-time reader can tell which CLI to install/use today.
- The repo has a durable explanation for why Go is not yet canonical.

### U2: Define Brief Parity Harness Contract

Files:

- `internal/commands/verify.go`
- `internal/commands/verify_test.go`
- `internal/parity/testdata/cache-anchor.db`
- `docs/research/canonical-cli-decision.md`

Work:

- Extend the parity contract to recognize `brief` as a promotion gate.
- Decide whether the first implementation is an expected-fail gate, an allowlisted missing gate, or a real comparison once Go `brief` exists.
- Make accepted differences explicit so parity failures do not become vague judgment calls.

Tests and checks:

- `go test ./internal/commands/... ./internal/parity/...`
- A failing or pending `brief` parity gate must explain what is missing.

Acceptance:

- `brief` parity is represented in the harness or documented as the next gate to add.
- The promotion blocker is visible to contributors before Go is treated as canonical.

### U3: Port First-Run Demo To Go

Files:

- `internal/commands/demo.go`
- `internal/commands/demo_test.go`
- `internal/parity/testdata/cache-anchor.db`
- `cmd/gamechanger/main.go`
- `README.md`

Work:

- Add Go `demo` with anonymized sample output and no credential requirement.
- Use the anchor fixture as the source of truth.
- Match Ruby's `demo --report brief` and `demo --report progress` product shape.

Tests and checks:

- `go test ./internal/commands/...`
- `go run ./cmd/gamechanger demo --format markdown`
- `go run ./cmd/gamechanger demo --report progress`

Acceptance:

- A first-time user can see Go sample output without setup.
- Go `demo` is close enough to Ruby `demo` that onboarding can compare them honestly.

### U4: Port Action-First Brief To Go

Files:

- `internal/commands/brief.go`
- `internal/commands/brief_test.go`
- `internal/analytics/`
- `internal/format/`
- `internal/parity/`

Work:

- Add Go `brief` command.
- Preserve the action plan first: pitching, lineup, equity, and development.
- Reuse existing Go analytics where possible and only port Ruby logic needed for the brief.
- Feed the output through the parity harness.

Tests and checks:

- `go test ./internal/commands/... ./internal/analytics/... ./internal/format/... ./internal/parity/...`
- `go run ./cmd/gamechanger brief`
- `gamechanger verify brief` or the equivalent local parity command once wired.

Acceptance:

- Go renders an action-first pre-game brief from the anchor fixture.
- Go renders a real-cache brief in a game-day smoke without Ruby fallback.
- Differences from Ruby are either eliminated or recorded as accepted differences.

### U5: Promotion Review And README Flip

Files:

- `README.md`
- `docs/research/canonical-cli-decision.md`
- `CHANGELOG.md`

Work:

- Review whether all promotion gates passed.
- Flip README canonical install/setup path from Ruby to Go only after the gates are satisfied.
- Update the decision record with the promotion date and remaining Ruby support policy.

Tests and checks:

- `go run ./cmd/gamechanger demo`
- `go run ./cmd/gamechanger brief`
- `go run ./cmd/gamechanger refresh`
- One real game-day smoke test covering setup, refresh, and brief.

Acceptance:

- Go is the single documented user-facing CLI.
- Ruby is clearly marked as legacy, maintenance, or removed according to the follow-up decision.

## Risks

- Go passes fixture tests but produces weaker coaching output for real games.
- The anchor fixture does not exercise enough pitcher availability, batting sample size, or equity edge cases.
- README flips too early and first-time users hit a partial product.
- Ruby keeps receiving unrelated product improvements after Go parity work begins, moving the target.

## Success Criteria

- The repo has one clear canonical user-facing CLI at every point in the transition.
- Go has a visible promotion path instead of an open-ended porting effort.
- First-run demo and action-first brief are treated as product gates, not nice-to-have reports.
- Documentation, help text, and parity checks all agree before canonical status changes.
