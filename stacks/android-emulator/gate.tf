# On-demand lifecycle: the emulator scales to ZERO when idle and wakes on
# visit. The gate (tiny stdlib-python HTTP server) owns `/` on both emulator
# hostnames — it scales the deployment up and hands the browser to noVNC once
# ready; agents use GET /wake + /status. The idle CronJob scales back to zero
# after ~1h with no adb/VNC connections. Decision: Viktor 2026-06-12 —
# dev-only usage, and an always-on GPU emulator would permanently hold T4
# VRAM that the LLM jobs need.

resource "kubernetes_service_account" "gate" {
  metadata {
    name      = "android-emulator-gate"
    namespace = kubernetes_namespace.android-emulator.metadata[0].name
  }
}

resource "kubernetes_role" "gate" {
  metadata {
    name      = "android-emulator-gate"
    namespace = kubernetes_namespace.android-emulator.metadata[0].name
  }
  rule {
    api_groups     = ["apps"]
    resources      = ["deployments"]
    resource_names = ["android-emulator"]
    verbs          = ["get", "patch"]
  }
  rule {
    api_groups = [""]
    resources  = ["pods"]
    verbs      = ["get", "list"]
  }
  rule {
    api_groups = [""]
    resources  = ["pods/exec"]
    verbs      = ["create"]
  }
}

resource "kubernetes_role_binding" "gate" {
  metadata {
    name      = "android-emulator-gate"
    namespace = kubernetes_namespace.android-emulator.metadata[0].name
  }
  role_ref {
    api_group = "rbac.authorization.k8s.io"
    kind      = "Role"
    name      = kubernetes_role.gate.metadata[0].name
  }
  subject {
    kind      = "ServiceAccount"
    name      = kubernetes_service_account.gate.metadata[0].name
    namespace = kubernetes_namespace.android-emulator.metadata[0].name
  }
}

resource "kubernetes_config_map" "gate" {
  metadata {
    name      = "android-emulator-gate"
    namespace = kubernetes_namespace.android-emulator.metadata[0].name
  }
  data = {
    "gate.py" = file("${path.module}/gate.py")
  }
}

resource "kubernetes_deployment" "gate" {
  metadata {
    name      = "android-emulator-gate"
    namespace = kubernetes_namespace.android-emulator.metadata[0].name
    labels = {
      app = "android-emulator-gate"
    }
  }
  spec {
    replicas = 1
    selector {
      match_labels = { app = "android-emulator-gate" }
    }
    template {
      metadata {
        labels = { app = "android-emulator-gate" }
        annotations = {
          "checksum/gate" = sha1(file("${path.module}/gate.py"))
        }
      }
      spec {
        service_account_name = kubernetes_service_account.gate.metadata[0].name
        container {
          name    = "gate"
          image   = "python:3.12-alpine"
          command = ["python", "/app/gate.py"]
          env {
            name  = "NAMESPACE"
            value = kubernetes_namespace.android-emulator.metadata[0].name
          }
          env {
            name  = "DEPLOYMENT"
            value = "android-emulator"
          }
          port {
            container_port = 8080
          }
          volume_mount {
            name       = "app"
            mount_path = "/app"
          }
          resources {
            requests = {
              cpu    = "10m"
              memory = "64Mi"
            }
            limits = {
              memory = "64Mi"
            }
          }
          readiness_probe {
            http_get {
              path = "/healthz"
              port = 8080
            }
            period_seconds = 10
          }
        }
        volume {
          name = "app"
          config_map {
            name = kubernetes_config_map.gate.metadata[0].name
          }
        }
      }
    }
  }
  lifecycle {
    ignore_changes = [spec[0].template[0].spec[0].dns_config] # KYVERNO_LIFECYCLE_V1
  }
}

resource "kubernetes_service" "gate" {
  metadata {
    name      = "android-emulator-gate"
    namespace = kubernetes_namespace.android-emulator.metadata[0].name
  }
  spec {
    selector = {
      app = "android-emulator-gate"
    }
    port {
      name        = "http"
      port        = 80
      target_port = 8080
    }
  }
}

# Sleep side: every 15 min, ask the emulator how long since it was actually
# USED — dumpsys power's last user-activity time (taps/keys/app-launches,
# including noVNC clicks) vs guest uptime. No activity for 6h → scale the
# deployment to zero. This deliberately IGNORES open adb/noVNC connections:
# a forgotten adb transport (connect with no disconnect) stays ESTABLISHED
# forever, so the old connection-count check kept resetting and the emulator
# never slept (up 6+ days while idle ~5). Reads activity via `kubectl exec`
# (the SA has pods/exec) and scales down with a direct replicas patch on the
# named deployment — the SAME path the wake gate scales UP — so it needs only
# the existing `deployments` patch grant, NOT `deployments/scale` (which the
# SA lacks; the old `kubectl scale` here failed Forbidden). Stateless: no
# idle-counter annotation. Fail-safe: any read error → do NOT sleep.
resource "kubernetes_cron_job_v1" "idle_sleeper" {
  metadata {
    name      = "android-emulator-idle-sleeper"
    namespace = kubernetes_namespace.android-emulator.metadata[0].name
  }
  spec {
    schedule                      = "*/15 * * * *"
    concurrency_policy            = "Forbid"
    successful_jobs_history_limit = 1
    failed_jobs_history_limit     = 2
    job_template {
      metadata {}
      spec {
        backoff_limit              = 0
        ttl_seconds_after_finished = 3600
        template {
          metadata {}
          spec {
            service_account_name = kubernetes_service_account.gate.metadata[0].name
            restart_policy       = "Never"
            container {
              name    = "sleeper"
              image   = "bitnami/kubectl:latest"
              command = ["/bin/bash", "-c"]
              args = [<<-EOT
                set -euo pipefail
                NS=android-emulator
                DEPLOY=android-emulator
                IDLE_LIMIT_SECONDS=21600   # 6h with no user activity -> sleep
                spec=$(kubectl -n $NS get deploy $DEPLOY -o jsonpath='{.spec.replicas}')
                [ "$spec" = "0" ] && { echo "already asleep"; exit 0; }
                pod=$(kubectl -n $NS get pods -l app=$DEPLOY --field-selector=status.phase=Running -o name | head -1)
                [ -z "$pod" ] && { echo "no running pod (booting?) — not sleeping"; exit 0; }
                pod=$${pod#pod/}
                # How long since the emulator was actually used? Compare the
                # last user-activity time from dumpsys power (taps/keys/app
                # launches, incl. noVNC clicks) against current guest uptime,
                # both in ms on the guest uptime clock. Fail-safe: if adb is
                # not answering yet (cold boot) these come back empty and we
                # must NOT sleep.
                uptime_ms=$(kubectl -n $NS exec $pod -- sh -c 'adb shell cat /proc/uptime' 2>/dev/null | awk '{printf "%d", $1*1000}')
                last_ms=$(kubectl -n $NS exec $pod -- sh -c 'adb shell dumpsys power' 2>/dev/null | awk -F= '/mLastUserActivityTime\(excludingAttention\)/{gsub(/[^0-9]/,"",$2); print $2; exit}')
                if [ -z "$uptime_ms" ] || [ -z "$last_ms" ]; then
                  echo "could not read activity (emulator booting / adb not ready) — not sleeping"
                  exit 0
                fi
                idle_s=$(( (uptime_ms - last_ms) / 1000 ))
                echo "idle for $idle_s s (limit $IDLE_LIMIT_SECONDS s / 6h)"
                if [ "$idle_s" -ge "$IDLE_LIMIT_SECONDS" ]; then
                  echo "idle >= 6h with no user activity — scaling to zero"
                  kubectl -n $NS patch deploy $DEPLOY --type=merge -p '{"spec":{"replicas":0}}'
                else
                  echo "used within 6h — staying up"
                fi
              EOT
              ]
              resources {
                requests = {
                  cpu    = "10m"
                  memory = "64Mi"
                }
                limits = {
                  memory = "128Mi"
                }
              }
            }
          }
        }
      }
    }
  }
  lifecycle {
    ignore_changes = [spec[0].job_template[0].spec[0].template[0].spec[0].dns_config] # KYVERNO_LIFECYCLE_V1
  }
}
