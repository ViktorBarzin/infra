#!/usr/bin/env bash
#
# Universal upgrade-step body. Each Job in the k8s-version-upgrade chain runs
# this once, dispatching on $PHASE. On success it computes the next phase from
# LIVE cluster state and spawns the next Job. The chain is:
#
#   preflight  (run on the first worker)
#     ↓
#   master     (drains k8s-master; run on the first worker = the "runner")
#     ↓
#   worker <W> (drains <W>; run on k8s-master w/ control-plane toleration)   ── repeats
#     ↓         for EVERY worker still off-target, enumerated from kubectl
#   postflight (no node pinning)
#
# The worker list is derived dynamically (worker_nodes / next_pending_worker),
# so newly-added nodes are upgraded with no script change — the old hardcoded
# master→node4→3→2→1 chain silently skipped node5/node6 (added 2026-05-26).
# Self-preemption invariant: a Job never runs on the node it drains — the
# master-drain Job runs on a worker; each worker-drain Job runs on the
# already-upgraded master. SSH targets are node InternalIPs (no DNS dependency).
#
# Required env vars (set on the Job pod by job-template.yaml):
#   PHASE              preflight | master | worker | postflight
#   TARGET_NODE        k8s-master | k8s-nodeN  (empty for preflight/postflight)
#   TARGET_VERSION     X.Y.Z
#   KIND               patch | minor
#   IMAGE              container image to use for next Job in the chain

set -euo pipefail

NS=k8s-upgrade
SSH_KEY=/secrets/k8s-upgrade/ssh_key
SLACK_FILE=/secrets/k8s-upgrade/slack_webhook
PG='http://prometheus-prometheus-pushgateway.monitoring:9091/metrics/job/k8s-version-upgrade'
PROM='http://prometheus-server.monitoring.svc.cluster.local:80'
KUBECTL=kubectl
JOB_TEMPLATE=/template/job-template.yaml
UPDATE_K8S_SH=/scripts/update_k8s.sh

# SSH targets are node InternalIPs, resolved live from `kubectl get nodes` (see
# ssh_target() below) — the pipeline has NO dependency on node DNS records
# (`k8s-node<N>.viktorbarzin.lan`). This is what lets a freshly-joined node be
# upgraded with zero DNS/Kea provisioning. (Was FQDN-based until 2026-06-17:
# node5/node6 had no .viktorbarzin.lan records, which blocked the 1.34.9 chain.)

# SSH key must be 0400 — refresh from secret mount (defaultMode does this but
# bind-mount semantics can preserve loose perms; chmod is idempotent).
install -m 0400 "$SSH_KEY" /tmp/ssh_key
SSH_KEY=/tmp/ssh_key

SSH_OPTS=(-i "$SSH_KEY"
          -o StrictHostKeyChecking=accept-new
          -o UserKnownHostsFile=/tmp/known_hosts
          -o ConnectTimeout=10)

SLACK_URL="$(cat "$SLACK_FILE")"

slack() {
  local msg="$1"
  curl -sS -X POST -H 'Content-Type: application/json' \
    --data "$(jq -nc --arg t "[k8s-upgrade-${PHASE}${TARGET_NODE:+:$TARGET_NODE}] $msg" \
              '{text: $t}')" \
    "$SLACK_URL" >/dev/null || echo "warn: slack post failed"
}

# Kill-switch — checked before every phase. If the ConfigMap
# `k8s-upgrade-killswitch` exists in the `k8s-upgrade` namespace, the chain
# halts immediately (exit 0, not 1 — this is an intentional pause, not a
# failure). Restores via `kubectl -n k8s-upgrade delete cm k8s-upgrade-killswitch`.
# Designed for "stop the storm" scenarios: emergency-press the brake from
# any kubectl session in <5 seconds, no script changes needed.
#
# Create:  kubectl -n k8s-upgrade create configmap k8s-upgrade-killswitch \
#               --from-literal=reason="why you stopped it"
# Inspect: kubectl -n k8s-upgrade get cm k8s-upgrade-killswitch -o yaml
# Resume:  kubectl -n k8s-upgrade delete cm k8s-upgrade-killswitch
if $KUBECTL -n "$NS" get configmap k8s-upgrade-killswitch >/dev/null 2>&1; then
  reason=$($KUBECTL -n "$NS" get configmap k8s-upgrade-killswitch \
    -o jsonpath='{.data.reason}' 2>/dev/null || echo "(no reason set)")
  slack "HALTED by kill-switch (phase=$PHASE target_node=${TARGET_NODE:-none}): $reason"
  echo "HALTED by k8s-upgrade-killswitch ConfigMap. Reason: $reason"
  echo "Resume: kubectl -n $NS delete cm k8s-upgrade-killswitch"
  exit 0
fi

push() {
  printf '# TYPE %s gauge\n%s %s\n' "$1" "$1" "$2" \
    | curl -sS --data-binary @- "$PG" || echo "warn: pushgateway push failed"
}

# Auto-upgrade safety: a preflight compat-gate refusal is a BLOCK, not a crash —
# the cluster simply isn't ready for this target yet (an addon / in-use API /
# containerd is too old). Record it (k8s_upgrade_blocked=1 -> K8sUpgradeBlocked
# alert), Slack the reasons, and halt so a human clears the blocker (or a later
# run proceeds once it's cleared). This is the "upgrade when we can, alert when
# we can't" contract.
block() {
  push k8s_upgrade_blocked 1
  slack "BLOCKED preflight (target v$TARGET_VERSION) — auto-upgrade halted, needs attention:\n$1"
  echo "BLOCKED: $1" >&2
  exit 1
}

halt_on_alert_query() {
  local extra_ignore="${1:-}"
  # ALLOWLIST design (refactored 2026-05-23 from a denylist): halt only on
  # alerts with severity=critical. Any warning/info-level alert is treated
  # as informational and doesn't block the chain.
  #
  # Why this is the right model:
  #   - The cluster has long-running warning-level alerts that are NOT
  #     blockers for a k8s patch (e.g. GPU operator crashloop on the GPU
  #     node, ingress latency spikes, IO-wait warnings).
  #   - Maintaining a denylist of every "noisy" alert is a losing battle.
  #   - Critical alerts are the only ones that should actually stop us
  #     mid-chain (apiserver down, etcd down, node not ready, etc.).
  #
  # `extra_ignore` is now mostly historical — kept for backwards compat with
  # `halt_on_alert_query "RecentNodeReboot|IngressTTFBCritical"`-style calls. With severity-based
  # filtering, RecentNodeReboot (severity=info) is filtered automatically.
  # We still build the regex for any critical alert the caller wants to
  # explicitly ignore (e.g. a known-broken thing we're aware of).
  local ignore_regex=""
  [ -n "$extra_ignore" ] && ignore_regex="^($extra_ignore)\$"

  # `grep` returns 1 when nothing matches → under `set -o pipefail` that
  # bubbles up and aborts the script via the caller's `alerts=$(...)`.
  # Trailing `|| true` on each grep handles the no-matches case.
  local critical_firing
  critical_firing=$(curl -sf "$PROM/api/v1/alerts" \
    | jq -r '.data.alerts[]
              | select(.state == "firing" and .labels.severity == "critical")
              | .labels.alertname' 2>/dev/null \
    | sort -u || true)

  if [ -n "$ignore_regex" ]; then
    echo "$critical_firing" | { grep -vE "$ignore_regex" || true; }
  else
    echo "$critical_firing"
  fi
}

wait_for_node_ready() {
  local node="$1" want_version="$2" deadline=$(( $(date +%s) + 900 ))  # 15 min
  while [ "$(date +%s)" -lt "$deadline" ]; do
    local status kubelet
    status=$($KUBECTL get node "$node" -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null || true)
    kubelet=$($KUBECTL get node "$node" -o jsonpath='{.status.nodeInfo.kubeletVersion}' 2>/dev/null | tr -d v || true)
    if [ "$status" = "True" ] && [ "$kubelet" = "$want_version" ]; then
      return 0
    fi
    sleep 15
  done
  return 1
}

# Pre-drain: find pods on $node whose PDB has zero disruptionsAllowed and
# delete them directly. Drain's eviction API respects PDBs and will loop
# forever on single-replica deployments with `minAvailable: 1` — common
# pattern on this cluster (e.g. Anubis instances default to replicas=1). A
# direct delete bypasses eviction; the parent Deployment recreates the pod
# elsewhere (the node is already cordoned by drain).
predrain_unstick() {
  local node="$1"
  $KUBECTL get pdb -A -o json | jq -r '
    .items[]
    | select(.status.disruptionsAllowed == 0)
    | "\(.metadata.namespace) \(.spec.selector.matchLabels | to_entries | map("\(.key)=\(.value)") | join(","))"
  ' | while read -r ns selector; do
    [ -z "$selector" ] && continue
    $KUBECTL -n "$ns" get pods --field-selector "spec.nodeName=$node,status.phase=Running" \
      -l "$selector" -o name 2>/dev/null \
      | while read -r pod; do
          echo "predrain_unstick: deleting PDB-blocked $ns/$pod (drain would loop on it)"
          $KUBECTL -n "$ns" delete "$pod" --wait=false || true
        done
  done
}

# Drain wrapper: kick predrain_unstick before drain, then again every 60s in
# the background while drain runs (in case new pods land mid-drain). Drain
# exits when the node has no non-daemonset workload.
drain_node() {
  local node="$1"
  predrain_unstick "$node"
  ( while kill -0 $$ 2>/dev/null; do sleep 60; predrain_unstick "$node"; done ) &
  local watcher=$!
  trap "kill $watcher 2>/dev/null || true" EXIT
  $KUBECTL drain "$node" --ignore-daemonsets --delete-emptydir-data --force --grace-period=300
  kill $watcher 2>/dev/null || true
  trap - EXIT
}

# ---------------------------------------------------------------------------
# Cluster topology — derived live so new nodes are covered automatically
# ---------------------------------------------------------------------------
# The old chain hardcoded master→node4→3→2→1 and silently skipped node5/node6
# (added 2026-05-26). Everything below enumerates nodes from `kubectl get nodes`
# instead, and SSHes by InternalIP (no .viktorbarzin.lan DNS record needed), so
# a freshly-joined worker is upgraded with ZERO pipeline changes.
#
# Self-preemption invariant preserved: a phase Job never runs on the node it
# drains. The master-drain Job runs on a worker (the "runner"); every
# worker-drain Job runs on the (already-upgraded) master.
worker_nodes() { $KUBECTL get nodes -l '!node-role.kubernetes.io/control-plane' \
  -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}' | sort; }
all_nodes() { { echo k8s-master; worker_nodes; } | sed '/^$/d'; }
# SSH target = the node's InternalIP (avoids any DNS dependency).
ssh_target() { echo "wizard@$($KUBECTL get node "$1" \
  -o jsonpath='{.status.addresses[?(@.type=="InternalIP")].address}')"; }
# First worker not yet on $TARGET_VERSION, excluding $1 (the node the current
# phase is upgrading — still pending when this runs). Empty → all workers done.
next_pending_worker() {
  local n v exclude="${1:-}"
  while read -r n; do
    [ -z "$n" ] && continue
    [ "$n" = "$exclude" ] && continue
    v=$($KUBECTL get node "$n" -o jsonpath='{.status.nodeInfo.kubeletVersion}' 2>/dev/null | tr -d v)
    [ "$v" != "$TARGET_VERSION" ] && { echo "$n"; return 0; }
  done < <(worker_nodes)
  # No worker left off-target. Explicit success — the loop's final `read` exits
  # 1 at EOF, and `next_w="$(next_pending_worker …)"` under `set -e` would abort
  # the chain BEFORE the postflight branch (cluster upgraded but no cleanup /
  # in_flight reset / success). Verified blocker — keep this return 0.
  return 0
}

# ---------------------------------------------------------------------------
# Chain definition — what comes after the current phase (dynamic)
# ---------------------------------------------------------------------------

NEXT_PHASE=""
NEXT_TARGET_NODE=""
NEXT_RUN_ON=""

case "$PHASE" in
  preflight)
    # master upgrade drains the control-plane node → its Job runs on a worker.
    NEXT_PHASE=master
    NEXT_RUN_ON="$(worker_nodes | head -1)" ;;
  master | worker)
    # Next worker still off-target (excluding the one this phase handled). Its
    # Job runs on the already-upgraded master (k8s-master, control-plane
    # toleration). Dynamic → every worker incl. node5/6 + any future node.
    next_w="$(next_pending_worker "${TARGET_NODE:-}")"
    if [ -n "$next_w" ]; then
      NEXT_PHASE=worker; NEXT_TARGET_NODE="$next_w"; NEXT_RUN_ON=k8s-master
    else
      NEXT_PHASE=postflight; NEXT_RUN_ON=""   # all workers on target
    fi ;;
  postflight)
    NEXT_PHASE="" ;;                          # end of chain
  *)
    echo "ERROR: unknown phase: $PHASE" >&2
    exit 2 ;;
esac

spawn_next() {
  [ -z "$NEXT_PHASE" ] && { echo "End of chain."; return 0; }

  local job_name="k8s-upgrade-${NEXT_PHASE}-${TARGET_VERSION//./-}"
  [ -n "${NEXT_TARGET_NODE:-}" ] && job_name="${job_name}-${NEXT_TARGET_NODE}"

  # Retry-on-failure idempotency: skip an existing next-Job ONLY if it is
  # Active or Complete. A *Failed* Job (a phase that aborted on a transient
  # gate) is deleted and re-created — otherwise its deterministic name plus
  # ttlSecondsAfterFinished (7d) would block the whole chain from re-running
  # that phase until the dead Job aged out. (Stuck-pipeline fix 2026-06-17:
  # a transient critical alert wedged the 1.34.9 preflight for 5 days.)
  if $KUBECTL -n "$NS" get job "$job_name" >/dev/null 2>&1; then
    local job_failed
    job_failed=$($KUBECTL -n "$NS" get job "$job_name" \
      -o jsonpath='{.status.conditions[?(@.type=="Failed")].status}' 2>/dev/null || true)
    if [ "$job_failed" = "True" ]; then
      echo "Next Job $job_name exists but FAILED — deleting and re-spawning."
      $KUBECTL -n "$NS" delete job "$job_name" --wait=true >/dev/null 2>&1 || true
    else
      echo "Next Job $job_name already exists (active/complete); idempotent skip."
      return 0
    fi
  fi

  local scheduling_block=""
  case "${NEXT_RUN_ON:-}" in
    k8s-master)
      scheduling_block=$'      nodeSelector:\n        kubernetes.io/hostname: k8s-master\n      tolerations:\n        - key: node-role.kubernetes.io/control-plane\n          operator: Exists\n          effect: NoSchedule' ;;
    "")
      scheduling_block="" ;;
    *)
      scheduling_block=$'      nodeSelector:\n        kubernetes.io/hostname: '"$NEXT_RUN_ON" ;;
  esac

  export JOB_NAME="$job_name"
  export PHASE_NEXT="$NEXT_PHASE"
  export TARGET_NODE_NEXT="${NEXT_TARGET_NODE:-}"
  export TARGET_VERSION_LABEL="${TARGET_VERSION//./-}"
  export SCHEDULING_BLOCK="$scheduling_block"
  # TARGET_VERSION, KIND, IMAGE inherited from current env

  echo "Spawning next Job: $job_name (phase=$NEXT_PHASE target=${NEXT_TARGET_NODE:-} run_on=${NEXT_RUN_ON:-anywhere})"
  # python3 expandvars replaces $VAR / ${VAR} from env, same semantics as
  # envsubst but available in the claude-agent-service image (which lacks
  # gettext-base). Multi-line $SCHEDULING_BLOCK is preserved correctly.
  python3 -c 'import os,sys;sys.stdout.write(os.path.expandvars(sys.stdin.read()))' \
    <"$JOB_TEMPLATE" | $KUBECTL apply -f -
}

# ---------------------------------------------------------------------------
# Phase bodies
# ---------------------------------------------------------------------------

phase_preflight() {
  slack "Starting preflight (target v$TARGET_VERSION, kind=$KIND)"

  # 0. Auto-upgrade compat gate (compat-gate.py): refuse the upgrade if a critical
  #    addon, an in-use deprecated API, or a node's containerd is too old for the
  #    target. Runs FIRST — before any mutation (etcd snapshot, drains) — so a
  #    block is cheap. Reset the blocked gauge for this run; block() sets it to 1
  #    only on a refusal. This is what makes unattended minor upgrades safe: the
  #    chain proceeds when the cluster supports the target and halts+alerts when
  #    it doesn't (e.g. Calico/ESO/kyverno behind, or a removed API still in use).
  push k8s_upgrade_blocked 0
  local gate_out gate_rc=0
  gate_out=$(python3 /scripts/compat-gate.py "$TARGET_VERSION" < /scripts/addon-compat.json 2>&1) || gate_rc=$?
  if [ "$gate_rc" -ne 0 ]; then block "$gate_out"; fi
  echo "compat-gate passed for v$TARGET_VERSION"

  # 1. All nodes Ready + no pressure
  local bad_nodes
  bad_nodes=$($KUBECTL get nodes -o json | jq -r '
    .items[]
    | select(
        (.status.conditions[] | select(.type=="Ready").status) != "True"
        or (.status.conditions[] | select(.type=="MemoryPressure").status) == "True"
        or (.status.conditions[] | select(.type=="DiskPressure").status) == "True")
    | .metadata.name')
  if [ -n "$bad_nodes" ]; then
    slack "ABORT preflight — nodes unhealthy: $bad_nodes"
    exit 1
  fi

  # 2. Halt-on-alert. RecentNodeReboot is fully redundant with check 3
  # (inline quiet-baseline) below — both surface "a node rebooted recently".
  # Including it here meant the chain refused to start for 1h after EVERY
  # kured reboot of any node (kured fires whenever /var/run/reboot-required
  # is set, often daily). Now skipped — check 3 is the single source of truth
  # for "is the cluster quiet enough to upgrade".
  local alerts
  alerts=$(halt_on_alert_query "RecentNodeReboot|IngressTTFBCritical")
  if [ -n "$alerts" ]; then
    slack "ABORT preflight — firing alerts:\n$alerts"
    exit 1
  fi

  # 3. Quiet-baseline check — fail if any node had a Ready transition in the
  # last 10 min. Tightened from 3600s → 600s on 2026-05-21 after diagnosing
  # that the previous 1h window meant the chain couldn't run after any
  # reboot for an hour. 10min is sufficient for kubelet/control-plane to
  # stabilise; the kured-sentinel-gate DaemonSet enforces the broader
  # 24h-between-cluster-reboots invariant.
  local recent=0 now_ep ts_ep
  now_ep=$(date -u +%s)
  while IFS= read -r ts; do
    [ -z "$ts" ] && continue
    # Portable ISO8601(UTC) -> epoch. GNU `date -d` parses ISO8601 directly;
    # busybox `date` (the ghcr claude-agent-service base) does NOT and needs an
    # explicit -D format. Before 2026-06-17 the bare `date -d "$ts"` silently
    # failed on busybox, making this whole settle-window check a no-op. On
    # parse failure, warn + skip the node (never silently treat it as quiet).
    ts_ep=$(date -u -d "$ts" +%s 2>/dev/null || true)
    if [ -z "$ts_ep" ]; then ts_ep=$(date -u -D '%Y-%m-%dT%H:%M:%SZ' -d "$ts" +%s 2>/dev/null || true); fi
    if [ -z "$ts_ep" ]; then echo "WARN quiet-baseline: cannot parse Ready ts '$ts' (date impl?); skipping"; continue; fi
    if [ "$(( now_ep - ts_ep ))" -lt 600 ]; then recent=1; break; fi
  done < <($KUBECTL get nodes -o jsonpath='{range .items[*]}{range .status.conditions[?(@.type=="Ready")]}{.lastTransitionTime}{"\n"}{end}{end}')
  if [ "$recent" -eq 1 ]; then
    slack "ABORT preflight — node transitioned Ready <10min ago (settle window)"
    exit 1
  fi

  # 4. kubeadm upgrade plan matches target. `plan` runs the same CoreDNS
  # preflight as `apply`; once master's kubeadm is on the new version it errors
  # on a Keel-drifted CoreDNS (start version unsupported) and, under pipefail,
  # aborts this whole check. Ignore the two CoreDNS checks here too so plan
  # still emits its "kubeadm upgrade apply vX.Y.Z" line. (See update_k8s.sh.)
  #
  # SKIP this gate when k8s-master is ALREADY on TARGET_VERSION — a partial-chain
  # resume (master + earlier workers done, later workers still pending). `kubeadm
  # upgrade plan` run on an at-target master prints NO "kubeadm upgrade apply
  # vX.Y.Z" line, so the parse below yields an EMPTY plan_target and the `!=`
  # check aborts every run — even though the chain just needs to finish the
  # remaining workers (phase_master self-skips an at-target master the same way,
  # below). Confirmed root cause of the 1.34.9 preflight aborts (2026-06-18):
  # master was already on 1.34.9 while node2-6 lagged on 1.34.8, so every nightly
  # preflight died here with an empty `plan target  ≠ requested 1.34.9`.
  local master_kubelet_v
  master_kubelet_v=$($KUBECTL get node k8s-master -o jsonpath='{.status.nodeInfo.kubeletVersion}' 2>/dev/null | tr -d v)
  if [ "$master_kubelet_v" = "$TARGET_VERSION" ]; then
    slack "preflight — k8s-master already on v$TARGET_VERSION; skipping kubeadm-plan-target gate (workers still pending)"
    echo "k8s-master already on v$TARGET_VERSION — skipping kubeadm-plan-target gate"
  else
    local plan_target
    plan_target=$(ssh "${SSH_OPTS[@]}" "$(ssh_target k8s-master)" 'sudo kubeadm upgrade plan --ignore-preflight-errors=CoreDNSMigration,CoreDNSUnsupportedPlugins' \
      | grep -oE 'kubeadm upgrade apply v[0-9]+\.[0-9]+\.[0-9]+' \
      | grep -oE 'v[0-9]+\.[0-9]+\.[0-9]+' | head -1 | tr -d v)
    if [ "$plan_target" != "$TARGET_VERSION" ]; then
      slack "ABORT preflight — kubeadm plan target $plan_target ≠ requested $TARGET_VERSION"
      exit 1
    fi
  fi

  # 5. Push in-flight + started_timestamp metrics + ns annotations
  $KUBECTL annotate ns "$NS" \
    "viktorbarzin.me/k8s-upgrade-in-flight=$(date -u +%FT%TZ)" \
    "viktorbarzin.me/k8s-upgrade-target=$TARGET_VERSION" \
    --overwrite
  push k8s_upgrade_in_flight 1
  push k8s_upgrade_started_timestamp "$(date +%s)"
  push k8s_upgrade_snapshot_taken 0

  # 6. Trigger backup-etcd Job, wait, verify size
  local snap_job="pre-upgrade-etcd-${TARGET_VERSION//./-}-$(date +%s)"
  $KUBECTL -n default create job --from=cronjob/backup-etcd "$snap_job"
  if ! $KUBECTL -n default wait --for=condition=complete --timeout=600s "job/$snap_job"; then
    $KUBECTL -n default describe "job/$snap_job" | tail -30
    slack "ABORT preflight — etcd snapshot Job did not complete in 10 min"
    exit 1
  fi
  local snap_log size snap_file
  snap_log=$($KUBECTL -n default logs "job/$snap_job" -c backup-manage --tail=20 || \
             $KUBECTL -n default logs "job/$snap_job" --tail=20)
  size=$(echo "$snap_log" | grep -E '^Backup done:' | grep -oE '\([0-9]+ bytes\)' | grep -oE '[0-9]+' || true)
  snap_file=$(echo "$snap_log" | grep -E '^Backup done:' | awk '{print $3}' || true)
  if [ -z "$size" ] || [ "$size" -lt 1024 ]; then
    slack "ABORT preflight — etcd snapshot empty (size='${size:-unknown}')"
    exit 1
  fi
  $KUBECTL annotate ns "$NS" \
    "viktorbarzin.me/k8s-upgrade-snapshot-path=nfs://192.168.1.127:/srv/nfs/etcd-backup/$snap_file" \
    --overwrite
  push k8s_upgrade_snapshot_taken 1

  # 7. Containerd skew fix on master (if master < workers)
  local master_ctr worker_max=0.0.0
  master_ctr=$(ssh "${SSH_OPTS[@]}" "$(ssh_target k8s-master)" "containerd --version | awk '{print \$3}' | tr -d v")
  local n
  while read -r n; do
    [ -z "$n" ] && continue
    local v
    v=$(ssh "${SSH_OPTS[@]}" "$(ssh_target "$n")" "containerd --version | awk '{print \$3}' | tr -d v")
    [ "$(printf '%s\n%s' "$v" "$worker_max" | sort -V | tail -1)" = "$v" ] && worker_max="$v"
  done < <(worker_nodes)
  if [ "$(printf '%s\n%s' "$master_ctr" "$worker_max" | sort -V | head -1)" = "$master_ctr" ] \
     && [ "$master_ctr" != "$worker_max" ]; then
    slack "Master containerd $master_ctr < workers $worker_max — bumping"
    ssh "${SSH_OPTS[@]}" "$(ssh_target k8s-master)" \
      "sudo apt-mark unhold containerd.io && sudo apt-get install -y containerd.io='$worker_max-1' \
       && sudo apt-mark hold containerd.io && sudo systemctl restart containerd"
    wait_for_node_ready k8s-master "$($KUBECTL get node k8s-master -o jsonpath='{.status.nodeInfo.kubeletVersion}' | tr -d v)" \
      || { slack "ABORT — k8s-master not Ready after containerd bump"; exit 1; }
    slack "Master containerd: $master_ctr → $worker_max. Master Ready."
  fi

  # 8. Apt repo URL rewrite (minor only)
  if [ "$KIND" = "minor" ]; then
    local target_minor="${TARGET_VERSION%.*}"
    while read -r n; do
      [ -z "$n" ] && continue
      ssh "${SSH_OPTS[@]}" "$(ssh_target "$n")" \
        "echo 'deb [signed-by=/etc/apt/keyrings/kubernetes-apt-keyring.gpg] https://pkgs.k8s.io/core:/stable:/v$target_minor/deb/ /' | sudo tee /etc/apt/sources.list.d/kubernetes.list \
         && curl -fsSL 'https://pkgs.k8s.io/core:/stable:/v$target_minor/deb/Release.key' \
              | sudo gpg --dearmor -o /etc/apt/keyrings/kubernetes-apt-keyring.gpg --batch --yes \
         && sudo apt-get update"
    done < <(all_nodes)
    slack "Apt repo rewritten to v$target_minor/deb on all nodes"
  fi

  slack "Preflight clean. Snapshot at nfs://...$snap_file ($size bytes). Dispatching master Job."
}

phase_master() {
  # Idempotency: skip the whole phase if k8s-master is already on target.
  # The chain can re-run after a partial failure (e.g. workers got cut
  # short); without this short-circuit we re-drain and re-kubeadm an
  # already-upgraded master for no reason. Added 2026-05-23.
  local current_v
  current_v=$($KUBECTL get node k8s-master -o jsonpath='{.status.nodeInfo.kubeletVersion}' 2>/dev/null | tr -d v)
  if [ "$current_v" = "$TARGET_VERSION" ]; then
    slack "k8s-master already on v$TARGET_VERSION (kubelet=$current_v) — skipping master phase"
    echo "k8s-master already on v$TARGET_VERSION — skipping"
    return 0
  fi

  slack "Draining k8s-master"

  # Re-check halt-on-alert before drain. Always ignore RecentNodeReboot —
  # the chain itself causes node reboots, so this alert firing is expected
  # mid-chain (e.g. master was already upgraded+rebooted before this phase).
  local alerts
  alerts=$(halt_on_alert_query "RecentNodeReboot|IngressTTFBCritical")
  [ -n "$alerts" ] && { slack "ABORT master — alerts firing pre-drain: $alerts"; exit 1; }

  # Quiesce noisy operators that crashloop when apiserver briefly disappears
  # during the static-pod manifest swaps. The crashloop generates a disk-I/O
  # storm (~500 MB/s observed from tigera-operator alone) that slows the
  # apiserver↔kubelet status sync past kubeadm's hardcoded 5-min watch on
  # `kubernetes.io/config.hash`, causing kubeadm to roll back the upgrade.
  #
  # The data plane (calico-node DaemonSet, calico-typha, calico-kube-controllers)
  # keeps running unchanged — only the OPERATOR (a config reconciler) goes away
  # briefly. Restored at the end of the phase below.
  #
  # Long-term fix: HA control plane (3 masters) so apiserver never goes down
  # — see docs/plans/2026-05-21-ha-control-plane-{design,plan}.md (beads code-n0ow).
  drain_node k8s-master

  # Quiesce tigera-operator ONLY for the kubeadm window. Drain happens FIRST (it
  # doesn't blip the apiserver — only the static-pod swaps in `kubeadm upgrade
  # apply` do), then quiesce right before that. The EXIT trap GUARANTEES the
  # operator is restored even if any step below aborts: on 2026-06-17 the master
  # run aborted on a post-upgrade gate AFTER quiescing, the idempotent retry then
  # skipped the (now already-on-target) master phase, and the operator sat at 0
  # for ~1.5h. The trap is set AFTER drain_node so drain_node's own EXIT trap
  # (background predrain-watcher cleanup) can't clobber it.
  echo "Quiescing tigera-operator for the kubeadm window (it crashes on apiserver outage)"
  $KUBECTL -n tigera-operator scale deploy tigera-operator --replicas=0 2>&1 || true
  trap '$KUBECTL -n tigera-operator scale deploy tigera-operator --replicas=1 >/dev/null 2>&1 || true' EXIT

  slack "Running update_k8s.sh on k8s-master (--role master --release $TARGET_VERSION)"
  ssh "${SSH_OPTS[@]}" "$(ssh_target k8s-master)" 'bash -s' \
    < "$UPDATE_K8S_SH" -- --role master --release "$TARGET_VERSION"

  $KUBECTL uncordon k8s-master

  wait_for_node_ready k8s-master "$TARGET_VERSION" \
    || { slack "ABORT — k8s-master not Ready or wrong version after upgrade"; exit 1; }

  local not_ready
  # `grep -v Running` returns 1 when all pods are Running (happy path);
  # under `set -o pipefail` that aborts the script. Wrap in `|| true`.
  not_ready=$($KUBECTL -n kube-system get pods -l 'tier=control-plane' --no-headers 2>/dev/null \
    | { grep -v Running || true; } | wc -l)
  if [ "$not_ready" -gt 0 ]; then
    slack "ABORT — $not_ready control-plane pods not Running after master upgrade"
    exit 1
  fi

  alerts=$(halt_on_alert_query "RecentNodeReboot|IngressTTFBCritical")
  [ -n "$alerts" ] && { slack "ABORT master — alerts firing post-upgrade: $alerts"; exit 1; }

  # Re-apply apiserver OIDC. `kubeadm upgrade apply` regenerates the apiserver
  # static-pod manifest and DROPS --authentication-config, silently breaking SSO
  # (kubectl/kubelogin + the dashboard) until re-applied — historically a manual
  # `tg apply` of the rbac stack after every control-plane bump. Automate it here
  # while tigera-operator is STILL quiesced, so the flag-add apiserver restart
  # cannot crashloop the operator. Single source of truth: the rbac stack
  # publishes the exact script its own null_resource runs to a kube-system
  # ConfigMap; it is idempotent and health-gates /livez with auto-rollback, and a
  # failure here is NON-FATAL (the version upgrade already succeeded — only SSO
  # would lag until the next rbac apply).
  local oidc_restore
  oidc_restore=$($KUBECTL -n kube-system get configmap apiserver-oidc-restore \
    -o jsonpath='{.data.restore\.sh}' 2>/dev/null || true)
  if [ -n "$oidc_restore" ]; then
    slack "Re-applying apiserver OIDC after master upgrade"
    printf '%s' "$oidc_restore" | ssh "${SSH_OPTS[@]}" "$(ssh_target k8s-master)" 'bash -s' \
      || slack "WARN: apiserver OIDC re-apply exited non-zero — verify SSO"
    if ssh "${SSH_OPTS[@]}" "$(ssh_target k8s-master)" \
         'sudo grep -q -- "--authentication-config=" /etc/kubernetes/manifests/kube-apiserver.yaml'; then
      slack "apiserver OIDC restored (--authentication-config present)"
    else
      slack "WARN: --authentication-config absent after re-apply — SSO down; run the rbac apiserver_oidc_config apply"
    fi
  else
    slack "WARN: apiserver-oidc-restore ConfigMap missing — skipping OIDC re-apply (apply the rbac stack)"
  fi

  # Restore tigera-operator (happy path) + clear the safety-net EXIT trap.
  echo "Restoring tigera-operator"
  $KUBECTL -n tigera-operator scale deploy tigera-operator --replicas=1 2>&1 || true
  trap - EXIT

  slack "Master on v$TARGET_VERSION, control-plane Running. Dispatching worker chain."
}

phase_worker() {
  [ -z "$TARGET_NODE" ] && { echo "ERROR: worker phase requires TARGET_NODE"; exit 2; }

  # Idempotency: skip if target node is already on target version. Same
  # rationale as phase_master — chains re-running after partial completion
  # shouldn't re-drain an already-upgraded worker. Added 2026-05-23.
  local current_v
  current_v=$($KUBECTL get node "$TARGET_NODE" -o jsonpath='{.status.nodeInfo.kubeletVersion}' 2>/dev/null | tr -d v)
  if [ "$current_v" = "$TARGET_VERSION" ]; then
    slack "$TARGET_NODE already on v$TARGET_VERSION (kubelet=$current_v) — skipping worker phase"
    echo "$TARGET_NODE already on v$TARGET_VERSION — skipping"
    return 0
  fi

  slack "Draining $TARGET_NODE"

  # Halt-on-alert wait (up to 30 min). Ignore RecentNodeReboot — the chain
  # just rebooted a node, that's the cause and is expected.
  local attempt alerts
  for attempt in $(seq 1 30); do
    alerts=$(halt_on_alert_query "RecentNodeReboot|IngressTTFBCritical")
    [ -z "$alerts" ] && break
    echo "Waiting for alerts to clear (attempt $attempt/30): $alerts"
    sleep 60
  done
  [ -n "$alerts" ] && { slack "ABORT $TARGET_NODE — alerts firing after 30min: $alerts"; exit 1; }

  drain_node "$TARGET_NODE"

  slack "Running update_k8s.sh on $TARGET_NODE (--role worker --release $TARGET_VERSION)"
  ssh "${SSH_OPTS[@]}" "$(ssh_target "$TARGET_NODE")" 'bash -s' \
    < "$UPDATE_K8S_SH" -- --role worker --release "$TARGET_VERSION"

  $KUBECTL uncordon "$TARGET_NODE"

  wait_for_node_ready "$TARGET_NODE" "$TARGET_VERSION" \
    || { slack "ABORT — $TARGET_NODE not Ready or wrong version"; exit 1; }

  # Daemonsets back on the node
  local missing=0
  for ds in calico-node kube-proxy; do
    local count
    count=$($KUBECTL get pods -A -o wide --field-selector "spec.nodeName=$TARGET_NODE,status.phase=Running" --no-headers \
      | awk -v d="$ds" '$2 ~ d {n++} END{print n+0}')
    [ "$count" -lt 1 ] && missing=$((missing+1))
  done
  [ "$missing" -gt 0 ] && { slack "WARN $TARGET_NODE — $missing daemonset(s) missing"; }

  # 10-min soak with halt-on-alert (RecentNodeReboot ignored — we know we restarted it)
  echo "Soaking $TARGET_NODE for 10 min..."
  for i in $(seq 1 10); do
    alerts=$(halt_on_alert_query "RecentNodeReboot|IngressTTFBCritical")
    [ -n "$alerts" ] && { slack "ABORT $TARGET_NODE mid-soak — alerts: $alerts"; exit 1; }
    sleep 60
  done

  slack "$TARGET_NODE on v$TARGET_VERSION. Soaked clean (10 min)."
}

phase_postflight() {
  slack "Running postflight"

  # Belt-and-suspenders: ensure tigera-operator is back to 1 at chain end. The
  # master phase's EXIT trap already restores it, but a master phase that was
  # skipped-on-retry (master already on target) never quiesces OR restores, so
  # if an earlier aborted attempt left it down this is the final guarantee.
  $KUBECTL -n tigera-operator scale deploy tigera-operator --replicas=1 >/dev/null 2>&1 || true

  # All nodes at target
  local versions wrong
  versions=$($KUBECTL get nodes -o jsonpath='{range .items[*]}{.metadata.name}:{.status.nodeInfo.kubeletVersion}{"\n"}{end}')
  # `grep -v` returns 1 when all nodes are on target (the happy path —
  # exactly when postflight SHOULD succeed); under `set -o pipefail` that
  # would abort the script right at the moment of victory.
  wrong=$(echo "$versions" | { grep -v ":v${TARGET_VERSION}\$" || true; } | wc -l)
  if [ "$wrong" -ne 0 ]; then
    slack "ABORT postflight — $wrong node(s) off target:\n$versions"
    exit 1
  fi

  # No alerts firing. Ignore RecentNodeReboot — by definition we just
  # rebooted every node; this alert clears naturally in <1h.
  local alerts
  alerts=$(halt_on_alert_query "RecentNodeReboot|IngressTTFBCritical")
  [ -n "$alerts" ] && slack "Postflight WARN — alerts still firing (cluster on target, please check):\n$alerts"

  # Pod-ready ratio
  local ratio
  ratio=$(curl -sf "$PROM/api/v1/query" \
            --data-urlencode 'query=sum(kube_pod_status_ready{condition="true"}) / sum(kube_pod_status_phase{phase="Running"})' \
          | jq -r '.data.result[0].value[1] // "0"')

  # ---------------------------------------------------------------------------
  # Deeper smoke tests — catch a cluster that's "all pods Running" but actually
  # broken after the upgrade (dead apiserver health endpoints, broken
  # CoreDNS/in-cluster DNS, or a control-plane component that's only superficially
  # up). Uses ONLY the chain's existing permissions: read-only kubectl raw API
  # reads + this pod's own resolver. No new pods/exec/images/RBAC. We do NOT
  # rollback — kubeadm can't downgrade — we halt loudly for a human.
  local smoke_failed=0

  # 1. apiserver health endpoints. `kubectl get --raw` exits non-zero on a
  #    non-200, which under `set -e` would abort — capture rc explicitly.
  local readyz_out readyz_rc=0 livez_out livez_rc=0
  readyz_out=$($KUBECTL get --raw='/readyz' 2>&1) || readyz_rc=$?
  if [ "$readyz_rc" -ne 0 ] || [ "$readyz_out" != "ok" ]; then
    smoke_failed=1
    slack "postflight smoke FAIL — apiserver /readyz not ok (rc=$readyz_rc, body='${readyz_out:0:200}')"
  fi
  livez_out=$($KUBECTL get --raw='/livez' 2>&1) || livez_rc=$?
  if [ "$livez_rc" -ne 0 ] || [ "$livez_out" != "ok" ]; then
    smoke_failed=1
    slack "postflight smoke FAIL — apiserver /livez not ok (rc=$livez_rc, body='${livez_out:0:200}')"
  fi

  # 2. In-cluster DNS resolution from THIS pod's resolver. If CoreDNS / kube-dns
  #    is broken after the upgrade, resolving the apiserver's cluster service
  #    name fails here even though pods may still look Running.
  local dns_rc=0
  python3 -c 'import socket; socket.gethostbyname("kubernetes.default.svc.cluster.local")' >/dev/null 2>&1 || dns_rc=$?
  if [ "$dns_rc" -ne 0 ]; then
    smoke_failed=1
    slack "postflight smoke FAIL — in-cluster DNS broken (could not resolve kubernetes.default.svc.cluster.local; CoreDNS down?)"
  fi

  # 3. Core kube-system pods Running: control-plane statics (apiserver,
  #    controller-manager, scheduler, etcd) AND CoreDNS. `grep -v Running`
  #    returns 1 when everything is Running (the happy path) → wrap in `|| true`
  #    so pipefail doesn't abort us at the moment of success.
  local comp not_running
  for comp in kube-apiserver kube-controller-manager kube-scheduler etcd coredns; do
    not_running=$($KUBECTL -n kube-system get pods --no-headers 2>/dev/null \
      | { grep -E "(^|[[:space:]])${comp}-" || true; } \
      | { grep -v Running || true; } | wc -l)
    if [ "$not_running" -gt 0 ]; then
      smoke_failed=1
      slack "postflight smoke FAIL — $not_running kube-system '$comp' pod(s) not Running after upgrade"
    fi
  done

  if [ "$smoke_failed" -ne 0 ]; then
    slack "postflight smoke tests FAILED — upgrade left the cluster unhealthy, halting for a human (no rollback; kubeadm can't downgrade)"
    exit 1
  fi
  echo "postflight smoke tests passed (apiserver health + DNS + core kube-system pods)"

  # Clear annotations + gauges
  $KUBECTL annotate ns "$NS" \
    'viktorbarzin.me/k8s-upgrade-in-flight-' \
    'viktorbarzin.me/k8s-upgrade-target-' \
    'viktorbarzin.me/k8s-upgrade-snapshot-path-' || true
  push k8s_upgrade_in_flight 0
  push k8s_upgrade_snapshot_taken 0
  push k8s_upgrade_started_timestamp 0

  slack ":white_check_mark: K8s upgrade complete: cluster on v$TARGET_VERSION (pod-ready ratio $ratio)"
}

# ---------------------------------------------------------------------------
# Dispatch
# ---------------------------------------------------------------------------

case "$PHASE" in
  preflight)  phase_preflight ;;
  master)     phase_master ;;
  worker)     phase_worker ;;
  postflight) phase_postflight ;;
  *) echo "ERROR: unknown PHASE: $PHASE" >&2; exit 2 ;;
esac

spawn_next
