// Pure helpers for t3-browser-cookies (tested in lib.test.mjs).
//
// Cookies are in Playwright's shape: {name, value, domain, path, expires,
// httpOnly, secure, sameSite, partitionKey?, _crHasCrossSiteAncestor?}.
// expires <= 0 means a session cookie.

/** @typedef {{name: string, value: string, domain: string, path: string, expires: number,
 *   httpOnly?: boolean, secure?: boolean, sameSite?: string, partitionKey?: string,
 *   _crHasCrossSiteAncestor?: boolean}} Cookie */

const LOCAL_SUFFIXES = ["viktorbarzin.me", "lan", "local", "localhost"];

/** @param {string} domain */
function bare(domain) {
  return domain.replace(/^\./, "").toLowerCase();
}

/** @param {string} domain */
export function isLocalHost(domain) {
  const d = bare(domain);
  if (!d || /^[\d.]+$/.test(d) || d.includes(":")) return true;
  return LOCAL_SUFFIXES.some((s) => d === s || d.endsWith("." + s));
}

/** @param {Cookie} c */
export function cookieKey(c) {
  return [c.name, c.domain.toLowerCase(), c.path || "/", c.partitionKey || "",
    Boolean(c._crHasCrossSiteAncestor)].join("\u0000");
}

/**
 * Cookies worth sending to the hub: persistent, unexpired, for outside sites.
 * @param {Cookie[]} cookies @param {number} now seconds
 */
export function pushable(cookies, now) {
  return cookies.filter((c) => c.name && c.expires > 0 && c.expires > now && !isLocalHost(c.domain));
}

/**
 * key -> value|expires, the state a later run compares against.
 * @param {Cookie[]} cookies @returns {Record<string, string>}
 */
export function baselineOf(cookies) {
  /** @type {Record<string, string>} */
  const out = {};
  for (const c of cookies) out[cookieKey(c)] = `${c.value}|${c.expires}`;
  return out;
}

/**
 * Cookies that are new or changed since `baseline` (what this browser held
 * after the last sync), so a cookie the hub dropped is not pushed back merely
 * because T3 still has its old copy.
 * @param {Cookie[]} cookies @param {Record<string, string>} baseline
 */
export function changedSince(cookies, baseline) {
  return cookies.filter((c) => baseline[cookieKey(c)] !== `${c.value}|${c.expires}`);
}

/**
 * Hub cookies T3's browser should take: ones it lacks, or holds with an earlier
 * expiry. Session cookies come over too when T3 lacks them: some sites keep the
 * login in one (chess.com's PHPSESSID next to its remember-me cookie, measured
 * 2026-11-08: without it T3 landed on the login page). Never replaces a newer
 * login T3 made itself; never removes anything.
 * @param {Cookie[]} hub @param {Cookie[]} t3 @param {number} now
 */
export function toInject(hub, t3, now) {
  const have = new Map(t3.map((c) => [cookieKey(c), c]));
  const out = [];
  for (const c of hub) {
    const session = !(c.expires > 0);
    if (!session && !(c.expires > now)) continue;
    const held = have.get(cookieKey(c));
    if (held && (session || !(c.expires > held.expires))) continue;
    const { _crHasCrossSiteAncestor, ...clean } = c;
    out.push(clean);
  }
  return out;
}

/** @param {string[]} commandLines descendants of T3's browser process */
export function rendererCount(commandLines) {
  return commandLines.filter((a) => /(^|\s)--type=renderer(\s|$)/.test(a)).length;
}
