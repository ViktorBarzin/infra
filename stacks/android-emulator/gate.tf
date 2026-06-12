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

# Sleep side: every 15 min, look at established TCP connections to the
# emulator's adb (5555) and noVNC (6080) ports from OUTSIDE the pod
# (remote != 127.0.0.1 — the in-container adb server holds a permanent
# loopback connection to adbd that must not count as activity). Four
# consecutive idle checks (~1h) scale the deployment to zero.
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
                NS=android-emulator DEPLOY=android-emulator ANN=emulator.viktorbarzin.me/idle-checks
                spec=$(kubectl -n $NS get deploy $DEPLOY -o jsonpath='{.spec.replicas}')
                [ "$spec" = "0" ] && { echo "already asleep"; exit 0; }
                pod=$(kubectl -n $NS get pods -l app=$DEPLOY --field-selector=status.phase=Running -o name | head -1)
                [ -z "$pod" ] && { echo "no running pod (booting?) — not counting"; exit 0; }
                # /proc/net/tcp: count ESTABLISHED (st=01) conns with local port
                # 5555 (0x15B3) or 6080 (0x17C0) whose remote is not loopback.
                est=$(kubectl -n $NS exec $${pod#pod/} -- cat /proc/net/tcp | awk '
                  $4 == "01" {
                    split($2, l, ":"); split($3, r, ":")
                    if ((l[2] == "15B3" || l[2] == "17C0") && r[1] != "0100007F") n++
                  } END { print n+0 }')
                if [ "$est" -gt 0 ]; then
                  echo "$est active connection(s) — resetting idle counter"
                  kubectl -n $NS annotate deploy $DEPLOY $ANN=0 --overwrite
                  exit 0
                fi
                n=$(kubectl -n $NS get deploy $DEPLOY -o jsonpath="{.metadata.annotations['emulator\.viktorbarzin\.me/idle-checks']}")
                n=$(( $${n:-0} + 1 ))
                if [ "$n" -ge 4 ]; then
                  echo "idle for $n checks (~1h) — scaling to zero"
                  kubectl -n $NS scale deploy $DEPLOY --replicas=0
                  kubectl -n $NS annotate deploy $DEPLOY $ANN=0 --overwrite
                else
                  echo "idle check $n/4"
                  kubectl -n $NS annotate deploy $DEPLOY $ANN=$n --overwrite
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
