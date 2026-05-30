# Design: Dedicated MetalLB IP for Traefik with externalTrafficPolicy=Local

**Date:** 2026-05-30
**Status:** Draft — for review (no changes applied yet)
**Author:** Viktor + Claude

## Problem

Two issues share one root cause on the Traefik ingress LoadBalancer:

1. **CrowdSec is blind to real client IPs on the 24 non-proxied/direct apps.**
   Traefik logs `10.0.20.103` (k8s-node3's IP) as the client for the
   overwhelming majority of direct-app requests (measured: 2522 hits vs 3
   real external IPs). Cause: the Traefik LB is `externalTrafficPolicy:
   Cluster`, so kube-proxy SNATs every external client to the MetalLB-elected
   node's IP before Traefik sees it. CrowdSec therefore makes ban decisions
   against an internal node IP it would never block → **no effective IP-based
   protection on the direct apps** (immich, forgejo, send, ytdlp, servarr,
   ebooks, novelapp, freedify, affine, health, f1-stream, kms, k8s-portal,
   etc. — 24 total).
   *Proxied apps are unaffected — they arrive via the cloudflared tunnel and
   get real IPs through Cloudflare's `X-Forwarded-For`.*

2. **HTTP/3 / QUIC does not complete for the direct apps.** An external probe
   (`http3check.net`) confirms "QUIC connection could not be established"
   despite `Alt-Svc: h3` being advertised and UDP 443 reaching Traefik
   (verified: pfSense NATs UDP 443 → Traefik LB; Traefik binds UDP 8443).
   Same root cause: `ETP=Cluster` + 3 replicas means kube-proxy SNATs and can
   spread the UDP flow across pods, which breaks the QUIC handshake.

Both are fixed by `externalTrafficPolicy: Local` on the Traefik LB (no SNAT →
real client IPs preserved → QUIC stays pinned to one pod).

## Why we can't just flip ETP on the current IP

Traefik currently shares MetalLB IP **`10.0.20.200`** with **9 other services**
via `metallb.io/allow-shared-ip`:

`dbaas/postgresql-lb` (**Terraform state backend**), `headscale/headscale-server`,
`wireguard/wireguard`, `coturn/coturn`, `xray/xray-reality`,
`shadowsocks/shadowsocks`, `beads-server/dolt`, `servarr/qbittorrent-torrenting`,
`tor-proxy/torrserver-bt`.

Per MetalLB docs, services sharing an IP **must all use `Cluster`** (or point
to identical pods). Mixing `Local` and `Cluster` on a shared IP is **not
allowed** and would break the IP allocation — taking down all ingress **and
the Terraform state DB** (locking out `terragrunt` itself), plus VPN/DNS path.
→ Traefik must move to its **own** IP.

## Target state

- New dedicated MetalLB IP **`10.0.20.203`** (free; pool is `10.0.20.200-220`),
  **not** shared, `externalTrafficPolicy: Local`, for the Traefik LB.
- `10.0.20.200` keeps the other 9 services unchanged (still all `Cluster`).
- Internal split-horizon DNS apex `viktorbarzin.me A` → `10.0.20.203`
  (currently `10.0.20.200`). All `*.viktorbarzin.me` CNAME → apex, so this one
  record moves every internal ingress hostname.
- pfSense: the WAN 443 (TCP **and** UDP) port-forward target moves from the
  `<nginx>` alias to a **new pfSense alias** for `10.0.20.203`
  (per request: define a VIP/alias, do **not** hardcode the IP in rules —
  matches the existing `<nginx>` / `<k8s_shared_lb>` alias pattern).

## Key decisions

- **Dedicated IP, not shared** — forced by the MetalLB mixed-ETP rule above.
- **`10.0.20.203`** — first free IP after technitium (.201) and kms (.202).
- **pfSense reference by alias, not literal IP** (user requirement) — create
  alias e.g. `traefik_lb` = `10.0.20.203`, reference it in the rdr + firewall
  pass rule. One place to change later.
- **Cutover style** — two options, decided at review (see plan):
  - *In-place* (recommended for maintainability): change the Helm Service to
    the new IP + ETP=Local in one edit; brief cutover window (mitigated by
    pre-lowering DNS TTL + staging the pfSense change).
  - *Additive* (zero-downtime): stand up a second LB Service on `.203`
    (ETP=Local) alongside the existing `.200` one, cut DNS/pfSense over, then
    retire Traefik from `.200`. More moving parts to maintain.

## Risks & watch-items

- **Terraform state backend lives on `.200`** — every phase must verify
  `dbaas/postgresql-lb:5432` stays reachable. We never touch `.200`'s config,
  only remove Traefik from it at the end; low risk but explicitly checked.
- **Live-firewall edit** (pfSense rdr + alias) — done via the pfSense UI
  (persisted in config.xml); CLI `pfctl` edits don't persist. Per the
  network-device rule, this step is operator-driven/confirmed, not automated.
- **CrowdSec behavior change** — once it sees *real* public IPs on direct
  apps, it will start making real ban decisions there. Confirm the security
  allowlist (source-IP allowlist `10.0.20.0/22`, `192.168.1.0/24`, tailnet;
  identity `me@viktorbarzin.me`) is correct so family/legit IPs aren't banned.
- **MetalLB ETP=Local node election** — `.203` is announced only from a node
  running a ready Traefik pod. Traefik has 3 replicas (node4, node5, +1) and
  PDB minAvailable=2, so ≥2 eligible nodes always exist; re-elects on failure.
- **Cloudflare-proxied apps** route via the cloudflared tunnel → Traefik
  ClusterIP, **not** the LB IP, so they are unaffected — verified in plan.
- **Cutover window** for the in-place option — keep it short; have rollback
  staged.

## Out of scope

- No change to the 9 services on `10.0.20.200`.
- No change to Cloudflare-proxied apps' path.
- No re-architecture of the pfSense↔K8s ingress beyond the 443 target move.

## Affected docs (update on apply)

- `.claude/CLAUDE.md` (Networking & Resilience / Service-Specific notes)
- `docs/architecture/networking.md` (or equivalent — Traefik LB IP, ETP)
- `docs/runbooks/` — add a short "Traefik LB IP / ETP" runbook entry
- `.claude/reference/service-catalog.md` if it records LB IPs
- memory: update the QUIC/ingress entries (ids 3241-3246)
