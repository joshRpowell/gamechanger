package commands

import (
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"io"
	"os"
	"os/exec"
	"path/filepath"
	"runtime"
	"strings"
	"testing"
	"time"

	"github.com/joshrpowell/gamechanger-cli/internal/parity"
)

// ─── Helper-process trick ────────────────────────────────────────────────────
//
// TestHelperProcess is invoked when the test binary re-executes itself as a
// fake Ruby. The behaviors are selected by GO_HELPER_MODE.

func TestHelperProcess(t *testing.T) {
	if os.Getenv("GO_WANT_HELPER_PROCESS") != "1" {
		return
	}
	mode := os.Getenv("GO_HELPER_MODE")
	stdout := os.Getenv("GO_HELPER_STDOUT")

	switch mode {
	case "ok":
		fmt.Fprintln(os.Stdout, stdout)
		os.Exit(0)
	case "fail":
		fmt.Fprintln(os.Stderr, "RuntimeError: simulated Ruby failure\n  from exe/gamechanger:1:in `<main>'")
		os.Exit(1)
	case "timeout":
		// Sleep longer than any reasonable test timeout. Context cancellation
		// from the parent will kill us before this returns.
		time.Sleep(30 * time.Second)
		os.Exit(0)
	case "bad-json":
		fmt.Fprintln(os.Stdout, "this is not json {")
		os.Exit(0)
	case "env-dump":
		// Dump the inherited env to a file the test specifies via
		// GO_HELPER_ENV_FILE. Emit valid JSON on stdout so runVerify's
		// parity.Compare call doesn't bail with a parse error before the
		// test inspects the dumped file.
		if envFile := os.Getenv("GO_HELPER_ENV_FILE"); envFile != "" {
			f, err := os.Create(envFile)
			if err != nil {
				fmt.Fprintln(os.Stderr, "env-dump open:", err)
				os.Exit(2)
			}
			for _, e := range os.Environ() {
				fmt.Fprintln(f, e)
			}
			_ = f.Close()
		}
		fmt.Fprintln(os.Stdout, "[]")
		os.Exit(0)
	default:
		fmt.Fprintln(os.Stderr, "TestHelperProcess: unknown mode", mode)
		os.Exit(2)
	}
}

// helperCmd builds a rubyCmdFactory that re-executes the current test binary
// in TestHelperProcess mode. envExtra is appended to the sanitized env.
func helperCmd(t *testing.T, mode, stdout string, envExtra ...string) func(ctx context.Context, command, fixtureDir string) *exec.Cmd {
	t.Helper()
	return func(ctx context.Context, command, fixtureDir string) *exec.Cmd {
		cmd := exec.CommandContext(ctx, os.Args[0], "-test.run=TestHelperProcess")
		cmd.Env = append(sanitizedEnv(fixtureDir),
			"GO_WANT_HELPER_PROCESS=1",
			"GO_HELPER_MODE="+mode,
			"GO_HELPER_STDOUT="+stdout,
		)
		cmd.Env = append(cmd.Env, envExtra...)
		return cmd
	}
}

// withRubyCmdFactory swaps rubyCmdFactory for the duration of the test.
func withRubyCmdFactory(t *testing.T, factory func(ctx context.Context, command, fixtureDir string) *exec.Cmd) {
	t.Helper()
	original := rubyCmdFactory
	rubyCmdFactory = factory
	t.Cleanup(func() { rubyCmdFactory = original })
}

// withGoRunner swaps goRunners[command] for the duration of the test.
func withGoRunner(t *testing.T, command string, runner goRunner) {
	t.Helper()
	original, had := goRunners[command]
	goRunners[command] = runner
	t.Cleanup(func() {
		if had {
			goRunners[command] = original
		} else {
			delete(goRunners, command)
		}
	})
}

// setupFakeHome creates a temp dir, sets HOME to it, and creates a
// `.gamechanger/` subdir. Returns the .gamechanger path. The fixture sits
// inside this scope so resolveFixturePath accepts it.
func setupFakeHome(t *testing.T) string {
	t.Helper()
	home := t.TempDir()
	t.Setenv("HOME", home)
	gcHome := filepath.Join(home, ".gamechanger")
	if err := os.MkdirAll(gcHome, 0o700); err != nil {
		t.Fatalf("mkdir %s: %v", gcHome, err)
	}
	return gcHome
}

// writeFixtureFile creates a placeholder fixture file (the resolveFixturePath
// machinery only stats it — the contents don't matter unless the test invokes
// the real Go runner).
func writeFixtureFile(t *testing.T, dir, name string) string {
	t.Helper()
	path := filepath.Join(dir, name)
	if err := os.WriteFile(path, []byte("not-really-sqlite"), 0o600); err != nil {
		t.Fatalf("write fixture %s: %v", path, err)
	}
	return path
}

// ─── Result rendering & parity verdicts ──────────────────────────────────────

func TestVerify_ParityPass(t *testing.T) {
	gcHome := setupFakeHome(t)
	fixture := writeFixtureFile(t, gcHome, "cache.db")

	rubyJSON := `[{"player":"X"}]`
	withRubyCmdFactory(t, helperCmd(t, "ok", rubyJSON))
	withGoRunner(t, "progress", func(ctx context.Context, dir string, season int) ([]byte, error) {
		return []byte(rubyJSON), nil
	})

	code, stdout, stderr := runVerifyCapture(t, "progress", &verifyOpts{
		fixture: fixture, format: "human", rubyTimeout: 5 * time.Second,
	})
	if code != ExitParityPass {
		t.Fatalf("exit code: got %d want %d (stderr=%q)", code, ExitParityPass, stderr)
	}
	if !strings.Contains(stdout, "parity-pass") {
		t.Fatalf("human output missing status: %q", stdout)
	}
}

func TestVerify_DriftExit(t *testing.T) {
	gcHome := setupFakeHome(t)
	fixture := writeFixtureFile(t, gcHome, "cache.db")

	withRubyCmdFactory(t, helperCmd(t, "ok", `[{"player":"X","position":1}]`))
	withGoRunner(t, "progress", func(ctx context.Context, dir string, season int) ([]byte, error) {
		return []byte(`[{"player":"X","position":2}]`), nil
	})

	code, stdout, _ := runVerifyCapture(t, "progress", &verifyOpts{
		fixture: fixture, format: "human", rubyTimeout: 5 * time.Second,
	})
	if code != ExitDrift {
		t.Fatalf("exit code: got %d want %d", code, ExitDrift)
	}
	if !strings.Contains(stdout, "position") {
		t.Fatalf("human output missing drifted field: %q", stdout)
	}
}

func TestVerify_ParityUnstableAndStrict(t *testing.T) {
	gcHome := setupFakeHome(t)
	fixture := writeFixtureFile(t, gcHome, "cache.db")

	// trend differs AND the underlying obp delta straddles 0.050 ± 0.005.
	// We avoid the `narrative` leaf because the engine's nil_half quirk
	// allowlists narrative drift unconditionally — trend is the right surface
	// for exercising parity-unstable.
	ruby := `{"batting":{"first_half_obp":0.300,"second_half_obp":0.348,"trend":"up"}}`
	gobs := `{"batting":{"first_half_obp":0.300,"second_half_obp":0.348,"trend":"down"}}`
	withRubyCmdFactory(t, helperCmd(t, "ok", ruby))
	withGoRunner(t, "progress", func(ctx context.Context, dir string, season int) ([]byte, error) {
		return []byte(gobs), nil
	})

	// Without --strict → parity-unstable.
	code, _, _ := runVerifyCapture(t, "progress", &verifyOpts{
		fixture: fixture, format: "human", rubyTimeout: 5 * time.Second,
	})
	if code != ExitParityUnstable {
		t.Fatalf("non-strict: got exit %d want %d", code, ExitParityUnstable)
	}

	// With --strict → drift.
	withRubyCmdFactory(t, helperCmd(t, "ok", ruby))
	withGoRunner(t, "progress", func(ctx context.Context, dir string, season int) ([]byte, error) {
		return []byte(gobs), nil
	})
	code, _, _ = runVerifyCapture(t, "progress", &verifyOpts{
		fixture: fixture, format: "human", strict: true, rubyTimeout: 5 * time.Second,
	})
	if code != ExitDrift {
		t.Fatalf("strict: got exit %d want %d", code, ExitDrift)
	}
}

func TestVerify_FormatJSON_RoundTrip(t *testing.T) {
	gcHome := setupFakeHome(t)
	fixture := writeFixtureFile(t, gcHome, "cache.db")

	withRubyCmdFactory(t, helperCmd(t, "ok", `[{"player":"X","position":1}]`))
	withGoRunner(t, "progress", func(ctx context.Context, dir string, season int) ([]byte, error) {
		return []byte(`[{"player":"X","position":2}]`), nil
	})

	_, stdout, _ := runVerifyCapture(t, "progress", &verifyOpts{
		fixture: fixture, format: "json", rubyTimeout: 5 * time.Second,
	})
	var result parity.Result
	if err := json.Unmarshal([]byte(stdout), &result); err != nil {
		t.Fatalf("--format json output not valid JSON: %v\noutput: %q", err, stdout)
	}
	if result.Status != parity.StatusDrift {
		t.Fatalf("round-trip status: got %q want %q", result.Status, parity.StatusDrift)
	}
}

// ─── Allowlist / argv-injection ──────────────────────────────────────────────

func TestVerify_AllowlistRejectsUnknownCommand(t *testing.T) {
	gcHome := setupFakeHome(t)
	_ = writeFixtureFile(t, gcHome, "cache.db")

	code, _, stderr := runVerifyCapture(t, "lineup", &verifyOpts{
		format: "human", rubyTimeout: 5 * time.Second,
	})
	if code != ExitGoNotImplemented {
		t.Fatalf("got exit %d want %d (stderr=%q)", code, ExitGoNotImplemented, stderr)
	}
	if !strings.Contains(stderr, `"lineup"`) {
		t.Fatalf("error message missing rejected command name: %q", stderr)
	}
}

func TestVerify_AllowlistRejectsArgvInjection(t *testing.T) {
	gcHome := setupFakeHome(t)
	_ = writeFixtureFile(t, gcHome, "cache.db")

	// The malicious string is not in the allowlist → rejected before any
	// exec.Cmd is constructed.
	code, _, _ := runVerifyCapture(t, "brief; rm -rf /", &verifyOpts{
		format: "human", rubyTimeout: 5 * time.Second,
	})
	if code != ExitGoNotImplemented {
		t.Fatalf("argv injection: got exit %d want %d", code, ExitGoNotImplemented)
	}
}

// ─── Fixture path validation ─────────────────────────────────────────────────

func TestVerify_FixtureMissing(t *testing.T) {
	setupFakeHome(t)

	code, _, stderr := runVerifyCapture(t, "progress", &verifyOpts{
		fixture: "/tmp/this-file-does-not-exist-12345.db",
		format:  "human", rubyTimeout: 5 * time.Second,
	})
	if code != ExitFixtureMissing {
		t.Fatalf("got exit %d want %d", code, ExitFixtureMissing)
	}
	// Basename in message, but the full path must not leak.
	if strings.Contains(stderr, "/tmp/this-file-does-not-exist-12345") {
		t.Fatalf("error message leaked full path: %q", stderr)
	}
}

func TestVerify_FixtureOutsideAllowedScope(t *testing.T) {
	setupFakeHome(t)

	// Create a file in an explicitly-disallowed location (outside HOME and
	// outside CWD/internal/parity/testdata).
	disallowedDir := t.TempDir()
	disallowed := filepath.Join(disallowedDir, "cache.db")
	if err := os.WriteFile(disallowed, []byte("x"), 0o600); err != nil {
		t.Fatalf("write disallowed fixture: %v", err)
	}

	code, _, stderr := runVerifyCapture(t, "progress", &verifyOpts{
		fixture: disallowed, format: "human", rubyTimeout: 5 * time.Second,
	})
	if code != ExitFixtureMissing {
		t.Fatalf("got exit %d want %d", code, ExitFixtureMissing)
	}
	if strings.Contains(stderr, disallowedDir) {
		t.Fatalf("error message leaked disallowed dir: %q", stderr)
	}
}

func TestVerify_SymlinkTraversal(t *testing.T) {
	if runtime.GOOS == "windows" {
		t.Skip("symlink semantics differ on Windows")
	}
	gcHome := setupFakeHome(t)

	// Create a real file outside HOME.
	outside := t.TempDir()
	target := filepath.Join(outside, "secret.db")
	if err := os.WriteFile(target, []byte("x"), 0o600); err != nil {
		t.Fatalf("write target: %v", err)
	}

	// Symlink inside HOME → outside. resolveFixturePath should follow the
	// symlink, see the resolved path lies outside allowed scope, and reject.
	link := filepath.Join(gcHome, "sneaky.db")
	if err := os.Symlink(target, link); err != nil {
		t.Fatalf("symlink: %v", err)
	}

	code, _, stderr := runVerifyCapture(t, "progress", &verifyOpts{
		fixture: link, format: "human", rubyTimeout: 5 * time.Second,
	})
	if code != ExitFixtureMissing {
		t.Fatalf("got exit %d want %d", code, ExitFixtureMissing)
	}
	if strings.Contains(stderr, target) || strings.Contains(stderr, outside) {
		t.Fatalf("error message leaked symlink target: %q", stderr)
	}
}

// ─── Ruby subprocess failure modes ───────────────────────────────────────────

func TestVerify_RubyTimeout(t *testing.T) {
	gcHome := setupFakeHome(t)
	fixture := writeFixtureFile(t, gcHome, "cache.db")

	withRubyCmdFactory(t, helperCmd(t, "timeout", ""))

	code, _, stderr := runVerifyCapture(t, "progress", &verifyOpts{
		fixture: fixture, format: "human", rubyTimeout: 50 * time.Millisecond,
	})
	if code != ExitRubyTimeout {
		t.Fatalf("got exit %d want %d (stderr=%q)", code, ExitRubyTimeout, stderr)
	}
	if !strings.Contains(stderr, "50ms") {
		t.Fatalf("error message missing timeout duration: %q", stderr)
	}
}

func TestVerify_RubyError(t *testing.T) {
	gcHome := setupFakeHome(t)
	fixture := writeFixtureFile(t, gcHome, "cache.db")

	withRubyCmdFactory(t, helperCmd(t, "fail", ""))
	engineInvoked := false
	withGoRunner(t, "progress", func(ctx context.Context, dir string, season int) ([]byte, error) {
		engineInvoked = true
		return []byte(`[]`), nil
	})

	code, _, stderr := runVerifyCapture(t, "progress", &verifyOpts{
		fixture: fixture, format: "human", rubyTimeout: 5 * time.Second,
	})
	if code != ExitRubyError {
		t.Fatalf("got exit %d want %d", code, ExitRubyError)
	}
	if !strings.Contains(stderr, "RuntimeError") {
		t.Fatalf("error message missing Ruby stderr snippet: %q", stderr)
	}
	if engineInvoked {
		t.Fatalf("engine was invoked despite Ruby failure — phantom drift risk")
	}
}

func TestVerify_RubyParseError(t *testing.T) {
	gcHome := setupFakeHome(t)
	fixture := writeFixtureFile(t, gcHome, "cache.db")

	withRubyCmdFactory(t, helperCmd(t, "bad-json", ""))
	withGoRunner(t, "progress", func(ctx context.Context, dir string, season int) ([]byte, error) {
		return []byte(`[]`), nil
	})

	code, _, stderr := runVerifyCapture(t, "progress", &verifyOpts{
		fixture: fixture, format: "human", rubyTimeout: 5 * time.Second,
	})
	if code != ExitRubyParseError {
		t.Fatalf("got exit %d want %d (stderr=%q)", code, ExitRubyParseError, stderr)
	}
}

func TestVerify_RubyUnavailable(t *testing.T) {
	gcHome := setupFakeHome(t)
	fixture := writeFixtureFile(t, gcHome, "cache.db")

	withRubyCmdFactory(t, func(ctx context.Context, command, fixtureDir string) *exec.Cmd {
		// Reference a binary that doesn't exist anywhere on PATH.
		return exec.CommandContext(ctx, "this-binary-does-not-exist-anywhere-9b2c4f")
	})

	code, _, stderr := runVerifyCapture(t, "progress", &verifyOpts{
		fixture: fixture, format: "human", rubyTimeout: 5 * time.Second,
	})
	if code != ExitRubyUnavailable {
		t.Fatalf("got exit %d want %d (stderr=%q)", code, ExitRubyUnavailable, stderr)
	}
}

// ─── Environment scrubbing ───────────────────────────────────────────────────

func TestVerify_SecretsDenylist(t *testing.T) {
	gcHome := setupFakeHome(t)
	fixture := writeFixtureFile(t, gcHome, "cache.db")

	// Plant several secrets in the parent env. sanitizedEnv should strip them
	// before they reach the subprocess.
	t.Setenv("GC_TOKEN", "secret-gc-token-value")
	t.Setenv("GAMECHANGER_TOKEN", "secret-gamechanger-token-value")
	t.Setenv("AWS_SECRET_ACCESS_KEY", "secret-aws-value")
	t.Setenv("MY_PASSWORD_KEY", "secret-password-key-value")
	t.Setenv("STRIPE_SECRET", "secret-stripe-value")
	t.Setenv("BENIGN_VAR", "should-pass-through")

	// The helper writes its inherited env to this file. We read it after
	// runVerify returns — using cmd.Stdout for capture would race with
	// runRuby's own stdout assignment.
	envFile := filepath.Join(t.TempDir(), "env.dump")
	t.Setenv("GO_HELPER_ENV_FILE", envFile)

	withRubyCmdFactory(t, helperCmd(t, "env-dump", ""))
	withGoRunner(t, "progress", func(ctx context.Context, dir string, season int) ([]byte, error) {
		return []byte(`[]`), nil
	})

	_, _, _ = runVerifyCapture(t, "progress", &verifyOpts{
		fixture: fixture, format: "human", rubyTimeout: 5 * time.Second,
	})

	dumped, err := os.ReadFile(envFile)
	if err != nil {
		t.Fatalf("env-dump file not written: %v", err)
	}
	asString := string(dumped)
	leaks := []string{
		"GC_TOKEN=", "GAMECHANGER_TOKEN=", "AWS_SECRET_ACCESS_KEY=",
		"MY_PASSWORD_KEY=", "STRIPE_SECRET=",
	}
	for _, prefix := range leaks {
		if strings.Contains(asString, prefix) {
			t.Errorf("subprocess env leaked %q", prefix)
		}
	}
	if !strings.Contains(asString, "BENIGN_VAR=should-pass-through") {
		t.Errorf("subprocess env stripped benign var (expected to pass through)")
	}
	// resolveFixturePath returns the symlink-resolved form; GAMECHANGER_HOME
	// inherits that, so we compare against EvalSymlinks(gcHome).
	resolvedHome, err := filepath.EvalSymlinks(gcHome)
	if err != nil {
		resolvedHome = gcHome
	}
	if !strings.Contains(asString, "GAMECHANGER_HOME="+resolvedHome) {
		t.Errorf("subprocess env missing GAMECHANGER_HOME=%s\nfull dump:\n%s", resolvedHome, asString)
	}
}

func TestVerify_GamechangerHomeInjection(t *testing.T) {
	gcHome := setupFakeHome(t)
	fixture := writeFixtureFile(t, gcHome, "cache.db")

	var capturedDir string
	withRubyCmdFactory(t, func(ctx context.Context, command, fixtureDir string) *exec.Cmd {
		// Inspect the env we'd hand the subprocess.
		for _, e := range sanitizedEnv(fixtureDir) {
			if strings.HasPrefix(e, "GAMECHANGER_HOME=") {
				capturedDir = strings.TrimPrefix(e, "GAMECHANGER_HOME=")
			}
		}
		// Hand back a no-op helper so the rest of the flow doesn't fail.
		cmd := exec.CommandContext(ctx, os.Args[0], "-test.run=TestHelperProcess")
		cmd.Env = append(sanitizedEnv(fixtureDir),
			"GO_WANT_HELPER_PROCESS=1",
			"GO_HELPER_MODE=ok",
			`GO_HELPER_STDOUT=[]`,
		)
		return cmd
	})
	withGoRunner(t, "progress", func(ctx context.Context, dir string, season int) ([]byte, error) {
		return []byte(`[]`), nil
	})

	_, _, _ = runVerifyCapture(t, "progress", &verifyOpts{
		fixture: fixture, format: "human", rubyTimeout: 5 * time.Second,
	})
	// resolveFixturePath canonicalizes the fixture path via EvalSymlinks
	// (on macOS, /var/folders/... resolves to /private/var/folders/...).
	// Compare against the resolved form rather than the raw t.TempDir() path.
	expected, err := filepath.EvalSymlinks(gcHome)
	if err != nil {
		expected = gcHome
	}
	if capturedDir != expected {
		t.Fatalf("Ruby subprocess GAMECHANGER_HOME: got %q want %q", capturedDir, expected)
	}
}

// ─── runVerifyCapture is the test driver ─────────────────────────────────────
//
// Invokes runVerify with a captured stdout/stderr buffer pair, converts the
// returned error into an exit code via exitCodeFor, and returns
// (exitCode, stdoutString, stderrString).

func runVerifyCapture(t *testing.T, commandName string, vo *verifyOpts) (int, string, string) {
	t.Helper()
	var stdout, stderr bytes.Buffer
	err := runVerify(context.Background(), &stdout, io.MultiWriter(&stderr), commandName, vo)
	if err == nil {
		return 0, stdout.String(), stderr.String()
	}
	// runVerify's *parityExit with empty Msg has Error() == "". Mirror what
	// root.Execute does: append the message to stderr.
	if msg := err.Error(); msg != "" {
		fmt.Fprintln(&stderr, "gamechanger:", msg)
	}
	return exitCodeFor(err), stdout.String(), stderr.String()
}
