package commands

import (
	"bufio"
	"context"
	"fmt"
	"io"
	"os"
	"strconv"
	"strings"

	"github.com/spf13/cobra"
	"golang.org/x/term"

	"github.com/joshrpowell/gamechanger-cli/internal/client"
	"github.com/joshrpowell/gamechanger-cli/internal/config"
	"github.com/joshrpowell/gamechanger-cli/internal/gcerr"
)

func newSetupCmd(opts *rootOpts) *cobra.Command {
	var (
		flagEmail    string
		flagPassword string
		flagTeamSlug string
	)
	cmd := &cobra.Command{
		Use:   "setup",
		Short: "Configure Gamechanger credentials and team",
		Args:  cobra.NoArgs,
		RunE: func(cmd *cobra.Command, _ []string) error {
			out := cmd.OutOrStdout()
			errOut := cmd.ErrOrStderr()

			fmt.Fprintln(out, "Gamechanger Setup")
			fmt.Fprintln(out, strings.Repeat("-", 40))

			email := resolveCredential(flagEmail, "GAMECHANGER_EMAIL")
			if email == "" {
				email = prompt(cmd.InOrStdin(), out, "Email: ")
			}
			password := resolveCredential(flagPassword, "GAMECHANGER_PASSWORD")
			if password == "" {
				password = readPassword(out, "Password: ")
			}
			if strings.TrimSpace(email) == "" || strings.TrimSpace(password) == "" {
				return gcerr.Configf("email and password are required")
			}

			dir, err := opts.configDirOrDefault()
			if err != nil {
				return err
			}
			cfg, err := config.LoadFrom(dir)
			if err != nil {
				return err
			}
			cfg.Email = email
			cfg.Password = password
			if err := cfg.Save(); err != nil {
				return err
			}

			fmt.Fprintln(errOut, "Authenticating...")
			cli := client.New(cfg)
			if _, err := cli.Authenticate(cmd.Context()); err != nil {
				return err
			}

			teamID, teamSlug, err := discoverTeam(cmd.Context(), cli, cmd.InOrStdin(), out,
				resolveCredential(flagTeamSlug, "GAMECHANGER_TEAM_SLUG"))
			if err != nil {
				// Non-fatal: print a hint and let the user finish manually.
				fmt.Fprintln(errOut, "warning:", err.Error())
				fmt.Fprintln(errOut,
					"You can add team_id and team_slug to ~/.gamechanger/config.yml manually.")
			}
			cfg.TeamID = teamID
			cfg.TeamSlug = teamSlug
			if err := cfg.Save(); err != nil {
				return err
			}

			fmt.Fprintln(out, "Configuration saved to", cfg.Dir()+"/config.yml")
			fmt.Fprintln(out, "Run `gamechanger refresh` to sync this season's data.")
			return nil
		},
	}
	cmd.Flags().StringVar(&flagEmail, "email", "", "Account email (or set $GAMECHANGER_EMAIL)")
	cmd.Flags().StringVar(&flagPassword, "password", "", "Account password (or set $GAMECHANGER_PASSWORD)")
	cmd.Flags().StringVar(&flagTeamSlug, "team-slug", "", "Team slug (or set $GAMECHANGER_TEAM_SLUG)")
	return cmd
}

func resolveCredential(flag, envVar string) string {
	if flag != "" {
		return flag
	}
	return os.Getenv(envVar)
}

func prompt(stdin io.Reader, out io.Writer, label string) string {
	fmt.Fprint(out, label)
	scanner := bufio.NewScanner(stdin)
	if !scanner.Scan() {
		return ""
	}
	return strings.TrimSpace(scanner.Text())
}

// readPassword turns off echo when reading from a TTY. Falls back to a
// regular Scanner read when stdin is not a TTY (CI, piped input).
func readPassword(out io.Writer, label string) string {
	fmt.Fprint(out, label)
	fd := int(os.Stdin.Fd())
	if term.IsTerminal(fd) {
		b, err := term.ReadPassword(fd)
		fmt.Fprintln(out) // newline after hidden input
		if err != nil {
			return ""
		}
		return strings.TrimSpace(string(b))
	}
	scanner := bufio.NewScanner(os.Stdin)
	if !scanner.Scan() {
		return ""
	}
	return strings.TrimSpace(scanner.Text())
}

// discoverTeam pulls /me/teams, returns the matching (team_id, team_slug)
// pair. If multiple teams exist, prompts the user. fallbackSlug is used
// when the response shape doesn't include a slug field.
func discoverTeam(ctx context.Context, cli *client.Client, stdin io.Reader, out io.Writer, fallbackSlug string) (string, string, error) {
	raw, err := cli.Teams(ctx)
	if err != nil {
		return "", "", err
	}
	teams := extractTeamsList(raw)
	switch len(teams) {
	case 0:
		fmt.Fprintln(out, "No teams found for this account.")
		return "", fallbackSlug, nil
	case 1:
		t := teams[0]
		name, _ := t["name"].(string)
		id, _ := t["id"].(string)
		slug := teamSlugFrom(t, fallbackSlug)
		fmt.Fprintf(out, "Team: %s (%s)\n", name, id)
		return id, slug, nil
	default:
		fmt.Fprintln(out, "Multiple teams found:")
		for i, t := range teams {
			name, _ := t["name"].(string)
			id, _ := t["id"].(string)
			fmt.Fprintf(out, "  %d. %s (%s)\n", i+1, name, id)
		}
		raw := prompt(stdin, out, "Which team? (enter number): ")
		idx, _ := strconv.Atoi(raw)
		if idx < 1 || idx > len(teams) {
			return "", fallbackSlug, gcerr.Configf("invalid team selection: %q", raw)
		}
		t := teams[idx-1]
		id, _ := t["id"].(string)
		return id, teamSlugFrom(t, fallbackSlug), nil
	}
}

// extractTeamsList accepts either a bare array or a wrapped object.
func extractTeamsList(raw any) []map[string]any {
	var items []any
	switch v := raw.(type) {
	case []any:
		items = v
	case map[string]any:
		for _, key := range []string{"teams", "data"} {
			if list, ok := v[key].([]any); ok {
				items = list
				break
			}
		}
	}
	out := make([]map[string]any, 0, len(items))
	for _, it := range items {
		if m, ok := it.(map[string]any); ok {
			out = append(out, m)
		}
	}
	return out
}

func teamSlugFrom(t map[string]any, fallback string) string {
	if s, _ := t["slug"].(string); s != "" {
		return s
	}
	if s, _ := t["short_id"].(string); s != "" {
		return s
	}
	return fallback
}
