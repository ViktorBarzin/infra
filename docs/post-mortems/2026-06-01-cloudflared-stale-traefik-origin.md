# Post-Mortem: Out-of-Band Tunnel Repoint Reverted by Terraform → Full External 502

| Field | Value |
|-------|-------|
| **Date** | 2026-06-01 |
| **Duration** | Drift present 2026-05-30 → 2026-06-01. Actual external outage began when a `terragrunt apply` reverted the tunnel origin on 2026-06-01 (cloudflared errors visible from ≥20:58Z); root-caused and fixed at 21:15Z; pods converged 21:16Z. |
| **Severity** | SEV1 — *every* Cloudflare-proxied hostname (`viktorbarzin.me` + all `*.viktorbarzin.me`) returned HTTP 502 to external clients. Internal/LAN access (split-horizon → Traefik direct) was unaffected, which is why it stayed hidden. |
| **Affected Services** | All external ingress: viktorbarzin.me, nextcloud, vault, authentik, vaultwarden, immich, linkwarden, nas, technitium, terminal, speedtest, and every other proxied app. |
| **Issue** | None filed (diagnosed and fixed in-session). |
| **Status** | Resolved. |
| **Recurrence count** | 1st of this exact kind. Same `.200→.203` migration family as the 2026-06-01 forgejo-registry containerd-redirect fix (`a382683c`). |

## Summary

On 2026-05-30 Traefik was moved off the shared MetalLB IP `10.0.20.200` onto a dedicated `10.0.20.203`. The migration plan correctly identified that the Cloudflare tunnel had to be repointed away from `10.0.20.200:443` **first**, and it was — but the repoint was done **out-of-band via the Cloudflare Global API Key**, not in Terraform. The Terraform source (`stacks/cloudflared/modules/cloudflared/cloudflare.tf`) was left pointing at `https://10.0.20.200:443`, creating silent drift between live (correct: service DNS) and code (stale: `.200`).

External ingress kept working for ~2 days on the manual config. Then on 2026-06-01 a `terragrunt apply` of the cloudflared stack reconciled live back to the stale Terraform value `https://10.0.20.200:443`. Nothing serves HTTPS on `.200:443` after the Traefik move, so cloudflared could not reach its origin (`connect: no route to host` / `i/o timeout`) and Cloudflare returned 502 across the entire public surface.

Fix: codify the correct origin in Terraform — both ingress rules now point at `https://traefik.traefik.svc.cluster.local:443` (in-cluster Traefik Service DNS). This both restores ingress and makes it permanent (TF and live agree; future applies can't revert it; the origin is decoupled from the Traefik LB IP entirely).

## Impact

- **User-facing**: 100% of externally-reachable services returned 502 via Cloudflare. LAN/internal access (which resolves `*.viktorbarzin.me` → `10.0.20.203` via Technitium split-horizon, bypassing Cloudflare) kept working — this masked the outage.
- **Blast radius**: every proxied hostname. Origin (Traefik) was healthy the whole time — purely a tunnel-origin routing fault.
- **Data loss**: none.
- **Collateral**: Vault's own public hostname (`vault.viktorbarzin.me`) was also 502, creating a bootstrap problem — `terragrunt apply` needs Vault for the PG state-backend creds, but Vault was only reachable from the dev box via the broken tunnel. Worked around with a temporary `/etc/hosts` entry pointing `vault.viktorbarzin.me` → `10.0.20.203` (internal Traefik), removed after the apply.

## Root Cause

**A manual (out-of-band) fix was never codified in Terraform, and a later Terraform apply reverted it.** This is a direct violation of the repo's "Terraform Only — all infra changes go through Terraform" rule. The 2026-05-30 plan applied the tunnel repoint via the Cloudflare API for speed/safety during the migration but did not land the equivalent change in `cloudflare.tf`. Terraform's authority over the resource guaranteed the manual change would eventually be reverted; it was, on the next apply.

Contributing factors:
- **No drift alarm tied this to user impact.** The TF/live divergence on `cloudflare_zero_trust_tunnel_cloudflared_config` existed for ~2 days; drift-detection (if it ran) didn't escalate it as outage-risk.
- **Detection gap (masking).** Split-horizon means LAN users never see external-only breakage. The `[External]` Uptime-Kuma monitors + `ExternalAccessDivergence` alert are the only signal for this failure mode, and they did not prompt action.
- **Docs vs code.** CLAUDE.md described cloudflared as targeting the service DNS — true of live (post-manual-fix) but not of the TF source. The doc masked the drift.

## Timeline (UTC)

| Time | Event |
|------|-------|
| **2026-05-30 ~08:09** | Traefik Service moved to `10.0.20.203` (`ETP=Local`). Plan step 1 repoints the tunnel `https://10.0.20.200:443` → `https://traefik.traefik.svc.cluster.local:443` **via the CF Global API Key (out-of-band)**. Ingress works. `cloudflare.tf` still says `.200` → **drift**. |
| **2026-05-30 → 06-01** | External ingress healthy on the manual config. Drift sits unnoticed. |
| **2026-06-01 (during the day)** | A `terragrunt apply` of the cloudflared stack reconciles the tunnel origin back to the stale TF value `https://10.0.20.200:443`. External ingress breaks → 502. |
| **2026-06-01 ~20:51** | Keel auto-patches the cloudflared image; pods roll (coincidental, not causal). |
| **~20:58** | cloudflared logs show every proxied hostname failing against `https://10.0.20.200:443` (`no route to host` / `i/o timeout`). |
| **21:08** | User reports "no ingress coming in." Investigation starts. |
| **21:09** | Isolated: origin healthy (direct to `.203` → 200/302), public path → 502; logs pin origin to dead `.200:443`. |
| **21:13** | Vault unreachable via public name (circular dep); temp `/etc/hosts` → `.203`. `tg init -reconfigure` (rotated PG backend creds). |
| **21:15:25** | Targeted apply: both ingress origins → service DNS. `Apply complete! 1 changed`. |
| **21:16** | 10/10 curls to `viktorbarzin.me` → 200; 0 `.200` errors across all pods; `vault.viktorbarzin.me` via real Cloudflare → 200. Temp hosts entry removed. Resolved + committed (`f807050e`). |

## Resolution

Changed both `ingress_rule` blocks in `cloudflare.tf` from `https://10.0.20.200:443` to `https://traefik.traefik.svc.cluster.local:443` (`no_tls_verify` retained), making the Terraform source match the intended (and previously-manual) live config. Applied surgically with `-target` on the tunnel config resource only, to avoid touching two pre-existing, unrelated drift items the full plan surfaced (below). Committed `[ci skip]` since live already matched after the targeted apply.

## Pre-existing drift (NOT part of this incident, left untouched)

The full `cloudflared` stack plan showed two extra in-place changes, deliberately **not** applied:
1. `kubernetes_deployment.cloudflared` — TF would strip Keel's runtime annotations (`keel.sh/policy|pollSchedule|trigger|update-time`). The deployment ignores `dns_config` but not `metadata.annotations`. Self-healing (Keel re-adds within its 1h poll); clean fix is to add `metadata[0].annotations` (+ template equivalent) to `ignore_changes`.
2. `cloudflare_record.mail_domainkey_rspamd` — cosmetic re-chunking of the DKIM TXT record (identical key). Benign.

## Action Items

- [x] Codify tunnel origin (service DNS) in `cloudflare.tf` (this fix) — drift eliminated.
- [x] Fix stale `10.0.20.200:443` Traefik reference in `docs/runbooks/kms-public-exposure.md` (→ `.203`).
- [x] Post-mortem written.
- [ ] **Audit for other out-of-band changes from the 2026-05-30 migration** that were applied via CF API / kubectl / pfSense but not landed in code — they will all revert on the next apply.
- [ ] **Make `ExternalAccessDivergence` trustworthy and seen** — it is the only signal for external-only outages and did not prompt action here.
- [ ] **Drift detection should flag tunnel-origin divergence as outage-risk**, not just generic drift.
- [ ] (Optional) Pin the exact reverting-apply time via Woodpecker pipeline history for the cloudflared stack on 2026-06-01.
- [ ] (Optional) Fix the cloudflared Keel-annotation drift so the stack plans clean.

## Lessons

- **Codify out-of-band fixes immediately.** A manual change to a Terraform-managed resource is a time bomb — Terraform *will* revert it on the next apply. The "Terraform Only" rule exists for exactly this; the 05-30 manual tunnel repoint should have been mirrored into `cloudflare.tf` the same day.
- **Reference shared infra (Traefik) by stable Service DNS, not LB IP**, from anything that can use cluster DNS. The service-DNS origin also happens to survive LB-IP moves.
- **External-only outages are invisible from the LAN** (split-horizon). The `[External]` divergence signal is load-bearing — it must be trustworthy and actually seen.
- **Keep docs honest about source-of-truth.** "Live is correct" is not the same as "code is correct"; a doc that conflates them hides drift.
