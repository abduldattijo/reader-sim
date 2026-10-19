// save-session.js — run once to log into TDS and save cookies for local headless=0 testing.
//
// Usage:
//   node save-session.js
//
// Reads TDS_USERNAME / TDS_PASSWORD from env or ../local-secrets/api keys.md.
// Saves cookies to ../local-secrets/tds-session.json (never committed to git).
const { chromium } = require('playwright-extra');
const StealthPlugin = require('puppeteer-extra-plugin-stealth');
const path = require('path');
const fs   = require('fs');

chromium.use(StealthPlugin());

const SECRETS = path.join(__dirname, '../local-secrets/api keys.md');

// Credentials line format: "tds credentials username <email> password: <pass>"
function readTdsCreds() {
  if (!fs.existsSync(SECRETS)) return {};
  const line = fs.readFileSync(SECRETS, 'utf8').split('\n')
    .find(l => /tds credentials/i.test(l));
  if (!line) return {};
  const u = line.match(/username\s+(\S+)/i);
  const p = line.match(/password:\s*(\S+)/i);
  return { username: u ? u[1] : null, password: p ? p[1] : null };
}

const creds = readTdsCreds();
const USERNAME = process.env.TDS_USERNAME || creds.username;
const PASSWORD = process.env.TDS_PASSWORD || creds.password;

const OUT = path.join(__dirname, '../local-secrets/tds-session.json');

(async () => {
  try {
  if (!USERNAME || !PASSWORD) {
    console.error('TDS credentials not found. Set TDS_USERNAME / TDS_PASSWORD or add them to local-secrets/api keys.md');
    process.exit(1);
  }

  console.log('Launching browser...');
  const browser = await chromium.launch({ headless: false, slowMo: 50 });
  const ctx = await browser.newContext({ viewport: { width: 1280, height: 800 } });
  const page = await ctx.newPage();
  console.log('Browser launched.');

  console.log('Opening TDS — log in in the browser window that appears.');
  console.log('The script will detect when you are logged in and save automatically.');
  await page.goto('https://towardsdatascience.com/i-tested-four-ways-to-give-an-ai-assistant-a-memory-the-obvious-one-was-the-worst-value/', { waitUntil: 'load', timeout: 30000 });
  console.log('>>> The article should flash briefly. Click "Sign In" in the top-right nav, log in, then wait. <<<');

  // Give the user 90 seconds to log in manually, with a countdown.
  console.log('You have 90 seconds to log in. Counting down:');
  for (let s = 90; s > 0; s -= 5) {
    process.stdout.write(`${s}s `);
    await page.waitForTimeout(5000);
  }
  console.log('\nTime up — saving session now.');

  const cookies = await ctx.cookies();
  fs.writeFileSync(OUT, JSON.stringify(cookies, null, 2));
  console.log(`Saved ${cookies.length} cookies to ${OUT}`);
  console.log('You can now run: HEADLESS=0 node reader.js <url> watch 1 90');

  await browser.close();
  } catch (err) {
    console.error('FATAL:', err.message || err);
    process.exit(1);
  }
})();
