// Package format hosts output renderers shared across commands. scout.go is
// the matchup-history renderer (U7, Fork A) — TTY-aware (colored at terminal,
// plain when piped) plus a JSON encoder for AI/agent pipelines.
package format

import (
	"encoding/json"
	"fmt"
	"io"
	"strings"

	"github.com/joshrpowell/gamechanger-cli/internal/scout"
)

// Plain text cap (AE3) — output must be ≤500 chars and ANSI-free when piped
// so paste into Messages renders cleanly. Hard cap, the renderer truncates
// games before exceeding this.
const plainTextMaxBytes = 500

// ScoutContext is the renderer's input — wraps scout.MatchupHistory with a
// FormatHint set by the command layer's TTY detection.
type ScoutContext struct {
	History *scout.MatchupHistory
	IsTTY   bool // true → terminal-pretty; false → plain text
}

// Scout renders the matchup history. format must be "human" or "json".
// For "human" output: when ctx.IsTTY is true the output uses ANSI color +
// borders; when false it stays plain and capped to plainTextMaxBytes for
// paste-into-Messages friendliness.
func Scout(w io.Writer, ctx ScoutContext, format string) error {
	if ctx.History == nil {
		return fmt.Errorf("format.Scout: nil history")
	}
	switch format {
	case "json":
		enc := json.NewEncoder(w)
		enc.SetIndent("", "  ")
		return enc.Encode(ctx.History)
	case "", "human":
		if ctx.IsTTY {
			return renderTerminalPretty(w, ctx.History)
		}
		return renderPlain(w, ctx.History)
	default:
		return fmt.Errorf("format.Scout: unknown format %q (expected human | json)", format)
	}
}

// renderPlain produces paste-friendly text capped at plainTextMaxBytes. The
// header line plus enough games to fit the budget; older games dropped first.
//
// Example output:
//
//	Matchup vs Eagles 12U (4 games)
//	2026-04-15  home  L 4-7
//	2026-03-22  away  W 8-3
//	2026-02-08  away  W 6-5
//	2025-11-12  home  L 2-9
func renderPlain(w io.Writer, h *scout.MatchupHistory) error {
	var b strings.Builder
	fmt.Fprintf(&b, "Matchup vs %s (%d game", h.Opponent.Name, len(h.Games))
	if len(h.Games) != 1 {
		b.WriteString("s")
	}
	b.WriteString(")\n")

	// Build game lines, trimming oldest first if total exceeds the cap.
	type line struct{ s string }
	lines := make([]line, 0, len(h.Games))
	for _, g := range h.Games {
		s := fmt.Sprintf("%s  %-4s  %s %d-%d\n", g.Date, g.HomeAway, g.Outcome, g.OwningScore, g.OpponentScore)
		lines = append(lines, line{s})
	}
	// Trim from the end (oldest games) until everything fits.
	for {
		total := b.Len()
		for _, ln := range lines {
			total += len(ln.s)
		}
		if total <= plainTextMaxBytes || len(lines) == 0 {
			break
		}
		lines = lines[:len(lines)-1]
	}
	for _, ln := range lines {
		b.WriteString(ln.s)
	}
	_, err := io.WriteString(w, b.String())
	return err
}

// renderTerminalPretty produces a colored, structured output for interactive
// terminal use. Keeps the same data as plain mode but with visual structure.
// ANSI codes are minimal so the output also reads cleanly in terminals
// without color support.
func renderTerminalPretty(w io.Writer, h *scout.MatchupHistory) error {
	const (
		bold   = "\033[1m"
		green  = "\033[32m"
		red    = "\033[31m"
		yellow = "\033[33m"
		dim    = "\033[2m"
		reset  = "\033[0m"
	)
	var b strings.Builder
	fmt.Fprintf(&b, "%sMatchup vs %s%s  %s(%d games)%s\n",
		bold, h.Opponent.Name, reset, dim, len(h.Games), reset)
	for _, g := range h.Games {
		color := dim
		switch g.Outcome {
		case "W":
			color = green
		case "L":
			color = red
		case "T":
			color = yellow
		}
		fmt.Fprintf(&b, "  %s  %-4s  %s%s%s  %d-%d\n",
			g.Date, g.HomeAway, color, displayOutcome(g.Outcome), reset, g.OwningScore, g.OpponentScore)
	}
	if len(h.Games) == 0 {
		fmt.Fprintf(&b, "  %s(no games against this opponent yet)%s\n", dim, reset)
	}
	_, err := io.WriteString(w, b.String())
	return err
}

// displayOutcome maps W/L/T to a fixed-width display token so the columns
// line up. Empty outcome (in-progress games) becomes a bullet.
func displayOutcome(o string) string {
	switch o {
	case "":
		return "·"
	default:
		return o
	}
}
