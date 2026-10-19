#!/bin/bash
# run-test.sh: create 3 Vultr servers, run simulated readers from each, then destroy them.
#
# usage: ./run-test.sh <url> <readers-per-server> [seconds] [--dry-run]
#   ./run-test.sh https://usehomesteados.com/pricing 5
#   ./run-test.sh https://usehomesteados.com/ 5 70 --dry-run     (checks key + lookups, creates nothing)
#
# Needs: the Vultr API key (line "vultr api key: ..." in ../local-secrets/api keys.md,
#        or the VULTR_API_KEY env var), the "reader-sim" SSH key and the
#        "reader-install" startup script already added in Vultr.
# Optional: USE_PROXY=1 routes each server's browser through a residential proxy in that
#   server's country (fra->de, ewr->us, jnb->za). PROXY_PROVIDER=dataimpulse (default) or decodo.
#   Needs "<provider> login: ...", "<provider> password: ..." (and optionally "<provider> host:",
#   "<provider> port:") in ../local-secrets/api keys.md. Uses proxy traffic (GB).
#   USE_PROXY=1 ./run-test.sh https://usehomesteados.com/pricing 5
#   USE_PROXY=1 PROXY_PROVIDER=decodo ./run-test.sh https://usehomesteados.com/pricing 5
# Servers are always destroyed on exit (success, error or Ctrl-C).
set -u

HERE="$(cd "$(dirname "$0")" && pwd)"
URL="${1:?usage: run-test.sh <url> <readers-per-server> [seconds] [--dry-run]}"
N="${2:?readers per server}"
SECS="${3:-70}"
DRY=0
for a in "$@"; do [ "$a" = "--dry-run" ] && DRY=1; done
[ "$SECS" = "--dry-run" ] && SECS=70

# Auto-detect social post URLs (LinkedIn, X/Twitter) → enable social click-through mode.
SOCIAL_MODE=0
if echo "$URL" | grep -qE '(linkedin\.com|lnkd\.in|twitter\.com|x\.com)'; then
  SOCIAL_MODE=1
fi

REGIONS=(fra ewr)     # Frankfurt, New Jersey — 2 regions to stay within Scrapfly 200k/month limit
PLAN="vc2-1c-2gb"                 # 1 vCPU, 2 GB RAM
OS_NAME="Ubuntu 24.04 LTS x64"
SSH_KEY_NAME="reader-sim"
SCRIPT_NAME="reader-install"
LABEL_PREFIX="reader-run"
KEYFILE="$HOME/.ssh/vultr_reader_ed25519"
SECRETS="$HERE/../local-secrets/api keys.md"
SNAPSHOT_FILE="$HERE/.snapshot-id"
# If a pre-baked snapshot exists (run bake-snapshot.sh once to create it),
# boot from it — no startup script needed, ready in ~30s instead of 5-8 min.
SNAP_ID=""
[ -f "$SNAPSHOT_FILE" ] && SNAP_ID="$(cat "$SNAPSHOT_FILE" | tr -d '[:space:]')"
MAX_READY_WAIT=$([ -n "$SNAP_ID" ] && echo 120 || echo 900)

[ "$N" -ge 1 ] 2>/dev/null && [ "$N" -le 10 ] || { echo "readers per server must be 1..10"; exit 1; }

# ---- API key (never printed) ------------------------------------------------
KEY="${VULTR_API_KEY:-}"
if [ -z "$KEY" ] && [ -f "$SECRETS" ]; then
  KEY="$(grep -i '^vultr api key:' "$SECRETS" | head -1 | sed -E 's/^[^:]*:[[:space:]]*//' | tr -d '[:space:]')"
fi
[ -n "$KEY" ] || { echo "No Vultr API key found (set VULTR_API_KEY or add 'vultr api key: ...' to $SECRETS)"; exit 1; }

# ---- optional DataImpulse proxy (credentials never printed) ----------------------
cc_for() { case "$1" in fra) echo de;; ewr) echo us;; sgp) echo sg;; lax) echo us;; ams) echo nl;; *) echo us;; esac; }
PROXY_ON=0
PROXY_PROVIDER="${PROXY_PROVIDER:-dataimpulse}"   # dataimpulse | decodo
if [ "${USE_PROXY:-0}" = "1" ]; then
  px() { grep -i "^$PROXY_PROVIDER $1:" "$SECRETS" 2>/dev/null | head -1 | sed -E 's/^[^:]*:[[:space:]]*//' | tr -d '[:space:]'; }
  case "$PROXY_PROVIDER" in
    dataimpulse) DEF_HOST=gw.dataimpulse.com; DEF_PORT=823;  PREFIX=DATAIMPULSE ;;
    decodo)      DEF_HOST=gate.decodo.com;    DEF_PORT=7000; PREFIX=DECODO ;;
    *) echo "PROXY_PROVIDER must be dataimpulse or decodo"; exit 1 ;;
  esac
  PX_HOST="$(px host)"; PX_PORT="$(px port)"; PX_LOGIN="$(px login)"; PX_PASS="$(px password)"
  [ -n "$PX_LOGIN" ] && [ -n "$PX_PASS" ] || { echo "USE_PROXY=1 but '$PROXY_PROVIDER login/password' not found in $SECRETS"; exit 1; }
  PX_HOST="${PX_HOST:-$DEF_HOST}"; PX_PORT="${PX_PORT:-$DEF_PORT}"
  PROXY_ON=1
fi

# ---- optional Scrapfly cloud browser (takes precedence over local proxy) -------
SCRAPFLY_ON=0
SF_KEY="${SCRAPFLY_API_KEY:-}"
if [ -z "$SF_KEY" ] && [ -f "$SECRETS" ]; then
  SF_KEY="$(grep -i '^scrapfly api key:' "$SECRETS" | head -1 | sed -E 's/^[^:]*:[[:space:]]*//' | tr -d '[:space:]')"
fi
if [ -n "$SF_KEY" ]; then
  SCRAPFLY_ON=1
  PROXY_ON=0   # Scrapfly handles its own proxying
fi

cc_name() {
  case "$1" in
    us) echo "United States";; gb) echo "United Kingdom";; de) echo "Germany";;
    fr) echo "France";;       ca) echo "Canada";;          au) echo "Australia";;
    jp) echo "Japan";;        sg) echo "Singapore";;       br) echo "Brazil";;
    nl) echo "Netherlands";;  se) echo "Sweden";;          es) echo "Spain";;
    it) echo "Italy";;        pl) echo "Poland";;          in) echo "India";;
    za) echo "South Africa";; *) echo "$1";;
  esac
}

# ---- pick random Scrapfly countries (one per server, no repeats) ---------------
SF_COUNTRIES=()
if [ "$SCRAPFLY_ON" -eq 1 ]; then
  while IFS= read -r cc; do SF_COUNTRIES+=("$cc"); done < <(python3 -c "
import random
pool = ['us','gb','de','fr','ca','au','jp','sg','br','nl','se','es','it','pl','in']
random.shuffle(pool)
for c in pool[:${#REGIONS[@]}]: print(c)
")
fi

api() { # api METHOD PATH [JSON_BODY]
  local method="$1" path="$2" body="${3:-}"
  if [ -n "$body" ]; then
    printf 'header = "Authorization: Bearer %s"\n' "$KEY" | \
      curl -sS --max-time 60 -K - -X "$method" -H "Content-Type: application/json" --data-raw "$body" "https://api.vultr.com/v2$path"
  else
    printf 'header = "Authorization: Bearer %s"\n' "$KEY" | \
      curl -sS --max-time 60 -K - -X "$method" "https://api.vultr.com/v2$path"
  fi
}
py() { python3 -c "import sys,json
d=json.load(sys.stdin)
$1"; }

# ---- cleanup: destroy everything this run created -----------------------------
CREATED=()
cleanup() {
  trap - EXIT INT TERM
  if [ "${#CREATED[@]}" -gt 0 ]; then
    echo; echo "Destroying ${#CREATED[@]} server(s)..."
    for id in "${CREATED[@]}"; do
      code=$(printf 'header = "Authorization: Bearer %s"\n' "$KEY" | curl -sS -o /dev/null -w '%{http_code}' -K - -X DELETE "https://api.vultr.com/v2/instances/$id")
      echo "  $id -> HTTP $code"
    done
    echo "Done. Check https://my.vultr.com for anything still listed."
  fi
}
trap cleanup EXIT INT TERM

# ---- preflight (read-only) --------------------------------------------------
echo "Checking Vultr account..."
ACC="$(api GET /account)"
echo "$ACC" | py 'a=d.get("account")
if not a: sys.exit("API error: "+str(d.get("error", d))[:200])
print("  account ok, name:", a.get("name"))' || exit 1

SSHKEY_ID="$(api GET "/ssh-keys?per_page=100" | py 'print(next((k["id"] for k in d.get("ssh_keys",[]) if k["name"]=="'"$SSH_KEY_NAME"'"),""))')"
[ -n "$SSHKEY_ID" ] || { echo "SSH key '$SSH_KEY_NAME' not found in Vultr"; exit 1; }
if [ -n "$SNAP_ID" ]; then
  echo "  ssh key id: $SSHKEY_ID | snapshot: $SNAP_ID (fast boot)"
else
  SCRIPT_ID="$(api GET "/startup-scripts?per_page=100" | py 'print(next((k["id"] for k in d.get("startup_scripts",[]) if k["name"]=="'"$SCRIPT_NAME"'"),""))')"
  OS_ID="$(api GET "/os?per_page=500" | py 'print(next((k["id"] for k in d.get("os",[]) if k["name"]=="'"$OS_NAME"'"),""))')"
  [ -n "$SCRIPT_ID" ] || { echo "Startup script '$SCRIPT_NAME' not found in Vultr"; exit 1; }
  [ -n "$OS_ID" ]     || { echo "OS '$OS_NAME' not found"; exit 1; }
  echo "  ssh key id: $SSHKEY_ID | startup script id: $SCRIPT_ID | os id: $OS_ID"
fi
[ -f "$KEYFILE" ] || { echo "Missing private key $KEYFILE"; exit 1; }

LEFT="$(api GET "/instances?per_page=100" | py 'print(" ".join(i["label"] for i in d.get("instances",[]) if i["label"].startswith("'"$LABEL_PREFIX"'")))')"
[ -z "$LEFT" ] || { echo "Leftover servers from an earlier run: $LEFT. Destroy them first."; exit 1; }

TOTAL=$(( ${#REGIONS[@]} * N ))
echo
echo "Plan: ${#REGIONS[@]} servers (${REGIONS[*]}), $N readers each = $TOTAL readers, ${SECS}s each"
echo "Target: $URL"
if [ "$SCRAPFLY_ON" -eq 1 ]; then
  echo "Browser: Scrapfly cloud browser, countries: $(for i in "${!REGIONS[@]}"; do printf '%s->%s (%s)  ' "${REGIONS[$i]}" "${SF_COUNTRIES[$i]}" "$(cc_name "${SF_COUNTRIES[$i]}")"; done)"
elif [ "$PROXY_ON" -eq 1 ]; then
  echo "Proxy: $PROXY_PROVIDER residential, countries: $(for r in "${REGIONS[@]}"; do printf '%s->%s ' "$r" "$(cc_for "$r")"; done)"
else
  echo "Proxy: none (Vultr data-center IPs). Set USE_PROXY=1 for residential, or set SCRAPFLY_API_KEY for cloud browser."
fi
if [ "$SOCIAL_MODE" -eq 1 ]; then
  echo "Mode: social click-through — reader will navigate to the post, click the article link, then read"
elif [ "${GOOGLE_MODE:-0}" = "1" ]; then
  echo "Mode: Google referral — reader arrives with google.com as the Referer"
fi
[ "${MOBILE_PCT:-0}" != "0" ] && echo "Mobile: ~$(python3 -c "print(round(${MOBILE_PCT:-0}*100))")% of readers use a mobile viewport"
echo "Cost estimate: about \$0.02 for a 15-minute run"
if [ "$SCRAPFLY_ON" -eq 1 ] && [ "$TOTAL" -gt 5 ]; then
  echo "Warning: Scrapfly plan allows 5 concurrent sessions; $TOTAL readers requested."
  echo "  Reduce readers-per-server to $((5 / ${#REGIONS[@]})) or fewer (e.g. ./run-test.sh <url> 1)."
  echo "  Continuing anyway — readers beyond the cap will fail with 'session closed'."
fi
if [ "$DRY" -eq 1 ]; then echo; echo "Dry run: nothing created."; exit 0; fi

# ---- create -----------------------------------------------------------------
RUNID="$(date +%H%M%S)"
IDS=();
for r in "${REGIONS[@]}"; do
  RESP="$(V_REGION="$r" V_PLAN="$PLAN" V_OSID="${OS_ID:-0}" V_SNAPID="${SNAP_ID:-}" V_LABEL="$LABEL_PREFIX-$r-$RUNID" V_HOST="$LABEL_PREFIX-$r" V_SSHKEY="$SSHKEY_ID" V_SCRIPT="${SCRIPT_ID:-}" VULTR_KEY="$KEY" python3 -c "
import json, os, urllib.request, urllib.error
snap = os.environ.get('V_SNAPID','').strip()
data = {
  'region': os.environ['V_REGION'],
  'plan': os.environ['V_PLAN'],
  'label': os.environ['V_LABEL'],
  'hostname': os.environ['V_HOST'],
  'backups': 'disabled',
  'enable_ipv6': False,
  'sshkey_id': [os.environ['V_SSHKEY']],
}
if snap:
  data['snapshot_id'] = snap
else:
  data['os_id'] = int(os.environ['V_OSID'])
  data['script_id'] = os.environ['V_SCRIPT']
body = json.dumps(data).encode('utf-8')
req = urllib.request.Request(
  'https://api.vultr.com/v2/instances',
  data=body,
  headers={'Authorization': 'Bearer ' + os.environ['VULTR_KEY'].strip(), 'Content-Type': 'application/json'},
  method='POST'
)
try:
  with urllib.request.urlopen(req) as r: print(r.read().decode())
except urllib.error.HTTPError as e: print(e.read().decode())
")"
  ID="$(echo "$RESP" | py 'print(d.get("instance",{}).get("id",""))')"
  if [ -z "$ID" ]; then echo "Create failed in $r: $(echo "$RESP" | head -c 300)"; exit 1; fi
  CREATED+=("$ID"); IDS+=("$ID")
  echo "created $r -> $ID"
done

# ---- wait for IPs -----------------------------------------------------------
IPS=()
for i in "${!IDS[@]}"; do
  ip=""
  for t in $(seq 1 60); do
    ip="$(api GET "/instances/${IDS[$i]}" | py 'i=d.get("instance",{})
ip=i.get("main_ip","")
print(ip if i.get("status")=="active" and i.get("power_status")=="running" and ip!="0.0.0.0" else "")')"
    [ -n "$ip" ] && break; sleep 10
  done
  [ -n "$ip" ] || { echo "Server ${REGIONS[$i]} never became active"; exit 1; }
  IPS+=("$ip"); echo "${REGIONS[$i]}: $ip"
done

# ---- wait for startup script ------------------------------------------------
SSHO=(-i "$KEYFILE" -o IdentitiesOnly=yes -o StrictHostKeyChecking=accept-new -o PasswordAuthentication=no -o ConnectTimeout=10 -o LogLevel=ERROR)
echo "Waiting for startup scripts (about 5-8 minutes). A progress line prints every 30 seconds."
READY_FLAG=(); for i in "${!IPS[@]}"; do READY_FLAG+=(0); done
WAIT_START=$(date +%s); LAST_PRINT=0
while true; do
  PENDING=0
  for i in "${!IPS[@]}"; do
    [ "${READY_FLAG[$i]}" -eq 1 ] && continue
    # prints READY, NOTREADY, or nothing (server not accepting SSH yet)
    STATE="$(ssh "${SSHO[@]}" root@"${IPS[$i]}" 'test -f /root/READY && echo READY || echo NOTREADY' 2>/dev/null)"
    ELAPSED=$(( $(date +%s) - WAIT_START ))
    case "$STATE" in
      READY)    READY_FLAG[$i]=1; echo "${REGIONS[$i]}: ready (after ${ELAPSED}s)" ;;
      NOTREADY) PENDING=1; LAST_STATE[$i]="installing" ;;
      *)        PENDING=1; LAST_STATE[$i]="starting up" ;;
    esac
  done
  [ "$PENDING" -eq 0 ] && break
  ELAPSED=$(( $(date +%s) - WAIT_START ))
  if [ "$ELAPSED" -ge "$MAX_READY_WAIT" ]; then
    for i in "${!IPS[@]}"; do [ "${READY_FLAG[$i]}" -eq 0 ] && echo "${REGIONS[$i]}: NOT ready after ${MAX_READY_WAIT}s — skipping (last state: ${LAST_STATE[$i]:-unknown})"; done
    break
  fi
  if [ $(( ELAPSED - LAST_PRINT )) -ge 30 ]; then
    for i in "${!IPS[@]}"; do
      [ "${READY_FLAG[$i]}" -eq 0 ] && echo "${REGIONS[$i]}: ${LAST_STATE[$i]:-starting up}... ${ELAPSED}s elapsed"
    done
    LAST_PRINT=$ELAPSED
  fi
  sleep 10
done

# ---- upload the current reader.js (so the Vultr startup script copy can be stale) ----
echo "Uploading current reader.js to each server..."
for i in "${!IPS[@]}"; do
  [ "${READY_FLAG[$i]}" -eq 0 ] && continue
  scp "${SSHO[@]}" "$HERE/reader.js" root@"${IPS[$i]}":/root/reader/reader.js >/dev/null 2>&1 \
    || { echo "${REGIONS[$i]}: could not upload reader.js"; exit 1; }
done

# ---- install extra packages (skipped when booting from snapshot — already baked in) ----
RECORD="${RECORD:-0}"
if [ -z "$SNAP_ID" ]; then
  echo "Installing extra packages on each server..."
  for i in "${!IPS[@]}"; do
    [ "${READY_FLAG[$i]}" -eq 0 ] && continue
    EXTRA_PKGS="playwright-extra puppeteer-extra-plugin-stealth gif-encoder-2 pngjs"
    ssh "${SSHO[@]}" root@"${IPS[$i]}" \
      "cd /root/reader && npm install $EXTRA_PKGS --save-exact 2>&1 | tail -1" \
      || { echo "${REGIONS[$i]}: npm install failed"; exit 1; }
  done
fi

# ---- run readers --------------------------------------------------------------
# CLICK_LINK_PROB (0..1) = chance a reader clicks one internal link mid-visit. Default 0.
CLICK_PROB="${CLICK_LINK_PROB:-0.25}"
OUT="$(mktemp -d)"
echo; echo "Running $TOTAL readers (link-click chance: $CLICK_PROB)..."; date -u +"start %H:%M:%S UTC"
for i in "${!IPS[@]}"; do
  [ "${READY_FLAG[$i]}" -eq 0 ] && continue
  PENV=""
  if [ "$SCRAPFLY_ON" -eq 1 ]; then
    PENV="$(printf 'SCRAPFLY_API_KEY=%q SCRAPFLY_COUNTRY=%q' "$SF_KEY" "${SF_COUNTRIES[$i]}")"
  elif [ "$PROXY_ON" -eq 1 ]; then
    PENV="$(printf '%s_HOST=%q %s_PORT=%q %s_LOGIN=%q %s_PASSWORD=%q %s_COUNTRY=%q' "$PREFIX" "$PX_HOST" "$PREFIX" "$PX_PORT" "$PREFIX" "$PX_LOGIN" "$PREFIX" "$PX_PASS" "$PREFIX" "$(cc_for "${REGIONS[$i]}")")"
  fi
  SENV="$PENV NO_AUTOMATION_FLAG=1 CLICK_LINK_PROB=$CLICK_PROB"
  [ "$SOCIAL_MODE" -eq 1 ] && SENV="$SENV SOCIAL_MODE=1"
  [ "${GOOGLE_MODE:-0}" = "1" ] && SENV="$SENV GOOGLE_MODE=1"
  [ -n "${MOBILE_PCT:-}" ]   && SENV="$SENV MOBILE_PCT=$MOBILE_PCT"
  [ -n "${BOUNCE_PCT:-}" ]   && SENV="$SENV BOUNCE_PCT=$BOUNCE_PCT"
  [ -n "${SECOND_URL:-}" ]   && SENV="$SENV $(printf 'SECOND_URL=%q' "${SECOND_URL}")"
  [ -n "${SECOND_READ_PROB:-}" ] && SENV="$SENV SECOND_READ_PROB=$SECOND_READ_PROB"
  [ "$RECORD" = "1" ] && SENV="$SENV RECORD=1"
  ssh "${SSHO[@]}" root@"${IPS[$i]}" "cd /root/reader && $SENV node reader.js '$URL' ${REGIONS[$i]} $N $SECS" > "$OUT/${REGIONS[$i]}.out" 2>&1 &
done
wait
date -u +"end   %H:%M:%S UTC"

# ---- download recordings if RECORD=1 ----------------------------------------
if [ "$RECORD" = "1" ]; then
  REC_DIR="$HERE/recordings"
  mkdir -p "$REC_DIR"
  echo "Downloading recordings..."
  for i in "${!IPS[@]}"; do
    [ "${READY_FLAG[$i]}" -eq 0 ] && continue
    scp "${SSHO[@]}" "root@${IPS[$i]}:/root/reader/recordings/*" "$REC_DIR/" 2>/dev/null \
      && echo "  ${REGIONS[$i]}: downloaded to $REC_DIR/" \
      || echo "  ${REGIONS[$i]}: no recordings found"
  done
  # open the newest recording
  NEWEST="$(ls -t "$REC_DIR"/*.webm "$REC_DIR"/*.gif 2>/dev/null | head -1)"
  [ -n "$NEWEST" ] && open "$NEWEST" && echo "Opened: $NEWEST"
fi

N_EXPECTED="$N" python3 - "$OUT" "${REGIONS[@]}" <<'PY'
import sys, json, os
out = sys.argv[1]
expected = int(os.environ["N_EXPECTED"])
ok = bad = 0
reached_total = 0
blocked_total = 0
reasons = []
for r in sys.argv[2:]:
    rows, other = [], []
    for l in open(os.path.join(out, r + ".out")):
        l = l.rstrip("\n")
        if l.startswith("{"):
            rows.append(json.loads(l))
        elif l.strip():
            other.append(l.strip())
    good = [x for x in rows if x["status"] == "ok" and not x.get("bounced")]
    ok += len(good)
    bounced_readers = sum(1 for x in rows if x.get("bounced"))
    mobile_readers = sum(1 for x in rows if x.get("mobile"))
    clicks = [x["clicked"] for x in rows if x.get("clicked") and x["clicked"] not in ("click-failed", "no-link-found")]
    ups = sum(x.get("scrollUps", 0) for x in rows)
    sels = sum(x.get("textSelections", 0) for x in rows)
    steps_total = sum(x.get("steps", 0) for x in rows)
    extra = f", {len(clicks)} clicked a link" if any("clicked" in x for x in rows) else ""
    second_visits = sum(1 for x in rows if x.get("secondVisit"))
    if bounced_readers: extra += f", {bounced_readers} bounced early"
    if mobile_readers: extra += f", {mobile_readers} mobile"
    if second_visits: extra += f", {second_visits} visited 2nd article"
    reached = [x for x in rows if x.get("reached", True)]
    reached_total += len(reached)
    blocked_total += len(rows) - len(reached)
    print(f"{r}: {len(reached)}/{expected} reached the real page, {len(good)}/{expected} ran to the end, event sent by {sum(1 for x in rows if 'POST /__l5e/trackevents' in x['tracked'])}{extra}, {steps_total} scroll steps ({ups} back), {sels} text selections")
    for x in rows:
        path = x.get("finalPath") or "?"
        title = (x.get("title") or "?")[:60]
        secs = x.get("seconds", "?")
        print(f"  reader {x['reader']}: {x.get('steps',0)} steps, {x.get('scrollUps',0)} back, {x.get('textSelections',0)} sel, {secs}s — landed on {path!r}")
    seen = {}
    for x in rows:
        if not x.get("reached", True):
            seen[x.get("notReached") or "unknown"] = seen.get(x.get("notReached") or "unknown", 0) + 1
    for why, cnt in seen.items():
        reasons.append(f"  {r}: {cnt} reader(s) did NOT reach the page - {why}")
    for x in rows:
        if x["status"] != "ok":
            bad += 1
            reasons.append(f"  {r} reader {x['reader']}: failed after {x['seconds']}s - {x['status']}")
    missing = expected - len(rows)
    if missing > 0:
        bad += missing
        why = "; ".join(other[:3])[:300] or "no output from the server"
        reasons.append(f"  {r}: {missing} reader(s) gave no result - {why}")
print(f"Total: {reached_total} reached the real page, {blocked_total} blocked or not loaded; {ok} ran to the end, {bad} failed")
if reasons:
    print("Failure reasons:")
    for line in reasons:
        print(line)
PY
rm -rf "$OUT"
