// homelab browser — node CDP runner (auto-managed; regenerated each run from the
// homelab binary — DO NOT EDIT here). Connects to the port-forwarded
// chrome-service CDP endpoint, installs the stealth init script, then runs the
// user's Playwright script (run mode) or opens a URL (open mode). All inputs
// arrive via HOMELAB_* env vars set by the Go CLI.
'use strict';
const fs = require('fs');
const http = require('http');

// How long the pre-connect sweep may take before we give up and connect anyway.
const preflightTimeoutMS = 5000;

// connectOverCDP attaches to the whole browser, so Chrome replays one
// attachedToTarget event per target already open — including whatever an
// earlier session left in the shared pool browser. patchright's handler asserts
// targetInfo.browserContextId is present before it reaches its own "unknown
// context, detach" path, and a worker that outlived its browser context reports
// no browserContextId at all. That assert throws out of an EventEmitter rather
// than a promise, so main()'s catch never sees it and node dies before the
// script runs a line. One orphan then breaks every later caller until the pod
// restarts (infra issue #98, where an embed.st service worker held the single
// warm worker down for everyone).
//
// Targets that DO carry a context id are left alone. That is what keeps the
// worker's own Chrome extension service workers running: measured on a live
// pool worker, both of them sit in the default context with a real id, so a
// blanket "close every service worker" sweep would have taken out stealth.
function contextlessTargets(targetInfos) {
  return (targetInfos || []).filter((t) => t && t.type !== 'browser' && !t.browserContextId);
}

// The CDP websocket lives on whatever host Chrome thinks it is; we reach it
// through a port-forward, so keep the path and use the endpoint we dialled.
function browserWSURL(reported, cdpURL) {
  const ws = new URL(reported);
  const cdp = new URL(cdpURL);
  ws.protocol = cdp.protocol === 'https:' ? 'wss:' : 'ws:';
  ws.host = cdp.host;
  return ws.toString();
}

function getJSON(url, timeoutMS) {
  return new Promise((resolve, reject) => {
    const req = http.get(url, { timeout: timeoutMS }, (res) => {
      let body = '';
      res.on('data', (c) => (body += c));
      res.on('end', () => {
        try {
          resolve(JSON.parse(body));
        } catch (e) {
          reject(e);
        }
      });
    });
    req.on('timeout', () => req.destroy(new Error('timeout')));
    req.on('error', reject);
  });
}

// Best-effort sweep. Any failure here leaves us exactly where we were before,
// so it logs and returns rather than throwing: a broken preflight must never be
// worse than the crash it is trying to avoid.
async function closeContextlessTargets(cdpURL, log) {
  let ws;
  try {
    const version = await getJSON(cdpURL + '/json/version', preflightTimeoutMS);
    if (!version.webSocketDebuggerUrl) return;
    ws = new WebSocket(browserWSURL(version.webSocketDebuggerUrl, cdpURL));

    let nextID = 1;
    const pending = new Map();
    const send = (method, params = {}) =>
      new Promise((resolve, reject) => {
        const id = nextID++;
        pending.set(id, { resolve, reject });
        ws.send(JSON.stringify({ id, method, params }));
      });

    await new Promise((resolve, reject) => {
      const timer = setTimeout(() => reject(new Error('CDP websocket open timed out')), preflightTimeoutMS);
      ws.onopen = () => {
        clearTimeout(timer);
        resolve();
      };
      ws.onerror = (e) => {
        clearTimeout(timer);
        reject(new Error('CDP websocket error: ' + (e && e.message ? e.message : 'unknown')));
      };
    });

    ws.onmessage = (ev) => {
      let m;
      try {
        m = JSON.parse(ev.data);
      } catch (_) {
        return;
      }
      const waiter = m.id && pending.get(m.id);
      if (!waiter) return;
      pending.delete(m.id);
      if (m.error) waiter.reject(new Error(m.error.message || 'CDP error'));
      else waiter.resolve(m.result);
    };
    // A socket that drops mid-sweep would otherwise leave every in-flight
    // send() awaiting forever, which would hang the run we are trying to save.
    const abandonPending = (why) => {
      for (const [, waiter] of pending) waiter.reject(new Error(why));
      pending.clear();
    };
    ws.onclose = () => abandonPending('CDP websocket closed mid-sweep');
    ws.onerror = () => abandonPending('CDP websocket errored mid-sweep');

    const sweep = async () => {
      const { targetInfos } = await send('Target.getTargets');
      const orphans = contextlessTargets(targetInfos);
      for (const t of orphans) {
        try {
          await send('Target.closeTarget', { targetId: t.targetId });
          log(`cleared orphaned ${t.type} left in the shared browser: ${t.url || t.targetId}`);
        } catch (e) {
          log(`could not clear orphaned ${t.type} ${t.targetId}: ${e.message}`);
        }
      }
    };

    // Whatever happens, connecting is more important than sweeping.
    let overall;
    await Promise.race([
      sweep(),
      new Promise((_, reject) => {
        overall = setTimeout(() => reject(new Error('sweep timed out')), preflightTimeoutMS);
      }),
    ]).finally(() => clearTimeout(overall));
  } catch (e) {
    log('target preflight skipped: ' + (e && e.message ? e.message : e));
  } finally {
    try {
      if (ws) ws.close();
    } catch (_) {
      /* ignore */
    }
  }
}

async function main() {
  // Required lazily so the pure helpers above can be unit-tested without the
  // node_modules tree the CLI installs into its cache dir.
  // patchright-core: playwright-core drop-in that avoids the Runtime.enable CDP leak.
  const { chromium } = require('patchright-core');

  const cdpURL = process.env.HOMELAB_CDP_URL;
  if (!cdpURL) throw new Error('HOMELAB_CDP_URL not set');
  const mode = process.env.HOMELAB_BROWSER_MODE || 'run';
  const stealthPath = process.env.HOMELAB_STEALTH_PATH || '';
  const initURL = process.env.HOMELAB_BROWSER_URL || '';
  const scriptPath = process.env.HOMELAB_BROWSER_SCRIPT || '';
  const shared = process.env.HOMELAB_BROWSER_SHARED === '1';
  const keepOpen = process.env.HOMELAB_BROWSER_KEEP_OPEN === '1';
  const screenshotPath = process.env.HOMELAB_BROWSER_SCREENSHOT || '';
  // Viewport for a fresh context. Default 1920x1080 DPR1 (high-res vision tier,
  // Viktor's bigger-screen decision); --tall / --viewport override via the CLI.
  // Playwright's newContext() ignores the Xvfb screen size, so this is what
  // actually sizes the page (see docs/plans chrome-service-pool-design R4).
  const vpEnv = process.env.HOMELAB_VIEWPORT || '1920,1080';
  const [vw, vh] = vpEnv.split(',').map((n) => parseInt(n, 10));
  // Seed file (the broker's on-demand storage_state export) — inject the master's
  // cookies+localStorage into the fresh context, read-only. Absent for --shared-context.
  const seedPath = process.env.HOMELAB_STORAGE_STATE || '';

  const log = (...a) => console.error('[browser]', ...a);

  // Sweep before connecting: connectOverCDP is what trips over an orphan, so
  // this has to happen while we can still do something about it.
  await closeContextlessTargets(cdpURL, log);

  const browser = await chromium.connectOverCDP(cdpURL);

  // Fresh isolated context by default (safe for the shared browser + concurrent
  // callers); --shared-context reuses the warmed persistent profile on the MASTER.
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
    const ctxOpts = { deviceScaleFactor: 1 };
    if (vw > 0 && vh > 0) ctxOpts.viewport = { width: vw, height: vh };
    if (seedPath && fs.existsSync(seedPath)) ctxOpts.storageState = seedPath;
    context = await browser.newContext(ctxOpts);
    createdContext = true;
  }

  if (stealthPath) {
    const stealth = fs.readFileSync(stealthPath, 'utf8');
    if (stealth.trim()) await context.addInitScript(stealth);
  }

  const page = await context.newPage();

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

// Required as a module by browser_runner_test.js; run directly by the CLI.
if (require.main === module) {
  main().catch((e) => {
    console.error('homelab browser: fatal:', e && e.stack ? e.stack : e);
    process.exit(1);
  });
}

module.exports = { contextlessTargets, browserWSURL, closeContextlessTargets };
