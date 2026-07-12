variable "tls_secret_name" {
  type      = string
  sensitive = true
}
variable "nfs_server" { type = string }


resource "kubernetes_namespace" "excalidraw" {
  metadata {
    name = "excalidraw"
    labels = {
      "istio-injection" : "disabled"
      tier               = local.tiers.aux
      "keel.sh/enrolled" = "true"
    }
  }
  lifecycle {
    # KYVERNO_LIFECYCLE_V1: goldilocks-vpa-auto-mode ClusterPolicy stamps this label on every namespace
    ignore_changes = [metadata[0].labels["goldilocks.fairwinds.com/vpa-update-mode"]]
  }
}


module "tls_secret" {
  source          = "../../modules/kubernetes/setup_tls_secret"
  namespace       = kubernetes_namespace.excalidraw.metadata[0].name
  tls_secret_name = var.tls_secret_name
}

module "nfs_data_host" {
  source       = "../../modules/kubernetes/nfs_volume"
  name         = "excalidraw-data-host"
  namespace    = kubernetes_namespace.excalidraw.metadata[0].name
  nfs_server   = var.nfs_server
  nfs_path     = "/srv/nfs/excalidraw"
  storage      = "1Gi"
  access_modes = ["ReadWriteOnce"]
}

resource "kubernetes_deployment" "excalidraw" {
  metadata {
    name      = "excalidraw"
    namespace = kubernetes_namespace.excalidraw.metadata[0].name
    labels = {
      app  = "excalidraw"
      tier = local.tiers.aux
      # Scale-to-zero enrollment (ADR-0022): parked when idle, woken by the
      # first request through the ingress (design doc 2026-07-12).
      "sablier.enable" = "true"
      "sablier.group"  = "excalidraw"
      # 5s settling delay after k8s readiness: covers Traefik endpoint-list
      # propagation so the first forwarded request never hits a 503 race.
      "sablier.ready-after" = "5s"
    }
    # Keel rolls new ghcr:latest digests (k8s-portal pattern). Values here are
    # recreate-correct seeds only — the keys are in ignore_changes below, so
    # the live annotations win on an existing deployment.
    annotations = {
      "keel.sh/policy"       = "force"
      "keel.sh/trigger"      = "poll"
      "keel.sh/match-tag"    = "true"
      "keel.sh/pollSchedule" = "@every 5m"
    }
  }
  spec {
    replicas = 1
    strategy {
      type = "Recreate"
    }
    selector {
      match_labels = {
        app = "excalidraw"
      }
    }
    template {
      metadata {
        labels = {
          app = "excalidraw"
        }
        annotations = {
          "diun.enable"       = "true"
          "diun.include_tags" = "^latest$"
        }
      }
      spec {
        # GHCR pull secret: the ghcr-credentials Secret in this namespace is
        # cloned in by the kyverno stack's sync-ghcr-credentials ClusterPolicy
        # (allowlisted private-ghcr namespaces only — ADR-0002). Source of
        # truth: stacks/kyverno/modules/kyverno/ghcr-credentials.tf.
        image_pull_secrets {
          name = "ghcr-credentials"
        }
        container {
          # ADR-0002: GHA-built (.github/workflows/build-excalidraw.yml),
          # PRIVATE ghcr; Keel rolls new :latest digests. DockerHub
          # viktorbarzin/excalidraw-library:v4 is the frozen rollback image.
          image             = "ghcr.io/viktorbarzin/excalidraw-library:latest"
          image_pull_policy = "Always"
          name              = "excalidraw"
          port {
            container_port = 8080
          }
          env {
            name  = "DATA_DIR"
            value = "/data"
          }
          env {
            name  = "PORT"
            value = "8080"
          }
          volume_mount {
            name       = "data"
            mount_path = "/data"
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
        }
        volume {
          name = "data"
          persistent_volume_claim {
            claim_name = module.nfs_data_host.claim_name
          }
        }
      }
    }
  }
  lifecycle {
    ignore_changes = [
      spec[0].template[0].spec[0].dns_config,         # KYVERNO_LIFECYCLE_V1
      spec[0].template[0].spec[0].container[0].image, # KEEL_IGNORE_IMAGE — Keel manages tag updates
      metadata[0].annotations["keel.sh/policy"],
      metadata[0].annotations["keel.sh/trigger"],
      metadata[0].annotations["keel.sh/pollSchedule"], # KYVERNO_LIFECYCLE_V2
      metadata[0].annotations["keel.sh/match-tag"],
      metadata[0].annotations["kubernetes.io/change-cause"],
      metadata[0].annotations["deployment.kubernetes.io/revision"],
      spec[0].template[0].metadata[0].annotations["keel.sh/update-time"], # KEEL_LIFECYCLE_V1
      spec[0].replicas,                                                   # SABLIER_MANAGED_REPLICAS — sablier scales 0<->1 (ADR-0022)
    ]
  }
}

resource "kubernetes_service" "draw" {
  metadata {
    name      = "draw"
    namespace = kubernetes_namespace.excalidraw.metadata[0].name
    labels = {
      app = "excalidraw"
    }
  }

  spec {
    selector = {
      app = "excalidraw"
    }
    port {
      name        = "http"
      port        = 80
      target_port = 8080
    }
  }
}

module "ingress" {
  source = "../../modules/kubernetes/ingress_factory"
  # Scale-to-zero (ADR-0022): held-request wake, 3h idle park.
  sablier = {
    group = "excalidraw"
  }
  dns_type        = "proxied"
  namespace       = kubernetes_namespace.excalidraw.metadata[0].name
  name            = "draw"
  tls_secret_name = var.tls_secret_name
  auth            = "required"
  extra_annotations = {
    "gethomepage.dev/enabled"      = "true"
    "gethomepage.dev/name"         = "Excalidraw"
    "gethomepage.dev/description"  = "Collaborative whiteboard"
    "gethomepage.dev/icon"         = "excalidraw.png"
    "gethomepage.dev/group"        = "Development & CI"
    "gethomepage.dev/pod-selector" = ""
  }
}
