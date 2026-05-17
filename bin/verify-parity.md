# bin/verify-parity

Thin pass-through wrapper for `gamechanger verify`. Runs Ruby (subprocess)
and Go (in-process) against the same fixture, then diffs the JSON outputs
through the parity engine.

## Usage

```sh
bin/verify-parity <command> [--fixture PATH] [--format human|json] [--strict]
```

### Examples

```sh
# Default fixture: internal/parity/testdata/cache-anchor.db
bin/verify-parity progress

# Verify against your local cache.db (must live under ~/.gamechanger/)
bin/verify-parity progress --fixture ~/.gamechanger/cache.db

# JSON output for an AI-loop driver
bin/verify-parity progress --format json

# Treat parity-unstable (threshold-proximate categorical drift) as drift
bin/verify-parity progress --strict
```

## Exit codes

| Code | Meaning                                                    |
|------|------------------------------------------------------------|
| 0    | parity-pass                                                |
| 10   | drift                                                      |
| 11   | parity-unstable (categorical near a known float threshold) |
| 20   | go-not-implemented (`<command>` not in allowlist)          |
| 21   | fixture-missing (path missing or outside allowed scope)    |
| 30   | ruby-unavailable (`bundle` not on PATH)                    |
| 31   | ruby-timeout (60s subprocess timeout fired)                |
| 32   | ruby-error (Ruby exited nonzero — engine NOT invoked)      |
| 33   | ruby-parse-error (Ruby stdout not valid JSON)              |
| 40   | go-parse-error (Go renderer produced invalid JSON)         |

## Fixture path rules

`--fixture` is resolved via `filepath.EvalSymlinks`. Only paths under
`internal/parity/testdata/` (cwd-relative) or `~/.gamechanger/` are accepted.
Symlinks pointing outside the allowed scopes are rejected before any SQLite
open is attempted. Error messages emit only the basename — never the full
resolved path — so AI-loop transcripts don't leak directory structure.

## Allowed commands

The verify subcommand maintains an explicit allowlist. As Go ports more
analytics commands, add entries to `verifyAllowedCommands` /
`goRunners` in `internal/commands/verify.go`.

Currently allowed: `progress`.
