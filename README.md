# reader-sim: commands

Simulated readers for testing visits on a site you own. Servers are created,
used and destroyed automatically through the Vultr API.

All commands are run from this folder:

```bash
cd "/Users/abduldattijo/Downloads/01_Code_Projects/AI_Blog_Agent/article blog  agent/reader-sim"
```

---

## 1. Run a test (creates 3 servers, runs readers, destroys the servers)

```bash
./run-test.sh https://towardsdatascience.com/your-article-slug 1 120
```

The values are: the URL, readers per server (1–10), seconds each reader stays (default 70).
3 servers run in parallel (Frankfurt, New Jersey, Singapore) = 3 readers total when N=1.

Check everything without creating any servers:

```bash
./run-test.sh https://towardsdatascience.com/your-article-slug 1 120 --dry-run
```

### Direct article vs LinkedIn referral

The script detects the URL type automatically — no flag needed.

**Direct read** (no social platform involved):
```bash
./run-test.sh https://towardsdatascience.com/your-article-slug 1 120
```

**LinkedIn referral** (reader navigates to your post, clicks the article link, then reads):
```bash
./run-test.sh "https://www.linkedin.com/feed/update/urn:li:activity:..." 1 120
```

Pass any `linkedin.com`, `lnkd.in`, `twitter.com` or `x.com` URL and social mode activates
automatically. The output shows `Mode: social click-through` and each reader's `landed on` line
confirms which page they ended up on.

In social mode the reader:
1. Navigates to the LinkedIn post
2. Expands "see more" if the post is collapsed
3. Finds the article link (article hosts like `towardsdatascience.com` are prioritised over
   code repos like `github.com`; LinkedIn's redirect wrappers are decoded automatically)
4. Navigates to the article with the LinkedIn post URL as the `Referer` header —
   TDS analytics will attribute the visit to LinkedIn

**Note on LinkedIn proxy reliability**: Scrapfly's residential proxies block `linkedin.com`
for some country draws. If a reader fails with `ERR_SOCKS_CONNECTION_FAILED`, retry — the
next run will draw different countries and usually succeeds.

### Browser mode: Scrapfly (recommended) vs local Chromium

If the line `scrapfly api key: ...` is in `../local-secrets/api keys.md`, the script
automatically uses Scrapfly's cloud browser — no proxy needed, Cloudflare-protected sites
(Medium, Towards Data Science, etc.) are reached reliably. The plan line shows:

```
Browser: Scrapfly cloud browser, countries: fra->it (Italy)  ewr->pl (Poland)  sgp->au (Australia)
```

**Scrapfly concurrency limit**: the DISCOVERY plan allows 5 concurrent sessions. Use **`N=1`**
(3 readers total) to stay safely under the cap. Using `N=2` (6 total) occasionally fails one
reader; `N=3+` will fail most of them. Run the command twice if you need more readers.

**Countries are randomised on every run.** Each run draws 3 different countries from a pool
of 15 (us, gb, de, fr, ca, au, jp, sg, br, nl, se, es, it, pl, in) and assigns one per server.
The `Browser:` line shows which three were picked with full country names, e.g.
`fra->it (Italy)  ewr->pl (Poland)  sgp->au (Australia)`. Running the same article twice
will use different countries.

Without a Scrapfly key the script falls back to local Chromium + stealth plugin, with optional
residential proxy (section 6).

### What the run prints

- Each step as it happens: account check, servers created, their IPs.
- While waiting for the servers to install (2–3 minutes), a progress line every 30 seconds.
- After readers finish: one line per server showing reached/total, scroll-ups, text selections,
  and the `landed on` path + page title for each reader.
- `Total: N reached, M failed` summary.
- If any reader failed, a `Failure reasons:` list.
- Cleanup block ending with `HTTP 204` per server and `Done.`

### How each reader behaves

- Opens the page in a fresh browser (no cookies), staggered start (0 s, 8 s, 16 s …)
  to avoid hitting Scrapfly's rate limit.
- `navigator.webdriver` reports `false` (stealth plugin for local; Scrapfly handles it natively).
- Mouse moves along a smooth curved bezier path, not an instant jump.
- Scrolls down in small wheel ticks (35–70 px); about 1 in 5 steps scrolls back up to re-read.
- Pause depends on position: longer at the top (5–9 s) and bottom (4–8 s),
  shorter in the middle (2–5 s), with an occasional extra-long stop.
- Randomly selects text: 15% chance per scroll step — double-clicks a word or drag-selects
  a short line (controlled by `TEXT_SELECT_PROB`, default 0.15).
- 25% chance of clicking one internal link 40–65% of the way through, then keeps reading
  (controlled by `CLICK_LINK_PROB`, default 0.25). A click adds a second pageview.
  Login, checkout, delete, file and external links are never clicked.

### Why N=1 (one reader per server)?

Scrapfly's DISCOVERY plan allows **5 concurrent sessions**. All 3 servers run simultaneously,
so each reader on each server opens a session at the same time:

| N | Total readers | Concurrent sessions | Result |
|---|---|---|---|
| 1 | 3 | 3 | ✅ safe |
| 2 | 6 | 6 | ❌ over limit — readers fail |
| 3 | 9 | 9 | ❌ over limit — most fail |

To get more than 3 readers, run the command twice — each run creates new servers, runs 3
readers, and destroys them. Two runs back-to-back = 6 readers total.

### Override env vars

```bash
# Direct article — higher click and text selection rates
CLICK_LINK_PROB=0.5 TEXT_SELECT_PROB=0.3 ./run-test.sh https://towardsdatascience.com/ai-slop-is-now-in-your-training-dataset-i-tested-three-ways-to-spot-it/ 1 120

# LinkedIn referral — same overrides work in social mode
CLICK_LINK_PROB=0.5 TEXT_SELECT_PROB=0.3 ./run-test.sh "https://www.linkedin.com/feed/update/urn:li:activity:7515354942174306305/" 1 120
```

| Var | Default | What it does |
|---|---|---|
| `CLICK_LINK_PROB` | `0.25` | Chance (0–1) a reader clicks one internal link |
| `TEXT_SELECT_PROB` | `0.15` | Chance per scroll step of selecting a word or line |

---

## 2. Change the test URL

Change the first value. Examples:

```bash
# Direct article read
./run-test.sh https://towardsdatascience.com/your-article-slug 1 120

# LinkedIn referral (full post URL — more reliable than lnkd.in shortlinks)
./run-test.sh "https://www.linkedin.com/feed/update/urn:li:activity:7515354942174306305/" 1 120
```

Rules: use the full `https://` address; always quote LinkedIn URLs (they contain `:` characters);
use a page that does not need login.

---

## 3. Destroy running servers (stop billing)

See what is running:

```bash
./destroy-servers.sh --list
```

Destroy them (it asks you to type yes):

```bash
./destroy-servers.sh
```

Destroy without asking:

```bash
./destroy-servers.sh --yes
```

Only servers whose name starts with `reader-` are touched.
Powering a server off does NOT stop billing. Only destroying it does.
The automated run in section 1 destroys its own servers when it finishes.

---

## 4. Run readers from your Mac only (no servers)

```bash
SF_KEY="$(grep -i '^scrapfly api key:' "../local-secrets/api keys.md" | head -1 | sed -E 's/^[^:]*:[[:space:]]*//' | tr -d '[:space:]')"
SCRAPFLY_API_KEY="$SF_KEY" SCRAPFLY_COUNTRY=us node reader.js \
  https://towardsdatascience.com/your-article-slug local 1 120
```

Or with local Chromium (no Scrapfly):

```bash
NO_AUTOMATION_FLAG=1 node reader.js https://usehomesteados.com/pricing test1 1 70
```

The values are: URL, a label, number of readers, seconds each stays.

---

## 5. Run readers on an existing server (manual)

```bash
vps/run_key.sh <label> <server-ip> <url> <readers> [seconds]
```

---

## 6. Send readers through a residential proxy (local Chromium only)

Only applies when **not** using Scrapfly. By default the servers use Vultr data-center IPs.
To route each server's browser through a residential IP, put `USE_PROXY=1` in front.

```bash
USE_PROXY=1 ./run-test.sh https://usehomesteados.com/pricing 5
USE_PROXY=1 PROXY_PROVIDER=decodo ./run-test.sh https://usehomesteados.com/pricing 5 120
```

| What you type before the command | What the readers use |
|---|---|
| nothing | Vultr data-center IPs, no proxy |
| `USE_PROXY=1` | DataImpulse (default provider) |
| `USE_PROXY=1 PROXY_PROVIDER=decodo` | Decodo |

The run prints a `Proxy:` line before it creates any server.
`--dry-run` shows the same line without creating anything.

Note: if a Scrapfly key is present in the secrets file, `USE_PROXY` is ignored — Scrapfly
takes precedence and handles its own proxying.

---

## One-time setup (already done on this account)

- **Vultr API key**: the line `vultr api key: ...` in `../local-secrets/api keys.md`
  (or set the `VULTR_API_KEY` environment variable). Never commit or paste it.
- **SSH key**: `~/.ssh/vultr_reader_ed25519`, added in Vultr as `reader-sim`.
- **Startup script**: `vps/startup-script.sh`, added in Vultr as `reader-install` (Boot type).
  It installs Node 20 and Playwright. `run-test.sh` uploads the current `reader.js` and installs
  `playwright-extra` + `puppeteer-extra-plugin-stealth` on each server before running, so editing
  `reader.js` needs no change in Vultr.
- **Proxy logins** (only for `USE_PROXY=1`), as lines in `../local-secrets/api keys.md`:
  `dataimpulse login: ...` / `dataimpulse password: ...`, and/or
  `decodo login: ...` / `decodo password: ...`.
  Host and port are optional. Defaults: `gw.dataimpulse.com:823` and `gate.decodo.com:7000`.
- **Scrapfly**: the line `scrapfly api key: ...` in the same file. Auto-detected — no flag needed.
  DISCOVERY plan: 5 concurrent sessions, 200,000 credits/month (~450 residential readers).
  One reader costs about 430 credits (measured 2026-10-13).
- If a credential was ever pasted into a chat or document, reset it in the provider's dashboard.
- Vultr API access control lists allowed IPs. If a run stops with `Unauthorized IP address`,
  add your current IP at my.vultr.com → Account → API.

---

## What we found

### Towards Data Science / Medium (tested 2026-10-13 to 2026-10-14)

- Protected by Cloudflare. **Decodo residential proxies alone return HTTP 403** — Cloudflare
  blocks headless Chromium at the TLS/HTTP2 fingerprint level regardless of IP.
- **Scrapfly cloud browser**: consistent 3/3 readers reaching the real page, full 120 s read,
  text selections, scroll-ups and link clicks working. Recommended path for Cloudflare-protected sites.
- **LinkedIn social click-through**: readers navigate to a LinkedIn post, find and click the
  article link (LinkedIn redirect wrappers decoded automatically), then read the TDS article
  with `linkedin.com` as the Referer. 2/3 success rate per run; retry if a reader hits a
  proxy SOCKS error on the LinkedIn URL.

### usehomesteados.com (tested 2026-10-13, 15 readers)

- `NO_AUTOMATION_FLAG=1` is required. Without it the analytics drop the visit.
- Analytics count a visit, but session duration is always 0 and country shows "Unknown".
- Pages behind login (/dashboard, /farm-stand, /organizer) redirect to /auth.

### Proxies and Scrapfly (usehomesteados.com, same 15-reader run on each)

| Mode | Reached the page | Notes |
|---|---|---|
| Vultr IPs only | most | country "Unknown" in analytics |
| DataImpulse residential | 14/15 | 1 miss was a 30 s timeout; $1/GB |
| Decodo residential | 15/15 | $4/GB pay as you go |
| Scrapfly Cloud Browser | 3/3 | ~430 credits per reader |

---

## Files

- `reader.js` — the simulated reader (Playwright + playwright-extra). Handles stealth,
  DataImpulse/Decodo proxy, Scrapfly cloud browser, social click-through mode, text selection
  and link clicks, all switched by environment variables.
- `run-test.sh` — automated create, run, destroy. Auto-detects Scrapfly key and social URLs;
  falls back to local Chromium + optional proxy (`USE_PROXY=1`, `PROXY_PROVIDER=...`).
- `diag-proxy.sh`, `diag.js` — one-server check that prints the exit IP a browser on the
  server has, with and without the proxy (~3 minutes, destroys its server).
- `destroy-servers.sh` — list and destroy leftover `reader-*` servers.
- `vps/startup-script.sh` — boot script that prepares a server (installs Node 20 + Playwright).
- `vps/run_key.sh` — run readers on an existing server with the SSH key.
- `vps/install.sh`, `vps/run_n.sh`, `vps/askpass.sh` — older password-based helpers.
