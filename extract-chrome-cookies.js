// extract-chrome-cookies.js — reads TDS cookies from your real Chrome browser
// and saves them to local-secrets/tds-session.json for HEADLESS=0 testing.
//
// Usage: node extract-chrome-cookies.js  (Chrome can be running)
const chromeCookies = require('chrome-cookies-secure');
const fs   = require('fs');
const path = require('path');
const os   = require('os');
const { execSync } = require('child_process');

const OUT = path.join(__dirname, '../local-secrets/tds-session.json');
const SRC = path.join(os.homedir(), 'Library/Application Support/Google/Chrome/Default/Cookies');
const TMP = path.join(os.tmpdir(), 'chrome-cookies-copy-' + Date.now());

// Copy the locked cookie file so SQLite can open it without Chrome's lock.
fs.copyFileSync(SRC, TMP);
process.env.CHROME_COOKIES_PATH = TMP;

chromeCookies.getCookies('https://towardsdatascience.com', 'puppeteer', (err, cookies) => {
  try { fs.unlinkSync(TMP); } catch (_) {}
  if (err) {
    console.error('Failed to read Chrome cookies:', err.message || err);
    process.exit(1);
  }
  if (!cookies || cookies.length === 0) {
    console.error('No cookies found for towardsdatascience.com — are you logged in in Chrome?');
    process.exit(1);
  }
  fs.writeFileSync(OUT, JSON.stringify(cookies, null, 2));
  console.log(`Saved ${cookies.length} cookies to ${path.basename(OUT)}`);
  console.log('Run: HEADLESS=0 BOUNCE_PCT=0 node reader.js <url> watch 1 90');
});
