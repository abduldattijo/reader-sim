#!/bin/bash
# run-scrapfly.sh: run simulated readers in Scrapfly Cloud Browsers (no Vultr servers).
#
# usage: ./run-scrapfly.sh <url> <readers> [seconds] [--dry-run] [--yes]
#   ./run-scrapfly.sh https://usehomesteados.com/pricing 5
#   ./run-scrapfly.sh https://usehomesteados.com/pricing 10 120 --dry-run
#
# Needs: the line "scrapfly api key: ..." in ../local-secrets/api keys.md
#        (or the SCRAPFLY_API_KEY env var).
# Optional env:
#   SCRAPFLY_COUNTRY=us            exit country (default us)
#   SCRAPFLY_PROXY_POOL=residential|datacenter   (default residential)
#   SCRAPFLY_CONCURRENCY=5         readers at the same time (default: your plan's limit)
#   CLICK_LINK_PROB=0.3            chance a reader clicks one internal link (default 0)
# Readers are run in waves of SCRAPFLY_CONCURRENCY. More than 20 readers needs --yes.
set -u

HERE="$(cd "$(dirname "$0")" && pwd)"
URL="${1:?usage: run-scrapfly.sh <url> <readers> [seconds] [--dry-run] [--yes]}"
N="${2:?number of readers}"
SECS="${3:-70}"
DRY=0; YES=0
for a in "$@"; do [ "$a" = "--dry-run" ] && DRY=1; [ "$a" = "--yes" ] && YES=1; done
case "$SECS" in --*) SECS=70;; esac
SECRETS="$HERE/../local-secrets/api keys.md"

[ "$N" -ge 1 ] 2>/dev/null || { echo "readers must be a number of 1 or more"; exit 1; }

KEY="${SCRAPFLY_API_KEY:-}"
if [ -z "$KEY" ] && [ -f "$SECRETS" ]; then
  KEY="$(grep -i '^scrapfly api key:' "$SECRETS" | head -1 | sed -E 's/^[^:]*:[[:space:]]*//' | tr -d '[:space:]')"
fi
[ -n "$KEY" ] || { echo "No Scrapfly key found (set SCRAPFLY_API_KEY or add 'scrapfly api key: ...' to $SECRETS)"; exit 1; }

POOL="${SCRAPFLY_PROXY_POOL:-residential}"
COUNTRY="${SCRAPFLY_COUNTRY:-us}"
CLICK="${CLICK_LINK_PROB:-0}"

# ---- account (read-only; the key is never printed) --------------------------------
acct() { curl -sS --max-time 30 "https://api.scrapfly.io/account?key=$KEY" 2>/dev/null; }
field() { python3 -c "
import sys,json
try: d=json.load(sys.stdin)
except Exception: print(''); sys.exit()
x=d
for k in '$1'.split('.'):
    x=x.get(k) if isinstance(x,dict) else None
print('' if x is None else x)"; }

A0="$(acct)"
PLAN="$(echo "$A0" | field subscription.plan_name)"
MAXC="$(echo "$A0" | field subscription.max_concurrency)"
REM0="$(echo "$A0" | field subscription.usage.scrape.remaining)"
[ -n "$PLAN" ] || { echo "Could not read the Scrapfly account (bad key?)"; exit 1; }
CONC="${SCRAPFLY_CONCURRENCY:-${MAXC:-5}}"
[ -n "$MAXC" ] && [ "$CONC" -gt "$MAXC" ] && CONC="$MAXC"

# rough cost: measured 430 credits per residential reader (about 7 MB at 52 credits/MB, plus time)
if [ "$POOL" = "residential" ]; then PER=430; else PER=70; fi
EST=$(( N * PER ))
WAVES=$(( (N + CONC - 1) / CONC ))

echo "Scrapfly account: plan $PLAN, credits remaining $REM0, concurrent sessions $MAXC"
echo "Plan: $N readers in $WAVES wave(s) of up to $CONC, ${SECS}s each, $POOL IPs, country $COUNTRY"
echo "Target: $URL (link-click chance $CLICK)"
echo "Estimated credits: about $EST (about 7 MB per reader; check the dashboard for the real figure)"
if [ "$DRY" -eq 1 ]; then echo; echo "Dry run: nothing started."; exit 0; fi
if [ "$N" -gt 20 ] && [ "$YES" -ne 1 ]; then echo "More than 20 readers: add --yes to confirm."; exit 1; fi

# ---- run in waves ---------------------------------------------------------------
OUT="$(mktemp -d)"
trap 'rm -rf "$OUT"' EXIT
date -u +"start %H:%M:%S UTC"
LEFT="$N"; W=0
while [ "$LEFT" -gt 0 ]; do
  W=$(( W + 1 ))
  K="$CONC"; [ "$LEFT" -lt "$K" ] && K="$LEFT"
  echo "wave $W: $K reader(s)..."
  SCRAPFLY_API_KEY="$KEY" SCRAPFLY_PROXY_POOL="$POOL" SCRAPFLY_COUNTRY="$COUNTRY" \
    NO_AUTOMATION_FLAG=1 CLICK_LINK_PROB="$CLICK" \
    node "$HERE/reader.js" "$URL" "scrapfly-w$W" "$K" "$SECS" 2>&1 | sed "s/$KEY/<redacted>/g" > "$OUT/w$W.out"
  LEFT=$(( LEFT - K ))
done
date -u +"end   %H:%M:%S UTC"

# ---- summary --------------------------------------------------------------------
N_EXPECTED="$N" python3 - "$OUT" <<'PY'
import sys, json, os, glob
rows, other = [], []
for f in sorted(glob.glob(os.path.join(sys.argv[1], "w*.out"))):
    for l in open(f):
        l = l.rstrip("\n")
        if l.startswith("{"): rows.append(json.loads(l))
        elif l.strip(): other.append(l.strip())
exp = int(os.environ["N_EXPECTED"])
good = [x for x in rows if x["status"] == "ok"]
reached = [x for x in rows if x.get("reached", True)]
clicks = [x for x in rows if x.get("clicked") and x["clicked"] not in ("click-failed", "no-link-found")]
sent = sum(1 for x in rows if "POST /__l5e/trackevents" in x["tracked"])
print(f"{len(reached)}/{exp} reached the real page, {len(good)}/{exp} ran to the end, event sent by {sent}, {len(clicks)} clicked a link")
ends = {}
for x in rows: ends[x.get("finalPath")] = ends.get(x.get("finalPath"), 0) + 1
print("final pages:", ", ".join(f"{p} x{c}" for p, c in sorted(ends.items(), key=lambda t: -t[1])))
reasons = []
for x in rows:
    if x["status"] != "ok": reasons.append(f"  reader {x['label']}#{x['reader']}: failed after {x['seconds']}s - {x['status']}")
    elif not x.get("reached", True): reasons.append(f"  reader {x['label']}#{x['reader']}: did not reach the page - {x.get('notReached')}")
missing = exp - len(rows)
if missing > 0: reasons.append(f"  {missing} reader(s) gave no result - " + ("; ".join(other[:3])[:300] or "no output"))
if reasons:
    print("Failure reasons:"); [print(r) for r in reasons]
PY

# ---- credits used (account counters can lag a little) ------------------------------
sleep 5
A1="$(acct)"
REM1="$(echo "$A1" | field subscription.usage.scrape.remaining)"
if [ -n "$REM0" ] && [ -n "$REM1" ]; then
  echo "Credits remaining: $REM0 -> $REM1 (used $(( REM0 - REM1 )); the counter can lag, check the dashboard)"
fi
