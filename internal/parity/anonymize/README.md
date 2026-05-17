# `internal/parity/anonymize/`

U3 of the verify-parity harness. Generates a privacy-preserving SQLite fixture from a real `~/.gamechanger/cache.db` so the test corpus can be committed to a public repo without leaking youth-baseball PII.

## Usage

```bash
go run ./cmd/anonymize-fixture \
  --source ~/.gamechanger/cache.db \
  --out internal/parity/testdata/cache-anchor.db
```

The substitution map (real-name → synthetic-name audit trail) is written to `~/.gamechanger/parity-substitution-<hash>.yml` and **must never be committed**. The fixture and the map together would allow re-identification.

## Threat model

### In-scope adversary

An anonymous reader of the public GitHub repo, with optional access to public youth-baseball stats sites (GameChanger team pages, USSSA / PerfectGame results).

### Out-of-scope

- An adversary with access to the substitution map file (the map is local and not committed; a leaked map breaks anonymization entirely).
- An adversary with insider knowledge of the team (parents, coaches, league registrars).
- Side-channel attacks on the commit history of the fixture file.

### Defended properties

1. **No real player name** appears in the committed fixture (`games.opponent`, `game_pitcher_stats.pitcher_name`, `game_batter_stats.batter_name`).
2. **No game `(date, opponent, stat-line)` combination** is linkable to a single public game record with greater than ~5% confidence. The combination of date-shift + opponent substitution + stat perturbation breaks naive joins against public sources.
3. **Same source + same seed → byte-identical fixture** (R9 determinism). Different seeds produce different mappings — so two regenerations of the same source DB are unlinkable to each other (cross-version unlinkability, < 5% synthetic-name overlap in tests).

### Anonymization techniques

| What | How | Why |
|---|---|---|
| Player names | Substituted from a static synthetic pool (50 entries), assigned via seeded Fisher-Yates shuffle | Removes the strongest direct identifier |
| Opponent team names | Substituted from a synthetic team-name pool (32 entries) | Real opponent + date is the fingerprint join key against public sources |
| Game dates | Shifted by an independent random 0-365 day offset per game | **Day-of-week is NOT preserved** (eng review SEC-ANON-01) — preserving weekday left the fixture linkable to public Saturday-tournament schedules |
| Game IDs | Replaced with synthetic IDs of the form `anon-NNNN-XXXXXXXX` | Source UUIDs link to GameChanger backend records |
| Per-game stats | Perturbed by ±3 in each of `pitches_thrown`, `strikes_thrown`, `at_bats`, `hits`, `walks`, `strikeouts`, with baseball constraints enforced (AB ≥ H, AB ≥ K, pitches ≥ strikes, all non-negative) | Eng review SEC-ANON-02 — ±1 was too tight; ±3 breaks fingerprint-match against public box scores |
| `fetched_at` / `first_seen_at` | Zeroed to a fixed value (`2026-01-01T00:00:00Z`) | Real timestamps narrow the data window |

### Substitution-map lifecycle

- The map filename is derived from the seed: `parity-substitution-<sha256(seed)[:12]>.yml`. Different seeds produce different filenames so concurrent regenerations don't clobber each other.
- The map file mode is **`0o600`** (user-only). Anyone with read access to the map can de-anonymize the fixture.
- The map directory defaults to `~/.gamechanger/` (outside the repo, so the file CANNOT be accidentally committed via `git add`). A future pre-commit hook (deferred — see TODOS `GO-9`) will enforce that any `parity-substitution-*.yml` is rejected regardless of location.
- Each `Run()` generates a fresh seed (unless one is supplied for tests). This guarantees that regenerating the fixture against an updated source DB produces a new mapping — cross-version linkage attacks cannot use a stable map.

## Falsification test (manual)

Before treating a fixture as fit for public commit, run the falsification check at least once:

1. Generate the fixture: `go run ./cmd/anonymize-fixture --source ~/.gamechanger/cache.db --out /tmp/test-anchor.db`
2. Hand `/tmp/test-anchor.db` (and ONLY the fixture, never the map) to a fresh AI agent or a knowledgeable third party.
3. Give them access to public youth-baseball stats sites (GameChanger team pages, USSSA, PerfectGame).
4. Ask: "Can you identify any real player on this team with greater than 5% confidence?"

If the answer is **yes**, the anonymization is insufficient. Increase the perturbation magnitude, broaden the name-pool, drop additional fingerprintable columns (`status`, `home_away`), or switch to fully synthetic data generated from a distribution model rather than perturbed real data.

If the answer is **no**, record the result and date in the test plan; the falsification test passes for this source snapshot.

## Failure modes & typed errors

| Sentinel | Cause | CLI exit code | Recovery |
|---|---|---|---|
| `ErrSourceMissing` | `--source` path does not exist | 2 | Run `gamechanger refresh` to populate cache, or pass a correct `--source` |
| `ErrSourceCorrupt` | Source file is not a valid SQLite database (truncated, garbage bytes, etc.) | 3 | Re-run `gamechanger refresh`; if persistent, the cache is damaged |
| `ErrSourceSchema` | `games` table missing or required columns absent | 4 | The source is from a different Ruby gem version; re-run `gamechanger refresh` to bring it to current schema |

## What this package is NOT

- Not a general-purpose anonymizer; the schema knowledge is gamechanger-specific.
- Not GDPR / HIPAA compliance — see your legal counsel if the data crosses into those regimes.
- Not a defense against an adversary with the substitution map. Keep the map local. If it leaks, regenerate the fixture from the source with a fresh seed and rotate the committed fixture.
