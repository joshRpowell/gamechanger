// internal/commands/verify.go — U6 of the verify-parity harness.
//
// `gamechanger verify <command>` runs Ruby (subprocess) and Go (in-process)
// against the same fixture, diffs the JSON outputs through internal/parity,
// and exits with a typed code so an AI-loop driver can distinguish drift from
// every failure mode the harness might encounter.
//
// EXIT-CODE DECISION TREE
//
//   verify <command> --fixture <path>
//        │
//        ├─ <command> ∉ allowlist ───────────────────────────────► 20  go-not-implemented
//        │
//        ├─ fixture not resolvable / outside allowed scope ──────► 21  fixture-missing
//        │
//        ├─ bundle exec exe/gamechanger:
//        │     ├─ not on PATH ─────────────────────────────────► 30  ruby-unavailable
//        │     ├─ context.DeadlineExceeded (60s) ──────────────► 31  ruby-timeout
//        │     ├─ exited nonzero (engine NOT invoked) ─────────► 32  ruby-error
//        │     └─ stdout not valid JSON ───────────────────────► 33  ruby-parse-error
//        │
//        ├─ Go renderer produced invalid JSON (engine signal) ──► 40  go-parse-error
//        │
//        └─ parity.Compare(ruby, go) result:
//              ├─ parity-pass ───────────────────────────────────►  0  parity-pass
//              ├─ parity-unstable (and not --strict) ────────────► 11  parity-unstable
//              └─ drift (or unstable with --strict)              ► 10  drift
//
// Path validation: --fixture is resolved via filepath.EvalSymlinks. Only paths
// that land under <repo>/internal/parity/testdata/ or ~/.gamechanger/ are
// accepted. Symlinks pointing outside the allowed scopes are rejected. Error
// messages emit filepath.Base only — never the full resolved path — so an
// AI-loop transcript can't leak directory structure.
//
// Ruby subprocess environment: os.Environ() minus a secrets denylist
// (anything ending in _TOKEN / _SECRET / _KEY, plus explicit GC_TOKEN /
// GAMECHANGER_TOKEN), then GAMECHANGER_HOME=<fixture dir> appended.

package commands

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"os"
	"os/exec"
	"path/filepath"
	"regexp"
	"strings"
	"time"

	"github.com/spf13/cobra"

	"github.com/joshrpowell/gamechanger-cli/internal/analytics/progressjson"
	"github.com/joshrpowell/gamechanger-cli/internal/config"
	"github.com/joshrpowell/gamechanger-cli/internal/parity"
)

// Typed exit codes. Grouped by domain:
//
//	0x — parity verdicts
//	2x — command / fixture pre-checks
//	3x — Ruby subprocess failure modes
//	4x — Go internal failure modes
//
// Avoids 1 (general error) and 2 (misuse-of-shell-builtins on some POSIX
// shells); each integer is documented in the exit-code decision-tree above.
const (
	ExitParityPass       = 0
	ExitDrift            = 10
	ExitParityUnstable   = 11
	ExitGoNotImplemented = 20
	ExitFixtureMissing   = 21
	ExitRubyUnavailable  = 30
	ExitRubyTimeout      = 31
	ExitRubyError        = 32
	ExitRubyParseError   = 33
	ExitGoParseError     = 40
)

// verifyAllowedCommands gates the positional <command> argument. The map is
// the security boundary against argv injection — anything not in this map
// short-circuits before exec.Cmd is ever constructed.
//
// `pitches` is excluded because Commands::Pitches#call invokes Syncer (hits
// the live API and mutates the cache). `brief` is excluded until its
// dependency tree (PitchRules, LineupOptimizer) is ported. New entries
// require a matching goRunners entry.
var verifyAllowedCommands = map[string]bool{
	"progress": true,
}

// goRunner produces the Go-side JSON output for a given allowed command.
// Tests replace entries to swap in mocks without touching the on-disk fixture.
type goRunner func(ctx context.Context, fixtureDir string, season int) ([]byte, error)

// goRunners is a package-level map so tests can override entries.
var goRunners = map[string]goRunner{
	"progress": runProgressJSON,
}

// rubyCmdFactory builds the Ruby invocation. Overridable for tests via the
// TestHelperProcess pattern so verify_test.go can simulate timeouts, nonzero
// exits, malformed JSON, and env-leak checks without a real Ruby toolchain.
var rubyCmdFactory = defaultRubyCmd

// defaultRubyTimeout caps the Ruby subprocess. When exceeded, verify exits
// with ExitRubyTimeout — a distinct signal from drift so an AI loop can
// recognize "Ruby hung" without ambiguity.
const defaultRubyTimeout = 60 * time.Second

// secretEnvRegex matches variable names that look like credential material.
// (?i) is case-insensitive; the trailing $-anchor ensures we only filter
// suffix matches (PATH stays, GAMECHANGER_TOKEN gets stripped).
var secretEnvRegex = regexp.MustCompile(`(?i).*(_TOKEN|_SECRET|_KEY)$`)

// secretEnvExplicit is a belt-and-suspenders list for known sensitive vars
// that don't fit the regex pattern (or whose presence we want documented).
var secretEnvExplicit = map[string]bool{
	"GC_TOKEN":          true,
	"GAMECHANGER_TOKEN": true,
}

type verifyOpts struct {
	fixture string
	format  string
	strict  bool

	// rubyTimeout is injectable so tests can use millisecond timeouts.
	rubyTimeout time.Duration
}

func newVerifyCmd(opts *rootOpts) *cobra.Command {
	vo := &verifyOpts{rubyTimeout: defaultRubyTimeout}
	cmd := &cobra.Command{
		Use:   "verify <command>",
		Short: "Verify Ruby↔Go parity for a single analytics command",
		Long: `Run the Ruby command (subprocess) and the Go command (in-process) against
the same fixture, then diff the JSON outputs through the parity engine.

Exits with a typed code so an AI-loop driver can distinguish drift from
each failure mode. See the exit-code table in --help.`,
		Args: cobra.ExactArgs(1),
		RunE: func(cmd *cobra.Command, args []string) error {
			return runVerify(cmd.Context(), cmd.OutOrStdout(), cmd.ErrOrStderr(), args[0], vo)
		},
	}
	cmd.Flags().StringVar(&vo.fixture, "fixture", "",
		"Fixture .db path (default: internal/parity/testdata/cache-anchor.db)")
	cmd.Flags().StringVar(&vo.format, "format", "human",
		"Output format: human | json")
	cmd.Flags().BoolVar(&vo.strict, "strict", false,
		"Treat parity-unstable as drift (exit 10 instead of 11)")
	_ = opts // root options not consumed here yet — verify has no auth/network surface
	return cmd
}

// parityExit signals a verify-specific exit code to root.Execute. When msg is
// empty, Execute skips the "gamechanger: " prefix so verdict output (already
// printed to stdout) stays clean.
type parityExit struct {
	code int
	msg  string
}

func (e *parityExit) Error() string { return e.msg }
func (e *parityExit) Code() int     { return e.code }

func runVerify(ctx context.Context, stdout, stderr io.Writer, commandName string, vo *verifyOpts) error {
	// 1. Allowlist gate — first line of defense against argv injection.
	if !verifyAllowedCommands[commandName] {
		return &parityExit{
			code: ExitGoNotImplemented,
			msg:  fmt.Sprintf("Go command not implemented: %q (allowed: %s)", commandName, allowlistDescription()),
		}
	}

	// 2. Resolve and validate the fixture path.
	fixturePath, err := resolveFixturePath(vo.fixture)
	if err != nil {
		return &parityExit{code: ExitFixtureMissing, msg: err.Error()}
	}
	fixtureDir := filepath.Dir(fixturePath)

	// 3. Load the Ruby-compatible config from the fixture dir so Ruby and Go
	//    agree on season. Missing config.yml falls back to current year (same
	//    behavior in Ruby).
	cfg, err := config.LoadFrom(fixtureDir)
	if err != nil {
		// LoadFrom only errors on unreadable dir / malformed yaml — treat as
		// fixture-missing because the user fixed the path wrong.
		return &parityExit{code: ExitFixtureMissing, msg: err.Error()}
	}

	// 4. Run Ruby (subprocess) — captures stdout, propagates stderr to caller.
	rubyOut, rubyErr := runRuby(ctx, vo.rubyTimeout, commandName, fixtureDir)
	if rubyErr != nil {
		return rubyErr // already wrapped in *parityExit
	}

	// 5. Run Go (in-process) — same fixture, same season.
	runner, ok := goRunners[commandName]
	if !ok {
		// Belt-and-suspenders — allowlist + runner map should always agree.
		return &parityExit{
			code: ExitGoNotImplemented,
			msg:  fmt.Sprintf("Go runner missing for allowlisted command %q", commandName),
		}
	}
	goOut, err := runner(ctx, fixtureDir, cfg.Season)
	if err != nil {
		return &parityExit{code: ExitGoParseError, msg: fmt.Sprintf("Go renderer failed: %v", err)}
	}

	// 6. Diff via the parity engine.
	result, err := parity.Compare(rubyOut, goOut)
	if err != nil {
		var pe *parity.ParseError
		if errors.As(err, &pe) {
			code := ExitGoParseError
			if pe.Side == "ruby" {
				code = ExitRubyParseError
			}
			return &parityExit{
				code: code,
				msg:  fmt.Sprintf("%s output is not valid JSON: %v (snippet: %q)", pe.Side, pe.Cause, pe.Snippet),
			}
		}
		return &parityExit{code: ExitGoParseError, msg: fmt.Sprintf("parity compare: %v", err)}
	}

	// 7. Render the result for the user (verdict + diff details).
	if err := renderResult(stdout, vo.format, result); err != nil {
		return &parityExit{code: ExitGoParseError, msg: fmt.Sprintf("render result: %v", err)}
	}

	// 8. Map status → exit code. With --strict, parity-unstable collapses to drift.
	switch result.Status {
	case parity.StatusPass:
		return nil
	case parity.StatusUnstable:
		if vo.strict {
			return &parityExit{code: ExitDrift, msg: ""}
		}
		return &parityExit{code: ExitParityUnstable, msg: ""}
	case parity.StatusDrift:
		return &parityExit{code: ExitDrift, msg: ""}
	default:
		return &parityExit{code: ExitDrift, msg: fmt.Sprintf("unknown parity status %q", result.Status)}
	}
}

func allowlistDescription() string {
	names := make([]string, 0, len(verifyAllowedCommands))
	for k := range verifyAllowedCommands {
		names = append(names, k)
	}
	// Order is unstable across runs because of map iteration; sort for stable error messages.
	for i := 0; i < len(names); i++ {
		for j := i + 1; j < len(names); j++ {
			if names[i] > names[j] {
				names[i], names[j] = names[j], names[i]
			}
		}
	}
	return strings.Join(names, ", ")
}

// resolveFixturePath returns the absolute, symlink-resolved fixture path.
// Default (empty flag) → repo-relative testdata anchor. Any non-empty value is
// resolved and scope-checked against allowed roots. Error messages contain
// only filepath.Base to avoid leaking directory structure.
func resolveFixturePath(flagValue string) (string, error) {
	candidate := flagValue
	if candidate == "" {
		// Default to the committed anchor fixture relative to current working
		// directory. Manual users typically pass --fixture ~/.gamechanger/cache.db.
		candidate = filepath.Join("internal", "parity", "testdata", "cache-anchor.db")
	}

	if _, err := os.Stat(candidate); err != nil {
		return "", fmt.Errorf("fixture not found: %s", filepath.Base(candidate))
	}

	resolved, err := filepath.EvalSymlinks(candidate)
	if err != nil {
		return "", fmt.Errorf("fixture not resolvable: %s", filepath.Base(candidate))
	}
	absResolved, err := filepath.Abs(resolved)
	if err != nil {
		return "", fmt.Errorf("fixture path not absolute: %s", filepath.Base(resolved))
	}

	if !inAllowedScope(absResolved) {
		return "", fmt.Errorf("fixture path outside allowed scope: %s", filepath.Base(absResolved))
	}
	return absResolved, nil
}

// inAllowedScope returns true when `path` resolves inside the repo's testdata
// directory (cwd-relative) or under ~/.gamechanger/. All other resolved paths
// are rejected, even via symlink.
//
// Both the candidate path and the allowed roots are passed through EvalSymlinks
// so a macOS-style /var → /private/var difference doesn't cause a false negative.
func inAllowedScope(path string) bool {
	cleanPath := filepath.Clean(path)
	for _, root := range allowedScopeRoots() {
		if pathHasPrefix(cleanPath, root) {
			return true
		}
	}
	return false
}

// allowedScopeRoots returns the absolute, symlink-resolved roots considered
// safe. Each base candidate is added in both its raw and its EvalSymlinks form
// so tests using t.TempDir() (which on macOS lives under /var → /private/var)
// match cleanly. EvalSymlinks errors are tolerated — the raw form already
// covers the non-symlink case.
func allowedScopeRoots() []string {
	var roots []string
	add := func(p string) {
		abs, err := filepath.Abs(p)
		if err != nil {
			return
		}
		roots = append(roots, abs)
		if resolved, err := filepath.EvalSymlinks(abs); err == nil {
			roots = append(roots, resolved)
		}
	}
	if cwd, err := os.Getwd(); err == nil {
		add(filepath.Join(cwd, "internal", "parity", "testdata"))
	}
	if home, err := os.UserHomeDir(); err == nil {
		add(filepath.Join(home, ".gamechanger"))
	}
	return roots
}

// pathHasPrefix is a path-aware prefix check. `/foo/bar` is under `/foo` but
// `/foobar` is NOT under `/foo` — strings.HasPrefix would falsely match the
// second case.
func pathHasPrefix(path, prefix string) bool {
	cleanPrefix := filepath.Clean(prefix)
	if path == cleanPrefix {
		return true
	}
	return strings.HasPrefix(path, cleanPrefix+string(filepath.Separator))
}

// defaultRubyCmd builds the production Ruby invocation: bundle exec
// exe/gamechanger <command> --format json. Argv form, no shell interpolation.
// The env passed to the subprocess is the parent env minus secrets, plus
// GAMECHANGER_HOME pointed at the fixture directory.
func defaultRubyCmd(ctx context.Context, command, fixtureDir string) *exec.Cmd {
	cmd := exec.CommandContext(ctx, "bundle", "exec", "exe/gamechanger", command, "--format", "json")
	cmd.Env = sanitizedEnv(fixtureDir)
	return cmd
}

// sanitizedEnv returns os.Environ() with secret-looking variables removed and
// GAMECHANGER_HOME appended. PATH, GEM_HOME, HOME, and similar are preserved
// so `bundle` can resolve.
func sanitizedEnv(fixtureDir string) []string {
	parent := os.Environ()
	clean := make([]string, 0, len(parent)+1)
	for _, kv := range parent {
		eq := strings.IndexByte(kv, '=')
		if eq < 0 {
			continue
		}
		name := kv[:eq]
		if secretEnvExplicit[name] {
			continue
		}
		if secretEnvRegex.MatchString(name) {
			continue
		}
		// Also strip any pre-existing GAMECHANGER_HOME — we set our own below.
		if name == "GAMECHANGER_HOME" {
			continue
		}
		clean = append(clean, kv)
	}
	clean = append(clean, "GAMECHANGER_HOME="+fixtureDir)
	return clean
}

// runRuby invokes the Ruby command via rubyCmdFactory, enforces a timeout,
// and classifies the failure mode (unavailable / timeout / error / parse).
// On success returns the stdout bytes for the parity engine.
func runRuby(parentCtx context.Context, timeout time.Duration, command, fixtureDir string) ([]byte, error) {
	if timeout <= 0 {
		timeout = defaultRubyTimeout
	}
	ctx, cancel := context.WithTimeout(parentCtx, timeout)
	defer cancel()

	cmd := rubyCmdFactory(ctx, command, fixtureDir)
	var stdout, stderr bytes.Buffer
	cmd.Stdout = &stdout
	cmd.Stderr = &stderr

	err := cmd.Run()
	if err == nil {
		return stdout.Bytes(), nil
	}

	// Timeout dominates other classifications — when DeadlineExceeded fires,
	// cmd.Run() returns a non-nil error AND ctx.Err() is set.
	if errors.Is(ctx.Err(), context.DeadlineExceeded) {
		return nil, &parityExit{
			code: ExitRubyTimeout,
			msg:  fmt.Sprintf("Ruby subprocess exceeded %s timeout", timeout),
		}
	}

	// bundle not on PATH → exec.Error wraps "executable file not found".
	var execErr *exec.Error
	if errors.As(err, &execErr) {
		return nil, &parityExit{
			code: ExitRubyUnavailable,
			msg:  "Ruby toolchain not available — install Ruby and run `bundle install`",
		}
	}

	// Ruby ran but exited nonzero — capture first 500 chars of stderr so the
	// AI loop has something actionable. The engine is NOT invoked: passing
	// partial Ruby stdout to parity.Compare would produce phantom drift the
	// loop would try to "fix" by making Go match Ruby's panic state.
	var exitErr *exec.ExitError
	if errors.As(err, &exitErr) {
		snippet := truncate(stderr.String(), 500)
		return nil, &parityExit{
			code: ExitRubyError,
			msg:  fmt.Sprintf("Ruby exited %d: %s", exitErr.ExitCode(), snippet),
		}
	}

	return nil, &parityExit{
		code: ExitRubyError,
		msg:  fmt.Sprintf("Ruby invocation failed: %v", err),
	}
}

func truncate(s string, max int) string {
	if len(s) <= max {
		return s
	}
	return s[:max]
}

// runProgressJSON is the production Go runner for the `progress` command. It
// calls progressjson.Render in-process — no subprocess, no go run.
func runProgressJSON(ctx context.Context, fixtureDir string, season int) ([]byte, error) {
	return progressjson.Render(ctx, fixtureDir, season)
}

// renderResult prints the parity Result to stdout in the chosen format.
func renderResult(out io.Writer, format string, result *parity.Result) error {
	switch format {
	case "json":
		enc := json.NewEncoder(out)
		enc.SetIndent("", "  ")
		return enc.Encode(result)
	case "human", "":
		return renderHuman(out, result)
	default:
		return fmt.Errorf("unknown --format %q (expected human | json)", format)
	}
}

func renderHuman(out io.Writer, result *parity.Result) error {
	fmt.Fprintf(out, "Status: %s\n", result.Status)
	if len(result.Diffs) == 0 {
		fmt.Fprintln(out, "(no diffs)")
		return nil
	}
	for _, d := range result.Diffs {
		fmt.Fprintf(out, "  %s [%s/%s] ruby=%v go=%v",
			d.Path, d.Class, d.Disposition, d.Ruby, d.Go)
		if d.Delta != nil {
			fmt.Fprintf(out, " Δ=%g", *d.Delta)
		}
		if d.ThresholdProximity != "" {
			fmt.Fprintf(out, " (%s)", d.ThresholdProximity)
		}
		if d.QuirkNote != "" {
			fmt.Fprintf(out, " — quirk: %s", d.QuirkNote)
		}
		fmt.Fprintln(out)
	}
	return nil
}
