# proxy

Per-user **persistent remote browsers**, each surfing from a country of your
choice through NordVPN. Log in at `proxy.viktorbarzin.me`, pick a country, and
get your own Chrome — streamed via **neko** (WebRTC: hardware-H.264 video on the
T4 plus Opus audio, with live resolution changes) — whose traffic egresses
from a NordVPN exit in that country. Your logins are saved in an encrypted
profile across visits. Chrome opens **maximised (windowed)**, so the address bar
and tabs are always reachable — never fullscreen-by-default.

Design + rationale: `docs/plans/2026-07-25-proxy-scale-design.md`
(scale-up) · `docs/plans/2026-07-24-proxy-nordvpn-design.md` (original).

## Architecture — shared per-country gateways + per-user browsers

```
user ─▶ proxy.viktorbarzin.me/ (Authentik login)  ─▶ proxy-broker (per-user API)
                                                        │ POST /api/browser {country}
                                                        ▼
                    per COUNTRY (shared, ≤ MAX_COUNTRIES-RESERVED = 6 concurrent):
                      Pod  proxy-gw-<i>   [ gluetun(NordVPN,country) + wg-server ]
                      Svc  proxy-gw-<i>   (ClusterIP :51820/UDP — stable WG endpoint)
                      CM   proxy-gw-<i>-peers   (broker-maintained; sidecar reconciles wg0)

                    per USER (persistent):
                      PVC  proxy-profile-<user>  (encrypted, RWO — the Chromium profile)
                      Pod  proxy-br-<user>   [ gluetun(custom-WG → gateway) + neko+Chromium ]
                      Svc/Ing  proxy-br-<user>   proxy-<token>.viktorbarzin.me (auth=none, token-gated)
user ─▶ proxy-<token>.viktorbarzin.me ─▶ neko UI + WS signaling (HTTP)
user ◀▶ turn.viktorbarzin.me (coturn relay) ◀▶ neko WebRTC media (H.264 + Opus)
```

The **NordVPN ~10-tunnel account cap therefore limits concurrent COUNTRIES**
(`pool.MAX_COUNTRIES - RESERVED_SLOTS`, default 8-2=6), **not users** — many
browsers share one country's single tunnel. Proven end-to-end by Spike G
(memory #10214): a browser pod egresses NordVPN with no home-IP leak.

- **Broker** (`files/broker/`, pure-stdlib `python:3.12-slim`, ConfigMap-mounted —
  no custom image/GHA). `broker.py` serves the UI + JSON API and orchestrates
  gateways + browsers; `pool.py` (gateway-pool decisions) and `wgkeys.py`
  (X25519 WireGuard keygen) are pure + **unit-tested** (`*_test.py`, 27 tests).
- **Gateway pod** = `gluetun` (NordVPN WireGuard) + a `wg-server` sidecar
  (linuxserver/wireguard) that, once `tun0` is up, brings up `wg0`, adds the
  forwarding rules (`ip_forward` via pod `securityContext.sysctls` + MASQUERADE
  + FORWARD-accept + the gluetun return-path `ip rule ... lookup main pref 90`)
  and **reconciles peers** from the mounted `proxy-gw-<i>-peers` ConfigMap every
  10s (survives restarts, no `kubectl exec`). Pinned to `node2-5` (the workers
  where `net.ipv4.ip_forward` is kubelet-allowed) via the
  `proxy.viktorbarzin.me/gateway=true` node label.
- **Browser pod** = `gluetun` in **custom-WireGuard** mode dialling its country
  gateway's Service ClusterIP (leak-proof: gluetun's kill-switch) + a single
  **neko** container (upstream `ghcr.io/m1k1o/neko/nvidia-chromium`,
  DIGEST-pinned via `NEKO_IMAGE` in `main.tf`) serving its UI + signaling
  WebSocket on HTTP `:8080`. neko v3 streams **hardware H.264** (NVENC on the T4,
  `nvh264enc` at 8 Mbps) plus **Opus audio** over WebRTC, at
  `NEKO_SCREEN=2560x1440@30` by default — an admin can change the resolution live
  from the UI. GPU scheduling: `nvidia.com/gpu=1` + a `viktorbarzin.me/gpumem`
  slot (`GPUMEM_MIB`, ~384) pins the pod to node1, and `GPU_BROWSERS_MAX` caps
  concurrent GPU browsers (1 today — the T4 budget is full). An `xorg-glx-fix`
  initContainer disables GLX in the stock image's `xorg.conf`; the GPU is needed
  for encode, not render.

  **Media relays through coturn** (`10.0.20.200` in-cluster for neko's own
  allocation, `turn.viktorbarzin.me` + STUN for the viewer's browser), with
  ephemeral TURN-REST credentials minted per browser by the broker from Vault
  `secret/coturn`. WebRTC media is not HTTP, so it cannot ride the shared Traefik
  `:443` — the relay is what makes a per-user browser reachable from anywhere.

  Each browser still gets its **own subdomain** `proxy-<token>.viktorbarzin.me`,
  which keeps neko's signaling WebSocket and assets at their own root; the token
  doubles as neko's admin password, so `?usr=proxy&pwd=<token>` auto-logs in.
  Chromium is neko's single app under openbox; the profile persists on the PVC.
  One per user, keyed on the `X-authentik-username` identity header.

  This replaced KasmVNC (which itself replaced noVNC) in infra#81: KasmVNC 1.3.3
  has no H.264/WebCodecs support and its Xvnc build carries no audio path at all,
  so video topped out around 13-17 fps of WebP tiles and audio was not reachable
  over the HTTP-only ingress. `files/kasmvnc/` remains in the tree as the
  previous generation.

## Auth

`auth = "required"` — Authentik forward-auth gates the UI + API; each user's
browser + encrypted profile keys on their identity. The per-user
`proxy-<token>.viktorbarzin.me` ingress stays `auth = "none"` — the unguessable
per-user token (`HMAC(salt, userkey)`) is the gate, and it is also neko's admin
password. (The carve-out dates from KasmVNC, whose WebSocket forward-auth broke;
it has not been retested against neko's `/ws`.)

## Guardrails

- **Concurrency**: gateways capped at `MAX_COUNTRIES - RESERVED_SLOTS` (`pool.py`),
  one gateway per distinct country (same NordLynx key on two tunnels to the same
  country flaps); browsers are one-per-user. `RESERVED_SLOTS=2` keeps NordVPN
  tunnels free for Viktor's own devices.
- **Persistence**: profiles are encrypted PVCs (`proxmox-lvm-encrypted`), no
  backup — a rare loss = re-login. Deleting a browser KEEPS its profile.
- **Reaping**: an idle gateway (no browsers for `GW_IDLE_SECONDS=600`) is reaped,
  freeing its tunnel slot; the reaper also re-asserts peers each cycle.
- Least-privilege: session pods run UNPRIVILEGED (`NET_ADMIN`+`SYS_MODULE`, no
  `/dev/net/tun`/privileged). The one posture addition is the opt-in
  `net.ipv4.ip_forward` unsafe-sysctl on node2-5 (infra#81; contained to the
  pod netns). ns on `ghcr_private_namespaces` (kyverno) for the
  private image pull (the neko image itself is public).

## Operate

- Health/metrics: `proxy-broker` `/healthz`, `/metrics` (`proxy_gateways_active`,
  `proxy_browsers_active`, `proxy_max_countries`).
- List: `kubectl get pods -n proxy -l 'app in (proxy-gateway,proxy-browser)'`.
- Run the broker tests: `cd files/broker && python3 -m unittest pool_test wgkeys_test`.
- NordVPN token rotates the NordLynx key account-wide; the broker re-fetches per
  gateway spawn (token in Vault `secret/proxy`).

## Deferred (see the design doc)

- **Phase 3 — Headscale exit nodes**: `tailscale --advertise-exit-node` on the
  gateways so tailnet users route their own traffic through NordVPN (same
  forwarding primitive; unblocked by Spike G).
- **WebRTC display — DONE** (neko, infra#81): hardware H.264 over a coturn relay,
  see "Browser pod" above. Two follow-ups it left open: the TURN credential is
  minted at browser-creation time with a 30-day TTL and neko's env is static, so a
  browser outliving the TTL needs a recreate to re-mint (reaper-driven in-place
  rotation is unbuilt); and `GPU_BROWSERS_MAX=1` until the `gpumem` budget frees
  up (ADR-0016), so a second concurrent GPU browser is rejected up-front.
- Social self-signup for non-admins is handled by the Authentik enrollment flow
  (separate work in `stacks/authentik`).
