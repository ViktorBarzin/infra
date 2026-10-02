# terminal-api: Terminal Lobby's public machine API

`https://terminal-api.viktorbarzin.me` exposes Terminal Lobby's HTTP APIs to programs on the
internet that cannot use a VPN or a browser login. The first caller is Meta Muse, which runs in
Meta's cloud. The browser host `terminal.viktorbarzin.me` is separate and unchanged.

- Config: `stacks/terminal/terminal_api.tf`, plus `playbooks/devvm.yml` (agent-api bind, nftables)
- Ban scenario: `viktor/terminal-api-auth-bf` in `stacks/crowdsec`
- Alerts: `TerminalApiAuthFailure`, `TerminalApiBlockedSurge` (Slack #alerts, security lane)

## How a request is checked

```mermaid
flowchart TD
  C["client"] --> E["TP-Link, pfSense rdr (IPv4) or HAProxy PROXY v2 (IPv6)"]
  E --> B["Traefik websecure: CrowdSec bouncer"]
  B --> A["ipAllowList: only listed source addresses"]
  A --> H["identity headers removed, no proxy secret added"]
  H --> R["per-client rate limit 5/s burst 20, 10 concurrent"]
  R --> L["Lobby service: bearer token, sha256 digest, constant-time"]
```

A valid bearer token is the only credential. The host deliberately sends no `X-TL-Proxy-Secret`
and strips `X-Authentik-Username`, `X-Forwarded-User` and `X-TL-Proxy-Secret` from requests, so
the Lobby header login path cannot succeed here. Never add the `tl-proxy-secret` middleware to
these routes: with it, a forged identity header would be accepted as that user.

A token acts as the OS user its entry maps to. `muse` maps to `wizard`, which has sudo, a
cluster-admin kubeconfig and a Vault token on the devvm (Viktor's decision, 2026-10-02).

## What is exposed

| Path | Backend | Notes |
|---|---|---|
| `/v1/*` | agent-api `10.0.10.10:8710` | conversations, messages, transcripts, tasks |
| `/api/sessions/*` | tmux-api `:7684` (prefix stripped) | except `/metrics`, `/health`, `/push*`, `/internal/*`, which need no login |
| `/events/` `/prompt/` `/cancel/` `/earlier/` `/result/` `/pane/` `/keys/` `/commands/` `/search/` `/answer-text/` `/answer/` `/model/` | session-events `:7685` | `/keys/` and `/pane/` type into tmux panes |
| `/files/*` | file-api `:7686` | |
| `/skills`, `/skills/*` | skills-api `:7688` | |

Not exposed: ttyd (`/`, `/ws`, `/token`, an interactive shell), clipboard-upload (it parses the
upload body before checking auth), static assets, build stamps, agent-api `/health` and
`/openapi.json`. Unmatched paths get Traefik's catch-all error page.

## Calling it

```sh
curl -H "Authorization: Bearer $TOKEN" https://terminal-api.viktorbarzin.me/v1/conversations
curl -H "Authorization: Bearer $TOKEN" https://terminal-api.viktorbarzin.me/api/sessions/whoami
```

Muse's token: `vault kv get -field=agent_api_muse_token secret/terminal-lobby`.

## Source addresses

`local.api_allowed_sources` in `stacks/terminal/terminal_api.tf` lists who reaches the token check
at all: Cloudflare WARP's IPv6 block `2a09:bac0::/29` and mx2 (`92.5.132.215`, for testing).

Muse egresses through Cloudflare WARP, a shared range used by everyone running the free WARP app,
and its address changes on nearly every request. So the allowlist filters out non-WARP traffic but
cannot single Muse out, and the per-address defences (the 401 ban, the rate limit) cannot stop a
caller who also rotates through WARP. The bearer token, about 288 bits, is what identifies Muse.

To add a source, edit the list and apply the terminal stack. An address in Meta's space would also
hit CrowdSec's static Meta ban (`meta-asn.txt` in `stacks/crowdsec/modules/crowdsec/main.tf`) and
needs carving out there too. Muse's WARP addresses are not in that list.

## Add, rotate or revoke a caller

Callers are `devvm_external_agents` in `playbooks/devvm.yml`; each token is Vault
`secret/terminal-lobby` field `agent_api_<name>_token`.

- Add: add the entry, write a token of at least 32 random URL-safe characters to Vault, run the
  playbook. Give the token to the caller out of band.
- Rotate: write a new token to Vault and run the playbook. The old token stops working when the
  tokens file is rewritten.
- Revoke now: remove the entry (or `scripts/agent-api-kill <name>`) and run the playbook.
- If the token may have leaked: revoke first, then check `homelab logs query '{namespace="traefik"} |= "terminal-api"' --since 24h`
  and the agent-api trace in Loki for what it was used for.

## When the alerts fire

| Alert | Meaning | First checks |
|---|---|---|
| `TerminalApiAuthFailure` | an allowlisted address sent a wrong or stale token | Was the token rotated without updating the caller? Source address and path in the Traefik access log |
| `TerminalApiBlockedSurge` | sustained 403s: the allowlist or CrowdSec is refusing someone in volume | Sources in the access log; `cscli decisions list` in the crowdsec LAPI pod |

A caller that sends 5 bad tokens within about a minute is banned by CrowdSec for the default
duration. To lift a ban on a legitimate caller:
`kubectl -n crowdsec exec deploy/crowdsec-lapi -- cscli decisions delete --ip <addr>`.

## Defence in depth around the devvm ports

- devvm nftables: `7681` and `8710` accept only the Traefik node addresses and loopback; the
  Lobby ports are dropped on IPv6.
- AdminNetworkPolicy `devvm-lobby-ports` (priority 10): no namespace except `traefik` may reach
  `10.0.10.10` on 7681, 7683-7688 or 8710. `devvm-lobby-ports-observers` (priority 11) lets
  `monitoring` reach only 7684 (tmux-api metrics) and `headscale` only 7681 (subnet-router probe).
  Needed because Calico SNATs pod egress to the node address, which the nftables rules admit.
