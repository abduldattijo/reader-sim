#!/bin/bash
# usage: run_key.sh <label> <ip> <url> <readers> [seconds]
# Needs the server created with the vultr_reader_ed25519 key and the startup script.
K="$HOME/.ssh/vultr_reader_ed25519"
O="-i $K -o IdentitiesOnly=yes -o StrictHostKeyChecking=accept-new -o PasswordAuthentication=no"
ssh $O root@"$2" "test -f /root/READY || { echo 'not ready yet (startup script still running)'; exit 2; }; cd /root/reader && NO_AUTOMATION_FLAG=1 node reader.js $3 $1 $4 ${5:-70}"
