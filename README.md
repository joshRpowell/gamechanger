# Gamechanger Pitch Count Tracker

A Ruby CLI gem that fetches pitcher workload data from the [Gamechanger](https://web.gc.com) baseball app and presents season-wide pitch count analysis from the command line.

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

## Usage

### Season summary (all pitchers)

```bash
bundle exec gamechanger pitches
```

Output:

```
┌───────────────┬────┬───────────────┬──────────┬─────────────┬──────────────┐
│ Pitcher       │ GP │ Total Pitches │ Avg/Game │ 7-Day Total │ Last Outing  │
├───────────────┼────┼───────────────┼──────────┼─────────────┼──────────────┤
│ Alice Smith   │  8 │           512 │     64.0 │          65 │ 2026-03-14   │
│ Bob Jones     │  5 │           320 │     64.0 │           0 │ 2026-03-02   │
└───────────────┴────┴───────────────┴──────────┴─────────────┴──────────────┘
```

### Single pitcher deep-dive

```bash
bundle exec gamechanger pitches --pitcher "Alice"
```

### Single game breakdown

```bash
bundle exec gamechanger pitches --game 2026-03-14
```

### Force refresh from Gamechanger

```bash
bundle exec gamechanger pitches --refresh
```

### JSON output

All views support `--format json`:

```bash
bundle exec gamechanger pitches --format json
bundle exec gamechanger pitches --pitcher "Alice" --format json
bundle exec gamechanger pitches --game 2026-03-14 --format json
```

## Options

| Flag | Description |
|------|-------------|
| `--pitcher NAME` | Filter to a single pitcher (case-insensitive substring) |
| `--game YYYY-MM-DD` | Show a single game by date |
| `--game-number N` | For doubleheaders, pick game 1 or 2 (default: 1) |
| `--refresh` | Force re-fetch of non-final games |
| `--format table\|json` | Output format (default: table) |

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
