#!/usr/bin/env bash
set -euo pipefail

# Fast syntax check before running suite
ruby -c lib/gamechanger/**/*.rb spec/**/*.rb > /dev/null 2>&1 || true

# Run rspec and capture coverage output
OUTPUT=$(bundle exec rspec --format progress 2>&1)
echo "$OUTPUT"

# Parse SimpleCov line coverage from output
LINE_PCT=$(echo "$OUTPUT" | grep "Line Coverage:" | grep -oE '[0-9]+\.[0-9]+%' | head -1 | tr -d '%')
BRANCH_PCT=$(echo "$OUTPUT" | grep "Branch Coverage:" | grep -oE '[0-9]+\.[0-9]+%' | head -1 | tr -d '%')

if [ -n "$LINE_PCT" ]; then
  echo "METRIC line_coverage=$LINE_PCT"
else
  echo "METRIC line_coverage=0"
fi

if [ -n "$BRANCH_PCT" ]; then
  echo "METRIC branch_coverage=$BRANCH_PCT"
else
  echo "METRIC branch_coverage=0"
fi

# Also output failures count
FAILURES=$(echo "$OUTPUT" | grep -oE '[0-9]+ failures?' | grep -oE '[0-9]+' | head -1 || echo "0")
echo "METRIC test_failures=$FAILURES"
