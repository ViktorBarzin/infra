# geo-browser

On-demand, per-country **remote browser** tunnelled through NordVPN. Open
`geo.viktorbarzin.me` (Authentik-gated), pick a country, and get a full Chromium
in the browser (noVNC) whose traffic egresses from a NordVPN exit in that
country. Sessions are ephemeral and auto-close after 60 minutes.

Design + rationale: `docs/plans/2026-07-24-geo-browser-nordvpn-design.md`.

## How it works

```
user ──▶ geo.viktorbarzin.me/ (Authentik)  ──▶ geo-broker (country picker + API)
                                                   │  POST /api/session {country}
                                                   ▼
                                   creates, per session:
                                     Pod  geo-<token>  [ gluetun(WG,country) + chromium + noVNC ]
                                     Svc  geo-<token>  → :6080
                                     Ing  geo-<token>  /s/<token>  (auth=none, stripPrefixRegex)
user ──▶ geo.viktorbarzin.me/s/<token>/vnc.html ──▶ noVNC view of the in-country browser
```

- **Broker** (`files/broker/broker.py`, pure-stdlib on a stock `python:3.12-slim`
  image, ConfigMap-mounted — no custom image/GHA, the chrome-broker pattern):
  serves the UI + JSON API, creates/reaps session objects via the apiserver, and
  re-fetches the NordLynx key from NordVPN's API (via the account token in Vault
  `secret/geo-browser`) into the `geo-nord-wg` Secret at each spawn.
- **Session pod** — three containers sharing ONE netns so the browser egresses
  through the tunnel: `gluetun` (NordVPN **WireGuard**, kernelspace, UNPRIVILEGED
  with `NET_ADMIN`+`SYS_MODULE`, kill-switch, `FIREWALL_INPUT_PORTS=6080` so
  Traefik can reach noVNC, `FIREWALL_OUTBOUND_SUBNETS` for cluster replies) +
  `chrome-service-browser` (headful Chromium under Xvfb, `--no-sandbox`) +
  `chrome-service-novnc` (x11vnc + websockify on :6080). `dnsPolicy: None` +
  `dnsConfig 127.0.0.1` routes DNS through gluetun's resolver (no leak).
- **noVNC routing**: each session gets a `/s/<token>` Ingress (auth=none — an
  Authentik forward-auth would break the WebSocket) referencing a single static
  `stripPrefixRegex` middleware; the unguessable 128-bit token IS the gate.

## Guardrails

- **Concurrency ceiling 4** (`MAX_SESSIONS`) — a self-imposed cluster-resource
  limit, well under NordVPN's ~10-connection cap; the oldest is evicted when a
  5th is requested.
- **Hard deadline 60 min** (`activeDeadlineSeconds`); the reaper cleans up the
  Pod+Service+Ingress trio for finished/expired sessions.
- Least-privilege: NO privileged pods, NO `/dev/net/tun`, NO Kyverno security
  exclude — full pod-security enforcement retained. The namespace is only on
  `ghcr_private_namespaces` (stacks/kyverno) for the private
  `chrome-service-browser` pull.

## Operate

- Health/metrics: `geo-broker` `/healthz`, `/metrics` (`geo_sessions_active`).
- List/kill sessions: the UI, or `kubectl get pods -n geo-browser -l app=geo-session`.
- NordVPN token rotates the NordLynx key account-wide; the broker re-fetches per
  spawn, so no manual key handling. Token lives in Vault `secret/geo-browser`.
- gluetun image is `ghcr.io/qdm12/gluetun` — pin it if the `:latest`
  OpenVPN-2.6.20 `handshake-window` bug (gluetun #3306) ever affects the WG path.

## Deferred (see the design doc)

Public SOCKS5/Shadowsocks proxy surface, subscription-URL integration,
persistent per-user profiles, warm pool, programmatic egress-country verify.
