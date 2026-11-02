#!/bin/bash
# usage: run_n.sh <label> <ip> <script> <url> <readers>   (password in $VPS_PW)
S="$(cd "$(dirname "$0")" && pwd)"
O="-o StrictHostKeyChecking=accept-new -o PreferredAuthentications=password -o PubkeyAuthentication=no"
export SSH_ASKPASS="$S/askpass.sh" SSH_ASKPASS_REQUIRE=force
scp $O "$3" root@"$2":/root/reader/reader.js > "$S/$1.n.log" 2>&1
ssh $O root@"$2" "cd /root/reader && NO_AUTOMATION_FLAG=1 node reader.js $4 $1 $5 70" >> "$S/$1.n.log" 2>&1
