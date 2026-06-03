# L4 LoadBalancer IP review & pfSense hygiene — design + decisions

**Date:** 2026-06-03
**Status:** repo changes implemented; pfSense DHCP shrink pending live-change approval
**Trigger:** "Review the L4 LB IPs we give away, consolidate, and use pfSense Virtual IPs instead of hardcoding IPs in rules."

## TL;DR

The headline ask — **consolidate to fewer MetalLB IPs** — is a verified dead end. The
real, worthwhile outcome is a **single source of truth (this doc + the renumber
checklist in `architecture/networking.md`) plus two stale-reference fixes**. We
deliberately did **not** reduce the IP count and did **not** do the high-risk pfSense
mail-VIP surgery.

## Current state (verified live, 2026-06-03)

MetalLB L2, pool `10.0.20.200-220` (21 IPs, **17 free**). Four in use:

| IP | ETP | What | Why dedicated |
|----|-----|------|---------------|
| `.200` | Cluster (shared) | ~9 svcs: postgresql-lb (TF state), dolt, coturn, headscale, wireguard, qbittorrent, shadowsocks, torrserver, xray | already maximally consolidated (the 2026-03 "5→1" merge) |
| `.201` | Local | technitium-dns | real client IP → network-scoped split-horizon |
| `.202` | Local | windows-kms | real client IP → notifier source labeling |
| `.203` | Local | traefik | real client IP (CrowdSec) + QUIC/HTTP3 (UDP) |

## Why consolidation fails (the core finding)

MetalLB L2 only lets multiple `ETP=Local` services **share** an IP if they have
**identical pod selectors** (so traffic to the single announcing node lands on the
right pods). Traefik / KMS / Technitium have disjoint selectors and disjoint pods,
and a shared `ETP=Local` IP announces from one node (stateless `node+VIP` hash) —
blackholing any service whose pods aren't there. Refs:
[MetalLB L2 concepts](https://metallb.universe.tf/concepts/layer2/),
[Usage / IP sharing](https://metallb.universe.tf/usage/),
[issue #271](https://github.com/metallb/metallb/issues/271).

Consequences:
- **Traefik can never leave a dedicated `ETP=Local` IP** — QUIC's UDP listener needs it; QUIC can't traverse pfSense HAProxy either.
- The trio is **fewer-IPs XOR client-IP preservation** — not both. The only "both" is making all three DaemonSets (breaks Technitium's primary/secondary AXFR design; burns resources to save 2 of 17 free IPs). Not worth it.

**Decision (user, 2026-06-03):** keep all 4 dedicated, preserve client IPs everywhere. No MetalLB changes.

## Why a doc registry instead of a `config.tfvars`/Terraform IP variable

The cascade risk is **consumers that hardcode another service's IP and get forgotten**
(the 2026-05-30 Traefik `.200→.203` move broke cloudflared, woodpecker, containerd,
and the `.lan`+`.me` zones). A Terraform-var single-source was considered and rejected:

1. Editing `terragrunt.hcl`/`config.tfvars` triggers the CI "global change → apply ALL
   ~37 platform stacks" path (`.woodpecker/default.yml`) — a 37-stack apply for what
   are no-op refactors (rendered IPs unchanged), risking unrelated drift surfacing.
2. It can't cover the **out-of-band** consumers (cloudflared via CF-API, containerd
   `hosts.toml` on each node) — which were half the 2026-05-30 breakage.
3. Bootstrap-critical literals (PG state in `scripts/tg`, node DNS) must stay literals
   (DNS chicken-and-egg) regardless.

A **documentation registry** (the "LB-IP renumber checklist" in
`architecture/networking.md`) covers *all* consumers — in-band and OOB — at zero
apply-risk, and is the complete pre-move checklist. That is the single source of truth.

## Changes made (minimal-hygiene scope)

1. **`architecture/networking.md`** — rewrote the stale MetalLB section into an accurate
   registry (it had KMS on `.200`, mailserver on a LB IP, "two dedicated" — all wrong)
   + added the **renumber checklist**.
2. **woodpecker** (`stacks/woodpecker/main.tf`) — the `forgejo.viktorbarzin.me`
   hostAlias hardcoded the **dead** `10.0.20.200` (Traefik moved to `.203`; `.200:443`
   refuses TLS). Now reads the Traefik **ClusterIP dynamically** (`data
   "kubernetes_service" "traefik"`) so it can't rot on a future renumber and avoids the
   ETP=Local hairpin trap. (Real fix — the next woodpecker apply would otherwise
   re-pin the dead IP and break pipeline creation.)
3. **monitoring** (`prometheus_chart_values.tpl`) — `ViktorBarzinApexDrift` alert
   summary said "expected 10.0.20.200" (stale post-Traefik-move) → `.203`. Cosmetic
   (alert logic was already correct) but prevents a misleading incident message.
4. **`backend.tf`** — 72 stale generated copies were tracked in git with a plaintext
   (Vault-rotated, ~expired) PG password + `.200` literal, despite already being in
   `.gitignore`. `git rm --cached` (they regenerate from `PG_CONN_STR`). History scrub
   deferred (creds rotate weekly → low urgency).
5. **pfSense DHCP range** (`opt1`/K8s VLAN) — `.200-.254` overlaps the MetalLB pool
   `.200-.220` (latent IP-conflict: DHCP could hand out a live LB IP). Plan: shrink to
   start at `.221`. Verified zero leases/statics in the band. **PENDING** — live
   pfSense change, applied separately after explicit approval (live network device).

## Explicitly NOT done (rationale)

- **No MetalLB IP merging** — infeasible without losing client-IP/QUIC/HA (above).
- **No mail Virtual IP** — mail binds pfSense's own `10.0.20.1`, the most stable IP in
  the system; the 2026-06-02 incident was a *DNS split-horizon* bug, not an IP move.
  A mail VIP is 4 NAT + 5 filter + HAProxy cutover on the live mail path for marginal
  "identity" benefit. Skipped.
- **No `nginx`-alias delete / NAT literal→alias** — pfSense rule cosmetics; left for a
  later pfSense-focused pass (would also need the web filter F#2/F#3 `nginx`→`traefik_lb`
  repoint to avoid breaking 80/443).
- **No Terraform IP variable** — see registry rationale above.

## Known latent items (documented, not fixed here)

- pfSense web filter rules F#2/F#3 reference `nginx` (.200) while their NAT targets
  `traefik_lb` (.203) — inconsistent but currently passing; fix in a pfSense pass.
- pfSense NAT 53 hardcodes literal `10.0.20.201` instead of the `technitium_dns` alias.
- In-cluster `*.viktorbarzin.me` split-horizon still resolves some hosts to the dead
  `.200` (beads `code-yh33`) — the woodpecker hostAlias is the per-app workaround.
- CrowdSec syslog `remoteserver` doc/config drift (`.200` vs comment `.202`).
