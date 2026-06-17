# K8s Version Upgrade Pipeline

## Overview

Kubernetes component versions (`kubeadm`/`kubelet`/`kubectl`) on the 5 K8s
VMs are upgraded automatically by a weekly detection CronJob that seeds a
chain of small phase Jobs. Each Job is **pinned to a node that is NOT its
drain target** — so no pod in the chain can preempt itself.

The chain (Sun 12:00 UTC weekly):

```
detection CronJob → preflight Job → master Job → worker × 4 Jobs → postflight Job
```

This is **independent** of the OS-side `unattended-upgrades + kured`
pipeline (see `k8s-node-auto-upgrades.md`). They do not share rollouts.
Schedules can overlap (kured runs daily 02:00-06:00 London; detection
here runs Sun 12:00 UTC) — when a kured reboot lands within 24h of the
Sunday detection, the `RecentNodeReboot` alert in the Upgrade Gates
group blocks the version-upgrade preflight, so the chain self-defers
to the next Sunday rather than rolling on top of a half-fresh node.

## Architecture

```
k8s-version-check CronJob   (Sun 12:00 UTC, k8s-upgrade ns, SA: k8s-upgrade-job)
  │ kubectl get nodes  → running version
  │ ssh master 'apt-cache madison kubeadm'  → latest patch (within current minor)
  │ HEAD pkgs.k8s.io/.../v<NEXT_MINOR>/deb/Release  → next minor available?
  │ push k8s_upgrade_available{kind,running,target} → Pushgateway
  │
  ▼ if a target is detected
envsubst on /template/job-template.yaml  | kubectl apply -f -
  │ creates k8s-upgrade-preflight-<target_version>
  ▼

Job 0 — preflight       (pinned: k8s-node1)
  ├── All nodes Ready + no Mem/Disk pressure
  ├── halt-on-alert (kured-style ignore-list)
  ├── 24h-quiet baseline (no Ready transitions <24h ago)
  ├── kubeadm upgrade plan matches target
  ├── Push k8s_upgrade_in_flight=1, k8s_upgrade_started_timestamp=$(date +%s)
  ├── Trigger backup-etcd Job, wait, verify snapshot byte count
  ├── SSH master: containerd skew fix (if master < workers)
  ├── SSH all 5 nodes: apt repo URL rewrite (only kind=minor)
  └── spawn_next → k8s-upgrade-master-<target_version>
  ▼

Job 1 — master upgrade  (pinned: k8s-node1)
  ├── halt-on-alert recheck (no firing alerts)
  ├── drain k8s-master (predrain_unstick deletes PDB-blocked pods)
  ├── ssh wizard@k8s-master 'bash -s' < /scripts/update_k8s.sh -- --role master --release X.Y.Z
  ├── kubectl uncordon k8s-master; wait Ready + version match
  ├── verify control-plane pods Running
  ├── halt-on-alert recheck (allows RecentNodeReboot)
  └── spawn_next → k8s-upgrade-worker-<v>-k8s-node4
  ▼

Job 2 — worker k8s-node4 (pinned: k8s-node1)
Job 3 — worker k8s-node3 (pinned: k8s-node1)
Job 4 — worker k8s-node2 (pinned: k8s-node1)
  (identical pattern: halt-on-alert wait 30m → drain → ssh script → uncordon → 10-min soak → spawn_next)
  ▼

Job 5 — worker k8s-node1 (pinned: k8s-master + control-plane toleration)
  └── spawn_next → k8s-upgrade-postflight-<target_version>
  ▼

Job 6 — postflight       (no pinning)
  ├── Verify all 5 nodes at target version
  ├── Verify no firing Upgrade Gates alerts
  ├── Compute pod-ready ratio (should be ≥ 0.9)
  ├── Clear k8s-upgrade-* annotations on namespace
  ├── Push k8s_upgrade_in_flight=0, k8s_upgrade_snapshot_taken=0, k8s_upgrade_started_timestamp=0
  └── Slack: ✅ K8s upgrade complete
```

**Pin choices summarised:**
- k8s-node1 hosts every Job that drains master or another worker. k8s-node1
  itself is upgraded **last**.
- k8s-master hosts Job 5 (which drains k8s-node1). Job 5's spec includes a
  toleration for `node-role.kubernetes.io/control-plane:NoSchedule`.
- If anyone reorders the worker sequence, the pin for Job 5 needs to track
  whatever worker is upgraded last. The mapping is in `scripts/upgrade-step.sh`
  → the `case "${PHASE}:${TARGET_NODE:-}"` block.

## Components

### Shared resources (one-time, Terraform-managed)

| Resource | Purpose |
|---|---|
| **ConfigMap `k8s-upgrade-scripts`** | Mounts `/scripts/upgrade-step.sh` (universal phase body, dispatches on `$PHASE`) and `/scripts/update_k8s.sh` (per-node kubeadm/kubelet/kubectl upgrade body — same script the old manual loop used) in every Job pod. |
| **ConfigMap `k8s-upgrade-job-template`** | Mounts `/template/job-template.yaml` — universal Job manifest with envsubst placeholders. Rendered by upgrade-step.sh and the detection CronJob via `envsubst | kubectl apply`. |
| **ServiceAccount `k8s-upgrade-job`** | Used by both the detection CronJob and every chain Job. ClusterRole binding grants: nodes get/list/patch, pods/eviction create, pods delete, batch/jobs CRUD, PDB list (for predrain_unstick), CronJob get (snapshot trigger), namespaces patch on `k8s-upgrade` only. Namespace-scoped Role binding grants secrets:get on `k8s-upgrade-creds`. |
| **ExternalSecret `k8s-upgrade-creds`** | Syncs `secret/k8s-upgrade/{ssh_key, slack_webhook}` from Vault. Mounted into every Job at `/secrets/k8s-upgrade`. |
| **CronJob `k8s-version-check`** | Sun 12:00 UTC. Probes apt + pkgs.k8s.io for target. If found, renders Job 0 from `job-template.yaml` and applies it. |

### Pushgateway metrics

Pushed by upgrade-step.sh during phase execution; observed by the
`Upgrade Gates` alert group in `stacks/monitoring/.../prometheus_chart_values.tpl`:

| Metric | Pushed by | Cleared by |
|---|---|---|
| `k8s_upgrade_in_flight` (1/0) | preflight Job (set to 1) | postflight Job (set to 0) |
| `k8s_upgrade_started_timestamp` (epoch s) | preflight Job | postflight Job (set to 0) |
| `k8s_upgrade_snapshot_taken` (1/0) | preflight Job (set to 1 after Job=`pre-upgrade-etcd-*` completes with `Backup done:` log of ≥1 KiB) | postflight Job (0) |
| `k8s_upgrade_available{kind,running,target}` | detection CronJob | next detection run (overwrite) |
| `k8s_version_check_last_run_timestamp` | detection CronJob | (cumulative) |

### Upgrade Gates alerts (`Upgrade Gates` group in prometheus_chart_values.tpl)

- **`K8sVersionSkew`** — distinct kubelet/apiserver `gitVersion` count > 1 for 30m. Catches a half-done rollout.
- **`EtcdPreUpgradeSnapshotMissing`** — `k8s_upgrade_in_flight==1 && k8s_upgrade_snapshot_taken==0` for 10m. Catches preflight Stage 2 failing silently.
- **`K8sUpgradeStalled`** — `k8s_upgrade_in_flight==1 && time()-k8s_upgrade_started_timestamp > 5400` for 5m. Catches a Job in the chain dying without spawning its successor.
- **`K8sUpgradeChainJobFailed`** — `kube_job_status_failed{namespace="k8s-upgrade",job_name=~"k8s-upgrade-.*",reason=~"BackoffLimitExceeded|DeadlineExceeded"} > 0` for 15m (warning). Catches a phase Job that **terminally failed before `k8s_upgrade_in_flight` was set** — the preflight gates exit pre-metric, so the two `in_flight`-based alerts above are blind to a failed preflight (this is what hid the 5-day 1.34.9 wedge on 2026-06-12). Reason-scoped to terminal job conditions so a retry-success doesn't false-positive (a bare failed-pod-count would otherwise also block kured for the Job's 7d TTL).
- All four alerts ALSO block kured (same `--prometheus-url` halt-on-alert mechanism) so the OS-reboot pipeline can't run on top of a half-done version upgrade.

### CoreDNS is NOT upgraded by kubeadm here

CoreDNS runs a **custom split-horizon Corefile** (owned by the technitium stack)
and its image is tracked separately — it must NOT be touched by kubeadm. The
master `kubeadm upgrade apply` therefore runs with
`--ignore-preflight-errors=CoreDNSMigration,CoreDNSUnsupportedPlugins
--skip-phases=addon/coredns` (in `scripts/update_k8s.sh`), so kubeadm upgrades
the control plane but leaves CoreDNS 100% untouched (image + Corefile). Without
the `--skip-phases`, forcing past the preflight makes kubeadm overwrite the
Corefile with its default and downgrade the image (verified via
`kubeadm upgrade apply --dry-run`).

**Keep CoreDNS off Keel.** On 2026-06-12 Keel had auto-bumped CoreDNS
v1.12.1 → v1.12.4 (kube-system out-of-band annotation from the 2026-05-26 Keel
cascade), and 1.12.4 is ahead of kubeadm 1.34.9's corefile-migration table —
which is what blocked the 1.34.9 upgrade. CoreDNS is now `keel.sh/policy=never`
(`kubectl -n kube-system annotate deploy/coredns keel.sh/policy=never`). If a
future kubeadm minor ships a CoreDNS that DOES know the running version, drop the
`--skip-phases` for that run to let kubeadm re-take ownership.

### Vault secrets

- `secret/k8s-upgrade/ssh_key` — ed25519 PRIVATE key, used by Jobs to SSH `wizard@<node>`
- `secret/k8s-upgrade/ssh_key_pub` — matching PUBLIC key, deployed to nodes' `~/.ssh/authorized_keys`
- `secret/k8s-upgrade/slack_webhook` — Slack incoming-webhook URL

Exposed in K8s via ExternalSecret `k8s-upgrade-creds` in the `k8s-upgrade` namespace. The previous `api_bearer_token` entry is GONE — the chain does not POST to `claude-agent-service`.

## Common Operations

### Post-upgrade: restore apiserver OIDC (REQUIRED after any control-plane bump)

`kubeadm upgrade apply` **regenerates `/etc/kubernetes/manifests/kube-apiserver.yaml`
and drops the `--authentication-config` flag**, silently disabling apiserver
OIDC (kubectl/kubelogin CLI **and** the web dashboard SSO break — tokens get
401). This is not auto-detected (the `rbac` stack's `null_resource` trigger is a
content hash that doesn't change). After any control-plane upgrade, re-apply:

```bash
cd stacks/rbac
TF_VAR_ssh_private_key="$(cat ~/.ssh/id_ed25519)" \
  VAULT_ADDR=https://vault.viktorbarzin.me ../../scripts/tg apply \
  --non-interactive -target=module.rbac.null_resource.apiserver_oidc_config
```

(`ssh_private_key` must be a key authorized for `wizard@<master>`; it is not yet
wired from Vault.) The provisioner re-writes `/etc/kubernetes/pki/auth-config.yaml`
(both `kubernetes` + `k8s-dashboard` issuers), re-adds the flag, and
health-gates `/livez` with auto-rollback. Verify: `curl -sk
https://localhost:6443/livez` on the master = `ok`, and the apiserver manifest
contains `--authentication-config`. See `docs/plans/2026-06-04-k8s-dashboard-sso-design.md`.

### Verify the pipeline is healthy
```bash
# CronJob present + not suspended
kubectl -n k8s-upgrade get cronjob k8s-version-check

# Latest detection run output
kubectl -n k8s-upgrade get jobs -l app=k8s-version-upgrade
kubectl -n k8s-upgrade logs -l app=k8s-version-upgrade --tail=200

# Chain Jobs from the last run (retained 7 days via ttlSecondsAfterFinished)
kubectl -n k8s-upgrade get jobs -l app=k8s-upgrade-chain

# Pushgateway — running detection metric
kubectl -n monitoring exec deploy/prometheus-server -c prometheus-server -- \
  wget -q -O- 'http://prometheus-prometheus-pushgateway.monitoring:9091/metrics' | \
  grep -E '^(k8s_upgrade_(available|in_flight|started_timestamp|snapshot_taken)|k8s_version_check_last_run_timestamp)'

# Upgrade Gates rules loaded
kubectl -n monitoring exec deploy/prometheus-server -c prometheus-server -- \
  wget -q -O- 'http://localhost:9090/api/v1/rules' | \
  jq -r '.data.groups[] | select(.name == "Upgrade Gates") | .rules[] | "  \(.name): \(.state)"'
```

### Manually trigger detection (no upgrade)
Use `detection_dry_run=true` to short-circuit before spawning Job 0:

```bash
# Toggle var in TF, apply, and trigger
# (in stacks/k8s-version-upgrade/main.tf)
#   variable "detection_dry_run" { default = true }
# scripts/tg apply
kubectl -n k8s-upgrade create job --from=cronjob/k8s-version-check version-check-test
kubectl -n k8s-upgrade logs -l job-name=version-check-test -f
# When done, flip back to false.
```

### Manually trigger the chain (skip detection)
Useful for testing or to force a specific target. Render Job 0 directly:

```bash
TARGET=1.34.7
KIND=patch
IMAGE=$(kubectl -n k8s-upgrade get cronjob k8s-version-check \
  -o jsonpath='{.spec.jobTemplate.spec.template.spec.containers[0].image}')

cat <<EOF | envsubst | kubectl apply -f -
$(kubectl -n k8s-upgrade get cm k8s-upgrade-job-template -o jsonpath='{.data.job-template\.yaml}')
EOF
# Note: export JOB_NAME, PHASE_NEXT, etc. first — see the CronJob's command for
# the full env block. Easier: just trigger detection with the right inputs.
```

### Kill a stuck Job (chain halted mid-flight)
A phase Job that dies without spawning its successor halts the chain. Two alerts
surface it: `K8sUpgradeStalled` (a mid-chain Job that died with `in_flight=1`,
after 90 min) and `K8sUpgradeChainJobFailed` (any phase that terminally failed,
after 15 min — including a **preflight** that aborted before `in_flight` was set,
which `K8sUpgradeStalled` cannot see).

**Preflight failures now self-heal** (since 2026-06-17): the detection CronJob and
`spawn_next` delete + re-spawn a terminally-Failed Job instead of skipping it on
name-existence (retry-on-failure), so a transient preflight gate — e.g. a spurious
critical alert like the ttyd web-terminal probe that wedged 1.34.9 for 5 days —
clears on the next daily cycle. A mid-chain phase that keeps failing still needs
manual recovery: fix the root cause, then:

```bash
# 1. Identify the failed Job
kubectl -n k8s-upgrade get jobs -l app=k8s-upgrade-chain
kubectl -n k8s-upgrade describe job/<failed-job-name> | tail -50
kubectl -n k8s-upgrade logs job/<failed-job-name>

# 2. Diagnose. Common causes:
#    - drain stuck on PDB-violating pod (predrain_unstick should handle this;
#      but a brand-new PDB pattern could escape it — manually delete the pod)
#    - SSH from Job pod failing (node restarted? known_hosts mismatch?)
#    - kubeadm upgrade failed on a node (check journalctl + apt history on that node)

# 3. Fix the root cause first.

# 4. Delete the failed Job + re-spawn it. Naming is deterministic so
#    `kubectl apply` of the same name reconciles to a single Job.
kubectl -n k8s-upgrade delete job/<failed-job-name>

# 5. Manually render + apply the same Job. Pull the template + spec from the
#    next-Job-creation block in upgrade-step.sh — easiest is to copy from a
#    sibling Job's YAML:
kubectl -n k8s-upgrade get job/<sibling-job-name> -o yaml \
  | yq 'del(.metadata.resourceVersion, .metadata.uid, .metadata.creationTimestamp, .metadata.managedFields, .status)' \
  | yq '.metadata.name = "<failed-job-name>"' \
  | yq '.spec.template.spec.containers[0].env[] | select(.name=="PHASE") .value = "<right-phase>"' \
  | kubectl apply -f -

# The chain will continue from there. The next-Job-creation step in upgrade-step.sh
# is idempotent (deterministic name) so re-running won't duplicate downstream.
```

### Skip a phase (advanced; use sparingly)
If you've already done the work for a phase manually and want the chain to
jump past it, manually create the NEXT phase's Job with the deterministic
name. The previous phase's spawn-next will see the Job already exists and
short-circuit. Example: master already on target; jump straight to worker:

```bash
TARGET=1.34.7
TGT_LBL=${TARGET//./-}
# (compose Job from upgrade-step.sh spawn_next code, name=k8s-upgrade-worker-$TGT_LBL-k8s-node4, run on k8s-node1)
```

### Halt the pipeline in an emergency

```bash
# Option 1: suspend the detection CronJob (won't stop an in-flight chain)
kubectl -n k8s-upgrade patch cronjob k8s-version-check \
  -p '{"spec":{"suspend":true}}' --type=merge
# Re-enable: -p '{"spec":{"suspend":false}}'

# Option 2: delete all in-flight chain Jobs
kubectl -n k8s-upgrade delete jobs -l app=k8s-upgrade-chain
# This leaves the in-flight annotation + Pushgateway gauge intact —
# K8sUpgradeStalled will fire to surface the halt.

# Option 3: force a blocker alert (same regex kured uses)
# — see k8s-node-auto-upgrades.md "Force halt by adding a custom blocker alert"
```

### Clear orphaned in-flight state
After deciding NOT to retry a halted chain:

```bash
kubectl annotate ns k8s-upgrade \
  viktorbarzin.me/k8s-upgrade-in-flight- \
  viktorbarzin.me/k8s-upgrade-target- \
  viktorbarzin.me/k8s-upgrade-snapshot-path-

# Reset Pushgateway gauges so K8sUpgradeStalled / EtcdPreUpgradeSnapshotMissing clear:
kubectl -n monitoring port-forward svc/prometheus-prometheus-pushgateway 9091:9091 &
printf '# TYPE k8s_upgrade_in_flight gauge\nk8s_upgrade_in_flight 0\n# TYPE k8s_upgrade_snapshot_taken gauge\nk8s_upgrade_snapshot_taken 0\n# TYPE k8s_upgrade_started_timestamp gauge\nk8s_upgrade_started_timestamp 0\n' \
  | curl --data-binary @- http://localhost:9091/metrics/job/k8s-version-upgrade
kill %1
```

### Rollback paths
`kubeadm` does **not** support in-place downgrade. If a run fails:

#### Master broke during/after kubeadm upgrade
1. Identify the etcd snapshot: `kubectl get ns k8s-upgrade -o jsonpath='{.metadata.annotations.viktorbarzin\.me/k8s-upgrade-snapshot-path}'`
2. Restore etcd per `infra/docs/runbooks/restore-etcd.md`.
3. Manually downgrade master `kubeadm`/`kubelet`/`kubectl` to the pre-upgrade version. Find versions in `/var/log/apt/history.log` on the node:
   ```bash
   ssh wizard@k8s-master 'sudo cat /var/log/apt/history.log | tail -40'
   # Pre-upgrade versions are in the most recent "Commandline: apt-get install"
   sudo apt-mark unhold kubeadm kubelet kubectl
   sudo apt-get install --allow-downgrades -y \
     kubeadm=<OLD>-1.1 kubelet=<OLD>-1.1 kubectl=<OLD>-1.1
   sudo apt-mark hold kubeadm kubelet kubectl
   sudo systemctl daemon-reload && sudo systemctl restart kubelet
   ```

#### Worker broke
1. `kubectl drain <node> --ignore-daemonsets --delete-emptydir-data --force --grace-period=300`
2. Downgrade apt packages on that node only (see above)
3. `kubectl uncordon <node>`
4. The cluster continues running on the master + remaining workers throughout

### One-shot SSH key rotation
1. Generate new keypair: `ssh-keygen -t ed25519 -f /tmp/k8s-upgrade -N ""`
2. Update Vault:
   ```bash
   vault kv patch secret/k8s-upgrade \
     ssh_key=@/tmp/k8s-upgrade \
     ssh_key_pub=@/tmp/k8s-upgrade.pub
   ```
3. Push the new pubkey to every node:
   ```bash
   for n in k8s-master k8s-node1 k8s-node2 k8s-node3 k8s-node4; do
     ssh wizard@$n 'sed -i "/k8s-upgrade-key$/d" ~/.ssh/authorized_keys'
     ssh wizard@$n 'echo "$(cat /tmp/k8s-upgrade.pub) k8s-upgrade-key" >> ~/.ssh/authorized_keys'
   done
   ```
4. ESO refreshes within 15 min — or force: `kubectl -n k8s-upgrade annotate externalsecret k8s-upgrade-creds force-sync=$(date +%s) --overwrite`

## Past Incidents

### 2026-05-11 — Self-preemption (agent → Job-chain rewrite)
- The v1 agent ran inside the `claude-agent-service` Deployment (replicas=1, no nodeSelector) and was scheduled to k8s-node4.
- During Stage 6 (first worker drain) the agent ran `kubectl drain k8s-node4` — evicting itself.
- The bash process died after the drain but before the SSH-pipe to install kubeadm on node4.
- Node4 was left cordoned; cluster stuck at master v1.34.7, workers v1.34.2 until manual recovery.
- **Mitigation**: rewrote the pipeline as a chain of Jobs, each `nodeSelector`-pinned to a non-target node. New `predrain_unstick` step deletes PDB-blocked single-replica pods (Anubis pattern) before drain so they don't loop forever. Added `K8sUpgradeStalled` alert (in-flight + started_timestamp > 90 min).

## File Pointers

| What | Where |
|------|-------|
| Stack (CronJob + ConfigMaps + SA/RBAC + ExternalSecret) | `infra/stacks/k8s-version-upgrade/main.tf` |
| Universal phase body | `infra/stacks/k8s-version-upgrade/scripts/upgrade-step.sh` |
| Job template | `infra/stacks/k8s-version-upgrade/job-template.yaml` |
| Per-node upgrade script | `infra/scripts/update_k8s.sh` |
| Upgrade Gates alerts | `infra/stacks/monitoring/modules/monitoring/prometheus_chart_values.tpl` (group "Upgrade Gates") |
| Vault secrets | `secret/k8s-upgrade/{ssh_key, ssh_key_pub, slack_webhook}` |
| Architecture doc | `infra/docs/architecture/automated-upgrades.md` (K8s Version Upgrades section) |
| Related (OS reboots) | `infra/docs/runbooks/k8s-node-auto-upgrades.md` |
| Deprecated agent prompt (reference) | `infra/.claude/agents/k8s-version-upgrade.deprecated.md` |
