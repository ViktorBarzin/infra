# On-demand live camera for the London robot vacuum "Yiko" (Ecovacs DEEBOT X8
# PRO OMNI), shown in Home Assistant London.
#
# The bridge is the third-party github.com/c4talyst/ecovacs-deebot-video-proxy,
# run UNMODIFIED (Viktor, 2026-11-01: no fork to maintain). It opens the
# robot's camera over WebRTC (Ecovacs cloud + AWS Kinesis signaling) and serves
# it as RTSP. Before adoption, every file in the image was diffed against the
# audited commit 1b08ccb and the bundled MediaMTX binary against the official
# v1.21.2 release; both matched. The image is pinned by digest, so a bump means
# a fresh review: keep Renovate off this image.
#
# On demand: the Deployment sits at 0 replicas. HA London scales it to 1 when
# someone turns on input_boolean.yiko_camera, and back to 0 after 5 minutes or
# when it is turned off (ServiceAccount camera-switch below). With
# ACTIVE_ONLY_VIDEO=false the bridge streams for as long as the pod runs, so
# "pod up" is "camera on". The camera-cap CronJob scales it down if a pod has
# run for more than 15 minutes, in case HA never sends the stop.
#
# Runbook: docs/runbooks/london-yiko.md.

locals {
  name      = "ecovacs-video-proxy"
  namespace = "ecovacs-video-proxy"
  image     = "ghcr.io/c4talyst/ecovacs-deebot-video-proxy@sha256:9530c28cbc40150ca45fea056ef693f3c703cca5a2031fdf8f127f28e96cd910" # 1.1.1 = sha-1b08ccb
}

resource "kubernetes_namespace" "this" {
  metadata {
    name = local.namespace
    labels = {
      "istio-injection" : "disabled"
      tier = local.tiers.aux
    }
  }
  lifecycle {
    # KYVERNO_LIFECYCLE_V1: goldilocks-vpa-auto-mode ClusterPolicy stamps this label on every namespace
    ignore_changes = [metadata[0].labels["goldilocks.fairwinds.com/vpa-update-mode"]]
  }
}

# Vault secret/ecovacs-video-proxy holds the bridge's own env vars, key = env
# var name: ECOVACS_{USERNAME,PASSWORD,COUNTRY,DEVICE_ID,ACCESS_TOKEN,USER_ID,
# ROBOT_DID,PIN} and RTSP_{USERNAME,PASSWORD}. DEVICE_ID is this bridge's own
# Ecovacs client ID, verified once by email code (runbook).
resource "kubernetes_manifest" "external_secret" {
  field_manager {
    force_conflicts = true
  }
  manifest = {
    apiVersion = "external-secrets.io/v1"
    kind       = "ExternalSecret"
    metadata = {
      name      = "${local.name}-secrets"
      namespace = local.namespace
    }
    spec = {
      refreshInterval = "1h"
      secretStoreRef = {
        name = "vault-kv"
        kind = "ClusterSecretStore"
      }
      target = {
        name = "${local.name}-secrets"
      }
      dataFrom = [{
        extract = {
          key = local.name
        }
      }]
    }
  }
  depends_on = [kubernetes_namespace.this]
}

resource "kubernetes_deployment" "this" {
  metadata {
    name      = local.name
    namespace = kubernetes_namespace.this.metadata[0].name
    labels = {
      app  = local.name
      tier = local.tiers.aux
    }
  }
  spec {
    # Off until HA London turns the camera on. HA and the camera-cap CronJob
    # own the live replica count, so Terraform ignores it after creation.
    replicas = 0
    strategy {
      type = "Recreate" # one WebRTC session to the robot at a time
    }
    selector {
      match_labels = {
        app = local.name
      }
    }
    template {
      metadata {
        labels = {
          app = local.name
        }
      }
      spec {
        container {
          name              = local.name
          image             = local.image
          image_pull_policy = "IfNotPresent"
          env_from {
            secret_ref {
              name = "${local.name}-secrets"
            }
          }
          env {
            name  = "ACTIVE_ONLY_VIDEO"
            value = "false" # stream for as long as the pod runs
          }
          env {
            name  = "OVERLAY_ENABLED"
            value = "false"
          }
          env {
            name  = "RTSP_PATH"
            value = "live"
          }
          env {
            name  = "LOG_LEVEL"
            value = "INFO"
          }
          port {
            name           = "rtsp"
            container_port = 8554
          }
          port {
            name           = "http"
            container_port = 8080
          }
          readiness_probe {
            http_get {
              path = "/api/config-status"
              port = 8080
            }
            initial_delay_seconds = 5
            period_seconds        = 10
          }
          liveness_probe {
            http_get {
              path = "/api/config-status"
              port = 8080
            }
            initial_delay_seconds = 60
            period_seconds        = 30
            failure_threshold     = 4
          }
          resources {
            # Decodes the robot's 720p H.264 and re-encodes it with libx264
            # (ultrafast) for MediaMTX, only while the camera is on.
            requests = {
              cpu    = "200m"
              memory = "384Mi"
            }
            limits = {
              memory = "1Gi"
            }
          }
        }
      }
    }
  }
  lifecycle {
    ignore_changes = [
      spec[0].replicas,                       # set by HA London and the camera-cap CronJob
      spec[0].template[0].spec[0].dns_config, # KYVERNO_LIFECYCLE_V1
    ]
  }
}

# RTSP for HA London's generic camera, and HTTP for /snapshot.jpg, which HA
# polls to learn when video is live (503 until the first frame). Both need the
# RTSP_USERNAME/RTSP_PASSWORD credentials. LAN and tunnel only, no ingress.
resource "kubernetes_service" "this" {
  metadata {
    name      = local.name
    namespace = kubernetes_namespace.this.metadata[0].name
    labels = {
      app = local.name
    }
    annotations = {
      "metallb.io/allow-shared-ip" = "shared"
      "metallb.io/loadBalancerIPs" = "10.0.20.200"
    }
  }
  spec {
    type                    = "LoadBalancer"
    external_traffic_policy = "Cluster"
    selector = {
      app = local.name
    }
    port {
      name        = "rtsp"
      port        = 8554
      target_port = 8554
      protocol    = "TCP"
    }
    port {
      name        = "http"
      port        = 8080
      target_port = 8080
      protocol    = "TCP"
    }
  }
  lifecycle {
    ignore_changes = [metadata[0].annotations["metallb.io/ip-allocated-from-pool"]] # METALLB_LIFECYCLE_V1
  }
}

# --- Camera switch for HA London -------------------------------------------
# HA London (rest_command over the WireGuard tunnel to https://10.0.20.100:6443)
# patches the replica count of this one Deployment and reads it back. Nothing
# else: the Role names the Deployment and grants only get/patch.
resource "kubernetes_service_account" "camera_switch" {
  metadata {
    name      = "camera-switch"
    namespace = kubernetes_namespace.this.metadata[0].name
  }
}

resource "kubernetes_role" "camera_switch" {
  metadata {
    name      = "camera-switch"
    namespace = kubernetes_namespace.this.metadata[0].name
  }
  rule {
    api_groups     = ["apps"]
    resources      = ["deployments", "deployments/scale"]
    resource_names = [local.name]
    verbs          = ["get", "patch"]
  }
}

resource "kubernetes_role_binding" "camera_switch" {
  metadata {
    name      = "camera-switch"
    namespace = kubernetes_namespace.this.metadata[0].name
  }
  role_ref {
    api_group = "rbac.authorization.k8s.io"
    kind      = "Role"
    name      = kubernetes_role.camera_switch.metadata[0].name
  }
  subject {
    kind      = "ServiceAccount"
    name      = kubernetes_service_account.camera_switch.metadata[0].name
    namespace = kubernetes_namespace.this.metadata[0].name
  }
}

# Long-lived token for HA London; copied into HA's secrets.yaml as
# k8s_yiko_camera_token (runbook). Delete this Secret to revoke it.
resource "kubernetes_secret" "camera_switch_token" {
  metadata {
    name      = "camera-switch-token"
    namespace = kubernetes_namespace.this.metadata[0].name
    annotations = {
      "kubernetes.io/service-account.name" = kubernetes_service_account.camera_switch.metadata[0].name
    }
  }
  type                           = "kubernetes.io/service-account-token"
  wait_for_service_account_token = true
}

# --- Safety cap ---------------------------------------------------------------
# If HA London never sends the stop (HA down, tunnel down), scale to 0 once a
# pod has run for more than 15 minutes. HA's own auto-off is 5 minutes.
resource "kubernetes_service_account" "camera_cap" {
  metadata {
    name      = "camera-cap"
    namespace = kubernetes_namespace.this.metadata[0].name
  }
}

resource "kubernetes_role" "camera_cap" {
  metadata {
    name      = "camera-cap"
    namespace = kubernetes_namespace.this.metadata[0].name
  }
  rule {
    api_groups     = ["apps"]
    resources      = ["deployments"]
    resource_names = [local.name]
    verbs          = ["get", "patch"]
  }
  # list cannot be limited by name
  rule {
    api_groups = [""]
    resources  = ["pods"]
    verbs      = ["list"]
  }
}

resource "kubernetes_role_binding" "camera_cap" {
  metadata {
    name      = "camera-cap"
    namespace = kubernetes_namespace.this.metadata[0].name
  }
  role_ref {
    api_group = "rbac.authorization.k8s.io"
    kind      = "Role"
    name      = kubernetes_role.camera_cap.metadata[0].name
  }
  subject {
    kind      = "ServiceAccount"
    name      = kubernetes_service_account.camera_cap.metadata[0].name
    namespace = kubernetes_namespace.this.metadata[0].name
  }
}

resource "kubernetes_cron_job_v1" "camera_cap" {
  metadata {
    name      = "camera-cap"
    namespace = kubernetes_namespace.this.metadata[0].name
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
            service_account_name = kubernetes_service_account.camera_cap.metadata[0].name
            restart_policy       = "Never"
            container {
              name    = "cap"
              image   = "bitnami/kubectl:latest"
              command = ["/bin/bash", "-c"]
              args = [<<-EOT
                set -eu
                NS=${local.namespace}
                DEPLOY=${local.name}
                LIMIT_SECONDS=900
                spec=$(kubectl -n $NS get deploy $DEPLOY -o jsonpath='{.spec.replicas}')
                [ "$spec" = "0" ] && { echo "camera off"; exit 0; }
                started=$(kubectl -n $NS get pods -l app=$DEPLOY -o jsonpath='{.items[*].metadata.creationTimestamp}' | tr ' ' '\n' | sort | head -n1)
                [ -z "$started" ] && { echo "replicas=$spec but no pod yet"; exit 0; }
                age=$(( $(date -u +%s) - $(date -u -d "$started" +%s) ))
                echo "camera pod up for $age s (limit $LIMIT_SECONDS s)"
                if [ "$age" -gt "$LIMIT_SECONDS" ]; then
                  kubectl -n $NS patch deploy $DEPLOY --type=merge -p '{"spec":{"replicas":0}}'
                  echo "scaled to 0"
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
