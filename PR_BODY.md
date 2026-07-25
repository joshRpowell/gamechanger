# perf: hoist and memoize `Date.parse` on pitcher-availability hot paths

## Problem

`Date.parse` is Ruby's heuristic date parser — the most expensive way to turn a
known-format `YYYY-MM-DD` string into a `Date`. Two independent perf audits
converged on the same finding: it was being re-run on loop-invariant or
already-parsed strings across the gem's only pure-CPU hot paths.

1. **`TournamentPlanner#can_pitch?`** (`lib/gamechanger/tournament_planner.rb:143`)
   is the innermost predicate of the forward simulation and ran
   `Date.parse(game_date)` on every call — but `game_date` is constant for the
   whole game iteration. It is called once per pitcher from
   `eligible_pitchers`'s `select`, and again for each of the two `pick_pitcher`
   scans, i.e. roughly `2 × games × pitchers` parses of the *same* string.
2. **`PitchRules#available_date`** (`lib/gamechanger/pitch_rules.rb:26`) parsed
   `last_outing_date` on every call, and `available_on?` delegates to it — so
   every eligibility check paid a full heuristic parse of a string the caller
   had usually already parsed moments earlier.
3. **Formatters** parsed the same `last_outing` string 2–3× per pitcher row:
   `available_on?` → parse, `available_date` → parse again, plus a bare
   `Date.parse(last_outing)` for the display label
   (`formatters/table.rb:131-136`, `markdown.rb:117-122`, `json.rb:44-45` and
   `:276-277`, `table.rb:190-192`, `markdown.rb:175-177`, and
   `pre_game_brief.rb:33-35`).

## Change

Pure call-graph restructuring plus memoization — no behavior change.

**`PitchRules`** gains a memoized `#parse_date`:

```ruby
def parse_date(value)
  return nil if value.nil?
  return value if value.instance_of?(Date)

  key = value.to_s
  @parsed_dates[key] ||= Date.parse(key)
end
```

The cache is per-instance (keyed by the string value, so distinct `String`
objects with equal content share an entry) and bounded by the number of
distinct date strings a command touches. `available_date` now goes through it,
so `available_on?` gets the win for free and every existing caller benefits
with no signature change.

**`TournamentPlanner`** parses each game date once per game in `generate_plan`
and threads the parsed `Date` down through `eligible_pitchers` → `pick_pitcher`
→ `can_pitch?`. The second `can_pitch?` scan inside `pick_pitcher` is
deliberately **retained** — it is load-bearing, because it must observe state
mutated by the preceding `assign!` (the starter's same-day pitch count). Only
the redundant *parsing* was removed, not the second scan.

**Formatters and `PreGameBrief`** derive availability from the already-computed
`avail_date` instead of a second `available_on?` parse chain, and use
`rules.parse_date` for the last-outing display label.

### nil semantics preserved exactly

This was the one real correctness hazard, since `available_on?` and
`available_date` disagree on `nil`: `available_on?` returns `true`, while
`available_date` returns `Date.today` (so a naive `target_date >= avail_date`
would wrongly report a never-pitched pitcher as unavailable for any target date
before today — and the pre-game brief is routinely rendered for past dates).
Every derived call site guards it explicitly:

```ruby
avail_date = rules.available_date(last_outing, last_pitches)
avail      = last_outing.nil? || target_date >= avail_date
```

and `PreGameBrief`, which already nil-ed out `avail_date`, uses
`avail_date.nil? || @target_date >= avail_date`. New specs pin this in all four
renderers with target dates both before and after `Date.today`.

## Benchmarks

All numbers measured in this session on this branch vs. `main` — nothing
estimated.

**Methodology.** `benchmark-ips` 2.15.1, Ruby 3.4.7 (arm64-darwin25), 2 s
warmup + 5 s measurement per report. `main` was materialized into a clean
directory with `git archive main | tar -x` and both versions were driven by the
*same* benchmark script (only `$LOAD_PATH` differs), so the fixture and harness
are identical. Because other work was running concurrently on this machine, the
before/after pairs were **interleaved across 3 alternating rounds** and medians
are reported; per-round variance is visible in the raw output below. The
direction and rough magnitude are stable across all 3 rounds.

Fixture: synthetic 8-game weekend (two games per day over four days) × 15
pitchers, with staggered last-outing dates and pitch counts spanning every rest
threshold. Synthetic names only (`Pitcher 1` … `Pitcher 15`, `Opponent 1` …).
A fresh `PitchRules` is constructed inside every iteration, so no measurement
benefits from a cache warmed by a previous iteration.

**Commands**

```bash
gem install benchmark-ips --no-document
git archive main | tar -x -C "$S/baseline"          # $S = scratchpad dir
ruby "$S/bench_date_parse.rb" "$S/baseline" before  # x3, interleaved
ruby "$S/bench_date_parse.rb" "$W"        after     # $W = this worktree
```

**Medians of 3 rounds**

| Benchmark | before (`main`) | after | speedup |
| --- | --- | --- | --- |
| `TournamentPlanner#assignments`, 8 games × 15 pitchers | 905 i/s (1.11 ms/i) | 2722 i/s (367 µs/i) | **~3.0×** |
| `Formatters::Table#availability`, 15 pitchers | 4.45k i/s (225 µs/i) | 13.74k i/s (72.8 µs/i) | **~3.1×** |
| `Formatters::Markdown#availability`, 15 pitchers | 4.65k i/s (215 µs/i) | 12.90k i/s (77.5 µs/i) | **~2.8×** |

<details>
<summary>Raw benchmark-ips output (3 interleaved rounds)</summary>

```
### ROUND 1
       plan 8 games x 15 pitchers (before)      1.025k (±21.3%) i/s  (975.49 μs/i) -      5.148k in   5.021800s
   table availability 15 pitchers (before)      4.744k (±32.7%) i/s  (210.78 μs/i) -     23.751k in   5.006296s
markdown availability 15 pitchers (before)      5.870k (±22.0%) i/s  (170.36 μs/i) -     29.700k in   5.059594s
       plan 8 games x 15 pitchers (after)       2.722k (±21.5%) i/s  (367.32 μs/i) -     13.800k in   5.069048s
   table availability 15 pitchers (after)      13.739k (±13.5%) i/s   (72.78 μs/i) -     68.850k in   5.011110s
markdown availability 15 pitchers (after)      11.480k (±29.8%) i/s   (87.10 μs/i) -     57.720k in   5.027671s
### ROUND 2
       plan 8 games x 15 pitchers (before)    904.606 (±15.0%) i/s    (1.11 ms/i) -      4.572k in   5.054134s
   table availability 15 pitchers (before)      4.450k (±26.0%) i/s  (224.70 μs/i) -     23.002k in   5.168569s
markdown availability 15 pitchers (before)      4.569k (±20.9%) i/s  (218.86 μs/i) -     23.562k in   5.156851s
       plan 8 games x 15 pitchers (after)       1.897k (±10.8%) i/s  (527.15 μs/i) -      9.600k in   5.060676s
   table availability 15 pitchers (after)      13.024k (±20.4%) i/s   (76.78 μs/i) -     65.778k in   5.050445s
markdown availability 15 pitchers (after)      12.900k (± 9.6%) i/s   (77.52 μs/i) -     65.650k in   5.089308s
### ROUND 3
       plan 8 games x 15 pitchers (before)    624.347 (±24.5%) i/s    (1.60 ms/i) -      3.136k in   5.022848s
   table availability 15 pitchers (before)      4.378k (±13.5%) i/s  (228.40 μs/i) -     22.200k in   5.070555s
markdown availability 15 pitchers (before)      4.648k (±19.8%) i/s  (215.15 μs/i) -     23.764k in   5.112780s
       plan 8 games x 15 pitchers (after)       2.975k (±22.6%) i/s  (336.08 μs/i) -     14.940k in   5.021019s
   table availability 15 pitchers (after)      22.768k (± 4.0%) i/s   (43.92 μs/i) -    115.162k in   5.058092s
markdown availability 15 pitchers (after)      18.763k (±22.3%) i/s   (53.30 μs/i) -     94.185k in   5.019795s
```

</details>

<details>
<summary>Benchmark script (scratchpad only — not committed; <code>benchmark-ips</code> is not added to the Gemfile)</summary>

```ruby
# frozen_string_literal: true

# Benchmark for the Date.parse hoisting/memoization fix.
# Usage: ruby bench_date_parse.rb /path/to/repo/root [label]
require 'benchmark/ips'

root = ARGV.fetch(0)
$LOAD_PATH.unshift(File.join(root, 'lib'))
require 'gamechanger'

label = ARGV.fetch(1, 'HEAD')

PITCHERS = (1..15).map { |i| "Pitcher #{i}" }

def rows_for(base)
  PITCHERS.each_with_index.map do |name, i|
    {
      'pitcher_name'    => name,
      'last_outing'     => (base - (i % 5) - 1).to_s,
      'last_pitches'    => [0, 20, 40, 55, 70][i % 5],
      'seven_day_total' => [0, 30, 55, 80][i % 4]
    }
  end
end

BASE  = Date.new(2026, 3, 20)
GAMES = [0, 0, 1, 1, 2, 2, 3, 3].each_with_index.map do |off, i|
  { 'game_date' => (BASE + off).to_s, 'opponent' => "Opponent #{i + 1}" }
end
ROWS = rows_for(BASE)

puts "== #{label} : ruby #{RUBY_VERSION} =="

Benchmark.ips do |x|
  x.config(time: 5, warmup: 2)

  x.report("plan 8 games x 15 pitchers (#{label})") do
    Gamechanger::TournamentPlanner.new(
      games: GAMES, rows: ROWS, rules: Gamechanger::PitchRules.new
    ).assignments
  end

  x.report("table availability 15 pitchers (#{label})") do
    Gamechanger::Formatters::Table.new.availability(
      BASE + 4, nil, ROWS, Gamechanger::PitchRules.new
    )
  end

  x.report("markdown availability 15 pitchers (#{label})") do
    Gamechanger::Formatters::Markdown.new.availability(
      BASE + 4, nil, ROWS, Gamechanger::PitchRules.new
    )
  end
end
```

</details>

## Tests

`bundle exec rspec` → **797 examples, 0 failures** (baseline on `main` was 773;
24 new examples).

New coverage:

- `PitchRules#parse_date` — `nil` passthrough, string parse, memoized identity
  (same string → the *same* `Date` object), memoization by value rather than
  object identity, independence of distinct date strings, `Date.parse` called
  exactly once per distinct string, `Date` argument returned as-is with no
  parse, non-`Date`/non-`String` values parsed via `to_s`, and no cache sharing
  across `PitchRules` instances.
- `#available_date` — reuses the cached parse across differing pitch counts,
  and does not mutate the cached `Date` when adding rest days.
- `TournamentPlanner` — each distinct date string parsed at most once for a
  whole 3-game/8-pitcher plan; rest requirements still honoured after the
  hoist; a pitcher inside their rest window is still blocked; state mutated by
  earlier same-day assignments is still observed (game 2's pool is disjoint
  from game 1's); single-eligible-pitcher path yields no reliever.
- Both branches of every new derived-availability conditional, in all four
  renderers: `Table#availability`, `Markdown#availability`,
  `Json#availability`, and `PreGameBrief#pitcher_plan`, each with a
  `nil` `last_outing` for target dates before *and* after `Date.today`, plus
  the unavailable (rest-window) case.

## Risk

Low. No public signature changed except the addition of
`PitchRules#parse_date`; the planner's changed methods are all private. The
memoization cache is per-`PitchRules`-instance and lives only as long as the
command that created it, so there is no cross-request growth. The one subtle
hazard — the `nil` `last_outing` disagreement between `available_on?` and
`available_date` — is explicitly guarded and spec-pinned at every derived call
site.

Note the pre-existing behavior this change makes more visible but does not
alter: a pitcher who has already pitched on a given calendar day is never
available again that day (`available_date` is always at least `last_outing + 1`),
so `actual_pitches_for`'s daily-capacity clamp is effectively unreachable in
practice. Left untouched — out of scope for a perf-only PR.

🤖 Generated with [Claude Code](https://claude.com/claude-code)
