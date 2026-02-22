# Talos Linux Migration Evaluation

**Date**: 2026-02-22
**Status**: Parked (evaluating ROI)
**Decision**: Not yet decided — saved for future reference

## Problem Statement

The Kubernetes cluster nodes (Ubuntu 24.04) are configured through a mix of:
- Cloud-init (packages, repos, containerd, kubelet, kubeadm join)
- Terraform `null_resource` with SSH (containerd mirrors, API server OIDC, audit policy, GPU taint)
- Ansible playbook (node exporter — optional)
- DaemonSets (sysctl inotify limits)
- Manual steps (GPU label, node upgrades, containerd mirror fixes)

This creates a drift surface and makes full from-scratch reprovisioning non-trivial.

**Goals:**
1. Prevent configuration drift — ensure nodes match what's declared in code
2. Single-command bootstrap — recover from complete node/cluster failure
3. Everything managed as code in the infra repository

## Options Evaluated

### Option 1: Chef on Ubuntu — Rejected

- Chef is effectively dead (Progress acquisition, shrinking ecosystem)
- Adds Ruby DSL, Chef server/zero, cookbook management — a parallel config system
- Drift detection is reactive (periodic convergence), not preventive
- Doesn't simplify the provisioning chain, just replaces SSH commands with recipes

### Option 2: NixOS — Not pursued

- Strongest drift guarantees (entire OS derived from Nix expression)
- Steep learning curve (functional language, unhelpful error messages)
- NVIDIA + containerd + K8s on NixOS is a niche combination
- Proxmox cloud-init integration less mature than Ubuntu
- Significant migration effort for marginal benefit over Talos

### Option 3: Talos Linux — Preferred candidate (if migrating)

Purpose-built immutable K8s OS. No SSH, no shell, no package manager. Entire node config is a single YAML document applied via gRPC API. Read-only filesystem makes drift structurally impossible.

### Option 4: Improve current setup — Low-cost alternative

Consolidate existing `null_resource` SSH blocks, fix the GPU label gap, and accept the small drift surface. See "Quick Wins" section below.

## Talos Linux — Detailed Assessment

### What Maps Cleanly

| Current (Ubuntu) | Talos Equivalent | Complexity |
|---|---|---|
| cloud_init.yaml packages | Eliminated (no packages needed) | None |
| containerd registry mirrors | `machine.registries.mirrors` in machine config | Simple |
| `kubeadm join` | Talos manages K8s lifecycle natively | Simple |
| sysctl DaemonSet (inotify) | `machine.sysctls` in machine config | Simple |
| API server OIDC flags (SSH+sed) | `cluster.apiServer.extraArgs` | Simple |
| Audit policy (SSH+sed) | `cluster.apiServer.extraArgs` + `extraVolumes` | Simple |
| GPU label (manual) | `machine.nodeLabels` | Simple |
| GPU taint (null_resource) | `machine.nodeTaints` or machine config | Simple |
| Static IPs | `machine.network.interfaces` | Simple |
| QEMU guest agent | `qemu-guest-agent` system extension | Simple |

### What Has Friction

| Component | Issue | Severity |
|---|---|---|
| NFS volumes | `nfs-utils` extension is "contrib" tier (community-maintained) | Medium |
| NVIDIA GPU | Extensions must version-lock to Talos release; Tesla T4 needs open kernel modules | Medium |
| No SSH | Debugging via `talosctl` only (dmesg, logs, dashboard, pcap) | Low-Medium |
| Not kubeadm | Cannot in-place migrate; must build parallel cluster | High (one-time) |
| Proxmox templates | Different provisioning model (ISO boot vs cloud-init clone) | Medium |
| No arbitrary packages | No tcpdump, htop, vim on nodes; use talosctl equivalents or debug containers | Low |

### Terraform Integration

Official provider: `siderolabs/talos` v0.10.1

```hcl
# Key resources:
# - talos_machine_secrets        — cluster-wide secrets (generated once)
# - talos_machine_configuration  — per-node machine config (data source)
# - talos_machine_configuration_apply — apply config to a node
# - talos_machine_bootstrap      — bootstrap control plane (once)
# - talos_cluster_kubeconfig     — retrieve kubeconfig
```

Would fit as `stacks/talos/` alongside existing `stacks/infra/`.

### Example Machine Configs

#### Worker node (e.g., k8s-node2)

```yaml
version: v1alpha1
machine:
  type: worker
  network:
    hostname: k8s-node2
    interfaces:
      - interface: eth0
        addresses:
          - 10.0.20.102/24
        routes:
          - network: 0.0.0.0/0
            gateway: 10.0.20.1
    nameservers:
      - 10.0.20.101  # Technitium
      - 1.1.1.1
  registries:
    mirrors:
      docker.io:
        endpoints: ["http://10.0.20.10:5000"]
      ghcr.io:
        endpoints: ["http://10.0.20.10:5010"]
      quay.io:
        endpoints: ["http://10.0.20.10:5020"]
      registry.k8s.io:
        endpoints: ["http://10.0.20.10:5030"]
      reg.kyverno.io:
        endpoints: ["http://10.0.20.10:5040"]
  sysctls:
    fs.inotify.max_user_watches: "1048576"
    fs.inotify.max_user_instances: "8192"
    net.ipv4.ip_forward: "1"
  kubelet:
    extraConfig:
      serializeImagePulls: false
      maxParallelImagePulls: 50
  install:
    disk: /dev/sda
    extensions:
      - image: ghcr.io/siderolabs/nfs-utils:v2.7.2
      - image: ghcr.io/siderolabs/qemu-guest-agent:v10.2.0
cluster:
  controlPlane:
    endpoint: https://10.0.20.100:6443
```

#### GPU node (k8s-node1) — additional config

```yaml
machine:
  kernel:
    modules:
      - name: nvidia
      - name: nvidia_uvm
      - name: nvidia_drm
      - name: nvidia_modeset
  nodeLabels:
    gpu: "true"
  nodeTaints:
    nvidia.com/gpu: "true:NoSchedule"
  install:
    extensions:
      - image: ghcr.io/siderolabs/nfs-utils:v2.7.2
      - image: ghcr.io/siderolabs/qemu-guest-agent:v10.2.0
      - image: ghcr.io/siderolabs/nvidia-open-gpu-kernel-modules:550.x-v1.9.5
      - image: ghcr.io/siderolabs/nvidia-container-toolkit:550.x-v1.17.x
```

#### Control plane (k8s-master) — OIDC + audit

```yaml
cluster:
  apiServer:
    extraArgs:
      oidc-issuer-url: https://authentik.viktorbarzin.me/application/o/kubernetes/
      oidc-client-id: kubernetes
      oidc-username-claim: email
      oidc-groups-claim: groups
      audit-policy-file: /etc/kubernetes/policies/audit-policy.yaml
      audit-log-path: /var/log/kubernetes/audit.log
      audit-log-maxage: "7"
      audit-log-maxbackup: "3"
      audit-log-maxsize: "100"
    extraVolumes:
      - hostPath: /etc/kubernetes/policies
        mountPath: /etc/kubernetes/policies
        readOnly: true
      - hostPath: /var/log/kubernetes
        mountPath: /var/log/kubernetes
```

### Migration Path (if proceeding)

This is NOT an in-place migration. Talos replaces kubeadm entirely.

1. **Build Talos machine configs** in the repo (YAML per node, templated via Terraform)
2. **Create `stacks/talos/` stack** — Proxmox VM creation + Talos provider resources
3. **Download Talos ISO** with extensions (nfs-utils, qemu-guest-agent, nvidia) from Image Factory
4. **Stand up parallel cluster** — new Talos VMs on unused IPs (Proxmox has ~46GB RAM headroom)
5. **Bootstrap control plane** via `talosctl bootstrap`
6. **Point existing Terraform service stacks** at new cluster kubeconfig
7. **Apply all service stacks** — NFS-backed services point at same data, no data migration
8. **Validate everything works** — run cluster healthcheck, test all services
9. **Tear down old Ubuntu VMs**
10. **Reassign IPs** if desired (reconfigure Talos nodes to use original IPs)

### What Gets Eliminated

If migrated, these files/patterns become unnecessary:
- `modules/create-template-vm/cloud_init.yaml`
- `modules/create-template-vm/` (entire module)
- `modules/create-vm/` (replaced by Talos provider)
- `scripts/setup_containerd_mirrors.sh`
- `stacks/platform/modules/rbac/apiserver-oidc.tf` (SSH+sed block)
- `stacks/platform/modules/rbac/audit-policy.tf` (SSH+sed block)
- `stacks/platform/modules/monitoring/loki.tf` sysctl-inotify DaemonSet
- `playbooks/deploy_node_exporter.yaml`
- `null_resource.gpu_node_taint` in nvidia module
- The undocumented GPU label manual step

## ROI Analysis

### Costs

| Cost | Estimate |
|---|---|
| Learn Talos + talosctl workflow | Significant (new paradigm, no SSH) |
| Build Talos Terraform stack | Medium (new stack, provider, machine configs) |
| Build custom Talos ISO with extensions | Low (Image Factory makes this easy) |
| Parallel cluster setup + validation | Medium-High (must test every service) |
| NVIDIA driver testing on Talos | Medium (version-locking, open kernel modules) |
| Loss of SSH node access | Ongoing (workflow change) |
| Ongoing: Talos upgrades require extension version alignment | Low-Medium |

### Benefits

| Benefit | Value |
|---|---|
| Zero configuration drift (structural guarantee) | High (but current drift risk is actually low) |
| Single-command node rebuild | High |
| Eliminates ~10 files/patterns of provisioning code | Medium |
| Atomic OS upgrades with rollback | Medium |
| Declarative API server config (no SSH+sed) | Medium |
| GPU label/taint properly codified | Low (could fix this today in 5 minutes) |
| Immutable, minimal attack surface | Low-Medium (nodes aren't internet-exposed) |

### Honest Assessment

The current drift surface is small and well-understood. The highest-risk items are:
1. **API server OIDC/audit config** — SSH+sed is fragile but rarely changes
2. **containerd mirrors** — baked into template, stable once set
3. **GPU label** — missing from code but trivially fixable

Most node config only runs at provisioning time (cloud-init) and doesn't drift because nobody SSHes into nodes to change things in practice.

**Talos solves a real problem, but the problem isn't causing real pain today.** The migration cost is high relative to the current risk. It would make sense to revisit if:
- Adding more nodes frequently (scaling the cluster)
- Experiencing actual drift incidents
- Rebuilding the cluster for other reasons (K8s major version upgrade, hardware change)
- The current SSH+sed patterns break and need rework anyway

## Quick Wins (Do Instead / Do Now)

These close most of the drift gap without changing the OS:

1. **Add GPU label to Terraform** — `kubectl label` in existing nvidia `null_resource` or a `kubernetes_labels` resource
2. **Make API server OIDC config idempotent** — improve the grep-before-sed checks
3. **Move node-exporter to K8s DaemonSet** — instead of Ansible playbook on host
4. **Document the full node rebuild procedure** — cloud-init template → clone → join → verify

## References

- Talos docs: https://docs.siderolabs.com/talos/v1.9/
- Talos Proxmox guide: https://docs.siderolabs.com/talos/v1.9/platform-specific-installations/virtualized-platforms/proxmox/
- Talos NVIDIA GPU: https://docs.siderolabs.com/talos/v1.9/configure-your-talos-cluster/hardware-and-drivers/nvidia-gpu
- Talos Terraform provider: https://registry.terraform.io/providers/siderolabs/talos/latest (v0.10.1)
- Talos system extensions: https://github.com/siderolabs/extensions
- Talos Image Factory: https://factory.talos.dev/
