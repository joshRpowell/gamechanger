#!/usr/bin/env bash
set -euo pipefail

# Fast syntax pre-check (non-fatal)
ruby -c lib/gamechanger/**/*.rb spec/**/*.rb > /dev/null 2>&1 || true

# Measure wall-clock time for dev-mode run (no SimpleCov)
START=$(ruby -e 'print (Time.now.to_f * 1000000000).to_i')
OUTPUT=$(bundle exec rspec --format progress 2>&1)
EXIT_CODE=$?
END=$(ruby -e 'print (Time.now.to_f * 1000000000).to_i')

DURATION=$(ruby -e "printf('%.3f', ($END.0 - $START.0) / 1000000000.0)")

# Parse failure count
FAILURES=$(echo "$OUTPUT" | grep -oE '[0-9]+ failures?' | grep -oE '^[0-9]+' | head -1 || echo "0")

echo "$OUTPUT"
echo "METRIC time_seconds=$DURATION"
echo "METRIC test_failures=$FAILURES"
exit $EXIT_CODE
