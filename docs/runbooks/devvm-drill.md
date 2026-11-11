# devvm drill: build a throwaway devvm from Terraform

The disposable-devvm plan (`docs/plans/2026-11-11-disposable-devvm.md`) says the
devvm must be rebuildable from code, and a drill proves it every few months:
build a second devvm from the Terraform definition, log in, check what came
back, delete it. This runbook is how.

## The pieces

| Piece | Where | What it does |
|---|---|---|
| VM definition | `modules/proxmox-devvm` | One VM with the live devvm's shape (32 cores, 32 GiB, 228 GiB scsi0 capped 60/60 MB/s, vmbr1 VLAN 10, guest agent), a static address and the admin's keys on the cloud-init drive. Refuses the live name, VMID 102, 10.0.10.10 and its MAC unless `allow_live_identity = true`. |
| Stack | `stacks/devvm` | `local.drills` lists the drill VMs. Empty means the stack holds nothing on the host, not even the Ubuntu image. Standalone terragrunt (bpg/proxmox as `proxmoxbpg`, like `stacks/opnsense`). |
| Token | Vault `secret/devvm` `pve_api_token` | `terraform-devvm@pve!tf`, role `TFDevvm` on `/pool/devvm`, the VMID slots `/vms/9100`-`/vms/9109`, and storage, network and node paths. PVE checks `/vms/<id>` during create, before the VM joins the pool, so a drill needs a slot. VM 102 is neither, so the token gets 403 on it. Declared by `playbooks/pve-host.yml --tags devvm-tf`. |
| Snippet | `/var/lib/vz/snippets/devvm_bootstrap.yaml` | Vendor data for every Terraform devvm. Rendered by `pve-host.yml --tags snippets` from `playbooks/files/pve/snippets/devvm_bootstrap.yaml.j2`, embedding `scripts/devvm-bootstrap`. |
| Handoff | `scripts/devvm-drill-handoff` | Runs on the applier after the VM is up: mints a wrapped token through Vault token role `devvm-bootstrap` and writes it into the guest through the guest agent. |
| First boot | `scripts/devvm-bootstrap` | In the guest: unwraps the token, clones infra at `infra_ref`, runs `playbooks/devvm.yml` locally, runs `t3-provision-users` once, revokes the token, writes `/var/lib/devvm-bootstrap/status`. |

The Vault side (`stacks/vault`): policy `devvm-bootstrap` reads exactly the
paths `playbooks/devvm.yml` reads (`secret/claude-sessions`, `terminal-lobby`,
`devvm-authorized-keys`, `rybbit`, `glitchtip`, `agentmd`); the token role makes
orphan, non-renewable tokens with a 4 h hard limit; CI's policy may create
tokens through that role and nothing else. When the playbook starts reading a
new Vault path, add it to the policy, or a fresh build fails at that task.

## Before a drill

1. Host RAM. The live devvm alone is 32 GiB; the host had 45 GiB available on
   2026-11-11 with swap in use. Size the drill to fit:
   `ssh root@192.168.1.127 free -g`. 4 cores, 8 GiB and 80 GiB build fine;
   the playbook scales its memory caps to the box.
2. Pick a free VMID in 9100-9109 (other IDs get 403 at create) and an address below VLAN 10's DHCP pool (.100-.254)
   that nothing answers on: `ping -c1 10.0.10.11`. Not 10.0.10.10.
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
   `ok` means the playbook and the provisioner finished. `failed: <step>`
   names the step; the log above has the detail. `cloud-init status --long`
   shows the same result from cloud-init's side.

## What to check

- `ssh wizard@<address>` works with your usual key, and `sudo -n true` works.
- The playbook converged: rerun it on the drill from the main checkout,
  check mode, with an inventory line for the drill address. Expect no
  changes beyond the ones the live box also shows.
- Per the plan, as each workstream lands: log in as each user (wizard, emo,
  ancamilea) through `sudo -iu <user>`; work comes back from Forgejo, agent
  state from the session store, T3 threads from the nightly snapshot,
  credentials from Vault `workstation/<user>`. Vermont checks are out of scope
  for a drill.
- The drill does not take over anything of the live devvm's: Traefik, DNS and
  the DHCP reservation all point at 10.0.10.10, so the lobby and T3 on the
  drill are reachable only on its own address.

## Tear it down

Remove the entry from `local.drills` and land it. CI stops and destroys the VM
(`purge_on_destroy`) and, with no drills left, deletes the image from `local`.
Check: `ssh root@192.168.1.127 'qm list; pvesm list local --content import'`.

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
- **403 from Proxmox in the apply.** `TFDevvm` lacks a privilege for something
  new; add it to the list in `pve-host.yml` and rerun `--tags devvm-tf`.

## Building the real replacement

Only once VM 102 is gone: add an instance with the live identity
(`name = "devvm"`, `vm_id = 102`, `ipv4_cidr = "10.0.10.10/24"`,
`mac_address = "00:0c:29:c0:89:ec"` so the DHCP reservation and every
neighbour cache still match, `allow_live_identity = true`) and the full size.
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
- terminal-lobby is installed by its deploy pipeline on the live box; the
  bootstrap now installs it from the public registry after the playbook. All
  seven lobby units came up.

Still open after this drill, for the final one:

- wizard's unlocked `~/code/infra` is not cloned on a new box, so the hourly
  `t3-provision-users.service` fails ("roster/engine not under
  /home/wizard/code/infra/scripts/workstation"). The one-off run from the
  bootstrap clone works.
- `claude-sessions-ingest.service` fails with 203/EXEC: the program it runs is
  not installed by the playbook on a new box.
- Provisioning runs without an admin Vault token, so per-user Vault tokens,
  Claude-auth tokens, memory keys, browser-bridge tokens and the credential
  restore from `secret/workstation/<user>` are skipped with warnings. The
  bootstrap policy covers only the playbook's reads; the final drill needs
  either a wider policy or an admin re-running provisioning after
  `vault login`.
