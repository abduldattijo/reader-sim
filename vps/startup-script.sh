#!/bin/bash
# Vultr startup script: prepares a reader server on first boot. Log: /root/startup.log
exec > /root/startup.log 2>&1
set -e
export DEBIAN_FRONTEND=noninteractive
while fuser /var/lib/dpkg/lock-frontend >/dev/null 2>&1; do sleep 3; done
apt-get update -y
apt-get install -y curl ca-certificates
curl -fsSL https://deb.nodesource.com/setup_20.x | bash -
apt-get install -y nodejs
mkdir -p /root/reader && cd /root/reader
cat > reader.js <<'READER_EOF'
// usage: node reader.js <url> <label> <readers> <seconds>
// Each reader gets its own browser context (fresh cookies/storage), scrolls and
// moves the mouse like a person, stays <seconds> on the page, then reports.
const { chromium } = require('playwright');

const [, , url, label = 'run', n = '2', secs = '70'] = process.argv;
const readers = Number(n);
const stay = Number(secs) * 1000;
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
const rand = (a, b) => a + Math.random() * (b - a);

async function readerRun(browser, i) {
  const ctx = await browser.newContext({ viewport: { width: 1366, height: 768 } });
  const page = await ctx.newPage();
  const tracked = [];
  page.on('request', (r) => {
    if (r.url().includes('/__l5e/')) tracked.push(`${r.method()} ${new URL(r.url()).pathname}`);
  });

  await sleep(rand(0, 5000)); // stagger starts
  const start = Date.now();
  const startedAt = new Date().toISOString();
  let status = 'ok';
  try {
    await page.goto(url, { waitUntil: 'load', timeout: 30000 });
    while (Date.now() - start < stay) {
      await page.mouse.move(rand(100, 1200), rand(100, 650));
      await page.mouse.wheel(0, rand(150, 450));
      await sleep(rand(3000, 7000));
    }
  } catch (e) {
    status = 'error: ' + e.message.split('\n')[0];
  }
  const seconds = Math.round((Date.now() - start) / 1000);
  const webdriver = await page.evaluate(() => navigator.webdriver).catch(() => null);
  await ctx.close();
  return { label, reader: i + 1, startedAt, seconds, status, webdriver, trackedRequests: tracked.length, tracked: [...new Set(tracked)] };
}

(async () => {
  // NO_AUTOMATION_FLAG=1 launches without the "controlled by automation" marker,
  // so we can tell whether analytics filter on that flag or on the network.
  const args = process.env.NO_AUTOMATION_FLAG ? ['--disable-blink-features=AutomationControlled'] : [];
  const browser = await chromium.launch({ args });
  const results = await Promise.all(Array.from({ length: readers }, (_, i) => readerRun(browser, i)));
  await browser.close();
  for (const r of results) console.log(JSON.stringify(r));
})();
READER_EOF
npm init -y >/dev/null
npm install playwright
npx playwright install --with-deps chromium
echo "NODE: $(node -v)"
echo "PUBLIC_IP: $(curl -4 -s ifconfig.me)"
touch /root/READY
echo "STARTUP_DONE"
