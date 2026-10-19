// usage: node reader.js <url> <label> <readers> <seconds>
//
// Each reader gets its own browser context (fresh cookies/storage) and behaves like a
// person reading: smooth curved mouse movement, small scroll steps, occasional scroll-up,
// text selection, pauses that depend on where on the page it is, and (optionally) a click
// on an internal link.
//
// env:
//   NO_AUTOMATION_FLAG=1      launch without the "controlled by automation" marker
//   CLICK_LINK_PROB=0.25      chance (0..1) a reader clicks one internal link mid-visit
//                             (default 0.25; a click adds a 2nd pageview)
//   TEXT_SELECT_PROB=0.15     chance per scroll step of selecting a word or line of text
//                             (default 0.15)
//   GOOGLE_MODE=1             navigate to article with google.com as Referer
//   MOBILE_PCT=0.33           fraction (0..1) of readers that use a mobile viewport (default 0)
//   BOUNCE_PCT=0.20           fraction (0..1) of readers that leave early after 15-30s (default 0.20)
const path = require('path');
const fs   = require('fs');
const { chromium } = require('playwright-extra');

async function makeWebm(frames, outPath) {
  const { execFileSync } = require('child_process');
  const ffmpeg = require('ffmpeg-static');
  const os = require('os');
  if (!frames.length) return;
  const tmpDir = fs.mkdtempSync(path.join(os.tmpdir(), 'reader-frames-'));
  try {
    frames.forEach((buf, i) =>
      fs.writeFileSync(path.join(tmpDir, `f${String(i).padStart(4, '0')}.png`), buf));
    fs.mkdirSync(path.dirname(outPath), { recursive: true });
    execFileSync(ffmpeg, [
      '-y', '-framerate', '2',
      '-i', path.join(tmpDir, 'f%04d.png'),
      '-c:v', 'libvpx-vp9', '-b:v', '0', '-crf', '33',
      '-pix_fmt', 'yuv420p', outPath,
    ], { stdio: 'pipe' });
  } finally {
    fs.readdirSync(tmpDir).forEach(f => fs.unlinkSync(path.join(tmpDir, f)));
    fs.rmdirSync(tmpDir);
  }
}

async function makeGif(frames, outPath) {
  const { PNG } = require('pngjs');
  const GIFEncoder = require('gif-encoder-2');
  if (!frames.length) return;
  const first = PNG.sync.read(frames[0]);
  const enc = new GIFEncoder(first.width, first.height, 'neuquant', true);
  enc.setDelay(1500); // 3s real time per frame → 1500ms playback ≈ 2× speedup
  enc.setRepeat(0);
  enc.start();
  for (const buf of frames) {
    const img = PNG.sync.read(buf);
    enc.addFrame(img.data);
  }
  enc.finish();
  fs.mkdirSync(path.dirname(outPath), { recursive: true });
  fs.writeFileSync(outPath, enc.out.getData());
}

async function makeRecording(frames, outPath) {
  let hasffmpeg = false;
  try { require('ffmpeg-static'); hasffmpeg = true; } catch (_) {}
  if (hasffmpeg) {
    await makeWebm(frames, outPath);
  } else {
    await makeGif(frames, outPath.replace(/\.webm$/, '.gif'));
  }
}

const SESSION_FILE = path.join(__dirname, '../local-secrets/tds-session.json');
// Stealth is only needed for local Chromium — Scrapfly handles fingerprinting server-side.
if (!process.env.SCRAPFLY_API_KEY) {
  const StealthPlugin = require('puppeteer-extra-plugin-stealth');
  chromium.use(StealthPlugin());
}

const [, , url, label = 'run', n = '2', secs = '450'] = process.argv;
const readers = Number(n);
const stay = Number(secs) * 1000;
const clickProb = Math.min(1, Math.max(0, Number(process.env.CLICK_LINK_PROB ?? 0.25)));
const selectProb = Math.min(1, Math.max(0, Number(process.env.TEXT_SELECT_PROB ?? 0.15)));

const sleep = (ms) => new Promise((r) => setTimeout(r, Math.max(0, ms)));
const rand = (a, b) => a + Math.random() * (b - a);

// Links a reader will never click (login, checkout, destructive, files, non-http).
const AVOID = /auth|login|logout|signout|sign-out|signin|sign-in|signup|sign-up|register|checkout|cart|delete|remove|stripe|unsubscribe|mailto:|tel:|\.(pdf|zip|png|jpe?g|gif|svg|mp4)(\?|$)/i;

// Smooth curved mouse path (quadratic bezier with a random bend), not an instant jump.
async function moveMouse(page, pos, x, y) {
  const points = Math.floor(rand(14, 26));
  const cx = (pos.x + x) / 2 + rand(-120, 120);
  const cy = (pos.y + y) / 2 + rand(-80, 80);
  for (let i = 1; i <= points; i++) {
    const t = i / points;
    const px = (1 - t) * (1 - t) * pos.x + 2 * (1 - t) * t * cx + t * t * x;
    const py = (1 - t) * (1 - t) * pos.y + 2 * (1 - t) * t * cy + t * t * y;
    await page.mouse.move(px, py);
    await sleep(rand(8, 22));
  }
  pos.x = x;
  pos.y = y;
}

// Scroll in many small wheel ticks so it looks like a trackpad/wheel, not a teleport.
async function smoothScroll(page, dy) {
  const dir = Math.sign(dy);
  let left = Math.abs(dy);
  while (left > 0) {
    const tick = Math.min(left, rand(35, 70));
    await page.mouse.wheel(0, dir * tick);
    left -= tick;
    await sleep(rand(12, 32));
  }
}

async function scrollInfo(page) {
  return page.evaluate(() => {
    const el = document.scrollingElement || document.documentElement;
    return { y: el.scrollTop, h: el.scrollHeight, vh: window.innerHeight };
  }).catch(() => ({ y: 0, h: 0, vh: 768 }));
}

// Returns what kind of content is currently visible in the viewport.
async function viewportContent(page) {
  return page.evaluate(() => {
    const vh = window.innerHeight;
    const inView = el => { const r = el.getBoundingClientRect(); return r.top < vh && r.bottom > 0; };
    return {
      hasCode:  [...document.querySelectorAll('pre')].some(inView),
      hasImage: [...document.querySelectorAll('img, figure, [data-testid="image"]')].some(inView),
      hasHead:  [...document.querySelectorAll('h1,h2,h3,h4')].some(inView),
    };
  }).catch(() => ({}));
}

// Simulate a reader switching to another tab and coming back.
async function simulateTabSwitch(page) {
  await page.evaluate(() => {
    try {
      Object.defineProperty(document, 'hidden', { value: true, configurable: true, writable: true });
      document.dispatchEvent(new Event('visibilitychange'));
    } catch (e) {}
  });
  await sleep(rand(4000, 18000));
  await page.evaluate(() => {
    try {
      Object.defineProperty(document, 'hidden', { value: false, configurable: true, writable: true });
      document.dispatchEvent(new Event('visibilitychange'));
    } catch (e) {}
  });
}

// Pause length depends on where the reader is on the page.
function pauseFor(progress) {
  let lo, hi;
  if (progress < 0.1) { lo = 8; hi = 15; }       // top: headline / hero, read carefully
  else if (progress > 0.9) { lo = 6; hi = 12; }  // bottom: last section / footer
  else { lo = 4; hi = 9; }                        // middle: steady reading
  let s = rand(lo, hi);
  if (Math.random() < 0.12) s += rand(8, 18);    // occasionally stops to read something closely
  return s * 1000;
}

async function pickInternalLink(page) {
  const links = await page.locator('a[href^="/"]:visible').evaluateAll((as) =>
    as.map((a, i) => ({ i, href: a.getAttribute('href') || '' })));
  const SHORT_PATH = /\/(category|tag|videos?|author|topic|archive|page|search|feed|privacy|terms|about|contact|advertise|membership|newsletter|u\/|sign-?in|sign-?up|login|logout|cookie|legal|policy|imprint)\b/i;
  const ok = links.filter((l) => {
    if (l.href.startsWith('//') || l.href === '/' || AVOID.test(l.href)) return false;
    if (SHORT_PATH.test(l.href)) return false;
    // Only follow article-like slugs: path must have at least one segment with dashes (a title slug).
    const parts = l.href.split('/').filter(Boolean);
    return parts.length >= 1 && parts[parts.length - 1].includes('-');
  });
  if (!ok.length) return null;
  return ok[Math.floor(Math.random() * ok.length)];
}

// Simulate a reader selecting text: either double-click a word or drag-select a short span.
async function selectText(page, pos) {
  const x = rand(150, 1100);
  const y = rand(200, 620);
  if (Math.random() < 0.5) {
    await moveMouse(page, pos, x, y);
    await page.mouse.dblclick(x, y);                      // selects one word
  } else {
    const x2 = x + rand(60, 200);
    await moveMouse(page, pos, x, y);
    await page.mouse.down();
    await page.mouse.move(x2, y + rand(-4, 4), { steps: 12 });
    await page.mouse.up();                                 // drag-selects a line fragment
  }
}

// Scrapfly Cloud Browser: one separate remote session per reader.
function connectScrapfly(mobile) {
  const params = new URLSearchParams({
    api_key: process.env.SCRAPFLY_API_KEY,
    proxy_pool: process.env.SCRAPFLY_PROXY_POOL || 'residential',
    country: process.env.SCRAPFLY_COUNTRY || 'us',
    os: mobile ? 'android' : 'windows',
    target_url: url,
    timeout: String(Math.ceil(stay / 1000) + 120),
  });
  return chromium.connectOverCDP(`wss://browser.scrapfly.io?${params}`);
}

// DataImpulse residential proxy (optional). env: DATAIMPULSE_LOGIN, DATAIMPULSE_PASSWORD,
// DATAIMPULSE_HOST (default gw.dataimpulse.com), DATAIMPULSE_PORT (default 823),
// DATAIMPULSE_COUNTRY (e.g. us, de; added to the login as login__cr.<country>).
function dataImpulseProxy() {
  // Decodo (env: DECODO_LOGIN, DECODO_PASSWORD, DECODO_HOST=gate.decodo.com, DECODO_PORT=7000,
  // DECODO_COUNTRY). Username format: user-<login>-country-<cc>.
  if (process.env.DECODO_LOGIN) {
    const cc = process.env.DECODO_COUNTRY;
    const user = `user-${process.env.DECODO_LOGIN}` + (cc ? `-country-${cc.toLowerCase()}` : '');
    return { proxy: {
      server: `http://${process.env.DECODO_HOST || 'gate.decodo.com'}:${process.env.DECODO_PORT || 7000}`,
      username: user, password: process.env.DECODO_PASSWORD } };
  }
  const login = process.env.DATAIMPULSE_LOGIN;
  if (!login) return {};
  const cc = process.env.DATAIMPULSE_COUNTRY;
  return {
    proxy: {
      server: `http://${process.env.DATAIMPULSE_HOST || 'gw.dataimpulse.com'}:${process.env.DATAIMPULSE_PORT || 823}`,
      username: cc ? `${login}__cr.${cc.toLowerCase()}` : login,
      password: process.env.DATAIMPULSE_PASSWORD,
    },
  };
}

async function readerRun(browser, i) {
  const remote = !!process.env.SCRAPFLY_API_KEY;
  const mobilePct = parseFloat(process.env.MOBILE_PCT ?? '0');
  const mobile = Math.random() < mobilePct;
  const bouncePct = parseFloat(process.env.BOUNCE_PCT ?? '0.20');
  const willBounce = Math.random() < bouncePct;
  const bounceAfterMs = willBounce ? rand(15000, 30000) : Infinity;

  // Per-reader personality — each simulated person behaves differently.
  const readMult    = rand(0.60, 1.60);          // skim (60%) to deep-read (160%) of base time
  const readerStay  = Math.round(stay * readMult);
  const tabSwitchP  = rand(0.02, 0.30);          // focused reader to heavy multitasker
  const scrollUpP   = rand(0.05, 0.18);          // occasionally re-reads a section; net progress stays forward
  const domBonusP   = rand(0.15, 0.70);          // glances past images to studies every chart
  const keyboardP   = rand(0.05, 0.35);          // mostly mouse to keyboard-first scroller
  const mySelectP   = rand(0.03, 0.38);          // never highlights to highlights constantly

  // Scrapfly rate-limits concurrent new sessions; stagger by index (8s apart).
  // Local browsers just need a small random jitter.
  await sleep(process.env.SCRAPFLY_API_KEY ? i * 8000 + rand(0, 1500) : rand(0, 5000));
  const start = Date.now();
  const startedAt = new Date().toISOString();
  const pos = { x: rand(200, 900), y: rand(150, 500) };
  const willClick = Math.random() < clickProb;
  const clickAt = start + readerStay * rand(0.4, 0.65);
  let clicked = null, scrollUps = 0, steps = 0, textSelections = 0, status = 'ok';
  let httpStatus = null, title = null, words = null, reached = false, notReached = null;
  let bounced = false, scrolledToComments = false, secondVisit = false;
  let readTime = readerStay;
  let ctx = null, page = null;
  const gifFrames = [];
  let gifTimer = null;
  const secondUrl = process.env.SECOND_URL || null;
  const secondProb = parseFloat(process.env.SECOND_READ_PROB ?? '0.35');
  const tracked = [];

  try {
    if (remote) browser = await connectScrapfly(mobile);
    const vp = mobile ? { width: 390, height: 844 } : { width: 1366, height: 768 };
    const recordVideo = process.env.RECORD
      ? { dir: path.join(__dirname, 'recordings'), size: vp }
      : undefined;
    ctx = remote
      ? (browser.contexts()[0] || await browser.newContext())
      : await browser.newContext({ viewport: vp, ...dataImpulseProxy(), ...(recordVideo ? { recordVideo } : {}) });
    page = remote ? (ctx.pages()[0] || await ctx.newPage()) : await ctx.newPage();
    if (remote && mobile) await page.setViewportSize({ width: 390, height: 844 });
    // Inject saved TDS session cookies when running locally in visible mode.
    if (!remote && process.env.HEADLESS === '0' && fs.existsSync(SESSION_FILE)) {
      const cookies = JSON.parse(fs.readFileSync(SESSION_FILE, 'utf8'));
      await ctx.addCookies(cookies);
    }
    page.on('request', (r) => {
      if (r.url().includes('/__l5e/')) tracked.push(`${r.method()} ${new URL(r.url()).pathname}`);
    });

    const social = process.env.SOCIAL_MODE === '1';
    const googleMode = process.env.GOOGLE_MODE === '1';
    const timeout = process.env.SCRAPFLY_API_KEY ? 60000 : 30000;

    if (social) {
      // Navigate to the social post, click through to the article.
      await page.goto(url, { waitUntil: 'load', timeout });
      await sleep(rand(2000, 4000));
      // Expand "see more" if present so all links are in the DOM.
      await page.locator('button:has-text("…more"), button:has-text("see more")').first()
        .click({ timeout: 3000 }).catch(() => {});
      await sleep(rand(500, 1000));
      // Find the best external link: article hosts first, code hosts last, skip social.
      // LinkedIn wraps outbound links as linkedin.com/redir/redirect?url=<dest> — unwrap those.
      const linkInfo = await page.evaluate(() => {
        const socialHosts  = ['linkedin.com', 'lnkd.in', 'twitter.com', 'x.com', 'facebook.com', 't.co'];
        const codeHosts    = ['github.com', 'gitlab.com', 'bitbucket.org', 'gist.github.com'];
        const articleHosts = ['towardsdatascience.com', 'medium.com', 'substack.com', 'ghost.io', 'hashnode.dev', 'dev.to'];
        const avoid = /auth|login|logout|signup|register|javascript:|mailto:|tel:/i;
        const unwrap = href => {
          try {
            const u = new URL(href);
            if (socialHosts.some(h => u.hostname.endsWith(h))) {
              const dest = u.searchParams.get('url') || u.searchParams.get('redirectUrl');
              if (dest) return decodeURIComponent(dest);
            }
          } catch(e) {}
          return href;
        };
        const cands = Array.from(document.querySelectorAll('a[href]')).map(a => ({
          el: a, eff: unwrap(a.href),
        })).filter(({ eff }) => {
          try {
            const u = new URL(eff);
            return u.protocol.startsWith('http') &&
                   !socialHosts.some(h => u.hostname.endsWith(h)) &&
                   !avoid.test(eff) && u.pathname.length > 1;
          } catch(e) { return false; }
        });
        const score = eff => {
          try {
            const host = new URL(eff).hostname;
            if (articleHosts.some(h => host.endsWith(h))) return 100;
            if (codeHosts.some(h => host.endsWith(h))) return 1;
            return new URL(eff).pathname.split('/').filter(Boolean).length;
          } catch(e) { return 0; }
        };
        cands.sort((a, b) => score(b.eff) - score(a.eff));
        if (!cands.length) return null;
        const { el, eff } = cands[0];
        const r = el.getBoundingClientRect();
        return { href: eff, x: r.left + r.width / 2, y: r.top + r.height / 2 };
      });
      if (!linkInfo) throw new Error('no external article link found in social post');
      // Scroll the link into view, re-read its coordinates, then click via mouse.
      await page.evaluate(href => {
        const el = [...document.querySelectorAll('a[href]')].find(a => a.href === href);
        if (el) el.scrollIntoView({ block: 'center' });
      }, linkInfo.href);
      await sleep(rand(500, 1000));
      const coords = await page.evaluate(href => {
        const el = [...document.querySelectorAll('a[href]')].find(a => a.href === href);
        if (!el) return null;
        const r = el.getBoundingClientRect();
        return { x: r.left + r.width / 2, y: r.top + r.height / 2 };
      }, linkInfo.href);
      // Hover over the link for realism, then navigate with the LinkedIn post URL
      // as the Referer header — TDS analytics reads this to attribute traffic to LinkedIn.
      if (coords && coords.x > 0 && coords.y > 0) {
        await moveMouse(page, pos, coords.x, coords.y);
        await sleep(rand(300, 700));
      }
      const referer = page.url(); // the linkedin.com/posts/... URL after the lnkd.in redirect
      const resp2 = await page.goto(linkInfo.href, { waitUntil: 'load', timeout, referer });
      httpStatus = resp2 ? resp2.status() : null;
      await sleep(rand(1000, 2000));
    } else if (googleMode) {
      // Arrive as if the reader clicked a Google search result.
      const slug = url.split('/').filter(Boolean).pop() || 'article';
      const query = encodeURIComponent(slug.replace(/-/g, ' '));
      const resp = await page.goto(url, {
        waitUntil: 'load', timeout,
        referer: `https://www.google.com/search?q=${query}`,
      });
      httpStatus = resp ? resp.status() : null;
    } else {
      const resp = await page.goto(url, { waitUntil: 'load', timeout });
      httpStatus = resp ? resp.status() : null;
    }

    // Dismiss cookie consent and sticky banners — run twice (immediately + after 2s) because
    // TDS/Medium banners often appear a couple of seconds after the initial page load.
    async function dismissBanners() {
      await page.evaluate(() => {
        // Cookie consent: prefer reject, fall back to accept so the page isn't frozen.
        const rejectRe = /reject all|reject cookies|decline|necessary only|accept required/i;
        const acceptRe = /accept all|accept cookies|agree/i;
        const closeRe  = /^close$|^dismiss$|^no thanks$/i;
        const btns = [...document.querySelectorAll('button, [role="button"]')];
        const reject = btns.find(b => rejectRe.test(b.innerText || b.getAttribute('aria-label') || ''));
        if (reject) { reject.click(); }
        else {
          const accept = btns.find(b => acceptRe.test(b.innerText || b.getAttribute('aria-label') || ''));
          if (accept) accept.click();
        }
        // Close sticky newsletter / promo bars (Medium partner bars, TDS subscription nag).
        const close = btns.find(b =>
          closeRe.test(b.innerText || '') ||
          /close/i.test(b.getAttribute('aria-label') || '') ||
          b.getAttribute('data-testid') === 'close-button'
        );
        if (close) close.click();
      }).catch(() => {});
    }
    await dismissBanners();
    await sleep(2000);
    await dismissBanners(); // second pass catches banners that load after initial render
    await sleep(rand(300, 600));

    // SCREENSHOT=1: save a screenshot of what the browser sees at page load.
    if (process.env.SCREENSHOT) {
      const screenshotPath = path.join(__dirname, `screenshot-reader${i + 1}.png`);
      await page.screenshot({ path: screenshotPath, fullPage: true }).catch(() => {});
      console.error(`[screenshot] saved ${screenshotPath}`);
    }

    // RECORD=1 on remote (Scrapfly): capture frames every 3s and stitch into a GIF.
    if (process.env.RECORD && remote) {
      gifTimer = setInterval(async () => {
        const buf = await page.screenshot({ fullPage: false }).catch(() => null);
        if (buf) gifFrames.push(buf);
      }, 3000);
    }

    // Did we get the real page, or a block / challenge / error page?
    // Single-page apps render after "load", so give the text a few seconds to appear.
    for (let t = 0; t < 5; t++) {
      const probe = await page.evaluate(() => ({
        title: document.title,
        words: (document.body.innerText || '').split(/\s+/).filter(Boolean).length,
      })).catch(() => ({ title: null, words: null }));
      title = probe.title; words = probe.words;
      if (words !== null && words >= 30) break;
      await sleep(1000);
    }
    const BLOCKED = /just a moment|attention required|access denied|you have been blocked|verify you are human|are you a robot|captcha|\bforbidden\b|security check|\bnot found\b|\b40[0-9]\b|\b50[0-9]\b|\berror\b/i;
    if (httpStatus !== null && httpStatus >= 400) notReached = `HTTP ${httpStatus}`;
    else if (title && BLOCKED.test(title)) notReached = `block or error page ("${title}")`;
    else if (words !== null && words < 30) notReached = `almost empty page (${words} words)`;
    reached = !notReached;

    // Adjust read time based on article length (~250 WPM = 240ms/word for careful reading).
    // Clamped between 120s and the original stay time.
    if (reached && words && words > 100) {
      readTime = Math.max(120000, Math.min(readerStay, words * 240));
    }

    // A person who lands on a block page leaves; do the same instead of "reading" it.
    while (reached && Date.now() - start < readTime) {  // eslint-disable-line no-constant-condition
      const info = await scrollInfo(page);
      const maxY = Math.max(1, info.h - info.vh);
      const progress = Math.min(1, info.y / maxY);

      // Early bounce: reader leaves after 15-30s without reading the whole article.
      if (Date.now() - start >= bounceAfterMs) { bounced = true; break; }

      // Near the bottom: finish reading, then either stop or scroll back up to re-read a section.
      if (!scrolledToComments && progress >= 0.85) {
        // Scroll to the very bottom.
        const info2 = await scrollInfo(page);
        const toBottom = info2.h - info2.y - info2.vh;
        if (toBottom > 50) await smoothScroll(page, toBottom);
        scrolledToComments = true;
        await sleep(rand(4000, 9000)); // pause at bottom to read conclusion / comments
        // 45% of readers scroll back up to re-read a section before leaving.
        if (Math.random() < 0.45 && readTime - (Date.now() - start) > 20000) {
          const scrollBackDist = rand(0.3, 0.7); // scroll back 30-70% of the page
          const info3 = await scrollInfo(page);
          await smoothScroll(page, -info3.h * scrollBackDist);
          scrollUps++;
          await sleep(rand(5000, 12000)); // read the re-visited section
          // then scroll forward again slowly to the end
          const info4 = await scrollInfo(page);
          const remaining = info4.h - info4.y - info4.vh;
          if (remaining > 100) await smoothScroll(page, remaining);
          await sleep(rand(3000, 6000));
        }
        break;
      }

      if (willClick && !clicked && Date.now() >= clickAt) {
        const link = await pickInternalLink(page);
        if (link) {
          const loc = page.locator('a[href^="/"]:visible').nth(link.i);
          try {
            await loc.scrollIntoViewIfNeeded({ timeout: 4000 });
            const box = await loc.boundingBox();
            if (box) await moveMouse(page, pos, box.x + box.width / 2, box.y + box.height / 2);
            await loc.click({ timeout: 5000 });
            clicked = link.href;
            await sleep(1500); // let the new page render
          } catch (e) { clicked = 'click-failed'; }
        } else {
          clicked = 'no-link-found';
        }
        continue;
      }

      // Occasionally select a word or line of text before scrolling.
      if (Math.random() < mySelectP) {
        await selectText(page, pos);
        textSelections++;
        await sleep(rand(400, 1200));
      }

      // Occasionally simulate switching to another tab and coming back.
      if (Math.random() < tabSwitchP) {
        await simulateTabSwitch(page);
      }

      // Mostly read downward; sometimes scroll back up to re-read.
      const goUp = info.y > 400 && Math.random() < scrollUpP;
      if (goUp) {
        await smoothScroll(page, -rand(60, 200));
        scrollUps++;
      } else if (Math.random() < keyboardP) {
        // Keyboard-based scroll: use arrow keys for slow deliberate reading.
        const key = Math.random() < 0.5 ? 'ArrowDown' : (Math.random() < 0.5 ? 'Space' : 'PageDown');
        await page.keyboard.press(key);
      } else {
        await smoothScroll(page, rand(80, 250));  // deliberate reading pace, reaches bottom in ~450s
      }
      steps++;

      await moveMouse(page, pos, rand(100, 1250), rand(100, 680));

      // DOM-aware pause: linger longer at code blocks, images, and section headers.
      const vc = await viewportContent(page);
      const domBonus = Math.random() < domBonusP
        ? (vc.hasCode ? rand(1500, 3500) : vc.hasImage ? rand(1000, 2500) : vc.hasHead ? rand(500, 1500) : 0)
        : 0;

      const after = await scrollInfo(page);
      const p2 = Math.min(1, after.y / Math.max(1, after.h - after.vh));
      const left = readTime - (Date.now() - start);
      await sleep(Math.min(pauseFor(p2) + domBonus, left));
    }

    // Second article: ~35% of full readers navigate to another article after finishing.
    // Uses the current page as referer, simulating a click from the article's related section.
    if (secondUrl && reached && !bounced && Math.random() < secondProb) {
      const referer = page.url();
      await sleep(rand(2000, 5000)); // pause before clicking to next article
      await page.goto(secondUrl, { waitUntil: 'load', timeout, referer }).catch(() => {});
      await sleep(rand(1500, 3000));
      const secondDuration = rand(30000, 60000);
      const secondStart = Date.now();
      while (Date.now() - secondStart < secondDuration) {
        await smoothScroll(page, rand(150, 400));
        await sleep(pauseFor(0.5));
      }
      secondVisit = true;
    }
  } catch (e) {
    status = 'error: ' + e.message.split('\n')[0];
  }
  const seconds = Math.round((Date.now() - start) / 1000);
  const webdriver = page ? await page.evaluate(() => navigator.webdriver).catch(() => null) : null;
  let finalPath = null;
  if (page) try { finalPath = new URL(page.url()).pathname; } catch (e) {}
  if (gifTimer) clearInterval(gifTimer);
  if (gifFrames.length) {
    const recPath = path.join(__dirname, 'recordings', `reader${i + 1}-${Date.now()}.webm`);
    await makeRecording(gifFrames, recPath).catch(e => console.error('[recording error]', e.message));
    const saved = recPath.replace(/\.webm$/, '') + ((() => { try { require('ffmpeg-static'); return '.webm'; } catch(_) { return '.gif'; } })());
    console.error(`[recording] ${saved}`);
  }
  if (remote) { if (browser) await browser.close().catch(() => {}); }
  else if (ctx) {
    if (process.env.RECORD && page) {
      const videoPath = await page.video()?.path().catch(() => null);
      await ctx.close();
      if (videoPath) {
        const dest = path.join(__dirname, 'recordings', `reader${i + 1}-${Date.now()}.webm`);
        fs.mkdirSync(path.dirname(dest), { recursive: true });
        try { fs.renameSync(videoPath, dest); } catch (_) {}
        console.error(`[recording] ${dest}`);
      }
    } else {
      await ctx.close();
    }
  }
  return {
    label, reader: i + 1, startedAt, seconds, status, webdriver,
    reached, notReached, httpStatus, title, words,
    mobile, bounced, scrolledToComments, secondVisit,
    steps, scrollUps, textSelections, clicked, finalPath,
    trackedRequests: tracked.length, tracked: [...new Set(tracked)],
  };
}

(async () => {
  // NO_AUTOMATION_FLAG=1 launches without the "controlled by automation" marker,
  // so we can tell whether analytics filter on that flag or on the network.
  const args = process.env.NO_AUTOMATION_FLAG ? ['--disable-blink-features=AutomationControlled'] : [];
  // SCRAPFLY_API_KEY set: each reader runs in its own Scrapfly Cloud Browser session
  //   (SCRAPFLY_PROXY_POOL=residential|datacenter, SCRAPFLY_COUNTRY=us).
  const browser = process.env.SCRAPFLY_API_KEY ? null : await chromium.launch({
    args,
    headless: process.env.HEADLESS !== '0',
  });
  const results = await Promise.all(Array.from({ length: readers }, (_, i) => readerRun(browser, i)));
  if (browser) await browser.close();
  for (const r of results) console.log(JSON.stringify(r));
})();
