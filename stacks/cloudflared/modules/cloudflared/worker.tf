# Outage-failover Worker (ADR-0020). When the homelab or its tunnel dies,
# every proxied hostname shows a bare Cloudflare 530/1033 (or 521-523) error
# page. On the Free plan a Worker is the ONLY mechanism that can replace
# those: Snippets are paid-only, and Custom Error Pages for origin 5xx are
# Enterprise-only AND exclude 521/522. The Worker passes healthy traffic
# through untouched and swaps origin-unreachable errors for a friendly 503
# page pointing at status.viktorbarzin.me (served from mx2, grey-cloud, so it
# survives the same outage). Logic + interception rationale: worker_failover.js.
resource "cloudflare_worker_script" "outage_failover" {
  account_id = var.cloudflare_account_id
  name       = "outage-failover"
  content    = file("${path.module}/worker_failover.js")
  module     = true # ES module Worker (export default { fetch })
}

# Zone routes — quota math: the zone serves ~20k proxied req/day (26k peak,
# measured 2026-07-01..07) against the 100k req/day free Workers quota, ~4-5x
# headroom. Grey-cloud names (status, mx2, keyserver, proxy, turn, vpn, …)
# never consume quota: routes only see traffic that transits the Cloudflare
# proxy. If the quota is ever exhausted anyway, the per-route "request limit
# failure mode" must be fail open (bypass the Worker = today's raw 530s, and
# healthy traffic flows normally) — that toggle is dashboard-only (not in the
# routes API, hence not in this provider); verify it once after first apply:
# dash → Workers Routes → edit each route below.
#
# Two patterns because "*.viktorbarzin.me/*" does not match the apex.
resource "cloudflare_worker_route" "outage_failover_wildcard" {
  zone_id     = var.cloudflare_zone_id
  pattern     = "*.viktorbarzin.me/*"
  script_name = cloudflare_worker_script.outage_failover.name
}

resource "cloudflare_worker_route" "outage_failover_apex" {
  zone_id     = var.cloudflare_zone_id
  pattern     = "viktorbarzin.me/*"
  script_name = cloudflare_worker_script.outage_failover.name
}
