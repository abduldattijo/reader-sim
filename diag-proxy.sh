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
# Optional: USE_PROXY=1 routes each server's browser through a DataImpulse residential
#   proxy in that server's country (fra->de, ewr->us, jnb->za). Needs the lines
#   "dataimpulse login: ...", "dataimpulse password: ...", "dataimpulse host: ...",
#   "dataimpulse port: ..." in ../local-secrets/api keys.md. Uses proxy traffic (GB).
#   USE_PROXY=1 ./run-test.sh https://usehomesteados.com/pricing 5
# Servers are always destroyed on exit (success, error or Ctrl-C).
set -u

HERE="$(cd "$(dirname "$0")" && pwd)"
URL="${1:?usage: run-test.sh <url> <readers-per-server> [seconds] [--dry-run]}"
N="${2:?readers per server}"
SECS="${3:-70}"
DRY=0
for a in "$@"; do [ "$a" = "--dry-run" ] && DRY=1; done
[ "$SECS" = "--dry-run" ] && SECS=70

REGIONS=(fra)                     # diagnostic: one server only
PLAN="vc2-1c-2gb"                 # 1 vCPU, 2 GB RAM
OS_NAME="Ubuntu 24.04 LTS x64"
SSH_KEY_NAME="reader-sim"
SCRIPT_NAME="reader-install"
LABEL_PREFIX="reader-diag"
KEYFILE="$HOME/.ssh/vultr_reader_ed25519"
MAX_READY_WAIT=900                # seconds to wait for the startup script
SECRETS="$HERE/../local-secrets/api keys.md"

[ "$N" -ge 1 ] 2>/dev/null && [ "$N" -le 10 ] || { echo "readers per server must be 1..10"; exit 1; }

# ---- API key (never printed) ------------------------------------------------
KEY="${VULTR_API_KEY:-}"
if [ -z "$KEY" ] && [ -f "$SECRETS" ]; then
  KEY="$(grep -i '^vultr api key:' "$SECRETS" | head -1 | sed -E 's/^[^:]*:[[:space:]]*//' | tr -d '[:space:]')"
fi
[ -n "$KEY" ] || { echo "No Vultr API key found (set VULTR_API_KEY or add 'vultr api key: ...' to $SECRETS)"; exit 1; }

# ---- optional DataImpulse proxy (credentials never printed) ----------------------
cc_for() { case "$1" in fra) echo de;; ewr) echo us;; jnb) echo za;; *) echo us;; esac; }
PROXY_ON=0
if [ "${USE_PROXY:-0}" = "1" ]; then
  di() { grep -i "^dataimpulse $1:" "$SECRETS" 2>/dev/null | head -1 | sed -E 's/^[^:]*:[[:space:]]*//' | tr -d '[:space:]'; }
  DI_HOST="$(di host)"; DI_PORT="$(di port)"; DI_LOGIN="$(di login)"; DI_PASS="$(di password)"
  [ -n "$DI_LOGIN" ] && [ -n "$DI_PASS" ] || { echo "USE_PROXY=1 but dataimpulse login/password not found in $SECRETS"; exit 1; }
  DI_HOST="${DI_HOST:-gw.dataimpulse.com}"; DI_PORT="${DI_PORT:-823}"
  PROXY_ON=1
fi

api() { # api METHOD PATH [JSON_BODY]
  local method="$1" path="$2" body="${3:-}"
  if [ -n "$body" ]; then
    printf 'header = "Authorization: Bearer %s"\n' "$KEY" | \
      curl -sS --max-time 60 -K - -X "$method" -H "Content-Type: application/json" --data "$body" "https://api.vultr.com/v2$path"
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
SCRIPT_ID="$(api GET "/startup-scripts?per_page=100" | py 'print(next((k["id"] for k in d.get("startup_scripts",[]) if k["name"]=="'"$SCRIPT_NAME"'"),""))')"
OS_ID="$(api GET "/os?per_page=500" | py 'print(next((k["id"] for k in d.get("os",[]) if k["name"]=="'"$OS_NAME"'"),""))')"
[ -n "$SSHKEY_ID" ] || { echo "SSH key '$SSH_KEY_NAME' not found in Vultr"; exit 1; }
[ -n "$SCRIPT_ID" ] || { echo "Startup script '$SCRIPT_NAME' not found in Vultr"; exit 1; }
[ -n "$OS_ID" ]     || { echo "OS '$OS_NAME' not found"; exit 1; }
echo "  ssh key id: $SSHKEY_ID | startup script id: $SCRIPT_ID | os id: $OS_ID"
[ -f "$KEYFILE" ] || { echo "Missing private key $KEYFILE"; exit 1; }

LEFT="$(api GET "/instances?per_page=100" | py 'print(" ".join(i["label"] for i in d.get("instances",[]) if i["label"].startswith("'"$LABEL_PREFIX"'")))')"
[ -z "$LEFT" ] || { echo "Leftover servers from an earlier run: $LEFT. Destroy them first."; exit 1; }

TOTAL=$(( ${#REGIONS[@]} * N ))
echo
echo "Plan: ${#REGIONS[@]} servers (${REGIONS[*]}), $N readers each = $TOTAL readers, ${SECS}s each"
echo "Target: $URL"
if [ "$PROXY_ON" -eq 1 ]; then
  echo "Proxy: DataImpulse residential, countries: $(for r in "${REGIONS[@]}"; do printf '%s->%s ' "$r" "$(cc_for "$r")"; done)"
else
  echo "Proxy: none (Vultr data-center IPs). Set USE_PROXY=1 for residential."
fi
echo "Cost estimate: about \$0.02 for a 15-minute run"
if [ "$DRY" -eq 1 ]; then echo; echo "Dry run: nothing created."; exit 0; fi

# ---- create -----------------------------------------------------------------
RUNID="$(date +%H%M%S)"
IDS=();
for r in "${REGIONS[@]}"; do
  BODY="$(python3 -c "import json;print(json.dumps({'region':'$r','plan':'$PLAN','os_id':int('$OS_ID'),'label':'$LABEL_PREFIX-$r-$RUNID','hostname':'$LABEL_PREFIX-$r','backups':'disabled','enable_ipv6':False,'sshkey_id':['$SSHKEY_ID'],'script_id':'$SCRIPT_ID'}))")"
  RESP="$(api POST /instances "$BODY")"
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
    for i in "${!IPS[@]}"; do [ "${READY_FLAG[$i]}" -eq 0 ] && echo "${REGIONS[$i]}: NOT ready after ${MAX_READY_WAIT}s (last state: ${LAST_STATE[$i]:-unknown})"; done
    exit 1
  fi
  if [ $(( ELAPSED - LAST_PRINT )) -ge 30 ]; then
    for i in "${!IPS[@]}"; do
      [ "${READY_FLAG[$i]}" -eq 0 ] && echo "${REGIONS[$i]}: ${LAST_STATE[$i]:-starting up}... ${ELAPSED}s elapsed"
    done
    LAST_PRINT=$ELAPSED
  fi
  sleep 10
done

# ---- diagnostic: exit IP seen by a browser on the server --------------------------
echo "Uploading diag.js..."
scp "${SSHO[@]}" "$HERE/diag.js" root@"${IPS[0]}":/root/reader/diag.js >/dev/null 2>&1 || { echo "upload failed"; exit 1; }
PENV=""
if [ "$PROXY_ON" -eq 1 ]; then
  PENV="$(printf 'DATAIMPULSE_HOST=%q DATAIMPULSE_PORT=%q DATAIMPULSE_LOGIN=%q DATAIMPULSE_PASSWORD=%q DATAIMPULSE_COUNTRY=%q' "$DI_HOST" "$DI_PORT" "$DI_LOGIN" "$DI_PASS" "$(cc_for fra)")"
fi
echo "---- output from the server ----"
ssh "${SSHO[@]}" root@"${IPS[0]}" "cd /root/reader && $PENV node diag.js" 2>&1
echo "--------------------------------"
