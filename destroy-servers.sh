#!/bin/bash
# destroy-servers.sh: list and destroy Vultr servers whose label starts with "reader-".
#
# usage: ./destroy-servers.sh            list them, ask, then destroy
#        ./destroy-servers.sh --list     only list, destroy nothing
#        ./destroy-servers.sh --yes      destroy without asking
# Servers with other names are never touched.
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
SECRETS="$HERE/../local-secrets/api keys.md"
PREFIX="reader-"
MODE="${1:-ask}"

KEY="${VULTR_API_KEY:-}"
if [ -z "$KEY" ] && [ -f "$SECRETS" ]; then
  KEY="$(grep -i '^vultr api key:' "$SECRETS" | head -1 | sed -E 's/^[^:]*:[[:space:]]*//' | tr -d '[:space:]')"
fi
[ -n "$KEY" ] || { echo "No Vultr API key found (VULTR_API_KEY or $SECRETS)"; exit 1; }

api() { printf 'header = "Authorization: Bearer %s"\n' "$KEY" | curl -sS --max-time 60 -K - "$@"; }

LIST="$(api "https://api.vultr.com/v2/instances?per_page=100" | PREFIX="$PREFIX" python3 -c '
import sys, json, os
d = json.load(sys.stdin)
for i in d.get("instances", []):
    if i["label"].startswith(os.environ["PREFIX"]):
        print("%s\t%s\t%s\t%s" % (i["id"], i["label"], i["region"], i["main_ip"]))
')"

if [ -z "$LIST" ]; then echo "No servers starting with '$PREFIX' found. Nothing to destroy."; exit 0; fi

echo "Servers starting with '$PREFIX':"
echo "$LIST" | awk -F'\t' '{printf "  %-22s %-5s %s\n", $2, $3, $4}'
[ "$MODE" = "--list" ] && exit 0

if [ "$MODE" != "--yes" ]; then
  printf "Destroy these %s server(s)? Type yes to confirm: " "$(echo "$LIST" | wc -l | tr -d ' ')"
  read -r ans
  [ "$ans" = "yes" ] || { echo "Cancelled. Nothing destroyed."; exit 0; }
fi

echo "$LIST" | while IFS=$'\t' read -r id label region ip; do
  code="$(printf 'header = "Authorization: Bearer %s"\n' "$KEY" | curl -sS -o /dev/null -w '%{http_code}' -K - -X DELETE "https://api.vultr.com/v2/instances/$id")"
  echo "  destroyed $label ($ip) -> HTTP $code"
done
echo "Done. Billing stops once a server is destroyed."
