#!/bin/bash
# run-promo.sh — promotion batch runner.
# Settings come from GUI_* env vars when triggered via the web GUI;
# fall back to hardcoded defaults when triggered manually.

# --- defaults (used when no GUI_* override is present) ---
DEFAULT_ARTICLE="https://towardsdatascience.com/does-agentic-rag-actually-retrieve-better-evidence-i-tested-it-on-298-questions/"
DEFAULT_TRAFFIC="direct"
DEFAULT_BOUNCE="0.20"
DEFAULT_MOBILE="0.33"
DEFAULT_REGIONS="fra ewr sgp ams tor"
DEFAULT_ROUNDS="10"

# --- resolve settings ---
ARTICLE="${GUI_ARTICLE_URL:-$DEFAULT_ARTICLE}"
TRAFFIC="${GUI_TRAFFIC_SOURCE:-$DEFAULT_TRAFFIC}"
ROUNDS="${GUI_ROUNDS:-$DEFAULT_ROUNDS}"

export PROMO_REGIONS="${GUI_REGIONS:-$DEFAULT_REGIONS}"
export MOBILE_PCT="${GUI_MOBILE_PCT:-$DEFAULT_MOBILE}"
export BOUNCE_PCT="${GUI_BOUNCE_PCT:-$DEFAULT_BOUNCE}"

# handle traffic source
if [ "$TRAFFIC" = "google" ]; then
  export GOOGLE_MODE=1
  echo "Traffic source: Google"
elif echo "$ARTICLE" | grep -qE '(linkedin\.com|lnkd\.in)'; then
  echo "Traffic source: LinkedIn (detected from URL)"
else
  echo "Traffic source: direct"
fi

echo "Article:  $ARTICLE"
echo "Regions:  $PROMO_REGIONS"
echo "Rounds:   $ROUNDS"
echo "Bounce:   $BOUNCE_PCT  Mobile: $MOBILE_PCT"

HERE="$(cd "$(dirname "$0")" && pwd)"
ok_total=0
fail_total=0

for i in $(seq 1 $ROUNDS); do
  echo ""
  echo "=== Promo round $i / $ROUNDS ==="
  OUT=$("$HERE/run-test.sh" "$ARTICLE" 1 300 2>&1)
  echo "$OUT"
  ok=$(echo "$OUT"   | grep -oP '(?<=; )\d+(?= ran to the end)' | tail -1)
  fail=$(echo "$OUT" | grep -oP '\d+(?= failed)'                 | tail -1)
  ok_total=$(( ok_total + ${ok:-0} ))
  fail_total=$(( fail_total + ${fail:-0} ))
done

echo ""
echo "=== Promo batch complete: $ok_total readers ran to the end, $fail_total failed ==="
