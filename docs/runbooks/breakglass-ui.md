# Runbook: devvm breakglass UI (claude-breakglass)

Last updated: 2026-06-12

## What this is

`breakglass.viktorbarzin.me` — an in-cluster Claude-driven web UI for recovering
the **devvm** (Proxmox VM 102) when it is wedged but the cluster is healthy (the
**warm** case). You chat with a Claude agent that SSHes into the devvm to
diagnose/repair it, and there are manual buttons that power-cycle the VM via the
Proxmox host even if the Anthropic API is down.

This is NOT the cold breakglass. If the **cluster or PVE host** is down, this UI
is down too (it's a cluster workload). For that case use the cold path:
- `ssh -p 52222 root@<wan>` → `qm stop 102 && qm start 102` (`docs/runbooks/breakglass-ssh.md`)
- `server-lifecycle` iDRAC CLI (192.168.1.4) to power-cycle the whole host.

## Architecture

```
browser ─► Cloudflare ─► Traefik ─► auth-proxy (Authentik, basic-auth fallback)
                                      └─► claude-breakglass Service (in-cluster)
claude-breakglass pod (ns claude-breakglass, own SA, NO Vault role):
  • app.breakglass.server (FastAPI) serves the Svelte UI + /api
  • chat → claude -p --agent breakglass (stream-json → SSE)
  • ssh-agent holds the breakglass key (synced by ESO, never on disk)
  • ssh devvm  → breakglass@10.0.10.10 (full sudo)         [diagnose/repair]
  • ssh pve <verb> → root@192.168.1.127 forced-command     [VM 102 power verbs]
```

Image: `forgejo.viktorbarzin.me/viktor/claude-agent-service:latest` (shared with
claude-agent-service; the deployment overrides the command with
`/srv/docker-entrypoint-breakglass.sh`). Code: `claude-agent-service/app/breakglass/`.
Stack: `stacks/claude-breakglass/`. ADR: `claude-agent-service/docs/adr/0001-*`.

## Auth (how to get in)

- **Normal:** Authentik SSO (you're already logged in to the SSO).
- **Authentik down:** the auth-proxy falls back to HTTP basic-auth ("Emergency
  Access"). Username `admin`; password is the shared `auth_fallback_htpasswd`
  (Vault `secret/platform`). This same credential gates every `auth="required"`
  app. Rotate: regenerate the htpasswd, `vault kv patch secret/platform
  auth_fallback_htpasswd=...`, apply the `traefik` stack (the auth-proxy rolls
  on the `checksum/auth-proxy-htpasswd` annotation).

## The PVE forced-command (the reset path)

The breakglass SSH key's entry in PVE `/root/.ssh/authorized_keys` is pinned to
`command="/usr/local/bin/breakglass-pve",restrict,from="192.168.1.2"`. It only
accepts the bare verbs **`status | forensics | reset | stop | start | cycle`**
against VM 102 — anything else is rejected and logged to
`/var/log/breakglass-pve.log`. Every mutating verb captures forensics first.

- **cycle** = stop→start (fresh QEMU, applies staged config) — the fix for a
  QEMU I/O stall (2026-06-11). If a clean stop fails, it kills the wedged QEMU
  PID then starts. **Prefer `cycle` over `reset` for a wedged VM.**
- `reset` is a warm reset (reuses QEMU) — only for a normal guest hang.

Script source: `stacks/claude-breakglass/files/breakglass-pve` (deploy via
`scp … root@192.168.1.127:/usr/local/bin/breakglass-pve`).

## NAT quirks (why `from=` differs per host)

Discovered during bring-up — both verified from a real in-cluster pod:
- **pod → PVE (192.168.1.127):** pfSense SNATs inter-VLAN traffic to its
  `192.168.1.2` interface, so PVE sees `192.168.1.2` for ALL cluster (and devvm)
  SSH. Hence the PVE key uses `from="192.168.1.2"`. The devvm itself is NOT a
  permitted source (it's the box being recovered).
- **pod → devvm (10.0.10.10):** the devvm sees the Calico-SNAT **node IP**
  (10.0.20.0/24). Hence the devvm key uses `from="10.0.20.0/24"`.

## Host bootstrap (one-time; redo on devvm rebuild / key rotation)

The keypair lives in Vault `secret/claude-breakglass/ssh_key`
(`private_key`/`public_key`). To re-provision after a rebuild:

```bash
PUB=$(vault kv get -field=public_key secret/claude-breakglass/ssh_key)

# devvm (full-sudo recovery user):
sudo useradd -m -s /bin/bash breakglass 2>/dev/null || true
sudo install -d -m700 -o breakglass -g breakglass /home/breakglass/.ssh
printf 'from="10.0.20.0/24" %s\n' "$PUB" | sudo tee /home/breakglass/.ssh/authorized_keys
sudo chown breakglass:breakglass /home/breakglass/.ssh/authorized_keys
sudo chmod 600 /home/breakglass/.ssh/authorized_keys
echo 'breakglass ALL=(ALL) NOPASSWD:ALL' | sudo tee /etc/sudoers.d/breakglass && sudo chmod 440 /etc/sudoers.d/breakglass

# PVE (forced-command power verbs):
scp stacks/claude-breakglass/files/breakglass-pve root@192.168.1.127:/usr/local/bin/breakglass-pve
ssh root@192.168.1.127 chmod 0755 /usr/local/bin/breakglass-pve
# then append to /root/.ssh/authorized_keys on PVE:
#   command="/usr/local/bin/breakglass-pve",restrict,from="192.168.1.2" <PUB>
```

Host-key checking is OFF in the pod's ssh config (a devvm rebuild rotates the
host key; strict checking would lock the breakglass out mid-incident — trusted
internal LAN, key auth stands).

## Verify

```bash
kubectl -n claude-breakglass get pods                 # Running
kubectl -n claude-breakglass logs deploy/claude-breakglass | grep -i ssh-add
curl -sk https://breakglass.viktorbarzin.me/health    # (through the edge)
# from a pod, the PVE path:  ssh pve status  → "status: running"
```

## Isolation (why a separate deployment)

The shared `claude-agent` pod runs agents that ingest untrusted input
(recruiter emails, nextcloud todos) with Bash. Co-locating the root-on-devvm key
there would let a prompt injection exfiltrate it. The breakglass runs in its own
namespace with its own SA and **no Vault role** (ESO syncs only its key); the
`terraform-state` Vault policy is explicitly DENIED `secret/claude-breakglass/*`.
