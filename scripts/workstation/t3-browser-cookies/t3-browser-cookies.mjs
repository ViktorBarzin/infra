#!/usr/bin/env node
// Keep T3 Code's browser signed in with this person's hub logins, and send the
// logins it picks up back to the hub.
//
// One hub per person (infra docs/architecture/chrome-service.md "One hub per
// person"). T3's browser is a persistent Chrome profile that T3 launches with a
// private debugging pipe, so nothing outside T3 can reach it while it runs, and
// Chrome reads its cookie store only at startup. So, every 10 minutes
// (t3-browser-cookies@<user>.timer), as the user:
//
//  1. Skip unless something changed: the local hub snapshot or T3's Cookies file.
//  2. Skip if T3's browser has a tab open (a renderer process). Viktor's rule:
//     restart it only while nothing is open in it.
//  3. If it runs idle, SIGTERM it. T3 starts a new one on the next preview call
//     (measured 2026-11-08 on T3 0.1.7).
//  4. Work on a COPY of the cookie store with Playwright and T3's own
//     chrome-headless-shell: export cookies, push the ones that changed since the
//     last run to the hub, refresh the local snapshot, add hub cookies T3 lacks
//     or holds with an earlier expiry.
//  5. If T3 has not started its browser meanwhile, rename the copy into place.
//
// Nothing is ever deleted. Logs carry counts only.

import { execFileSync, spawnSync } from "node:child_process";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import crypto from "node:crypto";
import { baselineOf, changedSince, pushable, rendererCount, toInject } from "./lib.mjs";

const HOME = os.homedir();
const HUB_FILE = process.env.CHROME_HUB_CONFIG || path.join(HOME, ".config/chrome-hub/hub.json");
const PROFILE = process.env.T3_BROWSER_PROFILE || path.join(HOME, ".t3/userdata/server-browser/profiles/default");
const TOOLS = process.env.T3_BROWSER_TOOLS || path.join(HOME, ".t3/tools/chrome-headless-shell/linux64");
const SNAPSHOT = path.join(HOME, ".cache/playwright-shared-storage-state.json");
const STATE_DIR = path.join(HOME, ".local/state/t3-browser-cookies");
const STATE_FILE = path.join(STATE_DIR, "state.json");
const PLAYWRIGHT = process.env.PLAYWRIGHT_CORE || "/usr/lib/terminal-lobby/tl-browser-host/node_modules/playwright-core/index.mjs";
const FORCE = process.argv.includes("--force");

/** @param {string} msg */
const log = (msg) => console.log(`[t3-browser-cookies] ${msg}`);

/** @param {string} p */
function readJson(p, fallback = null) {
  try { return JSON.parse(fs.readFileSync(p, "utf8")); } catch { return fallback; }
}

/** @param {string} p */
function fileSig(p) {
  try {
    const st = fs.statSync(p);
    return `${st.size}:${st.mtimeMs}`;
  } catch { return ""; }
}

/** PIDs of T3's browser main process(es) for this profile. */
function browserPids() {
  const out = spawnSync("pgrep", ["-u", String(process.getuid?.() ?? ""), "-f", `--user-data-dir=${PROFILE}`], { encoding: "utf8" });
  return (out.stdout || "").split("\n").map(Number).filter((pid) => pid && pid !== process.pid)
    .filter((pid) => !cmdline(pid).includes("--type="));
}

/** @param {number} pid */
function cmdline(pid) {
  try { return execFileSync("ps", ["-o", "args=", "-p", String(pid)], { encoding: "utf8" }).trim(); } catch { return ""; }
}

/** @param {number} pid @returns {number[]} */
function descendants(pid) {
  const out = spawnSync("ps", ["--ppid", String(pid), "-o", "pid="], { encoding: "utf8" });
  const kids = (out.stdout || "").split("\n").map(Number).filter(Boolean);
  return kids.flatMap((k) => [k, ...descendants(k)]);
}

/** @param {number} pid */
async function waitGone(pid, ms) {
  const end = Date.now() + ms;
  while (Date.now() < end) {
    try { process.kill(pid, 0); } catch { return true; }
    await new Promise((r) => setTimeout(r, 200));
  }
  return false;
}

function newestShell() {
  const versions = fs.readdirSync(TOOLS).filter((v) => fs.existsSync(path.join(TOOLS, v, "chrome-headless-shell")));
  versions.sort((a, b) => a.localeCompare(b, undefined, { numeric: true }));
  if (!versions.length) throw new Error(`no chrome-headless-shell under ${TOOLS}`);
  return path.join(TOOLS, versions[versions.length - 1], "chrome-headless-shell");
}

/** @param {{cookies_url: string, write_token: string}} hub @param {object[]} cookies */
async function push(hub, cookies) {
  const res = await fetch(hub.cookies_url, {
    method: "POST",
    headers: { Authorization: `Bearer ${hub.write_token}`, "Content-Type": "application/json" },
    body: JSON.stringify({ source: "t3", cookies }),
    signal: AbortSignal.timeout(60_000),
  });
  if (!res.ok) throw new Error(`hub push answered HTTP ${res.status}`);
  return res.json();
}

/** Same refresh the hourly timer runs, so the lock and the format stay one. */
function refreshSnapshot() {
  const r = spawnSync("/usr/local/bin/playwright-snapshot-refresh", [], { encoding: "utf8" });
  if (r.status !== 0) log(`snapshot refresh failed: ${(r.stderr || "").trim().slice(0, 200)}`);
}

async function main() {
  const hub = readJson(HUB_FILE);
  if (!hub) return log("no hub config: nothing to do");
  if (!fs.existsSync(path.join(PROFILE, "Default"))) return log("T3's browser has no profile yet: nothing to do");

  const state = readJson(STATE_FILE, { snapshotSig: "", cookiesSig: "", baseline: {} });
  const snapshotSig = fileSig(SNAPSHOT);
  const cookiesFile = path.join(PROFILE, "Default", "Cookies");
  if (!FORCE && snapshotSig === state.snapshotSig && fileSig(cookiesFile) === state.cookiesSig) {
    return log("no change since the last sync");
  }

  for (const pid of browserPids()) {
    const kids = descendants(pid).map(cmdline);
    const tabs = rendererCount(kids);
    if (tabs > 0) return log(`T3's browser has ${tabs} tab(s) open: leaving it alone`);
    process.kill(pid, "SIGTERM");
    if (!(await waitGone(pid, 10_000))) return log("T3's browser did not stop within 10s: skipping");
    log("stopped T3's idle browser (T3 starts it again on next use)");
  }

  // Work on a copy: T3 may start its browser on the real profile at any moment.
  const work = fs.mkdtempSync(path.join(os.tmpdir(), "t3-browser-cookies-"));
  try {
    fs.mkdirSync(path.join(work, "Default"), { recursive: true });
    for (const f of ["Local State", "Default/Preferences", "Default/Cookies", "Default/Cookies-journal"]) {
      const src = path.join(PROFILE, f);
      if (fs.existsSync(src)) fs.copyFileSync(src, path.join(work, f));
    }

    const { chromium } = await import(PLAYWRIGHT);
    const now = Date.now() / 1000;
    const ctx = await chromium.launchPersistentContext(work, { executablePath: newestShell(), headless: true });
    let pushed = 0, injected = 0, rejected = 0;
    try {
      const mine = await ctx.cookies();
      const changed = changedSince(pushable(mine, now), state.baseline || {});
      if (changed.length) {
        try {
          const res = await push(hub, changed);
          pushed = res.accepted ?? 0;
          log(`pushed ${changed.length} changed cookie(s): hub accepted ${pushed}, skipped ${JSON.stringify(res.skipped || {})}`);
          refreshSnapshot();
        } catch (e) {
          log(`push failed: ${e instanceof Error ? e.message : e}`);
        }
      }
      const hubCookies = readJson(SNAPSHOT, { cookies: [] }).cookies || [];
      for (const c of toInject(hubCookies, mine, now)) {
        try { await ctx.addCookies([c]); injected++; } catch { rejected++; }
      }
      state.baseline = baselineOf(pushable(await ctx.cookies(), now));
    } finally {
      await ctx.close();
    }

    if (browserPids().length) {
      return log("T3 started its browser during the sync: discarded this run, will retry");
    }
    for (const f of ["Default/Cookies", "Default/Cookies-journal"]) {
      const src = path.join(work, f);
      if (fs.existsSync(src)) {
        const tmp = path.join(PROFILE, `${f}.t3sync-${crypto.randomUUID()}`);
        fs.copyFileSync(src, tmp);
        fs.renameSync(tmp, path.join(PROFILE, f));
      }
    }
    state.snapshotSig = fileSig(SNAPSHOT);
    state.cookiesSig = fileSig(cookiesFile);
    fs.mkdirSync(STATE_DIR, { recursive: true, mode: 0o700 });
    fs.writeFileSync(STATE_FILE, JSON.stringify(state), { mode: 0o600 });
    log(`done: pushed ${pushed}, injected ${injected}, rejected ${rejected}`);
  } finally {
    fs.rmSync(work, { recursive: true, force: true });
  }
}

main().catch((e) => {
  log(`failed: ${e instanceof Error ? e.stack || e.message : e}`);
  process.exitCode = 1;
});
