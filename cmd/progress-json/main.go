// Command progress-json is a pilot-only Go entry point for the verify-parity
// harness (U1). It reads the development summary from the gamechanger SQLite
// store and emits JSON matching Ruby's `gamechanger progress --format json`
// output shape (lib/gamechanger/formatters/json.rb#progress).
//
// Reads GAMECHANGER_HOME for the data directory and GC_SEASON for the season
// year. Both have sensible defaults: ~/.gamechanger and current year.
//
// The actual rendering lives in internal/analytics/progressjson; this binary
// is a thin CLI wrapper. internal/commands/verify (U6) calls the same Render
// function in-process so the harness and the pilot diff loop emit identical
// bytes.
package main

import (
	"context"
	"fmt"
	"os"
	"strconv"
	"time"

	"github.com/joshrpowell/gamechanger-cli/internal/analytics/progressjson"
)

func main() {
	ctx := context.Background()

	out, err := progressjson.Render(ctx, dataDir(), currentSeason())
	if err != nil {
		fmt.Fprintln(os.Stderr, err)
		os.Exit(1)
	}
	fmt.Println(string(out))
}

func currentSeason() int {
	if v := os.Getenv("GC_SEASON"); v != "" {
		if i, err := strconv.Atoi(v); err == nil {
			return i
		}
	}
	return time.Now().Year()
}

func dataDir() string {
	if v := os.Getenv("GAMECHANGER_HOME"); v != "" {
		return v
	}
	home, _ := os.UserHomeDir()
	return home + "/.gamechanger"
}
