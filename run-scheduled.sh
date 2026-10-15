#!/bin/bash
# run-scheduled.sh — cycles through LinkedIn referral, direct read, and Google referral.
#
# Run 1: LinkedIn  →  Run 2: direct  →  Run 3: Google  →  Run 4: LinkedIn  →  …
#
# Usage: ./run-scheduled.sh
# Set up with cron to run every 2 hours:
#   crontab -e
#   0 */2 * * * cd "/path/to/reader-sim" && ./run-scheduled.sh >> /tmp/reader-sim.log 2>&1

HERE="$(cd "$(dirname "$0")" && pwd)"

LINKEDIN_URL="https://www.linkedin.com/feed/update/urn:li:activity:7516078992584654849/"

# Articles to rotate across direct and Google referral runs (add new articles here).
ARTICLES=(
  "https://towardsdatascience.com/can-an-apartment-search-agent-call-the-model-fewer-times-and-still-find-good-matches/"
  "https://towardsdatascience.com/ai-slop-is-now-in-your-training-dataset-i-tested-three-ways-to-spot-it/"
)

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

# Pick article for this run (rotates every 3 runs through the array).
NARTICLES="${#ARTICLES[@]}"
ARTICLE_IDX=$(( ((COUNT - 1) / 3) % NARTICLES ))
ARTICLE="${ARTICLES[$ARTICLE_IDX]}"

# 3-cycle: LinkedIn → direct → Google referral
GOOGLE_MODE=0
case $(( ((COUNT - 1) % 3) + 1 )) in
  1) URL="$LINKEDIN_URL"; MODE="LinkedIn referral" ;;
  2) URL="$ARTICLE";      MODE="direct article" ;;
  3) URL="$ARTICLE";      MODE="Google referral"; GOOGLE_MODE=1 ;;
esac

export GOOGLE_MODE
export MOBILE_PCT=0.33   # ~1 in 3 readers uses a mobile viewport

echo "========================================"
echo "Run $COUNT — $MODE — $(date)"
echo "========================================"
"$HERE/run-test.sh" "$URL" "$N" "$SECS"
