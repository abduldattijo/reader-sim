#!/bin/bash
# cloud-init / user_data script for DigitalOcean (and Vultr) reader droplets.
# Installs Node 20, Playwright Chromium, and the reader npm deps.
# Writes /root/READY when done — run-test.sh polls for this file via SSH.
exec > /root/startup.log 2>&1
set -e
export DEBIAN_FRONTEND=noninteractive
while fuser /var/lib/dpkg/lock-frontend >/dev/null 2>&1; do sleep 3; done
apt-get update -y
apt-get install -y curl ca-certificates
curl -fsSL https://deb.nodesource.com/setup_20.x | bash -
apt-get install -y nodejs
mkdir -p /root/reader && cd /root/reader
# Minimal package.json — run-test.sh uploads the real reader.js before running.
cat > package.json <<'PKG_EOF'
{"name":"reader","version":"1.0.0","private":true,"dependencies":{"playwright":"latest"}}
PKG_EOF
npm install
npx playwright install --with-deps chromium
echo "NODE: $(node -v)"
echo "PUBLIC_IP: $(curl -4 -s ifconfig.me)"
touch /root/READY
echo "STARTUP_DONE"
