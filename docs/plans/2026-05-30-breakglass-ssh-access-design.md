# Break-Glass SSH Access — Design

> **⚠️ SUPERSEDED 2026-06-11** by `2026-06-11-breakglass-ssh-redesign-design.md`.
> The port-knock was removed: it added no real security (the SSH key already
> makes the port brute-force-proof) and its knock sequence lived only in
> in-cluster Vault — unreachable in the exact cold/away scenario break-glass
> exists for, which caused a real lockout. Retained for history. As-built:
> `docs/runbooks/breakglass-ssh.md`.

- **Date**: 2026-05-30
- **Status**: Draft — pending user review
- **Owner**: Viktor
- **Related**: `docs/architecture/vpn.md`, `docs/architecture/security.md`, `infra/.claude/CLAUDE.md` (Security Posture Wave 1)

## 1. Goal

Provide a **cold, brute-force-proof backdoor onto the home LAN from the public
internet** for the case where the Kubernetes cluster and every cluster-hosted
remote-access path are down (cloudflared, Headscale/Tailscale, in-cluster
WireGuard), but the **Proxmox host, pfSense, and the edge router are still up**.

### Hard requirements (from the user)

1. **Cold-survivable**: must work when the k8s cluster + all its tunnels are
   down. The path must touch **nothing in the cluster** (no Authentik, Traefik,
   Technitium/AdGuard DNS, cloudflared).
2. **Full LAN access** once connected (SSH to Proxmox host, pfSense, Synology,
   k8s API, etc.).
3. **No brute force**: no password-guessable surface.
4. **Client uses only software pre-installed on Linux/macOS** — no WireGuard /
   Tailscale / fwknop client install. Stock `ssh` (+ `bash`) only.
5. **Minimal effort**, and ideally **honor the locked Wave 1 policy**
   (`no public-IP access — … PVE sshd must transit LAN or Headscale`).

## 2. Decision

**Key-only SSH to the Proxmox host, gated behind a UDP port-knock.**

- The Proxmox host (`192.168.1.127`) is the entry point — it's the recovery box
  (`virsh`/`qm` to reboot the pfSense VM, `kubectl`, full hypervisor control)
  and it sits directly on the `192.168.1.0/24` segment, so the path **does not
  traverse pfSense or the cluster** — it survives a wedged pfSense too, not just
  a down cluster.
- SSH is the only externally-usable remote tool **pre-installed on every
  Linux/macOS box**, satisfying requirement 4.
- **Key-only auth** (no passwords anywhere) makes password brute force
  impossible → requirement 3.
- A **port-knock** keeps the external SSH port **closed/invisible to scanners**
  until a knock sequence is sent. This restores the "no standing public service"
  property we'd have had with WireGuard and keeps us within the **intent** of the
  Wave 1 policy (PVE sshd is not internet-scannable). The knock is sent with a
  **bash `/dev/udp` one-liner** — zero install.

### Alternatives rejected

| Option | Why rejected |
|---|---|
| WireGuard road-warrior on pfSense | Needs a WireGuard **client app** (fails requirement 4). Was the prior design. |
| Tailscale / Headscale | Client app + control plane is in-cluster (dies cold). |
| Browser → web admin UI (Proxmox/pfSense/Synology) | "Pre-installed" (browser) but password-based → brute-forceable, far larger attack surface than a key-only SSH port. |
| Plain **exposed** key-only SSH (no knock) | Brute-force-proof, but a **publicly visible** service (Shodan-catalogued) and a standing violation of the Wave 1 "no public PVE sshd" policy. The knock removes the standing exposure for ~15 min more setup. |
| fwknop / cryptographic SPA | Strongest hiding, but needs a **client install** (fails requirement 4). |

## 3. Architecture

```
  Your laptop (anywhere) — stock ssh + bash, nothing installed
     │  (1) UDP knock sequence  →  bash: echo > /dev/udp/<pub>/<port>   (instant, no handshake)
     │  (2) ssh -p 52222 root@<pub>
     ▼
  Edge router 192.168.1.1   (the box the stored password unlocks)
     │  forwards:  UDP <k1>,<k2>,<k3>  +  TCP 52222   →   192.168.1.127
     ▼
  Proxmox host 192.168.1.127   ← path bypasses pfSense entirely
     ├─ knockd (libpcap) sees the UDP knock → opens TCP 52222 for your source IP (30 s)
     ├─ sshd listens on :22 (LAN admin, always) AND :52222 (external, knock-gated), key-only
     └─ once in:  virsh/qm (reboot pfSense VM), kubectl, ssh -J / ssh -D → full LAN
```

**Why it meets "cold + full LAN":** the host is up by definition of the chosen
failure mode; nothing in the path depends on k8s, pfSense, or DNS. From the host
you reach the whole LAN either directly (it's on `192.168.1.0/24` and routes to
the VLANs via pfSense when pfSense is up) or by using SSH's built-in
`-J`/`-D` — both stock, no install.

## 4. Components

### 4.1 Edge router @ 192.168.1.1 (manual, in the browser)
Add port-forwards (same place the existing `51821` WireGuard forward lives):
- **TCP 52222 → 192.168.1.127:52222** (external SSH; no port rewrite — see §4.3 rationale)
- **UDP `<k1>`, `<k2>`, `<k3>` → 192.168.1.127** (knock ports; actual numbers in Vault)

If the router supports a **port range** forward, a single range covering the
knock ports + 52222 is tidier than four rules.

> **Verify (#1 implementation check):** whether `.1` **preserves the source IP**
> on forwarded packets (typical DNAT) or **SNATs** them to `192.168.1.1`. Test by
> knocking + connecting from an external network and checking `/var/log/auth.log`
> + `knockd` syslog for the observed source IP. The design works either way (see
> §4.3), but it determines knock granularity.

### 4.2 SSH keys & Vault layout
- Mint a **dedicated** break-glass keypair (ed25519), separate from
  `secret/viktor/proxmox_ssh_key`, so it's independently revocable and clearly
  labelled.
- **Public key** → `/root/.ssh/authorized_keys` on the Proxmox host (no `from=`
  restriction — break-glass is from-anywhere; the knock + key are the gate).
- **Private key** → Vault `secret/viktor/breakglass_ssh_privkey` (for
  re-provisioning) **and** on your laptop at `~/.ssh/breakglass_ed25519`
  (chmod 600).
- **Knock sequence** → Vault `secret/viktor/breakglass_knock_sequence` (kept out
  of git — obscurity value only; see §5).

### 4.3 Proxmox host — sshd hardening
`/etc/ssh/sshd_config.d/10-breakglass.conf`:
```
Port 22
Port 52222
PasswordAuthentication no
KbdInteractiveAuthentication no
PubkeyAuthentication yes
PermitRootLogin prohibit-password     # key-only root (PVE recovery norm)
MaxAuthTries 3
LoginGraceTime 20
```
- sshd listens on **:22 (LAN admin, always allowed)** and **:52222 (external,
  knock-gated)**. Using a dedicated external port (not a DNAT rewrite to 22)
  lets the firewall distinguish LAN vs external **regardless of `.1` SNAT
  behaviour** (§4.1) — LAN admin on `:22` is never affected by the gate.
- **Default to root key-only** for recovery practicality. *Alternative for
  review:* a dedicated `breakglass` sudo user instead of root.

> **Verify (#2):** key login already works for your normal access **before**
> `PasswordAuthentication no` is committed — no lockout. (Backup rsync jobs
> already use keys, so this is likely already effectively true.)

### 4.4 Host firewall (knock gate)
Default-drop the external SSH port; knockd punches a per-source hole. LAN admin
(`:22`) and established sessions are untouched:
```
# allow established / related
iptables -A INPUT -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT
# LAN admin + backups: SSH on :22 always allowed
iptables -A INPUT -p tcp --dport 22 -j ACCEPT
# external SSH on :52222 closed by default — knockd opens it per-source
iptables -A INPUT -p tcp --dport 52222 -j DROP
```
- **knockd uses libpcap**, so it sees the UDP knock packets even though iptables
  drops them — the knock ports stay **silent/closed** to scanners.
- **pve-firewall coexistence (verify #3):** confirm whether the PVE firewall is
  enabled. If it is, express these rules through it (or a dedicated chain) so a
  pve-firewall reload doesn't wipe the knockd-managed rule. Default PVE installs
  often have it off at datacenter level.

### 4.5 knockd
`apt install knockd` (Debian/PVE). `/etc/knockd.conf`:
```
[options]
    UseSyslog
    Interface = vmbr0          # the 192.168.1.127 interface

[breakglass]
    sequence      = <k1>:udp,<k2>:udp,<k3>:udp     # real ports from Vault
    seq_timeout   = 10
    start_command = /usr/sbin/iptables -I INPUT 1 -s %IP% -p tcp --dport 52222 -j ACCEPT
    cmd_timeout   = 30
    stop_command  = /usr/sbin/iptables -D INPUT -s %IP% -p tcp --dport 52222 -j ACCEPT
```
- **UDP knock** → the client knock is fire-and-forget (`/dev/udp`), no TCP-hang
  on the client (a TCP knock to a dropped port would block until timeout).
- Opens `:52222` for the knocker's source IP for **30 s**; an SSH session
  established within that window **persists** via conntrack ESTABLISHED after the
  rule is removed. Enable + start the `knockd` service.

### 4.6 fail2ban (defense-in-depth)
`apt install fail2ban`, sshd jail (watches `auth.log`, bans repeat failures).
Local to the host, **no cluster dependency**. Catches anything that gets past the
knock to the sshd listener.

### 4.7 Client side (laptop — stock tools only)
`~/.ssh/config`:
```
Host breakglass
    HostName <public-ip-or-dyndns>
    Port 52222
    User root
    IdentityFile ~/.ssh/breakglass_ed25519
```
Knock + connect — a shell function using **bash builtins only** (works on
macOS `/bin/bash` + Linux; UDP send is instant):
```sh
bg() {
  local host=<public-ip-or-dyndns>
  for p in <k1> <k2> <k3>; do echo -n x > "/dev/udp/$host/$p"; sleep 0.4; done
  sleep 0.5
  ssh breakglass "$@"
}
```
- **Full LAN, no install:** `ssh -J breakglass <internal-host>` (jump), or
  `ssh -D 1080 breakglass` then point a browser/`curl` at SOCKS5 `127.0.0.1:1080`
  to reach any internal IP. From the host shell you already have everything.
- *Optional fully-transparent variant:* fold the knock into a `ProxyCommand` in
  the `Host breakglass` block so plain `ssh breakglass` knocks automatically.

### 4.8 Cold-scenario IP cheat sheet (DNS is down when the cluster is down)
Technitium + AdGuard are in-cluster, so `.lan` resolution is gone in a cold
event. Use IPs:

| Host | IP |
|---|---|
| Proxmox host | `192.168.1.127` (also `10.0.10.1` VLAN10) |
| pfSense | `10.0.20.1` (WAN `192.168.1.2`) |
| k8s API server | `10.0.20.100` |
| Synology NAS | `192.168.1.13` |
| Edge router | `192.168.1.1` |
| Traefik LB / MetalLB | `10.0.20.200` / `10.0.20.203` |

## 5. Security analysis

- **Brute force: solved.** No password auth anywhere → password guessing is
  impossible; key brute force is cryptographically infeasible.
- **Invisibility / Wave 1 intent: satisfied.** The external SSH port is
  default-dropped and the knock ports are pcap-sniffed (never answered), so a
  scanner sees a closed/silent host — PVE sshd is **not internet-scannable**,
  honouring the spirit of "no public-IP access to PVE sshd".
- **The knock is obscurity, not cryptography.** A port-knock sequence is
  plaintext and replayable by a passive on-path observer. **The SSH key is the
  real access control** — the knock only removes the standing/scannable surface.
  (Cryptographic SPA = fwknop, rejected for needing a client install.) Treat the
  knock sequence as a secret-ish convenience, not a second cryptographic factor.
- **Residual risks** (none are brute force):
  1. An sshd **0-day** exploitable during the 30 s open window → mitigation: keep
     PVE patched; short `cmd_timeout`; fail2ban.
  2. **Private key theft** → mitigation: key has a passphrase; revoke by removing
     the line from `authorized_keys`.
  3. If `.1` **SNATs** (§4.1), the 30 s window opens `:52222` for the shared
     `192.168.1.1` source — anyone else arriving via `.1` in that window could
     reach the sshd banner, but still needs your key. Mitigated by the short
     window + key-only + fail2ban.
- **Deliberate, documented exception** to the Wave 1 "no public-IP access"
  policy, scoped to this single knock-gated port. To be recorded in
  `security.md` + the Wave 1 note in `infra/.claude/CLAUDE.md` on implementation.

## 6. What's automated vs manual

- **I do**: generate the keypair + knock sequence, store them in Vault, produce
  the exact `sshd_config.d` snippet, `knockd.conf`, iptables rules, the client
  `~/.ssh/config` + `bg()` function, and write the runbook + doc updates.
- **Manual / careful (live devices)**: the `.1` edge-router forwards are done by
  you in the browser (out-of-Terraform, live device). The Proxmox host changes
  (sshd, knockd, iptables, fail2ban) are applied over SSH **with key-login
  verified first** to avoid lockout; pfSense is **not** touched. None of this is
  a `tg apply` — pfSense and the edge router are not Terraform-managed.

## 7. Testing & verification
1. From an **external** network (phone hotspot): run `bg`; confirm knockd syslog
   shows the sequence + opens `:52222`; SSH succeeds.
2. **Without** knocking: `ssh -p 52222` from external → connection refused/timed
   out (port closed). A plain port scan of `52222` + the knock ports → silent.
3. LAN admin on `:22` still works (no regression); backup rsync jobs unaffected.
4. Full-LAN: `ssh -J breakglass 10.0.20.1` (pfSense) and `ssh -D 1080` SOCKS to
   an internal IP.
5. Determine `.1` source-IP behaviour (verify #1) and adjust knock granularity
   note accordingly.

## 8. Failure modes & rotation
- **Proxmox host down** (not just cluster): this path is gone — that's the
  out-of-band tier (serial/IPMI/separate device), explicitly **out of scope**.
- **`.1` router config reset**: forwards lost → re-add from this doc; consider
  exporting the `.1` config for backup.
- **Public IP change**: use a hostname endpoint (Cloudflare-resolved) so it
  auto-follows; keep the raw IP as fallback.
- **Key/knock compromise**: remove the `authorized_keys` line (kills access
  instantly); rotate the knock sequence in `knockd.conf` + Vault.

## 9. Out of scope
- Host-down / site-down out-of-band access (IPMI, LTE) — a future tier.
- Phone access (would need an SSH **app**, e.g. Termius — outside the
  "pre-installed Linux/macOS" constraint; laptop is the target).

## 10. Docs to update on implementation
- `docs/architecture/vpn.md` — add a "Break-glass SSH" section.
- `docs/architecture/security.md` + Wave 1 note in `infra/.claude/CLAUDE.md` —
  record the deliberate knock-gated exception to "no public PVE sshd".
- New runbook `docs/runbooks/breakglass-ssh.md` — connect + rotate procedure.
