# Break-glass SSH — Redesign

- **Date**: 2026-06-11
- **Status**: Implemented
- **Owner**: Viktor
- **Supersedes**: `2026-05-30-breakglass-ssh-access-{design,plan}.md` (port-knock design)
- **As-built runbook**: `docs/runbooks/breakglass-ssh.md`

## Why redesign

The 2026-05-30 design gated a key-only SSH port on the Proxmox host behind a UDP
**port-knock** (knockd). It caused a real lockout, for a structural reason:

- The knock sequence was 3 random ports stored **only** in Vault, and the client
  helper fetched it from Vault at connect time.
- **Vault is in-cluster** and not publicly reachable (Wave-1 policy). In the
  exact scenario break-glass exists for — away from home, cluster/tunnels down —
  the knock sequence is unreachable and unmemorable. Circular dependency.

The knock's only benefit was hiding an already brute-force-proof port; its cost
was that fragility. For a *recovery* path, robustness beats stealth.

## Decision

**Plain key-only SSH to the Proxmox host on `:52222`, openly reachable, no knock.**
Hardened with: the exposed port trusts only a dedicated break-glass key
(`Match LocalPort`), per-source connection rate-limiting (iptables hashlimit),
and fail2ban. Scenario covered: *cluster + tunnels down, host + pfSense + router
up* (the common "I'm away and need in" case — confirmed with Viktor; deeper
"pfSense wedged" / "host down" tiers are explicitly out of scope).

Alternatives considered and rejected: keeping the knock (fragile, circular);
Tailscale-on-pfSense (briefly chosen, then dropped — reintroduces the upstream
dependency Headscale is self-hosted to avoid, and the user preferred a
self-contained stock-ssh path); WireGuard road-warrior (needs a client, and the
self-contained SSH path was preferred).

## Components

| Layer | Change | Source of truth |
|---|---|---|
| sshd | dual-port `:22` (LAN, all keys) + `:52222` (WAN, break-glass key only via `Match LocalPort`, terminated by `Match all`); key-only everywhere | `scripts/sshd-10-breakglass.conf` |
| host firewall | `BREAKGLASS` chain: `:52222` rate-limited per source, LAN bypass; replaced the knock-gated default-DROP | `scripts/breakglass-firewall.sh` (+ `breakglass-firewall.service`) |
| fail2ban | jail fixed for Debian 13 (`journalmatch` by unit, not `_COMM=sshd`, else it never bans), bans on `:22`+`:52222` | `scripts/fail2ban-breakglass-sshd.local` |
| knockd | **removed** (package purged, config deleted) | — |
| edge router | `breakglass-ssh` WAN tcp/52222 → 192.168.1.127:52222; **removed** legacy Synology SSH forward (ext 3333 → .13:22) | manual (live device) |
| Vault | `breakglass_ssh_{pub,priv}key` retained; `breakglass_knock_sequence` now dead | `secret/viktor` |

## Edge-router constraints discovered (TP-Link AX6000)

- **No port remapping** — external port must equal internal port (rejects e.g.
  `22 → 52222` as a "conflict"). All forwards are ext==int; hence `:52222` both
  sides.
- **Port 22 is reserved** — `22 → 22` is also refused. Break-glass cannot use 22
  (Viktor's initial preference); `:52222` is the landed port.
- **Row delete is immediate** (no confirm dialog).

## Security posture

- **Brute force: impossible** (key-only, no password).
- **Scannable: yes** — deliberate, documented Wave-1 exception (`security.md`).
- **Residual risks:** sshd 0-day during exposure (mitigate: patch, rate-limit,
  fail2ban, low MaxAuthTries); break-glass key theft (revoke by removing the
  `authorized_keys.breakglass` line). Logins are audited (PVE ships sshd auth +
  snoopy execve to Loki).

## Verification (2026-06-11)

- `:52222` reachable; break-glass key authenticates (`root@pve`).
- Non-break-glass keys **rejected** on `:52222` (Match isolation works).
- `:22` LAN admin unaffected (Match all reset confirmed — global root login intact).
- Full WAN path: `ssh -p 52222 <WAN-IP>` with the break-glass key → `root@pve`.
- knockd gone; fail2ban jail matches Debian 13 `sshd-session` lines.
