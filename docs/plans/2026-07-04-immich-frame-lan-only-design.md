# immich-frame: LAN-only access, Portals untouched (2026-07-04)

## Goal

Strangers must no longer be able to view `highlights-immich.viktorbarzin.me`
(Viktor's London Portal Plus frame) or `highlights-immich-emo.viktorbarzin.me`
(Emo's Sofia Portal Mini frame) — pages or ImmichFrame API. Both were
`auth = "none"`, Cloudflare-proxied, fully public.

Who keeps access (per Viktor, this session): the two Portals plus **any
household device on the Sofia, London, or Valchedrym home networks**. No
public access, no tailnet requirement. Hard constraint: the Portal app is a
WebView with the URL **baked in at APK build time** (`portal-immich-frame`,
`-PframeUrl`), so the exact URLs must keep loading from where the Portals sit
— zero app rebuilds, zero device touches, zero router changes.

## Design

Two cooperating pieces — the gate and the reachability pointer:

1. **The gate — `home-lans-only` Traefik middleware** (traefik stack, next to
   `local-only`): `ipAllowList` of `192.168.1.0/24` (Sofia LAN), `10.0.0.0/8`
   (VLANs, K8s pods `10.10.0.0/16`, services `10.96.0.0/12`, WG tunnel
   `10.3.2.0/24`), `192.168.8.0/24` (London LAN), `192.168.0.0/24`
   (Valchedrym LAN), `fc00::/7`, `fe80::/10`. Attached to both frame
   ingresses via `extra_middlewares`. Everyone else gets a Traefik 403 —
   including direct-to-WAN-IP requests carrying the right SNI, which DNS
   changes alone cannot stop. A **separate** middleware rather than a widened
   `local-only`, because widening would silently grant the remote LANs access
   to the 9 admin surfaces using it (Prometheus, iDRAC, Loki, …).

2. **The pointer — `dns_type = "internal"`** (new `ingress_factory` tier,
   Viktor's idea): a **non-proxied public A record → `10.0.20.203`** (module
   var `internal_lb_ip`). Outsiders resolve it but get an unroutable RFC1918
   address; every household resolver path delivers a working answer with no
   config anywhere: Sofia LAN already gets the internal CNAME from Technitium,
   London/Valchedrym resolve the public record via any upstream and
   policy-route `10.0.0.0/8` down the WireGuard tunnel. IPv4-only (spokes
   route no internal v6 range).

Interlock (the reason both flip together): with a *proxied* record, public
traffic arrives from cloudflared **pod IPs inside 10/8** and would sail
through the allowlist. `internal` removes the Cloudflare path entirely (CF
edge stops serving the hostname), so every request reaches Traefik with its
real source IP (ETP=Local). Verified: no wildcard `*.viktorbarzin.me` record
exists to resurrect public resolution.

`auth` stays `"none"` — there is still no *user* auth by design (kiosk
WebView; forward-auth would 302 the device to a login it can't complete, and
emo's Google-only account can't log in inside a WebView at all); the
convention comment now names the ipAllowList as the gate.

### Resulting flows

| Client | Path | Result |
|---|---|---|
| Emo's Portal Mini (Sofia LAN) | Technitium CNAME → `.203` direct (unchanged) | allowed (`192.168.1.x`) |
| Viktor's Portal Plus (London LAN) | public A → `10.0.20.203` → WG tunnel | allowed (`192.168.8.x`) |
| Household browsers (any of the 3 LANs) | same as above | allowed |
| In-cluster checks (`homelab browser`, blackbox) | CoreDNS → Technitium → `.203` | allowed (pod IP in 10/8) |
| Stranger, resolves hostname | gets `10.0.20.203` | unroutable |
| Stranger, hits WAN IP with SNI | pfSense NAT → Traefik (real source IP) | **403** |
| Stranger, via Cloudflare | no proxied record | CF edge won't serve the host |

### Rejected alternatives

- **ImmichFrame `AuthenticationSecret`** (supported upstream: web input field
  or `?authsecret=` param + bearer API): real auth from anywhere, but family
  browsers would face a secret prompt (fails "household devices just work"),
  the secret leaks into URLs/analytics/APK, and robust rollout needs APK
  rebuild + USB-adb sideload on both Portals (the Sofia one is high-friction).
- **Authentik forward-auth / `auth = "public"`**: WebView can't complete SSO
  (Google blocks WebView logins; session expiry silently bricks an appliance);
  the anonymous outpost is an audit trail, not a gate.
- **Remove DNS + London router AdGuardHome rewrites**: works, but adds an
  out-of-band, un-IaC'd router dependency the internal-IP record makes
  unnecessary. Kept as documented fallback if resolver-side private-IP
  filtering ever appears in the London path.

## Pre-verified facts (2026-07-04)

- London Flint 2 DNS chain returns RFC1918 answers unfiltered
  (`nslookup 10.0.20.203.nip.io 127.0.0.1` on the router → `10.0.20.203`;
  dnsmasq `rebind_protection '0'`, no AdGuardHome rebind filtering).
- Technitium already CNAMEs both hostnames → apex → `10.0.20.203`
  (`technitium-ingress-dns-sync` is ingress-driven, not DNS-record-driven, so
  the internal answer survives the Cloudflare record swap).
- Pod CIDR `10.10.0.0/16`, service CIDR `10.96.0.0/12` — inside `10.0.0.0/8`.
- No public wildcard record in the zone.

## Blast radius & cleanups

- `external_monitor = false` set explicitly on both ingresses: the
  external-monitor-sync default opt-in would otherwise keep the now-doomed
  `[External] highlights-immich*` uptime-kuma monitors alive and red. Verify
  the sync drops them post-apply.
- rybbit CF worker: `highlights-immich` removed from `SITE_IDS` (`index.js`)
  and `wrangler.toml` routes — off Cloudflare the route can never fire.
  Requires a `wrangler deploy` to take effect (route removal is hygiene, not
  functional).
- Homepage dashboard link keeps working from LANs (hostname unchanged).
- Docs updated in the same change: `.claude/CLAUDE.md` (DNS tier +
  external-monitor mechanism), `AGENTS.md`, `docs/architecture/networking.md`
  (Internal-IP domains category). The `portal-immich-frame` repo's glossary
  ("public, login-less URL") updated separately in that repo.

## Failure-mode delta

London frame now depends on the WG tunnel instead of Cloudflare+cloudflared
(the app self-heals with 5s retries; tunnel-flap modes documented in
`docs/architecture/vpn.md`). A Traefik LB renumber must update
`internal_lb_ip` in the module alongside the split-horizon apex record.
Cutover window: cached proxied answers keep working ≤ ~5 min TTL, then the
WebView's own retry picks up the new path.

## Verification & rollback

Verify: public dig → `10.0.20.203` (both hosts); Technitium dig → `.203`;
curl from devvm (10/8) → 200; external vantage (WebFetch/cloud) → unreachable
or 403; middleware attached on both ingresses; Emo's frame renders via
`homelab browser`; London Portal image fetches visible in Traefik access logs
from `192.168.8.x`. Rollback: `git revert` + apply traefik/immich — records
and middleware chain restore (`allow_overwrite = true` re-adopts the records).
