# Proxmox CSI Migration — Cleanup TODO

**Date**: 2026-04-03
**Status**: Pending (do when confident everything is stable)
**Prerequisites**: All services healthy on proxmox-lvm for 1+ week

## Context

The iSCSI → Proxmox CSI migration is complete. All 13 block PVCs are on `proxmox-lvm`, all 41 databases (21 PG + 20 MySQL) restored and verified. This doc tracks the remaining cleanup.

## TODO

### 1. Remove democratic-csi iSCSI stack

Frees 5 pods (~500Mi RAM), removes unused CSI driver.

```bash
# Delete Helm release
KUBECONFIG=./config helm delete democratic-csi-iscsi -n iscsi-csi

# Delete namespace
kubectl delete namespace iscsi-csi

# Remove iscsi-truenas StorageClass (verify no PVCs reference it first)
kubectl get pvc -A | grep iscsi-truenas  # should only show orphaned PVCs
kubectl delete storageclass iscsi-truenas

# Remove Terraform stack (or mark as disabled)
# Option A: delete stacks/iscsi-csi/ directory
# Option B: keep for reference, remove from CI pipeline
```

### 2. Delete orphaned iSCSI PVCs

These are old copies from before the migration. No pods mount them.

```bash
# Verify nothing mounts them
for pvc in old-pg-data old-mysql-data; do
  kubectl get pods -n dbaas -o json | grep -q "$pvc" && echo "IN USE: $pvc" || echo "SAFE: $pvc"
done

# Delete helper PVCs
kubectl delete pvc old-pg-data old-mysql-data -n dbaas

# Delete old service PVCs
kubectl delete pvc nextcloud-data-iscsi -n nextcloud
kubectl delete pvc novelapp-data -n novelapp
kubectl delete pvc vaultwarden-data-iscsi -n vaultwarden
kubectl delete pvc ebooks-calibre-config-iscsi -n ebooks
```

### 3. Clean up TrueNAS iSCSI zvols

After deleting PVCs, the underlying PVs (reclaimPolicy: Retain) and TrueNAS zvols remain.

```bash
# Delete Released PVs
kubectl get pv | grep Released | grep iscsi-truenas | awk '{print $1}' | xargs kubectl delete pv

# SSH to TrueNAS and clean up zvols
ssh root@10.0.10.15 'zfs list -t volume main/iscsi | grep csi-'
# Review list, then destroy each:
# zfs destroy main/iscsi/<zvol-name>
```

### 4. Remove Vault secrets (optional)

These were used by democratic-csi SSH driver. No longer needed.

```bash
# Remove from secret/platform (used by stacks/iscsi-csi/main.tf)
vault kv patch secret/platform truenas_api_key=REMOVED truenas_ssh_private_key=REMOVED
```

### 5. Update CLAUDE.md

Remove iSCSI references from:
- `infra/.claude/CLAUDE.md` — Storage & Backup Architecture section
- `AGENTS.md` if any storage references

### 6. Commit and push

```bash
git add stacks/ebooks/main.tf docs/ .claude/
git commit -m "proxmox-csi cleanup: remove democratic-csi, delete orphaned PVCs [ci skip]"
git push
```
