# On-demand lifecycle: the emulator scales to ZERO when idle and wakes on
# visit, and also sleeps when a labelled pod waits for its GPU seat (below). The gate (tiny stdlib-python HTTP server) owns `/` on both emulator
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

# The f1-stream deploy puts the emulator to sleep before it rolls the
# Transcoder, whose surge pod needs the 800 gpumem the emulator holds on
# k8s-node1 (Viktor, 2026-10-17; f1-stream .woodpecker/deploy.yml, infra
# stacks/f1-stream/main.tf GPU seat note). It scales down the same way the idle
# sleeper does, a replicas patch on the named Deployment, and waits for the pod
# to leave. It does not wake the emulator again; the gate does that on the next
# visit.
#
# Woodpecker runs pipeline steps as the `default` ServiceAccount in namespace
# woodpecker. That account is cluster-admin today (stacks/woodpecker,
# woodpecker-default), so this Role grants nothing new yet. It names what the
# deploy needs here, so the deploy keeps working if that binding is narrowed.
resource "kubernetes_role" "deploy_yield" {
  metadata {
    name      = "f1-stream-deploy-yield"
    namespace = kubernetes_namespace.android-emulator.metadata[0].name
  }
  rule {
    api_groups     = ["apps"]
    resources      = ["deployments"]
    resource_names = ["android-emulator"]
    verbs          = ["get", "patch"]
  }
  # `kubectl get pods -l app=android-emulator` lists, and list cannot be
  # limited by name.
  rule {
    api_groups = [""]
    resources  = ["pods"]
    verbs      = ["list"]
  }
}

resource "kubernetes_role_binding" "deploy_yield" {
  metadata {
    name      = "f1-stream-deploy-yield"
    namespace = kubernetes_namespace.android-emulator.metadata[0].name
  }
  role_ref {
    api_group = "rbac.authorization.k8s.io"
    kind      = "Role"
    name      = kubernetes_role.deploy_yield.metadata[0].name
  }
  subject {
    kind      = "ServiceAccount"
    name      = "default"
    namespace = "woodpecker"
  }
}

# The gate also watches for a pod that waits Pending for the GPU seat the
# emulator holds, and puts the emulator to sleep when it finds one (gate.py,
# yield_loop). The pods it watches carry the label
# android-emulator-yields-to=gpu-seat; today that is the f1-stream Transcoder,
# whose surge pod needs a second 1850 gpumem on k8s-node1, and the f1-stream
# Worker, whose replacement pod needs its 2000 back (infra
# stacks/f1-stream/main.tf GPU seat note). A pod that still waits after
# YIELD_LIMIT_SECONDS stops holding the emulator asleep. The deploy pipeline above sleeps the
# emulator before its own roll, but Reloader and Terraform roll the Transcoder
# too, and only this watcher sees those. Reading pods there needs list on pods
# in that namespace, and nothing more.
resource "kubernetes_role" "gate_yield_watch" {
  metadata {
    name      = "android-emulator-yield-watch"
    namespace = "f1-stream"
  }
  rule {
    api_groups = [""]
    resources  = ["pods"]
    verbs      = ["list"]
  }
}

resource "kubernetes_role_binding" "gate_yield_watch" {
  metadata {
    name      = "android-emulator-yield-watch"
    namespace = "f1-stream"
  }
  role_ref {
    api_group = "rbac.authorization.k8s.io"
    kind      = "Role"
    name      = kubernetes_role.gate_yield_watch.metadata[0].name
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
          image   = "library/python:3.15.1-alpine"
          command = ["python", "/app/gate.py"]
          env {
            name  = "NAMESPACE"
            value = kubernetes_namespace.android-emulator.metadata[0].name
          }
          env {
            name  = "DEPLOYMENT"
            value = "android-emulator"
          }
          # Pods the emulator gives its GPU seat to (see the yield-watch Role).
          env {
            name  = "YIELD_NAMESPACE"
            value = kubernetes_role.gate_yield_watch.metadata[0].namespace
          }
          env {
            name  = "YIELD_SELECTOR"
            value = "android-emulator-yields-to=gpu-seat"
          }
          # One pod keeps the emulator asleep for at most 15 min; past that it
          # is short of more than the emulator's 800 gpumem (Viktor,
          # 2026-10-18).
          env {
            name  = "YIELD_LIMIT_SECONDS"
            value = "900"
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
          # Readiness only asks whether the server answers (/readyz). The
          # gate runs one replica, so putting the watcher state here would
          # empty the Service and stop human visits and agent /wake calls
          # for up to a minute before the liveness restart below.
          readiness_probe {
            http_get {
              path = "/readyz"
              port = 8080
            }
            period_seconds = 10
          }
          # /healthz fails when the yield watcher thread has died or stopped
          # finishing passes; restarting the gate starts a new one.
          liveness_probe {
            http_get {
              path = "/healthz"
              port = 8080
            }
            period_seconds    = 10
            failure_threshold = 6
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
    ignore_changes = [
      spec[0].template[0].spec[0].dns_config, # KYVERNO_LIFECYCLE_V1
      metadata[0].labels["tier"],             # stamped by Kyverno sync-tier-label-from-namespace
    ]
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
                set -eu
                NS=android-emulator
                DEPLOY=android-emulator
                IDLE_LIMIT_SECONDS=21600   # 6h with no user activity -> sleep
                spec=$(kubectl -n $NS get deploy $DEPLOY -o jsonpath='{.spec.replicas}')
                [ "$spec" = "0" ] && { echo "already asleep"; exit 0; }
                pod=$(kubectl -n $NS get pods -l app=$DEPLOY --field-selector=status.phase=Running -o jsonpath='{.items[0].metadata.name}')
                [ -z "$pod" ] && { echo "no running pod (booting?) — not sleeping"; exit 0; }
                # How long since the emulator was actually used? Compare the last
                # user-activity time from dumpsys power (taps/keys/app-launches,
                # incl. noVNC clicks) with current guest uptime, both in ms on
                # the guest uptime clock. Capture first, then parse: NO pipefail
                # and no early `exit` in awk, so a streaming `dumpsys` can't
                # SIGPIPE the exec and trip set -e (that bug made every run die
                # 141 with no output). Fail-safe: a still-booting emulator (adb
                # not ready) yields empty values -> do NOT sleep.
                uptime_raw=$(kubectl -n $NS exec $pod -- adb shell cat /proc/uptime 2>/dev/null || true)
                dump=$(kubectl -n $NS exec $pod -- adb shell dumpsys power 2>/dev/null || true)
                uptime_ms=$(printf '%s' "$uptime_raw" | awk '{printf "%d", $1*1000}')
                last_ms=$(printf '%s' "$dump" | awk -F= '/mLastUserActivityTime\(excludingAttention\)/{v=$2} END{gsub(/[^0-9]/,"",v); print v}')
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
