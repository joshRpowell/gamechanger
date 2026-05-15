# `internal/parity/testdata/`

U4 of the verify-parity harness. Contains the committed anchor fixture for `internal/parity/...` tests and the verify subcommand (U6).

## Files

| File | Purpose |
|---|---|
| `cache-anchor.db` | Anonymized SQLite snapshot of the developer's `~/.gamechanger/cache.db`. Read by `parity.Open` in read-only immutable mode. Never modify in place. |

## Current anchor

| Property | Value |
|---|---|
| Generated | 2026-05-15 |
| Source database fingerprint (sha256) | `6057b27412d7911a361b399a3adc4c5b092f77266debf417cccff93f4b6d8ca4` |
| Source size | 100 KB |
| Anchor size | 48 KB |
| Anchor sha256 | `3d8ebcf29b0086b0643cf9b7040944dd99d28310dc0b8d7f8f60d61aaa6493b0` |
| Games | 18 total (17 final, 1 scheduled) |
| Distinct players | 12 |
| Substitution map (local-only) | `~/.gamechanger/parity-substitution-1cefaf8ef5a5.yml` |

The substitution map is gitignored by location (`~/.gamechanger/` is outside the repo). The seed is recorded inside the map file; it is **not** documented in this README because the seed + source DB are jointly de-anonymizing (see `../anonymize/README.md` threat model).

## How to regenerate

```bash
go run ./cmd/anonymize-fixture \
  --source ~/.gamechanger/cache.db \
  --out internal/parity/testdata/cache-anchor.db \
  --map-dir ~/.gamechanger
```

This produces a **new** anchor with a fresh seed and a new substitution map. The new anchor's content and synthetic names will differ from the prior anchor — that's the cross-version unlinkability property (R9) at work. Update this README's metadata table after regenerating.

### When to regenerate

- Ruby `Storage` schema migration adds or renames a column the analytics modules read. The current anchor's schema lags; `go test ./internal/parity/...` will fail with `no such column` or similar.
- The harness reports `parity-pass` on a fixture but `drift` on the real cache, suggesting the anchor no longer represents the realistic data distribution.
- More than ~6 months have passed and the source DB has substantially grown (the anchor is a static slice; long-tail edge cases drift in).

See TODOS `GO-8` for the deferred cadence policy.

## How NOT to use this directory

- **Do not** modify `cache-anchor.db` in place. The fixture is immutable; modifications break test reproducibility.
- **Do not** commit any `*-wal` or `*-shm` sidecar files. `parity.Open` opens with `mode=ro&immutable=1` to prevent sidecar creation; if you see one, your test was probably opened with a different DSN — fix the call, then delete the sidecar.
- **Do not** copy the substitution map into the repo. The map is the de-anonymization key and stays local.

## Threat model

See `../anonymize/README.md` for the full threat model. Short version:
- An anonymous reader of the public repo cannot identify any real player on the team with greater than ~5% confidence from the anchor alone.
- An adversary with the substitution map can de-anonymize completely. Keep the map local.

If a falsification test (`../anonymize/README.md#falsification-test-manual`) on a new anchor fails, do not commit it; switch to a fully synthetic source.
