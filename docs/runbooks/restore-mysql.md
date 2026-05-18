# Restore MySQL (Standalone)

Last updated: 2026-05-18 (after the 8.4.9 DD-upgrade disaster recovery)

Applies to the `mysql-standalone` StatefulSet in the `dbaas` namespace
(raw `kubernetes_stateful_set_v1`, migrated from InnoDB Cluster on
2026-04-16). The historic InnoDB-Cluster recovery flow is gone.

## Prerequisites
- `kubectl` against the cluster
- Root password: `kubectl -n dbaas get secret cluster-secret -o jsonpath='{.data.ROOT_PASSWORD}' | base64 -d`
- A backup dump on NFS at `/srv/nfs/mysql-backup/` (exported via
  `dbaas-mysql-backup-host` PVC inside the cluster)

## Backup Locations

| Location | Purpose | Retention |
|---|---|---|
| `/srv/nfs/mysql-backup/dump_YYYY_MM_DD_HH_MM.sql.gz` | Full daily dump (CronJob `mysql-backup`, daily 00:30 UTC) | 14 days |
| `/srv/nfs/mysql-backup/per-db/<dbname>/dump_*.sql.gz` | Per-DB dumps (CronJob `mysql-backup-per-db`, daily 00:45 UTC) | 14 days |
| Synology `Backup/Viki/nfs/mysql-backup/` | Offsite mirror via inotify-tracked rsync | unlimited |

Latest full dump is ~230MB compressed (~3GB uncompressed). Restore
of a full dump into a fresh MySQL pod takes ~3 minutes.

## Scenario A — Single database restored alongside the others

When one DB is corrupted but MySQL is otherwise fine.

```bash
ROOT_PWD=$(kubectl -n dbaas get secret cluster-secret -o jsonpath='{.data.ROOT_PASSWORD}' | base64 -d)

# List per-db dumps for the affected database
kubectl -n dbaas exec mysql-standalone-0 -- ls -lt /backup/per-db/<dbname>/

# Pipe a chosen dump into MySQL (REPLACE existing data in <dbname>):
kubectl -n dbaas exec -i mysql-standalone-0 -- \
    sh -c "zcat /backup/per-db/<dbname>/dump_YYYY_MM_DD_HH_MM.sql.gz | mysql -uroot -p\"$ROOT_PWD\" <dbname>"

# Restart consumers
kubectl -n <ns> rollout restart deployment
```

## Scenario B — Full disaster: data dictionary corrupt or PVC unsalvageable

This is the path executed on 2026-05-18 when a Keel-driven bump to
`mysql:8.4.9` left the data dictionary half-upgraded and 8.4.8 refused
to start (`Server upgrade of version 80408 is still pending` —
MY-013379). Wipes the PVC and rehydrates from the daily dump.

**Estimated downtime: 25 minutes.** Plan accordingly — Forgejo +
registry + every MySQL app go offline during this.

### B.1 Stop the failing MySQL pod

```bash
kubectl -n dbaas scale statefulset mysql-standalone --replicas=0
```

### B.2 Verify the dump you intend to restore is healthy

```bash
ssh root@192.168.1.127 'ls -la /srv/nfs/mysql-backup/dump_*.sql.gz | tail -5'
# Sanity-check the header
ssh root@192.168.1.127 'zcat /srv/nfs/mysql-backup/dump_YYYY_MM_DD_HH_MM.sql.gz | head -20'
# Should show "MySQL dump 10.13 ... Server version 8.4.X"
```

### B.3 Pin MySQL image in Terraform (if it auto-bumped)

If the upgrade was triggered by a Keel bump on a floating tag
(`mysql:8.4`), edit `stacks/dbaas/modules/dbaas/main.tf` to pin to a
known-good exact version (`mysql:8.4.8`). Commit but don't apply yet.

### B.4 Wipe the corrupted PVC

The PV reclaim policy defaults to **Retain** on
`proxmox-lvm-encrypted` — `kubectl delete pvc` alone leaves the PV
attached to the (corrupted) disk. Flip to `Delete` first so the CSI
driver actually cleans up the underlying LV.

```bash
PV=$(kubectl -n dbaas get pvc data-mysql-standalone-0 -o jsonpath='{.spec.volumeName}')
kubectl patch pv "$PV" -p '{"spec":{"persistentVolumeReclaimPolicy":"Delete"}}'
kubectl -n dbaas delete pvc data-mysql-standalone-0
```

The PV transitions to `Released` then gets cleaned up by the CSI
controller; confirm with `kubectl get pv | grep <PV>` (eventually
disappears).

### B.5 Scale MySQL back up via Terraform

```bash
cd stacks/dbaas && /home/wizard/code/infra/scripts/tg apply
```

This recreates the PVC fresh (5Gi initial; pvc-autoresizer grows it
on demand) and starts a brand-new MySQL pod. The pod initializes an
empty datadir using `MYSQL_ROOT_PASSWORD` from the `cluster-secret`
K8s Secret — ~30s to ready.

### B.6 Restore the full dump via a one-shot Job

```bash
cat <<'YAML' | kubectl apply -f -
apiVersion: batch/v1
kind: Job
metadata:
  name: mysql-restore-$(date +%Y-%m-%d)
  namespace: dbaas
spec:
  ttlSecondsAfterFinished: 3600
  template:
    spec:
      restartPolicy: Never
      containers:
      - name: restore
        image: mysql:8.4.8
        command: ["bash","-c"]
        args:
        - |
          set -euo pipefail
          gunzip -c /backup/dump_YYYY_MM_DD_HH_MM.sql.gz | \
            mysql -h mysql.dbaas.svc.cluster.local -uroot -p"$MYSQL_ROOT_PASSWORD"
          mysql -h mysql.dbaas.svc.cluster.local -uroot -p"$MYSQL_ROOT_PASSWORD" -e 'SHOW DATABASES;'
        env:
        - name: MYSQL_ROOT_PASSWORD
          valueFrom:
            secretKeyRef: { name: cluster-secret, key: ROOT_PASSWORD }
        volumeMounts:
        - { name: backup, mountPath: /backup, readOnly: true }
      volumes:
      - name: backup
        persistentVolumeClaim: { claimName: dbaas-mysql-backup-host, readOnly: true }
YAML
```

Watch progress: `kubectl -n dbaas logs -f job/<name>`. Takes ~3 min
for a 230MB compressed dump.

### B.7 Reset static MySQL users with passwords from Vault

**This step is mandatory.** `mysqldump` restores rows in `mysql.user`
verbatim, including password hashes. But `null_resource.mysql_static_user`
in Terraform writes the **current Vault password** to `forgejo` and
`roundcubemail` — and that current password rarely matches the dump's
hash. The apps will fail auth (forgejo logs `Error 1045 (28000): Access
denied for user 'forgejo'@'...'`) until you reset them.

```bash
FORGEJO_PW=$(vault kv get -field=mysql_forgejo_password secret/viktor)
RC_PW=$(vault kv get -field=mysql_roundcubemail_password secret/viktor)

kubectl -n dbaas exec -i mysql-standalone-0 -- bash -c 'mysql -uroot -p"$MYSQL_ROOT_PASSWORD"' <<SQL
DROP USER IF EXISTS 'forgejo'@'%';
DROP USER IF EXISTS 'roundcubemail'@'%';
CREATE USER 'forgejo'@'%' IDENTIFIED WITH caching_sha2_password BY '$FORGEJO_PW';
CREATE USER 'roundcubemail'@'%' IDENTIFIED WITH caching_sha2_password BY '$RC_PW';
GRANT ALL PRIVILEGES ON \`forgejo\`.* TO 'forgejo'@'%';
GRANT ALL PRIVILEGES ON \`roundcubemail\`.* TO 'roundcubemail'@'%';
FLUSH PRIVILEGES;
SQL
```

`ALTER USER` sometimes hits `ERROR 1396 Operation ALTER USER failed`
on freshly-restored DBs (stale grant-table cache); `DROP USER` +
`CREATE USER` is the reliable form.

Vault-rotated app users (nextcloud, codimd, grafana, paperless,
phpipam, etc.) are managed by Vault DB engine and their dump password
already matches the live K8s secret, so they need no manual fixup.

### B.8 Restart MySQL-dependent apps

The dump restore brings MySQL up, but app pods still hold stale
connections (and forgejo has been crash-looping). Roll the
deployments to force fresh connections:

```bash
for ns_app in \
    "forgejo:deploy/forgejo" \
    "nextcloud:deploy/nextcloud" \
    "hackmd:deploy/hackmd" \
    "monitoring:deploy/grafana" \
    "paperless-ngx:deploy/paperless-ngx" \
    "uptime-kuma:deploy/uptime-kuma" \
    "url:deploy/shlink" \
    "realestate-crawler:deploy/realestate-crawler-api" \
    "realestate-crawler:deploy/realestate-crawler-celery" \
    "realestate-crawler:deploy/realestate-crawler-celery-beat" \
    "realestate-crawler:deploy/realestate-crawler-ui"; do
  ns=${ns_app%%:*}; app=${ns_app##*:}
  kubectl -n "$ns" rollout restart "$app" &
done
wait
```

If any deployments stay stuck in `ImagePullBackOff` (e.g.
`chrome-service`, `fire-planner`, `freedify`), those rely on the
Forgejo registry — once forgejo is back, just delete their pods to
force a fresh pull:

```bash
kubectl -n chrome-service delete pod --all
kubectl -n fire-planner delete pod --all
kubectl -n freedify delete pod --all
```

### B.9 Verify recovery

```bash
# All workloads ready
kubectl get deploy,sts -A -o json | jq -r '.items[] | select(.spec.replicas != .status.readyReplicas and .spec.replicas > 0) | "\(.metadata.namespace)/\(.metadata.name)"'
# (empty output = healthy)

# Database integrity — table counts per schema
kubectl -n dbaas exec mysql-standalone-0 -- mysql -uroot -p"$ROOT_PWD" \
    -e "SELECT table_schema, COUNT(*) FROM information_schema.tables \
        WHERE table_schema NOT IN ('information_schema','performance_schema','sys') \
        GROUP BY table_schema;"

# Forgejo's registry catalog (catches the cascade alert)
kubectl -n monitoring create job --from=cronjob/forgejo-integrity-probe manual-postrestore-$(date +%s)
kubectl -n monitoring logs job/manual-postrestore-<timestamp> --tail=10
# Expect "Probe complete: 0 failures across N repos / M tags / K indexes"

# Cluster-health re-run
bash /home/wizard/code/infra/scripts/cluster_healthcheck.sh --quiet
```

### B.10 Clean up failed CronJob pods from the outage window

```bash
kubectl delete pods -A --field-selector=status.phase=Failed
```

## Why the 8.4.9 upgrade got us — and the version pin

The MySQL 8.4.9 data-dictionary upgrade from 80408 → 80409 stalls
reliably on this hardware. ~24s of writes to `mysql.ibd` and the redo
log, then no further progress, no CPU, no completion. We bumped the
liveness probe to 600s (`initial_delay_seconds`) and still no
progress. Hypothesised root cause: `innodb_io_capacity=100` combined
with `innodb_page_cleaners=1` — the upgrade's spatial-reference-system
flush phase is IO-starved. **Don't retry 8.4.9 without first bumping
IO capacity and pinning a proper maintenance window.**

Until then, the StatefulSet pins to `mysql:8.4.8` exactly, not the
floating `mysql:8.4` tag. Keel will not silently bump it.

## See also
- `docs/runbooks/forgejo-registry-breakglass.md` — companion runbook
  for when the cascade has reached the registry layer.
- Beads `code-eme8` / `code-k40p` — incident tracker entries (closed
  in commit ea475c3d).
