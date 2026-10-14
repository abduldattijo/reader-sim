// Runs ON the server: prints the proxy env (presence only) and the exit IP seen by a browser,
// first with no proxy, then with the DataImpulse proxy built the same way as reader.js.
const { chromium } = require('playwright');
const e = process.env;
console.log('env present:', {
  host: !!e.DATAIMPULSE_HOST, port: e.DATAIMPULSE_PORT || null, login: !!e.DATAIMPULSE_LOGIN,
  password: !!e.DATAIMPULSE_PASSWORD, country: e.DATAIMPULSE_COUNTRY || null,
});
function proxyOpt() {
  if (!e.DATAIMPULSE_LOGIN) return {};
  const cc = e.DATAIMPULSE_COUNTRY;
  return { proxy: {
    server: `http://${e.DATAIMPULSE_HOST || 'gw.dataimpulse.com'}:${e.DATAIMPULSE_PORT || 823}`,
    username: cc ? `${e.DATAIMPULSE_LOGIN}__cr.${cc.toLowerCase()}` : e.DATAIMPULSE_LOGIN,
    password: e.DATAIMPULSE_PASSWORD } };
}
async function probe(label, ctxOpts) {
  const browser = await chromium.launch({ args: ['--disable-blink-features=AutomationControlled'] });
  const ctx = await browser.newContext(ctxOpts);
  const page = await ctx.newPage();
  const t = Date.now();
  try {
    const r = await page.goto('https://ipinfo.io/json', { waitUntil: 'load', timeout: 45000 });
    const d = JSON.parse(await page.evaluate(() => document.body.innerText));
    console.log(label, { status: r.status(), ip: d.ip, country: d.country, region: d.region, org: d.org, ms: Date.now() - t });
  } catch (err) {
    console.log(label, 'ERROR', err.message.split('\n')[0], `(${Date.now() - t} ms)`);
  }
  await browser.close();
}
(async () => {
  await probe('no proxy  :', {});
  const p = proxyOpt();
  console.log('proxy option built:', !!p.proxy, p.proxy ? p.proxy.server : '');
  await probe('with proxy:', p);
})();
