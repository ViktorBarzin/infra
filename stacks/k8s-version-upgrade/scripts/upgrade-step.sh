#!/usr/bin/env bash
#
# Universal upgrade-step body. Each Job in the k8s-version-upgrade chain runs
# this once, dispatching on $PHASE. On success it computes the next phase and
# spawns the next Job. The chain is:
#
#   preflight  (run on k8s-node1)
#     ↓
#   master     (drains k8s-master; run on k8s-node1)
#     ↓
#   worker k8s-node4   (run on k8s-node1)
#     ↓
#   worker k8s-node3   (run on k8s-node1)
#     ↓
#   worker k8s-node2   (run on k8s-node1)
#     ↓
#   worker k8s-node1   (drains k8s-node1; run on k8s-master with control-plane toleration)
#     ↓
#   postflight (no node pinning)
#
# k8s-node1 hosts every Job except the one that drains k8s-node1 itself.
# k8s-node1 is therefore upgraded LAST.
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

# Pod-side DNS: the cluster's CoreDNS has search domains
# `<ns>.svc.cluster.local svc.cluster.local cluster.local` (plus ndots=2 via
# Kyverno mutation). Unqualified `k8s-master` falls through all of these and
# then queries the upstream DNS (Technitium) for bare `k8s-master`, which
# returns NXDOMAIN. The FQDN `k8s-master.viktorbarzin.lan` is what Technitium
# actually serves. Suffix every node SSH target with this domain.
NODE_DOMAIN=".viktorbarzin.lan"

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
  # `halt_on_alert_query RecentNodeReboot`-style calls. With severity-based
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
# Chain definition — what comes after the current phase
# ---------------------------------------------------------------------------

NEXT_PHASE=""
NEXT_TARGET_NODE=""
NEXT_RUN_ON=""

case "${PHASE}:${TARGET_NODE:-}" in
  preflight:)
    NEXT_PHASE=master
    NEXT_RUN_ON=k8s-node1 ;;
  master:)
    NEXT_PHASE=worker; NEXT_TARGET_NODE=k8s-node4
    NEXT_RUN_ON=k8s-node1 ;;
  worker:k8s-node4)
    NEXT_PHASE=worker; NEXT_TARGET_NODE=k8s-node3
    NEXT_RUN_ON=k8s-node1 ;;
  worker:k8s-node3)
    NEXT_PHASE=worker; NEXT_TARGET_NODE=k8s-node2
    NEXT_RUN_ON=k8s-node1 ;;
  worker:k8s-node2)
    NEXT_PHASE=worker; NEXT_TARGET_NODE=k8s-node1
    NEXT_RUN_ON=k8s-master ;;  # control-plane toleration required
  worker:k8s-node1)
    NEXT_PHASE=postflight
    NEXT_RUN_ON="" ;;          # no node pinning for postflight
  postflight:)
    NEXT_PHASE="" ;;           # end of chain
  *)
    echo "ERROR: unknown phase/target combo: ${PHASE}/${TARGET_NODE:-}" >&2
    exit 2 ;;
esac

spawn_next() {
  [ -z "$NEXT_PHASE" ] && { echo "End of chain."; return 0; }

  local job_name="k8s-upgrade-${NEXT_PHASE}-${TARGET_VERSION//./-}"
  [ -n "${NEXT_TARGET_NODE:-}" ] && job_name="${job_name}-${NEXT_TARGET_NODE}"

  if $KUBECTL -n "$NS" get job "$job_name" >/dev/null 2>&1; then
    echo "Next Job $job_name already exists; idempotent skip."
    return 0
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
  alerts=$(halt_on_alert_query RecentNodeReboot)
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
  local recent=0
  while IFS= read -r ts; do
    [ -z "$ts" ] && continue
    local diff=$(( $(date +%s) - $(date -d "$ts" +%s) ))
    if [ "$diff" -lt 600 ]; then recent=1; break; fi
  done < <($KUBECTL get nodes -o jsonpath='{range .items[*]}{range .status.conditions[?(@.type=="Ready")]}{.lastTransitionTime}{"\n"}{end}{end}')
  if [ "$recent" -eq 1 ]; then
    slack "ABORT preflight — node transitioned Ready <10min ago (settle window)"
    exit 1
  fi

  # 4. kubeadm upgrade plan matches target
  local plan_target
  plan_target=$(ssh "${SSH_OPTS[@]}" "wizard@k8s-master$NODE_DOMAIN" 'sudo kubeadm upgrade plan' \
    | grep -oE 'kubeadm upgrade apply v[0-9]+\.[0-9]+\.[0-9]+' \
    | grep -oE 'v[0-9]+\.[0-9]+\.[0-9]+' | head -1 | tr -d v)
  if [ "$plan_target" != "$TARGET_VERSION" ]; then
    slack "ABORT preflight — kubeadm plan target $plan_target ≠ requested $TARGET_VERSION"
    exit 1
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
  master_ctr=$(ssh "${SSH_OPTS[@]}" "wizard@k8s-master$NODE_DOMAIN" "containerd --version | awk '{print \$3}' | tr -d v")
  for n in k8s-node1 k8s-node2 k8s-node3 k8s-node4; do
    local v
    v=$(ssh "${SSH_OPTS[@]}" "wizard@$n$NODE_DOMAIN" "containerd --version | awk '{print \$3}' | tr -d v")
    [ "$(printf '%s\n%s' "$v" "$worker_max" | sort -V | tail -1)" = "$v" ] && worker_max="$v"
  done
  if [ "$(printf '%s\n%s' "$master_ctr" "$worker_max" | sort -V | head -1)" = "$master_ctr" ] \
     && [ "$master_ctr" != "$worker_max" ]; then
    slack "Master containerd $master_ctr < workers $worker_max — bumping"
    ssh "${SSH_OPTS[@]}" "wizard@k8s-master$NODE_DOMAIN" \
      "sudo apt-mark unhold containerd.io && sudo apt-get install -y containerd.io='$worker_max-1' \
       && sudo apt-mark hold containerd.io && sudo systemctl restart containerd"
    wait_for_node_ready k8s-master "$($KUBECTL get node k8s-master -o jsonpath='{.status.nodeInfo.kubeletVersion}' | tr -d v)" \
      || { slack "ABORT — k8s-master not Ready after containerd bump"; exit 1; }
    slack "Master containerd: $master_ctr → $worker_max. Master Ready."
  fi

  # 8. Apt repo URL rewrite (minor only)
  if [ "$KIND" = "minor" ]; then
    local target_minor="${TARGET_VERSION%.*}"
    for n in k8s-master k8s-node1 k8s-node2 k8s-node3 k8s-node4; do
      ssh "${SSH_OPTS[@]}" "wizard@$n$NODE_DOMAIN" \
        "echo 'deb [signed-by=/etc/apt/keyrings/kubernetes-apt-keyring.gpg] https://pkgs.k8s.io/core:/stable:/v$target_minor/deb/ /' | sudo tee /etc/apt/sources.list.d/kubernetes.list \
         && curl -fsSL 'https://pkgs.k8s.io/core:/stable:/v$target_minor/deb/Release.key' \
              | sudo gpg --dearmor -o /etc/apt/keyrings/kubernetes-apt-keyring.gpg --batch --yes \
         && sudo apt-get update"
    done
    slack "Apt repo rewritten to v$target_minor/deb on all 5 nodes"
  fi

  slack "Preflight clean. Snapshot at nfs://...$snap_file ($size bytes). Dispatching master Job."
}

phase_master() {
  slack "Draining k8s-master"

  # Re-check halt-on-alert before drain. Always ignore RecentNodeReboot —
  # the chain itself causes node reboots, so this alert firing is expected
  # mid-chain (e.g. master was already upgraded+rebooted before this phase).
  local alerts
  alerts=$(halt_on_alert_query RecentNodeReboot)
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
  # If the chain dies between quiesce and restore (e.g. kubeadm fails),
  # manually restore with:
  #   kubectl -n tigera-operator scale deploy tigera-operator --replicas=1
  #
  # Long-term fix: HA control plane (3 masters) so apiserver never goes down
  # — see docs/plans/2026-05-21-ha-control-plane-{design,plan}.md (beads code-n0ow).
  echo "Quiescing tigera-operator before master upgrade (it crashes on apiserver outage)"
  $KUBECTL -n tigera-operator scale deploy tigera-operator --replicas=0 2>&1 || true

  drain_node k8s-master

  slack "Running update_k8s.sh on k8s-master (--role master --release $TARGET_VERSION)"
  ssh "${SSH_OPTS[@]}" "wizard@k8s-master$NODE_DOMAIN" 'bash -s' \
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

  alerts=$(halt_on_alert_query RecentNodeReboot)
  [ -n "$alerts" ] && { slack "ABORT master — alerts firing post-upgrade: $alerts"; exit 1; }

  # Restore tigera-operator (quiesced before drain). It reconciles in seconds.
  echo "Restoring tigera-operator"
  $KUBECTL -n tigera-operator scale deploy tigera-operator --replicas=1 2>&1 || true

  slack "Master on v$TARGET_VERSION, control-plane Running. Dispatching worker chain."
}

phase_worker() {
  [ -z "$TARGET_NODE" ] && { echo "ERROR: worker phase requires TARGET_NODE"; exit 2; }
  slack "Draining $TARGET_NODE"

  # Halt-on-alert wait (up to 30 min). Ignore RecentNodeReboot — the chain
  # just rebooted a node, that's the cause and is expected.
  local attempt alerts
  for attempt in $(seq 1 30); do
    alerts=$(halt_on_alert_query RecentNodeReboot)
    [ -z "$alerts" ] && break
    echo "Waiting for alerts to clear (attempt $attempt/30): $alerts"
    sleep 60
  done
  [ -n "$alerts" ] && { slack "ABORT $TARGET_NODE — alerts firing after 30min: $alerts"; exit 1; }

  drain_node "$TARGET_NODE"

  slack "Running update_k8s.sh on $TARGET_NODE (--role worker --release $TARGET_VERSION)"
  ssh "${SSH_OPTS[@]}" "wizard@$TARGET_NODE$NODE_DOMAIN" 'bash -s' \
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
    alerts=$(halt_on_alert_query RecentNodeReboot)
    [ -n "$alerts" ] && { slack "ABORT $TARGET_NODE mid-soak — alerts: $alerts"; exit 1; }
    sleep 60
  done

  slack "$TARGET_NODE on v$TARGET_VERSION. Soaked clean (10 min)."
}

phase_postflight() {
  slack "Running postflight"

  # All 5 nodes at target
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
  alerts=$(halt_on_alert_query RecentNodeReboot)
  [ -n "$alerts" ] && slack "Postflight WARN — alerts still firing (cluster on target, please check):\n$alerts"

  # Pod-ready ratio
  local ratio
  ratio=$(curl -sf "$PROM/api/v1/query" \
            --data-urlencode 'query=sum(kube_pod_status_ready{condition="true"}) / sum(kube_pod_status_phase{phase="Running"})' \
          | jq -r '.data.result[0].value[1] // "0"')

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
