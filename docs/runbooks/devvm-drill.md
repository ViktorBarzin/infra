# devvm drill: build a throwaway devvm from Terraform

The disposable-devvm plan (`docs/plans/2026-11-11-disposable-devvm.md`) says the
devvm must be rebuildable from code, and a drill proves it every few months:
build a second devvm from the Terraform definition, log in, check what came
back, delete it. This runbook is how.

## The pieces

| Piece | Where | What it does |
|---|---|---|
| VM definition | `modules/proxmox-devvm` | One VM with the live devvm's shape (32 cores, 32 GiB, 228 GiB scsi0 capped 60/60 MB/s, vmbr1 VLAN 10, guest agent), a static address and the admin's keys on the cloud-init drive. Refuses the live name, VMID 102, 10.0.10.10 and its MAC unless `allow_live_identity = true`. |
| Stack | `stacks/devvm` | `local.drills` lists the drill VMs. Empty means the stack holds only the pinned Ubuntu image (~600 MB in `local`), kept because deleting it would need a wider grant. Standalone terragrunt (bpg/proxmox as `proxmoxbpg`, like `stacks/opnsense`). |
| Token | Vault `secret/devvm` `pve_api_token` | `terraform-devvm@pve!tf`, role `TFDevvm` on `/pool/devvm`, the VMID slots `/vms/9100`-`/vms/9109`, and storage, network and node paths. PVE checks `/vms/<id>` during create, before the VM joins the pool, so a drill needs a slot. VM 102 is neither, so the token gets 403 on it. Declared by `playbooks/pve-host.yml --tags devvm-tf`. |
| Slot grants | `pve-devvm-tf-acl.timer` on the host | Every VM destroy deletes the ACLs on its `/vms/<id>`, purge or not, so each teardown takes its slot grant with it. `scripts/pve-devvm-tf-acl` puts the grants back every minute, for the VMIDs in `pve_devvm_tf_vmids` (`pve-host.yml`), and never for a VMID that holds a guest outside pool `devvm`. |
| Snippet | `/var/lib/vz/snippets/devvm_bootstrap.yaml` | Vendor data for every Terraform devvm. Rendered by `pve-host.yml --tags snippets` from `playbooks/files/pve/snippets/devvm_bootstrap.yaml.j2`, embedding `scripts/devvm-bootstrap`. |
| Handoff | `scripts/devvm-drill-handoff` | Runs on the applier after the VM is up: mints a wrapped token through Vault token role `devvm-bootstrap` and writes it into the guest through the guest agent. For the replacement (`allow_live_identity`, or a drill's `live_host_keys` test) the token also carries policy `devvm-host-identity` and the handoff says `host_keys: true`. |
| First boot | `scripts/devvm-bootstrap` | In the guest: unwraps the token, on the replacement swaps the first-boot SSH host keys for the live devvm's (Vault `secret/workstation/devvm/ssh-host-keys`) and tells cloud-init never to regenerate them, clones infra at `infra_ref`, runs `playbooks/devvm.yml` locally, copies the users' T3 snapshots from the host's `/mnt/backup/t3-state` (key Vault `secret/devvm-t3-seed`, read-only on the host), runs `t3-provision-users` once, revokes the token, writes `/var/lib/devvm-bootstrap/status`. |

The Vault side (`stacks/vault`): policy `devvm-bootstrap` reads exactly the
paths `playbooks/devvm.yml` reads (`secret/claude-sessions`, `terminal-lobby`,
`terminal-lobby/vapid`, `devvm-authorized-keys`, `rybbit`, `glitchtip`, `agentmd`), plus
`secret/devvm-t3-seed` for the bootstrap's T3 snapshot copy; the token role makes
orphan, non-renewable tokens with a 4 h hard limit; CI's policy may create
tokens through that role and nothing else. Policy `devvm-host-identity` reads
the live devvm's SSH host keys, `secret/workstation/devvm/ssh-host-keys`; the
role allows it, but the handoff asks for it only for the replacement, so a
drill's token cannot read them. `ci`, `eso-reader`, `openclaw-k8s` and
`terraform-state` deny `secret/data/workstation/devvm/*`. When the playbook starts reading a
new Vault path, add it to the policy, or a fresh build fails at that task.

## Before a drill

1. Host RAM. The live devvm alone is 32 GiB; the host had 45 GiB available on
   2026-11-11 with swap in use. Size the drill to fit:
   `ssh root@192.168.1.127 free -g`. 4 cores, 8 GiB and 80 GiB build fine;
   the playbook scales its memory caps to the box.
2. Pick a free VMID in 9100-9109 (other IDs get 403 at create) and an address below VLAN 10's DHCP pool (.100-.254)
   that nothing answers on: `ping -c1 10.0.10.11`. Not 10.0.10.10. The slot
   must hold its grant: `ssh root@192.168.1.127 'pveum user permissions
   "terraform-devvm@pve!tf" --path /vms/<id>'` lists `VM.Allocate`. A slot
   freed less than a minute ago may not have it back yet.
3. If `scripts/devvm-bootstrap` or the snippet template changed since the last
   run, re-render the snippet (claim `host:pve` first):
   `ansible-playbook -i playbooks/inventory.ini playbooks/pve-host.yml --tags snippets --check --diff`, then without `--check`.

## Run it

1. Add the drill to `local.drills` in `stacks/devvm/main.tf`:
   ```hcl
   drills = {
     "devvm-drill" = { vm_id = 9102, ipv4_cidr = "10.0.10.11/24" }
   }
   ```
   Left out, `cores`, `memory_mb` and `disk_gb` are 4, 8192 and 80 in a
   drill entry, not the live box's 32, 32768 and 228.
   `infra_ref = "<branch>"` builds from a branch instead of master.
2. Land it. CI applies the stack: it downloads the pinned Ubuntu image, creates
   the VM in pool `devvm`, waits for the guest agent and hands over the token.
   An admin may instead run `homelab tf apply devvm` from the main checkout.
3. Watch the build (20-60 min; most of it is the playbook):
   ```sh
   ssh wizard@10.0.10.11 'cat /var/lib/devvm-bootstrap/status; sudo tail -f /var/log/cloud-init-output.log'
   ```
   `ok` means the playbook and the provisioner finished.
   `ok (T3 held: snapshots not copied from the Proxmox host)` means the same,
   but the T3 snapshot copy failed, so every user without a database has T3
   stopped until the snapshots arrive (backup-dr.md, "T3 snapshots", copy by
   hand). `failed: <step>`
   names the step; the log above has the detail. `cloud-init status --long`
   shows the same result from cloud-init's side.

## What to check

- `ssh wizard@<address>` works with your usual key, and `sudo -n true` works.
- Each roster user's T3 serves: `systemctl is-active t3-serve@wizard
  t3-serve@emo` prints `active` twice, and `ls -l /usr/bin/t3` points into
  `/usr/local/lib/t3/<ver>`. The playbook puts the first build in through
  `t3-autoupdate`; before 2026-11-11 it did not, and every serve died with
  `203/EXEC`.
- Run provisioning once with an admin token, as in `devvm-credentials.md`,
  "Rebuild: put a user's credentials back", started from `/` (`cd /`
  first). chezmoi runs as each user in the caller's directory and stops
  with `stat .: permission denied` in a home that user cannot read, so a
  run started in wizard's home leaves emo's dotfiles to the next hourly run
  (drill 6). The bootstrap's own run has only
  the bootstrap token, which cannot read `secret/workstation/*`, so it skips
  every credential and every clone that needs one. Then check, as root:
  `ls /home/wizard/.vault-token /home/emo/.vault-token`; `ls /home/emo/code`
  lists `tv`, `agents`, `app-kit` and `vermont-device-configs`; and
  `readlink /home/emo/bin/hikreboot.py` points into
  `~/code/vermont-device-configs/bin/` (his repo's `devvm-setup.sh` ran; since
  2026-11-12 it installs no timer, the B4 watchdog runs on ha-sofia). On a drill this means handing the drill an admin
  token; skip it there unless the drill is the final one, and record that
  you did. On a drill, give it a child token of your own instead of your
  periodic one (`vault token create -policy=vault-admin -policy=sops-admin
  -ttl=3h -display-name=devvm-<drill>-admin -field=token`, written straight
  to a 0600 file and copied to the drill's `~wizard/.vault-token`), and
  before the run stop what would write shared state from a second box:
  `systemctl mask` `claude-auth-sync@wizard` and `@emo` (timer and service:
  a second holder of the shared Claude OAuth refresh tokens could rotate
  them under the live box), `systemctl disable --now codex-auth-backup.path
  codex-auth-backup.timer`. The run also unlocks wizard's `~/code/infra`
  with the git-crypt key, but only on 10.0.10.10: a drill keeps the key off
  its disk and logs `not the live devvm: wizard:~/code/infra stays locked`.
  To test the unlock on a drill, opt in before the run with `sudo touch
  /var/lib/t3-provision/drill-unlock-infra`, then check it as wizard
  (`devvm-credentials.md`, the unlock check): `head -c 10
  ~/code/infra/config.tfvars | grep -qa GITCRYPT && echo locked || echo
  unlocked` prints `unlocked`. The key then sits in that drill's
  `~wizard/code/infra/.git/git-crypt/keys/default` until the VM is
  destroyed. Before deleting the drill,
  revoke every token the run minted, as root on the drill, reading each
  file inside the command: `emo`'s `~/.vault-token` and both
  `~/.config/claude-auth-sync/vault-token` files (`vault token revoke
  -self`), then your child token by accessor.
- The playbook converged: rerun it on the drill from the main checkout,
  check mode, with an inventory line for the drill address. Expect no
  changes beyond the ones the live box also shows.
- Per the plan, as each workstream lands: log in as each roster user (wizard,
  emo) through `sudo -iu <user>`; work comes back from Forgejo, agent
  state from the session store, T3 threads from the nightly snapshot,
  credentials from Vault `workstation/<user>`. Vermont checks are out of scope
  for a drill.
- ancamilea is parked (her `roster.yaml` row is commented out since
  2026-08-17), so a rebuilt box has no account for her and nothing is
  restored into one. Her `~/.claude` and `~/.codex` are in the session store;
  check they are there with `homelab claude-sessions sql "SELECT count() FROM
  claude.home_files FINAL WHERE os_user = 'ancamilea'"`. Giving her an account
  on a rebuild means bringing her roster row back.
- Agent state: `sudo ls /var/lib/claude-sessions-ingest/restored/` lists each
  user once provisioning step 4a has restored them, and `claude --resume` as
  each user lists their sessions. `~/.claude/settings.json` is the user's own
  (statusLine, enabledPlugins, env flags) with the memory keys filled from
  Vault, not a hooks-only skeleton. `jq '.mcpServers | keys' ~/.claude.json` lists the
  user's MCP servers, `claude mcp list` shows them connected after the admin
  run's `mcp-secrets fill` (`sudo ls /var/lib/claude-sessions-ingest/mcp-filled/`
  lists each user it ran for), wizard's `~/.local/bin/uvx` and
  `~/.local/share/phpipam-mcp/bin/phpipam-mcp-server` exist (step 4a3), a
  `google_workspace` tool call such as `list_calendars` returns data, and
  `claude` in a project the user trusted on the
  live box starts without the trust prompt. The drill must read the store and never
  write to it: no `/etc/claude-sessions/ingest.env`,
  `claude-sessions-ingest.timer` disabled, and after the drill no rows from
  its time window that the live ingest's journal does not account for:
  `homelab claude-sessions sql "SELECT toStartOfMinute(ingested_at) m,
  os_user, count() FROM claude.home_files WHERE ingested_at > now() - INTERVAL
  2 HOUR GROUP BY m, os_user ORDER BY m"` against `journalctl -u
  claude-sessions-ingest` on 10.0.10.10. The 2026-11-11 drill failed this
  (drill log).
- The drill's journal reaches Loki as `{job="devvm-drill-journal",
  host="<drill name>"}`, sshd lines included. Every devvm alert, the TLEVENT
  dashboard and the crowdsec sshd source select on `job="devvm-journal"` or
  `job="sshd-devvm"`, so nothing from the drill reaches them:
  `homelab logs query '{job="devvm-journal", host!="devvm"}' --since 1h`
  returns nothing. Until 2026-11-11 a drill shipped as `job="devvm-journal"`;
  drill 3's `claude-auth-sync` FAIL lines fired
  `WorkstationClaudeAuthInvalid` for wizard and emo for the rule's 7 h window
  while the live box logged OK.
- The drill does not take over anything of the live devvm's: Traefik, DNS and
  the DHCP reservation all point at 10.0.10.10, so the lobby and T3 on the
  drill are reachable only on its own address.

## Tear it down

Remove the entry from `local.drills` and land it. CI stops and destroys the
VM. The destroy deletes the token's ACL on that `/vms/<id>`;
`pve-devvm-tf-acl.timer` on the host re-grants it within a minute. The Ubuntu
image stays in `local` for the next drill.
Check: `ssh root@192.168.1.127 'qm list'` shows no 91xx VM, and
`ssh root@192.168.1.127 pve-devvm-tf-acl --dry-run` prints nothing (every slot
granted).

## When it goes wrong

- **Apply fails waiting for the guest agent.** cloud-init could not install
  `qemu-guest-agent`, usually no network: the address is taken, or the gateway
  or DNS is wrong. Open the console with `qm terminal <vmid>` on the host.
- **`failed: no handoff`.** The handoff never wrote the file. Check the apply
  log for `[devvm-drill-handoff]`. A re-run: `terraform apply -replace` on the
  drill's `terraform_data.handoff`, or remove and re-add the drill.
- **`failed: unwrap`.** The wrapped token was used already or expired (1 h). If
  nobody retried, someone else unwrapped it: rotate nothing yet, look at the
  Vault audit log for `sys/wrapping/unwrap` around the time.
- **`failed: playbook`.** A playbook bug on a fresh box, which is what the
  drill is for. Fix it in `playbooks/devvm.yml` and rebuild.
- **A CI apply was killed mid-create** (a later push supersedes the
  pipeline; the next pipeline diffs from the killed push, so it does not
  re-apply this stack). The VM exists on the host but not in state, and the
  next apply fails on the taken VMID. Destroy the orphan
  (`qm stop <vmid>; qm destroy <vmid>` on the host, drill VMs only), wait a
  minute for the timer to re-grant the slot, and land any change under
  `stacks/devvm` to re-apply. An admin apply from the main checkout avoids
  the race.
- **403 `Permission check failed (/vms/<id>, ...)` at create.** The slot has
  no grant: it is not in `pve_devvm_tf_vmids`, the timer has not run since
  the last destroy (a VM replaced in one apply hits this: wait a minute and
  re-apply), or a guest outside pool `devvm` holds that VMID
  (`journalctl -u pve-devvm-tf-acl` on the host says `skip`).
- **403 from Proxmox in the apply.** `TFDevvm` lacks a privilege for something
  new; add it to the list in `pve-host.yml` and rerun `--tags devvm-tf`.

## Building the real replacement

Before touching VM 102, take everything the rebuild restores from as late as
possible. Each of these runs on its own schedule, and the newest copy is what
comes back:

1. Tell the users, and wait until nobody has a session running.
2. On the devvm: `sudo systemctl start t3-backup-state.service`, then
   `sudo systemctl start claude-sessions-ingest.service`; both journals end
   with a success line. Re-capture any credential rotated since its last
   capture (`devvm-credentials.md`, "Add or refresh a credential"), and each
   user's MCP server secrets (`devvm-credentials.md`, "MCP server secrets");
  `journalctl -u claude-sessions-ingest -n 1` shows `mcp_uncaptured=0
  mcp_unfilled=0`.
3. On the host: `systemctl start t3-state-pull.service`;
   `ls -l /mnt/backup/t3-state/*/` shows a snapshot from the last hour per
   user.
4. Push work: for every user's clone under `/home/*/code`, `git status
   --porcelain` is empty and `git log @{u}..` prints nothing, or the owner has
   said what can go.

The token cannot create VMID 102 until it holds the slot, and PVE deletes any
`/vms/102` ACL when 102 is destroyed, so the grant has to come after. Keep the
old disk until the new box passes "What to check":

1. As root on the host: `qm shutdown 102`, then park its disk on a holding VM
   outside every slot and pool, and only then destroy 102:
   ```sh
   qm create 9190 --name devvm-old --memory 512 --description "VM 102's disk, kept until the replacement passes its checks"
   qm disk move 102 scsi0 --target-vmid 9190 --target-disk scsi0
   qm config 9190 | grep scsi0    # vm-9190-disk-0, 228G
   qm destroy 102
   ```
   If the new box fails, `qm disk move 9190 scsi0 --target-vmid <a new 102>`
   puts the old disk back. Destroy 9190 only once the replacement is
   accepted.
2. Add 102 to `pve_devvm_tf_vmids` in `playbooks/pve-host.yml`, land it, and
   run `pve-host.yml --tags devvm-tf` (claim `host:pve`, `--check --diff`
   first). The timer then keeps the grant. While a VM 102 outside pool
   `devvm` exists the script refuses to grant it, so landing this step early
   grants nothing.
3. Check: `pveum user permissions "terraform-devvm@pve!tf" --path /vms/102`
   lists `VM.Allocate`.

Then add an instance with the live identity
(`name = "devvm"`, `vm_id = 102`, `ipv4_cidr = "10.0.10.10/24"`,
`mac_address = "00:0c:29:c0:89:ec"` so the DHCP reservation and every
neighbour cache still match, `allow_live_identity = true`) and the full size
(`cores = 32, memory_mb = 32768, disk_gb = 228`; a drill entry defaults to
4, 8192 and 80). With `allow_live_identity` the VM carries PVE's protection
flag, so an apply that drops the entry or forces a replacement fails instead
of destroying the box. To take it down on purpose, root runs `qm set 102
--protection 0` first.
Once the bootstrap says `ok`, run provisioning with an admin token
(`devvm-credentials.md`, "Rebuild: put a user's credentials back") and go
through "What to check" above, including the T3 and emo items. That run
also unlocks wizard's `~/code/infra` (the box is on 10.0.10.10, so no
opt-in is needed); its log says `unlocked wizard:~/code/infra`, and
`head -c 10 ~/code/infra/config.tfvars | grep -qa GITCRYPT && echo locked
|| echo unlocked` prints `unlocked`. Nothing else is done by hand after the
Vault sign-in.

The new box keeps the live devvm's SSH host keys, so nobody runs
`ssh-keygen -R` or `ssh-keyscan`: the Proxmox host's `t3-state-pull` and every
user's ssh client go on trusting 10.0.10.10. With `allow_live_identity` the
handoff gives the bootstrap a token that reads Vault
`secret/workstation/devvm/ssh-host-keys`, and right after the unwrap it checks
each private key against its `.pub`, installs them in `/etc/ssh`, writes
`/etc/cloud/cloud.cfg.d/99-devvm-host-keys.cfg` (`ssh_deletekeys: false`,
`ssh_genkeytypes: []`, so a later change to the VM's cloud-init settings,
which gives the next boot a new instance-id, does not regenerate them) and
restarts sshd. The keys are fetched by the guest rather than put on the
cloud-init drive because a Terraform-supplied key would sit in this stack's
Tier 1 state, which is not encrypted and which every holder of the
`pg-terraform-state` creds can read, and in the drive's ISO on the host.

For the first few minutes after boot, until the handoff arrives, sshd
answers with the keys cloud-init made. A client that has the live key pinned
refuses those with `REMOTE HOST IDENTIFICATION HAS CHANGED`; that is the
window, not a reason to remove the pinned key. Wait for the status to move
past `installing the live devvm's SSH host keys`. Checks:

- Before step 1 above, on the live box: the Vault copy is the live one,
  `vault kv get -field=ssh_host_ed25519_key.pub
  secret/workstation/devvm/ssh-host-keys | ssh-keygen -lf -` prints the same
  fingerprint as `ssh-keygen -lf /etc/ssh/ssh_host_ed25519_key.pub`. If the
  live keys were ever regenerated, capture them again (below).
- After the build: `ssh-keyscan 10.0.10.10 | ssh-keygen -lf -` prints the
  fingerprints recorded below, the same ones `ssh root@192.168.1.127
  'ssh-keygen -F 10.0.10.10 -l'` shows the host pinning (checked
  2026-11-12), and `systemctl start t3-state-pull.service` on the host ends
  without a host-key error.
- A status ending `(host keys not installed: ...)` means the read or the
  check failed and the box kept its first-boot keys; the log above says
  which key. Install them by hand as root on the new box: read each field of
  the secret into `/etc/ssh/<field>` (mode 600 for the private keys, 644 for
  the `.pub`), write the cloud-init drop-in above, `systemctl restart ssh`.

Fingerprints of the live devvm's keys, captured 2026-11-12 (version 1 of the
secret): ED25519 `SHA256:r1N+5R/BFK4AsnlDIUWmO3kzEA/AX4xZdX5kpU1hKL8`, ECDSA
`SHA256:dDyXeaVDjoYGHGmasqpgDEq2M4TKfiFFqrSHWiweVvo`, RSA 3072
`SHA256:ZRwm1gJvJ8rkjkf0QlYZGIjPu/Dq0DrvhYe9XlG9Nkk`. The 2023 DSA key in
`/etc/ssh` is not captured: sshd does not load it. To capture again, as an
admin on the live box, reading the token inside sudo so no secret reaches the
command line:

```sh
sudo bash -c 'cd /etc/ssh && VAULT_ADDR=https://vault.viktorbarzin.me VAULT_TOKEN="$(cat "/home/$SUDO_USER/.vault-token")" exec vault kv put -mount=secret workstation/devvm/ssh-host-keys ssh_host_ed25519_key=@ssh_host_ed25519_key ssh_host_ed25519_key.pub=@ssh_host_ed25519_key.pub ssh_host_ecdsa_key=@ssh_host_ecdsa_key ssh_host_ecdsa_key.pub=@ssh_host_ecdsa_key.pub ssh_host_rsa_key=@ssh_host_rsa_key ssh_host_rsa_key.pub=@ssh_host_rsa_key.pub'
```

To test the host-key path without touching VM 102, give a drill entry
`live_host_keys = true`: it installs the live keys on the drill's own
address and nothing else of the live identity. Compare `ssh-keyscan
<drill address> | ssh-keygen -lf -` with the fingerprints above, then take
the flag off (or the whole entry) and land again; a drill must not keep the
live identity's keys.
`stacks/devvm` drills pass `on_boot = false`; the replacement wants the module
default `true`, and boot order stays in `playbooks/reboot-boot-order.yml`.

## Drill log

**2026-11-11, first drill** (devvm-drill, VM 9102, then devvm-drill2, VM
9103). Found and fixed on the way:

- A pool ACL alone gets 403 at create (`/vms/9102, VM.Config.Options`): PVE
  checks the VM's own path before the VM joins the pool. The token now also
  holds the VMID slots 9100-9109.
- The guest agent creates the handoff file 0666; it now lands in the
  root-only `/run/devvm-bootstrap`.
- `playbooks/devvm.yml` failed on a blank box five times: three
  retire/restart tasks for units a new box never had, and two copies into
  directories the cloud image lacks (`/etc/systemd/resolved.conf.d`,
  `/etc/promtail`). After the fixes the playbook ran clean on the drill and a
  second run reported 256 ok, 0 changed.
- Destroying a VM deletes the ACLs on its `/vms/<id>`, so the slot grant
  went with it and the next apply got 403 refreshing the old VM. This
  drill's first diagnosis blamed purge and switched the module to destroy
  without it; that was wrong. PVE 9.2.21 calls `remove_vm_access` on every
  destroy, and drill 2's plain teardown removed `/vms/9103` too (found in
  review). The slots are now re-granted by `pve-devvm-tf-acl.timer` on the
  host.
- **A drill wrote to the session store.** A drill's playbook ran before the
  10.0.10.10 gate on the ingest landed, so the box had `ingest.env` and a
  running timer, and once provisioning had built `homelab` its 15:30 run sent 29
  `home_files` rows for wizard and emo: the drill's `settings.json`,
  `settings.local.json`, `installed_plugins.json`, hooks, and files wizard had
  deleted long ago (`statusline.sh`, `openclaw-install.sh`, `claude-memory/`).
  `FINAL`, and so a restore, returned those over the live box's copies. The
  rows were deleted by their two `ingested_at` values on the same day, before
  a merge dropped the live rows, and `FINAL` showed the live 3062 B and
  3997 B `settings.json` again. Since then the ingest unit also has an
  `ExecCondition` on 10.0.10.10.
- cloud-init's runcmd has no HOME, and the playbook's go build of
  t3-dispatch fails without one; the bootstrap now sets `HOME=/root`. With
  that, a rerun of the bootstrap on devvm-drill2 under a service with no HOME
  ran the playbook clean (292 ok, 0 failed).
- The teardown could not delete the Ubuntu image: that needs
  Datastore.Allocate on `local`, which would let the token delete every backup
  and ISO there. The image now stays between drills.
- terminal-lobby is installed by its deploy pipeline on the live box; the
  bootstrap now installs it from the public registry after the playbook. All
  seven lobby units came up.

Result on devvm-drill2 after the fixes: bootstrap status `ok`; wizard and emo
log in, sudo works, emo's `~/.claude` came back from the session store, every
user's T3 database from the Proxmox host copy (restored to disk; no T3
served them, see the review of drill 3 below), and six of the seven lobby
units are active. Both drill VMs were then removed.

**2026-11-11, third drill** (devvm-drill3, VM 9103, 10.0.10.12, 4 cores,
8 GiB, 80 GiB), built by CI from master with no manual step, in the slot
the second drill's teardown had emptied (re-granted by the new timer):

- 16:09 apply, 16:13 handoff unwrapped, 16:14-16:35 playbook (314 ok,
  0 failed), 16:37 terminal-lobby, 16:57 bootstrap status `ok`.
  `cloud-init status --long`: `done`, `errors: []`; the `degraded` flag is
  only the deprecated `user` key in the user data Proxmox generates.
- wizard logs in with the usual key and `sudo -n true` works; emo's
  account exists, without his repos or credentials (below).
  Both restore markers are there, `history.jsonl` came back (wizard 13,154
  lines, emo 4,273), 184 and 4 project folders against 181 and 4 projects
  in the store, and both T3 databases came from the host copy, but no
  `t3-serve@` ever started (below).
- Lobby units ttyd, clipboard-upload, tmux-api, session-events, file-api and
  skills-api active; agent-api restarting, as expected off 10.0.10.10.
- The session store got nothing from it: no `ingest.env`, the timer off,
  and no `home_files` rows after 16:20 while the live ingest sent none.
  Its journal reached Loki as `host="devvm-drill3"`.
- Failed units: `claude-auth-sync@wizard` and `@emo` (no Claude auth
  tokens without an admin Vault token, below), and one hourly
  `t3-provision-users.service` run at 16:32 that fired during the playbook,
  before the bootstrap had cloned wizard's infra; a manual start after the
  build succeeded.
- promtail had no `/var/lib/promtail` for its positions file; the playbook
  now creates it.

Found in review of drill 3, fixed afterwards:

- No T3 served on it. `t3-serve@wizard` and `@emo` exited `203/EXEC` 30
  times: `/usr/bin/t3` did not exist, because only `setup-devvm.sh` ever
  installed t3 and the bootstrap does not run it. The databases were
  restored but nothing served them. `t3-autoupdate` now does a first install
  on a box with no t3, and `playbooks/devvm.yml` runs it once.
- Rehearsing that first install on the live box set off a false page. The
  run used a scratch `T3_LINK` but read the live `/usr/bin/t3` as its own
  version, so at 17:11 it logged `rolling back` and `ROLLBACK FAILED` into
  the live journal: `T3AutoUpdateRollbackFailed` paged and
  `T3AutoUpdateRolledBack` would have stayed firing through the 0.1.9 bump the
  next morning. The live state was untouched (`last-good` 0.1.8,
  `/usr/bin/t3` on 0.1.8, no freeze file, no 0.1.9 pre-bump backups). A
  scratch link now reads its own version and never runs `npm -g` or restarts
  a serve, and the three rules count only lines from the t3 systemd units
  (`docs/runbooks/t3-version-bump.md`).
- Its journal still drove live alerts: the host label was its own, but every
  rule selects on `job`. `WorkstationClaudeAuthInvalid` fired for wizard and
  emo from drill FAIL lines (drill 2 at 14:22, 15:02 and 15:43 as
  `host="devvm"`, drill 3 at 17:03) while the live box logged OK. Drills now
  ship as `job="devvm-drill-journal"`.
- emo's three repos were not cloned (`clone of ebarzin/vermont-device-configs
  failed for emo`, the same for `ebarzin/agents` and `tv`), so his `~/bin`,
  the Hikvision SDK and the intercom watchdog did not come back, and no user
  got a `~/.vault-token` or a kubeconfig. All of it waits on credentials from
  `secret/workstation/*`, which the bootstrap token cannot read. "What to
  check" and the replacement now include the admin re-run.

**2026-11-11, fourth drill** (devvm-drill4, VM 9104, 10.0.10.13, the
drill defaults 4 cores, 8 GiB, 80 GiB), to check those fixes, built by CI
from master:

- 17:25 apply, 17:49 the playbook's first t3 install (`/usr/bin/t3` ->
  `/usr/local/lib/t3/0.1.9/...`, last-good 0.1.9), 18:26 status `ok`,
  `cloud-init status` done.
- `t3-serve@wizard` and `@emo` active with 0 restarts, both answer 200 on
  3773 and 3774, and wizard's serve logged "T3 Code server is ready" on the
  restored database. The restored databases hold 2,342 and 7 threads against
  2,408 and 7 on the live box: the snapshot was the 03:47 nightly, so the 66
  threads since then are what a rebuild without the replacement pre-flight
  would lose.
- Its journal is in Loki only as `{job="devvm-drill-journal",
  host="devvm-drill4"}`; no line from it is under `job="devvm-journal"`.
  Its two `claude-auth-sync` failures stayed in the drill job, so they add
  nothing to `WorkstationClaudeAuthInvalid`, which was still firing from
  drill 3's 17:03 lines until they leave the rule's 7 h window.
- Not checked here: the admin provisioning re-run, which would need an admin
  token on the drill.

Still open after these drills, for the final one:

- `agent-api` binds 10.0.10.10 and exits on any other address, so it fails on
  a drill by design of its config; a rebuild at 10.0.10.10 is unaffected.

- wizard's unlocked `~/code/infra` is not cloned on a new box, so the hourly
  `t3-provision-users.service` fails ("roster/engine not under
  /home/wizard/code/infra/scripts/workstation"). The one-off run from the
  bootstrap clone works. Fixed after this drill: that run now clones it,
  locked, from Forgejo (`install_admin_infra_clone`), and since 2026-11-12
  the admin provisioning run unlocks it (`unlock_admin_infra_clone`,
  `devvm-credentials.md`).
- `claude-sessions-ingest.service` fails with 203/EXEC: the program it runs is
  not installed by the playbook on a new box. Since 2026-11-11 a drill does not
  run the ingest at all (only 10.0.10.10 does, `playbooks/devvm.yml` 8d and the
  unit's `ExecCondition`), so
  this matters only for the real replacement, where provisioning step 0b
  builds `/usr/local/bin/homelab`.
- Provisioning runs without an admin Vault token, so per-user Vault tokens,
  Claude-auth tokens, memory keys, browser-bridge tokens and the credential
  restore from `secret/workstation/<user>` are skipped with warnings. The
  bootstrap policy covers only the playbook's reads; the final drill needs
  either a wider policy or an admin re-running provisioning after
  `vault login`.

**2026-11-11, fifth drill, the plan's final one** (devvm-drill5, VM 9105,
10.0.10.14, drill defaults), built by CI from master after all eight
workstreams had landed, then checked per user with the admin provisioning
re-run (a 3 h child token, with the safety steps in "What to check"):

- 18:50 VM up, 19:11 first t3 install, 19:20-19:45 restores from the
  session store (wizard 8,164 files, 6.96 GB in 756 s; emo 671 files,
  0.97 GB in 91 s), 19:46 status plain `ok`: 56 minutes, playbook 316 ok,
  0 failed. The admin run took 47 s and ended `reconcile complete`; a
  later hourly run succeeded too.
- Passed: credentials (wizard 44 and emo 19 files, names, modes and owners
  identical to the live homes; content identical except the comment lines
  of `~/.config/sops/age/keys.txt`, which is a Vault ref; `kubectl get
  nodes` lists 6, `gh auth status`, Forgejo SSH, both GPG secret keys,
  emo's minted Vault token); repos (emo's `tv`, `agents`, `app-kit`,
  `vermont-device-configs`; wizard's locked `~/code/infra`; a private
  clone over SSH and HTTPS); dotfiles (chezmoi applied, its status shows
  the same drift pattern as on the live box); `~/.claude` (`settings.json`
  is the same JSON as the live file for both users, history 13,154 and
  4,273 lines as live, and `claude --resume` lists recent sessions for
  both); T3 (wizard 2,342 threads, exactly the live threads created before
  the 03:47 snapshot, emo 7 of 7, both serves active and answering 200);
  user units (wizard lobby-local, tmux-plugin-update, agents-sync,
  vault-token-renew; emo vault-token-renew and intercom-watch enabled);
  `/tmp` tmpfs, journal in `/run/log/journal`, `vapid.env`; no rows in the
  session store beyond the live ingest's own; drill logs only under
  `job="devvm-drill-journal"`; the playbook in check mode against the drill
  changed only the two `codex-auth-backup` units this drill had disabled.
- Not checked: Vermont (out of scope), the infra unlock (kept the git-crypt
  key off a throwaway disk), a Claude login (claude-auth-sync masked, see
  above).

Gaps it found, none fixed in the drill itself:

- **MAJOR: no terraform.** The playbook declares the HashiCorp apt source
  but installs only Docker and kubectl from the third-party sources; the
  live box's terraform 1.15.4 was installed by hand. `homelab tf` and
  `scripts/tg` cannot run on a rebuilt box. Fixed 2026-11-11 after the
  drill: the playbook installs terraform 1.15.4-1 and vault 2.0.1-1 from
  that source and fetches terragrunt 0.77.20 and sops 3.9.4 by checksum,
  the versions installed system-wide on the live box (`devvm_terraform_version`
  and the lines after it). wizard's login shell resolves a hand-built
  `~/go/bin/sops` 3.12.1 ahead of `/usr/local/bin/sops`; the home backup
  skips `~/go`, so a rebuilt box runs 3.9.4, CI's version, for everyone.
  Round 2 review: `scripts/devvm-bootstrap` installed the newest vault
  (2.2.1-1) before the playbook, and the playbook's `vault=2.0.1-1` then
  failed on the downgrade. The bootstrap now installs the version it reads
  from `devvm_vault_version` in the cloned playbook. Not yet drilled.
- **MAJOR: emo's agent instructions never come back.** The bootstrap's
  provisioning run creates `/var/lib/t3-provision/agent-repos/emo.git`
  before the admin infra clone exists, so as root; every later fetch runs
  as wizard, gets `Permission denied` on `FETCH_HEAD`, and logs `fetch of
  ebarzin/agents failed` every hour. `~emo/.agents/AGENTS.md` (62 KB on the
  live box, the target of his `~/.claude/CLAUDE.md`) stays missing.
  Fixed after the drill: the fetches belong to the first admin when the
  run's clone is root's (`resolve_agents_owner`), and a fetch owned by
  anyone else is made again.
- **MAJOR: emo's shell setup has no kept place.** His roster row has no
  dotfiles repo, so `.zshrc`, `.zshenv`, `.zprofile`, `.tmux.conf.local`
  and `.tmux` are lost. Without his `.zshrc`, `~/.local/bin` is not on his
  zsh PATH, `claude` resolves to `/usr/local/bin/claude`, a link into
  wizard's home, and that home is 0750 on a new box (0751 on the live one),
  so his shell prints `permission denied: claude`. T3 is unaffected: its
  unit's PATH falls through to `~/.local/bin`. Fixed after the drill: his
  row has `dotfiles: ebarzin/dotfiles` (`devvm-credentials.md`, "Dotfiles").
- **MAJOR, known: `~/.claude.json` is not restored.** wizard loses the
  `google_workspace` MCP server and 454 project entries, emo the
  `paperless` MCP server; the first `claude` shows the onboarding and the
  folder trust prompt. Fixed after this drill: the store keeps a reduced
  `~/.claude.json` (project trust, user-scope MCP servers, the onboarding
  flags), restore writes it back or merges it into one provisioning wrote
  first, and the MCP secrets it leaves out come back from Vault
  `secret/workstation/<user>/mcp` in provisioning step 4a2
  (`claude-session-store.md`). Checked on the live box into scratch homes
  (`devvm-credentials.md`, "MCP server secrets"); not yet drilled on a VM.
  A review then found that `google_workspace` and the Codex `phpipam`
  server start programs under `~/.local` and read OAuth files that nothing
  kept. Step 4a3 now installs those programs, the OAuth files are in Vault,
  and a mount-namespace check with all of them hidden got calendars back
  through the restored config.
- MINOR: emo is in `docker` on the live box by hand; the roster gives
  `docker` to admins only, so a rebuild drops it. A decision, since that
  group is root-equivalent. Viktor decided he keeps it: his row has
  `extra_groups: [docker]`.
- MINOR: skills come back only when `claude-skills-update.timer` fires
  (05:45 daily); provisioning does not start it. After a manual run wizard
  still lacks `unslop` and emo `cluster-health` and his 20
  `~/.agents/skills` folders. Since the drill provisioning starts it once
  per box, when every user's `~/.claude` is back; the missing skills are a
  separate gap.
- MINOR: wizard's `ios-rig-doctor.timer`, `ios-rig-tunnel.service` and
  `ios-rig-wifi.service` come back only through `homelab ios bootstrap
  --units-only` (`ios-test-rig.md`), which no rebuild step runs. Since the
  drill provisioning runs it for an admin whose token reads
  `secret/ios-rig`, on the live box's address only, so a drill never does.
- MINOR: no known_hosts entry for Forgejo on a new box, so wizard's first
  `git` over SSH asks to trust `git.viktorbarzin.me`. Since the drill
  provisioning writes Forgejo's pinned host key for every user.
- MINOR, as in drill 3: the hourly `t3-provision-users.service` fires
  during the playbook and fails once before the infra clone exists; the
  next run succeeds. Since the drill that run exits 0 and logs why.
- ancamilea gets no account (her roster row is parked). Her state is
  kept: 200 `home_files` and 2 sessions in the store, 7 credential files in
  Vault, her T3 copy on the host.

Verdict: the rebuild works end to end in under an hour, but it did not
pass cleanly, so the nightly devvm-home backup stays.

**2026-11-12, sixth drill, after round 2** (devvm-drill6, VM 9106,
10.0.10.15, drill defaults), built by CI from master (74fc9313a) once every
round-2 workstream had landed, then checked per user after the admin
provisioning run (a 3 h child token, the safety steps in "What to check";
intercom-watch has no devvm unit any more, so there was nothing to stop):

- 01:34 VM up, 01:36-01:56 playbook (315 ok, 0 failed), 02:00-02:27
  restores from the session store (wizard 8,298 files, 7.02 GB in 788 s;
  emo 672 files, 0.97 GB in 90 s), 02:28 status plain `ok`: 54 minutes.
  The hourly `t3-provision-users` run at 01:52 fired during the playbook
  and exited 0 ("the infra checkout ... is not there yet"). The admin run
  took 58 s and ended `reconcile complete`; a later hourly run succeeded.
- Passed, against the live box: credentials (wizard 46 and emo 20 files,
  names, modes and owners as live; content as live except the sops
  `keys.txt` comment lines, the Google OAuth file the drill's own MCP call
  refreshed, and emo's `.git-credentials`, below); terraform 1.15.4, vault
  2.0.1, terragrunt 0.77.20 and sops 3.9.4, and `homelab tf plan devvm` as
  wizard on the drill reported "No changes" through the PG backend;
  `~/.claude.json` for both users with the same `mcpServers`, the same
  trusted projects (wizard 72, emo 2) and the onboarding flag, no
  `<redacted>` left in it or in `~/.codex/config.toml`, both `mcp-filled`
  markers, `claude mcp list` connected for every user server
  (`google_workspace`, `playwright`, emo's `paperless`), `list_calendars`
  through the restored `google_workspace` (workspace-mcp 2.4.2) returned 8
  calendars, `claude` in `~/code/infra` opened at the prompt with no
  onboarding and no trust prompt, and `claude --resume` listed sessions for
  both users; `settings.json`, `history.jsonl` (13,154 and 4,273 lines) and
  both users' `AGENTS.md` identical to live; wizard's dotfiles
  (`.zshrc`, `.zshenv`, `.bash_aliases`, `.tmux.conf.local` byte-identical
  to live, no tmux-resurrect or continuum plugin, no `tmux.service`, no
  `.mcp.json` memory server, `~/.kube` 0700); emo's dotfiles
  byte-identical to live once applied (below), his `claude` resolving to
  `~/.local/bin/claude` in zsh; emo's agent-instruction fetch owned by
  wizard and fetching, `~emo/.agents/AGENTS.md` back; emo in `docker`
  (`docker ps` works as him); Forgejo's host key in both users'
  `known_hosts` (wizard's SSH to Forgejo authenticates with no prompt);
  skills right after the bootstrap's provisioning run
  (`claude-skills-update` started once at 02:28); T3 (wizard 1,013 and emo
  7 threads, the live counts, both serves 200); user units as live minus
  the iOS rig (live address only); the playbook in check mode against the
  drill changed only the two `codex-auth-backup` units the drill had
  disabled; nothing in the session store beyond the live ingest's own rows;
  drill logs only under `job="devvm-drill-journal"`, and a logged fake
  Vault token, bearer header and GitHub token reached Loki as `[REDACTED]`.
- All four tokens the run minted (emo's `~/.vault-token`, both
  `claude-auth-sync` tokens, the child) were revoked before the teardown,
  and a scan of Vault's accessors found no other token created in the
  drill's window apart from CI and cluster ones.
- Not checked: Vermont (out of scope), the infra unlock, a Claude login
  (claude-auth-sync masked).

Gaps it found, none fixed in the drill itself, none CRITICAL or MAJOR:

- MINOR: neither the bootstrap's provisioning run nor the admin run applied
  emo's dotfiles. The bootstrap run cannot clone his private repo without
  his credentials; the admin run, started over SSH in wizard's home, ran
  `chezmoi init` as emo in that directory, which emo cannot read, and
  chezmoi stopped with `stat .: permission denied`. The next hourly run,
  whose working directory is `/`, applied them. On a rebuild his zsh has no
  `.zshrc` and prints `permission denied: claude` until then. A fix is to
  run the chezmoi calls in `install_user_dotfiles` from the user's home;
  until then, start the admin run from `/` ("What to check").
- MINOR: emo's `.git-credentials` in Vault holds a GitHub token that GitHub
  rejects (401 from `/user`). On the live box git dropped that line at
  02:00:11, so the kept copy and the live file differ. Capture his file
  again, or drop the line from the Vault copy.
- MINOR, as in drill 5: wizard has no `unslop` skill, and emo has no
  `cluster-health` in `~/.claude/skills` and none of his 20
  `~/.agents/skills` folders; no kept place holds them.
- MINOR, latent: `install_browser_bridge_token` stores a newly minted
  token with `vault kv patch secret/browser-bridge/tokens "$user=$token"`,
  so the token is on that process's command line. A rebuild never takes
  this path (wizard's and emo's tokens are in Vault); a new roster user
  would.
- Note: emo is uid 1001 on the drill and 1002 on the live box, because
  `useradd` takes the next free uid and the roster pins none. Restores
  chown by name, so nothing on the drill broke.
- Note: the project `ha` server in infra's `.mcp.json` needs `HA_MCP_URL`,
  which wizard's environment lacks on the live box too.
- Note: the first pipeline for the drill commit was cancelled by a later
  push but had already created the VM and handed over the token; the
  re-touch commit then applied nothing. Check `qm list` before re-touching.

Verdict: the rebuild passed with no CRITICAL or MAJOR gap. Viktor retired
the nightly devvm-home backup on 2026-11-12.

**2026-11-12, host-key test, round 3** (devvm-drill-hostkeys, VM 9101,
10.0.10.14, 2 cores, 4 GiB), built by CI from master with
`live_host_keys = true`, to test the host-key path without VM 102:

- At 08:08 UTC the box answered with its first-boot keys (ED25519
  `SHA256:6xr/R5fZ...`); at 08:09:28, a few seconds after the unwrap, with
  the live devvm's three: ED25519 `SHA256:r1N+5R/B...`, ECDSA
  `SHA256:dDyXeaVD...`, RSA `SHA256:ZRwm1gJv...`, the ones the Proxmox host
  pins for 10.0.10.10.
- `ssh` with `StrictHostKeyChecking=yes` and a known_hosts file holding only
  the live public keys for 10.0.10.14 logged in. The cloud-init drop-in was
  there, the keys 600 and 644 root, and the log said `the live devvm's SSH
  host keys are installed`; no `PRIVATE KEY` line in the cloud-init logs or
  the journal.
- Torn down the same hour, before its build finished: the test was the host
  keys, which a drill must not keep. Its bootstrap token, the only one
  carrying `devvm-host-identity`, was revoked by accessor after the destroy
  (found with `vault token lookup -accessor` over `auth/token/accessors`).
  The snippet was re-rendered (`pve-host.yml --tags snippets`) before the
  build, since the bootstrap changed.
