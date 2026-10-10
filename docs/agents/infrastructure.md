# Infrastructure

Moved verbatim from the repo's agent instruction files (`AGENTS.md`, `.claude/CLAUDE.md`) on 2026-09-22, when the two merged into one root `AGENTS.md`. Related as-built docs: `docs/architecture/overview.md`, `docs/architecture/compute.md`.

## Infrastructure
- **Proxmox**: 192.168.1.127 (Dell R730, 22c/44t, 142GB RAM)
- **Nodes**: k8s-master (10.0.20.100), node1 (GPU, Tesla T4), node2-4
- **GPU**: `node_selector = { "nvidia.com/gpu.present" : "true" }` + toleration `nvidia.com/gpu`. The label is auto-applied by NFD/gpu-feature-discovery on any node with an NVIDIA PCI device — nothing is hostname-pinned, so the GPU card can move between nodes without Terraform edits.
- **Pull-through cache**: 10.0.20.10 — docker.io (:5000), ghcr.io (:5010) only. Caches stale manifests for :latest tags — use versioned tags or pre-pull with `ctr --hosts-dir ''` to bypass.
- **pfSense**: 10.0.20.1 (gateway, firewall, DNS forwarding)
- **MySQL standalone** (`mysql-standalone` StatefulSet; InnoDB Cluster until 2026-04-16, its leftover CR, CRDs and PDB removed 2026-10-10): 1 instance on proxmox-lvm-encrypted, PriorityClass `tier-1-cluster`, no PDB, anti-affinity excludes any GPU node (`nvidia.com/gpu.present=true`) so MySQL moves off the GPU host automatically if the card is relocated
- **SMTP**: `var.mail_host` port 587 STARTTLS (not internal svc address — cert mismatch)
