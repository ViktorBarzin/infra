# Restore etcd

## Prerequisites
- SSH access to `k8s-master` node
- etcd snapshot available on NFS at `/mnt/main/etcd-backup/`
- etcd PKI certs at `/etc/kubernetes/pki/etcd/` on master node

## Backup Location
- NFS: `/mnt/main/etcd-backup/etcd-snapshot-YYYYMMDD-HHMMSS.db`
- Replicated to Synology NAS (192.168.1.13) via Proxmox host offsite-sync-backup (inotify-driven rsync)
- Retention: 30 days
- Schedule: Daily at 00:00

## CRITICAL: etcd is the foundation of the cluster
Restoring etcd will reset the entire Kubernetes state to the snapshot time. All objects created after the snapshot will be lost. This is a last-resort operation.

**Only restore etcd if the control plane is completely broken.**

## Restore Procedure

### 1. SSH to the master node
```bash
ssh k8s-master
```

### 2. Identify the snapshot to restore
```bash
ls -lt /mnt/main/etcd-backup/etcd-snapshot-*.db | head -10
```

### 3. Stop the API server and etcd
```bash
# Move static pod manifests to stop them
sudo mv /etc/kubernetes/manifests/kube-apiserver.yaml /etc/kubernetes/
sudo mv /etc/kubernetes/manifests/etcd.yaml /etc/kubernetes/

# Wait for pods to stop
sudo crictl ps | grep -E "etcd|apiserver"
```

### 4. Back up current etcd data
```bash
sudo mv /var/lib/etcd /var/lib/etcd.bak.$(date +%Y%m%d-%H%M%S)
```

### 5. Restore the snapshot
```bash
sudo ETCDCTL_API=3 etcdctl snapshot restore /mnt/main/etcd-backup/etcd-snapshot-YYYYMMDD-HHMMSS.db \
  --data-dir=/var/lib/etcd \
  --name=k8s-master \
  --initial-cluster=k8s-master=https://127.0.0.1:2380 \
  --initial-advertise-peer-urls=https://127.0.0.1:2380
```

### 6. Fix permissions
```bash
sudo chown -R root:root /var/lib/etcd
```

### 7. Restart etcd and API server
```bash
sudo mv /etc/kubernetes/etcd.yaml /etc/kubernetes/manifests/
# Wait for etcd to be ready
sleep 30
sudo mv /etc/kubernetes/kube-apiserver.yaml /etc/kubernetes/manifests/
```

### 8. Verify restoration
```bash
# Check etcd health
sudo ETCDCTL_API=3 etcdctl \
  --endpoints=https://127.0.0.1:2379 \
  --cacert=/etc/kubernetes/pki/etcd/ca.crt \
  --cert=/etc/kubernetes/pki/etcd/healthcheck-client.crt \
  --key=/etc/kubernetes/pki/etcd/healthcheck-client.key \
  endpoint health

# Check cluster status
kubectl get nodes
kubectl get pods -A | head -20
```

### 9. Reconcile state
After etcd restore, some objects may be stale:
```bash
# Re-apply critical infrastructure
cd /path/to/infra
scripts/tg apply stacks/platform

# Check for orphaned resources
kubectl get pods -A | grep -E "Terminating|Error|Unknown"
```

## Estimated Time
- Snapshot restore: ~10-15 minutes
- Full reconciliation: ~30-60 minutes (depends on drift)
