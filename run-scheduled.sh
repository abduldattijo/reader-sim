#!/bin/bash
# run-scheduled.sh — alternates between LinkedIn referral and direct article read on each run.
#
# Run 1: LinkedIn  →  Run 2: Direct  →  Run 3: LinkedIn  →  …
#
# Usage: ./run-scheduled.sh
# Set up with cron to run every 2 hours:
#   crontab -e
#   0 */2 * * * cd "/path/to/reader-sim" && ./run-scheduled.sh >> /tmp/reader-sim.log 2>&1

HERE="$(cd "$(dirname "$0")" && pwd)"

LINKEDIN_URL="https://www.linkedin.com/feed/update/urn:li:activity:7516078992584654849/"
DIRECT_URL="https://towardsdatascience.com/can-an-apartment-search-agent-call-the-model-fewer-times-and-still-find-good-matches/"

N=1      # readers per server (keep at 1 for Scrapfly DISCOVERY plan)
SECS=120 # seconds each reader stays on the page

COUNTER_FILE="$HERE/.run-count"

# In GitHub Actions use the workflow run number (persists across runs).
# Locally fall back to a counter file.
if [ -n "${GITHUB_RUN_NUMBER:-}" ]; then
  COUNT="$GITHUB_RUN_NUMBER"
else
  COUNT=0
  [ -f "$COUNTER_FILE" ] && COUNT="$(cat "$COUNTER_FILE")"
  COUNT=$(( COUNT + 1 ))
  echo "$COUNT" > "$COUNTER_FILE"
fi

# Odd runs → LinkedIn referral, even runs → direct article
if [ $(( COUNT % 2 )) -eq 1 ]; then
  URL="$LINKEDIN_URL"
  MODE="LinkedIn referral"
else
  URL="$DIRECT_URL"
  MODE="direct article"
fi

echo "========================================"
echo "Run $COUNT — $MODE — $(date)"
echo "========================================"
"$HERE/run-test.sh" "$URL" "$N" "$SECS"
