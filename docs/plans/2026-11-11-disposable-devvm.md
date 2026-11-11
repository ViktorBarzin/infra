# Disposable devvm

Status: approved 2026-11-11, from a grilling session with Viktor. Nothing built yet.

The devvm (10.0.10.10) should be deletable and rebuildable from code in about
an hour, losing only scratch. Today a rebuild means the playbook plus a
hand restore from the nightly `/home` copy, and anything outside `/home` is
lost (inventory 2026-11-11: T3 snapshots in `/var/backups`, a local Postgres,
an NFS export, undeclared packages, emo's watchers).

```mermaid
flowchart TD
    TF["Terraform VM definition<br/>+ cloud-init"] --> PB["playbooks/devvm.yml"] --> RO["roster provisioning"]
    RO -- "restores from" --> Kept
    subgraph Kept["Kept places, off the VM"]
        direction TB
        FJ["Forgejo<br/>pushed code, dotfiles, emo's tools"] ~~~ VA["Vault<br/>SSH, GPG, tokens, kubeconfig"] ~~~ CH["ClickHouse session store<br/>~/.claude and ~/.codex"] ~~~ HOST["Proxmox nightly-chain<br/>T3 snapshots"]
    end
    Kept --> VM["devvm 10.0.10.10<br/>caches and scratch only"]
    VM -. "everything else" .-> X["scratch, lost on rebuild"]
```

> [!IMPORTANT]
> Scratch includes work an agent has not pushed. Agents push finished work; in-progress work may be lost on a rebuild.

All three users are in scope: wizard, emo and ancamilea. Scratch is anything
not in a kept place.

## Kept places
- Code: Forgejo. Agents push finished work; in-progress work may be lost. No
  automatic backup refs.
- Agent state: ClickHouse session store, extended to ingest everything under
  ~/.claude and ~/.codex except credentials and caches (history.jsonl, plans,
  tasks, teams, todos, file-history, remote/, Codex sessions; raw transcripts,
  subagents and tool results are already there), plus a restore command that
  writes a user's ~/.claude back so `claude --resume` works.
- T3 threads: the existing nightly snapshot in /var/backups/t3-state is pulled
  off the VM by a new nightly-chain step on the Proxmox host; provisioning
  restores the newest on a rebuild.
- Memory: homelab memory (unchanged).
- Credentials: Vault under `workstation/<user>`, restored by provisioning (SSH
  keys, GPG keys, Git PATs, gh, rclone, gcloud, docker). Loose secrets in
  ~/code (keys.txt, tmp_id, git-crypt key copy) and meshcentral-data keys:
  checked against Vault, missing ones stored, local copies deleted.
- Dotfiles: provisioning runs chezmoi apply; the admin kubeconfig comes from
  Vault instead of GPG. wizard's user units (lobby-local, tmux,
  tmux-plugin-update) move into the dotfiles; the hourly infra git-pull cron
  is dropped. vault-token-renew is installed for every user by provisioning.
- No weekly "outside kept places" report.

## Scratch (lost on rebuild, nothing migrated)
All of wizard's data folders (reel-archive-countries, ha-london-recovered,
vault-audit-archive, actualbudget dumps, dab-downloader, ff, src/t3code,
immich-repro, rpi-london, 2023 mysql datadir), loose files and folders in
~/code, /var/lib/clipboard-store contents.

## Machine
- Now, ahead of the rest: remove the /home/wizard NFS export (rw to *),
  stop and disable nfs-server; record the removal in the playbook.
- Undeclared packages, binaries, units: fold into playbooks/devvm.yml if used,
  remove if not; --check stays a clean no-op. The clipboard-store writer is
  declared or removed.
- Local Postgres (finance, trading_dev): dropped, server removed.
- Docker containers tl-fallback and paperless-mcp: removed.
- The VM is defined in Terraform (disk, CPU, RAM, cloud-init that runs the
  playbook), pinned to 10.0.10.10. The live devvm is NOT replaced; the
  definition is used for drills.

## Unpushed work today
Reviewed repo by repo (terminal-lobby ~12 real commits + dirty worktrees,
infra 6 commits and dirty worktrees, interview-prep-app, Plotting-Your-Dream-Book,
stashes in 4 repos, insta2spotify and immich-repro dirty files, cloud with no
remote). dot_files' 158 are stale history, not work.

Done 2026-11-11. Pushed as branches, nothing merged and no master touched:
- terminal-lobby `wizard/pane-ownership` (3 commits plus the uncommitted
  claim work as one wip commit) and `wizard/inline-chip-art` (the
  uncommitted work as one wip commit). Both were rebuilt on the rewritten
  history, because their local copies sit on the pre-rewrite lineage, and
  pushing that would bring back the three plan docs purged on 2026-09-17
  and the old employer author address.
- infra `wizard/tripit-country-days-cron` (the worker-label fix is not on
  master), `wizard/immich-restore-runbook`, `wizard/ha-london-backup-upgrades`
  and `wizard/bb-stale` (the one untracked test, as a wip commit).
- interview-prep-app `wizard/render-generated-dsl` (2 commits from local master).
- agent-conductor `wizard/de-meta-rust-wip` (the demeta-baseline-check stash).
- cloud: new private Forgejo repo `viktor/cloud`, master pushed.

Judged scratch and left in place: the other terminal-lobby branches (their
only unique commits are the purged docs, or already on master by subject),
its stash and agent-delegation's glossary edit (both on master already), infra
`wizard/ebooks-calibre-trusted` (on master), Plotting-Your-Dream-Book (per-user
beads and gitleaks hook drift), the broker-sync stash (landed on master as the
HTML table fallback), the finance stash (a 2023 experiment), insta2spotify
(3050 deletions of node_modules files that were tracked by mistake),
immich-repro/src (a sparse upstream checkout plus 10 files byte-identical to
upstream v3.3.5), and two orphaned T3 checkouts of the dissolved monorepo root
under ~/.t3/worktrees/code (no edits since checkout).

## emo (changed without asking him first)
- Retire: panel115-watch, camera-stream-watch, led_report, vermont-mon,
  valia-backup-cleanup (when done), printer-price watcher, PAI-issue watcher,
  userspace Tailscale.
- intercom-watch becomes a ha-sofia automation (check, ISAPI reboot via
  rest_command after ~15 min offline, push to emo); ha-sofia's address joins
  the Vermont allowlist (OPNsense alias + rpi-sofia netmap). Verify the B4
  accepts the ISAPI reboot first.
- Hand tools go into his vermont-device-configs repo, cloned by provisioning.

## Also
- HA London backs up through HA network storage to a new NFS export on the
  Proxmox host (/srv/nfs/ha-london-backup), covered by nfs-mirror and offsite.

## Proof and retirement
- Throwaway drill: build a second VM from the Terraform definition (different
  address, no Vermont checks), log in as each user, check work, agent state,
  T3 threads and credentials come back, delete it. Repeat every few months.
- The nightly devvm-home backup stays until the drill passes, then shrinks and
  retires.

## Open questions

- The B4 intercom may not accept the ISAPI reboot the ha-sofia automation
  would use (the current script uses the vendor SDK). Checked before
  intercom-watch is retired; if it fails, the fallback is decided then.
- HA network storage over the tunnel to London has not been tried; a mount
  across the WAN can stall.
- The ClickHouse store's size growth once file-history and remote/ are
  ingested is not measured yet.
- Which local SSH keys already match the copies in Vault was not checked.
