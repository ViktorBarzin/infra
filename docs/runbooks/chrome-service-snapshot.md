# Runbook — chrome-service snapshot pipeline

Operational playbook for the hourly cookie-snapshot pipeline that warms
external Claude Code sessions on the dev box. Architecture in
`architecture/chrome-service.md`.

## At a glance

| Component | Where | When | What |
|---|---|---|---|
| chrome-service Deployment | `chrome-service` ns | always-on | headed chromium, CDP :9222, persistent /profile/chromium-data |
| snapshot-server sidecar | same pod | always-on | the hub API, port 8088: `GET /api/snapshot` (read token) and `POST /api/cookies` (write token, LAN-only host `chrome-hub.viktorbarzin.me`) |
| snapshot-harvester CronJob | `chrome-service` ns | `23 * * * *` | reads the master's cookies over raw CDP → `/profile/snapshots/storage-state.json`, records sign-outs as tombstones |
| emo's hub | `chrome-emo` ns | always-on | headless Chrome + the same sidecar, which refreshes its own snapshot hourly (`REFRESH_SECONDS`); API at `chrome-hub-emo.viktorbarzin.me` |
| dev-box refresh timer | each dev box, per OS user with a hub | hourly (`*:28`) | `playwright-snapshot-refresh@<user>.timer` GETs the `snapshot_url` in `~/.config/chrome-hub/hub.json` → `~/.cache/playwright-shared-storage-state.json`, under `flock` on `.lock` beside it |
| dev-box T3 browser sync | each dev box, per OS user with a hub | every 10 min | `t3-browser-cookies@<user>.timer`: pushes T3's new logins to the hub and loads hub logins into T3's browser while it has no tab open |
| dev-box `playwright-mcp@<user>.service` | each dev box, per OS user | always-on | pinned `@playwright/mcp@<ver> --isolated --storage-state=…` on the user's `PLAYWRIGHT_PORT`; per-MCP-connection (per-session) contexts |
| dev-box `tl-browser` (terminal-lobby) | each dev box, per Claude session | while the agent browses | since 2026-10-01: stdio launcher started by Claude itself; one headless Chrome per session in the user's `tl-browser.slice`, context seeded from the same `~/.cache/playwright-shared-storage-state.json`. Replaces `playwright-mcp@<user>` once `t3-provision-users.sh` switches the user (see `docs/architecture/multi-tenancy.md`) |

## Provisioning (reproducible from git)

The dev-box side is **per-OS-user** and fully reproducible — no hand-setup.
Each user gets their own isolated `@playwright/mcp` server (multiple concurrent
Claude sessions per user, isolated by `--isolated`), wired into their Claude in
**every directory** via a user-scope `~/.claude.json` entry
(`playwright → http://localhost:<PLAYWRIGHT_PORT>/mcp`).

- **System-level template units** (NOT `systemd --user`, so no linger needed):
  `playwright-mcp@.service` + `playwright-snapshot-refresh@.{service,timer}`,
  sourced from `infra/scripts/workstation/playwright/`, installed to
  `/etc/systemd/system/` by `setup-devvm.sh` (§9e). `User=%i`; per-user
  `PLAYWRIGHT_PORT` from `/etc/t3-serve/playwright-<user>.env`.
- **Port allocation**: `roster_engine.py` (`PLAYWRIGHT_BASE_PORT=8931`, sticky)
  — emitted in the derive JSON, written per-user by `t3-provision-users.sh` (§5c).
- **Hub config** (one hub per person, since 2026-11-08): `setup-devvm.sh` (§8c)
  runs `scripts/workstation/stage-chrome-hubs.sh`, which reads each person's
  Vault path from `scripts/workstation/chrome-hubs.json` and writes
  `/etc/t3-serve/chrome-hub-<user>.json` (root, 0600). The provisioner's
  `install_chrome_hub` copies it to `~/.config/chrome-hub/hub.json` whenever they
  differ and enables `t3-browser-cookies@<user>.timer` (the hourly root
  reconcile has no Vault token, hence the staging — mirrors the Claude OAuth
  token in §8a). The old single `/etc/t3-serve/chrome-service-token`, which every
  user received, is gone.
- **MCP wiring + enablement**: `t3-provision-users.sh` `install_playwright()` runs
  `claude mcp add --scope user … playwright` AS the user (clobber-proof, if-absent)
  and `systemctl enable --now` the system instances. Idempotent; never restarts a
  running instance or rewrites an existing `~/.claude.json` entry.
- **Legacy-unit retirement**: `install_playwright()` also calls
  `retire_legacy_playwright_units()` — stop + disable + rename any surviving
  `~/.config/systemd/user/playwright-*` unit to `<unit>.superseded-by-system-unit`
  before enabling the template instance. Enabling the new unit is not enough on a
  box that predates it: the old one hardcodes its own `--port`, so the new one
  cannot bind. See "A user's browser MCP is dead" below.
- **Pinned version**: bump `@playwright/mcp@<ver>` in
  `scripts/workstation/playwright/playwright-mcp@.service` (the `@latest` →
  silent-fleet-roll footgun is why; see the `T3_PIN` rationale in `setup-devvm.sh`).

## Day-to-day

### Log into a new site (warm the profile)

Since 2026-11-08 any of a person's browsers works: a login made in a lobby session
browser or in T3's browser is pushed to their hub (within 5 minutes, or 10 for
T3) and reaches every other browser from there. The hub's live view is the
direct route, and the only one for Viktor's in-cluster callers:

1. Open `https://chrome.viktorbarzin.me/` (Authentik will gate).
2. The neko view of the in-cluster headed Chrome loads. Click on the
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
# On the dev box, refresh a specific user's snapshot (system template instance):
sudo systemctl start playwright-snapshot-refresh@<user>.service

# Or run the script directly AS that user:
sudo -u <user> /usr/local/bin/playwright-snapshot-refresh

# Verify
sudo ls -la /home/<user>/.cache/playwright-shared-storage-state.json
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

### "could not read cookies from …"

The harvester, or the broker's `GET /seed`, cannot read the master's CDP
endpoint.

**Cause**: chrome-service pod not Ready, NetworkPolicy doesn't admit
the caller's namespace, or chromium isn't listening on :9222.

The master pod being Ready does not rule the master out: its readiness probe is
a TCP check on the cdp-bridge's own port, which says nothing about the browser
behind it.

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

**If `/json/version` answers and the read still fails**, the broker's stderr
carries the exception (`homelab logs query '{namespace="chrome-service",
container="broker"} |= "seed export"'`) and its 502 body repeats it. This used
to say only "seed export failed" with no reason, which is why the 2026-09-18
episode took a day to name.

### Dev-box `playwright-snapshot-refresh` returns 401

The `read_token` in `~/.config/chrome-hub/hub.json` doesn't match the hub's.
Almost always means the Vault secret was rotated and the staged copy is stale.

**Fix** (re-stage centrally; the provisioner copies changed files on its next
run, or run it now):
```bash
vault login -method=oidc  # if needed
sudo VAULT_TOKEN="$(cat ~/.vault-token)" bash ~/code/infra/scripts/workstation/stage-chrome-hubs.sh
sudo systemctl start t3-provision-users.service
sudo systemctl start playwright-snapshot-refresh@<user>.service
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

**Fix**: restart the user's MCP server on the dev box to pick up the new file:
```bash
sudo systemctl restart playwright-mcp@<user>.service
```

### Snapshot file is suspiciously small or empty cookies array

The persistent chromium context isn't holding any cookies. Probably
means the user hasn't logged into anything via the neko view, or Chrome was
relaunched without preserving `/profile/chromium-data`.

**Diagnose**:
```bash
kubectl -n chrome-service exec deploy/chrome-service -c chrome-service -- \
  ls -la /profile/chromium-data/Default/Cookies
```

A populated `Cookies` SQLite file should be several hundred KB once
real logins exist. If it's missing or empty, log in via the neko view.

### "Target page, context or browser has been closed"

A user's Claude playwright tools all fail this way, while `claude mcp get
playwright` still shows the entry.

**Cause**: the per-user `playwright-mcp@<user>` instance is crash-looping on
`EADDRINUSE` because something else holds its `PLAYWRIGHT_PORT` — usually a
surviving pre-template `~/.config/systemd/user/playwright-mcp.service`, which
hardcodes its own port. Enabling the system instance does not displace it. This
hid for ~16 days across all three users (2026-07-29 → 2026-08-14) with six-figure
restart counts, and the ports were cross-wired between users, so it reads as one
user squatting on another's port rather than each being blocked by its own
leftover.

**Diagnose**:

```bash
systemctl is-active playwright-mcp@<user>            # activating/auto-restart = looping
systemctl show playwright-mcp@<user> -p NRestarts    # six figures = looping for weeks
journalctl -u playwright-mcp@<user> -n 20            # EADDRINUSE names the port

# Who holds it? The listener's comm is `MainThread` (node), which does not look
# like playwright — resolve the pid, not the name.
sudo ss -ltnp | grep 893
cat /proc/<pid>/cgroup
#   user@<uid>.service/app.slice/...  -> a LEGACY systemd --user unit (usual cause)
#   system.slice/...                  -> the current template instance
```

**Fix** (idempotent, safe to re-run):

```bash
sudo /usr/local/bin/t3-provision-users.sh     # retire_legacy_playwright_units + re-enable
sudo systemctl restart playwright-mcp@<user>
```

Confirm each user holds their OWN assigned port afterwards — a legacy unit may
have been bound to someone else's, so check the mapping, not just that something
is listening:

```bash
grep . /etc/t3-serve/playwright-*.env    # the assignment
sudo ss -ltnp | grep 893                 # what is live
```

## Token rotation

Each hub has a read token (`api_bearer_token`: snapshot and broker) and a write
token (`api_write_token`: `POST /api/cookies`) in its own Vault path
(`secret/chrome-service` for Viktor, `secret/chrome-emo` for emo).

```bash
# Rotate one token (patch keeps the other keys).
vault kv patch secret/chrome-service \
  api_bearer_token=$(python3 -c 'import secrets; print(secrets.token_urlsafe(32))')

# ESO refreshes hourly; force it so the sidecar and broker move now. Reloader
# then restarts the hub pod and the broker.
kubectl -n chrome-service annotate externalsecret chrome-service-secrets force-sync=$(date +%s) --overwrite

# On the dev box: re-stage, then let the provisioner copy the changed files.
sudo VAULT_TOKEN="$(cat ~/.vault-token)" bash ~/code/infra/scripts/workstation/stage-chrome-hubs.sh
sudo systemctl start t3-provision-users.service

# Verify the next refresh succeeds for a user:
sudo systemctl start playwright-snapshot-refresh@<user>.service
sudo journalctl -u playwright-snapshot-refresh@<user>.service -n 20
```

tv extracts the whole `secret/chrome-service` path and picks a rotated read token
up on its own ESO refresh.

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
