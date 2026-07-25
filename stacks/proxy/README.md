# proxy

Per-user **persistent remote browsers**, each surfing from a country of your
choice through NordVPN. Log in at `proxy.viktorbarzin.me`, pick a country, and
get your own Chrome — streamed via **KasmVNC** with audio, adjustable resolution,
and smooth FullHD video — whose traffic egresses from a NordVPN exit in that
country. Your logins and tabs are saved in an encrypted profile across visits.

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
                      Pod  proxy-br-<user>   [ gluetun(custom-WG → gateway) + KasmVNC+Chrome ]
                      Svc/Ing  proxy-br-<user>   /s/<token> (auth=none, token-gated)
user ─▶ proxy.viktorbarzin.me/s/<token>/ ─▶ KasmVNC view (audio + resolution + FullHD)
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
  **KasmVNC + Chrome** container (`files/kasmvnc/`, image
  `ghcr.io/viktorbarzin/proxy-kasmvnc-browser`, built on GHA) serving HTTP on
  :6080. KasmVNC gives **audio** (PulseAudio → browser), **client-driven dynamic
  resolution**, and **FullHD H.264/WebCodecs video** — all over the WebSocket
  ingress, no coturn/TURN. Chrome is the single autostart app; the profile
  persists on the PVC at `/config`. One per user, keyed on the
  `X-authentik-username` identity header.

## Auth

`auth = "required"` — Authentik forward-auth gates the UI + API; each user's
browser + encrypted profile keys on their identity. The per-user `/s/<token>`
ingress stays `auth = "none"` (an Authentik forward-auth breaks the KasmVNC
WebSocket) — the unguessable per-user token (`HMAC(salt, userkey)`) is the gate.

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
  `proxy-kasmvnc-browser` image pull.

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
- **Selkies/WebRTC display** (only marginally smoother than KasmVNC's WebSocket
  H.264 on very fast motion): would need coturn's public TURN path reachable — a
  pfSense NAT + DNS record (Spike A: currently NXDOMAIN). KasmVNC already delivers
  audio + resolution + FullHD without it, so this is optional.
- Social self-signup for non-admins is handled by the Authentik enrollment flow
  (separate work in `stacks/authentik`).
