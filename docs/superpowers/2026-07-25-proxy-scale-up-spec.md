# Spec: proxy scale-up — per-user persistent browsers, shared per-country NordVPN gateway, VPN-chaining

> Design: `docs/plans/2026-07-25-proxy-scale-design.md`
> (published at plans.viktorbarzin.me/2026-07-25-proxy-scale-design.html).
> Builds on the shipped ephemeral browser: `docs/plans/2026-07-24-proxy-nordvpn-design.md`.
> Adversarially reviewed against live infra; two load-bearing decisions were reversed
> (SOCKS5 egress → shared L3 gateway) or gated (Selkies → coturn spike).

## Problem Statement

Today `proxy.viktorbarzin.me` is a single, **public, ephemeral** remote browser: anyone
who opens it picks a country and gets a throwaway Chromium tunnelled through NordVPN that
vanishes after 60 minutes. For the small trusted circle Viktor wants to share it with,
that is too coarse in four ways:

- **No accounts.** There is no per-person identity, so no persistent state, no scoping,
  and no audit of who did what. The one way in — social signup — is currently **broken**
  (the invitation token doesn't survive the Google OAuth round-trip, so enrollment
  denies).
- **Nothing persists.** A user's logins, tabs, and cookies are gone on the next visit,
  because every session is ephemeral.
- **No leak-proof way to pack more than a handful of users onto NordVPN.** NordVPN allows
  only ~10 concurrent tunnels; the obvious "point the browser at a SOCKS5 proxy" approach
  **leaks the home IP** (Chromium sends QUIC/WebRTC/UDP outside any SOCKS5 tunnel).
- **VPN users can't chain through NordVPN.** People already on Viktor's Headscale tailnet
  have no way to send *their own device's* traffic out through a NordVPN country.

## Solution

Grow proxy into a small multi-user product for **~5–20 trusted accounts**:

- **Accounts.** Fix social-only signup and add **passkey (WebAuthn) enrollment**; re-gate
  the whole service behind login (`auth = "required"`). Per-user identity comes from the
  Authentik forward-auth headers the broker already sits behind.
- **Own persistent browser.** Each user gets their own multi-tab Chromium with an
  **encrypted per-user profile** that survives across visits. The pod is on-demand (wakes
  on visit, reaps when idle); the profile is durable.
- **Leak-proof, tunnel-efficient egress.** The browser joins a **shared per-country
  gateway** at the network layer (WireGuard into a gluetun pod), never via an app-level
  proxy. gluetun's kill-switch makes leaks kernel-impossible, and many browsers share one
  country's single NordVPN tunnel — so the ~10-tunnel budget caps **concurrent countries
  (~8 after reserve)**, not users.
- **VPN-chaining on the same primitive.** A Headscale **exit node** is just
  `tailscale --advertise-exit-node` co-located in that same per-country gateway
  (`tag:infra` → route auto-approved). Tailnet users select a country exit and egress
  through the shared NordVPN tunnel — no extra tunnel consumed.

## User Stories

1. As a trusted user, I want to sign up with my Google account, so that I can get access without Viktor hand-creating an account for me.
2. As a trusted user whose social signup currently fails, I want the invite → Google → account flow to actually complete, so that I stop hitting a dead end after the OAuth redirect.
3. As a trusted user, I want to enroll a passkey during signup, so that I have a second, password-less way in that isn't tied to a social provider.
4. As a returning user, I want to log in with my passkey, so that I don't depend on a social provider being reachable.
5. As a signed-up proxy user, I want to reach only the proxy service and nothing else behind Authentik, so that my account can't wander into admin surfaces.
6. As Viktor, I want the whole proxy service gated behind login again, so that it is no longer an open, internet-reachable remote browser on my NordVPN account.
7. As Viktor, I want each account scoped by the existing `Proxy Users` group / `proxy_only` attribute, so that I reuse the access model already built rather than inventing a new one.
8. As a user, I want my own browser rather than a shared one, so that my tabs, logins, and history are mine and isolated from other users.
9. As a user, I want multiple tabs in my browser, so that I can work across several pages at once.
10. As a user, I want my browser profile to persist across visits, so that I stay logged into sites and keep my session between days.
11. As a user, I want to pick my exit country when I launch my browser, so that I control where my traffic appears to come from.
12. As a user, I want to relaunch to switch country, so that the model stays simple and my profile follows me.
13. As a user, I want my profile stored encrypted, so that my browsing state isn't sitting in plaintext on shared storage.
14. As a user, I want my browser to wake when I visit and sleep when I'm idle, so that it's there when I need it without running 24/7.
15. As a user, I want my real (home) IP to never leak — not via DNS, WebRTC, QUIC, or IPv6 — so that the service actually hides my origin as promised.
16. As a user, I want my browsing to fail closed if the tunnel drops, so that a tunnel blip exposes nothing rather than silently leaking.
17. As a user, I want the remote browser to feel responsive, so that interacting with it isn't painful — via Selkies/WebRTC if the TURN path proves out, otherwise tuned noVNC.
18. As Viktor, I want many users on a popular country (US/UK) to share one NordVPN tunnel, so that a handful of countries can serve the whole circle within the ~10-tunnel cap.
19. As Viktor, I want 1–2 tunnel slots always reserved, so that my own phone/laptop on NordVPN never gets locked out by the service.
20. As Viktor, I want the service to respect NordVPN's ~10-min cooldown on over-limit connections, so that churn doesn't freeze a country for ten minutes.
21. As Viktor, I want long-lived gateway tunnels to survive NordVPN key rotation, so that one NordVPN app login elsewhere doesn't silently kill every live country tunnel.
22. As a Headscale user, I want to select a per-country exit node, so that my own device's traffic egresses through NordVPN in that country.
23. As a Headscale user, I want the exit route to be approved automatically, so that I don't wait on a manual approval step.
24. As Viktor, I want a tailnet exit node to reuse the same per-country gateway a browser uses, so that VPN-chaining consumes no extra NordVPN tunnel.
25. As Viktor, I want the privilege posture of the forwarding gateway surfaced explicitly, so that if it needs a Kyverno/node change I decide that consciously rather than discovering it in a diff.
26. As Viktor, I want the whole thing to stay on the free NordVPN subscription and existing cluster, so that no new monetary cost is incurred.
27. As an operator, I want to see how many country gateways and user browsers are live, so that I can reason about where the tunnel budget is going.
28. As an operator, I want idle browsers and unused country gateways reaped, so that cluster RAM and tunnel slots aren't held by absent users.
29. As a future maintainer, I want the broker's pool logic unit-tested, so that changes to cap/reserve/rotation behaviour don't silently regress.

## Implementation Decisions

**Ownership & delivery.** All changes are Terraform in the existing `proxy` stack (plus
Authentik, Headscale, coturn, and — only if a spike forces it — Kyverno/node config),
applied via CI on push. The broker stays a pure-stdlib Python app mounted from a
ConfigMap; its decision logic is **extracted from the heredoc into a real module** so it
can be unit-tested (the `watchdog.py`/`watchdog_test.py` split from infra#80 is the
precedent).

**The per-country forwarding gateway (the core primitive — make-or-break).** A pod
running `gluetun` (NordVPN WireGuard for one country, kill-switch on) **plus** a WireGuard
server (browser side) and/or `tailscale --advertise-exit-node` (tailnet side), with
`net.ipv4.ip_forward=1` + a MASQUERADE rule on `tun0` + a FORWARD-accept rule +
`FIREWALL_OUTBOUND_SUBNETS` covering the client subnet(s). It holds the **single** NordVPN
tunnel for its country and forwards clients' traffic out through it. One gateway per
distinct country; the broker never runs two tunnels for the same country (same-key
same-server flap). The known risk: gluetun's kill-switch drops *forwarded* (FORWARD-chain)
traffic unless the forward/MASQUERADE/`ip_forward` rules are present — this is proven or
disproven by **Spike G before anything is built on it**. `ip_forward` is namespaced; the
spike determines whether a runtime `sysctl -w` under the current unprivileged `NET_ADMIN`
posture suffices, or whether it needs a kubelet `--allowed-unsafe-sysctls` entry + a
Kyverno security-exclude for the `proxy` namespace — the latter is a posture change to be
surfaced to Viktor, not applied silently.

**Browser pod.** Per user, on-demand, netns-shared: `gluetun` in **custom-WireGuard mode
pointing at its country's gateway** (kill-switch on) + a Selkies/noVNC Chromium. Page
egress goes browser → WG → gateway → NordVPN; the browser's own `eth0`/home path is never
a page-egress route (kill-switch drops non-tunnel egress). DNS uses the shipped
`dnsPolicy: None` → `127.0.0.1` (gluetun resolver) pattern. Every hop fails closed. This
**replaces** the disproven SOCKS5-consumption model (Chromium has no SOCKS5 UDP ASSOCIATE
→ QUIC/WebRTC/UDP leak the home IP).

**Persistent profile.** One encrypted PVC per user (`proxmox-lvm-encrypted`), mounted as
the Chromium profile dir, no backup (rare loss = re-login). Keyed by the user's Authentik
identity.

**Display.** Selkies + WebRTC through the existing `coturn` if **Spike A** proves coturn's
public TURN path reachable (it currently resolves NXDOMAIN and has never been exercised);
otherwise the shipped **tuned noVNC** (proven, leak-safe) is the fallback. Either way the
display path is allow-listed out `eth0` to coturn so it isn't dropped by the kill-switch,
while page egress stays on the tunnel. coturn's `use-auth-secret`/`static-auth-secret`
already matches Selkies' `SELKIES_TURN_HOST/SECRET` (no second TURN server needed).

**Broker extension.** New responsibilities layered onto the shipped broker: per-user
identity from the forward-auth header; a **country-gateway pool** (create/reuse/reap one
gateway per active country, enforce the concurrent-country cap with 1–2 reserved slots,
respect the cooldown on eviction); a **NordVPN key-rotation watchdog** that re-fetches the
NordLynx key and rolls long-lived gateway tunnels; and a per-user ↔ PVC ↔ browser-pod ↔
country-gateway mapping with idle reaping. The API grows from "create a session" to
"attach this user to their persistent browser on country X, wiring it to X's gateway".

**Auth.** Fix social signup by making the invitation context survive the OAuth round-trip
(or moving the invite check into the source's own enrollment flow — chosen after a live
repro in Spike D), plus a username-derivation guarantee on `user_write`. Add a WebAuthn
authenticator **setup** stage after a username-yielding `user_write`, cloned to
`resident_key = required` + `user_verification = required` (the stock stage is
`preferred`); separately wire the **login** flow's Identification → WebAuthn-validation so
an enrolled passkey is actually usable to log in. Re-gate the proxy ingress to
`auth = "required"`; keep the `Proxy Users` group + `proxy_only` attribute scoping.

**VPN-chaining.** Add `tailscale --advertise-exit-node` (tagged `tag:infra`, so the
existing `autoApprovers` in `headscale_acl` auto-approves the `0.0.0.0/0` route) to the
per-country gateway. Use `headscale nodes approve-routes`/`list-routes` (the `routes` CLI
was removed in Headscale 0.28).

**Phasing (each phase spike-gated).** P1 Auth (Spike D + passkey + re-gate). P2 Per-user
browser over shared gateways (Spike G + A + B). P3 Headscale exit nodes on the gateways.

## Testing Decisions

**What a good test is here:** exercise external behaviour, not internals. For the broker
that means feeding the pool logic a sequence of user attach/detach/idle/rotate events and
asserting the *decisions* it emits (which gateway to reuse vs create, when the
concurrent-country cap or reserved-slot rule blocks/evicts, when a key roll is triggered,
which PVC/gateway a user maps to, when a browser or gateway is reaped) — never asserting
on Kubernetes object shapes or private helpers.

**What gets unit-tested:** the extracted broker pool module, with stdlib `unittest`. Prior
art: `stacks/nvidia/.../watchdog_test.py` (infra#80) — logic pulled out of a TF heredoc
into a real file with a parameterised test. Prefer table-driven cases over the cap /
reserve / one-gateway-per-country / rotation invariants.

**What is verified by live spike, not unit test** (infra norm; Terraform/config are
test-exempt per the engineering rules):
- **Spike G** — gateway forwarding: from a WG client pod and a second tailnet node,
  `curl` an IP-echo and confirm the **NordVPN country IP with no home-IP leak**; record
  the `ip_forward` privilege verdict.
- **Spike A** — coturn: a real TURN allocation from off-LAN against `turn.viktorbarzin.me`.
- **Spike B** — browser leak-safety: with the browser pod live, confirm curl / DNS /
  WebRTC / QUIC / IPv6 all show the NordVPN IP or are dropped (nothing shows the home IP),
  and the display works.
- **Spike D** — Authentik: a real Google signup driven through Playwright completes an
  account, watched against the flow-execution + `goauthentik-server` logs.

## Out of Scope

- A user-facing per-country **SOCKS5/Shadowsocks** endpoint (Viktor deferred it).
- Profile **backup / DR** — encrypted, no-backup by explicit choice.
- **Warm pool / pre-provisioning** of browsers or gateways.
- Switching VPN providers (Mullvad/Proton stable `.conf` would remove the key-rotation
  and cap fragility but is new spend).
- Anything that raises the NordVPN plan or adds monetary cost.
- Reconciling the divergence in NordVPN's per-key vs per-tunnel device counting beyond
  the conservative "assume per-tunnel, cap at ~8 countries" guardrail.

## Further Notes

- **Spike order matters:** Spike G is the make-or-break and runs first; if it needs a
  Kyverno/node posture change, that decision goes back to Viktor before P2 proceeds.
- The gateway unifies decisions #2 (shared browser tunnel) and #6 (Headscale exit node) —
  build it once.
- Relevant memories: #10198 (gluetun FORWARD-chain gateway), #10199 (Chromium SOCKS5
  leak), #10200 (coturn TURN unreachable today), #10201 (social-signup root cause), #10202
  (passkey enrollment caveats), #10203 (Headscale 0.28 tag:infra auto-approval), #10204
  (shared-gateway decision), #10182 (NordVPN ~10-tunnel cap + cooldown).
