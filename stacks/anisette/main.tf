# anisette — self-hosted Apple anisette-data server for SideStore/AltStore.
#
# Purpose (infra issue #40): the TripIt iOS Shell is sideloaded with SideStore
# using a free Apple ID. SideStore needs an "anisette" server to broker the
# Apple-ID auth dance; the public community anisette servers see every login,
# so we run our own. Stateless HTTP service on a stable INTERNAL endpoint
# (anisette.viktorbarzin.lan) that SideStore points at.
#
# Image: Dadoum/anisette-v3-server — the de-facto standard anisette-v3 server
# for SideStore/AltStore (the same project SideStore's own docs point at).
# Upstream publishes ONLY a mutable :latest tag (no GitHub releases, no semver,
# no date/sha tags — verified 2026-06-14), so we pin by MANIFEST DIGEST instead
# (immutable, honours the "never :latest" rule). DockerHub is pulled
# transparently via the registry-VM pull-through cache, same as echo/cyberchef.
# To bump: `docker buildx imagetools inspect dadoum/anisette-v3-server:latest`,
# then replace the digest below.
#
# Stateless: the container caches Apple provisioning libraries under
# /home/Alcoholic/.config/anisette-v3/lib (a regenerable download — re-fetched
# if absent — and per upstream issue #23 it does NOT preserve client auth across
# restarts anyway). So an emptyDir is the honest fit: keeps that path writable
# without taking on a backup-pipeline obligation. No PVC, no Vault secret.

variable "tls_secret_name" {
  type      = string
  sensitive = true
}

resource "kubernetes_namespace" "anisette" {
  metadata {
    name = "anisette"
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

module "tls_secret" {
  source          = "../../modules/kubernetes/setup_tls_secret"
  namespace       = kubernetes_namespace.anisette.metadata[0].name
  tls_secret_name = var.tls_secret_name
}

resource "kubernetes_deployment" "anisette" {
  metadata {
    name      = "anisette"
    namespace = kubernetes_namespace.anisette.metadata[0].name
    labels = {
      app  = "anisette"
      tier = local.tiers.aux
    }
  }
  spec {
    replicas = 1
    selector {
      match_labels = {
        app = "anisette"
      }
    }
    template {
      metadata {
        labels = {
          app = "anisette"
        }
        annotations = {
          # Diun notify-only watch. Upstream tags only :latest, so watch the
          # digest of :latest rather than a semver pattern.
          "diun.enable"       = "true"
          "diun.watch_repo"   = "false"
          "diun.include_tags" = "^latest$"
        }
      }
      spec {
        container {
          # Pinned by digest — upstream ships only a mutable :latest (no tags).
          # The `docker.io/` prefix is REQUIRED, not cosmetic: the Kyverno
          # require-trusted-registries policy allowlists `docker.io/*` but NOT a
          # bare `dadoum/*` prefix (only enumerated DockerHub user repos like
          # mendhak/*, mpepping/* are listed in
          # stacks/kyverno/modules/kyverno/security-policies.tf). A bare
          # `dadoum/anisette-v3-server@...` is denied at admission; the explicit
          # docker.io/ registry matches the allowlist and still pulls via the
          # 10.0.20.10 pull-through cache.
          image = "docker.io/dadoum/anisette-v3-server@sha256:1e20384985d3c49965f444bef39d627768dacc39ea0dca91f2a535edb7591ba3"
          name  = "anisette"
          port {
            name           = "http"
            container_port = 6969
          }
          # The image runs as the non-root user "Alcoholic" and writes its
          # provisioning-library cache here; back it with an emptyDir so the
          # path is writable (stateless — wiped on restart, re-downloaded).
          volume_mount {
            name       = "provisioning-cache"
            mount_path = "/home/Alcoholic/.config/anisette-v3/lib"
          }
          resources {
            requests = {
              cpu    = "10m"
              memory = "256Mi"
            }
            limits = {
              # anisette downloads + initializes Apple's CoreADI provisioning
              # library at startup, which spikes past 128Mi → OOMKilled (exit
              # 137) before it can bind :6969. 512Mi gives headroom; steady
              # state is much lower.
              memory = "512Mi"
            }
          }
          readiness_probe {
            http_get {
              path = "/"
              port = 6969
            }
            period_seconds        = 15
            initial_delay_seconds = 5
          }
          liveness_probe {
            http_get {
              path = "/"
              port = 6969
            }
            period_seconds    = 30
            failure_threshold = 6
          }
        }
        volume {
          name = "provisioning-cache"
          empty_dir {}
        }
      }
    }
  }
  lifecycle {
    ignore_changes = [
      spec[0].template[0].spec[0].dns_config, # KYVERNO_LIFECYCLE_V1
    ]
  }
}

resource "kubernetes_service" "anisette" {
  metadata {
    name      = "anisette"
    namespace = kubernetes_namespace.anisette.metadata[0].name
    labels = {
      "app" = "anisette"
    }
  }
  spec {
    selector = {
      app = "anisette"
    }
    port {
      name        = "http"
      port        = "80"
      target_port = "6969"
    }
  }
}

module "ingress" {
  source = "../../modules/kubernetes/ingress_factory"
  # auth = "none": SideStore is a native iOS client — it can't replay the
  # Authentik forward-auth cookie dance, so Authentik would break it (same
  # reasoning as android-emulator's adb). Internal-only: anisette.viktorbarzin.lan,
  # allow_local_access_only locks it to the LAN, and it brokers no user data of
  # ours (it just relays Apple-ID anisette data). Never publicly exposed.
  auth                    = "none"
  namespace               = kubernetes_namespace.anisette.metadata[0].name
  name                    = "anisette"
  root_domain             = "viktorbarzin.lan"
  tls_secret_name         = var.tls_secret_name
  allow_local_access_only = true
  ssl_redirect            = false
  extra_annotations = {
    "gethomepage.dev/enabled" = "false"
  }
}
