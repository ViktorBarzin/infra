# ADR-0045: Physical nodes use a Tang-unlocked State volume and are provisioned by PXE and Ansible

- Status: accepted
- Date: 2026-11-21
- Related: ADR-0002 (amended the same day), the plan `docs/plans/2026-11-21-dell-opportunistic-worker-design.md`, `GLOSSARY.md` (Physical node, Opportunistic worker, State volume, Tether, Spill-over)

## Context

Every Kubernetes node so far is a VM on the Sofia Proxmox host, built from a cloud-init template. The Dell Precision 5530 in London is the first Physical node. It is an Opportunistic worker: it is on most of the time, it is off for days now and then, and nothing depends on it. It has Wi-Fi only. Viktor wants its setup to be the model for every future machine: encrypted, unattended at boot, and provisioned from the repo.

The Dell's Linux side had a broken Fedora install. It was repaired on 2026-11-21, and Viktor keeps it as a desktop. The worker runs on its own Ubuntu partition, and the Dell boots it by default.

## Decision

- **Encryption.** A Physical node has a plain OS root and a LUKS2 **State volume**. The State volume holds `/etc/kubernetes`, `/var/lib/kubelet`, `/var/lib/containerd`, `/etc/cni/net.d` (it holds a Calico service-account token), `/var/log/pods`, `/var/log/containers` and the GitHub runner's state. Clevis unlocks it after the network is up, from a **Tang** server in the Sofia cluster. Tang is reachable only through the WireGuard tunnel. Each node has its own Tang key set. journald keeps logs in memory, and swap, core dumps, suspend and hibernate are off.
- **Tether.** When a node cannot reach Tang for 10 minutes, it stops kubelet and containerd and closes the State volume. It opens the volume again when Tang returns.
- **Provisioning.** A host file in the repo names the machine (MAC, Site, role, disk). PXE boots it from one in-cluster HTTP boot service: iPXE, Ubuntu 26.04 autoinstall and the per-machine config. OPNsense Kea in Sofia and the Flint 2 in London hand out only `ipxe.efi`. When the install reports in, `homelab machine provision <name>` runs `playbooks/physical-node.yml` from the devvm. The playbook binds Tang, builds the State volume, joins the cluster and runs `k8s-node-tuning.yml`. A machine with no wired port (the Dell) gets Ubuntu by `debootstrap` instead, and then the same playbook.
- **Scheduling.** An Opportunistic worker carries a `NoSchedule` taint. Only workloads that tolerate it run there, and they fall back to Sofia when it is off. Its node-down alerts are muted. A GPU that the cluster's GPU Operator driver does not support keeps a host driver, and the node has the label `nvidia.com/gpu.deploy.driver=false`.

## Considered options

- **Full-disk encryption with Tang in the initramfs.** Rejected. When Tang or the tunnel is down, the node waits at a password prompt that nobody can reach. Wi-Fi in the initramfs needs a custom hook. The Wi-Fi password is in plaintext in both models, and a tampered OS defeats both without TPM measurement.
- **TPM-only unlock.** Rejected: the owner wants a node to decrypt only when it can reach the homelab.
- **A Tang server on the London router.** Rejected: a stolen laptop that joins the London LAN can unlock.
- **The machine pulls its own config.** Rejected: the join token and Tang binding are secrets, and the infra repo is public.
- **A PXE server at each Site.** Rejected: two sources of truth.

## Consequences

- A thief with a powered-off node gets the OS and no cluster secrets, if the State volume path list is complete. Each new DaemonSet that tolerates the taint and writes a hostPath must be checked against that list.
- Tang does not authenticate clients. Anybody who has the disk and can reach Tang can unlock it. The tunnel-only reach of Tang is part of the security boundary.
- After a theft, delete that node's Tang keys and re-key its SSH host keys. The node's state is rebuilt by the playbook and a new join.
- Evil-maid tampering of the plaintext root is accepted. The stated threat is theft, not repeated access to the flat.
- The OPNsense DHCP pointer to the dead host `10.0.10.20` (`pxelinux.0`) is replaced.
- Rollback: drain and delete the node, destroy the Tang and HTTP boot stacks, and revert the DHCP options.
