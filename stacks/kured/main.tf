# kured — Kubernetes Reboot Daemon
#
# Auto-reboots nodes when /var/run/reboot-required exists on the host (set by
# unattended-upgrades). The reboot process is gated by a custom sentinel file
# (kured-sentinel-gate DaemonSet below) and by Prometheus alerts so reboots
# only happen when:
#   - all nodes Ready
#   - all calico-node pods Running
#   - no node has transitioned Ready in the last 24 hours (24h soak)
#   - no Prometheus alert is firing (excluding self-referential ignore-list)
#
# "All nodes" means every node WITHOUT the label
# node-role.viktorbarzin.me/opportunistic (ADR-0045). An Opportunistic worker
# such as dell-worker is offline for days by design, so the three node checks
# leave it out; otherwise it would hold every reboot in Sofia while it is off,
# and its daily return would restart the 24h soak. kured itself does not run
# there: neither kured nor the sentinel gate tolerates the
# node-role.viktorbarzin.me/opportunistic:NoSchedule taint, so kured never
# drains or reboots an Opportunistic worker. Such a node reboots when its owner
# turns it off and on, and its packages are updated by re-running
# playbooks/physical-node.yml (docs/runbooks/physical-node.md).
#
# History:
#   - 2026-03 post-mortem (memory 390): 26h cluster outage triggered by kured
#     rebooting nodes while containerd's overlayfs snapshotter was corrupted.
#     Remediation included the sentinel gate and a tight reboot window
#     (Mon-Fri 02:00-06:00 London).
#   - 2026-04-18: adopted into Terraform (Wave 5a). Previously helm-installed
#     manually + kubectl-applied sentinel gate.
#   - 2026-05-10: re-enabled unattended-upgrades (cloud_init.yaml flipped from
#     remove → install). Sentinel cool-down stretched 30m → 24h. Added Helm
#     values prometheusUrl + alertFilterRegexp so any non-ignored firing alert
#     halts the rollout. New "Upgrade Gates" alert group in monitoring stack
#     (KubeAPIServerDown, KubeStateMetricsDown, PrometheusRuleEvaluationFailing,
#     PVCStuckPending, RecentNodeReboot, MysqlStandaloneDown,
#     ClusterPodReadyRatioDropped, NodeMemoryPressure, NodeDiskPressure,
#     KubeQuotaAlmostFull) provides explicit cluster-health gating.

# -----------------------------------------------------------------------------
# OVERNIGHT FREEZE, 2026-09-13 (Viktor). REMOVE WHEN THE CLEANUP IS DONE.
# -----------------------------------------------------------------------------
# The 2026-09-13 freeze was LIFTED on 2026-09-19. var.frozen stays as the
# emergency hold; set it true to stop kured again. Outage write-up:
# https://pages.viktorbarzin.me/2026-09-13-authentik-outage-recovery.html
#
# State when it was lifted, measured rather than assumed. THREE nodes carry
# /var/run/reboot-required: node2 (since 09-10), node3 (09-10), node4 (09-12).
# master cleared its own when it rebooted on 2026-09-16, so the earlier "four
# nodes, master included" note here was already out of date.
#
# ClusterCannotTolerateNonGpuNodeLoss WAS REMOVED from alertFilterRegexp on
# 2026-09-19. It had blocked every reboot since 2026-09-06, and it was never
# going to stop. The alert itself is honest and stays firing as a capacity
# signal; it was simply the wrong question to gate a reboot on.
#
# What it asks: if a worker vanished and never came back, would its pods fit on
# the rest. Measured over the whole firing window, no. LHS floor 27.98 GiB
# against an RHS ceiling of 17.56 GiB, 50 and 74 samples, never within 10 GiB of
# crossing. What kured asks is different: may I borrow a node for ten to twenty
# minutes tonight.
#
# Both remediations the alert's own annotation suggests are closed, which is why
# the block had no exit. Right-sizing recovers about 3.1 GiB at p99 over 30 days
# against a 12 to 15.5 GiB requirement, because 11 of the top 12 reservers
# already sit at or above their own request; chasing it is the loop that shaved
# prometheus 4Gi to 3Gi on 2026-07-26 for an unreal problem. Adding a worker is
# out too, the hypervisor has 34.85 GiB of 267.35 GiB available with swap 70.9%
# consumed. Capacity stays tracked in bead code-eu6l.
#
# The guard against a node not coming back was never this alert. It is the
# sentinel gate below (all nodes Ready, all calico-node Running, no Ready
# transition in 24h) plus concurrency=1 and drainTimeout=30m, all unchanged.
#
# An earlier version of this comment said to unfreeze only after the outpost
# had a readiness probe. That never happened and no longer applies: the
# outpost's Deployment is not reconciled by authentik at all for an embedded
# outpost, so kubernetes_json_patches cannot add one. See code-f1zd and
# code-osvg
# (bead code-f1zd) and the four pending reboots are being done deliberately, one
# node at a time, master last.
variable "frozen" {
  type        = bool
  default     = false
  description = "Emergency hold: keeps kured and its sentinel gate off every node so no reboot happens unattended. Set true to hold. Used for the 2026-09-13 auth outage, lifted 2026-09-19 once authentik was stable."
}

locals {
  # A label no node carries, so the DaemonSets schedule nowhere.
  freeze_node_selector = var.frozen ? { "kured-frozen-2026-09-13" = "true" } : {}
}

resource "kubernetes_namespace" "kured" {
  metadata {
    name = "kured"
    labels = {
      "istio-injection" = "disabled"
      tier              = local.tiers.cluster
    }
  }
  lifecycle {
    # KYVERNO_LIFECYCLE_V1: goldilocks-vpa-auto-mode ClusterPolicy stamps this label on every namespace
    ignore_changes = [metadata[0].labels["goldilocks.fairwinds.com/vpa-update-mode"]]
  }
}

# -----------------------------------------------------------------------------
# kured Helm release
# -----------------------------------------------------------------------------

resource "helm_release" "kured" {
  namespace        = kubernetes_namespace.kured.metadata[0].name
  create_namespace = false
  name             = "kured"
  chart            = "kured"
  repository       = "https://kubereboot.github.io/charts/"
  version          = "6.1.0"
  # A failed upgrade without these leaves a release with no deployed revision
  # that Terraform cannot upgrade again. The DaemonSet rolls one node at a
  # time, so give the wait 15 minutes.
  atomic          = true
  cleanup_on_fail = true
  timeout         = 900

  depends_on = [kubernetes_manifest.notify_external_secret]

  values = [yamlencode({
    configuration = {
      period    = "1h0m0s"
      timeZone  = "Europe/London"
      startTime = "02:00"
      endTime   = "06:00"
      # All 7 days — operator decision 2026-05-16. The Mon–Fri restriction
      # was a 2026-03-16-era guardrail (overlapping with weekend on-call
      # response). Today the rest of the safety net (halt-on-alert,
      # sentinel-gate Check 4 = 24h soak, single-concurrency, the
      # K8sUpgradeStalled alert) is strong enough to operate any day; the
      # weekday-only schedule was just slowing the backlog down.
      rebootDays = ["mo", "tu", "we", "th", "fr", "sa", "su"]
      # IMPORTANT: must match where kured-sentinel-gate writes (below):
      # `touch /host/var-run/gated-reboot-required` → host
      # `/var/run/gated-reboot-required`. The kured chart derives the host
      # path from `dirname(rebootSentinel)`, so this single setting controls
      # BOTH the in-pod mountPath AND the host hostPath. Previously
      # `/sentinel/gated-reboot-required` — that pointed the chart's hostPath
      # at `/sentinel/` (empty, auto-created by hostPath:Directory) while the
      # gate kept writing to `/var/run/`. kured never saw the open gate so
      # nodes stopped rebooting on 2026-05-10 when unattended-upgrades was
      # re-enabled. Fixed 2026-05-16.
      rebootSentinel = "/var/run/gated-reboot-required"
      concurrency    = 1
      rebootDelay    = "30s"
      # Fail closed instead of looping forever. Default is 0 (unlimited) — if
      # a future PDB or finalizer stalls drain, kured retries indefinitely and
      # the node stays cordoned silently. 30m gives CNPG / shared-store
      # Anubis / any other stateful workload plenty of time to settle, but
      # caps the silent-failure window. After timeout kured logs the abort
      # and waits for the next period; node stays Schedulable so the cluster
      # doesn't lose capacity. Fixed 2026-05-16.
      drainTimeout = "30m"
      # Cloud's drain handoff (Cloud backlog B10, scripts/cloud-drain-handoff.sh).
      # kured labels the node, waits drainDelay, then cordons and drains it
      # (kured 1.23.0 cmd/kured/main.go drain()). The sentinel gate on that
      # node sees the label, cordons the node itself and rollout-restarts each
      # one-pod Cloud Deployment there, so its new pod is Ready on another
      # node before the drain evicts the old one. 5m covers an App's image
      # pull and start; the gate gives up after 4m and the drain goes on as
      # before. kured requires the same label keys before and after.
      drainDelay           = "5m"
      preRebootNodeLabels  = ["cloud.viktorbarzin.me/drain=pending"]
      postRebootNodeLabels = ["cloud.viktorbarzin.me/drain=done"]
      # Halt rolling reboots when ANY firing Prometheus alert is not in the
      # ignore-list. The ignore-list excludes self-referential / always-firing
      # alerts that would otherwise deadlock kured. alertFilterMatchOnly stays
      # false (default) so the regex marks alerts to IGNORE — every other
      # firing alert blocks. See "Upgrade Gates" group in monitoring stack.
      prometheusUrl = "http://prometheus-server.monitoring.svc.cluster.local:80"
      # INVERTED 2026-09-02 to match-only, which is what the "Upgrade Gates"
      # group above was built for. As an ignore-list this halted every reboot:
      # the list named five alerts against a standing floor of five to eight
      # firing warnings, so kured logged "Reboot blocked: 7 active alerts:
      # [DriftStackErrored DriftStacksMany HDDDailyReadVolume
      # ImmichSmartSearchSlow JobFailed StrayWorkloadDetected
      # T3AutoUpdateRolledBack]" and rebooted NO node in the whole retained
      # window. node2 sat pending-reboot from 2026-07-18, so kernel and libc
      # updates went untaken on four nodes. Enumerating the noise was never
      # going to hold, because the floor changes weekly.
      #
      # The list below is therefore what SHOULD stop a reboot, not what should
      # be ignored: the three Upgrade Gates criticals, plus the node and cluster
      # conditions that mean taking a node out right now makes things worse.
      #
      # PVCStuckPending is deliberately NOT here, though it sits in that group.
      # It is a warning about one namespace's volume rather than a statement
      # that the cluster cannot lose a node, and it was firing at the time of
      # writing (chrome-service/chrome-service-backup-host), so including it
      # would have left kured exactly as deadlocked as before.
      #
      # THE FAILURE DIRECTION FLIPS WITH THIS SETTING, so read before editing.
      # As an ignore-list a typo'd name failed CLOSED (blocked forever). Under
      # match-only a typo fails OPEN: the name simply never matches and kured
      # reboots through a condition you meant to gate. Every one of the nine
      # below was checked to exist as `alert: <name>` in
      # stacks/monitoring/.../prometheus_chart_values.tpl. EtcdMembersDown and
      # KubeletDown were considered and left out because neither is defined.
      # Verify existence when adding to this list.
      #
      # Dropped from the old ignore-list, now unnecessary: Watchdog,
      # RebootRequired, KuredNodeWasNotDrained, InfoInhibitor and
      # KernelOOMKiller no longer need naming, because anything unnamed is
      # ignored by default. The 2026-07-27 KernelOOMKiller self-deadlock (the
      # sentinel gate's own kubectls OOM their cgroup, firing the alert that
      # blocks the reboot that would quiesce the gate) cannot recur under
      # match-only for the same reason.
      alertFilterRegexp    = "^(KubeAPIServerDown|KubeStateMetricsDown|PrometheusRuleEvaluationFailing|NodeDown|NodeConditionBad|NodeDiskPressure|NodeMemoryPressure|NFSCSINodeDown)$"
      alertFiringOnly      = true
      alertFilterMatchOnly = true
    }
    # The Slack webhook reaches kured as KURED_NOTIFY_URL from a Secret
    # (kured maps KURED_<FLAG> env vars onto its flags). The chart's
    # configuration.notifyUrl would render it into the DaemonSet args as
    # --notify-url, readable by anyone who can read DaemonSets.
    extraEnvVars = [{
      name = "KURED_NOTIFY_URL"
      valueFrom = {
        secretKeyRef = {
          name = "kured-notify"
          key  = "notify_url"
        }
      }
    }]
    reboot_days  = "mon,tue,wed,thu,fri,sat,sun"
    window_end   = "06:00"
    window_start = "22:00"
    service = {
      annotations = {
        "prometheus.io/scrape" = "true"
        "prometheus.io/port"   = "8080"
        "prometheus.io/path"   = "/metrics"
      }
    }
    # No toleration for node-role.viktorbarzin.me/opportunistic, on purpose:
    # kured must not drain or reboot an Opportunistic worker (see the header).
    # reboot-self-heal Phase 2: the kured chart REPLACES its default
    # control-plane/master tolerations when `tolerations` is set, so both are
    # re-listed here (replicating the chart default exactly) alongside the GPU
    # toleration — kured must still reboot the control-plane AND keep a pod on
    # the GPU-tainted k8s-node1.
    # FREEZE: merged with the chart default so the DaemonSet matches no node
    # while var.frozen is true. Setting nodeSelector at all REPLACES the chart
    # default, so kubernetes.io/os must be restated here.
    nodeSelector = merge({ "kubernetes.io/os" = "linux" }, local.freeze_node_selector)

    tolerations = [
      { key = "node-role.kubernetes.io/control-plane", effect = "NoSchedule" },
      { key = "node-role.kubernetes.io/master", effect = "NoSchedule" },
      { key = "nvidia.com/gpu", operator = "Exists", effect = "NoSchedule" },
    ]
  })]
}

# Synced from Vault secret/kured by ESO. Terraform waits for the sync before
# the Helm release, because kured pods cannot start without the Secret.
resource "kubernetes_manifest" "notify_external_secret" {
  manifest = {
    apiVersion = "external-secrets.io/v1"
    kind       = "ExternalSecret"
    metadata = {
      name      = "kured-notify"
      namespace = kubernetes_namespace.kured.metadata[0].name
    }
    spec = {
      refreshInterval = "1h"
      secretStoreRef = {
        name = "vault-kv"
        kind = "ClusterSecretStore"
      }
      target = {
        name = "kured-notify"
      }
      data = [{
        secretKey = "notify_url"
        remoteRef = {
          key      = "kured"
          property = "slack_kured_webhook"
        }
      }]
    }
  }
  wait {
    condition {
      type   = "Ready"
      status = "True"
    }
  }
}

# -----------------------------------------------------------------------------
# kured-sentinel-gate
#
# Runs a DaemonSet that creates /var/run/gated-reboot-required ONLY when all
# safety preconditions are met (see script). kured's rebootSentinel points at
# this file, so reboots are effectively blocked unless every check passes.
# -----------------------------------------------------------------------------

resource "kubernetes_service_account" "kured_sentinel_gate" {
  metadata {
    name      = "kured-sentinel-gate"
    namespace = kubernetes_namespace.kured.metadata[0].name
  }
  # Token IS mounted — the script uses kubectl to read nodes + pods state for
  # the safety checks. Without an authenticated token, kubectl falls back to
  # localhost:8080 (no proxy in distroless-ish image), every check silently
  # no-ops on parse-empty stdout, and the gate appears to PASS when it
  # shouldn't. Mount the token. (Found 2026-05-10 during Test 3 validation.)
  automount_service_account_token = true
}

resource "kubernetes_cluster_role" "kured_sentinel_gate" {
  metadata {
    name = "kured-sentinel-gate"
  }
  # get, watch and patch: the Cloud handoff waits for kured's label on its own
  # node and cordons it.
  rule {
    api_groups = [""]
    resources  = ["nodes"]
    verbs      = ["get", "list", "watch", "patch"]
  }
  rule {
    api_groups = [""]
    resources  = ["pods"]
    verbs      = ["list"]
  }
  # The Cloud handoff reads Deployments and rollout-restarts the one-pod ones
  # in namespace cloud and p-*. RBAC cannot name a namespace pattern or a
  # field, so ValidatingAdmissionPolicy kured-sentinel-gate-scope
  # (gate_admission.tf) admits only a rollout restart there, and only a
  # cordon and the drain label on the gate's own Node.
  rule {
    api_groups = ["apps"]
    resources  = ["deployments"]
    verbs      = ["get", "list", "watch", "patch"]
  }
}

# The admission policy that narrows the two rules above to the handoff
# (gate_admission.tf).
resource "kubernetes_manifest" "kured_gate_admission_policy" {
  manifest = local.kured_gate_admission.policy
}

resource "kubernetes_manifest" "kured_gate_admission_binding" {
  manifest   = local.kured_gate_admission.binding
  depends_on = [kubernetes_manifest.kured_gate_admission_policy]
}

# The Cloud drain handoff, shared with stacks/k8s-version-upgrade.
resource "kubernetes_config_map" "kured_sentinel_gate_scripts" {
  metadata {
    name      = "kured-sentinel-gate-scripts"
    namespace = kubernetes_namespace.kured.metadata[0].name
  }
  data = {
    "cloud-drain-handoff.sh" = file("${path.module}/../../scripts/cloud-drain-handoff.sh")
  }
}

resource "kubernetes_cluster_role_binding" "kured_sentinel_gate" {
  metadata {
    name = "kured-sentinel-gate"
  }
  role_ref {
    api_group = "rbac.authorization.k8s.io"
    kind      = "ClusterRole"
    name      = kubernetes_cluster_role.kured_sentinel_gate.metadata[0].name
  }
  subject {
    kind      = "ServiceAccount"
    name      = kubernetes_service_account.kured_sentinel_gate.metadata[0].name
    namespace = kubernetes_namespace.kured.metadata[0].name
  }
}

resource "kubernetes_daemon_set_v1" "kured_sentinel_gate" {
  metadata {
    name      = "kured-sentinel-gate"
    namespace = kubernetes_namespace.kured.metadata[0].name
    labels = {
      app  = "kured-sentinel-gate"
      tier = local.tiers.cluster
    }
  }
  spec {
    selector {
      match_labels = {
        app = "kured-sentinel-gate"
      }
    }
    template {
      metadata {
        labels = {
          app = "kured-sentinel-gate"
        }
      }
      spec {
        # FREEZE: the gate is what creates /sentinel/gated-reboot-required, so
        # stopping it is the second half of holding kured. Empty when not frozen.
        node_selector                   = local.freeze_node_selector
        service_account_name            = kubernetes_service_account.kured_sentinel_gate.metadata[0].name
        automount_service_account_token = true
        enable_service_links            = false
        # bitnami/kubectl:latest runs as uid=1001 by default. The hostPath
        # /var/run is root:root 0755 → final `touch
        # /host/var-run/gated-reboot-required` fails with EACCES, so the gate
        # never opens. Run as root inside the container (the hostPath mount
        # already gives privileged-equivalent access; this just lets us write
        # to /var/run). Found 2026-05-10 during Test 3 validation.
        security_context {
          run_as_user = 0
        }
        toleration {
          effect   = "NoSchedule"
          key      = "node-role.kubernetes.io/control-plane"
          operator = "Equal"
        }
        toleration {
          effect   = "NoSchedule"
          key      = "node-role.kubernetes.io/master"
          operator = "Equal"
        }
        # reboot-self-heal Phase 2: keep the sentinel gate on the GPU-tainted
        # k8s-node1 when nvidia.com/gpu flips to NoSchedule.
        toleration {
          key      = "nvidia.com/gpu"
          operator = "Exists"
          effect   = "NoSchedule"
        }
        container {
          name = "gate"
          # bitnami/kubectl publishes only :latest on Docker Hub (versioned
          # tags moved to bitnamilegacy in 2025), so this is latest@digest:
          # the digest makes the pin immutable and Renovate bumps it.
          image             = "bitnami/kubectl:latest@sha256:ae71f848f057a71029d092e98548cabf7cd17b11da0adad0a8f4145a9c87c830"
          image_pull_policy = "IfNotPresent"
          command = [
            "/bin/bash",
            "-c",
            <<-EOT
              # Self-restart guard (added 2026-05-31): a node stuck in
              # pending-reboot keeps THIS pod on the kubectl-heavy hot path
              # every cycle. The long-lived bash loop slowly leaks (repeated
              # kubectl forks + the Check-4 process substitution) until the
              # cgroup OOM-kills child processes — PID 1 bash survives, so the
              # pod never restarts, it just racks up silent oom_events
              # (149 in 7d / accelerating on k8s-master, 2026-05-30..31).
              # Exit 0 every MAX_ITER cycles so kubelet restarts the pod fresh
              # and memory can never accumulate. Tightened 72->12 (~6h->~1h) on
              # 2026-07-27: on a node stuck pending-reboot for days (the kured
              # deadlock, also fixed via the KernelOOMKiller ignore above) the
              # leak still crossed the 256Mi ceiling within 6h and OOM-killed
              # ~139 child kubectls/6h. A ~1h reset keeps the cgroup well under
              # the (now 512Mi) limit so it never OOMs.
              ITER=0
              MAX_ITER=12
              while true; do
                ITER=$((ITER + 1))
                if [ "$ITER" -gt "$MAX_ITER" ]; then
                  echo "  Iteration cap ($MAX_ITER) reached — exit 0 for a clean restart (leak guard)"
                  exit 0
                fi
                echo "[$(date)] Checking reboot gate conditions... (iter $ITER/$MAX_ITER)"

                # Check 1: Does the host need a reboot?
                if [ ! -f /host/var-run/reboot-required ]; then
                  echo "  No reboot required on this host"
                  rm -f /host/var-run/gated-reboot-required
                  sleep 300
                  continue
                fi
                echo "  Host has /var/run/reboot-required"

                # Opportunistic workers (ADR-0045) are offline for days by
                # design, so Checks 2-4 leave them out by their label. If this
                # lookup fails, OPP_FS stays empty and the checks include every
                # node, which fails closed.
                OPP_FS=$(kubectl get nodes -l node-role.viktorbarzin.me/opportunistic -o jsonpath='{range .items[*]}spec.nodeName!={.metadata.name},{end}' 2>/dev/null || true)
                CALICO_SEL=()
                if [ -n "$OPP_FS" ]; then
                  CALICO_SEL=(--field-selector "$${OPP_FS%,}")
                fi

                # Check 2: Are ALL nodes Ready (Opportunistic workers excepted)?
                NOT_READY=$(kubectl get nodes -l '!node-role.viktorbarzin.me/opportunistic' --no-headers | grep -v ' Ready' | wc -l | tr -d ' ')
                if [ "$NOT_READY" -gt 0 ]; then
                  echo "  BLOCKED: $NOT_READY node(s) not Ready"
                  rm -f /host/var-run/gated-reboot-required
                  sleep 300
                  continue
                fi
                echo "  All nodes Ready"

                # Check 3: Are ALL calico-node pods Running (except those on
                # Opportunistic workers)?
                CALICO_NOT_RUNNING=$(kubectl get pods -n calico-system -l k8s-app=calico-node "$${CALICO_SEL[@]}" --no-headers 2>/dev/null | grep -v Running | wc -l | tr -d ' ')
                if [ "$CALICO_NOT_RUNNING" -gt 0 ]; then
                  echo "  BLOCKED: $CALICO_NOT_RUNNING calico-node pod(s) not Running"
                  rm -f /host/var-run/gated-reboot-required
                  sleep 300
                  continue
                fi
                echo "  All calico-node pods Running"

                # Check 4: No node rebooted in last 24 hours (soak window).
                # Stretched from 30m to 24h on 2026-05-10 so the de-facto canary
                # node has a full day of observation before the next node drains.
                RECENT_REBOOT=0
                while IFS= read -r transition_time; do
                  if [ -n "$transition_time" ]; then
                    transition_epoch=$(date -d "$transition_time" +%s 2>/dev/null || date -j -f "%Y-%m-%dT%H:%M:%SZ" "$transition_time" +%s 2>/dev/null)
                    now_epoch=$(date +%s)
                    diff=$(( now_epoch - transition_epoch ))
                    if [ "$diff" -lt 86400 ]; then
                      RECENT_REBOOT=1
                      break
                    fi
                  fi
                done < <(kubectl get nodes -l '!node-role.viktorbarzin.me/opportunistic' -o jsonpath='{range .items[*]}{range .status.conditions[?(@.type=="Ready")]}{.lastTransitionTime}{"\n"}{end}{end}')

                if [ "$RECENT_REBOOT" -eq 1 ]; then
                  echo "  BLOCKED: A node transitioned Ready within the last 24 hours (soak window)"
                  rm -f /host/var-run/gated-reboot-required
                  sleep 300
                  continue
                fi
                echo "  No recent node reboots (24h soak window clear)"

                # All checks passed — create gated sentinel
                echo "  ALL CHECKS PASSED — creating /var/run/gated-reboot-required"
                touch /host/var-run/gated-reboot-required

                # Instead of sleeping 300 s, wait up to 300 s for kured's
                # pre-drain label on this node (one kubectl, no polling).
                # kured then waits its drainDelay before it drains, and this
                # hands the one-pod Cloud Deployments off the node first.
                # Any other failure (API unreachable, RBAC) is logged, and the
                # rest of the 300 s is slept out so the loop keeps its pace.
                WAIT_START=$(date +%s)
                if WAIT_ERR=$(kubectl wait "node/$NODE_NAME" --for=jsonpath='{.metadata.labels.cloud\.viktorbarzin\.me/drain}'=pending --timeout=300s 2>&1 >/dev/null); then
                  echo "  kured is about to drain $NODE_NAME: Cloud handoff"
                  kubectl cordon "$NODE_NAME"
                  # shellcheck source=/dev/null
                  . /scripts/cloud-drain-handoff.sh
                  cloud_drain_handoff "$NODE_NAME" 240 || echo "  Cloud handoff incomplete; kured drains anyway"
                  kubectl label node "$NODE_NAME" cloud.viktorbarzin.me/drain=handed-off --overwrite
                else
                  case "$WAIT_ERR" in
                    *"timed out waiting"*) ;;
                    *)
                      echo "  waiting for kured's drain label failed: $WAIT_ERR"
                      REST=$((300 - ($(date +%s) - WAIT_START)))
                      if [ "$REST" -gt 0 ]; then sleep "$REST"; fi
                      ;;
                  esac
                fi
              done
            EOT
          ]
          resources {
            requests = {
              cpu    = "10m"
              memory = "32Mi"
            }
            # 64Mi was too tight for the kubectl-heavy hot path (each kubectl
            # fork is a ~90Mi RSS Go binary). Raised 64->256Mi 2026-05-31, then
            # 256->512Mi 2026-07-27 after the gate STILL OOM-killed ~139 child
            # kubectls/6h on a node stuck pending-reboot for days. 512Mi headroom
            # + the tightened MAX_ITER=12 (~1h reset, loop above) together keep
            # the cgroup from ever filling to the OOM ceiling.
            limits = {
              memory = "512Mi"
            }
          }
          # The node this pod runs on, for the Cloud handoff.
          env {
            name = "NODE_NAME"
            value_from {
              field_ref {
                field_path = "spec.nodeName"
              }
            }
          }
          volume_mount {
            name       = "var-run"
            mount_path = "/host/var-run"
          }
          volume_mount {
            name       = "scripts"
            mount_path = "/scripts"
            read_only  = true
          }
        }
        volume {
          name = "var-run"
          host_path {
            path = "/var/run"
            type = "Directory"
          }
        }
        volume {
          name = "scripts"
          config_map {
            name = kubernetes_config_map.kured_sentinel_gate_scripts.metadata[0].name
          }
        }
      }
    }
  }
  lifecycle {
    ignore_changes = [
      spec[0].template[0].spec[0].dns_config, # KYVERNO_LIFECYCLE_V1
      metadata[0].annotations["kubernetes.io/change-cause"],
      metadata[0].annotations["deployment.kubernetes.io/revision"],
    ]
  }
}

# CI retrigger 2026-05-16T13:42:57+00:00 — bulk enrollment apply (pipeline #689 killed)
# CI retrigger v2 2026-05-16T13:46:35+00:00
