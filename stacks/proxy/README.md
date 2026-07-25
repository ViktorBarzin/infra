# proxy

On-demand, per-country **remote browser** tunnelled through NordVPN. Open
`proxy.viktorbarzin.me`, pick a country, and get a full Chromium in the browser
(noVNC) whose traffic egresses from a NordVPN exit in that country. Sessions are
ephemeral and auto-close after 60 minutes.

> **Auth: currently PUBLIC (`auth = "none"`, Viktor 2026-07-25).** The UI is
> open with no login — an internet-reachable remote browser egressing via the
> NordVPN account (broker still caps at `MAX_SESSIONS=4`). Re-gate by setting the
> ingress `auth = "required"` in `main.tf`. The `Proxy Users` group / `proxy_only`
> policy / social invite (`stacks/authentik/proxy-enrollment.tf`) stay in place
> but dormant while ungated.

Design + rationale: `docs/plans/2026-07-24-proxy-nordvpn-design.md`.

## How it works

```
user ──▶ proxy.viktorbarzin.me/ (Authentik)  ──▶ proxy-broker (country picker + API)
                                                   │  POST /api/session {country}
                                                   ▼
                                   creates, per session:
                                     Pod  proxy-<token>  [ gluetun(WG,country) + chromium + noVNC ]
                                     Svc  proxy-<token>  → :6080
                                     Ing  proxy-<token>  /s/<token>  (auth=none, stripPrefixRegex)
user ──▶ proxy.viktorbarzin.me/s/<token>/vnc.html ──▶ noVNC view of the in-country browser
```

- **Broker** (`files/broker/broker.py`, pure-stdlib on a stock `python:3.12-slim`
  image, ConfigMap-mounted — no custom image/GHA, the chrome-broker pattern):
  serves the UI + JSON API, creates/reaps session objects via the apiserver, and
  re-fetches the NordLynx key from NordVPN's API (via the account token in Vault
  `secret/proxy`) into the `nordvpn-wg` Secret at each spawn.
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

- Health/metrics: `proxy-broker` `/healthz`, `/metrics` (`proxy_sessions_active`).
- List/kill sessions: the UI, or `kubectl get pods -n proxy -l app=proxy-session`.
- NordVPN token rotates the NordLynx key account-wide; the broker re-fetches per
  spawn, so no manual key handling. Token lives in Vault `secret/proxy`.
- gluetun image is `ghcr.io/qdm12/gluetun` — pin it if the `:latest`
  OpenVPN-2.6.20 `handshake-window` bug (gluetun #3306) ever affects the WG path.

## Deferred (see the design doc)

Public SOCKS5/Shadowsocks proxy surface, subscription-URL integration,
persistent per-user profiles, warm pool, programmatic egress-country verify.
