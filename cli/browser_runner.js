// homelab browser — node CDP runner (auto-managed; regenerated each run from the
// homelab binary — DO NOT EDIT here). Connects to the port-forwarded
// chrome-service CDP endpoint, installs the stealth init script, then runs the
// user's Playwright script (run mode) or opens a URL (open mode). All inputs
// arrive via HOMELAB_* env vars set by the Go CLI.
'use strict';
const fs = require('fs');
const { chromium } = require('playwright-core');

async function main() {
  const cdpURL = process.env.HOMELAB_CDP_URL;
  if (!cdpURL) throw new Error('HOMELAB_CDP_URL not set');
  const mode = process.env.HOMELAB_BROWSER_MODE || 'run';
  const stealthPath = process.env.HOMELAB_STEALTH_PATH || '';
  const initURL = process.env.HOMELAB_BROWSER_URL || '';
  const scriptPath = process.env.HOMELAB_BROWSER_SCRIPT || '';
  const shared = process.env.HOMELAB_BROWSER_SHARED === '1';
  const keepOpen = process.env.HOMELAB_BROWSER_KEEP_OPEN === '1';
  const screenshotPath = process.env.HOMELAB_BROWSER_SCREENSHOT || '';

  const browser = await chromium.connectOverCDP(cdpURL);

  // Fresh isolated context by default (safe for the shared browser + concurrent
  // callers); --shared-context reuses the warmed persistent profile.
  let context;
  let createdContext = false;
  if (shared) {
    const existing = browser.contexts();
    if (existing.length) {
      context = existing[0];
    } else {
      context = await browser.newContext();
      createdContext = true;
    }
  } else {
    context = await browser.newContext();
    createdContext = true;
  }

  if (stealthPath) {
    const stealth = fs.readFileSync(stealthPath, 'utf8');
    if (stealth.trim()) await context.addInitScript(stealth);
  }

  const page = await context.newPage();
  const log = (...a) => console.error('[browser]', ...a);

  let exitCode = 0;
  try {
    if (initURL) {
      await page.goto(initURL, { waitUntil: 'domcontentloaded' });
    }
    if (mode === 'open') {
      console.log('url:    ' + page.url());
      console.log('title:  ' + (await page.title()));
      const text = (await page.evaluate(() => (document.body ? document.body.innerText : ''))).trim();
      console.log('--- visible text (truncated to 4000 chars) ---');
      console.log(text.slice(0, 4000));
      if (screenshotPath) {
        await page.screenshot({ path: screenshotPath, fullPage: true });
        console.log('screenshot: ' + screenshotPath);
      }
    } else {
      if (!scriptPath) throw new Error('run mode requires HOMELAB_BROWSER_SCRIPT');
      const src = fs.readFileSync(scriptPath, 'utf8');
      // Run the user's source with page/context/browser/log in lexical scope.
      // AsyncFunction body permits top-level await.
      const AsyncFunction = Object.getPrototypeOf(async () => {}).constructor;
      const fn = new AsyncFunction('page', 'context', 'browser', 'log', src);
      const result = await fn(page, context, browser, log);
      if (result !== undefined) {
        let out;
        try {
          out = typeof result === 'string' ? result : JSON.stringify(result, null, 2);
        } catch (_) {
          out = String(result);
        }
        console.log(out);
      }
    }
  } catch (e) {
    console.error('homelab browser: script error:', e && e.stack ? e.stack : e);
    exitCode = 1;
  } finally {
    if (!keepOpen) {
      try {
        // Close only what we created; never tear down the shared persistent context.
        if (createdContext) {
          await context.close();
        } else {
          await page.close();
        }
      } catch (_) { /* ignore */ }
    }
    // Disconnect from the CDP endpoint; this does NOT kill the remote browser.
    try {
      await browser.close();
    } catch (_) { /* ignore */ }
  }
  process.exit(exitCode);
}

main().catch((e) => {
  console.error('homelab browser: fatal:', e && e.stack ? e.stack : e);
  process.exit(1);
});
