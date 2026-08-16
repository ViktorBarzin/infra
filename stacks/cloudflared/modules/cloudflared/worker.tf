# Outage-failover Worker (ADR-0020). When the homelab or its tunnel dies, every
# proxied hostname would show a bare Cloudflare 530/1033 (or 521-523) page. On the
# Free plan a Worker is the ONLY replacement (Snippets are paid-only; Custom Error
# Pages for origin 5xx are Enterprise-only AND exclude 521/522). It swaps
# origin-unreachable errors for a friendly 503 pointing at status.viktorbarzin.me
# (mx2, grey-cloud, so it survives the same outage); everything else passes through
# untouched. Logic: worker_failover.js.
#
# (The retired rybbit-analytics injection was folded in here 2026-07-17 then
# removed the same day — Rybbit is unconfigured, 0 sites, analytics dead since
# ~2026-04-13, so injection did nothing. Pure failover now.)
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
  # Pin the runtime compatibility date (good hygiene — an empty value lets Worker
  # runtime behaviour drift). Matches the retired rybbit-analytics wrangler.toml.
  compatibility_date = "2024-01-01"
}

# Zone routes — coverage model "explicit allow-list" (Viktor's call, 2026-08-16,
# replacing the 2026-07-17 "wildcard minus carve-outs" model). The Worker runs
# ONLY on the hosts named in local.worker_covered_hosts, plus the apex.
#
# Why the model changed. Cloudflare bills a Worker invocation on ROUTE MATCH,
# before the script runs, and DNS is a single proxied wildcard CNAME
# (*.viktorbarzin.me → tunnel, ADR-0021). Under a wildcard ROUTE that combination
# makes quota consumption track total zone traffic, with two consequences the
# carve-out list could not cover:
#
#   1. A new host is billed the moment it exists. terminal-dev.viktorbarzin.me
#      (a second ttyd terminal, added 2026-07-21 — four days after the July quota
#      fix) reached 70,899 requests on 2026-08-15 without ever being considered
#      for a carve-out — under a wildcard route there is no point at which a
#      new host has to declare itself, so nothing surfaced it until the alert.
#   2. Hostnames that do not exist are billed too. Every invented subdomain
#      resolves through the wildcard, so a routine subdomain scan on 2026-08-15
#      hit 34 non-existent hosts (legacy, jobs, careers, old, frontend, …) for
#      37,304 requests. Baseline scan traffic is ~11k/day across ~57 such names.
#
# Together with nextcloud (67,384/day, mostly DAV sync) and a linkwarden client
# retry-looping on 401 (16,656/day), that drove 121,128 invocations on 2026-08-15
# — 121% of the free plan's 100k/day. Fail-open meant passthrough, not an outage.
#
# An allow-list inverts both failure modes: a new host and a made-up host alike
# default to no route, so they cost nothing and cannot regress the quota. The
# trade-off is that outage coverage is now opt-in — a host absent from the list
# shows Cloudflare's raw error during an outage instead of the friendly page.
# That is the intended direction: the quota is a hard daily cliff, whereas
# missing the styled page on a rarely-browsed host is cosmetic.
#
# Projected effect, replaying 2026-08-15 per-host request counts against this
# list: roughly a quarter of that day's billed volume, with the scan
# contributing zero. Treat the absolute number as approximate — Cloudflare's
# per-host request dataset and its Workers invocation dataset differed by about
# 2x that day, so the ratio is the reliable part, not the figure. Confirm
# against actual invocations over the first few days.
#
# Grey-cloud names (status, mx2, keyserver, turn, …) never hit any route at all —
# routes only see proxied traffic.
#
# The out-of-band rybbit-analytics Worker + its ~25 per-host routes were retired
# 2026-07-17 (folded here, then the injection was stripped — Rybbit unconfigured;
# docs/adr/0020).
#
# FAIL-OPEN: the per-route "request limit failure mode" (request_limit_fail_open)
# IS exposed by the CF routes API, but is NOT in the cloudflare v4 provider — so
# it is set OUT-OF-BAND via API and is drift the provider does not manage. It
# MUST be true on every worker-bearing route so a quota exhaustion degrades to
# passthrough (raw 530s), never a 1027 error. Re-assert after any route change:
#   scripts/cf-worker-routes-fail-open        (idempotent; verifies + fixes)
#
# TO ADD OUTAGE COVERAGE for a new host: add its subdomain to the list below.
# TO DELIBERATELY EXCLUDE one, leave it out and note it in the exclusion list.
#
# Deliberately NOT covered (and why):
#   terminal, terminal-ro, terminal-dev  ttyd web terminals — WebSocket + a
#                                        ~2.7s session/layout poll per open tab
#   nextcloud                            DAV/sync clients; ~37-67k req/day
#   authentik                            forward-auth checks for every gated
#                                        request; a login host's outage page
#                                        adds nothing
#   linkwarden, proxmox                  JSON APIs polled by clients
#   matrix                               federation / client API / WS
#   vault                                API + CLI + agents
#   t3, t3-afk                           T3 Code sync (WS / API)
#   xray-grpc, xray-ws                   Xray VPN transports (not HTTP pages)
#   rybbit                               analytics JS + event POSTs
#   cinemeta                             Stremio JSON API (in-cluster nginx,
#                                        infra#80) — a JSON client cannot read
#                                        an HTML outage page
#   loki-otlp, prometheus-otlp,          telemetry ingest + machine endpoints:
#   webhook, health-api, tripit-api,     no human ever types these
#   repowise-mcp, paperless-mcp,
#   pages-publish, public-auth,
#   tuya-bridge, owntracks, echo,
#   poison, chrome-fleet, flaresolverr,
#   claude-memory, k8s, docker,
#   headscale, kms, executor
locals {
  # Hosts that get the outage page. This list was seeded from the live ingress
  # inventory (`kubectl get ingress,ingressroute -A`) minus the exclusions above;
  # reconcile it the same way when hosts are added or removed. Full analysis:
  # docs/adr/0020-mx2-outage-failover-and-external-vantage.md (UPDATE 2026-08-16).
  worker_covered_hosts = [
    "ac", "affine", "aiostreams", "alertmanager",
    "android-emulator", "audiblez", "audiobookshelf", "beadboard",
    "book-search", "breakglass", "budget-anca", "budget-viktor",
    "calibre", "cc", "changedetection", "chrome",
    "ci", "city-guesser", "crowdsec-web", "dashy",
    "dawarich", "dolt-workbench", "draw", "dronelog",
    "ebook2audiobook", "f1", "family", "files",
    "fire-planner", "forgejo", "frigate", "grafana",
    "gw", "ha-london", "ha-sofia", "hackmd",
    "health", "highlights-immich", "highlights-immich-emo", "home",
    "idrac", "immich", "insta2spotify", "instagram-poster",
    "interview-prep", "json", "k8s-portal", "learn",
    "lesson-harvester", "listenarr", "london", "mail",
    "mbp14", "meshcentral", "mladost3", "music-assistant",
    "music-emo", "music-viktor", "n8n", "nas",
    "navidrome", "netbox", "networking-toolbox", "nextcloud-todos",
    "novelapp", "ntfy", "offline-reader", "openclaw",
    "openlobster", "pages", "paperless-ai", "pb",
    "pdf", "pfsense", "pgadmin", "phpipam",
    "pi", "plans", "plotting-book", "pma",
    "postiz", "priority-pass", "prometheus", "prowlarr",
    "proxy", "qbittorrent", "recruiter-responder", "repowise",
    "resume", "rss", "send", "shlink",
    "speedtest", "stacks", "stirling-pdf", "stremio",
    "tandoor", "tasks", "technitium", "torrserver",
    "trading", "traefik", "trek", "tripit",
    "uptime", "url", "valchedrym", "vaultwarden",
    "vpn", "wealthfolio", "whisker", "wrongmove",
    "yotovski-status", "yt", "yt-highlights",
  ]
}

resource "cloudflare_worker_route" "outage_failover_host" {
  for_each    = toset(local.worker_covered_hosts)
  zone_id     = var.cloudflare_zone_id
  pattern     = "${each.value}.viktorbarzin.me/*"
  script_name = cloudflare_worker_script.outage_failover.name
}

# Apex is not matched by any *.viktorbarzin.me pattern, so it needs its own route
# (the blog). Was previously owned by rybbit.
resource "cloudflare_worker_route" "outage_failover_apex" {
  zone_id     = var.cloudflare_zone_id
  pattern     = "viktorbarzin.me/*"
  script_name = cloudflare_worker_script.outage_failover.name
}

# NOTE: the Cinemeta reverse-proxy moved from a CF Worker to an in-cluster nginx
# (stacks/stremio, cinemeta-nginx.conf) on 2026-07-22 so cinemeta.viktorbarzin.me
# resolves BOTH publicly and on the home LAN (a Worker only lives at the edge, so
# Technitium/internal clients got NXDOMAIN). cinemeta is absent from the
# allow-list above, so the public path flows CF wildcard DNS -> tunnel -> Traefik
# -> nginx with no Worker invocation.
