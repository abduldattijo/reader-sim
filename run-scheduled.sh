#!/bin/bash
# run-scheduled.sh — cycles through LinkedIn referral, direct read, and Google referral.
#
# Run 1: LinkedIn  →  Run 2: direct  →  Run 3: Google  →  Run 4: LinkedIn  →  …
#
# Usage: ./run-scheduled.sh

HERE="$(cd "$(dirname "$0")" && pwd)"

# Target lists come from newline-separated env vars (set from repo variables, not stored in the repo).
LINKEDIN_POSTS=()
while IFS= read -r l; do [ -n "$l" ] && LINKEDIN_POSTS+=("$l"); done <<< "${SCHEDULE_LINKEDIN:-}"
ARTICLES=()
while IFS= read -r l; do [ -n "$l" ] && ARTICLES+=("$l"); done <<< "${SCHEDULE_ARTICLES:-}"
if [ "${#ARTICLES[@]}" -eq 0 ] || [ "${#LINKEDIN_POSTS[@]}" -eq 0 ]; then
  echo "No scheduled targets configured"; exit 1
fi

N=1      # readers per server (keep at 1 for Scrapfly DISCOVERY plan)
SECS=400 # seconds each reader stays on the page (6.7 min; ~200s buffer under Scrapfly's ~600s limit)

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
