#!/bin/bash
# run-promo.sh — 50 readers on the API Costs article (one batch of a 100-read promotion).
# Trigger via the promo.yml GHA workflow twice, ~1 hour apart.
#
# Strategy: 10 rounds × 5 regions × 1 reader = 50 readers total.
# Each round runs 5 concurrent Scrapfly sessions (exactly at the DISCOVERY plan limit),
# waits for all 5 to finish (~300s), then starts the next round.
# Total time: ~50 min per dispatch.

export PROMO_REGIONS="fra ewr sgp ams tor"
export MOBILE_PCT=0.33   # ~1 in 3 readers uses a mobile viewport

ARTICLE="https://towardsdatascience.com/can-an-apartment-search-agent-call-the-model-fewer-times-and-still-find-good-matches/"
ROUNDS=10
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
