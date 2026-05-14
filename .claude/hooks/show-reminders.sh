#!/usr/bin/env bash
# Project SessionStart hook: print every Markdown file in .claude/reminders/.
#
# Add reminders by dropping a .md file into .claude/reminders/.
# Remove a reminder by deleting its file.
# The hook never errors out — missing directory or empty directory exits silently.

set -u

DIR="$(cd "$(dirname "$0")"/.. && pwd)/reminders"

if [ ! -d "$DIR" ]; then
  exit 0
fi

found=0
for f in "$DIR"/*.md; do
  [ -e "$f" ] || continue  # no files matched
  if [ "$found" -eq 0 ]; then
    echo ""
    echo "═══════════════════════════════════════════════════════════════"
    echo "  Project reminders (from .claude/reminders/)"
    echo "═══════════════════════════════════════════════════════════════"
    found=1
  fi
  echo ""
  echo "── $(basename "$f" .md) ──"
  cat "$f"
done

if [ "$found" -eq 1 ]; then
  echo ""
  echo "═══════════════════════════════════════════════════════════════"
  echo ""
fi

exit 0
