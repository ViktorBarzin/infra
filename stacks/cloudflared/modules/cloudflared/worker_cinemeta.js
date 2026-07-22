// Cinemeta reverse-proxy Worker (infra#80 follow-up, 2026-07-22).
//
// WHY: Viktor's Meta-managed Mac has an endpoint firewall (uberAgent) that
// blocks *.strem.io, so on that Mac the Stremio web client's Cinemeta catalog
// + meta fetches ("Popular", "Featured", ...) fail with "Failed to fetch"
// (stremio-core env.rs:318). Everything else loads (his own *.viktorbarzin.me
// addons, caching.stremio.net, metahub.space) — only *.strem.io is blocked.
//
// WHAT: re-serve Cinemeta through cinemeta.viktorbarzin.me — a host the firewall
// ALLOWS. The browser only ever talks to *.viktorbarzin.me; this Worker (running
// at the Cloudflare edge, NOT on the blocked Mac) fetches v3-cinemeta.strem.io
// and FOLLOWS Cinemeta's catalog 307 -> cinemeta-catalogs.strem.io server-side,
// so no strem.io hostname is ever requested by the browser. Catalog data is
// public, so no auth. The manifest `id` is rewritten so this installs as a
// DISTINCT addon from the protected com.linvo.cinemeta (which stays but fails on
// the blocked Mac).
//
// Runs only on the cinemeta.viktorbarzin.me/* route (more specific than the
// outage-failover *.viktorbarzin.me wildcard, so it overrides it there).
const UPSTREAM = "https://v3-cinemeta.strem.io";
const CORS = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Methods": "GET, OPTIONS",
  "Access-Control-Allow-Headers": "*",
};

export default {
  async fetch(request) {
    if (request.method === "OPTIONS") {
      return new Response(null, { status: 204, headers: CORS });
    }
    const url = new URL(request.url);
    // fetch() follows the catalog 307 (-> cinemeta-catalogs.strem.io) at the
    // edge; meta is a direct 200 on v3-cinemeta. Either way the browser only saw
    // cinemeta.viktorbarzin.me.
    const upstream = await fetch(UPSTREAM + url.pathname + url.search, {
      method: "GET",
      headers: { accept: request.headers.get("accept") || "application/json" },
      redirect: "follow",
    });
    const headers = new Headers(upstream.headers);
    for (const [k, v] of Object.entries(CORS)) headers.set(k, v);
    headers.delete("content-security-policy");

    // Rewrite the manifest id/name so Stremio treats this as its own addon,
    // not a duplicate of the protected com.linvo.cinemeta.
    if (url.pathname.endsWith("/manifest.json")) {
      try {
        const m = await upstream.json();
        m.id = "com.viktorbarzin.cinemeta-proxy";
        m.name = "Cinemeta (proxied)";
        headers.set("content-type", "application/json");
        headers.delete("content-length");
        headers.delete("content-encoding");
        return new Response(JSON.stringify(m), { status: upstream.status, headers });
      } catch (e) {
        return new Response(upstream.body, { status: upstream.status, headers });
      }
    }
    return new Response(upstream.body, { status: upstream.status, headers });
  },
};
