package commands

import (
	"bufio"
	"encoding/base64"
	"encoding/json"
	"fmt"
	"io"
	"strings"
	"time"

	"github.com/spf13/cobra"

	"github.com/joshrpowell/gamechanger-cli/internal/gcerr"
)

// jwtPayload extracts the fields we care about. The CLI never verifies
// the signature — we trust the server to do that when we use the token.
type jwtPayload struct {
	Type   string `json:"type"`
	Email  string `json:"email"`
	UserID string `json:"userId"`
	Iat    int64  `json:"iat"`
	Exp    int64  `json:"exp"`
}

func newAuthCmd(opts *rootOpts) *cobra.Command {
	cmd := &cobra.Command{
		Use:   "auth",
		Short: "Manage Gamechanger authentication state",
	}
	cmd.AddCommand(newAuthImportCmd(opts))
	cmd.AddCommand(newAuthStatusCmd(opts))
	return cmd
}

func newAuthImportCmd(opts *rootOpts) *cobra.Command {
	var (
		flagToken    string
		flagFromFile string
	)
	cmd := &cobra.Command{
		Use:   "import",
		Short: "Import a gc-token JWT captured from web.gc.com",
		Long: `Import a session token captured from your logged-in browser session.

Workflow:
  1. Open https://web.gc.com in a browser and log in (handles MFA).
  2. Open DevTools → Network tab, click any request to api.team-manager.gc.com.
  3. Copy the 'gc-token' request header value.
  4. Run: gamechanger auth import --token <paste-here>

The token typically expires after 1 hour. Re-run when it expires.`,
		Args: cobra.NoArgs,
		RunE: func(cmd *cobra.Command, _ []string) error {
			token, err := readToken(cmd.InOrStdin(), flagToken, flagFromFile)
			if err != nil {
				return err
			}
			payload, err := parseJWT(token)
			if err != nil {
				return err
			}

			cfg, err := opts.loadConfig()
			if err != nil {
				return err
			}
			if err := cfg.CacheToken(token, payload.Exp); err != nil {
				return err
			}

			out := cmd.OutOrStdout()
			fmt.Fprintln(out, "Token imported.")
			if payload.Email != "" {
				fmt.Fprintln(out, "  Account:", payload.Email)
			}
			if payload.Exp > 0 {
				remaining := time.Until(time.Unix(payload.Exp, 0))
				fmt.Fprintf(out, "  Expires: %s (%s from now)\n",
					time.Unix(payload.Exp, 0).Local().Format(time.RFC3339),
					remaining.Round(time.Second))
			}
			return nil
		},
	}
	cmd.Flags().StringVar(&flagToken, "token", "",
		"JWT to import. If empty, reads from stdin or --from-file.")
	cmd.Flags().StringVar(&flagFromFile, "from-file", "",
		"Read the JWT from this file path. Useful for keeping the token out of shell history.")
	return cmd
}

func newAuthStatusCmd(opts *rootOpts) *cobra.Command {
	return &cobra.Command{
		Use:   "status",
		Short: "Show whether a valid token is cached",
		Args:  cobra.NoArgs,
		RunE: func(cmd *cobra.Command, _ []string) error {
			cfg, err := opts.loadConfig()
			if err != nil {
				return err
			}
			out := cmd.OutOrStdout()
			token := cfg.CachedToken()
			if token == "" {
				fmt.Fprintln(out, "No valid token cached. Run `gamechanger auth import` to add one.")
				return nil
			}
			payload, err := parseJWT(token)
			if err != nil {
				// Token is cached but unparseable — surface a warning, don't error out.
				fmt.Fprintln(out, "Token cached but could not parse payload:", err)
				return nil
			}
			fmt.Fprintln(out, "Token cached.")
			if payload.Email != "" {
				fmt.Fprintln(out, "  Account:", payload.Email)
			}
			if payload.Exp > 0 {
				remaining := time.Until(time.Unix(payload.Exp, 0))
				fmt.Fprintf(out, "  Expires: %s (%s from now)\n",
					time.Unix(payload.Exp, 0).Local().Format(time.RFC3339),
					remaining.Round(time.Second))
			}
			return nil
		},
	}
}

// readToken resolves the token from --token, --from-file, or stdin in that
// priority order. Returns an error if none of those produce a non-empty
// string.
func readToken(stdin io.Reader, flagToken, flagFromFile string) (string, error) {
	if flagToken != "" {
		return strings.TrimSpace(flagToken), nil
	}
	if flagFromFile != "" {
		data, err := readAllFile(flagFromFile)
		if err != nil {
			return "", gcerr.Configf("read --from-file %s: %v", flagFromFile, err)
		}
		return strings.TrimSpace(string(data)), nil
	}
	scanner := bufio.NewScanner(stdin)
	// Long tokens can exceed Scanner's default 64KB buffer; raise it.
	scanner.Buffer(make([]byte, 0, 64*1024), 1024*1024)
	if !scanner.Scan() {
		return "", gcerr.Configf("no token provided (use --token, --from-file, or pipe via stdin)")
	}
	token := strings.TrimSpace(scanner.Text())
	if token == "" {
		return "", gcerr.Configf("empty token")
	}
	return token, nil
}

// parseJWT splits a JWT and decodes the middle (payload) segment.
// Signature verification is intentionally NOT performed — the CLI is a
// dumb relay of credentials the server later validates.
func parseJWT(token string) (jwtPayload, error) {
	parts := strings.Split(token, ".")
	if len(parts) != 3 {
		return jwtPayload{}, gcerr.Configf("invalid JWT shape: expected 3 dot-separated parts, got %d", len(parts))
	}
	raw, err := base64.RawURLEncoding.DecodeString(parts[1])
	if err != nil {
		// Some encoders include padding; try the padded form as a fallback.
		raw, err = base64.URLEncoding.DecodeString(parts[1])
		if err != nil {
			return jwtPayload{}, gcerr.Configf("decode JWT payload: %v", err)
		}
	}
	var p jwtPayload
	if err := json.Unmarshal(raw, &p); err != nil {
		return jwtPayload{}, gcerr.Configf("parse JWT payload JSON: %v", err)
	}
	if p.Exp > 0 && time.Now().Unix() > p.Exp {
		return jwtPayload{}, gcerr.Authf("token is already expired (exp=%d, now=%d)", p.Exp, time.Now().Unix())
	}
	return p, nil
}

// readAllFile reads the entire contents of a file. Inline rather than
// adding an os import at the top — keeps file-reading scoped to the one
// caller that needs it.
func readAllFile(path string) ([]byte, error) {
	return readFile(path)
}
