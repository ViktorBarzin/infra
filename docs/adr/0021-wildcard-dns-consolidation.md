# ADR-0021: Wildcard DNS — one proxied CNAME for the whole app fleet

Date: 2026-07-09
Status: Accepted

## Context

The `viktorbarzin.me` Cloudflare zone sits on the Free plan, capped at 200
DNS records. On 2026-07-04 the zone HIT the cap and blocked a deploy (the
drone-logbook ingress could not create its record); two rounds of ad-hoc
dead-name cleanup (2026-07-04, 2026-07-08) bought back only a handful of
slots. At analysis time (2026-07-09) the zone held **185/200 records** for
148 unique names, and nearly every name was load-bearing — the bloat was
structural, not dead weight:

- **99 proxied CNAMEs** (one per app, incl. apex), all pointing at the SAME
  tunnel (`75182cd7-….cfargotunnel.com`), whose Terraform-managed config
  already routed `*.viktorbarzin.me` → Traefik with a catch-all. The
  per-name records added nothing but a DNS answer.
- **67 records as A+AAAA pairs** for ~34 non-proxied names (every direct
  name costs 2 slots).
- ~19 mail/TXT/special records (untouchable).

Paying Cloudflare for a higher record limit was rejected: a recurring cost
to keep records a single wildcard makes redundant.

## Decision

1. **One proxied wildcard CNAME `*` → the tunnel** (declared in
   `stacks/cloudflared/modules/cloudflared/cloudflare.tf`). Cloudflare has
   supported proxied wildcards on all plans since 2021. The Universal SSL
   edge cert already covers `*.viktorbarzin.me` + apex (single-level names
   only — never create `a.b.viktorbarzin.me` web hosts).
2. **`dns_type = "proxied"` keeps its meaning but no longer creates a
   record.** Both ingress factories (`modules/kubernetes/ingress_factory`,
   `stacks/reverse-proxy/modules/reverse_proxy/factory`) stop declaring
   per-name proxied CNAMEs; the value still drives the external-monitor
   annotation and records intent at the call site. ~60 call sites needed
   zero churn.
3. **Apex carve-out**: a DNS wildcard does NOT cover the zone apex.
   `ingress_factory` keeps creating the proxied record when the effective
   host IS the root domain (`dns_name == "@"`, used by `stacks/blog`).
4. **Explicit records shadow the wildcard** — this is standard DNS wildcard
   semantics (RFC 4592: a wildcard only synthesizes answers for names with
   no records of any type). Non-proxied A/AAAA names (immich, forgejo,
   mail, …) and `internal` names are therefore unaffected by the wildcard.

## Security consequence — "dark by missing DNS" is dead

Before: a `.me` ingress with `dns_type = "none"` was unreachable from the
internet — Cloudflare's edge refuses to route hostnames that are not
provisioned in the zone, so no public DNS record meant no public path.

After the wildcard, EVERY recordless `.me` name resolves through the proxy
and reaches Traefik, which routes by Host header to whatever ingress
matches. **A `.me` ingress can no longer be private by omission.** The
doctrine is now:

- Internal-only `.me` ingress → `dns_type = "internal"` (explicit A record
  carrying the internal Traefik LB IP `10.0.20.203` shadows the wildcard;
  outsiders resolve an unroutable RFC1918 address) **plus**
  `extra_middlewares = ["traefik-home-lans-only@kubernetescrd"]` (the record
  is reachability, not a gate — direct-to-WAN-IP SNI requests and, if the
  shadow record were ever deleted, wildcard-riding requests still reach
  Traefik).
- Truly private services → host them on `viktorbarzin.lan` (Technitium
  split-horizon only; does not exist in the public zone at all).

Applied at cutover (2026-07-09, "part 1/3" commit): `family`,
`hermes-agent`, `mladost3`, `torrserver` moved to `internal` (+4 records,
preserving their exact prior posture), and the orphaned unauthenticated
`task-webhook` public ingress was deleted outright (the Forgejo webhook
calls the cluster-local Service; the public hostname had zero callers).

Accepted trade-offs:

- Unknown/typo'd subdomains resolve and serve Traefik's 404 via the tunnel
  (was NXDOMAIN). Scanner traffic hits the CrowdSec-protected edge; the
  `crowdsec-cf-sync` zone WAF rule and rate-limit middleware apply as for
  any proxied host. A hostname that must NXDOMAIN publicly is no longer
  possible on `.me`.
- Anyone can make `<anything>.viktorbarzin.me` resolve (e.g. for phishing
  lures); it serves only the 404/error page. Same exposure class as any
  wildcard-DNS operator.

## Record accounting

| | before | after |
|---|---|---|
| proxied CNAMEs → tunnel | 99 | 2 (apex + `*`) + `test-failover` canary |
| non-proxied A+AAAA | 67 | 62 (proxy.viktorbarzin.me deleted −2; dead AAAA off vpn/turn/xray-reality −3, ports 51820/3478/7443 are not bridged by the IPv6 HAProxy which carries only 443/80+mail) |
| internal shadows | 2 | 6 (+family, hermes-agent, mladost3, torrserver) |
| mail / TXT / MX / Pages / keyserver / vlmcs | ~19 | ~19 |
| **total** | **185/200** | **≈87/200** |

Marginal cost of a new app: proxied = **0 records**, internal = 1,
non-proxied = 2. The cap stops being an operational concern; no record-count
guardrail was added (explicit decision — headroom is ~113 and only
non-proxied/internal apps consume slots).

## Rollback

Every deleted per-name CNAME is recreatable from git history: revert the
factory-module commits and re-apply the affected stacks (`allow_overwrite =
true` makes recreation conflict-free). The wildcard record itself is one
resource — deleting it restores the exact pre-change resolution behaviour
for recordless names (NXDOMAIN).

## References

- Tunnel catch-all + stale-origin post-mortem:
  `docs/post-mortems/2026-06-01-cloudflared-stale-traefik-origin.md`
- `dns_type = "internal"` design:
  `docs/plans/2026-07-04-immich-frame-lan-only-design.md`
- IPv6 bridge scope (why some AAAA records were dead):
  `docs/architecture/networking.md` → "IPv6 Ingress"
- Outage-failover canary kept as-is (`test-failover`): ADR-0020
