# Outage-failover + analytics Worker (ADR-0020). Two jobs in one script
# (rybbit-analytics consolidated in 2026-07-17):
#  - When the homelab or its tunnel dies, every proxied hostname would show a
#    bare Cloudflare 530/1033 (or 521-523) page. On the Free plan a Worker is the
#    ONLY replacement (Snippets are paid-only; Custom Error Pages for origin 5xx
#    are Enterprise-only AND exclude 521/522). It swaps origin-unreachable errors
#    for a friendly 503 pointing at status.viktorbarzin.me (mx2, grey-cloud, so it
#    survives the same outage).
#  - On healthy HTML for a Rybbit-tracked host it injects the analytics <script>.
# Everything else passes through untouched. Logic: worker_failover.js.
resource "cloudflare_worker_script" "outage_failover" {
  account_id = var.cloudflare_account_id
  name       = "outage-failover"
  # The self-contained outage page (error_page.html — same content mx2 serves
  # at /error.html) is baked into the script as a JSON string literal:
  # Worker fetch() to a same-zone grey-cloud hostname was observed failing
  # (2026-07-08), so the page must not depend on a runtime subrequest to mx2.
  content = replace(
    file("${path.module}/worker_failover.js"),
    "\"__INLINE_PAGE_JSON__\"",
    jsonencode(file("${path.module}/error_page.html")),
  )
  module = true # ES module Worker (export default { fetch })
  # REQUIRED for HTMLRewriter analytics injection to work. Carried over from the
  # retired rybbit-analytics wrangler.toml (which set 2024-01-01). With an empty/
  # ancient compat date the fetch()+HTMLRewriter path silently no-ops on origin
  # HTML (injection never fires); the failover branch is unaffected. Verified:
  # dropping it broke injection on every tracked host 2026-07-17.
  compatibility_date = "2024-01-01"
}

# Zone routes — coverage model "wildcard minus carve-outs" (Viktor's call,
# 2026-07-17). The Worker runs on the *.viktorbarzin.me wildcard + apex, EXCEPT
# the carve-out hosts below. Rationale: Cloudflare bills a Worker invocation on
# ROUTE MATCH, before the script runs — so a plain wildcard billed every request
# to every proxied host (terminal.viktorbarzin.me alone ≈55% of zone traffic) and
# drove the free 100k/day quota to 94.5% on 2026-07-16. Carving out the quota
# hogs / non-browsable hosts drops usage to ~30k/day (~3x headroom) while every
# browsable host keeps outage coverage. Grey-cloud names (status, mx2, keyserver,
# turn, …) never hit any route (routes only see proxied traffic).
#
# This consolidated the out-of-band rybbit-analytics Worker into this script and
# retired that Worker + its ~25 per-host routes (docs/adr/0020 updated).
#
# FAIL-OPEN: the per-route "request limit failure mode" (request_limit_fail_open)
# IS exposed by the CF routes API (the earlier "dashboard-only" note was wrong),
# but is NOT in the cloudflare v4 provider — so it is set OUT-OF-BAND via API and
# is drift the provider does not manage. It MUST be true on the worker-bearing
# routes (wildcard + apex) so a quota exhaustion degrades to passthrough (raw
# 530s), never a 1027 error on every host. Re-assert after any route recreate:
#   PUT /zones/<zone>/workers/routes/<id> {pattern, script, request_limit_fail_open:true}
# then verify with GET .../workers/routes.
resource "cloudflare_worker_route" "outage_failover_wildcard" {
  zone_id     = var.cloudflare_zone_id
  pattern     = "*.viktorbarzin.me/*"
  script_name = cloudflare_worker_script.outage_failover.name
}

# Apex is NOT matched by the *.viktorbarzin.me wildcard, so it needs its own
# route (blog + analytics site da853…). Was previously owned by rybbit.
resource "cloudflare_worker_route" "outage_failover_apex" {
  zone_id     = var.cloudflare_zone_id
  pattern     = "viktorbarzin.me/*"
  script_name = cloudflare_worker_script.outage_failover.name
}

# Carve-outs: a more-specific route with NO script_name overrides the wildcard, so
# the Worker does not run (and bills no invocation) on these hosts. They show the
# raw Cloudflare error during an outage — accepted, because each is either a quota
# hog or non-browsable (WebSocket / API / VPN transport) where an HTML outage page
# adds nothing:
#   terminal, terminal-ro = ttyd web terminals (WebSocket; ~55% of zone traffic)
#   matrix                = Matrix homeserver (federation / API / WS, not browsed)
#   vault                 = HashiCorp Vault (API / CLI / agents)
#   t3, t3-afk            = T3 Code sync (WS / API)
#   xray-grpc, xray-ws    = Xray VPN transports (not HTTP pages)
#   rybbit                = serves the tracker JS + event POSTs (self-amplification)
# Add a new high-traffic non-browsable host here so it never burns quota.
locals {
  worker_carveout_hosts = [
    "terminal", "terminal-ro", "matrix", "vault",
    "t3", "t3-afk", "xray-grpc", "xray-ws", "rybbit",
  ]
}

resource "cloudflare_worker_route" "outage_failover_carveout" {
  for_each = toset(local.worker_carveout_hosts)
  zone_id  = var.cloudflare_zone_id
  pattern  = "${each.value}.viktorbarzin.me/*"
  # No script_name → "no worker" route; overrides the wildcard for this host.
}
