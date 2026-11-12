# emo's hub: a headless Chrome that holds emo's own logins.
#
# One hub per person (2026-11-08, Viktor's decision): each person signs in once and
# every browser their agents use is signed in too. Viktor's hub is the chrome-service
# master (stacks/chrome-service). This one is emo's, and emo's browsers never see
# Viktor's cookies.
#
# Headless, without neko's live view (Viktor's choice): emo signs in through any of
# his own browsers, a terminal-lobby session browser (which he can watch and take
# over for captchas) or his T3 browser, and they push what they pick up here
# (POST /api/cookies). His devvm pulls the snapshot hourly and after each push.
#
# Pieces:
# - chrome-hub Deployment: the pool worker's image and launcher
#   (../chrome-service/files/worker_entrypoint.sh) on an encrypted PVC instead of
#   an emptyDir, plus the same snapshot-server sidecar as Viktor's hub, refreshing
#   its own snapshot hourly (no harvester CronJob, which would need the RWO volume).
# - chrome-hub-emo.viktorbarzin.me: LAN-only API (read and write tokens).
# - emo's `homelab browser` pool workers run in this namespace: the chrome-broker
#   (chrome-service) creates them here, and emo's emo-browser ServiceAccount may
#   port-forward here and nowhere else.
#
# Docs: docs/architecture/chrome-service.md "One hub per person".

variable "tls_secret_name" {
  type      = string
  sensitive = true
}

locals {
  namespace    = "chrome-emo"
  labels       = { app = "chrome-hub" }
  files        = "${path.module}/../chrome-service/files"
  python_image = "mcr.microsoft.com/playwright/python:v1.65.1-noble"
  # Same browser image the pool workers run, read from their template so the two
  # cannot drift apart.
  browser_image = jsondecode(file("${local.files}/broker/worker_pod.json")).spec.containers[0].image
}

resource "kubernetes_namespace" "chrome_emo" {
  metadata {
    name = local.namespace
    labels = {
      "istio-injection" = "disabled"
      tier              = local.tiers.aux
      # The tier-4-aux quota (3Gi requests) cannot fit the hub plus pool workers
      # at 2Gi each; the quota below replaces it.
      "resource-governance/custom-quota" = "true"
    }
  }
  lifecycle {
    # KYVERNO_LIFECYCLE_V1: goldilocks-vpa-auto-mode ClusterPolicy stamps this label on every namespace
    ignore_changes = [metadata[0].labels["goldilocks.fairwinds.com/vpa-update-mode"]]
  }
}

# Hub (~1Gi) plus up to three of emo's pool workers (2Gi request, 4Gi limit each).
# The broker's own MAX_WORKERS (6, shared across hubs) still applies.
resource "kubernetes_resource_quota" "chrome_emo" {
  metadata {
    name      = "chrome-emo"
    namespace = kubernetes_namespace.chrome_emo.metadata[0].name
  }
  spec {
    hard = {
      "requests.memory" = "8Gi"
      "limits.memory"   = "16Gi"
      "requests.cpu"    = "2"
      pods              = "6"
    }
  }
}

# secret/chrome-emo in Vault: api_bearer_token (read: snapshot, broker) and
# api_write_token (POST /api/cookies). Only this namespace extracts the whole
# path; the broker gets the read token alone (stacks/chrome-service/broker.tf).
resource "kubernetes_manifest" "external_secret" {
  manifest = {
    apiVersion = "external-secrets.io/v1"
    kind       = "ExternalSecret"
    metadata = {
      name      = "chrome-emo-secrets"
      namespace = local.namespace
    }
    spec = {
      refreshInterval = "1h"
      secretStoreRef = {
        name = "vault-kv"
        kind = "ClusterSecretStore"
      }
      target = {
        name = "chrome-emo-secrets"
      }
      dataFrom = [{
        extract = {
          key = "chrome-emo"
        }
      }]
    }
  }
  depends_on = [kubernetes_namespace.chrome_emo]
}

# Named snapshot-scripts like Viktor's, because the pool worker template the
# broker uses for emo's workers mounts a ConfigMap by that name.
resource "kubernetes_config_map_v1" "scripts" {
  metadata {
    name      = "snapshot-scripts"
    namespace = kubernetes_namespace.chrome_emo.metadata[0].name
    labels    = local.labels
  }
  data = {
    "snapshot_server.py"   = file("${local.files}/snapshot_server.py")
    "cdp_bridge.py"        = file("${local.files}/cdp_bridge.py")
    "cdp_cookies.py"       = file("${local.files}/broker/cdp_cookies.py")
    "cookie_merge.py"      = file("${local.files}/broker/cookie_merge.py")
    "hub_store.py"         = file("${local.files}/broker/hub_store.py")
    "worker_entrypoint.sh" = file("${local.files}/worker_entrypoint.sh")
  }
}

resource "kubernetes_persistent_volume_claim" "profile" {
  wait_until_bound = false
  metadata {
    name      = "chrome-emo-profile-encrypted"
    namespace = kubernetes_namespace.chrome_emo.metadata[0].name
    annotations = {
      "resize.topolvm.io/threshold"     = "10%"
      "resize.topolvm.io/increase"      = "100%"
      "resize.topolvm.io/storage_limit" = "10Gi"
    }
  }
  spec {
    access_modes       = ["ReadWriteOnce"]
    storage_class_name = "proxmox-lvm-encrypted"
    resources {
      requests = { storage = "2Gi" }
    }
  }
  lifecycle {
    # The autoresizer grows requests.storage; PVCs cannot shrink back.
    ignore_changes = [spec[0].resources[0].requests]
  }
}

resource "kubernetes_deployment" "hub" {
  metadata {
    name      = "chrome-hub"
    namespace = kubernetes_namespace.chrome_emo.metadata[0].name
    labels    = local.labels
    annotations = {
      "reloader.stakater.com/auto" = "true"
    }
  }
  spec {
    replicas = 1
    strategy {
      type = "Recreate" # RWO profile volume
    }
    selector {
      match_labels = local.labels
    }
    template {
      metadata {
        labels = local.labels
      }
      spec {
        security_context {
          run_as_user  = 1000
          run_as_group = 1000
          fs_group     = 1000
          seccomp_profile {
            type = "RuntimeDefault"
          }
        }

        container {
          name              = "chrome"
          image             = local.browser_image
          image_pull_policy = "IfNotPresent"
          command           = ["bash", "/scripts/worker_entrypoint.sh"]
          env {
            name  = "DISPLAY"
            value = ":99"
          }
          env {
            name  = "HOME"
            value = "/profile"
          }
          port {
            name           = "cdp"
            container_port = 9222
          }
          readiness_probe {
            http_get {
              path = "/json/version"
              port = 9222
            }
            initial_delay_seconds = 3
            period_seconds        = 10
          }
          liveness_probe {
            http_get {
              path = "/json/version"
              port = 9222
            }
            initial_delay_seconds = 30
            period_seconds        = 30
            failure_threshold     = 4
          }
          resources {
            requests = { cpu = "100m", memory = "768Mi" }
            limits   = { memory = "1536Mi" }
          }
          volume_mount {
            name       = "profile"
            mount_path = "/profile"
          }
          volume_mount {
            name       = "dshm"
            mount_path = "/dev/shm"
          }
          volume_mount {
            name       = "scripts"
            mount_path = "/scripts"
            read_only  = true
          }
        }

        container {
          name              = "snapshot-server"
          image             = local.python_image
          image_pull_policy = "IfNotPresent"
          command           = ["python3", "/scripts/snapshot_server.py"]
          env {
            name = "PW_TOKEN"
            value_from {
              secret_key_ref {
                name = "chrome-emo-secrets"
                key  = "api_bearer_token"
              }
            }
          }
          env {
            name = "PW_WRITE_TOKEN"
            value_from {
              secret_key_ref {
                name = "chrome-emo-secrets"
                key  = "api_write_token"
              }
            }
          }
          env {
            name  = "SNAPSHOT_PATH"
            value = "/profile/snapshots/storage-state.json"
          }
          env {
            name  = "CDP_URL"
            value = "http://127.0.0.1:9222"
          }
          env {
            name  = "REFRESH_SECONDS"
            value = "3600"
          }
          env {
            name  = "PORT"
            value = "8088"
          }
          port {
            name           = "snap"
            container_port = 8088
          }
          readiness_probe {
            http_get {
              path = "/healthz"
              port = 8088
            }
            period_seconds = 10
          }
          resources {
            requests = { cpu = "5m", memory = "48Mi" }
            limits   = { memory = "160Mi" }
          }
          volume_mount {
            name       = "profile"
            mount_path = "/profile/snapshots"
            sub_path   = "snapshots"
          }
          volume_mount {
            name       = "scripts"
            mount_path = "/scripts"
            read_only  = true
          }
        }

        volume {
          name = "profile"
          persistent_volume_claim {
            claim_name = kubernetes_persistent_volume_claim.profile.metadata[0].name
          }
        }
        volume {
          name = "dshm"
          empty_dir {
            medium     = "Memory"
            size_limit = "512Mi"
          }
        }
        volume {
          name = "scripts"
          config_map {
            name         = kubernetes_config_map_v1.scripts.metadata[0].name
            default_mode = "0555"
          }
        }
      }
    }
  }
  lifecycle {
    ignore_changes = [
      spec[0].template[0].spec[0].dns_config, # KYVERNO_LIFECYCLE_V1
    ]
  }
  depends_on = [kubernetes_manifest.external_secret]
}

resource "kubernetes_service" "hub" {
  metadata {
    name      = "chrome-hub"
    namespace = kubernetes_namespace.chrome_emo.metadata[0].name
    labels    = local.labels
  }
  spec {
    selector = local.labels
    port {
      name        = "cdp"
      port        = 9222
      target_port = 9222
    }
    port {
      name        = "snap"
      port        = 8088
      target_port = 8088
    }
  }
}

# emo's hub API, LAN-only: GET /api/snapshot and POST /api/cookies, bearer-gated
# inside snapshot_server.py. Same shape as Viktor's chrome-hub host.
module "ingress_hub" {
  source = "../../modules/kubernetes/ingress_factory"
  # auth = "none": emo's devvm timers and browsers hold no SSO cookie; the LAN
  # allowlist plus the read/write bearer checks in snapshot_server.py gate it.
  auth                    = "none"
  dns_type                = "internal"
  allow_local_access_only = true
  external_monitor        = false
  namespace               = kubernetes_namespace.chrome_emo.metadata[0].name
  name                    = "chrome-hub-emo"
  host                    = "chrome-hub-emo"
  service_name            = kubernetes_service.hub.metadata[0].name
  port                    = 8088
  ingress_path            = ["/api/snapshot", "/api/cookies"]
  tls_secret_name         = var.tls_secret_name
  extra_annotations = {
    "gethomepage.dev/enabled" = "false"
  }
}

# CDP (9222) of the hub and of emo's pool workers: only the broker (chrome-service,
# for seeds and worker resets) and this namespace. The hub API (8088): Traefik only.
# Port-forwards bypass NetworkPolicy; RBAC below limits those to emo.
resource "kubernetes_network_policy_v1" "ingress" {
  metadata {
    name      = "chrome-emo-ingress"
    namespace = kubernetes_namespace.chrome_emo.metadata[0].name
  }
  spec {
    pod_selector {}
    policy_types = ["Ingress"]
    ingress {
      ports {
        port     = 9222
        protocol = "TCP"
      }
      from {
        namespace_selector {
          match_labels = { "kubernetes.io/metadata.name" = "chrome-service" }
        }
      }
      from {
        namespace_selector {
          match_labels = { "kubernetes.io/metadata.name" = local.namespace }
        }
      }
    }
    ingress {
      ports {
        port     = 8088
        protocol = "TCP"
      }
      from {
        namespace_selector {
          match_labels = { "kubernetes.io/metadata.name" = "traefik" }
        }
      }
    }
  }
}

# The chrome-broker runs emo's pool workers here: the same pods verbs it holds in
# chrome-service.
resource "kubernetes_role" "broker" {
  metadata {
    name      = "chrome-broker"
    namespace = kubernetes_namespace.chrome_emo.metadata[0].name
  }
  rule {
    api_groups = [""]
    resources  = ["pods"]
    verbs      = ["get", "list", "watch", "create", "delete", "patch"]
  }
}

resource "kubernetes_role_binding" "broker" {
  metadata {
    name      = "chrome-broker"
    namespace = kubernetes_namespace.chrome_emo.metadata[0].name
  }
  role_ref {
    api_group = "rbac.authorization.k8s.io"
    kind      = "Role"
    name      = kubernetes_role.broker.metadata[0].name
  }
  subject {
    kind      = "ServiceAccount"
    name      = "chrome-broker"
    namespace = "chrome-service"
  }
}

# emo's `homelab browser` port-forwards to his pool worker (and, for
# --shared-context, his hub) here. His emo-browser ServiceAccount lives in
# chrome-service, where the devvm provisioner finds it, but may port-forward only
# in this namespace.
resource "kubernetes_role" "portforward" {
  metadata {
    name      = "chrome-emo-portforward"
    namespace = kubernetes_namespace.chrome_emo.metadata[0].name
  }
  rule {
    api_groups = [""]
    resources  = ["pods/portforward"]
    verbs      = ["create"]
  }
}

resource "kubernetes_role_binding" "emo_portforward" {
  metadata {
    name      = "emo-browser-portforward"
    namespace = kubernetes_namespace.chrome_emo.metadata[0].name
  }
  role_ref {
    api_group = "rbac.authorization.k8s.io"
    kind      = "Role"
    name      = kubernetes_role.portforward.metadata[0].name
  }
  subject {
    kind      = "ServiceAccount"
    name      = "emo-browser"
    namespace = "chrome-service"
  }
}
