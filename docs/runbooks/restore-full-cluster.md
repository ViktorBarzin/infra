# Full Cluster Rebuild

Last updated: 2026-04-06

## When to Use
- Complete cluster failure (all VMs lost)
- etcd corruption requiring full rebuild
- Proxmox host failure requiring fresh VM provisioning

## Prerequisites
- Proxmox host (192.168.1.127) accessible, with NFS exports on `/srv/nfs` and `/srv/nfs-ssd`
- Synology NAS (192.168.1.13) accessible for offsite backup restore if the PVE host backup disk is also lost
- sda backup disk mounted at `/mnt/backup` on PVE host (or restore from Synology first)
- Git repo with infra code
- SOPS age keys for state decryption (`~/.config/sops/age/keys.txt`)
- Vault unseal keys (emergency kit)

## Rebuild Order

The rebuild must follow dependency order. Each layer depends on the one before it.

### Phase 1: Infrastructure (Proxmox VMs)
```bash
# 1. Provision VMs via Terraform
cd infra
scripts/tg apply stacks/infra

# 2. Wait for VMs to boot and be reachable
# k8s-master, k8s-node3, k8s-node4, k8s-node5
# (node1 has GPU workloads, node2 excluded from MySQL anti-affinity only — both are active cluster members)
```

### Phase 2: Kubernetes Control Plane
```bash
# 3. Initialize kubeadm on master (if starting fresh)
sudo kubeadm init --config /etc/kubernetes/kubeadm-config.yaml

# 4. Join worker nodes
# Get join command from master, run on each node

# 5. OR restore etcd from snapshot (see restore-etcd.md)
# This restores all K8s objects from the snapshot time
```

### Phase 3: Storage Layer
```bash
# 6. Deploy CSI drivers (NFS + Proxmox)
scripts/tg apply stacks/nfs-csi
scripts/tg apply stacks/proxmox-csi

# 7. Verify PVs are accessible
kubectl get pv
kubectl get pvc -A | grep -v Bound
```

### Phase 3.5: Restore PVC Data from sda Backup

After storage layer is deployed, restore PVC data from the sda backup disk:

```bash
# 8a. List available backup weeks
ssh root@192.168.1.127
ls -l /mnt/backup/pvc-data/

# 8b. For each critical PVC, restore files:
# Example: vaultwarden-data-proxmox
WEEK="2026-14"  # Use most recent week
NAMESPACE="vaultwarden"
PVC_NAME="vaultwarden-data-proxmox"

# Find the PV LV name
kubectl get pv -o custom-columns='PV:.metadata.name,PVC:.spec.claimRef.name,NS:.spec.claimRef.namespace,HANDLE:.spec.csi.volumeHandle' | grep $PVC_NAME

# Assuming volumeHandle is "local-lvm:vm-999-pvc-abc123"
LV_NAME="vm-999-pvc-abc123"

# Mount the LV
lvchange -ay pve/$LV_NAME
mkdir -p /mnt/restore-temp
mount /dev/pve/$LV_NAME /mnt/restore-temp

# Restore from backup
rsync -avP --delete /mnt/backup/pvc-data/$WEEK/$NAMESPACE/$PVC_NAME/ /mnt/restore-temp/

# Unmount
umount /mnt/restore-temp
lvchange -an pve/$LV_NAME

# 8c. Repeat for all critical PVCs (prioritize: vaultwarden, vault, redis, nextcloud)
```

**Note on pfSense restore**: If pfSense needs restoration, restore `config.xml` from `/mnt/backup/pfsense/<week>/config.xml` via web UI, or full filesystem tar for custom scripts.

**Note on PVE config restore**: If custom scripts/timers are lost, restore from `/mnt/backup/pve-config/` (daily-backup, offsite-sync-backup, lvm-pvc-snapshot scripts + timers).

### Phase 4: Vault (secrets foundation)
```bash
# 8. Deploy Vault (see restore-vault.md for full procedure)
scripts/tg apply stacks/vault

# 9. Initialize/unseal/restore raft snapshot
# 10. Verify ESO can connect
scripts/tg apply stacks/external-secrets
kubectl get externalsecrets -A
```

### Phase 5: Platform Services
```bash
# 11. Deploy platform stack (Traefik, monitoring, Kyverno, etc.)
scripts/tg apply stacks/platform

# 12. Verify ingress is working
curl -s -o /dev/null -w "%{http_code}" https://viktorbarzin.me/
```

### Phase 6: Databases
```bash
# 13. Deploy database stack
scripts/tg apply stacks/dbaas

# 14. Wait for CNPG and InnoDB clusters to initialize
kubectl wait --for=condition=Ready cluster/pg-cluster -n dbaas --timeout=600s

# 15. Restore PostgreSQL from dump (see restore-postgresql.md)
# 16. Restore MySQL from dump (see restore-mysql.md)
```

### Phase 7: Application Services
```bash
# 17. Deploy remaining stacks in any order
for stack in vaultwarden immich nextcloud linkwarden health; do
  scripts/tg apply stacks/$stack
done

# 18. Restore Vaultwarden (see restore-vaultwarden.md)
```

### Phase 8: Verification
```bash
# 19. Check all pods are running
kubectl get pods -A | grep -v Running | grep -v Completed

# 20. Check all ingresses respond
kubectl get ingress -A -o jsonpath='{range .items[*]}{.spec.rules[0].host}{"\n"}{end}' | while read host; do
  code=$(curl -s -o /dev/null -w "%{http_code}" "https://$host/" 2>/dev/null)
  echo "$host: $code"
done

# 21. Check monitoring
# Verify Prometheus targets: https://prometheus.viktorbarzin.me/targets
# Verify Alertmanager: https://alertmanager.viktorbarzin.me/

# 22. Run backup CronJobs manually to establish baseline
kubectl create job --from=cronjob/backup-etcd manual-etcd-backup -n default
kubectl create job --from=cronjob/postgresql-backup manual-pg-backup -n dbaas
kubectl create job --from=cronjob/mysql-backup manual-mysql-backup -n dbaas
kubectl create job --from=cronjob/vault-raft-backup manual-vault-backup -n vault
kubectl create job --from=cronjob/vaultwarden-backup manual-vw-backup -n vaultwarden
```

## Dependency Graph
```
etcd → K8s API → CSI Drivers → Restore PVC data from sda → Vault → ESO → Platform → Databases → Apps
                                                                                          ↓
                                                                                    Restore DB dumps from
                                                                                    /mnt/backup/nfs-mirror
                                                                                    or Synology/pve-backup
```

## Estimated Time
- Full cluster rebuild from scratch: ~2-4 hours
- With etcd restore (objects preserved): ~1-2 hours
- Individual service restore: ~10-30 minutes each
