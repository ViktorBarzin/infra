---
status: shelved
plan: true
---

# The London Dell becomes an Opportunistic worker and the model for Physical nodes

The Dell Precision 5530 in London has 12 threads, 48 GB of RAM and a Quadro P2000, and nothing uses them. This plan makes it a tainted cluster node for Spill-over work, and turns its setup into the playbook for every future Physical node.

> **Shelved on 2026-11-22.** Steps 1 to 5 are done, and `dell-worker` joined the cluster. Fedora got its key slot back. The Physical-node playbook, Tang and the runbook stay as the model for the next machine. Step 6 and the GPU Operator toleration are not built. GitHub Actions cannot cost money: $0 budgets block usage. In November, included usage covered all $21.82 of usage, and $0 was charged. `proxy.viktorbarzin.me` already gives a UK exit. The Dell is off and stored, and Fedora is its default boot entry. When it boots the worker entry, it unlocks through Tang and rejoins by itself.

Terms (Opportunistic worker, Physical node, State volume, Tether, Spill-over, Site, Off-site copy) are in `GLOSSARY.md`. The decision record is ADR-0045, with an amendment to ADR-0002.

## In numbers

```numbers
caption: Measured 2026-11-21 (GitHub billing API, btrfs usage, kubectl, headscale).
rows:
  - {label: GitHub Actions minutes for private repos in October, before: "2,000 of 2,000", after: "tv and tripit on the London runner while the Dell is on"}
  - {label: Free space on the Dell's Fedora, before: "153 GB", after: "384 GB, then 134 GB after the 250 GB worker partition", better: false}
  - {label: Physical nodes in the cluster, before: "0", after: "1"}
  - {label: Extra capacity while the Dell is online, before: "0", after: "12 threads, 48 GB RAM, P2000 4 GB"}
  - {label: Live PXE servers, before: "0 (DHCP points at a dead host)", after: "1 in-cluster HTTP boot service"}
```

## The system, with the change on it

```topology
caption: Sofia keeps every critical service. The Dell adds capacity only while it is online.
direction: TD
groups:
  - {id: sofia, label: Sofia cluster}
  - {id: routers, label: Site routers}
  - {id: london, label: London Dell}
nodes:
  - {id: k8s, label: Kubernetes control plane and VM nodes, group: sofia, state: same}
  - {id: tang, label: Tang, note: one key set per Physical node, group: sofia, state: new, risk: medium}
  - {id: pxe, label: HTTP boot service, note: iPXE, Ubuntu autoinstall, per-machine config, group: sofia, state: new, risk: low}
  - {id: kea, label: OPNsense Kea DHCP, note: ipxe.efi instead of the dead pxelinux.0 pointer, group: routers, state: changed, risk: low}
  - {id: flint, label: Flint 2 router, note: TFTP serves ipxe.efi, group: routers, state: changed, risk: low}
  - {id: worker, label: Ubuntu 26.04 worker, note: tainted node, State volume, Tether, 580 driver, group: london, state: new, risk: high}
  - {id: runner, label: GitHub runner, note: tv and tripit, falls back to hosted, group: london, state: new, risk: medium}
  - {id: fedora, label: Fedora 44 desktop, note: KDE, fingerprint, password unlock, group: london, state: changed, risk: low}
  - {id: windows, label: Windows 11, scope: out}
edges:
  - {from: worker, to: tang, state: new, label: unlock over the WireGuard tunnel}
  - {from: worker, to: k8s, state: new, label: kubelet over the tunnel}
  - {from: flint, to: pxe, state: new, label: iPXE over HTTP}
  - {from: kea, to: pxe, state: new, label: iPXE over HTTP}
  - {from: runner, to: worker, state: new}
checks:
  - {node: worker, text: "Node joins, shows Ready, and takes only pods that tolerate its taint", status: open}
  - {node: tang, text: "State volume stays closed when the tunnel is down, and opens when it returns", status: open}
  - {node: runner, text: "A tv build runs on the London runner, and falls back to hosted with the Dell off", status: open}
  - {node: pxe, text: "A test VM boots from PXE and finishes the Ubuntu autoinstall", status: open}
  - {node: fedora, text: "Fedora 44 boots to Plasma and asks for the disk password", status: open}
left_out:
  - Off-site backup copy in London (declined)
  - Home Assistant voice on the P2000 (declined)
  - TV replay Jobs on the P2000 (declined; the disk load stays on sdc)
  - P2000 in the T4 GPU pool through a cluster-wide driver change
```

## Decisions

```decision
- question: What role does the Dell take?
  options:
    - {name: Opportunistic worker and tainted cluster node, chosen: true}
    - {name: Standalone London host, note: no Kubernetes Jobs can spill over}
    - {name: Permanent worker, note: it is off for days at a time}
  why: Kubernetes Jobs and CI can use it when it is on, and nothing breaks when it is off.
- question: Which operating systems run on the Dell?
  options:
    - {name: "Triple boot: Ubuntu 26.04 worker by default, Fedora 44 desktop, Windows 11", chosen: true}
    - {name: Fedora as the node, note: the only non-Ubuntu node}
    - {name: Ubuntu VM on Fedora, note: fragile GPU passthrough on a laptop}
  why: The worker matches the other nodes, and a desktop is one reboot away.
- question: How is a Physical node encrypted?
  options:
    - {name: "Plain OS root and a State volume that Clevis unlocks from Tang", chosen: true}
    - {name: Full-disk encryption with Tang in the initramfs, note: no SSH when Tang is down; Wi-Fi needs a custom hook}
    - {name: TPM only, note: no network check}
  why: The node stays reachable over SSH when Tang or the tunnel fails; a separate comparison agreed.
- question: Where does Tang run?
  options:
    - {name: Sofia cluster, reachable only through the WireGuard tunnel, chosen: true}
    - {name: London Flint router, note: a stolen laptop on the London LAN can unlock}
  why: A machine taken away from the London flat cannot reach Tang.
- question: What does the Tether do after 10 minutes without Tang?
  options:
    - {name: Stop kubelet and containerd and close the State volume; reopen when Tang returns, chosen: true}
    - {name: Power off, note: a Sofia outage strands the machine}
    - {name: Nothing, note: keys stay in RAM}
  why: Keys leave memory, and the node recovers by itself.
- question: How does a new machine get provisioned?
  options:
    - {name: "Host file in the repo, PXE, Ubuntu autoinstall, then homelab machine provision", chosen: true}
    - {name: The machine pulls its own config, note: needs a secret delivery path}
    - {name: Manual install, note: no repeatable path}
  why: One command, and secrets stay out of the public repo.
- question: Where does PXE run?
  options:
    - {name: One in-cluster HTTP boot service; the routers serve only ipxe.efi, chosen: true}
    - {name: A PXE box at each Site, note: two sources of truth}
  why: One source of truth; London needs two router settings.
- question: How does the GitHub runner run?
  options:
    - {name: Host systemd service on the worker, for a list of repos (tv, tripit), chosen: true}
    - {name: Actions Runner Controller pods, note: a new cluster controller}
    - {name: All 22 private repos, note: 22 registrations for 12 threads}
  why: tv alone used 1,775 of the 2,000 minutes in October.
- question: What happens to CI when the Dell is off?
  options:
    - {name: Fall back to GitHub-hosted runners, chosen: true}
    - {name: Wait for the Dell, note: builds stall for days}
  why: Builds never stall; minutes go only on the days the Dell is off.
- question: Which other work spills over?
  options:
    - {name: UK browser workers for sites that block Sofia, chosen: true}
    - {name: Backup restore drills, note: not chosen}
    - {name: TV replay Jobs, note: the disk load stays on sdc}
  why: A London home IP passes bot walls that refuse Sofia.
```

## Order of work

```timeline
caption: Files leave the laptop before any disk change. Shredding the plaintext secrets cannot be undone.
steps:
  - {when: "1. Ingest", what: "Code to Forgejo after a secret scan; documents to Paperless; photos to Immich; KeePass and keys to Vaultwarden", rollback: "Delete the new repos, documents and assets"}
  - {when: "1b. Shred", what: "Delete the plaintext password export, pw.txt and the old SSD key", ponr: true}
  - {when: "2. Fedora 44", what: "dnf system-upgrade 40 to 42 to 44, then fprintd-goodix53x5 with the Windows key import", rollback: "Boot the previous kernel; dnf history undo"}
  - {when: "3. Cluster side", what: "Tang, HTTP boot service, Kea and Flint DHCP options, Physical-node playbook, homelab machine verbs", rollback: "Destroy the stacks; revert the DHCP options"}
  - {when: "4. Worker", what: "Shrink Fedora by 250 GB, debootstrap Ubuntu 26.04, provision it, make it the default boot", rollback: "Delete the partition; grow the Fedora btrfs again"}
  - {when: "5. Fedora key", what: "Remove the temporary LUKS key slot and the old sata_ssd entries", rollback: "Add a key slot again with the password"}
  - {when: "6. Spill-over", what: "Runner for tv and tripit with hosted fallback; UK browser workers", rollback: "Remove the runner label from the workflows"}
```

## Configuration

```config
- {key: next_server and boot_file on VLAN 20, where: playbooks/files/opnsense/dhcp.yml, old: "10.0.10.20, pxelinux.0", new: "the HTTP boot service, ipxe.efi"}
- {key: PXE boot file, where: London Flint DHCP, old: "none", new: "ipxe.efi from the router's TFTP"}
- {key: Node taint, where: Physical-node playbook, old: "none", new: "node-role.viktorbarzin.me/opportunistic=true:NoSchedule"}
- {key: GPU driver on the Dell, where: node label, old: "none", new: "nvidia.com/gpu.deploy.driver=false with a host 580 driver"}
- {key: Tether timeout, where: Physical-node playbook, old: "none", new: "10 minutes"}
- {key: Worker partition, where: Dell NVMe, old: "Fedora 700 GB", new: "Fedora 450 GB, worker 250 GB"}
- {key: Fedora unlock, where: Dell boot entry, old: "temporary key file", new: "password at the keyboard"}
```

## Commands

```sh
homelab machine provision dell-london
ansible-playbook -i playbooks/inventory.ini playbooks/physical-node.yml --limit dell-london --check --diff
```
