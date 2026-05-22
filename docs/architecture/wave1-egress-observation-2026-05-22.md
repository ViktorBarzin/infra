# Wave 1 W1.6/W1.7 — Egress Observation Snapshot (2026-05-22)

First analysis pass over the Calico GNP `wave1-egress-observe-tier34` data
captured in Loki via `{job="node-journal"} |~ "calico-packet"`.

**Data scope:** ~10000 flow log lines pulled from Loki over ~6h+24h windows.
Loki caps queries at 5000 records so longer windows are sample-capped.

**Coverage:** 36 source namespaces observed making egress (out of 82 selected
by `tier in {3-edge, 4-aux}`). Namespaces missing from data are either idle,
scaled to 0, or producing only intra-namespace traffic (which Calico Log
captures from-workload but most pods in those namespaces talk locally).

## Egress fan-out per namespace

| Namespace | dests | pod-ns | svc | external |
|---|---:|---:|---:|---:|
| affine | 3 | 2 | 1 | 0 |
| beads-server | 4 | 3 | 1 | 0 |
| cyberchef | 2 | 1 | 1 | 0 |
| dawarich | 3 | 2 | 1 | 0 |
| default | 1 | 0 | 0 | 1 |
| ebooks | 3 | 2 | 1 | 0 |
| f1-stream | 16 | 2 | 1 | 13 |
| forgejo | 2 | 1 | 1 | 0 |
| hackmd | 2 | 1 | 1 | 0 |
| homepage | 2 | 1 | 1 | 0 |
| isponsorblocktv | 2 | 0 | 1 | 1 |
| jsoncrack | 2 | 1 | 1 | 0 |
| kms | 2 | 1 | 1 | 0 |
| mailserver | 2 | 0 | 1 | 1 |
| meshcentral | 2 | 2 | 0 | 0 |
| n8n | 2 | 1 | 1 | 0 |
| nextcloud | 5 | 2 | 1 | 2 |
| onlyoffice | 2 | 1 | 1 | 0 |
| openclaw | 18 | 4 | 1 | 13 |
| paperless-ngx | 3 | 2 | 1 | 0 |
| phpipam | 3 | 2 | 1 | 0 |
| poison-fountain | 2 | 1 | 1 | 0 |
| postiz | 9 | 8 | 1 | 0 |
| realestate-crawler | 2 | 1 | 1 | 0 |
| recruiter-responder | 2 | 0 | 1 | 1 |
| rybbit | 2 | 1 | 1 | 0 |
| send | 2 | 1 | 1 | 0 |
| servarr | 134 | 2 | 2 | 130 |
| speedtest | 2 | 1 | 1 | 0 |
| status-page | 10 | 2 | 1 | 7 |
| tandoor | 2 | 1 | 1 | 0 |
| technitium | 5 | 2 | 1 | 2 |
| trading-bot | 5 | 2 | 1 | 2 |
| url | 2 | 1 | 1 | 0 |
| website | 2 | 1 | 1 | 0 |
| woodpecker | 8 | 2 | 1 | 5 |

## Common patterns

**Universal baseline** (every observed namespace makes these):
- `kube-system/kube-dns` UDP/53 — DNS resolution
- Often `dbaas` TCP/3306 (MySQL) or TCP/5432 (Postgres)
- Often `redis` TCP/6379

**Per-namespace specifics** (the part that varies):
- External HTTPS to specific IPs (CDNs, APIs)
- Internal pod-to-pod for service-specific clients

## W1.7 rollout candidates (sorted by simplicity)

**Tier A — trivial egress (recommend first wave):**

`recruiter-responder` has the simplest profile of all observed:
- `kube-system/kube-dns` :53/UDP
- `99.83.136.103` :443/TCP (Telegram API)

That's it. Two destinations. Perfect first enforce candidate.

**Tier B — small egress (≤3 external + ≤5 internal, 29 namespaces):**

affine, beads-server, cyberchef, dawarich, ebooks, forgejo, hackmd, homepage,
isponsorblocktv, jsoncrack, kms, mailserver, meshcentral, n8n, nextcloud,
onlyoffice, paperless-ngx, phpipam, poison-fountain, realestate-crawler,
rybbit, send, speedtest, tandoor, technitium, trading-bot, url, website.

These can be enforce'd in batches of 3-5/day after the recruiter-responder
pilot proves out.

**Tier C — moderate egress (5–18 external):**

f1-stream (13 ext), openclaw (13 ext), woodpecker (5 ext), status-page (7 ext).
Need per-IP allowlist or domain-based selectors.

**Tier D — broad egress (do NOT enforce statically):**

`servarr` has 130+ external IPs because it runs BitTorrent peer-to-peer.
Static IP enforcement won't work; either leave in Log+Allow mode permanently
or use a port-only allowlist (TCP+UDP 6881+random high ports outbound).

## Important caveats before flipping to enforce

1. **Observation horizon is too short.** Only ~6h of dense data and ~24h
   total. CronJobs that run weekly, periodic Vault token rotations (7d),
   external service maintenance windows, Keel auto-rollouts pulling new
   image versions — all missed. Recommend collecting **at least 7 days**
   before declaring an allowlist complete.

2. **`servarr`** is fundamentally incompatible with static enforce — keep
   in Log+Allow (or explicit deny for known-bad CIDRs only).

3. **External IPs are dynamic.** Cloudflare-fronted services rotate IPs.
   The recruiter-responder external IP `99.83.136.103` is one of Telegram's
   API endpoints — Telegram has a CIDR range. Allowing single IPs will break
   when DNS resolves to a different IP. Prefer Calico's `domains:` selector
   (Calico OSS supports DNS-based egress allowlists via `dns_policy_resolver`)
   OR allow the full Cloudflare/AWS CIDR range OR use a per-app egress
   gateway.

4. **The observation didn't capture intra-namespace traffic** by design —
   the Calico Log rule fires on egress from workload endpoint, but
   pod-to-same-namespace-pod traffic on the same node may bypass the
   filter chain (varies). Real-world testing needed after enforce flip.

## Suggested next-session sequencing

1. **Continue observation for at least 7 days** before any enforce flip.
   Compare data on 2026-05-29 vs today; if no new destinations show up,
   the allowlist is stable.
2. **First enforce: recruiter-responder.** GNP with allowlist =
   {kube-dns, telegram CIDR, vault svc, eso svc}. Watch for breakage.
3. **Tier B batch rollout** at 3-5 namespaces/day per Keel-style phased
   rollout pattern (memory id=1972).
4. **Tier C requires per-namespace investigation** — what are those
   external IPs? Map to known services first.
5. **servarr stays in Log+Allow** indefinitely (or migrate to dedicated
   egress proxy).

## Source data location

- Loki LogQL: `{job="node-journal"} |~ "calico-packet"`
- Pod IP → namespace map at observation time saved at
  `/tmp/pod-ip-map.txt` on the analysis host (ephemeral).
- Analysis scripts: `/tmp/analyze_flows2.py`, `/tmp/build_allowlist.py`.
- Tracked under beads `code-8ywc` (W1.7).
