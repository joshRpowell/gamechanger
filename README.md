# Gamechanger

A command-line coaching analytics suite for youth baseball coaches. Connects to your [Gamechanger](https://web.gc.com) account and gives you a complete pre-game brief — pitcher availability, suggested lineup, equity flags, and development arcs — in one command.

```bash
gamechanger          # pre-game brief for your next scheduled game
gamechanger refresh  # pull latest data from Gamechanger
```

## Requirements

- Ruby 3.2.0+
- Bundler
- A Gamechanger account with access to the team

## Installation

```bash
cd gamechanger
bundle install
```

## Setup

Run the interactive setup to configure credentials and auto-detect your team:

```bash
bundle exec gamechanger setup
```

This will:
1. Prompt for your Gamechanger email and password
2. Authenticate with the Gamechanger API
3. Detect your team ID automatically
4. Save config to `~/.gamechanger/config.yml` (mode 0600)

### Manual config

If setup can't auto-detect your team ID, edit `~/.gamechanger/config.yml` directly:

```yaml
email: your@email.com
password: your_password
team_id: "12345"    # find this in the URL when viewing your team on web.gc.com
```

## Commands at a glance

| Command | Description |
|---------|-------------|
| `setup` | Configure credentials and auto-detect your team |
| `refresh` | Sync latest game data from Gamechanger |
| `brief` | Pre-game intelligence brief — pitcher plan, lineup, equity, development |
| `pitches` | Pitcher workload summary for the season |
| `availability` | Pitcher availability and rest status for the next game |
| `plan` | Tournament pitcher deployment plan |
| `hitting` | Season batting stats |
| `fielding` | Season fielding position usage (player × position pivot) |
| `lineup` | Suggested batting order based on recent OBP |
| `equity` | Playing time participation for all players |
| `progress` | Player development arcs across the season |

## Usage

### Pre-game brief (default)

```bash
bundle exec gamechanger
bundle exec gamechanger brief
bundle exec gamechanger brief --date 2026-03-21
bundle exec gamechanger brief --format markdown | pbcopy   # copy to clipboard for iMessage/Slack
```

### Sync data

```bash
bundle exec gamechanger refresh          # sync all games
bundle exec gamechanger pitches          # sync and show pitcher workload
bundle exec gamechanger pitches --refresh           # force re-fetch of in-progress games
bundle exec gamechanger pitches --sort era          # ranked by ERA ascending (best first)
bundle exec gamechanger pitches --sort ip_share --desc  # who shouldered the load
bundle exec gamechanger pitches --advanced          # add BB/9, BAA, P/IP columns
bundle exec gamechanger pitches --pitcher Smith     # per-outing log + cumulative footer
```

The default `pitches` table shows `GP`, `Pitches`, `Strikes`, `Balls`, `S%`, `ERA`, `WHIP`, `K/9`, `%IP`, `Avg/Game`, `7-Day`, `Last Outing`. With `--advanced`, three more columns appear between `K/9` and `%IP`: `BB/9`, `BAA`, `P/IP`.

Rate definitions:
- `ERA` = `ER × 9 / IP` (standard 9-inning scale, regardless of league game length)
- `WHIP` = `(H + BB) / IP`
- `K/9` = `SO × 9 / IP`
- `BB/9` = `BB × 9 / IP`
- `BAA` = `H / (BF − BB − HBP)` (rendered as `.XXX`)
- `P/IP` = pitches per inning
- `%IP` = pitcher's share of team's defensive innings (one decimal)

All rate stats render `—` when the denominator is 0 (e.g. relief appearance with no outs).

Sort keys: `name`, `gp`, `pitches`, `strikes`, `balls`, `pct`, `ip_share`, `era`, `whip`, `k9`, `bb9`, `baa`, `p_ip`, `p_bf`, `avg`, `7day`, `last`. Rate-stat sort keys (`era`, `whip`, etc.) work regardless of whether `--advanced` is set.

The per-pitcher view (`--pitcher NAME`) shows raw counts per outing (`P`, `S`, `IP`, `BF`, `H`, `R`, `ER`, `BB`, `SO`) and appends a cumulative footer with derived ERA, WHIP, K/9, and BAA across the displayed outings. Per-outing rates are intentionally not shown — single-outing rates are noisy at youth-game sample sizes.

### Pitcher availability

```bash
bundle exec gamechanger availability
bundle exec gamechanger availability --date 2026-03-21
```

### Tournament planning

```bash
bundle exec gamechanger plan --from 2026-03-21 --to 2026-03-22
bundle exec gamechanger plan --games 2026-03-21,2026-03-22,2026-03-23
bundle exec gamechanger plan --games 2026-03-21 --ace "Smith" --skip "Jones"
```

### Batting

```bash
bundle exec gamechanger hitting
bundle exec gamechanger hitting --sort pa --desc       # most plate appearances first
bundle exec gamechanger lineup
bundle exec gamechanger lineup --date 2026-03-21
```

The `hitting` table shows `PA` (plate appearances = AB + BB + HBP), `AB`, `H`, `BB`, `K`, `AVG`, `OBP`, a 7-day trend arrow, and the player's most recent fielding positions. Sort keys: `name`, `g`, `pa`, `ab`, `h`, `bb`, `k`, `avg`, `obp`. Sacrifice flies and bunts (`SF`/`SH`) are not exposed by the GameChanger boxscore endpoint — `PA` undercounts by 1 for each sac.

### Fielding positions

```bash
bundle exec gamechanger fielding                 # season pivot, sorted by total stints desc
bundle exec gamechanger fielding --sort SS --desc  # most-used shortstops first
bundle exec gamechanger fielding --sort player    # alphabetical
bundle exec gamechanger fielding --format json    # JSON array per player
```

Rows are players; columns are `G` (distinct games fielded), then fielding positions with at least one stint stored this season (canonical order `P C 1B 2B 3B SS LF CF RF DH EH`), then `Total` (sum across positions). Cells under position columns are stint counts (not innings — the boxscore doesn't carry inning numbers). Sort by games with `--sort g` (or `--sort games`).

### Player development

```bash
bundle exec gamechanger progress
bundle exec gamechanger progress --player "Alice"
bundle exec gamechanger progress --pitcher "Smith"
bundle exec gamechanger equity
```

### Sorting reports

`hitting`, `pitches`, `equity`, and `fielding` accept `--sort COL` (with optional `--desc`) to order the table by any column. Computed metrics (AVG, OBP, Strike%) are supported alongside stored columns; missing values always sort last. Sort keys are case-insensitive (`--sort SS` and `--sort ss` are equivalent).

```bash
bundle exec gamechanger hitting --sort avg --desc        # top hitters first
bundle exec gamechanger pitches --sort 7day --desc       # heaviest 7-day workload first
bundle exec gamechanger equity  --sort batago --desc     # players furthest from last AB
```

Run `gamechanger help <command>` to see the column keys for each report.

### Output formats

All commands support `--format table` (default), `--format json`, and `--format markdown`:

```bash
bundle exec gamechanger brief --format markdown | pbcopy
bundle exec gamechanger pitches --format json
```

## Exit codes

| Code | Meaning |
|------|---------|
| 0 | Success |
| 1 | User error (no data found, ambiguous name) |
| 2 | Authentication failure |
| 3 | Network / API error |
| 4 | Config error (missing or malformed config) |

## Data storage

- Config: `~/.gamechanger/config.yml` (mode 0600)
- Session token: `~/.gamechanger/session` (mode 0600)
- Cache: `~/.gamechanger/cache.db` (SQLite, mode 0600)

**Security note:** Password is stored in plaintext in `config.yml` (mode 0600 — readable only by you). This is the same security model used by the AWS CLI and Heroku CLI.

Final games are cached permanently. In-progress and today's games are re-fetched on every invocation.

## Development

```bash
bundle exec rspec                                  # Run tests
RUN_INTEGRATION_TESTS=1 bundle exec rspec          # Include live API tests
gem build gamechanger.gemspec                      # Verify gem builds
```

## Notes

This gem reverse-engineers Gamechanger's internal JSON API. The API is not publicly documented and may change without notice. If the gem stops working, inspect `docs/research/gc-api-notes.md` and update the endpoint constants in `lib/gamechanger/client.rb`.

## License

MIT
