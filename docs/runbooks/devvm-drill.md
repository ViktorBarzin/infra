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
  "Rebuild: put a user's credentials back". The bootstrap's own run has only
  the bootstrap token, which cannot read `secret/workstation/*`, so it skips
  every credential and every clone that needs one. Then check, as root:
  `ls /home/wizard/.vault-token /home/emo/.vault-token`; `ls /home/emo/code`
  lists `tv`, `agents`, `app-kit` and `vermont-device-configs`; and
  `sudo -u emo XDG_RUNTIME_DIR=/run/user/$(id -u emo) systemctl --user
  is-enabled intercom-watch.timer` prints `enabled` (his repo's
  `devvm-setup.sh` ran). On a drill this means handing the drill an admin
  token; skip it there unless the drill is the final one, and record that
  you did. On a drill, give it a child token of your own instead of your
  periodic one (`vault token create -policy=vault-admin -policy=sops-admin
  -ttl=3h -display-name=devvm-<drill>-admin -field=token`, written straight
  to a 0600 file and copied to the drill's `~wizard/.vault-token`), and
  before the run stop what would write shared state from a second box:
  `systemctl mask` `claude-auth-sync@wizard` and `@emo` (timer and service:
  a second holder of the shared Claude OAuth refresh tokens could rotate
  them under the live box), `systemctl disable --now codex-auth-backup.path
  codex-auth-backup.timer`, and right after the run, once `is-enabled`
  has printed `enabled`, `systemctl --user disable --now
  intercom-watch.timer` as emo (it would log in to Hik-Connect and can
  reboot the B4 alongside the live box's copy). Before deleting the drill,
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
  Vault, not a hooks-only skeleton. The drill must read the store and never
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
   capture (`devvm-credentials.md`, "Add or refresh a credential").
3. On the host: `systemctl start t3-state-pull.service devvm-home-backup.service`;
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
through "What to check" above, including the T3 and emo items.
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
  the versions the live box runs (`devvm_terraform_version` and the lines
  after it). Not yet drilled.
- **MAJOR: emo's agent instructions never come back.** The bootstrap's
  provisioning run creates `/var/lib/t3-provision/agent-repos/emo.git`
  before the admin infra clone exists, so as root; every later fetch runs
  as wizard, gets `Permission denied` on `FETCH_HEAD`, and logs `fetch of
  ebarzin/agents failed` every hour. `~emo/.agents/AGENTS.md` (62 KB on the
  live box, the target of his `~/.claude/CLAUDE.md`) stays missing.
- **MAJOR: emo's shell setup has no kept place.** His roster row has no
  dotfiles repo, so `.zshrc`, `.zshenv`, `.zprofile`, `.tmux.conf.local`
  and `.tmux` are lost. Without his `.zshrc`, `~/.local/bin` is not on his
  zsh PATH, `claude` resolves to `/usr/local/bin/claude`, a link into
  wizard's home, and that home is 0750 on a new box (0751 on the live one),
  so his shell prints `permission denied: claude`. T3 is unaffected: its
  unit's PATH falls through to `~/.local/bin`.
- **MAJOR, known: `~/.claude.json` is not restored.** wizard loses the
  `google_workspace` MCP server and 454 project entries, emo the
  `paperless` MCP server; the first `claude` shows the onboarding and the
  folder trust prompt.
- MINOR: emo is in `docker` on the live box by hand; the roster gives
  `docker` to admins only, so a rebuild drops it. A decision, since that
  group is root-equivalent.
- MINOR: skills come back only when `claude-skills-update.timer` fires
  (05:45 daily); provisioning does not start it. After a manual run wizard
  still lacks `unslop` and emo `cluster-health` and his 20
  `~/.agents/skills` folders.
- MINOR: wizard's `ios-rig-doctor.timer`, `ios-rig-tunnel.service` and
  `ios-rig-wifi.service` come back only through `homelab ios bootstrap
  --units-only` (`ios-test-rig.md`), which no rebuild step runs.
- MINOR: no known_hosts entry for Forgejo on a new box, so wizard's first
  `git` over SSH asks to trust `git.viktorbarzin.me`.
- MINOR, as in drill 3: the hourly `t3-provision-users.service` fires
  during the playbook and fails once before the infra clone exists; the
  next run succeeds.
- ancamilea gets no account (her roster row is parked). Her state is
  kept: 200 `home_files` and 2 sessions in the store, 7 credential files in
  Vault, her T3 copy on the host.

Verdict: the rebuild works end to end in under an hour, but it did not
pass cleanly, so the nightly devvm-home backup stays.
