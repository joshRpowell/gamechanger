// Package store is the SQLite-backed cache for game, pitcher, and batter
// data. Wire-compatible with the Ruby Gamechanger::Storage schema so a user
// who already ran `gamechanger refresh` in Ruby can keep using their existing
// ~/.gamechanger/cache.db.
package store

import (
	"context"
	"database/sql"
	"errors"
	"fmt"
	"io/fs"
	"os"
	"path/filepath"
	"time"

	_ "modernc.org/sqlite" // registers "sqlite" driver

	"github.com/joshrpowell/gamechanger-cli/internal/gcerr"
)

const (
	defaultDirName = ".gamechanger"
	dbFileName     = "cache.db"
	memoryPath     = ":memory:"
)

// Store wraps a *sql.DB with helpers for game/pitcher/batter records.
type Store struct {
	db     *sql.DB
	season int
}

// Open returns a Store backed by ~/.gamechanger/cache.db. season scopes
// every query to that calendar year.
func Open(ctx context.Context, season int) (*Store, error) {
	home, err := os.UserHomeDir()
	if err != nil {
		return nil, gcerr.Storagef("locate home directory: %v", err)
	}
	return OpenAt(ctx, filepath.Join(home, defaultDirName), season)
}

// OpenAt opens a store at a specific directory. Pass ":memory:" or "" to
// run against an in-memory database (tests).
func OpenAt(ctx context.Context, dir string, season int) (*Store, error) {
	dsn, err := resolveDSN(dir)
	if err != nil {
		return nil, err
	}

	db, err := sql.Open("sqlite", dsn)
	if err != nil {
		return nil, gcerr.Storagef("open sqlite: %v", err)
	}
	// modernc.org/sqlite is goroutine-safe per-connection; we don't need a
	// large pool for this single-process CLI. One connection is enough and
	// avoids "database is locked" surprises in WAL mode.
	db.SetMaxOpenConns(1)

	if dsn != memoryDSN() {
		if err := os.Chmod(dsnPath(dsn), 0o600); err != nil && !errors.Is(err, fs.ErrNotExist) {
			_ = db.Close()
			return nil, gcerr.Storagef("chmod %s: %v", dsn, err)
		}
	}

	pragmas := []string{
		"PRAGMA foreign_keys = ON",
		"PRAGMA synchronous = NORMAL",
		"PRAGMA cache_size = -10000",
		"PRAGMA busy_timeout = 5000",
	}
	if dsn != memoryDSN() {
		pragmas = append(pragmas, "PRAGMA journal_mode = WAL")
	}
	for _, p := range pragmas {
		if _, err := db.ExecContext(ctx, p); err != nil {
			_ = db.Close()
			return nil, gcerr.Storagef("pragma %q: %v", p, err)
		}
	}

	s := &Store{db: db, season: season}
	if err := s.migrate(ctx); err != nil {
		_ = db.Close()
		return nil, err
	}
	return s, nil
}

// Close releases the underlying database connection.
func (s *Store) Close() error {
	if s.db == nil {
		return nil
	}
	err := s.db.Close()
	s.db = nil
	return err
}

// DB exposes the underlying *sql.DB for tests and adjacent packages.
func (s *Store) DB() *sql.DB { return s.db }

// Season returns the configured season year.
func (s *Store) Season() int { return s.season }

func (s *Store) seasonStart() string     { return fmt.Sprintf("%d-01-01", s.season) }
func (s *Store) nextSeasonStart() string { return fmt.Sprintf("%d-01-01", s.season+1) }

func resolveDSN(dir string) (string, error) {
	if dir == "" || dir == memoryPath {
		return memoryDSN(), nil
	}
	if err := os.MkdirAll(dir, 0o700); err != nil {
		return "", gcerr.Storagef("create data dir %s: %v", dir, err)
	}
	path := filepath.Join(dir, dbFileName)
	// Create with 0600 if missing so the file is private from the start.
	if _, err := os.Stat(path); errors.Is(err, fs.ErrNotExist) {
		f, err := os.OpenFile(path, os.O_CREATE|os.O_EXCL|os.O_WRONLY, 0o600)
		if err != nil && !errors.Is(err, fs.ErrExist) {
			return "", gcerr.Storagef("pre-create %s: %v", path, err)
		}
		if f != nil {
			_ = f.Close()
		}
	}
	return "file:" + path + "?_pragma=foreign_keys(1)", nil
}

func memoryDSN() string {
	return "file::memory:?cache=shared"
}

func dsnPath(dsn string) string {
	// "file:/path?...". Strip prefix + query string.
	if len(dsn) >= 5 && dsn[:5] == "file:" {
		dsn = dsn[5:]
	}
	for i := 0; i < len(dsn); i++ {
		if dsn[i] == '?' {
			return dsn[:i]
		}
	}
	return dsn
}

// iso8601Now returns the current time in the Ruby strftime format
// '%Y-%m-%dT%H:%M:%SZ' for fetched_at column compatibility.
func iso8601Now() string {
	return time.Now().UTC().Format("2006-01-02T15:04:05Z")
}
