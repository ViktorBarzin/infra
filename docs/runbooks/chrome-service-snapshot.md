# Runbook — chrome-service snapshot pipeline

Operational playbook for the hourly cookie-snapshot pipeline that warms
external Claude Code sessions on the dev box. Architecture in
`architecture/chrome-service.md`.

## At a glance

| Component | Where | When | What |
|---|---|---|---|
| chrome-service Deployment | `chrome-service` ns | always-on | headed chromium, CDP :9222, persistent /profile/chromium-data |
| snapshot-server sidecar | same pod | always-on | serves `/api/snapshot`, bearer-gated, port 8088 |
| snapshot-harvester CronJob | `chrome-service` ns | `23 * * * *` | dumps `storage_state()` via CDP → `/profile/snapshots/storage-state.json` |
| dev-box refresh timer | each dev box | hourly | curls `chrome.viktorbarzin.me/api/snapshot` → `~/.cache/playwright-shared-storage-state.json` |
| dev-box `playwright-mcp.service` | each dev box | always-on | `@playwright/mcp --isolated --storage-state=…` per-MCP-connection contexts |

## Day-to-day

### Log into a new site (warm the profile)

1. Open `https://chrome.viktorbarzin.me/` (Authentik will gate).
2. The noVNC view of the in-cluster headed chromium loads. Click on the
   browser window, navigate, log in.
3. Cookies land in `/profile/chromium-data/Default/Cookies` on the PVC.
4. Within ≤60 min, the snapshot-harvester CronJob picks them up and
   writes the snapshot. Within ≤60 min after that, dev boxes pull the
   new file. New Claude Code sessions see the new cookies.
5. To skip the wait: trigger the harvester now (next section).

### Trigger snapshot harvester manually

```bash
kubectl -n chrome-service create job \
  --from=cronjob/chrome-service-snapshot-harvester \
  snapshot-harvest-$(date +%s)

# Watch logs
kubectl -n chrome-service logs -f -l job-name=$(kubectl -n chrome-service get jobs -o name | tail -1 | cut -d/ -f2)
```

Expected: `wrote snapshot (… bytes) to /profile/snapshots/storage-state.json`.

### Trigger dev-box refresh manually

```bash
# On the dev box, as the user whose Claude Code sessions need the new state:
systemctl --user start playwright-snapshot-refresh.service

# Or directly:
/usr/local/bin/playwright-snapshot-refresh

# Verify
ls -la ~/.cache/playwright-shared-storage-state.json
```

### Inspect the current snapshot

```bash
# In-cluster (from any pod with kubectl exec into the chrome-service pod):
kubectl -n chrome-service exec deploy/chrome-service -c snapshot-server -- \
  cat /profile/snapshots/storage-state.json | jq '.cookies | length'

# Externally (via the bearer-gated endpoint):
TOKEN=$(vault kv get -field=api_bearer_token secret/chrome-service)
curl -fsSL -H "Authorization: Bearer $TOKEN" \
  https://chrome.viktorbarzin.me/api/snapshot | jq '.cookies | length'
```

## Failure modes

### "no browser contexts found"

The harvester reports `no browser contexts found — chrome-service may
not have launched a persistent context yet` and exits non-zero.

**Cause**: chromium just started and hasn't created its default context
yet, or it crashed.

**Fix**: check chrome-service pod logs (`kubectl -n chrome-service logs
deploy/chrome-service -c chrome-service`). The next hourly run will
retry. If chromium is wedged: `kubectl -n chrome-service rollout restart
deploy/chrome-service` (strategy = Recreate, brief downtime).

### "connect_over_cdp failed"

Harvester or any in-cluster caller can't reach the CDP endpoint.

**Cause**: chrome-service pod not Ready, NetworkPolicy doesn't admit
the caller's namespace, or chromium isn't listening on :9222.

**Diagnose**:
```bash
kubectl -n chrome-service get pods
kubectl -n chrome-service describe networkpolicy chrome-service-ws-ingress

# From inside the cluster (e.g. a debug pod in chrome-service ns):
nc -zv chrome-service.chrome-service.svc.cluster.local 9222
curl -fsSL http://chrome-service.chrome-service.svc.cluster.local:9222/json/version
```

**Fix**: depends on the diagnosis. NetworkPolicy needs the caller's
namespace label or an explicit name-fallback. If chromium isn't
binding, check the container logs.

### Dev-box `playwright-snapshot-refresh` returns 401

The bearer token in `~/.config/playwright/token` doesn't match the
server's. Almost always means the Vault secret was rotated and the
local cache is stale.

**Fix**:
```bash
vault login -method=oidc  # if needed
vault kv get -field=api_bearer_token secret/chrome-service > ~/.config/playwright/token
chmod 600 ~/.config/playwright/token
systemctl --user start playwright-snapshot-refresh.service
```

### Dev-box `playwright-snapshot-refresh` returns 404 with "snapshot not yet available"

The harvester hasn't run successfully yet (fresh cluster, or all
recent runs failed). Trigger it manually (see "Trigger snapshot
harvester manually").

### Claude Code sessions still see old cookies

The MCP server reads the snapshot file at process start and seeds each
new context with it. **Existing MCP sessions don't hot-reload** — they
keep the cookies they were seeded with at session start. New sessions
get the fresh snapshot.

**Fix**: restart the MCP server on the dev box to pick up the new file:
```bash
systemctl --user restart playwright-mcp.service
```

### Snapshot file is suspiciously small or empty cookies array

The persistent chromium context isn't holding any cookies. Probably
means the user hasn't logged into anything via noVNC, or chromium was
relaunched without preserving `/profile/chromium-data`.

**Diagnose**:
```bash
kubectl -n chrome-service exec deploy/chrome-service -c chrome-service -- \
  ls -la /profile/chromium-data/Default/Cookies
```

A populated `Cookies` SQLite file should be several hundred KB once
real logins exist. If it's missing or empty, log in via noVNC.

## Token rotation

```bash
# Rotate Vault secret (32-byte URL-safe random).
vault kv put secret/chrome-service \
  api_bearer_token=$(python3 -c 'import secrets; print(secrets.token_urlsafe(32))')

# Reloader auto-restarts chrome-service pod (snapshot-server picks up new token).

# On EVERY dev box that pulls the snapshot:
vault kv get -field=api_bearer_token secret/chrome-service > ~/.config/playwright/token
chmod 600 ~/.config/playwright/token

# Verify the next refresh succeeds:
systemctl --user start playwright-snapshot-refresh.service
journalctl --user -u playwright-snapshot-refresh.service -n 20
```

## Restore from a backup tarball

The 6-hourly backup CronJob writes `tar -czf /backup/YYYY_MM_DD_HH.tar.gz
-C /profile .` to NFS at `/srv/nfs/chrome-service-backup/`. To restore
the entire profile:

```bash
# 1. Scale chrome-service down so its lock is released.
kubectl -n chrome-service scale deploy/chrome-service --replicas=0

# 2. Mount the PVC in a helper pod and restore.
kubectl -n chrome-service apply -f - <<EOF
apiVersion: v1
kind: Pod
metadata: {name: restore-helper, namespace: chrome-service}
spec:
  containers:
  - name: helper
    image: alpine:3.20
    command: [sleep, infinity]
    volumeMounts:
    - {name: profile, mountPath: /profile}
    - {name: backup, mountPath: /backup, readOnly: true}
  volumes:
  - name: profile
    persistentVolumeClaim: {claimName: chrome-service-profile-encrypted}
  - name: backup
    persistentVolumeClaim: {claimName: chrome-service-backup-host}
  restartPolicy: Never
EOF

kubectl -n chrome-service wait --for=condition=ready pod/restore-helper

kubectl -n chrome-service exec restore-helper -- sh -c '
  rm -rf /profile/chromium-data /profile/snapshots &&
  tar -xzf /backup/2026_06_04_18.tar.gz -C /profile
'

# 3. Cleanup helper, scale chrome-service back up.
kubectl -n chrome-service delete pod restore-helper
kubectl -n chrome-service scale deploy/chrome-service --replicas=1
```
