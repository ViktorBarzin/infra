# Plan: Migrate Traefik to dedicated IP 10.0.20.203 + ETP=Local

**Date:** 2026-05-30 · **Pairs with:** `2026-05-30-traefik-dedicated-ip-etp-local-design.md`
**Status:** Draft — review required before executing. Nothing applied yet.

Goal: real client IPs to CrowdSec + working QUIC on the 24 direct apps, by
moving Traefik off the shared `10.0.20.200` onto its own `10.0.20.203` with
`externalTrafficPolicy: Local`. Shared IP `.200` (incl. the TF state DB) is
left untouched until the final cleanup step.

> Recommended cutover: **in-place** (simplest, most maintainable) inside a short
> planned window. Additive/zero-downtime variant noted at the end.

## Phase 0 — Pre-flight (read-only, ~10 min)

- [ ] Snapshot current state (already captured in chat; re-confirm at execution):
  - Traefik svc: IP `10.0.20.200`, `allow-shared-ip=shared`, ETP=Cluster.
  - `.200` shared by 10 services incl. `dbaas/postgresql-lb:5432` (TF state).
  - DNS apex `viktorbarzin.me A = 10.0.20.200` (Technitium primary, split-horizon).
  - pfSense rdr: WAN 443 tcp+udp → alias `<nginx>` (=10.0.20.200); `admin@10.0.20.1`.
  - Traefik 3 replicas (node4, node5, +1), PDB minAvailable=2.
- [ ] Confirm `10.0.20.203` still free in pool `10.0.20.200-220`.
- [ ] **Lower DNS TTL** on the apex record to 60s (Technitium) ~30 min ahead of
      cutover to shrink the window. (Restore to normal afterward.)
- [ ] Baseline checks to compare against (run now, save output):
  - `curl -sI https://immich.viktorbarzin.me` (direct app) → 200/redirect
  - `curl -sI https://<a-proxied-app>` → 200 (proxied path)
  - PG state reachable: `nc -vz 10.0.20.200 5432` (or a `terragrunt plan` no-op)
  - Traefik access log shows `10.0.20.103` for a direct app (the bug we're fixing)
  - `http3check.net` for immich → QUIC FAILS (baseline)

## Phase 1 — Terraform: dedicated IP + ETP=Local (reversible)

Edit `stacks/traefik/modules/traefik/main.tf`, Helm `service` block (~L165-173):

```hcl
service = {
  type = "LoadBalancer"
  annotations = {
    "metallb.io/loadBalancerIPs" = "10.0.20.203"   # was 10.0.20.200
    # allow-shared-ip REMOVED — Traefik no longer shares an IP
  }
  spec = {
    externalTrafficPolicy = "Local"                 # was Cluster
  }
}
```

- [ ] `scripts/tg plan` in `stacks/traefik` — review: only the Traefik Service
      changes (new IP, ETP, annotation removed). No change to other stacks.
- [ ] `scripts/tg apply`.
- [ ] **Immediately verify** (ingress is briefly broken until DNS+pfSense move):
  - `kubectl get svc traefik -n traefik` → IP `10.0.20.203`, ETP=Local.
  - `kubectl get svc -A | grep 10.0.20.200` → the other 9 services still hold `.200`.
  - **`nc -vz 10.0.20.200 5432`** → TF state DB still reachable (critical).
  - `curl -sI --resolve <app>:443:10.0.20.203 https://<direct-app>` → 200
    (proves `.203` serves before DNS moves).

**Rollback (Phase 1):** revert the three lines → `scripts/tg apply`. Back to `.200`.

## Phase 2 — Internal DNS cutover (Technitium)

- [ ] Update split-horizon apex: `viktorbarzin.me A → 10.0.20.203` (primary;
      AXFR replicates to secondary/tertiary, or kick `technitium-zone-sync`).
- [ ] Verify internal resolution: `dig +short immich.viktorbarzin.me` → `10.0.20.203`
      from a cluster/LAN client; `curl -sI https://immich.viktorbarzin.me` → 200.

**Rollback (Phase 2):** apex A → `10.0.20.200`.

## Phase 3 — pfSense (live firewall — operator-driven, alias not literal)

Per the "create a VIP/alias, don't hardcode" requirement:

- [ ] **Create a pfSense Firewall Alias** (Firewall ▸ Aliases), type Host:
      name `traefik_lb`, value `10.0.20.203`. *(This is the correct pfSense
      object for a NAT-forward target — same kind as the existing `<nginx>`
      alias. If a CARP/IP-Alias Virtual IP is intended instead, confirm at
      review; a routed K8s LB IP normally uses an Alias, not a VIP.)*
- [ ] **Repoint the 443 forward** (Firewall ▸ NAT ▸ Port Forward): change the
      existing WAN `https` (TCP **and** UDP) rule's target from `nginx` →
      `traefik_lb`. Leave the auto firewall rule linked. Do **not** touch the
      `http-alt`/`7443` rules (those are xray on `<k8s_shared_lb>`).
- [ ] Apply pfSense changes.
- [ ] Verify externally:
  - `http3check.net` for immich → **QUIC OK** (h3 established).
  - External `curl` to a few direct apps → 200.
  - Traefik access log now shows **real client IPs** for direct apps (not `10.0.20.103`).

**Rollback (Phase 3):** point the 443 rule's target back to `nginx`.

## Phase 4 — Verify CrowdSec + the fleet (the real prize)

- [ ] Traefik logs: real public IPs on direct apps (sample several).
- [ ] CrowdSec: confirm it now ingests real IPs (a test decision / metrics);
      **confirm the source-IP allowlist** (`10.0.20.0/22`, `192.168.1.0/24`,
      tailnet) is active so family/LAN aren't banned.
- [ ] Proxied apps unaffected (spot-check 2-3 — still real IPs via Cloudflare).
- [ ] All other `.200` services healthy (PG state, headscale, wireguard, coturn,
      xray, etc.).
- [ ] Restore DNS TTL to normal.

## Phase 5 — Cleanup / docs

- [ ] Confirm Traefik no longer answers on `.200` (it shouldn't after Phase 1).
- [ ] Update docs (design doc "Affected docs" list): `.claude/CLAUDE.md`,
      `docs/architecture/networking.md`, service-catalog, memory ids 3241-3246.
- [ ] Commit TF + docs.

## Rollback (full)

Reverse order: pfSense 443 target → `nginx`; apex A → `.200`; revert the
Traefik Service TF (IP `.200`, `allow-shared-ip=shared`, ETP=Cluster) → apply.
kubectl/Helm reach the API server directly (not via Traefik), so control is
retained even if ingress is down mid-cutover.

## Additive (zero-downtime) variant — if the window is unacceptable

Instead of editing the Helm Service in place: add a second raw
`kubernetes_service` (type LoadBalancer, IP `.203`, ETP=Local, ports
web/80→8000, websecure/443→8443 TCP, websecure-http3/443→8443 UDP, selector =
Traefik pod labels). Both `.200` (old) and `.203` (new) serve Traefik. Cut
DNS+pfSense to `.203`, verify, then convert the Helm Service to ClusterIP
(drops `.200`). More config to carry long-term (a hand-maintained Service
duplicating Helm) — weigh against the brief in-place window.

## Attempt 1 — 2026-05-30 — ROLLED BACK (post-mortem)

First execution was rolled back to the `.200` baseline; all service restored,
TF state reconciled (`No changes`). The cutover **achieved its primary goal
mid-flight** (real external client IPs reached CrowdSec — confirmed real IPs
like `34.107.119.124` in Traefik logs instead of node `10.0.20.103`), but a
**missed dependency took proxied apps down**, forcing rollback. Fix the plan
before retrying:

1. **BLOCKER — cloudflared targets the LB IP.** The `cloudflared` tunnel is
   **token-based / Cloudflare-dashboard-managed** (`args: [tunnel]` +
   `TUNNEL_TOKEN`; no local `config.yaml`). Its ingress sends `*.viktorbarzin.me`
   to the **Traefik LB IP `10.0.20.200`**. Moving Traefik to `.203` left
   cloudflared pointing at a dead IP → **every proxied app (vault, home, …)
   went down**. **The retry MUST also repoint the tunnel ingress `.200 → .203`
   in Cloudflare (API/dashboard)** as part of the same cutover — ideally point
   cloudflared at the Traefik *ClusterIP/service* so it's IP-independent.
2. **Vault-ingress circular dependency.** Fetching the Technitium password from
   Vault *during* the window failed (Vault's ingress was down). Fix used:
   pre-fetch all creds before touching Traefik (worked). The DNS step then
   restored Vault.
3. **SIGPIPE → stuck PG state locks.** Piping `scripts/tg` through `head`/`grep`
   (early pipe close) SIGPIPE-killed terragrunt before it released the PG
   advisory lock, leaving an idle `terraform_state` connection holding the lock
   (`force-unlock` can't release another session's advisory lock). **Always run
   `tg` to a file, never pipe through early-closing filters.** Clear a stuck
   one by terminating the idle backend: `pg_terminate_backend(<pid>)` for the
   idle conn holding `pg_locks.objid` of the workspace.
4. **ETP=Local + hairpin.** Internal hosts that resolve `*.viktorbarzin.me` via
   *public* DNS and hairpin (e.g. the devvm) become flaky under ETP=Local.
   True external clients and internal-direct (`.203`) clients work. Ensure such
   hosts resolve internally (Technitium split-horizon).
5. **QUIC verification.** `http3check.net` was unreliable here (failed on TCP
   while real clients got 200s) — don't rely on it; confirm from a real device
   on cellular.

**Left in place for retry:** pfSense alias `traefik_lb` (=`10.0.20.203`, NAT
reverted to `nginx`); pfSense `config.xml` backups `config.xml.bak-traefik-*`.

## Attempt 2 — 2026-05-30 — SUCCESS

Live and verified, **no proxied/Vault outage** this time. Key change vs attempt 1:
**decouple cloudflared from the LB IP FIRST**, so moving Traefik no longer
touches the proxied path or Vault's ingress.

Executed order (all lessons applied — `tg` always run to a file, creds
pre-fetched while Vault up):
1. **Cloudflare tunnel ingress repointed** `https://10.0.20.200:443` →
   `https://traefik.traefik.svc.cluster.local:443` (both `*.viktorbarzin.me`
   and apex rules; `noTLSVerify` kept; catch-all 404 kept). Done via the
   **Cloudflare Global API Key** (`secret/platform` → `cloudflare_api_key`,
   email `vbarzin@gmail.com`, `X-Auth-Email`+`X-Auth-Key` headers — NOT the
   tunnel token, which is not an API credential). Tunnel: account
   `02e035473cfc4834fb10c5d35470d8b4`, id `75182cd7-bb91-4310-b961-5d8967da8b41`.
   → proxied apps now IP-independent.
2. Traefik Service → `10.0.20.203` + `ETP=Local` (single service; `tg apply`).
   Proxied apps + Vault stayed up (cloudflared → ClusterIP).
3. Technitium apex `viktorbarzin.me A` → `10.0.20.203` (ttl 60).
4. pfSense 443 (tcp+udp) NAT `nginx` → `traefik_lb` (`.203`); `/etc/rc.filter_configure`.

**Verified:** proxied 307/200 throughout; direct apps 200; **real external
client IPs now reach Traefik/CrowdSec** (`216.73.217.51`, `54.x`, `52.x` — not
node `10.0.20.103`); PG state DB OK; TF state reconciled (`tg apply` exit 0).

**Notes / follow-ups:**
- **Out-of-band (not in TF):** the cloudflared tunnel ingress (remote/dashboard
  config) and the pfSense `traefik_lb` alias + NAT. Codify the tunnel config in
  TF (`cloudflare_zero_trust_tunnel_cloudflared_config`) so `→ClusterIP` is
  declarative — pre-existing gap (tunnel was already remote-managed).
- **QUIC:** infra correct (ETP=Local + UDP 443 → `.203` + Traefik h3 listener).
  `http3check.net` is unreliable here — it hits the IPv6 AAAA
  (`2001:470:6e:43d::2`, separate HE-tunnel path, unchanged) and fails before
  reaching Traefik. Confirm QUIC from a real device (Chrome → Protocol `h3`).
- pfSense `nginx` alias (=`.200`) is now unused; `traefik_lb` (=`.203`) is live.
