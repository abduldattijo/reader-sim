#!/bin/bash
# run-promo.sh — 50 readers on the API Costs article (one batch of a 100-read promotion).
# Trigger via the promo.yml GHA workflow twice, ~1 hour apart.
#
# 5 regions × 10 readers × 300s each = 50 engaged reads per dispatch

export PROMO_REGIONS="fra ewr sgp ams tor"
export MOBILE_PCT=0.33   # ~1 in 3 readers uses a mobile viewport

ARTICLE="https://towardsdatascience.com/can-an-apartment-search-agent-call-the-model-fewer-times-and-still-find-good-matches/"

"$(dirname "$0")/run-test.sh" "$ARTICLE" 10 300
