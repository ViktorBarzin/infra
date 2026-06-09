# Runbook: Vault Raft Leader Deadlock + Safe Pod Restart

Captures the 2026-04-22 incident pattern. When a Vault raft leader enters a
stuck goroutine state (port 8201 accepts TCP but RPCs never return), the
recovery is *not* `kubectl delete --force`. Force-deleting a Vault pod that
holds a stuck NFS mount leaves kernel NFS client state corrupted, which
blocks all subsequent NFS mounts from the node and usually requires a VM
hard-reset to clear.

**Related**: [post-mortems/2026-04-22-vault-raft-leader-deadlock.md](../post-mortems/2026-04-22-vault-raft-leader-deadlock.md).

## Symptoms

- `https://vault.viktorbarzin.me/v1/sys/health` returns HTTP 503.
- Standbys log `msgpack decode error [pos 0]: i/o timeout` every 2s.
- `kubectl exec` into a standby shows raft thinks the leader is alive
  (peers list all `Voter`, leader address populated) but `vault operator
  raft autopilot state` stalls or errors.
- The "leader" pod's logs go silent — no heartbeats, no audit writes,
  nothing. TCP on 8201 still accepts connections.
- ESO-backed secrets stop refreshing (ExternalSecret `SecretSyncedError`).
- Woodpecker CI pipelines that read from Vault at plan time hang.

## 0. Confirm the diagnosis (before touching anything)

Don't jump to force-delete. Verify the leader is actually stuck, not just
slow:

```sh
# 1. Who does raft think the leader is?
kubectl exec -n vault vault-0 -c vault -- vault status 2>&1 | \
  grep -E 'HA Mode|Active Node|Leader|Raft'

# 2. Is the leader's port open but unresponsive?
LEADER_POD=vault-2   # or whichever vault status reports
kubectl exec -n vault $LEADER_POD -c vault -- sh -c \
  'timeout 3 nc -zv 127.0.0.1 8200 2>&1; echo; timeout 3 vault status'

# 3. Is the active vault service pointing at a real pod?
kubectl get endpoints -n vault vault-active -o yaml | \
  grep -E 'addresses|notReadyAddresses' -A2

# 4. What do standby logs say?
kubectl logs -n vault vault-0 -c vault --tail=40 | grep -iE 'msgpack|decode|rpc'
```

If (2) hangs and (4) shows repeated msgpack errors → stuck leader.

## 1. Identify the stuck pod precisely

```sh
# Find the pod whose vault_core_active would be 1 if it were scraping
# (currently no telemetry — use logs as proxy until telemetry is enabled).
for p in vault-0 vault-1 vault-2; do
  echo "=== $p ==="
  kubectl logs -n vault $p -c vault --tail=5 2>&1 | head -5
done | grep -B1 'no recent output'
```

The pod whose logs have been silent for minutes while the others are
actively erroring is the stuck leader.

## 2. The safe restart sequence (avoids zombie containers)

**DO NOT** `kubectl delete pod --force --grace-period=0` as the first
step. On NFS-backed Vault that's the exact move that leaves the kernel
NFS client corrupted on the node where the stuck pod ran.

Instead:

### 2a. Graceful delete first (30s grace)

```sh
kubectl delete pod -n vault vault-2
```

Wait 30 seconds. Most of the time the TERM → SIGKILL path works and the
new pod schedules cleanly. The remaining leaders re-elect and the external
endpoint recovers.

### 2b. If the pod is Terminating after 60s, find the stuck process

```sh
NODE=$(kubectl get pod -n vault vault-2-<suffix> -o jsonpath='{.spec.nodeName}')
POD_UID=$(kubectl get pod -n vault vault-2-<suffix> -o jsonpath='{.metadata.uid}')

ssh $NODE "sudo ps auxf | grep -A2 $POD_UID | head -20"
# Look for: mount.nfs (D-state), vault (Z-state), or the sh wrapper in do_wait
```

### 2c. Unmount stale NFS before force-deleting

If the old pod's NFS mount is still present, lazy-unmount it FIRST so
the kernel can release NFS session state cleanly:

```sh
ssh $NODE "sudo mount | grep $POD_UID | awk '{print \$3}' | xargs -I{} sudo umount -l {}"
```

Verify no mount.nfs processes are in D-state on the node:

```sh
ssh $NODE "ps -eo state,pid,comm | grep '^D' | head -5"
```

### 2d. Only NOW force-delete if needed

```sh
kubectl delete pod -n vault vault-2-<suffix> --force --grace-period=0
```

## 3. Recovery when the node is already stuck

If you force-deleted before reading this runbook and NFS is now broken
on the node:

**Diagnostic — confirm NFS client state is corrupted:**

```sh
NODE=k8s-node2   # node where the force-delete happened
ssh $NODE "sudo mkdir -p /tmp/nfstest && sudo timeout 30 \
  mount -t nfs 192.168.1.127:/srv/nfs /tmp/nfstest && echo MOUNT_OK"
```

If the mount times out at 30-110s, kernel NFS client state is stuck.
No userspace recovery exists — only a VM reboot clears it.

**Workaround before rebooting**: mounting with `nfsvers=4.1` succeeds
on broken nodes (the corruption is NFSv4.2 session-state specific).
This is useful for diagnostic mounts, but does NOT fix CSI pods —
their mount options come from the `nfs-proxmox` StorageClass and can't
be overridden per-pod.

**Reboot the affected node VM:**

```sh
# Find PVE VM ID — nodes numbered 201-204 for k8s-node1..4
ssh root@192.168.1.127 "qm reset 20<N>"

# If qm reset leaves the VM PID unchanged (it didn't actually reboot),
# use qm stop/start:
ssh root@192.168.1.127 "qm stop 20<N> && qm start 20<N>"
```

Wait for the node to become Ready (`kubectl get node k8s-node<N> -w`)
and CSI driver to register (`kubectl get pods -n nfs-csi -o wide`).

**Gotcha — `qm reset` can be a no-op.** On the 2026-04-22 incident,
`qm reset 201` returned exit 0 but did NOT restart the VM (same QEMU PID
before and after). `qm status` reported "running" throughout. Always
verify by checking the QEMU PID or VM uptime post-reset. If uptime is
unchanged, escalate to `qm stop && qm start`.

**Gotcha — check boot order before stop/start.** Long-running VMs
(630+ day uptime) may have stale `bootdisk:` config that's been hidden
by never rebooting. On 2026-04-22, k8s-node1's config had `bootdisk:
scsi0` but the actual OS disk was on `scsi1`, so the first boot after
stop attempted iPXE and failed. Before stopping, verify:

```sh
ssh root@192.168.1.127 "grep -E 'boot|scsi[0-9]+:' /etc/pve/qemu-server/20<N>.conf"
```

If `bootdisk` references a disk ID that doesn't exist, fix it first
with `qm set 20<N> --boot "order=scsi<ID>"` (use the ID of the main
OS disk).

## 4. Prevent re-infection — the chown loop

After the node comes back, the vault pod's PV chown walk can still
peg kubelet. The durable fix is in `stacks/vault/main.tf`:

```hcl
statefulSet = {
  securityContext = {
    pod = {
      fsGroupChangePolicy = "OnRootMismatch"
    }
  }
}
```

This was applied in commit `2f1f9107` (2026-04-22). If you find
yourself editing this in a kubectl patch for live recovery, follow
up with a Terraform apply the same session — leaving the cluster
ahead of Terraform state is technical debt that re-triggers on the
next apply.

## 5. Verify end-to-end

```sh
# External endpoint — the user-facing health check
curl -sk -o /dev/null -w "%{http_code}\n" https://vault.viktorbarzin.me/v1/sys/health
# expect: 200

# Raft peers (needs VAULT_TOKEN with operator capability)
kubectl exec -n vault vault-0 -c vault -- vault operator raft list-peers

# All pods 2/2
kubectl get pods -n vault -l app.kubernetes.io/name=vault -o wide

# No alerts fired (once VaultRaftLeaderStuck + VaultHAStatusUnavailable are live)
curl -s https://alertmanager.viktorbarzin.me/api/v2/alerts | \
  jq '.[] | select(.labels.alertname | test("Vault"))'
```

## Known limitations

- **No alert for stuck leaders yet.** `VaultRaftLeaderStuck` and
  `VaultHAStatusUnavailable` require Vault telemetry enabled
  (`telemetry { unauthenticated_metrics_access = true }`) and a
  scrape job. Alerts are defined in `prometheus_chart_values.tpl`
  but stay silent until telemetry lands — tracked as a beads task.
- **Vault on NFS violates the documented rule.** `infra/.claude/CLAUDE.md`
  says critical services must use `proxmox-lvm-encrypted`. The
  `dataStorage`/`auditStorage` still use `nfs-proxmox`. Migration
  tracked as an epic-level beads task.
