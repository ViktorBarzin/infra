# Post-Mortem: Cloudflare Tunnel Pointed at Traefik's Old LB IP → Full External 502

| Field | Value |
|-------|-------|
| **Date** | 2026-06-01 |
| **Duration** | Misconfiguration latent since 2026-05-30 08:09Z (Traefik LB-IP move). Confirmed external outage in cloudflared logs from ~20:58Z; root-caused and fixed at 21:15Z; all pods converged by 21:16Z. Detection→fix window ~17 min. |
| **Severity** | SEV1 — *every* Cloudflare-proxied hostname (`viktorbarzin.me` + all `*.viktorbarzin.me`) returned HTTP 502 to external clients. Internal/LAN access was unaffected (split-horizon → Traefik direct), which is why it stayed hidden. |
| **Affected Services** | All external ingress: viktorbarzin.me, nextcloud, vault, authentik, vaultwarden, immich, linkwarden, nas, technitium, terminal, speedtest, and every other proxied app. |
| **Issue** | None filed (diagnosed and fixed in-session). |
| **Status** | Resolved. |
| **Recurrence count** | 1st of this kind. Same *class* as the 2026-06-01 forgejo-registry `.200→.203` redirect breakage (containerd mirror) — both are fallout from the 2026-05-30 Traefik LB-IP move leaving a hard-coded `10.0.20.200` reference behind. |

## Summary

On 2026-05-30 (commit `0c01adac`) Traefik was moved off the shared MetalLB IP `10.0.20.200` onto its own dedicated IP `10.0.20.203` (with `externalTrafficPolicy: Local`). The Cloudflare tunnel's ingress rules — Terraform-managed in `stacks/cloudflared/modules/cloudflared/cloudflare.tf` — still routed `*.viktorbarzin.me` and `viktorbarzin.me` to `https://10.0.20.200:443`. After the move, nothing serves HTTPS on `.200:443` (the shared IP keeps only the non-HTTP LB services: postgresql-lb, headscale, wireguard, coturn, xray). cloudflared therefore could not reach its origin (`connect: no route to host` / `i/o timeout`), and Cloudflare returned 502 for the entire public surface.

The fix: repoint both ingress rules at the in-cluster Traefik **Service DNS** `https://traefik.traefik.svc.cluster.local:443` — the design the docs already *described* (CLAUDE.md "Networking" §) but which the code never actually implemented. Service DNS decouples the tunnel from the LB IP, so a future Traefik IP change cannot reproduce this.

## Impact

- **User-facing**: 100% of externally-reachable services returned 502 via Cloudflare. LAN/internal access (which resolves `*.viktorbarzin.me` → `10.0.20.203` via Technitium split-horizon, bypassing Cloudflare) kept working — this masked the outage.
- **Blast radius**: every proxied hostname. Origin (Traefik) was healthy the entire time — purely a tunnel-origin routing fault.
- **Data loss**: none.
- **Collateral**: Vault's own public hostname (`vault.viktorbarzin.me`) was also 502, creating a bootstrap problem for the fix — `terragrunt apply` needs Vault for the PG state-backend creds, but Vault was only reachable via the broken tunnel from the dev box. Worked around with a temporary `/etc/hosts` entry pointing `vault.viktorbarzin.me` → `10.0.20.203` (internal Traefik), removed after the apply.

## Root Cause

A hard-coded LB IP (`10.0.20.200`) in the tunnel origin survived the Traefik dedicated-IP migration. The 2026-05-30 migration updated Traefik's Service and the split-horizon DNS but did not grep for every consumer of the old `.200` HTTPS endpoint. The cloudflared tunnel origin (and, separately, the containerd forgejo-registry redirect — fixed earlier the same day in `42db69a2`) were missed.

Contributing factors:
- **Docs described intent as reality.** CLAUDE.md stated cloudflared targets `traefik.traefik.svc.cluster.local:443` "so proxied apps are decoupled from the LB IP." The code used a raw IP. The doc gave false confidence that the decoupling existed.
- **No guard** tied the tunnel origin to Traefik's actual address; a stale value plans/applies cleanly.
- **Detection gap (masking).** Split-horizon means LAN users never see external-only breakage. The `[External]` Uptime-Kuma monitors + `ExternalAccessDivergence` alert are the only signal for this failure mode.

## Timeline (UTC)

| Time | Event |
|------|-------|
| **2026-05-30 08:09** | Commit `0c01adac` — Traefik moves to dedicated LB IP `10.0.20.203`. `.200:443` stops serving HTTPS. Tunnel origin still `.200`. Outage latent from here. |
| **2026-06-01 ~20:51** | Keel auto-patches the cloudflared image; all 3 pods roll (coincidental — not the cause; the misconfig predates it). |
| **2026-06-01 ~20:58** | cloudflared logs show every proxied hostname failing: `originService=https://10.0.20.200:443 … no route to host / i/o timeout`. |
| **2026-06-01 ~21:08** | User reports "no ingress coming in." Investigation starts. |
| **21:09** | Isolated: origin healthy (direct to `.203` → 200/302), public path → 502. cloudflared logs pin origin to dead `.200:443`. |
| **21:10** | Confirmed tunnel config is Terraform-managed (`cloudflare_zero_trust_tunnel_cloudflared_config.sof`), origin = `.200` on both ingress rules. |
| **21:13** | Vault unreachable via public name (circular dep); worked around with temp `/etc/hosts` → `.203`. `tg init -reconfigure` (rotated PG backend creds). |
| **21:15:25** | Targeted apply: both ingress origins → `https://traefik.traefik.svc.cluster.local:443`. `Apply complete! 1 changed`. |
| **21:15:34–50** | cloudflared pushes config `version=253`; pods converge. |
| **21:16** | 10/10 curls to `viktorbarzin.me` → 200; 0 `.200` errors across all pods; `vault.viktorbarzin.me` via real Cloudflare path → 200. Temp hosts entry removed. Resolved. |

## Resolution

Changed both `ingress_rule` blocks in `cloudflare.tf` from `https://10.0.20.200:443` to `https://traefik.traefik.svc.cluster.local:443` (`no_tls_verify = true` retained). Applied surgically with `-target` on the tunnel config resource only, to avoid touching two pre-existing, unrelated drift items the full plan surfaced (see below).

## Pre-existing drift (NOT part of this incident, left untouched)

The full `cloudflared` stack plan showed two extra in-place changes, deliberately **not** applied:
1. `kubernetes_deployment.cloudflared` — TF would strip Keel's runtime annotations (`keel.sh/policy|pollSchedule|trigger|update-time`). The deployment ignores `dns_config` but not `metadata.annotations`, so Keel's enrollment annotations look like drift. Self-healing (Keel re-adds within its 1h poll), but a clean fix is to add `metadata[0].annotations` (and the template equivalent) to `ignore_changes`, or codify the policy annotation in TF.
2. `cloudflare_record.mail_domainkey_rspamd` — cosmetic re-chunking of the DKIM TXT record (identical key, different 255-char split). Benign.

## Action Items

- [x] Repoint tunnel origin to Traefik Service DNS (this fix).
- [x] Post-mortem written; CLAUDE.md networking claim is now actually true.
- [ ] **Pin exact outage-start** via Uptime-Kuma `[External]` monitor history / `ExternalAccessDivergence` firing time (confirm whether it began at the 05-30 move and went unnoticed, or at a later tunnel re-apply).
- [ ] **Verify `ExternalAccessDivergence` is wired to a channel that gets seen** — this is the only alert that catches external-only breakage; it apparently did not prompt action for ≤2.5 days.
- [ ] **Migration checklist**: when an LB IP changes, grep the whole repo for the old IP before declaring done (this and the forgejo redirect were both missed `.200` references on 2026-05-30).
- [ ] (Optional) Address the cloudflared Keel-annotation drift so the stack plans clean.

## Lessons

- Reference shared infra (Traefik) by **stable Service DNS, not LB IP**, from anything that can use cluster DNS. IPs are migration landmines.
- Keep docs honest: a doc that describes intended design as current reality hides exactly this class of bug.
- External-only outages are invisible from the LAN (split-horizon). The `[External]` divergence signal is load-bearing — it must be trustworthy and seen.
