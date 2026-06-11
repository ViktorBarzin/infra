# Break-Glass SSH Access — Implementation Plan

> **⚠️ SUPERSEDED 2026-06-11** by the redesign in
> `2026-06-11-breakglass-ssh-redesign-design.md` (port-knock removed). Retained
> for history. As-built: `docs/runbooks/breakglass-ssh.md`.

> **Execution model:** This plan mutates **live devices** (the Proxmox host's sshd, and the TP-Link edge router). It is **human-gated**, NOT for autonomous subagents. Each live step is applied with anti-lockout verification, and every edge-router change is made by Viktor (or by the browse tool with explicit per-change approval). Steps use `- [ ]` checkboxes.

**Goal:** Stand up a cold, brute-force-proof SSH backdoor onto the LAN — key-only SSH to the Proxmox host (`192.168.1.127`) gated behind a UDP port-knock — then decommission the legacy Synology SSH exposure and tighten UPnP.

**Architecture:** Edge router `.1` forwards a UDP knock sequence + TCP `52222` to the Proxmox host. The host runs `knockd` (libpcap) which opens `52222` for the knocker's IP for 30 s; `sshd` listens on `:22` (LAN, always) and `:52222` (external, knock-gated), key-only. Path bypasses pfSense + the k8s cluster. Client uses only stock `ssh` + `bash`.

**Tech stack:** OpenSSH, knockd, iptables, fail2ban (Debian/PVE host); TP-Link Archer AX6000 UI (edge router); HashiCorp Vault (secrets); Docker (`/home/wizard/tools/insecure-browse` for any router automation).

**Reference:** design doc `2026-05-30-breakglass-ssh-access-design.md`. Router audit (current `.1` forwards) recorded in task notes + `/home/wizard/tools/insecure-browse/out/`.

---

## Pre-flight (read before starting)

- **Anti-lockout rule:** never disable password auth or reload sshd without an *already-open* root session held + a *new* session verified. Applies to every host step.
- **Live-router rule:** all `.1` changes are made by Viktor in the UI (or browse-tool with explicit approval). No blind automation of router writes.
- **Ordering rule:** the legacy Synology SSH forward (Rule 6) is **not** closed until break-glass is verified working from an external network (Phase 4 gates on Phase 4-pre verification).
- **Host access:** PVE host reached as `ssh root@192.168.1.127` from the LAN.
- **Commit gate:** the infra repo currently has unmerged conflicts + an in-progress provider/backend migration. Do NOT commit (Phase 6) until Viktor confirms the repo is clean.

---

## Phase 0 — Generate secrets (no live changes)

### Task 0.1: Break-glass SSH keypair

**Files:** none in repo (secrets → Vault).

- [ ] **Step 1: Generate a dedicated ed25519 keypair (with passphrase)**

```bash
mkdir -p ~/.ssh
ssh-keygen -t ed25519 -a 100 -C "breakglass-$(date +%Y%m%d)" -f ~/.ssh/breakglass_ed25519
# set a passphrase when prompted (so a stolen laptop key isn't instantly usable)
```

- [ ] **Step 2: Store the private key + public key in Vault**

```bash
vault kv patch secret/viktor \
  breakglass_ssh_privkey=@$HOME/.ssh/breakglass_ed25519 \
  breakglass_ssh_pubkey="$(cat ~/.ssh/breakglass_ed25519.pub)"
```

- [ ] **Step 3: Verify the keys are retrievable**

```bash
vault kv get -field=breakglass_ssh_pubkey secret/viktor
```
Expected: prints the `ssh-ed25519 AAAA... breakglass-YYYYMMDD` line.

### Task 0.2: Knock sequence

- [ ] **Step 1: Generate 3 random UDP knock ports**

```bash
KNOCK="$(shuf -i 20000-60000 -n 3 | paste -sd, -)"; echo "$KNOCK"
```

- [ ] **Step 2: Store the sequence in Vault (keep it out of git)**

```bash
vault kv patch secret/viktor breakglass_knock_sequence="$KNOCK"
vault kv get -field=breakglass_knock_sequence secret/viktor
```
Expected: prints three comma-separated ports, e.g. `28411,49027,33180`.

---

## Phase 1 — Proxmox host: key-only SSH + knock gate (LIVE host change)

> Run everything in this phase **on the PVE host**. Keep your current `ssh root@192.168.1.127` session open the entire phase.

### Task 1.1: Pre-checks (no changes yet)

- [ ] **Step 1: Confirm key login already works (anti-lockout baseline)**

From your laptop, with the break-glass key authorized later — for now confirm your *existing* admin key works:
```bash
ssh -o PasswordAuthentication=no root@192.168.1.127 'echo KEY_LOGIN_OK'
```
Expected: `KEY_LOGIN_OK` (key auth works → safe to disable passwords later). If it prompts for a password, STOP and fix key auth first.

- [ ] **Step 2: Check whether the PVE firewall is active (coexistence)**

```bash
ssh root@192.168.1.127 'pve-firewall status 2>/dev/null; iptables -S | head'
```
Expected: note whether `Status: enabled/running`. If **enabled**, add the Phase-1.4 rules via PVE's firewall (Datacenter→Firewall) instead of raw iptables, OR disable it if unused. If **disabled** (common), proceed with the raw-iptables approach below.

### Task 1.2: Authorize the break-glass key

- [ ] **Step 1: Append the break-glass public key to root's authorized_keys**

```bash
PUB="$(vault kv get -field=breakglass_ssh_pubkey secret/viktor)"
ssh root@192.168.1.127 "grep -qF '$PUB' /root/.ssh/authorized_keys || echo '$PUB' >> /root/.ssh/authorized_keys"
```

- [ ] **Step 2: Verify break-glass key logs in (on :22, still default)**

```bash
ssh -i ~/.ssh/breakglass_ed25519 -o PasswordAuthentication=no root@192.168.1.127 'echo BREAKGLASS_KEY_OK'
```
Expected: `BREAKGLASS_KEY_OK`.

### Task 1.3: sshd dual-port + key-only

**Files:** Create on host: `/etc/ssh/sshd_config.d/10-breakglass.conf`

- [ ] **Step 1: Write the sshd drop-in**

```bash
ssh root@192.168.1.127 'cat > /etc/ssh/sshd_config.d/10-breakglass.conf' <<'EOF'
Port 22
Port 52222
PasswordAuthentication no
KbdInteractiveAuthentication no
PubkeyAuthentication yes
PermitRootLogin prohibit-password
MaxAuthTries 3
LoginGraceTime 20
EOF
```

- [ ] **Step 2: Validate config syntax (do NOT reload yet)**

```bash
ssh root@192.168.1.127 'sshd -t && echo SSHD_CONFIG_OK'
```
Expected: `SSHD_CONFIG_OK`. If error, fix the drop-in before reloading.

- [ ] **Step 3: Reload sshd (current session stays alive)**

```bash
ssh root@192.168.1.127 'systemctl reload ssh && echo RELOADED'
```
Expected: `RELOADED`.

- [ ] **Step 4: Verify a NEW key session works on :22 AND :52222 before trusting it**

```bash
ssh -i ~/.ssh/breakglass_ed25519 -p 22    root@192.168.1.127 'echo OK22'
ssh -i ~/.ssh/breakglass_ed25519 -p 52222 root@192.168.1.127 'echo OK52222'
```
Expected: `OK22` and `OK52222`. (If `:52222` refuses, sshd may not have bound the second port — check `ss -tlnp | grep ssh` on the host.) Only after both succeed, the old session is safe to drop.

### Task 1.4: Base firewall (default-drop :52222, allow :22 + established)

**Files:** Create on host: `/usr/local/sbin/breakglass-firewall.sh`, `/etc/systemd/system/breakglass-firewall.service`

- [ ] **Step 1: Write the idempotent base-firewall script (dedicated chain)**

```bash
ssh root@192.168.1.127 'cat > /usr/local/sbin/breakglass-firewall.sh' <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
# Idempotent: (re)build a dedicated BREAKGLASS chain hooked into INPUT.
iptables -N BREAKGLASS 2>/dev/null || iptables -F BREAKGLASS
iptables -C INPUT -j BREAKGLASS 2>/dev/null || iptables -I INPUT 1 -j BREAKGLASS
# established/related always allowed
iptables -A BREAKGLASS -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT
# LAN admin on :22 always allowed (.1 does NOT forward :22 to this host, so :22 is LAN-only)
iptables -A BREAKGLASS -p tcp --dport 22 -j ACCEPT
# external SSH on :52222 closed by default; knockd punches a per-source ACCEPT into INPUT pos 1
iptables -A BREAKGLASS -p tcp --dport 52222 -j DROP
EOF
ssh root@192.168.1.127 'chmod 0755 /usr/local/sbin/breakglass-firewall.sh'
```

- [ ] **Step 2: Write a boot-time systemd unit (persists across reboot, before knockd)**

```bash
ssh root@192.168.1.127 'cat > /etc/systemd/system/breakglass-firewall.service' <<'EOF'
[Unit]
Description=Break-glass base firewall (SSH knock gate)
After=network-pre.target
Before=knockd.service
Wants=network-pre.target

[Service]
Type=oneshot
ExecStart=/usr/local/sbin/breakglass-firewall.sh
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF
ssh root@192.168.1.127 'systemctl daemon-reload && systemctl enable --now breakglass-firewall.service && echo FW_APPLIED'
```
Expected: `FW_APPLIED`.

- [ ] **Step 3: Verify LAN :22 still works and :52222 is now dropped from LAN**

```bash
ssh -i ~/.ssh/breakglass_ed25519 -p 22 root@192.168.1.127 'echo STILL_OK22'         # works
nc -z -w3 192.168.1.127 52222 && echo "OPEN(bad)" || echo "CLOSED_AS_EXPECTED"      # closed pre-knock
```
Expected: `STILL_OK22` and `CLOSED_AS_EXPECTED`.

### Task 1.5: knockd

**Files:** Create/modify on host: `/etc/knockd.conf`, `/etc/default/knockd`

- [ ] **Step 1: Install knockd (host daemon — must be native, not Docker, to manage host iptables)**

```bash
ssh root@192.168.1.127 'apt-get update -qq && apt-get install -y knockd && echo KNOCKD_INSTALLED'
```
Expected: `KNOCKD_INSTALLED`.

- [ ] **Step 2: Write knockd.conf with the Vault knock sequence (UDP)**

```bash
KNOCK="$(vault kv get -field=breakglass_knock_sequence secret/viktor)"   # e.g. 28411,49027,33180
read K1 K2 K3 <<<"$(echo "$KNOCK" | tr ',' ' ')"
ssh root@192.168.1.127 "cat > /etc/knockd.conf" <<EOF
[options]
    UseSyslog
    Interface = vmbr0

[breakglass]
    sequence      = ${K1}:udp,${K2}:udp,${K3}:udp
    seq_timeout   = 10
    start_command = /usr/sbin/iptables -I INPUT 1 -s %IP% -p tcp --dport 52222 -j ACCEPT
    cmd_timeout   = 30
    stop_command  = /usr/sbin/iptables -D INPUT -s %IP% -p tcp --dport 52222 -j ACCEPT
EOF
```

- [ ] **Step 3: Enable + start knockd**

```bash
ssh root@192.168.1.127 "sed -i 's/^START_KNOCKD=.*/START_KNOCKD=1/' /etc/default/knockd 2>/dev/null || echo 'START_KNOCKD=1' >> /etc/default/knockd"
ssh root@192.168.1.127 'systemctl enable --now knockd && systemctl is-active knockd'
```
Expected: `active`.

### Task 1.6: fail2ban (defense-in-depth)

- [ ] **Step 1: Install + enable fail2ban with the default sshd jail**

```bash
ssh root@192.168.1.127 'apt-get install -y fail2ban && systemctl enable --now fail2ban && fail2ban-client status sshd >/dev/null && echo F2B_OK'
```
Expected: `F2B_OK` (sshd jail active).

---

## Phase 2 — Edge router `.1` forwards (LIVE router change — Viktor executes)

> In the AX6000 UI: **Advanced → NAT Forwarding → Port Forwarding → Add**. Do NOT remove anything yet.

- [ ] **Step 1: Add the SSH break-glass forward**
  - Name `breakglass-ssh`, External Port `52222`, Internal IP `192.168.1.127`, Internal Port `52222`, Protocol `TCP`, Enable.

- [ ] **Step 2: Add the three UDP knock forwards** (values from `vault kv get -field=breakglass_knock_sequence secret/viktor`)
  - For each of the 3 ports: Name `bg-knock-N`, External Port `<port>`, Internal IP `192.168.1.127`, Internal Port `<same port>`, Protocol `UDP`, Enable.

- [ ] **Step 3: (verify #1) Determine whether `.1` preserves source IP or SNATs**

After Phase 3 connects once, on the host check the observed source:
```bash
ssh root@192.168.1.127 'journalctl -u knockd -n 20 --no-pager | grep -i "stage\|open"'
```
If `%IP%` is a public IP → source preserved (per-IP granularity). If it's `192.168.1.1` → `.1` SNATs (knock opens `:52222` for the shared `.1` source during the 30 s window). Both are acceptable with the dual-port + key-only model; just note it in the runbook.

---

## Phase 3 — Client config (laptop, no live infra change)

**Files:** Modify `~/.ssh/config`; add a shell function to `~/.zshrc`/`~/.bashrc`.

- [ ] **Step 1: Add the SSH host block**

```bash
cat >> ~/.ssh/config <<'EOF'

Host breakglass
    HostName viktorbarzin.ddns.net
    Port 52222
    User root
    IdentityFile ~/.ssh/breakglass_ed25519
EOF
```
(`viktorbarzin.ddns.net` is the router's NO-IP DDNS name — follows the dynamic WAN IP. Raw IP `176.12.22.76` is the fallback.)

- [ ] **Step 2: Add the knock+connect function**

```bash
cat >> ~/.zshrc <<'EOF'

bg() {
  local host="viktorbarzin.ddns.net"
  local seq; seq="$(vault kv get -field=breakglass_knock_sequence secret/viktor 2>/dev/null || echo "")"
  [ -z "$seq" ] && { echo "no knock sequence (vault?)"; return 1; }
  for p in ${seq//,/ }; do (exec 3<>/dev/udp/$host/$p) 2>/dev/null && echo "x" >&3; sleep 0.4; done
  sleep 0.5
  ssh breakglass "$@"
}
EOF
```
> Note: the bash `/dev/udp` redirection works under bash (`/bin/bash` on macOS + Linux). Under zsh, `/dev/udp` is also supported by zsh's builtin in recent versions; if your zsh build lacks it, define `bg` in bash or use `nc -u -w1 $host $p </dev/null`.

---

## Phase 4-pre — Verify break-glass END-TO-END (gates Phase 4)

> Do this from an **external** network (phone hotspot / tethered), NOT the home LAN.

- [ ] **Step 1: Without knocking, the port is silent**

```bash
nc -z -w3 viktorbarzin.ddns.net 52222 && echo "OPEN(bad)" || echo "SILENT_OK"
```
Expected: `SILENT_OK`.

- [ ] **Step 2: Knock + connect succeeds**

```bash
bg 'hostname; echo BREAKGLASS_E2E_OK'
```
Expected: the PVE hostname + `BREAKGLASS_E2E_OK`.

- [ ] **Step 3: Full-LAN reach via the jump (no extra install)**

```bash
ssh -J breakglass root@10.0.20.1 'echo PFSENSE_REACHED' 2>/dev/null || echo "check pfSense ssh"
ssh -J breakglass admin@192.168.1.13 'echo SYNOLOGY_REACHED' 2>/dev/null || echo "check synology ssh"
```
Expected: confirms you can reach pfSense + Synology *through* break-glass (so closing Rule 6 loses nothing).

- [ ] **Step 4: LAN admin unaffected**

From the home LAN: `ssh -p 22 root@192.168.1.127 'echo LAN22_OK'` → `LAN22_OK`.

**GATE:** Only proceed to Phase 4 once Steps 1–4 pass. If any fail, fix before removing the legacy forward.

---

## Phase 5 — Router cleanup (LIVE router change — Viktor executes, AFTER Phase 4-pre passes)

> AX6000 UI. One pass, all three changes.

- [ ] **Step 1: Remove the Synology SSH exposure (Rule 6)**
  - Advanced → NAT Forwarding → Port Forwarding → delete (or disable) rule **`HTTP` / 3333 → 192.168.1.13:22**.

- [ ] **Step 2: Delete the stale Proxmox rule (Rule 3)**
  - Delete the disabled rule **`proxmox` / 8006 → 192.168.1.127**.

- [ ] **Step 3: Disable UPnP**
  - Advanced → NAT Forwarding → UPnP → toggle **OFF**. (Tailscale on `.101` falls back to DERP relay; the `41643→pfSense` mapping drops.)

- [ ] **Step 4: Verify the Synology SSH is gone from the WAN, break-glass still works**

From an external network:
```bash
nc -z -w3 viktorbarzin.ddns.net 3333 && echo "STILL_OPEN(bad)" || echo "SYNOLOGY_SSH_CLOSED_OK"
bg 'echo BREAKGLASS_STILL_OK'
```
Expected: `SYNOLOGY_SSH_CLOSED_OK` and `BREAKGLASS_STILL_OK`.

---

## Phase 6 — Docs + commit (AFTER infra repo is clean)

- [ ] **Step 1: Update `docs/architecture/vpn.md`** — add a "Break-glass SSH" section (knock-gated SSH to PVE host, client `bg()`, cheat-sheet IPs).
- [ ] **Step 2: Update `docs/architecture/security.md` + the Wave-1 note in `infra/.claude/CLAUDE.md`** — record the deliberate knock-gated exception; **correct the WAN-exposure inventory** (actual `.1` forwards are qbittorrent/stun/turn→pfSense + the new break-glass; Synology SSH removed; UPnP disabled; Remote Management off).
- [ ] **Step 3: New runbook `docs/runbooks/breakglass-ssh.md`** — connect procedure, knock/key rotation, re-adding `.1` forwards after a router reset.
- [ ] **Step 4: Commit the design + plan + doc updates** (only once Viktor confirms the repo is committable):

```bash
git -C /home/wizard/code/infra add \
  docs/plans/2026-05-30-breakglass-ssh-access-design.md \
  docs/plans/2026-05-30-breakglass-ssh-access-plan.md \
  docs/architecture/vpn.md docs/architecture/security.md \
  docs/runbooks/breakglass-ssh.md .claude/CLAUDE.md
git -C /home/wizard/code/infra commit -m "docs+feat: break-glass knock-gated SSH; retire Synology SSH forward; disable UPnP [ci skip]"
git -C /home/wizard/code/infra push origin master
```

---

## Self-review

- **Spec coverage:** key-only SSH ✅ (1.3), knock gate ✅ (1.4/1.5), invisibility ✅ (4-pre.1), full-LAN via jump ✅ (4-pre.3), no-lockout ✅ (1.1/1.3.4), Wave-1 exception doc ✅ (6.2), close legacy SSH ✅ (5.1), UPnP ✅ (5.3). All design §sections map to a task.
- **Placeholder scan:** no TBDs; secret values are generated + Vault-stored, referenced via `vault kv get` (concrete, not placeholders).
- **Consistency:** port `52222`, knock from `secret/viktor/breakglass_knock_sequence`, key `~/.ssh/breakglass_ed25519`, host `192.168.1.127` used consistently throughout.
- **Open verify items** (flagged inline, non-blocking): #1 `.1` SNAT behaviour (2.3), pve-firewall coexistence (1.1.2).
