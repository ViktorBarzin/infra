# Restore Vault (Raft)

## Prerequisites
- `kubectl` access to the cluster
- Vault root token (from `vault-root-token` secret in `vault` namespace — manually created, independent of automation)
- Raft snapshot available on NFS at `/mnt/main/vault-backup/`
- Unseal keys (stored securely — check `secret/viktor` in Vault or emergency kit)

## Backup Location
- NFS: `/mnt/main/vault-backup/vault-raft-YYYYMMDD-HHMMSS.db`
- Replicated to Synology NAS (192.168.1.13) via TrueNAS ZFS replication
- Retention: 30 days
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
