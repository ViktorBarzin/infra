# Restore Vault (Raft)

Last updated: 2026-10-09 (Vault 2.1.2)

## Prerequisites
- `kubectl` access to the cluster
- Vault root token (from `vault-root-token` secret in `vault` namespace — manually created, independent of automation)
- Raft snapshot available on NFS at `192.168.1.127:/srv/nfs/vault-backup/` (PVC `vault-backup-host` in the `vault` namespace)
- The unseal key (single Shamir share, threshold 1; kept in the `vault-unseal-key` K8s Secret, also in `secret/viktor` or the emergency kit)

## Backup Location
- NFS: `192.168.1.127:/srv/nfs/vault-backup/vault-raft-YYYYMMDD-HHMMSS.db`
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
ls -lt /srv/nfs/vault-backup/vault-raft-*.db | head -10   # on the PVE host 192.168.1.127
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

Unsealing is automatic. The seal config is a single Shamir share (shares=1,
threshold=1), and every Vault pod runs an `auto-unseal` sidecar that checks
`vault status` every 10 s and runs `vault operator unseal` with the key from the
`vault-unseal-key` K8s Secret (key `unseal-key`) whenever the pod is sealed. A
pod that restarts after the restore unseals itself within about 10 s; its
sidecar logs `Vault is sealed, unsealing...` once:

```bash
kubectl logs -n vault vault-0 -c auto-unseal | tail -3
```

Manual fallback, only if the sidecar is not running or the Secret is missing:

```bash
vault status                  # Sealed: true
vault operator unseal <key>   # one key, from secret/viktor or the emergency kit
```

`sys/unseal` needs no token in Vault 2.x either, so the sidecar and the manual
fallback work the same as on 1.x.

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
3. Initialize with a single share, which is what the auto-unseal sidecar expects:
   `vault operator init -key-shares=1 -key-threshold=1`
4. Store the unseal key where the sidecar reads it:
   `kubectl create secret generic vault-unseal-key -n vault --from-literal=unseal-key=<key>`.
   The pods unseal themselves within about 10 s (or run `vault operator unseal <key>`).
5. Restore raft snapshot (step 2 above). The snapshot carries the old cluster's
   keyring and root token, so after the restore Vault unseals only with the old
   unseal key and accepts the old root token, not the ones `init` printed. Put
   the old key into `vault-unseal-key` (same key name) so the sidecar can unseal
   restarted pods.
6. Recreate the `vault-root-token` Secret (key `vault-root-token`) for the backup CronJob if it is missing
7. Populate `secret/vault` with OIDC credentials
8. Uncomment data sources + OIDC
9. Re-apply: `scripts/tg apply stacks/vault`

### Vault 2.x: generate-root and rekey need a token

From Vault 2.0, the `sys/generate-root` and `sys/rekey` endpoints
(`vault operator generate-root`, `vault operator rekey`) require a Vault token as
well as the unseal key. The server config key `enable_unauthenticated_access`
(values `"generate-root"`, `"rekey"`) restores the old behaviour; we do not set it.
If the root token is lost, use any token with `sudo` on `sys/generate-root` (for
example the devvm admin token, policy `vault-admin`) to start generate-root.
With no working token at all, restore a snapshot whose root token is known.

## Estimated Time
- Snapshot restore + unseal: ~10 minutes
- Full rebuild: ~30-45 minutes
