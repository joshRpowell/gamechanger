# gamechanger

## Testing

Run tests: `bundle exec rspec`
Test directory: `spec/`

- 100% test coverage is the goal
- When writing new functions, write a corresponding test
- When fixing a bug, write a regression test (see ISSUE-001, ISSUE-002 in spec files for pattern)
- When adding error handling, write a test that triggers the error
- When adding a conditional (if/else), write tests for BOTH paths
- Never commit code that makes existing tests fail

Test conventions: RSpec with `instance_double`, `WebMock` for HTTP stubs, `Dir.mktmpdir` for temp config dirs, seeded in-memory SQLite (`':memory:'`) for storage fixtures.
