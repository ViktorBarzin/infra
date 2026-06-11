# Runbook: Break-glass SSH

Cold-survivable, brute-force-proof SSH onto the home LAN for when the Kubernetes
cluster and its remote-access tunnels (Headscale, cloudflared) are down but the
**Proxmox host + edge router are up**. Redesigned 2026-06-11 — the previous
port-knock design is decommissioned (see "History" below).

## Model (as built)

```
your laptop (anywhere) ── ssh -p 52222 ──▶ edge router 192.168.1.1
                                              │ WAN tcp/52222 ─▶ 192.168.1.127:52222
                                              ▼
                                       Proxmox host 192.168.1.127
                                          sshd :52222 (key-only, break-glass key ONLY)
                                          → full LAN via ssh -J / ssh -D
```

- **No port-knock.** Plain `ssh -p 52222`. The SSH key is the only gate.
- **Key-only**, brute-force-proof. The exposed `:52222` trusts **only** the
  dedicated break-glass key (`/root/.ssh/authorized_keys.breakglass`), separate
  from root's normal LAN-admin keys, so it is independently revocable and a leak
  of any other root key does not grant internet access.
- **Rate-limited** per source IP (iptables hashlimit) + **fail2ban**. These trim
  scanner noise only; key-only auth is the real protection.
- **Exposed, not hidden.** `:52222` answers on the WAN (Shodan-visible). This is
  a deliberate, documented exception to the Wave-1 "no public-IP access" policy
  (see `docs/architecture/security.md`), chosen for self-containment: it has **no
  dependency on the cluster** (unlike Headscale/cloudflared) and nothing to
  remember (unlike the old knock, whose sequence lived only in in-cluster Vault).

## Secrets (Vault `secret/viktor`)

| Key | Use |
|---|---|
| `breakglass_ssh_pubkey` | authorized on the host (`authorized_keys.breakglass`) |
| `breakglass_ssh_privkey` | the private key (also on your laptop at `~/.ssh/breakglass_ed25519`) |

The key has **no passphrase** (so it works in a true cold event without anything
to recall). Treat the private key as the sole credential — guard the laptop copy.

> Leftover: `breakglass_knock_sequence` is dead (knock decommissioned). It is
> inert; remove it when you have a Vault token with the `patch` capability
> (`vault kv patch` / merge-patch — the everyday token lacks it).

## Connect

Client `~/.ssh/config`:

```
Host breakglass
    HostName viktorbarzin.ddns.net        # follows the dynamic WAN IP
    Port 52222
    User root
    IdentityFile ~/.ssh/breakglass_ed25519
    IdentitiesOnly yes
```

Then:

```bash
ssh breakglass                              # shell on the Proxmox host
ssh -J breakglass root@10.0.20.1            # jump to pfSense (or any LAN host)
ssh -D 1080 breakglass                      # SOCKS5 → reach any internal IP
```

There is **no `bg()` knock function** anymore — delete it from your shell rc if
you added it under the old design.

## Cold-event IP cheat sheet (cluster DNS is down)

| Host | IP |
|---|---|
| Proxmox host | `192.168.1.127` |
| pfSense | `10.0.20.1` (WAN `192.168.1.2`) |
| k8s API | `10.0.20.100` |
| Synology NAS | `192.168.1.13` (reach via `ssh -J breakglass`) |
| edge router | `192.168.1.1` |

## Deploy / re-provision the host config

Source of truth lives in `infra/scripts/`. To (re)deploy:

```bash
# 1. break-glass key authorized for the exposed port
PUB="$(vault kv get -field=breakglass_ssh_pubkey secret/viktor)"
ssh root@192.168.1.127 "printf '%s\n' '$PUB' > /root/.ssh/authorized_keys.breakglass && chmod 600 /root/.ssh/authorized_keys.breakglass"

# 2. sshd drop-in (dual-port, Match-isolated) — validate before reload (anti-lockout)
scp scripts/sshd-10-breakglass.conf root@192.168.1.127:/etc/ssh/sshd_config.d/10-breakglass.conf
ssh root@192.168.1.127 'sshd -t && systemctl reload ssh'

# 3. firewall (rate-limit) + boot unit
scp scripts/breakglass-firewall.sh root@192.168.1.127:/usr/local/sbin/breakglass-firewall.sh
ssh root@192.168.1.127 'chmod 0755 /usr/local/sbin/breakglass-firewall.sh && systemctl enable --now breakglass-firewall.service'

# 4. fail2ban jail
scp scripts/fail2ban-breakglass-sshd.local root@192.168.1.127:/etc/fail2ban/jail.d/breakglass-sshd.local
ssh root@192.168.1.127 'systemctl restart fail2ban && fail2ban-client status sshd'
```

The `breakglass-firewall.service` unit (oneshot, `RemainAfterExit=yes`,
`Before=network-online`-ish ordering) is a manual host unit — recreate it if the
host is rebuilt:

```ini
[Unit]
Description=Break-glass base firewall (key-only SSH on :52222)
After=network-pre.target
Wants=network-pre.target
[Service]
Type=oneshot
ExecStart=/usr/local/sbin/breakglass-firewall.sh
RemainAfterExit=yes
[Install]
WantedBy=multi-user.target
```

## Edge-router forward (manual — live device, not Terraform)

TP-Link Archer AX6000 (`192.168.1.1`) → Advanced → NAT Forwarding → Port
Forwarding. The break-glass rule:

| Service Name | Device IP | External Port | Internal Port | Protocol |
|---|---|---|---|---|
| `breakglass-ssh` | `192.168.1.127` | `52222` | `52222` | TCP |

**AX6000 quirks (learned 2026-06-11 — do not relearn the hard way):**
- **External port must equal internal port.** The firmware rejects any remap
  (e.g. `22 → 52222`) with *"External Port: This item conflicts with existed
  ones."* Hence ext==int 52222.
- **Port 22 is reserved** — even `22 → 22` is refused. Break-glass cannot use 22.
- **Row delete is immediate** (no confirm dialog) — clicking the trash icon
  removes the rule and toasts "Operation succeeded".
- Automation: `~/wizard/tools/insecure-browse/add-forward.{sh,js}` (dockerized
  Playwright; double-gated save `DRY_RUN=0 CONFIRM_SAVE=1`; supports
  `RULES_JSON` add, `EDIT_RULES_JSON` protocol-edit, `DELETE_RULES_JSON`
  identity-guarded delete). Router password: Vault
  `secret/viktor/edge_router_192_168_1_1_password`.

## Rotate / revoke

- **Revoke instantly:** remove the line from `/root/.ssh/authorized_keys.breakglass`.
- **Rotate the key:** `ssh-keygen -t ed25519 -a 100 -f ~/.ssh/breakglass_ed25519`,
  `vault kv patch secret/viktor breakglass_ssh_privkey=@... breakglass_ssh_pubkey=...`,
  redeploy step 1 above.
- **Router reset wipes forwards:** re-add the `breakglass-ssh` rule above.

## History

- **2026-05-30:** original design — key-only SSH on `:52222` gated behind a
  **UDP port-knock** (knockd). Decommissioned 2026-06-11: the knock added no real
  security (the SSH key already makes the port brute-force-proof) and its only
  benefit — hiding the port — came at the cost of a **circular dependency**: the
  knock sequence lived only in in-cluster Vault, unreachable in the exact
  cold/away scenario break-glass exists for. That caused a real lockout. The
  knockd package + config + the legacy Synology SSH forward (ext 3333 → .13:22)
  were removed.
