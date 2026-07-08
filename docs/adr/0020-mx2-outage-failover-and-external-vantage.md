# mx2 becomes the external vantage: status page, outage error UX via a Cloudflare Worker, and edge-unreachable alerting

**Status: Accepted (2026-07-08)** — implementation in flight the same day: VM
tenants in `stacks/backup-mx/cloud-init.yaml.tftpl`, Worker + DNS records in
`stacks/cloudflared/`, in-cluster probe/alert in `stacks/monitoring/`; the live
VM was hand-converged 2026-07-08 with every change mirrored into cloud-init.
Runbook: [`backup-mx.md`](../runbooks/backup-mx.md) § "Status page / failover
tenants".

When the homelab is down, visitors get the worst possible story. The ~100
Cloudflare-proxied hosts serve Cloudflare's raw **530 / error 1033** (tunnel
unreachable) — a page that looks like Cloudflare broke, with no hint the outage
is known or temporary — and the ~35 grey-cloud hosts just time out. The
in-cluster error-pages middleware (tarampampam,
`stacks/traefik/modules/traefik/error-pages.tf`) owns themed 5xx/404s but sits
BEHIND Traefik, so in exactly this failure class — requests never reach
Traefik — it serves nothing. There is no status page to point anyone at:
`status.viktorbarzin.me` has been dormant since the Uptime-Kuma→GitHub-Pages
pusher was disabled (2026-05-26). And nothing external notices: ALL monitoring
probes run in-cluster, inside the failure domain they watch — the 2026-06-27
pfSense egress outage alerted on nothing, and the egress probes added after it
still die with the cluster they run in. Meanwhile ADR-0019 left an approved,
reusable external asset idle outside mail outages: **mx2** (OCI Always-Free
`E2.1.Micro`, reserved IP `92.5.132.215`, Frankfurt) — a box whose whole point
is being up when the homelab is not. `architecture/dns.md` has carried the
aspiration that genuine edge-path fidelity "is the job of a true external
vantage (ha-london)"; mx2 realizes it. Five moves, all decided 2026-07-08:

1. **`status.viktorbarzin.me` is revived, served FROM mx2.** gatus — YAML
   config codified in the `stacks/backup-mx` cloud-init, extending ADR-0019's
   disposability invariant to every tenant — behind nginx TLS (one certbot
   cert, **webroot mode**, SANs `mx2` + `status`). The DNS record moves
   proxied-CNAME → **grey-cloud A `92.5.132.215`**, so the page resolves and
   serves through a homelab + tunnel outage — the one moment it exists for.
   gatus probes **public hostnames only**: the page discloses nothing that is
   not already in public DNS.

2. **Proxied hosts get an outage page instead of raw 530s** — a free-plan
   Cloudflare Worker on `*.viktorbarzin.me/*` + the apex
   (`stacks/cloudflared/modules/cloudflared/worker_failover.js`). It is a
   passthrough `fetch` that intercepts ONLY fetch-error / 530 / 521–523
   responses, and only for GET/HEAD + `Accept: text/html` + non-WebSocket
   requests; everything else (APIs, uploads, websockets, non-HTML clients)
   passes untouched. On intercept it serves mx2's self-contained
   `/error.html` (edge-cached 60 s) as **HTTP 503 + `Retry-After`**, with an
   inline-HTML last resort if mx2 is unreachable too. It explicitly does
   **NOT** intercept 502/504 — those mean Traefik answered, and the
   in-cluster error-pages middleware owns app-level errors. Quota math
   (measured 2026-07-01..07 via CF GraphQL): the zone runs ≈20k requests/day
   (26k peak) against the free Workers cap of 100k/day, and the per-route
   request-limit failure mode is set to **FAIL OPEN** (bypass Worker →
   origin) — the quota cliff degrades to today's behaviour, never to a new
   outage.

3. **Edge-unreachable Slack alerting from mx2.** A gatus sentinel group
   watches the three edge paths — the Cloudflare-tunnel path (a proxied
   hostname healthy ⇔ cloudflared CONNECTED), the direct path (TCP to
   `mail.viktorbarzin.me:993`), and one direct HTTPS host — with
   **failure-threshold 3** before alerting. Per-service alerting stays with
   in-cluster Alertmanager (no double-paging); mx2 pages only for "the
   homelab is unreachable from the internet", the one alert the cluster
   cannot deliver about itself. The Slack webhook is **baked into the gatus
   config at provision time from Vault `secret/platform`** — mx2 cannot
   reach Vault mid-outage, so a runtime lookup is exactly the wrong
   dependency.

4. **WireGuard rider:** mx2's WG endpoint moves from the hardcoded
   `176.12.22.76` to **`vpn.viktorbarzin.me` + a re-resolve timer**.
   WireGuard resolves `Endpoint=` once; after a homelab WAN renumber the
   drain (and the box's management path) would dial a dead IP forever. The
   record itself is kept fresh from the homelab side (bead `code-dvla`,
   Consequences) — the Cloudflare API token stays in in-cluster Vault, never
   on mx2.

5. **A permanent synthetic test host, `test-failover.viktorbarzin.me`:**
   proxied CNAME → an all-zeros tunnel UUID, so the edge answers 530 for it
   ALWAYS. One `curl` verifies the whole Worker path end-to-end, any day,
   without touching production (drill in the runbook).

## Considered options

All verified as-of 2026-07-08:

- **Cloudflare Snippets** — the natural "small edge logic" product, but
  available on paid plans only. The Workers free tier covers this use.
- **Cloudflare Custom Error Pages for origin 5xx** — Enterprise-only AND
  they exclude 521/522, the exact origin-down codes this design exists to
  catch. Double disqualification.
- **Cloudflare Load Balancing failover pools** (origin pool falling over to
  mx2) — paid add-on; the account is hard-$0 (ADR-0019).
- **Automatic DNS flip of the ~35 grey-cloud records to mx2 during
  outages** — requires a Cloudflare API token on an internet-facing VM, plus
  hysteresis/flap logic whose success case is sending LIVE traffic (IMAP,
  WireGuard, …) to an error page. Rejected: the grey-cloud services'
  failover story is MX priority 20 for mail (ADR-0019) plus status-page
  visibility for the rest.
- **Second cloudflared tunnel replica on mx2** — replicas of a
  remotely-managed tunnel share config and are load-balanced, not
  prioritized: it would hairpin a share of live traffic through Frankfurt
  every normal day, and buy nothing during an outage (the origin behind the
  tunnel is down either way).
- **Uptime-Kuma on mx2** (familiar from the old status page) —
  UI-configured state violates the cattle/cloud-init invariant that keeps
  mx2 rebuildable, and it weighs ~200 MB against gatus' ~50 MB on a 1 GB box
  where mail has priority.

## Consequences

- **The Worker sits on the hot path of ALL proxied traffic.** Contained by
  design: pure pass-through outside the narrow intercept set, FAIL OPEN on
  quota, inline-HTML last resort — the engineered worst case equals the
  status quo (raw 530s), never a new outage class.
- **KNOWN COVERAGE GAP (as-built 2026-07-08):** the dashboard-managed
  `rybbit-analytics` Worker holds ~26 per-host routes (apex, www, immich,
  nextcloud, mail, f1, …); Cloudflare runs only the single most-specific
  route per request, so those hosts bypass the failover Worker and still
  show raw Cloudflare errors during an outage (an apex route for this Worker
  is impossible while rybbit owns `viktorbarzin.me/*` — API error 10020).
  Additionally, Worker `fetch()` to the same-zone grey-cloud `status` host
  was observed failing, so the outage page is BAKED INTO the script at
  deploy time (`error_page.html`, injected by `worker.tf`; live status loads
  client-side from the gatus API). Planned fix: consolidate rybbit's
  head-injection into this TF-managed Worker and retire the out-of-band
  script + routes — pending decision (out-of-band production config).
- **mx2 gains ~140 MB of tenants** (gatus under `MemoryMax=128M` + nginx)
  under the ADR-0019 mail-priority rule: the mail queue always wins.
- **Port 443 opens to the world** on mx2 — OCI security list + OS iptables —
  joining 25 and 80; the 9100/metrics scrape stays allowlisted to the
  homelab WAN /32.
- **The status page is public recon-lite by design**: it lists public
  hostnames and their health — only names already in public DNS. Accepted.
- **mx2 still cannot be REBUILT during a homelab outage** (the stack's
  Terraform state lives in the cluster's Postgres — ADR-0019 known caveat).
  The live VM keeps serving through the outage; only recreation waits for
  the cluster.
- **Oracle idle-reclamation defense improves for free**: real probe and
  network activity legitimately raises the 7-day utilization profile
  alongside `keepalive-cpu` (ADR-0019's load-bearing mitigation).
- **Live-converge debt is codified, not accrued**: the 2026-07-08 bring-up
  converged the live VM by hand and mirrored every change into cloud-init
  the same day; the runbook's LIVE-CONVERGE vs REBUILD rule makes that the
  standing discipline.
- **Follow-up (bead `code-dvla`)**: a homelab-side WAN-IP-change updater
  keeps `vpn.viktorbarzin.me` fresh (Cloudflare token stays in in-cluster
  Vault, never on mx2). Until it lands, a WAN renumber needs a manual record
  update — the re-resolve timer then heals mx2 unattended.
- **Docs**: `architecture/dns.md`'s external-vantage aspiration updated (mx2
  IS the vantage) and the `status`/`test-failover` records inventoried
  there; the backup-mx runbook gains the tenants section + verification
  drill. `architecture/incident-response.md` still describes the retired
  GitHub-Pages status page (`stacks/status-page`, pusher disabled
  2026-05-26) — stale, needs its own rewrite.
