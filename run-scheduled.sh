#!/bin/bash
# run-scheduled.sh — cycles through LinkedIn referral, direct read, and Google referral.
#
# Run 1: LinkedIn  →  Run 2: direct  →  Run 3: Google  →  Run 4: LinkedIn  →  …
#
# Usage: ./run-scheduled.sh

HERE="$(cd "$(dirname "$0")" && pwd)"

# LinkedIn posts — alternate between them across LinkedIn runs.
LINKEDIN_POSTS=(
  "https://www.linkedin.com/feed/update/urn:li:activity:7516078992584654849/"
  "https://www.linkedin.com/feed/update/urn:li:activity:7516490904891809792/"
  "https://www.linkedin.com/feed/update/urn:li:activity:7516580559108612098/"
)

# TDS articles — rotate across direct and Google runs. Add new articles here.
ARTICLES=(
  "https://towardsdatascience.com/can-an-apartment-search-agent-call-the-model-fewer-times-and-still-find-good-matches/"
  "https://towardsdatascience.com/ai-slop-is-now-in-your-training-dataset-i-tested-three-ways-to-spot-it/"
  "https://towardsdatascience.com/i-tested-four-ways-to-give-an-ai-assistant-a-memory-the-obvious-one-was-the-worst-value/"
  "https://towardsdatascience.com/i-built-a-trap-for-ai-image-judges-they-walked-into-a-different-one/"
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

NARTICLES="${#ARTICLES[@]}"
NLI="${#LINKEDIN_POSTS[@]}"
# Which article/post index for this run (advances every 3 runs)
IDX=$(( ((COUNT - 1) / 3) % NARTICLES ))

# 3-cycle: LinkedIn → direct → Google referral
GOOGLE_MODE=0
case $(( ((COUNT - 1) % 3) + 1 )) in
  1) LI_IDX=$(( ((COUNT - 1) / 3) % NLI ))
     URL="${LINKEDIN_POSTS[$LI_IDX]}"
     MODE="LinkedIn referral"
     SECOND_URL="${ARTICLES[$IDX]}"
     ;;
  2) URL="${ARTICLES[$IDX]}"
     MODE="direct article"
     SECOND_URL="${ARTICLES[$(( (IDX + 1) % NARTICLES ))]}"
     ;;
  3) URL="${ARTICLES[$IDX]}"
     MODE="Google referral"
     GOOGLE_MODE=1
     SECOND_URL="${ARTICLES[$(( (IDX + 1) % NARTICLES ))]}"
     ;;
esac

export GOOGLE_MODE
export MOBILE_PCT=0.33   # ~1 in 3 readers uses a mobile viewport
export SECOND_URL        # ~35% of full readers navigate to this article after the main one

echo "========================================"
echo "Run $COUNT — $MODE — $(date)"
echo "2nd article: $SECOND_URL"
echo "========================================"
"$HERE/run-test.sh" "$URL" "$N" "$SECS"
