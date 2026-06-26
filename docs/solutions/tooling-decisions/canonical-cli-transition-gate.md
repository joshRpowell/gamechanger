---
title: Ruby stays canonical until Go earns brief parity
date: "2026-06-06"
category: docs/solutions/tooling-decisions
module: cli-migration
problem_type: tooling_decision
component: tooling
severity: medium
applies_when:
  - deciding canonical CLI during a Ruby-to-Go migration
  - preventing a dual-stack CLI from becoming hybrid forever
  - choosing where new coach-facing work should land
tags: [ruby, go, cli, migration, parity, brief]
---

# Ruby stays canonical until Go earns brief parity

## Context

GameChanger currently has two CLI surfaces. The Ruby CLI contains the full coach-facing product: setup, refresh, brief, reports, and the first-run demo path. The Go CLI is the intended future direction, but its current surface is narrower: setup/auth/refresh/scout/verify/version.

The product risk is not that both implementations exist. The risk is letting both become canonical in different ways, where documentation, user trust, and implementation effort split across two incomplete products.

## Guidance

Keep Ruby canonical for user-facing coaching workflows until Go passes product-surface parity gates. Treat Go as the migration target, not as the default user-facing interface, until it can carry the game-day workflow without sending users back to Ruby.

The promotion gate should be `brief`, because `brief` is the product hero. A future Go CLI is not meaningfully canonical just because it can refresh data or verify parity fixtures. It becomes canonical when it can produce the same action-first pre-game coaching output that a first-time user is being sold.

Use this rule while the transition is active:

| Area | Canonical Today | Future Target | Gate |
| --- | --- | --- | --- |
| Game-day brief | Ruby | Go | Go `brief` parity |
| First-run demo | Ruby | Go | Go `demo` parity |
| Auth/session import | Ruby/Go split | Go | Stable token flow and documented setup |
| Scout workflow | Go | Go | Already Go-native |
| Analytics reference | Ruby | Go | `verify` parity pass or accepted differences |

New coach-facing improvements should land in Ruby unless they are Go-native already (`scout`, `verify`, auth plumbing) or explicitly part of a Go parity implementation unit.

## Why This Matters

A CLI product earns trust at the first command. If the docs point users to Go before Go can render the real coaching brief, first-run users will hit a weaker product than the one the repo is trying to build.

The opposite mistake is also expensive: continuing to add divergent Ruby and Go features without a promotion gate turns the migration into a permanent dual-stack product. The transition needs one canonical user surface now, one target surface later, and a visible gate between them.

## When to Apply

- During Ruby-to-Go migration planning.
- When deciding where a new user-facing CLI feature should land.
- When editing README setup instructions or command tables.
- When adding parity tests that decide whether Go can replace Ruby for a workflow.

## Examples

Before:

```text
README presents both Ruby and Go commands as equivalent entry points.
New `brief` UX improvements land in Ruby.
Go gets unrelated command names and partial report behavior.
No one can say which CLI a first-time coach should install.
```

After:

```text
README says Ruby is canonical today.
Go is documented as the migration target.
Go promotion requires demo + action-first brief + parity/accepted-diff checks.
New coach-facing work either lands in Ruby or is explicitly scoped as Go parity work.
```

## Related

- `docs/research/canonical-cli-decision.md`
- `docs/plans/2026-06-06-001-canonical-cli-transition-plan.md`
- `docs/ideation/2026-05-14-gamechanger-go-port-direction-ideation.md`
