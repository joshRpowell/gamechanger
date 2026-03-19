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
bundle exec gamechanger pitches --refresh  # force re-fetch of in-progress games
```

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
bundle exec gamechanger lineup
bundle exec gamechanger lineup --date 2026-03-21
```

### Player development

```bash
bundle exec gamechanger progress
bundle exec gamechanger progress --player "Alice"
bundle exec gamechanger progress --pitcher "Smith"
bundle exec gamechanger equity
```

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
