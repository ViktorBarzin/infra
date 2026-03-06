---
name: nfsv4-idmapd-uid-mapping
description: |
  Fix for all file UIDs showing as 65534 (nobody) inside Kubernetes containers when using
  NFS volumes from TrueNAS/FreeBSD. Use when: (1) ls -lan inside a container shows all files
  owned by 65534:65534 despite correct ownership on the NFS server, (2) PostgreSQL fails with
  "data directory has wrong ownership", (3) chown inside containers returns "Invalid argument"
  on NFS volumes, (4) services that check file ownership (PostgreSQL, MySQL) crash on startup,
  (5) the same NFS mount shows correct UIDs on the host but 65534 inside containers,
  (6) NFSv4.2 appears in container mount output even though host mounts use NFSv3.
  Root cause: Kubernetes inline NFS volumes auto-negotiate NFSv4.2 (not NFSv3), and NFSv4
  idmapd fails to map UIDs when domains don't match or users don't exist on the server.
author: Claude Code
version: 1.0.0
date: 2026-03-01
---

# NFSv4 idmapd UID Mapping — All Files Show as nobody (65534)

## Problem
All files on NFS volumes appear owned by UID 65534 (nobody:nogroup) inside Kubernetes
containers, even though `ls -lan` on the NFS server shows the correct UIDs (e.g., 999, 472).
This breaks any service that checks file ownership: PostgreSQL refuses to start ("data
directory has wrong ownership"), MySQL's entrypoint `chown` fails with "Invalid argument",
and any `chown` inside the container returns EINVAL.

## Context / Trigger Conditions

- TrueNAS CORE (FreeBSD) or TrueNAS SCALE as NFS server
- NFSv4 enabled on the NFS server (`v4: true` in TrueNAS NFS config)
- Kubernetes using inline NFS volumes (not PV/PVC with mount options)
- **Key symptom**: `mount` inside the container shows `type nfs4 (vers=4.2,...)` even
  though existing kubelet mounts on the host show `vers=3`
- **Key symptom**: Same NFS path mounted directly on the host shows correct UIDs, but
  inside any container shows 65534

## Root Cause

Kubernetes inline NFS volumes don't support `mountOptions`. When kubelet mounts NFS for a
new pod, the Linux NFS client auto-negotiates the highest available version — NFSv4.2 if
the server supports it.

NFSv4 uses **idmapd** for UID translation: the server translates UID→username (e.g.,
`999→postgres@domain`), sends the username string over the wire, and the client translates
it back to a local UID. This fails when:

1. **Domain mismatch**: Server domain (from hostname) differs from client domain
   - TrueNAS: `viktorbarzin.me` (from `truenas.viktorbarzin.me`)
   - K8s nodes: `viktorbarzin.lan` (from `k8s-node4.viktorbarzin.lan`)
   - When domains don't match, ALL UIDs fall back to `nobody` (65534)

2. **Unknown UIDs**: Even with matching domains, if the NFS server has no local user for
   UID 999 (common for container UIDs), idmapd maps it to `nobody`

**Why existing mounts work**: Older kubelet mounts (established before NFSv4 was enabled,
or when the NFS client defaulted to v3) continue using NFSv3 with direct numeric UID
passthrough. Only NEW mounts negotiate NFSv4.2.

## Solution

**Fix on TrueNAS (no NFS restart required):**

```bash
# 1. Enable NFSv3-style numeric UID passthrough for NFSv4
midclt call nfs.update '{"v4_v3owner": true, "v4_domain": "viktorbarzin.lan"}'

# 2. Restart nfsuserd with the correct domain (NOT nfsd — that would crash the cluster)
killall nfsuserd
nfsuserd -domain viktorbarzin.lan -force
```

**Clear caches on all K8s nodes:**

```bash
for node in k8s-node1 k8s-node2 k8s-node3 k8s-node4; do
  ssh wizard@$node "sudo nfsidmap -c && sudo keyctl clear @u"
done
```

**Key settings explained:**
- `v4_v3owner = true`: Makes NFSv4 use numeric UID passthrough like NFSv3, completely
  bypassing the username-based idmapd translation. **This is the critical fix.**
- `v4_domain`: Should match the K8s nodes' DNS domain (check with `hostname -d` on a node)
- `nfsuserd -domain <domain> -force`: FreeBSD daemon that handles NFSv4 user mapping.
  The `-force` flag is required if it thinks it's already running.

## Verification

```bash
# Run a test pod and check UIDs
kubectl run nfs-test --rm -it --restart=Never --image=alpine \
  --overrides='{"spec":{"containers":[{"name":"test","image":"alpine",
  "command":["sh","-c","ls -lan /data | head -5"],
  "volumeMounts":[{"name":"nfs","mountPath":"/data"}]}],
  "volumes":[{"name":"nfs","nfs":{"server":"10.0.10.15","path":"/mnt/main/some-path"}}]}}'

# Should show actual UIDs (e.g., 999, 472) instead of 65534
```

## Debugging Steps

If you're not sure whether this is the issue:

```bash
# 1. Check mount type INSIDE a container (not on the host!)
kubectl exec <pod> -- mount | grep nfs
# If it shows "type nfs4" with "vers=4.2" — this is the issue

# 2. Compare UIDs: host vs container
# On host (via kubelet mount path):
sudo ls -lan /var/lib/kubelet/pods/<pod-uid>/volumes/kubernetes.io~nfs/<vol>/
# Inside container:
kubectl exec <pod> -- ls -lan /mount-path/

# 3. Check TrueNAS NFS config
midclt call nfs.config  # Look for v4: true, v4_v3owner, v4_domain

# 4. Check nfsuserd is running with the right domain
ps aux | grep nfsuserd  # On TrueNAS
```

## Notes

- **NEVER restart NFS (nfsd)** on TrueNAS — it causes mount failures across ALL pods
  cluster-wide. Only restart `nfsuserd` (the ID mapping daemon).
- Existing NFSv3 mounts continue working fine. The issue only affects NEW mounts.
- The `v4_v3owner` setting is persistent across TrueNAS reboots (stored in middleware config).
- The `nfsuserd` restart is NOT persistent — TrueNAS may restart it without the `-domain`
  flag after a reboot. The `v4_domain` setting in the middleware config should handle this,
  but verify after any TrueNAS restart.
- On Linux NFS servers (not FreeBSD/TrueNAS), the equivalent fix is setting `Domain` in
  `/etc/idmapd.conf` on both server and all clients.
