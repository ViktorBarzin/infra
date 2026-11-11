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
| Handoff | `scripts/devvm-drill-handoff` | Runs on the applier after the VM is up: mints a wrapped token through Vault token role `devvm-bootstrap` and writes it into the guest through the guest agent. |
| First boot | `scripts/devvm-bootstrap` | In the guest: unwraps the token, clones infra at `infra_ref`, runs `playbooks/devvm.yml` locally, copies the users' T3 snapshots from the host's `/mnt/backup/t3-state` (key Vault `secret/devvm-t3-seed`, read-only on the host), runs `t3-provision-users` once, revokes the token, writes `/var/lib/devvm-bootstrap/status`. |

The Vault side (`stacks/vault`): policy `devvm-bootstrap` reads exactly the
paths `playbooks/devvm.yml` reads (`secret/claude-sessions`, `terminal-lobby`,
`terminal-lobby/vapid`, `devvm-authorized-keys`, `rybbit`, `glitchtip`, `agentmd`), plus
`secret/devvm-t3-seed` for the bootstrap's T3 snapshot copy; the token role makes
orphan, non-renewable tokens with a 4 h hard limit; CI's policy may create
tokens through that role and nothing else. When the playbook starts reading a
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
     "devvm-drill" = { vm_id = 9102, ipv4_cidr = "10.0.10.11/24", cores = 4, memory_mb = 8192, disk_gb = 80 }
   }
   ```
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
  Vault, not a hooks-only skeleton. The drill must read the store and never
  write to it: no `/etc/claude-sessions/ingest.env`,
  `claude-sessions-ingest.timer` disabled, and after the drill no rows from
  its time window that the live ingest's journal does not account for:
  `homelab claude-sessions sql "SELECT toStartOfMinute(ingested_at) m,
  os_user, count() FROM claude.home_files WHERE ingested_at > now() - INTERVAL
  2 HOUR GROUP BY m, os_user ORDER BY m"` against `journalctl -u
  claude-sessions-ingest` on 10.0.10.10. The 2026-11-11 drill failed this
  (drill log).
- The drill's journal reaches Loki as `{job="devvm-journal",
  host="<drill name>"}`, not `host="devvm"`, so it stays out of the live box's
  alerts.
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

The token cannot create VMID 102 until it holds the slot, and PVE deletes any
`/vms/102` ACL when 102 is destroyed, so the grant has to come after:

1. Destroy the old VM 102 as root on the host.
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
neighbour cache still match, `allow_live_identity = true`) and the full size.
The new box has new SSH host keys, so the host's nightly pulls from 10.0.10.10
(`t3-state-pull`, `devvm-home-backup`) fail until the host trusts the new key:
`ssh-keygen -R 10.0.10.10` on the host, then the `ssh-keyscan` step in
backup-dr.md, "T3 snapshots", "After a rebuild, on the host".
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
user's T3 database from the Proxmox host copy, and six of the seven lobby
units are active. Both drill VMs were then removed.

Still open after this drill, for the final one:

- `agent-api` binds 10.0.10.10 and exits on any other address, so it fails on
  a drill by design of its config; a rebuild at 10.0.10.10 is unaffected.
- cloud-init's own run on drill2 is marked failed (`cloud-final`), from the
  pre-fix HOME failure; the clean result came from a rerun of the same
  bootstrap under a service with no HOME. The next drill should be the first
  that goes green from cloud-init alone.

- wizard's unlocked `~/code/infra` is not cloned on a new box, so the hourly
  `t3-provision-users.service` fails ("roster/engine not under
  /home/wizard/code/infra/scripts/workstation"). The one-off run from the
  bootstrap clone works. Fixed after this drill: that run now clones it,
  locked, from Forgejo (`install_admin_infra_clone`); unlocking it is in
  `devvm-credentials.md`.
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
