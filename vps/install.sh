set -e
export DEBIAN_FRONTEND=noninteractive
# wait for any background apt job on a fresh server
while fuser /var/lib/dpkg/lock-frontend >/dev/null 2>&1; do sleep 3; done
apt-get update -y
apt-get install -y curl ca-certificates
curl -fsSL https://deb.nodesource.com/setup_20.x | bash -
apt-get install -y nodejs
mkdir -p /root/reader && cd /root/reader
npm init -y >/dev/null
npm install playwright
npx playwright install --with-deps chromium
echo "NODE: $(node -v)"
echo "PLAYWRIGHT: $(npx playwright --version)"
echo "PUBLIC_IP: $(curl -4 -s ifconfig.me)"
echo "INSTALL_DONE"
