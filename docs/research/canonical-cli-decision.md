# Canonical CLI Decision

Date: 2026-06-06

## Decision

Ruby is the canonical user-facing CLI for coach workflows today. Go is the future canonical target, but only after it passes explicit promotion gates centered on the action-first `brief` workflow.

This keeps the product honest: first-time coaches should be routed to the CLI that can deliver the full pre-game coaching brief now, while Go work remains focused on earning that surface rather than becoming a parallel product by drift.

## Current Surface

Ruby currently owns the coach-facing product surface:

- `demo`
- `brief`
- `pitches`
- `availability`
- `plan`
- `hitting`
- `fielding`
- `lineup`
- `equity`
- `progress`
- `refresh`
- `setup`
- `version`

Go currently owns or partially owns the migration/tooling surface:

- `auth`
- `refresh`
- `scout`
- `setup`
- `verify`
- `version`

## Promotion Gates

Go can become the canonical user-facing CLI only after these gates pass:

1. Go `demo` renders anonymized sample `brief` and `progress` output without credentials.
2. Go `brief` renders an action-first pre-game brief against the anchor fixture and a real refreshed cache.
3. `gamechanger verify brief` passes parity checks, or every difference is documented as an accepted product decision.
4. Go help text and README setup instructions make the Go install path clearly canonical.
5. A real game-day smoke test confirms Go can carry setup, refresh, and brief without falling back to Ruby.

## Transition Rules

While Ruby remains canonical:

- New coach-facing improvements land in Ruby unless they are explicitly scoped as Go parity work.
- Go UX mirrors Ruby command names, flags, and output concepts for migrated workflows unless a decision record says otherwise.
- Do not add divergent command names for the same coach job.
- Do not present Ruby and Go as equally canonical in onboarding docs.
- Do not remove or demote Ruby before Go passes `brief` parity.

## Non-Goals

- Do not build a thin Go wrapper that shells out to Ruby.
- Do not maintain two separate canonical README paths.
- Do not block Go-native features like `scout` while Ruby remains canonical.
- Do not require byte-for-byte output identity where a documented accepted difference is better for the product.

## Rationale

`brief` is now the product hero. A CLI that cannot produce the brief cannot be the canonical user-facing CLI, even if it can authenticate, refresh, or pass lower-level parity checks.

Ruby should continue to protect the current user experience. Go should become canonical by replacing the highest-value workflow first, not by accumulating adjacent infrastructure commands.

## Related

- `docs/solutions/tooling-decisions/canonical-cli-transition-gate.md`
- `docs/plans/2026-06-06-001-canonical-cli-transition-plan.md`
- `docs/ideation/2026-05-14-gamechanger-go-port-direction-ideation.md`
