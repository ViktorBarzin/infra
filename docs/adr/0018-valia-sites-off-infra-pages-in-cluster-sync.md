# Valia sites are served off-infra (Cloudflare Pages), synced in-cluster

Valia (Viktor's mother) authors small one-page static sites in Google Drive folders she
shares, and keeps asking for them to be hosted — two exist already (`stem95su`, `bridge`)
and more are expected. We decided all **Valia sites** are served **off-infra on Cloudflare
Pages** under `<english-name>.viktorbarzin.me`, kept fresh by **one shared in-cluster
CronJob** (`stacks/valia-sites/`) that mirrors each **Content folder** every 10 minutes
(rclone, drive.readonly) and re-deploys only on change (wrangler direct upload). The
existing in-cluster `stem95su` serving stack (nginx + NFS + ingress + per-site sync)
migrates onto this and is retired.

Why off-infra serving: these are her sites, shown to teachers/parents — they must survive
homelab outages (cf. the 2026-06-27 egress incident that took every proxied in-cluster
site down). With Pages, a homelab outage degrades to "content frozen until we're back",
never "site down". Serving costs no cluster resources and no per-site nginx/PVC/ingress/
Anubis. Why the syncer stays in-cluster anyway: secrets stay in Vault (no per-site GHA
secret sprawl), and the stem95su guard patterns (hard-fail on Drive auth errors, never
wipe a live site on an empty/partial folder, capped deletes) carry over wholesale. The
deliberate asymmetry — off-infra serving, on-infra syncing — is the point, not an
accident.

## Considered options

- **In-cluster everywhere** (generalise stem95su into a factory module): one roof, no
  Cloudflare Pages dependency — but her sites share the homelab's fate and each site
  spends cluster resources to serve static files a free CDN serves better.
- **Pages for new sites only**: less work now, two patterns and two runbooks forever.
- **GHA-scheduled sync** (fully off-infra pipeline): no cluster dependency at all, but
  Drive + Cloudflare credentials would live as GitHub secrets per repo, outside Vault.

## Consequences

- Registration is one entry in the `sites` map (name, Content folder, optional Entry
  file); CI applies Pages project, custom domain, public CNAME, and internal-DNS config
  together. Names are English, picked by Viktor (most → bridge set the precedent).
- The internal split-horizon zone learns Valia sites from a ConfigMap the
  `technitium-ingress-dns-sync` script consumes — declaratively, including **removal**
  (the previous static-CNAME approach was add-only; a retired site left a stale record).
- Deploy-on-change is mandatory, not an optimisation: Pages caps monthly deployments on
  the free tier, and a 10-minute cadence would burn ~4,300/month if unchanged runs
  deployed.
- Failure visibility is **failed-Job-only** by explicit choice (no stale-sync alert, no
  per-site uptime monitors, no notifications to Valia) — Viktor fields "it didn't
  update" reports, consistent with the alert-noise-reduction posture. Revisit if a
  silent stall actually bites.
- If the homelab is down, content updates pause; the sites keep serving last-deployed
  content. Accepted degradation.
