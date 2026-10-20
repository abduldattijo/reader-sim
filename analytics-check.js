#!/usr/bin/env node
// analytics-check.js — scrape TDS writer analytics and write a GitHub Actions summary.
//
// Env vars required:
//   TDS_USERNAME   — your TDS portal email
//   TDS_PASSWORD   — your TDS portal password
//
// Optional:
//   HISTORY_DIR    — directory to store daily JSON snapshots (default: ./analytics-history)
//   GITHUB_STEP_SUMMARY — set automatically by GitHub Actions

const { chromium } = require('playwright');
const fs   = require('fs');
const path = require('path');

const USERNAME    = process.env.TDS_USERNAME;
const PASSWORD    = process.env.TDS_PASSWORD;
const HISTORY_DIR = process.env.HISTORY_DIR || path.join(__dirname, 'analytics-history');
const SUMMARY     = process.env.GITHUB_STEP_SUMMARY;

if (!USERNAME || !PASSWORD) {
  console.error('TDS_USERNAME and TDS_PASSWORD must be set');
  process.exit(1);
}

const today     = new Date().toISOString().split('T')[0];
const yesterday = new Date(Date.now() - 86400000).toISOString().split('T')[0];

async function scrape() {
  const browser = await chromium.launch({ headless: true });
  const ctx  = await browser.newContext({ viewport: { width: 1280, height: 900 } });
  const page = await ctx.newPage();

  try {
    // Go straight to analytics — portal will redirect to login if needed
    await page.goto('https://write.insightmediagroup.io/tds/analytics', { waitUntil: 'networkidle', timeout: 30000 });

    // Handle login redirect
    if (page.url().includes('login') || page.url().includes('signin') || page.url().includes('auth')) {
      console.log('Redirected to login — signing in...');
      const emailInput = page.locator('input[type="email"], input[name="email"], input[name="username"]').first();
      await emailInput.fill(USERNAME);
      const passInput = page.locator('input[type="password"]').first();
      await passInput.fill(PASSWORD);
      await page.locator('button[type="submit"], input[type="submit"]').first().click();
      // Wait up to 30s for redirect to analytics, then navigate there manually if needed
      await page.waitForURL('**/tds/analytics', { timeout: 30000 }).catch(() => {});
      if (!page.url().includes('tds/analytics')) {
        await page.goto('https://write.insightmediagroup.io/tds/analytics', { waitUntil: 'networkidle', timeout: 30000 });
      }
    }

    // Wait for the table — portal is a SPA, data loads via XHR after mount
    await page.waitForSelector('table', { timeout: 45000 });
    await page.waitForTimeout(2000); // let all rows finish rendering

    // Scrape all rows
    const articles = await page.evaluate(() => {
      const rows = [];
      const trs = document.querySelectorAll('tbody tr, table tr');
      for (const tr of trs) {
        const tds = Array.from(tr.querySelectorAll('td'));
        if (tds.length < 4) continue;

        // Title + URL from the link in the first cell
        const linkEl  = tds[0].querySelector('a[href]');
        const titleEl = linkEl || tds[0].querySelector('p, span, h3, h4') || tds[0];
        const title   = titleEl.textContent.trim().split('\n')[0].trim();
        if (!title || title.length < 5) continue;

        // Extract the stable story slug (last path segment of the URL)
        const href    = linkEl?.href || '';
        const slug    = href ? href.replace(/\/$/, '').split('/').pop() : '';

        const num = (s) => parseInt((s || '').replace(/[^0-9]/g, '')) || 0;
        const str = (el) => (el || { textContent: '--' }).textContent.trim();

        rows.push({
          title,
          slug,                          // stable Medium story ID — survives title renames
          url: href,
          published:       str(tds[1]),
          pageviews:       num(str(tds[2])),
          engagedViews:    num(str(tds[3])),
          engagedViews30d: num(str(tds[4])),
          payout:          str(tds[5]) || '--',
        });
      }
      return rows;
    });

    return articles;
  } finally {
    await browser.close();
  }
}

function loadHistory(date) {
  const file = path.join(HISTORY_DIR, `${date}.json`);
  if (!fs.existsSync(file)) return null;
  try { return JSON.parse(fs.readFileSync(file, 'utf8')).articles; } catch { return null; }
}

function saveHistory(date, articles) {
  if (!fs.existsSync(HISTORY_DIR)) fs.mkdirSync(HISTORY_DIR, { recursive: true });
  fs.writeFileSync(path.join(HISTORY_DIR, `${date}.json`), JSON.stringify({ date, articles }, null, 2));
}

function saveDataFile(date) {
  // Rebuild analytics-data.json from all history snapshots so the dashboard artifact stays current.
  const snapshotFiles = fs.readdirSync(HISTORY_DIR).filter(f => f.endsWith('.json')).sort();
  const snapshots = {};
  for (const f of snapshotFiles) {
    try {
      const d = JSON.parse(fs.readFileSync(path.join(HISTORY_DIR, f), 'utf8'));
      snapshots[d.date] = d.articles;
    } catch {}
  }
  const dataPath = path.join(__dirname, 'analytics-data.json');
  fs.writeFileSync(dataPath, JSON.stringify({ generated: date, snapshots }, null, 2));
  console.log(`Dashboard data file updated: analytics-data.json (${snapshotFiles.length} snapshots)`);
}

function fmt(n) { return n.toLocaleString('en-US'); }
function delta(now, prev) {
  if (prev === undefined || prev === null) return '—';
  const d = now - prev;
  if (d > 0) return `+${d} ✅`;
  if (d < 0) return `${d} ⚠️`;
  return '0';
}

(async () => {
  console.log(`TDS Analytics check — ${today}`);
  const articles = await scrape();

  if (!articles.length) {
    console.error('No articles found — check login or page structure');
    process.exit(1);
  }

  saveHistory(today, articles);
  const prev = loadHistory(yesterday);

  // Match helper: slug first (survives title renames), fall back to exact title
  const match = (prev, a) => prev?.find(r =>
    (a.slug && r.slug && a.slug === r.slug) || r.title === a.title
  );

  // Print to console
  console.log(`\nFound ${articles.length} articles\n`);
  for (const a of articles) {
    const p = match(prev, a);
    console.log(`${a.title.slice(0, 55).padEnd(55)} | 30D: ${fmt(a.engagedViews30d).padStart(5)} | Δ: ${delta(a.engagedViews30d, p?.engagedViews30d)}`);
  }

  // Build GitHub Actions step summary (markdown)
  const totalEngaged    = articles.reduce((s, a) => s + a.engagedViews, 0);
  const total30d        = articles.reduce((s, a) => s + a.engagedViews30d, 0);
  const prevTotal30d    = prev ? prev.reduce((s, a) => s + a.engagedViews30d, 0) : null;
  const totalDelta      = prevTotal30d !== null ? total30d - prevTotal30d : null;
  const totalDeltaStr   = totalDelta === null ? '—' : totalDelta > 0 ? `+${totalDelta} ✅` : totalDelta < 0 ? `${totalDelta} ⚠️` : '0';

  const lines = [
    `## 📊 TDS Analytics — ${today}`,
    '',
    `**Total engaged views (all time):** ${fmt(totalEngaged)}  `,
    `**Total engaged views (30D):** ${fmt(total30d)} (${totalDeltaStr} vs yesterday's snapshot)`,
    '',
    `| Article | Published | Pageviews | Engaged (all) | Engaged (30D) | Δ 30D | Payout |`,
    `|---|---|---|---|---|---|---|`,
  ];

  for (const a of articles) {
    const p   = match(prev, a);
    const d   = delta(a.engagedViews30d, p?.engagedViews30d);
    const t   = a.title.length > 50 ? a.title.slice(0, 47) + '…' : a.title;
    lines.push(`| ${t} | ${a.published} | ${fmt(a.pageviews)} | ${fmt(a.engagedViews)} | ${fmt(a.engagedViews30d)} | ${d} | ${a.payout} |`);
  }

  lines.push('');
  lines.push(`> ⏱ Engaged views update with a 3–5 day delay — daily deltas may show 0 on unchanged days.`);
  lines.push(`> 📁 Snapshot saved: \`analytics-history/${today}.json\``);

  const md = lines.join('\n');
  console.log('\n--- GitHub Summary ---\n' + md);

  if (SUMMARY) fs.appendFileSync(SUMMARY, md + '\n');

  saveDataFile(today);
})();
