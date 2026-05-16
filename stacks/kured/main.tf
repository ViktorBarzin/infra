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
  version          = "5.11.0"

  values = [yamlencode({
    configuration = {
      period         = "1h0m0s"
      timeZone       = "Europe/London"
      startTime      = "02:00"
      endTime        = "06:00"
      # All 7 days — operator decision 2026-05-16. The Mon–Fri restriction
      # was a 2026-03-16-era guardrail (overlapping with weekend on-call
      # response). Today the rest of the safety net (halt-on-alert,
      # sentinel-gate Check 4 = 24h soak, single-concurrency, the
      # K8sUpgradeStalled alert) is strong enough to operate any day; the
      # weekday-only schedule was just slowing the backlog down.
      rebootDays     = ["mo", "tu", "we", "th", "fr", "sa", "su"]
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
      notifyUrl      = data.vault_kv_secret_v2.secrets.data["slack_kured_webhook"]
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
      # Halt rolling reboots when ANY firing Prometheus alert is not in the
      # ignore-list. The ignore-list excludes self-referential / always-firing
      # alerts that would otherwise deadlock kured. alertFilterMatchOnly stays
      # false (default) so the regex marks alerts to IGNORE — every other
      # firing alert blocks. See "Upgrade Gates" group in monitoring stack.
      prometheusUrl        = "http://prometheus-server.monitoring.svc.cluster.local:80"
      alertFilterRegexp    = "^(Watchdog|RebootRequired|KuredNodeWasNotDrained|InfoInhibitor)$"
      alertFiringOnly      = true
      alertFilterMatchOnly = false
    }
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
  })]
}

data "vault_kv_secret_v2" "secrets" {
  mount = "secret"
  name  = "kured"
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
  rule {
    api_groups = [""]
    resources  = ["nodes"]
    verbs      = ["list"]
  }
  rule {
    api_groups = [""]
    resources  = ["pods"]
    verbs      = ["list"]
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
        container {
          name              = "gate"
          image             = "bitnami/kubectl:latest"
          image_pull_policy = "Always"
          command = [
            "/bin/bash",
            "-c",
            <<-EOT
              while true; do
                echo "[$(date)] Checking reboot gate conditions..."

                # Check 1: Does the host need a reboot?
                if [ ! -f /host/var-run/reboot-required ]; then
                  echo "  No reboot required on this host"
                  rm -f /host/var-run/gated-reboot-required
                  sleep 300
                  continue
                fi
                echo "  Host has /var/run/reboot-required"

                # Check 2: Are ALL nodes Ready?
                NOT_READY=$(kubectl get nodes --no-headers | grep -v ' Ready' | wc -l | tr -d ' ')
                if [ "$NOT_READY" -gt 0 ]; then
                  echo "  BLOCKED: $NOT_READY node(s) not Ready"
                  rm -f /host/var-run/gated-reboot-required
                  sleep 300
                  continue
                fi
                echo "  All nodes Ready"

                # Check 3: Are ALL calico-node pods Running?
                CALICO_NOT_RUNNING=$(kubectl get pods -n calico-system -l k8s-app=calico-node --no-headers 2>/dev/null | grep -v Running | wc -l | tr -d ' ')
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
                done < <(kubectl get nodes -o jsonpath='{range .items[*]}{range .status.conditions[?(@.type=="Ready")]}{.lastTransitionTime}{"\n"}{end}{end}')

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
                sleep 300
              done
            EOT
          ]
          resources {
            requests = {
              cpu    = "10m"
              memory = "32Mi"
            }
            limits = {
              memory = "64Mi"
            }
          }
          volume_mount {
            name       = "var-run"
            mount_path = "/host/var-run"
          }
        }
        volume {
          name = "var-run"
          host_path {
            path = "/var/run"
            type = "Directory"
          }
        }
      }
    }
  }
  lifecycle {
    # KYVERNO_LIFECYCLE_V1: Kyverno admission webhook mutates dns_config with ndots=2
    ignore_changes = [spec[0].template[0].spec[0].dns_config]
  }
}
