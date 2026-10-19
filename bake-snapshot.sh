#!/bin/bash
# bake-snapshot.sh — create a Vultr snapshot with all reader dependencies pre-installed.
#
# Run once (or whenever Node/Playwright versions need updating).
# After this completes, run-test.sh will boot from the snapshot instead of
# running the startup script, cutting VPS ready-time from 5-8 minutes to ~30 seconds.
#
# Usage: ./bake-snapshot.sh
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
SECRETS="$HERE/../local-secrets/api keys.md"
KEYFILE="$HOME/.ssh/vultr_reader_ed25519"
SNAPSHOT_DESC="reader-base"
PLAN="vc2-1c-2gb"
OS_NAME="Ubuntu 24.04 LTS x64"
SSH_KEY_NAME="reader-sim"
SCRIPT_NAME="reader-install"
MAX_WAIT=900

KEY="${VULTR_API_KEY:-}"
if [ -z "$KEY" ] && [ -f "$SECRETS" ]; then
  KEY="$(grep -i '^vultr api key:' "$SECRETS" | head -1 | sed -E 's/^[^:]*:[[:space:]]*//' | tr -d '[:space:]')"
fi
[ -n "$KEY" ] || { echo "No Vultr API key found"; exit 1; }
[ -f "$KEYFILE" ] || { echo "Missing private key $KEYFILE"; exit 1; }

api() {
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

SSHO=(-i "$KEYFILE" -o IdentitiesOnly=yes -o StrictHostKeyChecking=accept-new -o PasswordAuthentication=no -o ConnectTimeout=10 -o LogLevel=ERROR)

# ---- preflight ---------------------------------------------------------------
echo "Looking up Vultr resources..."
SSHKEY_ID="$(api GET "/ssh-keys?per_page=100" | py 'print(next((k["id"] for k in d.get("ssh_keys",[]) if k["name"]=="'"$SSH_KEY_NAME"'"),""))')"
SCRIPT_ID="$(api GET "/startup-scripts?per_page=100" | py 'print(next((k["id"] for k in d.get("startup_scripts",[]) if k["name"]=="'"$SCRIPT_NAME"'"),""))')"
OS_ID="$(api GET "/os?per_page=500" | py 'print(next((k["id"] for k in d.get("os",[]) if k["name"]=="'"$OS_NAME"'"),""))')"
[ -n "$SSHKEY_ID" ] || { echo "SSH key '$SSH_KEY_NAME' not found"; exit 1; }
[ -n "$SCRIPT_ID" ] || { echo "Startup script '$SCRIPT_NAME' not found"; exit 1; }
[ -n "$OS_ID" ]     || { echo "OS '$OS_NAME' not found"; exit 1; }
echo "  ssh key: $SSHKEY_ID | startup script: $SCRIPT_ID | os: $OS_ID"

# ---- check for existing snapshot with same description -----------------------
EXISTING="$(api GET "/snapshots?per_page=100" | py 'print(next((s["id"] for s in d.get("snapshots",[]) if s.get("description")=="'"$SNAPSHOT_DESC"'"),""))')"
if [ -n "$EXISTING" ]; then
  echo "A snapshot named '$SNAPSHOT_DESC' already exists: $EXISTING"
  echo "Delete it first if you want to re-bake: Vultr dashboard → Backups & Snapshots → Snapshots"
  exit 0
fi

# ---- create base server (fra region, same as production) ---------------------
INSTANCE_ID=""
cleanup() {
  if [ -n "$INSTANCE_ID" ]; then
    echo; echo "Destroying build server..."
    printf 'header = "Authorization: Bearer %s"\n' "$KEY" | \
      curl -sS -o /dev/null -w "  %{http_code}\n" -K - -X DELETE "https://api.vultr.com/v2/instances/$INSTANCE_ID"
  fi
}
trap cleanup EXIT INT TERM

RUNID="$(date +%H%M%S)"
LABEL="reader-bake-$RUNID"
echo; echo "Creating build server in fra..."
RESP="$(V_PLAN="$PLAN" V_OSID="$OS_ID" V_LABEL="$LABEL" V_SSHKEY="$SSHKEY_ID" V_SCRIPT="$SCRIPT_ID" VULTR_KEY="$KEY" python3 -c "
import json, os, urllib.request, urllib.error
data = {
  'region': 'fra',
  'plan': os.environ['V_PLAN'],
  'os_id': int(os.environ['V_OSID']),
  'label': os.environ['V_LABEL'],
  'hostname': 'reader-bake',
  'backups': 'disabled',
  'enable_ipv6': False,
  'sshkey_id': [os.environ['V_SSHKEY']],
  'script_id': os.environ['V_SCRIPT'],
}
body = json.dumps(data).encode()
req = urllib.request.Request(
  'https://api.vultr.com/v2/instances', data=body,
  headers={'Authorization': 'Bearer ' + os.environ['VULTR_KEY'].strip(), 'Content-Type': 'application/json'},
  method='POST'
)
try:
  with urllib.request.urlopen(req) as r: print(r.read().decode())
except urllib.error.HTTPError as e: print(e.read().decode())
")"
INSTANCE_ID="$(echo "$RESP" | py 'print(d.get("instance",{}).get("id",""))')"
[ -n "$INSTANCE_ID" ] || { echo "Create failed: $(echo "$RESP" | head -c 300)"; exit 1; }
echo "  instance: $INSTANCE_ID"

# ---- wait for IP -------------------------------------------------------------
echo "Waiting for IP..."
IP=""
for t in $(seq 1 60); do
  IP="$(api GET "/instances/$INSTANCE_ID" | py 'i=d.get("instance",{})
ip=i.get("main_ip","")
print(ip if i.get("status")=="active" and i.get("power_status")=="running" and ip!="0.0.0.0" else "")')"
  [ -n "$IP" ] && break; sleep 10
done
[ -n "$IP" ] || { echo "Server never became active"; exit 1; }
echo "  IP: $IP"

# ---- wait for startup script -------------------------------------------------
echo "Waiting for startup script (up to ${MAX_WAIT}s)..."
WAIT_START=$(date +%s); LAST_PRINT=0
while true; do
  STATE="$(ssh "${SSHO[@]}" root@"$IP" 'test -f /root/READY && echo READY || echo NOTREADY' 2>/dev/null)"
  ELAPSED=$(( $(date +%s) - WAIT_START ))
  if [ "$STATE" = "READY" ]; then
    echo "  ready after ${ELAPSED}s"
    break
  fi
  if [ "$ELAPSED" -ge "$MAX_WAIT" ]; then
    echo "Startup script timed out after ${MAX_WAIT}s — aborting"
    exit 1
  fi
  if [ $(( ELAPSED - LAST_PRINT )) -ge 30 ]; then
    echo "  still installing... ${ELAPSED}s"
    LAST_PRINT=$ELAPSED
  fi
  sleep 10
done

# ---- install all extra packages into the snapshot ----------------------------
echo "Installing extra packages (playwright-extra, stealth, gif-encoder-2, pngjs)..."
ssh "${SSHO[@]}" root@"$IP" \
  "cd /root/reader && npm install playwright-extra puppeteer-extra-plugin-stealth gif-encoder-2 pngjs --save-exact 2>&1 | tail -3"

# ---- take snapshot -----------------------------------------------------------
echo "Taking snapshot (this takes 2-5 minutes)..."
SNAP_RESP="$(V_ID="$INSTANCE_ID" V_DESC="$SNAPSHOT_DESC" VULTR_KEY="$KEY" python3 -c "
import json, os, urllib.request, urllib.error
data = {'instance_id': os.environ['V_ID'], 'description': os.environ['V_DESC']}
body = json.dumps(data).encode()
req = urllib.request.Request(
  'https://api.vultr.com/v2/snapshots', data=body,
  headers={'Authorization': 'Bearer ' + os.environ['VULTR_KEY'].strip(), 'Content-Type': 'application/json'},
  method='POST'
)
try:
  with urllib.request.urlopen(req) as r: print(r.read().decode())
except urllib.error.HTTPError as e: print(e.read().decode())
")"
SNAP_ID="$(echo "$SNAP_RESP" | py 'print(d.get("snapshot",{}).get("id",""))')"
[ -n "$SNAP_ID" ] || { echo "Snapshot create failed: $(echo "$SNAP_RESP" | head -c 300)"; exit 1; }
echo "  snapshot id: $SNAP_ID"

# ---- wait for snapshot to complete -------------------------------------------
for t in $(seq 1 60); do
  STATUS="$(api GET "/snapshots/$SNAP_ID" | py 'print(d.get("snapshot",{}).get("status",""))')"
  echo "  status: $STATUS (${t}0s)"
  [ "$STATUS" = "complete" ] && break
  sleep 10
done
[ "$STATUS" = "complete" ] || { echo "Snapshot never completed"; exit 1; }

# ---- save snapshot ID to a local file ----------------------------------------
echo "$SNAP_ID" > "$HERE/.snapshot-id"
echo
echo "Done. Snapshot ID: $SNAP_ID"
echo "Saved to reader-sim/.snapshot-id — run-test.sh will use it automatically."
echo "The build server will now be destroyed."
