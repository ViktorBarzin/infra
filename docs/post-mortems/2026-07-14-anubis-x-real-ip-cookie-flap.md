# 2026-07-14 — Anubis-fronted sites served blank pages (X-Real-Ip cookie flap)

**Status:** resolved (fix: `traefik-drop-x-real-ip` middleware on all Anubis-fronted ingresses)
**Severity:** SEV2 — home.viktorbarzin.me (the user-facing service directory) and, in principle, all 7 Anubis-fronted public sites broken for externally-routed (Cloudflare) users for ~2 days. Internal/VPN users unaffected. No data loss.
**Detected by:** user report ("home.viktorbarzin.me shows an empty page"). Monitoring was blind — see Lessons.

## Impact

- External users of `home.viktorbarzin.me` got the HTML shell + a random ~half of the
  JS/CSS assets; the app entry chunks (`main-*.js`, `index-*.js`, `custom.css`) received
  Anubis challenge HTML instead → the SPA never hydrated → blank/empty page.
- Every failed validation also **cleared** the user's `techaro.lol-anubis-auth` cookie, so
  the state never self-healed. All Anubis-fronted sites (blog, kms, f1, cc, json, home,
  wrongmove UI) shared the failure mode for CF-routed traffic.
- Anubis metrics over the ~3 days: ~900 challenges issued, **1** validated.

## Root cause — three interacting layers

```mermaid
flowchart LR
    U[Browser] --> CF[Cloudflare edge]
    CF -->|"tunnel conns (round-robin per request)"| CFD1[cloudflared pod A]
    CF --> CFD2[cloudflared pod B]
    CFD1 --> T[Traefik]
    CFD2 --> T
    T -->|"X-Real-Ip := TCP peer = pod A/B IP (flaps!)"| AN[anubis]
    AN -->|"JWT bound to X-Real-Ip → ~50% invalid → challenge HTML + cookie clear"| APP[homepage]
```

1. **Anubis (v1.25.0) binds auth-cookie validity to the derived client IP** — the
   `X-Real-Ip` header when present, else the first public `X-Forwarded-For` entry after
   private-hop stripping (`XFF_STRIP_PRIVATE=true`; the derived value is what the stored
   challenge record's `{User-Agent, X-Real-Ip}` metadata carries). Characterized by
   controlled A/B against the live pods: a valid cookie passes with the original client
   IP and re-challenges when ONLY the IP changes (both via the X-Real-Ip header and via
   XFF with no X-Real-Ip at all); a UA change does NOT invalidate — the binding is
   IP-only. Note: an adversarial source-review disputed that the JWT claims embed an IP
   (they don't — claims are `{challenge, method, policyRule, action}`); the binding is
   enforced behaviorally regardless (likely via the challenge-record path), and the
   empirical A/B is the load-bearing evidence.
2. **Traefik stamps `X-Real-Ip` with its immediate TCP peer** when the header is absent —
   and cloudflared doesn't send it. So for CF-tunneled traffic, X-Real-Ip = a cloudflared
   **pod IP**, not the client.
3. **Cloudflare edge round-robins requests across tunnel connections** of multiple
   cloudflared replicas (3 deployed; the two holding SOF-PoP connections observed). One
   page-load's asset requests alternate between pod IPs (verified live: 4 consecutive
   probes = `.214, .253, .214, .253`).

JWT minted under pod A's IP → every request routed via pod B fails validation →
challenge HTML to subresources (which silently fail; challenge JS can only run on
document navigations) + auth cookie cleared.

## Why it broke on ~2026-07-12 and not before

The defect was **latent since Anubis went live (2026-05-10)** — cloudflared has run 3
replicas since March. It didn't bite because a given user's requests happened to ride a
single tunnel connection → single cloudflared pod → stable X-Real-Ip (verified: a
2026-07-11 17:02 session solved one challenge and everything flowed via one pod IP).
The cloudflared config rollouts on 2026-07-12/13 (ADR-0020/0021 work — outage-failover
Worker, wildcard DNS) restarted the pods and reshuffled tunnel-connection→edge-PoP
distribution; after that, two pods both held connections to the client-nearest PoP and
requests interleaved. Nothing about the homepage stack itself changed — the affinity
luck ran out.

Explicitly ruled out during diagnosis: signing-key split-brain (Vault `anubis_ed25519_key`
identical across all KV versions since v59; JWT validated on both pods), shared-store
failure (challenge records present in Redis DB 9 with correct TTL; the one observed
`store: key not found` was a malformed hand-rolled test missing the `id` param),
CSP/rate-limit/x402 middlewares, the CF-Worker header, gethomepage's
`HOMEPAGE_ALLOWED_HOSTS`, and the scale-to-zero rollout.

## Fix

`traefik-drop-x-real-ip` Middleware (headers.customRequestHeaders `X-Real-Ip: ""` =
delete) + `strip_x_real_ip = true` in `ingress_factory`, set on all 7 Anubis-fronted
stacks. With the header absent, Anubis derives the client from `X-Forwarded-For` with
private hops stripped = the **real, stable** client IP. The exact post-fix state was
verified end-to-end against the live pods before rollout: with no X-Real-Ip header and
only a public XFF, the full challenge → solve → pass → proxied-request flow works (no
500s — cloudflared/Traefik always supply XFF), the challenge binds the XFF-derived
client, and the same cookie keeps passing across repeated requests. Cost: each existing
user re-solves one instant (difficulty-2) challenge as their cookie re-binds; users
whose public IP genuinely changes (mobile roaming) re-solve silently too — upstream's
intended semantics.

Not chosen: cloudflared → 1 replica (loses tunnel HA), a Traefik real-ip rewrite plugin
(bigger surface; the vendored-plugin pattern exists but a builtin middleware suffices),
Anubis version bump (validation semantics unverified).

## Follow-up regression — the strip 500s header-less requests (same day, caught by `/cluster-health`)

Applying `strip_x_real_ip` **uniformly to all 7 sites** was too broad and caused a
second incident surfaced hours later by `IngressErrorRate5xxHigh` + several Anubis
monitors flipping "down". Anubis's `check()` returns **HTTP 500
`[misconfiguration] X-Real-Ip header is not set`** when a request has *neither*
`X-Real-Ip` *nor* `X-Forwarded-For`. Real external users always carry XFF (CF/pfSense
set it) so they were unaffected — but the in-cluster **Uptime-Kuma probes** resolve
`*.viktorbarzin.me` to the internal Traefik LB (split-horizon DNS) and arrive with
neither header, so on the stripped sites they 500'd every cycle (~13/hr/site), driving
the alert.

A live A/B confirmed the flap IS real (valid cookie + changed X-Real-Ip → re-challenge),
so reverting the strip was not an option. Two-part fix:

1. **Non-proxied sites (f1, kms) never needed the strip** — their X-Real-Ip is the
   stable real client via pfSense PROXY-protocol (no cloudflared, no flap). Removed
   `strip_x_real_ip` there; that alone fixes those two sites' probe 500s.
2. **Proxied sites keep the strip** (flap is real). Their in-cluster Uptime-Kuma
   monitors now send a synthetic public `X-Forwarded-For` (`203.0.113.10`, TEST-NET-3,
   survives `XFF_STRIP_PRIVATE`) via the `external-monitor-sync` script
   (`ANUBIS_PROBE_HEADERS`, scoped to `anubis-*` backends), so the probe gets the 200
   challenge page instead of a 500 — restoring the pre-strip monitor behaviour.

Lesson: a header-mangling middleware's blast radius includes every *header-less*
client (health probes, in-cluster callers), not just the browser path you designed it
for. Scope proxy-header rewrites to the path that actually needs them.

## Lessons / follow-ups

- **Monitoring was structurally blind**: Uptime-Kuma probes the ingress and received the
  Anubis challenge page — HTTP 200, monitor green — for the entire outage. The Anubis
  metrics (`anubis_challenges_issued` vs `anubis_challenges_validated`,
  `anubis_proxied_requests_total`) are exported on `:9090` but not scraped.
  **Action (open):** scrape Anubis metrics + alert on a sustained
  validated/issued ratio ≈ 0 while issued > baseline; consider a keyword monitor
  asserting real page content (e.g. `id="anubis_challenge"` absence) on one
  Anubis-fronted site.
- **X-Real-Ip is untrustworthy platform-wide for CF-tunneled traffic** (it's a cloudflared
  pod IP). Anything keying on it — logs, per-IP logic — should use XFF/CF-Connecting-IP
  instead. The global Traefik rate-limiter keys on RemoteAddr (also the tunnel pod for CF
  traffic), which collapses all external users into ~3 buckets; pre-existing, not fixed
  here.
- **Proxy-hop identity + identity-bound tokens don't mix**: any auth layer that
  fingerprints "the client IP" must be fed the real client IP end-to-end, or the binding
  breaks the moment a hop scales past 1 replica. The failure needed a pod restart to
  detonate, days after the enabling conditions landed.

## Resolution (2026-07-19)

The stop-gap strip (`drop-x-real-ip` middleware + `strip_x_real_ip`) was **superseded and
retired** in favour of a peer-trust `real-ip` Traefik plugin
(`stacks/traefik/modules/traefik/real-ip-plugin/`). The plugin rewrites `X-Real-Ip` to the
true client, deciding trust by the **unspoofable TCP peer**: it honours `Cf-Connecting-Ip`
only when the peer is a cloudflared pod (`trustedProxyCIDRs = 10.10.0.0/16`) and otherwise
sets `X-Real-Ip` = the peer. This fixes the cookie flap on proxied sites AND removes the
header-less 500 on non-proxied ones (it only ever *sets* `X-Real-Ip`, never deletes it), and
it closes a spoofing hole the strip approach masked — `X-Real-Ip` is no longer
client-forgeable on any path (a raw `X-Real-Ip`, a forged `X-Forwarded-For`, or a forged
`Cf-Connecting-Ip` from a non-cloudflared peer are all ignored). Attached to all 7
Anubis sites via `extra_middlewares` (anubis-only, **not** the fleet default chain, to keep
the first Yaegi plugin off the ~33 non-Anubis routers). Design + rollout:
`docs/plans/2026-07-17-cluster-root-cause-fixes-design.md` (Fix 1). The monitoring
follow-up (scrape Anubis `:9090`, validated/issued ratio alert) remains open as Fix 2.
