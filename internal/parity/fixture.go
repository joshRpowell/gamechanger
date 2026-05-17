// Package parity holds the verify-parity harness — Ruby↔Go behavioral
// equivalence checks for the analytics layer. This file is U4: the loader for
// committed test fixtures.
//
// IMPORTANT: parity.Open is the only sanctioned way to read a committed
// fixture. It opens the database with the SQLite `mode=ro&immutable=1` DSN
// flags, which:
//
//   - Disables write-ahead logging so no `<fixture>.db-wal` / `-shm` sidecar
//     files are created next to the committed binary
//   - Disables file locking so the read doesn't block on another reader
//   - Skips internal/store's migration pass; the fixture is treated as a
//     frozen artifact at the schema version it was anonymized at
//
// Without this, every `go test ./internal/parity/...` invocation would leave
// untracked sidecars in the working tree and trigger CI dirty-tree failures.
package parity

import (
	"context"
	"database/sql"
	"fmt"
	"os"

	_ "modernc.org/sqlite"
)

// Open opens a committed parity fixture in read-only, immutable mode.
//
// The returned *sql.DB has the same query surface as a regular *sql.DB but
// SQLite will refuse to write to the file or create sidecars. Callers must
// Close() when done.
//
// Returns an error if the file does not exist or cannot be opened.
func Open(ctx context.Context, path string) (*sql.DB, error) {
	if _, err := os.Stat(path); err != nil {
		return nil, fmt.Errorf("parity: fixture not found at %s: %w", path, err)
	}
	dsn := "file:" + path + "?mode=ro&immutable=1"
	db, err := sql.Open("sqlite", dsn)
	if err != nil {
		return nil, fmt.Errorf("parity: open %s: %w", path, err)
	}
	if err := db.PingContext(ctx); err != nil {
		_ = db.Close()
		return nil, fmt.Errorf("parity: ping %s: %w", path, err)
	}
	return db, nil
}
