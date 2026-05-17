// Command anonymize-fixture is the bootstrap CLI for U3 of the verify-parity
// harness. It reads a real cache.db and writes a PII-scrubbed fixture suitable
// for committing to the public repo.
//
// Usage:
//
//	go run ./cmd/anonymize-fixture \
//	  --source ~/.gamechanger/cache.db \
//	  --out internal/parity/testdata/cache-anchor.db \
//	  [--map-dir ~/.gamechanger]
//
// EXIT CODES (typed, machine-readable)
//
//	0 — success
//	1 — usage error (missing flags, both --source and --out required)
//	2 — source database not found at the given --source path
//	3 — source database is corrupt or unreadable
//	4 — source database schema does not match the expected gamechanger shape
//	5 — internal error (write failure, permission issue, etc.)
package main

import (
	"context"
	"errors"
	"flag"
	"fmt"
	"os"
	"path/filepath"

	"github.com/joshrpowell/gamechanger-cli/internal/parity/anonymize"
)

const (
	exitOK             = 0
	exitUsage          = 1
	exitSourceMissing  = 2
	exitSourceCorrupt  = 3
	exitSourceSchema   = 4
	exitInternal       = 5
)

func main() {
	os.Exit(run())
}

func run() int {
	source := flag.String("source", "", "path to source cache.db (required)")
	out := flag.String("out", "", "path to write anonymized fixture (required)")
	mapDir := flag.String("map-dir", defaultMapDir(), "directory for the substitution map (default: ~/.gamechanger)")
	flag.Parse()

	if *source == "" || *out == "" {
		fmt.Fprintln(os.Stderr, "anonymize-fixture: --source and --out are both required")
		flag.Usage()
		return exitUsage
	}

	res, err := anonymize.Run(context.Background(), anonymize.Options{
		SourcePath: *source,
		OutputPath: *out,
		MapDir:     *mapDir,
	})

	switch {
	case errors.Is(err, anonymize.ErrSourceMissing):
		fmt.Fprintf(os.Stderr, "anonymize-fixture: source not found at %s\nRun `gamechanger refresh` first to populate the cache, or pass --source to point at an existing cache.db.\n", *source)
		return exitSourceMissing
	case errors.Is(err, anonymize.ErrSourceCorrupt):
		fmt.Fprintf(os.Stderr, "anonymize-fixture: source database is corrupt or unreadable: %v\n", err)
		return exitSourceCorrupt
	case errors.Is(err, anonymize.ErrSourceSchema):
		fmt.Fprintf(os.Stderr, "anonymize-fixture: source schema mismatch: %v\nThe source database may be from a different Ruby gem version. Re-run `gamechanger refresh` to bring it up to the current schema.\n", err)
		return exitSourceSchema
	case err != nil:
		fmt.Fprintf(os.Stderr, "anonymize-fixture: %v\n", err)
		return exitInternal
	}

	fmt.Fprintf(os.Stdout, "anonymize-fixture: wrote %d games, %d players\n", res.GamesAnonymized, res.PlayersAnonymized)
	fmt.Fprintf(os.Stdout, "  fixture: %s\n", res.OutputPath)
	fmt.Fprintf(os.Stdout, "  substitution map: %s (keep local, never commit)\n", res.MapPath)
	return exitOK
}

func defaultMapDir() string {
	home, err := os.UserHomeDir()
	if err != nil {
		return ".gamechanger"
	}
	return filepath.Join(home, ".gamechanger")
}
