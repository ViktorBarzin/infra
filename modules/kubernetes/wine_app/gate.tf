# On-demand lifecycle, the android-emulator pattern (stacks/android-emulator,
# gate.tf). Sablier cannot serve here: it does not refresh its session on
# WebSocket traffic (ADR-0022), and a noVNC session is one long WebSocket.
#
# Wake: the gate owns `/` and scales the Deployment to 1 on visit.
# Sleep: the idle sleeper scales it to 0 after idle_no_viewer_seconds with no
# noVNC viewer, or idle_no_input_seconds with no keyboard or mouse input.

resource "kubernetes_service_account" "gate" {
  metadata {
    name      = "${var.name}-gate"
    namespace = var.namespace
  }
}

resource "kubernetes_role" "gate" {
  metadata {
    name      = "${var.name}-gate"
    namespace = var.namespace
  }
  rule {
    api_groups     = ["apps"]
    resources      = ["deployments"]
    resource_names = [var.name]
    verbs          = ["get", "patch"]
  }
  rule {
    api_groups = [""]
    resources  = ["pods"]
    verbs      = ["get", "list"]
  }
  # The sleeper reads the pod's idle signals with `kubectl exec ... cat`.
  rule {
    api_groups = [""]
    resources  = ["pods/exec"]
    verbs      = ["create"]
  }
}

resource "kubernetes_role_binding" "gate" {
  metadata {
    name      = "${var.name}-gate"
    namespace = var.namespace
  }
  role_ref {
    api_group = "rbac.authorization.k8s.io"
    kind      = "Role"
    name      = kubernetes_role.gate.metadata[0].name
  }
  subject {
    kind      = "ServiceAccount"
    name      = kubernetes_service_account.gate.metadata[0].name
    namespace = var.namespace
  }
}

resource "kubernetes_config_map" "gate" {
  metadata {
    name      = "${var.name}-gate"
    namespace = var.namespace
  }
  data = {
    "gate.py" = file("${path.module}/gate.py")
  }
}

resource "kubernetes_deployment" "gate" {
  metadata {
    name      = "${var.name}-gate"
    namespace = var.namespace
    labels    = { app = "${var.name}-gate" }
  }
  spec {
    replicas = 1
    selector {
      match_labels = { app = "${var.name}-gate" }
    }
    template {
      metadata {
        labels = { app = "${var.name}-gate" }
        annotations = {
          "checksum/gate" = sha1(file("${path.module}/gate.py"))
        }
      }
      spec {
        service_account_name = kubernetes_service_account.gate.metadata[0].name
        container {
          name    = "gate"
          image   = "library/python:3.15.0-alpine"
          command = ["python", "/app/gate.py"]
          env {
            name  = "NAMESPACE"
            value = var.namespace
          }
          env {
            name  = "DEPLOYMENT"
            value = kubernetes_deployment.app.metadata[0].name
          }
          env {
            name  = "APP_TITLE"
            value = var.title
          }
          port {
            container_port = 8080
          }
          volume_mount {
            name       = "gate"
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
          name = "gate"
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
    name      = "${var.name}-gate"
    namespace = var.namespace
  }
  spec {
    selector = { app = "${var.name}-gate" }
    port {
      name        = "http"
      port        = 80
      target_port = 8080
    }
  }
}

# Sleep side, every 5 minutes. The image's entrypoint keeps two signals in the
# pod: /tmp/last-viewer (touched while Xvnc has a client; noVNC's websockify
# is that client, so this counts browser sessions, not Traefik keep-alives or
# probes) and /tmp/input-idle-ms (X input idle time from xprintidle).
# Fail-safe: a pod that is not Running and Ready (booting, installing) is left
# alone, and so is any read error. The WineAppStuckAwake alert covers a pod
# that never sleeps.
resource "kubernetes_cron_job_v1" "idle_sleeper" {
  metadata {
    name      = "${var.name}-idle-sleeper"
    namespace = var.namespace
  }
  spec {
    schedule                      = "*/5 * * * *"
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
              image   = "bitnami/kubectl:latest@sha256:eaf442416e6f6b37ea76cc03dbdacc1d85f4c061670df7974dd1387288a11e50"
              command = ["/bin/bash", "-c"]
              args = [<<-EOT
                set -u
                NS=${var.namespace}
                DEPLOY=${var.name}
                NO_VIEWER_LIMIT=${var.idle_no_viewer_seconds}
                NO_INPUT_LIMIT=${var.idle_no_input_seconds}
                spec=$(kubectl -n $NS get deploy $DEPLOY -o jsonpath='{.spec.replicas}') || exit 0
                [ "$spec" = "0" ] && { echo "asleep"; exit 0; }
                pod=$(kubectl -n $NS get pods -l app=$DEPLOY --field-selector=status.phase=Running -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)
                [ -z "$pod" ] && { echo "no running pod (starting?), leaving it"; exit 0; }
                ready=$(kubectl -n $NS get pod $pod -o jsonpath='{.status.containerStatuses[?(@.name=="app")].ready}')
                [ "$ready" != "true" ] && { echo "pod not ready (starting or installing), leaving it"; exit 0; }
                now=$(kubectl -n $NS exec $pod -c app -- date +%s 2>/dev/null) || { echo "cannot read pod clock, leaving it"; exit 0; }
                viewer=$(kubectl -n $NS exec $pod -c app -- stat -c %Y /tmp/last-viewer 2>/dev/null) || viewer=""
                if [ -z "$viewer" ]; then
                  # The entrypoint creates it at start; if it is missing, count
                  # from the pod's start rather than staying awake forever.
                  started=$(kubectl -n $NS get pod $pod -o jsonpath='{.status.startTime}')
                  viewer=$(date -d "$started" +%s 2>/dev/null) || { echo "no viewer signal, leaving it"; exit 0; }
                fi
                input_ms=$(kubectl -n $NS exec $pod -c app -- cat /tmp/input-idle-ms 2>/dev/null) || input_ms=""
                no_viewer=$(( now - viewer ))
                echo "no viewer for $no_viewer s (limit $NO_VIEWER_LIMIT), input idle $${input_ms:-?} ms (limit $NO_INPUT_LIMIT s)"
                reason=""
                [ "$no_viewer" -ge "$NO_VIEWER_LIMIT" ] && reason="no viewer for $no_viewer s"
                case "$input_ms" in
                  ''|*[!0-9]*) ;;
                  *) [ $(( input_ms / 1000 )) -ge "$NO_INPUT_LIMIT" ] && reason="no input for $(( input_ms / 1000 )) s" ;;
                esac
                if [ -n "$reason" ]; then
                  echo "$reason: scaling to zero"
                  kubectl -n $NS patch deploy $DEPLOY --type=merge -p '{"spec":{"replicas":0}}'
                else
                  echo "in use, staying up"
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
