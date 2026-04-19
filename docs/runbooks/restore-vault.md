# Restore Vault (Raft)

Last updated: 2026-04-06

## Prerequisites
- `kubectl` access to the cluster
- Vault root token (from `vault-root-token` secret in `vault` namespace — manually created, independent of automation)
- Raft snapshot available on NFS at `/mnt/main/vault-backup/`
- Unseal keys (stored securely — check `secret/viktor` in Vault or emergency kit)

## Backup Location
- NFS: `/mnt/main/vault-backup/vault-raft-YYYYMMDD-HHMMSS.db`
- Mirrored to sda: `/mnt/backup/nfs-mirror/vault-backup/` (PVE host 192.168.1.127)
- Replicated to Synology NAS: `Synology/Backup/Viki/pve-backup/nfs-mirror/vault-backup/`
- Retention: 30 days (on NFS), latest only (on sda), unlimited (on Synology)
- Schedule: Weekly on Sundays at 02:00 (`0 2 * * 0`)

## CRITICAL: Vault is a dependency for many services
Vault provides secrets to the entire cluster via ESO (External Secrets Operator). A Vault outage affects:
- All ExternalSecrets (43 secrets + 9 DB-creds secrets)
- Vault DB engine password rotation
- K8s credentials engine
- CI/CD secret sync

**Priority: Restore Vault before any other service (except etcd).**

## Restore Procedure

### 1. Identify the snapshot to restore
```bash
# List available snapshots
ls -lt /mnt/main/vault-backup/vault-raft-*.db | head -10
```

### 2. Restore Raft snapshot
```bash
# Get root token
VAULT_TOKEN=$(kubectl get secret vault-root-token -n vault -o jsonpath='{.data.vault-root-token}' | base64 -d)

# Port-forward to Vault
kubectl port-forward svc/vault-active -n vault 8200:8200 &

# Restore the snapshot (this will overwrite current state)
export VAULT_ADDR=http://127.0.0.1:8200
export VAULT_TOKEN
vault operator raft snapshot restore -force /path/to/vault-raft-YYYYMMDD-HHMMSS.db
```

### 3. Unseal Vault (if sealed after restore)

> **Note:** Vault now has an auto-unseal sidecar that automatically unseals pods
> using the `vault-unseal-key` K8s Secret. The manual procedure below is a
> fallback if auto-unseal fails.

```bash
# Check seal status
vault status

# If sealed, unseal with keys (need threshold number of keys)
vault operator unseal <key1>
vault operator unseal <key2>
vault operator unseal <key3>
```

### 4. Verify restoration
```bash
# Check Vault health
vault status

# Check raft peers
vault operator raft list-peers

# Verify key secrets exist
vault kv get secret/viktor
vault kv list secret/

# Check DB engine
vault list database/roles

# Check K8s engine
vault list kubernetes/roles
```

### 5. Trigger ESO refresh
After Vault restore, ExternalSecrets may need a refresh:
```bash
# Restart ESO to force re-sync
kubectl rollout restart deployment -n external-secrets

# Check ExternalSecret status
kubectl get externalsecrets -A | grep -v "SecretSynced"
```

## Alternative: Restore from sda Backup

If the Proxmox host NFS mount is unavailable but the PVE host itself is accessible:

```bash
# 1. SSH to PVE host
ssh root@192.168.1.127

# 2. Find the latest snapshot
ls -lt /mnt/backup/nfs-mirror/vault-backup/

# 3. Copy snapshot to a location accessible from cluster
# Port-forward to Vault and restore
kubectl port-forward svc/vault-active -n vault 8200:8200 &
export VAULT_ADDR=http://127.0.0.1:8200
export VAULT_TOKEN=$(kubectl get secret vault-root-token -n vault -o jsonpath='{.data.vault-root-token}' | base64 -d)

# Copy snapshot from PVE host to local workstation, then restore
scp root@192.168.1.127:/mnt/backup/nfs-mirror/vault-backup/vault-raft-YYYYMMDD-HHMMSS.db ./
vault operator raft snapshot restore -force ./vault-raft-YYYYMMDD-HHMMSS.db
```

## Alternative: Restore from Synology (if PVE host is down)

If the PVE host itself is unavailable:

```bash
# 1. SSH to Synology NAS
ssh Administrator@192.168.1.13

# 2. Navigate to backup directory
cd /volume1/Backup/Viki/nfs/vault-backup/

# 3. Copy snapshot to local workstation
scp Administrator@192.168.1.13:/volume1/Backup/Viki/nfs/vault-backup/vault-raft-YYYYMMDD-HHMMSS.db ./

# 4. Restore via port-forward (same as above)
```

## Full Vault Rebuild (from zero)
If Vault needs to be rebuilt from scratch:
1. Comment out data sources + OIDC config in `stacks/vault/main.tf`
2. Apply Helm release: `scripts/tg apply -target=helm_release.vault stacks/vault`
3. Initialize: `vault operator init`
4. Unseal with generated keys
5. Restore raft snapshot (step 2 above)
6. Populate `secret/vault` with OIDC credentials
7. Uncomment data sources + OIDC
8. Re-apply: `scripts/tg apply stacks/vault`

## Estimated Time
- Snapshot restore + unseal: ~10 minutes
- Full rebuild: ~30-45 minutes
