variable "tls_secret_name" {
  type      = string
  sensitive = true
}
variable "nfs_server" { type = string }

# Cluster VPN egress pilot — docs/plans/2026-08-16-cluster-vpn-egress-service-design.md
#
# Book-search is the first consumer of the shared VPN egress service: its
# outbound HTTP is re-originated from inside the UK NordVPN tunnel by gluetun's
# built-in HTTP proxy listener. In-cluster calls and myanonamouse.net stay
# direct (see the NO_PROXY env on the Deployment).
#
# This is a MEASURED pilot, ON by default so we get data. What motivated it is
# the Anna's Archive 403, and that 403 is a DDoS-Guard JS challenge keyed on
# ASN reputation rather than a geo-block (reproduced from the pod, 2026-08-16:
# 902-byte body, <title>DDoS-Guard</title>). A datacenter/VPN exit may well be
# challenged at least as often as the current residential IP, so compare
# download success before and after rather than assuming the route fixes it.
# The FlareSolverr fallback leg does not move either — FlareSolverr makes its
# own outbound request from its own pod in servarr.
#
# TO REVERT: set this to "" and apply. An empty value produces no proxy mount
# at all (urllib's getproxies_environment drops empty *_proxy vars, so httpx
# sees none), which keeps the off position a value edit — the env blocks stay
# in place and NO_PROXY goes inert alongside them. Verified live in the running
# pod on 2026-08-16, both positions.
# Calibre-web shelf that Goodreads-sourced books land on. Public, owned by
# Anca's calibre-web user, so the admin session book-search already holds can
# write to it. "0" disables shelving (the book still imports into the library).
variable "goodreads_shelf_id" {
  type = string
  # Shelf 6: "Goodreads wishlist", public, owned by calibre-web user `anca`.
  default     = "6"
  description = "calibre-web shelf id for books sourced from Anca's Goodreads to-read shelf."
}

# Downloads stay OFF until the matcher has been checked by hand against her real
# shelf (backend/goodreads/replay.py). With this false the poller still reads the
# feed and reports what it would fetch, but never fetches.
variable "goodreads_downloads_enabled" {
  type = string
  # ON since 2026-08-16. The gate is passed: the matcher was replayed over 50 of
  # her real shelf items and every pick checked by hand, and the whole path was
  # run end to end (Strange Houses -> libgen -> Calibre 497 -> her shelf).
  default     = "true"
  description = "Whether the Goodreads poller may actually download books."
}

variable "book_search_proxy_url" {
  type = string
  # REVERTED 2026-08-16 after measuring. The pilot answered its question and the
  # answer was no: routing book-search through the UK exit changed nothing on any
  # of its blocked endpoints. Measured from the pod, direct vs proxied:
  #   annas-archive.gl/search  403 -> 403
  #   googleapis.com/books     429 -> 429   (a quota limit, not an IP block)
  #   libgen                   error -> error
  # This matches the design's stated expectation: NordVPN exits sit in hosting
  # ASNs that anti-bot vendors score more harshly than a residential address, so
  # a datacenter exit does not beat a challenge the home IP already fails. The
  # egress service itself is verified working (UK exit, fail-closed, no leak) —
  # this consumer just gains nothing from it.
  # Set back to "http://proxy-egress-uk.proxy.svc.cluster.local:8888" to re-run.
  default     = ""
  description = "Outbound HTTP proxy for book-search (cluster VPN egress, UK exit). Empty string = no proxy, traffic egresses from the home IP as before."
}

resource "kubernetes_namespace" "ebooks" {
  metadata {
    name = "ebooks"
    labels = {
      tier               = local.tiers.edge
      "keel.sh/enrolled" = "true"
      # Lets book-search reach the shared headful Chrome's CDP port, which is
      # the only way Anna's Archive can be searched: AA's DDoS-Guard refuses our
      # HTTP clients on fingerprint, and only that browser (once a human has
      # passed its captcha) gets real results.
      "chrome-service.viktorbarzin.me/client" = "true"
    }
  }
  lifecycle {
    # KYVERNO_LIFECYCLE_V1: goldilocks-vpa-auto-mode ClusterPolicy stamps this label on every namespace
    ignore_changes = [metadata[0].labels["goldilocks.fairwinds.com/vpa-update-mode"]]
  }
}

# ExternalSecrets for all three sources
resource "kubernetes_manifest" "calibre_external_secret" {
  field_manager {
    force_conflicts = true
  }
  manifest = {
    apiVersion = "external-secrets.io/v1"
    kind       = "ExternalSecret"
    metadata = {
      name      = "calibre-secrets"
      namespace = "ebooks"
    }
    spec = {
      refreshInterval = "15m"
      secretStoreRef = {
        name = "vault-kv"
        kind = "ClusterSecretStore"
      }
      target = {
        name = "calibre-secrets"
      }
      dataFrom = [{
        extract = {
          key = "calibre"
        }
      }]
    }
  }
  depends_on = [kubernetes_namespace.ebooks]
}

resource "kubernetes_manifest" "audiobookshelf_external_secret" {
  field_manager {
    force_conflicts = true
  }
  manifest = {
    apiVersion = "external-secrets.io/v1"
    kind       = "ExternalSecret"
    metadata = {
      name      = "audiobookshelf-secrets"
      namespace = "ebooks"
    }
    spec = {
      refreshInterval = "15m"
      secretStoreRef = {
        name = "vault-kv"
        kind = "ClusterSecretStore"
      }
      target = {
        name = "audiobookshelf-secrets"
      }
      dataFrom = [{
        extract = {
          key = "audiobookshelf"
        }
      }]
    }
  }
  depends_on = [kubernetes_namespace.ebooks]
}

resource "kubernetes_manifest" "servarr_external_secret" {
  field_manager {
    force_conflicts = true
  }
  manifest = {
    apiVersion = "external-secrets.io/v1"
    kind       = "ExternalSecret"
    metadata = {
      name      = "servarr-secrets"
      namespace = "ebooks"
    }
    spec = {
      refreshInterval = "15m"
      secretStoreRef = {
        name = "vault-kv"
        kind = "ClusterSecretStore"
      }
      target = {
        name = "servarr-secrets"
      }
      dataFrom = [{
        extract = {
          key = "servarr"
        }
      }]
    }
  }
  depends_on = [kubernetes_namespace.ebooks]
}

# Data sources to read ExternalSecret-created secrets
data "kubernetes_secret" "calibre_secrets" {
  metadata {
    name      = "calibre-secrets"
    namespace = kubernetes_namespace.ebooks.metadata[0].name
  }
  depends_on = [kubernetes_manifest.calibre_external_secret]
}

data "kubernetes_secret" "audiobookshelf_secrets" {
  metadata {
    name      = "audiobookshelf-secrets"
    namespace = kubernetes_namespace.ebooks.metadata[0].name
  }
  depends_on = [kubernetes_manifest.audiobookshelf_external_secret]
}

data "kubernetes_secret" "servarr_secrets" {
  metadata {
    name      = "servarr-secrets"
    namespace = kubernetes_namespace.ebooks.metadata[0].name
  }
  depends_on = [kubernetes_manifest.servarr_external_secret]
}

locals {
  calibre_homepage_credentials        = jsondecode(data.kubernetes_secret.calibre_secrets.data["homepage_credentials"])
  audiobookshelf_homepage_credentials = jsondecode(data.kubernetes_secret.audiobookshelf_secrets.data["homepage_credentials"])
}

module "tls_secret" {
  source          = "../../modules/kubernetes/setup_tls_secret"
  namespace       = kubernetes_namespace.ebooks.metadata[0].name
  tls_secret_name = var.tls_secret_name
}

# NFS Volumes - Calibre (prefixed with ebooks- to avoid PV name clash with old stacks)
module "nfs_calibre_library_host" {
  source     = "../../modules/kubernetes/nfs_volume"
  name       = "ebooks-calibre-library-host"
  namespace  = kubernetes_namespace.ebooks.metadata[0].name
  nfs_server = "192.168.1.127"
  nfs_path   = "/srv/nfs/calibre-web-automated/calibre-library"
}

# iSCSI volume for config (SQLite DBs) - enables WAL mode for concurrent reads/writes
resource "kubernetes_persistent_volume_claim" "calibre_config_iscsi" {
  metadata {
    name      = "ebooks-calibre-config-proxmox"
    namespace = kubernetes_namespace.ebooks.metadata[0].name
    annotations = {
      "resize.topolvm.io/threshold"     = "10%"
      "resize.topolvm.io/increase"      = "50%"
      "resize.topolvm.io/storage_limit" = "10Gi"
    }
  }
  spec {
    access_modes       = ["ReadWriteOnce"]
    storage_class_name = "proxmox-lvm"
    resources {
      requests = {
        storage = "2Gi"
      }
    }
  }
  lifecycle {
    # The autoresizer expands requests.storage up to storage_limit and
    # PVCs can't shrink. Without this, every TF apply tries to revert
    # to the spec value, K8s rejects the shrink, and the PVC ends up
    # in Terminating-but-in-use limbo.
    ignore_changes = [spec[0].resources[0].requests]
  }
}

module "nfs_calibre_ingest_host" {
  source     = "../../modules/kubernetes/nfs_volume"
  name       = "ebooks-calibre-ingest-host"
  namespace  = kubernetes_namespace.ebooks.metadata[0].name
  nfs_server = "192.168.1.127"
  nfs_path   = "/srv/nfs/calibre-web-automated/cwa-book-ingest"
}

module "nfs_mam_farming_host" {
  source     = "../../modules/kubernetes/nfs_volume"
  name       = "ebooks-mam-farming-host"
  namespace  = "ebooks"
  nfs_server = "192.168.1.127"
  nfs_path   = "/srv/nfs/servarr/mam-farming"
}

module "nfs_calibre_stacks_config_host" {
  source     = "../../modules/kubernetes/nfs_volume"
  name       = "ebooks-calibre-stacks-config-host"
  namespace  = kubernetes_namespace.ebooks.metadata[0].name
  nfs_server = "192.168.1.127"
  nfs_path   = "/srv/nfs/calibre-web-automated/stacks"
}

# NFS Volumes - Audiobookshelf (prefixed with ebooks- to avoid PV name clash)
module "nfs_audiobookshelf_audiobooks_host" {
  source     = "../../modules/kubernetes/nfs_volume"
  name       = "ebooks-abs-audiobooks-host"
  namespace  = kubernetes_namespace.ebooks.metadata[0].name
  nfs_server = "192.168.1.127"
  nfs_path   = "/srv/nfs/audiobookshelf/audiobooks"
}

module "nfs_audiobookshelf_podcasts_host" {
  source     = "../../modules/kubernetes/nfs_volume"
  name       = "ebooks-abs-podcasts-host"
  namespace  = kubernetes_namespace.ebooks.metadata[0].name
  nfs_server = "192.168.1.127"
  nfs_path   = "/srv/nfs/audiobookshelf/podcasts"
}

resource "kubernetes_persistent_volume_claim" "abs_config_proxmox" {
  wait_until_bound = false
  metadata {
    name      = "ebooks-abs-config-proxmox"
    namespace = kubernetes_namespace.ebooks.metadata[0].name
    annotations = {
      "resize.topolvm.io/threshold"     = "10%"
      "resize.topolvm.io/increase"      = "100%"
      "resize.topolvm.io/storage_limit" = "5Gi"
    }
  }
  spec {
    access_modes       = ["ReadWriteOnce"]
    storage_class_name = "proxmox-lvm"
    resources {
      requests = {
        storage = "1Gi"
      }
    }
  }
  lifecycle {
    # The autoresizer expands requests.storage up to storage_limit and
    # PVCs can't shrink. Without this, every TF apply tries to revert
    # to the spec value, K8s rejects the shrink, and the PVC ends up
    # in Terminating-but-in-use limbo.
    ignore_changes = [spec[0].resources[0].requests]
  }
}

module "nfs_audiobookshelf_metadata_host" {
  source     = "../../modules/kubernetes/nfs_volume"
  name       = "ebooks-abs-metadata-host"
  namespace  = kubernetes_namespace.ebooks.metadata[0].name
  nfs_server = "192.168.1.127"
  nfs_path   = "/srv/nfs/audiobookshelf/metadata"
}

# Calibre-Web-Automated Deployment
resource "kubernetes_deployment" "calibre-web-automated" {
  wait_for_rollout = true
  metadata {
    name      = "calibre-web-automated"
    namespace = kubernetes_namespace.ebooks.metadata[0].name
    labels = {
      app  = "calibre-web-automated"
      tier = local.tiers.edge
    }
    annotations = {
      "reloader.stakater.com/search" = "true"
    }
  }
  spec {
    replicas = 1
    strategy {
      type = "Recreate"
    }
    selector {
      match_labels = {
        app = "calibre-web-automated"
      }
    }
    template {
      metadata {
        annotations = {
          "diun.enable"       = "false"
          "diun.include_tags" = "^\\d+(?:\\.\\d+)?(?:\\.\\d+)?$"
        }
        labels = {
          app = "calibre-web-automated"
        }
      }
      spec {
        container {
          image = "viktorbarzin/calibre-web-automated:latest"
          name  = "calibre-web-automated"
          env {
            name  = "PUID"
            value = 1000
          }
          env {
            name  = "PGID"
            value = 1000
          }
          env {
            name  = "NO_CHOWN"
            value = "true"
          }
          env {
            name  = "CALIBRE_PORT"
            value = "8083"
          }
          env {
            # The ingest directory is NFS-backed and written by book-search;
            # inotify cannot observe writes made through another NFS client.
            name  = "NETWORK_SHARE_MODE"
            value = "true"
          }

          port {
            container_port = 8083
          }
          startup_probe {
            http_get {
              path = "/"
              port = 8083
            }
            initial_delay_seconds = 10
            timeout_seconds       = 5
            period_seconds        = 5
            failure_threshold     = 24
          }
          liveness_probe {
            http_get {
              path = "/"
              port = 8083
            }
            timeout_seconds   = 10
            period_seconds    = 30
            failure_threshold = 6
          }
          resources {
            requests = {
              cpu    = "50m"
              memory = "512Mi"
            }
            limits = {
              memory = "1Gi"
            }
          }
          volume_mount {
            name       = "config"
            mount_path = "/config"
          }
          volume_mount {
            name       = "library"
            mount_path = "/calibre-library"
          }
          volume_mount {
            name       = "ingest"
            mount_path = "/cwa-book-ingest"
          }
        }
        volume {
          name = "library"
          persistent_volume_claim {
            claim_name = module.nfs_calibre_library_host.claim_name
          }
        }
        volume {
          name = "config"
          persistent_volume_claim {
            claim_name = kubernetes_persistent_volume_claim.calibre_config_iscsi.metadata[0].name
          }
        }
        volume {
          name = "ingest"
          persistent_volume_claim {
            claim_name = module.nfs_calibre_ingest_host.claim_name
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
    ]
  }
}

resource "kubernetes_service" "calibre" {
  metadata {
    name      = "calibre"
    namespace = kubernetes_namespace.ebooks.metadata[0].name
    labels = {
      "app" = "calibre"
    }
  }

  spec {
    selector = {
      app = "calibre-web-automated"
    }
    port {
      name        = "http"
      target_port = 8083
      port        = 80
      protocol    = "TCP"
    }
  }
}

module "calibre_ingress" {
  source          = "../../modules/kubernetes/ingress_factory"
  auth            = "required"
  dns_type        = "proxied"
  namespace       = kubernetes_namespace.ebooks.metadata[0].name
  name            = "calibre"
  tls_secret_name = var.tls_secret_name
  extra_annotations = {
    "gethomepage.dev/enabled"         = "true"
    "gethomepage.dev/description"     = "Book library"
    "gethomepage.dev/group"           = "Media & Entertainment"
    "gethomepage.dev/icon"            = "calibre-web.png"
    "gethomepage.dev/name"            = "Calibre"
    "gethomepage.dev/widget.type"     = "calibreweb"
    "gethomepage.dev/widget.url"      = "http://calibre.ebooks.svc.cluster.local"
    "gethomepage.dev/widget.username" = local.calibre_homepage_credentials["calibre-web"]["username"]
    "gethomepage.dev/widget.password" = local.calibre_homepage_credentials["calibre-web"]["password"]
    "gethomepage.dev/pod-selector"    = ""
  }
}

# Stacks - Anna's Archive Download Manager
resource "kubernetes_deployment" "annas-archive-stacks" {
  metadata {
    name      = "annas-archive-stacks"
    namespace = kubernetes_namespace.ebooks.metadata[0].name
    labels = {
      # Deliberately NOT sablier-enrolled (un-enrolled 2026-07-14, Viktor):
      # book-search consumes this service SERVER-SIDE via ClusterIP
      # (STACKS_URL in book-search/backend/annas.py) — that path can never
      # trigger a sablier wake, so a parked instance silently kills the
      # Anna's Archive download pipeline. Always-on; do not re-enroll.
      app  = "annas-archive-stacks"
      tier = local.tiers.edge
    }
  }
  spec {
    replicas = 1
    selector {
      match_labels = {
        app = "annas-archive-stacks"
      }
    }
    template {
      metadata {
        labels = {
          app = "annas-archive-stacks"
        }
      }
      spec {
        container {
          image = "zelest/stacks:latest"
          name  = "annas-archive-stacks"
          resources {
            requests = {
              cpu    = "10m"
              memory = "384Mi"
            }
            limits = {
              memory = "384Mi"
            }
          }
          port {
            container_port = 7788
          }
          liveness_probe {
            http_get {
              path = "/api/version"
              port = 7788
            }
            initial_delay_seconds = 15
            period_seconds        = 30
            timeout_seconds       = 5
            failure_threshold     = 3
          }
          volume_mount {
            name       = "config"
            mount_path = "/opt/stacks/config"
          }
          volume_mount {
            name       = "ingest"
            mount_path = "/opt/stacks/download"
          }
        }
        volume {
          name = "config"
          persistent_volume_claim {
            claim_name = module.nfs_calibre_stacks_config_host.claim_name
          }
        }
        volume {
          name = "ingest"
          persistent_volume_claim {
            claim_name = module.nfs_calibre_ingest_host.claim_name
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
    ]
  }
}

resource "kubernetes_service" "annas-archive-stacks" {
  metadata {
    name      = "annas-archive-stacks"
    namespace = kubernetes_namespace.ebooks.metadata[0].name
    labels = {
      "app" = "annas-archive-stacks"
    }
  }

  spec {
    selector = {
      app = "annas-archive-stacks"
    }
    port {
      name        = "http"
      port        = "80"
      target_port = 7788
    }
  }
}

module "stacks_ingress" {
  source          = "../../modules/kubernetes/ingress_factory"
  dns_type        = "proxied"
  namespace       = kubernetes_namespace.ebooks.metadata[0].name
  name            = "stacks"
  service_name    = "annas-archive-stacks"
  tls_secret_name = var.tls_secret_name
  auth            = "required"
  extra_annotations = {
    "gethomepage.dev/enabled" = "false"
  }
}

# Audiobookshelf Deployment
resource "kubernetes_deployment" "audiobookshelf" {
  metadata {
    name      = "audiobookshelf"
    namespace = kubernetes_namespace.ebooks.metadata[0].name
    labels = {
      app  = "audiobookshelf"
      tier = local.tiers.edge
    }
    annotations = {
      "reloader.stakater.com/search" = "true"
    }
  }
  spec {
    replicas = 1
    strategy {
      type = "Recreate"
    }
    selector {
      match_labels = {
        app = "audiobookshelf"
      }
    }
    template {
      metadata {
        labels = {
          app = "audiobookshelf"
        }
      }
      spec {
        container {
          image = "ghcr.io/advplyr/audiobookshelf:2.33.1"
          name  = "audiobookshelf"

          port {
            container_port = 80
          }
          liveness_probe {
            http_get {
              path = "/healthcheck"
              port = 80
            }
            initial_delay_seconds = 15
            period_seconds        = 30
            timeout_seconds       = 5
            failure_threshold     = 5
          }
          readiness_probe {
            http_get {
              path = "/healthcheck"
              port = 80
            }
            initial_delay_seconds = 5
            period_seconds        = 30
            timeout_seconds       = 5
            failure_threshold     = 3
          }
          volume_mount {
            name       = "audiobooks"
            mount_path = "/audiobooks"
          }
          volume_mount {
            name       = "podcasts"
            mount_path = "/podcasts"
          }
          volume_mount {
            name       = "config"
            mount_path = "/config"
          }
          volume_mount {
            name       = "metadata"
            mount_path = "/metadata"
          }
          # DO NOT LOWER back to 256Mi on a right-sizing pass. Idle usage
          # (~75Mi) badly understates the requirement: a library scan that
          # IMPORTS new books is the real peak, and at 256Mi it OOMKills
          # (exit 137, observed 2026-08-08 importing 9 audiobooks). Scans
          # that find nothing new stay near idle, so krr/VPA-style
          # recommendations sampled between imports will keep suggesting a
          # cut — the headroom is deliberate and only exercised on import.
          # Requests stay at the idle figure so this remains Burstable, per
          # the tier 4-aux convention; only the ceiling is raised.
          resources {
            requests = {
              cpu    = "15m"
              memory = "64Mi"
            }
            limits = {
              memory = "512Mi"
            }
          }
        }
        volume {
          name = "audiobooks"
          persistent_volume_claim {
            claim_name = module.nfs_audiobookshelf_audiobooks_host.claim_name
          }
        }
        volume {
          name = "podcasts"
          persistent_volume_claim {
            claim_name = module.nfs_audiobookshelf_podcasts_host.claim_name
          }
        }
        volume {
          name = "config"
          persistent_volume_claim {
            claim_name = kubernetes_persistent_volume_claim.abs_config_proxmox.metadata[0].name
          }
        }
        volume {
          name = "metadata"
          persistent_volume_claim {
            claim_name = module.nfs_audiobookshelf_metadata_host.claim_name
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
    ]
  }
}

resource "kubernetes_service" "audiobookshelf" {
  metadata {
    name      = "audiobookshelf"
    namespace = kubernetes_namespace.ebooks.metadata[0].name
    labels = {
      "app" = "audiobookshelf"
    }
  }

  spec {
    selector = {
      app = "audiobookshelf"
    }
    port {
      name        = "http"
      target_port = 80
      port        = 80
      protocol    = "TCP"
    }
  }
}

module "audiobookshelf_ingress" {
  source = "../../modules/kubernetes/ingress_factory"
  # auth = "app": Audiobookshelf has its own user/password login + API
  # tokens used by the iOS/Android Audiobookshelf app. Authentik forward-auth
  # was 302-ing the mobile clients; ABS's own auth gates users.
  auth            = "app"
  dns_type        = "non-proxied"
  namespace       = kubernetes_namespace.ebooks.metadata[0].name
  name            = "audiobookshelf"
  tls_secret_name = var.tls_secret_name
  extra_annotations = {
    "gethomepage.dev/enabled"      = "true"
    "gethomepage.dev/name"         = "Audiobookshelf"
    "gethomepage.dev/description"  = "Audiobook library"
    "gethomepage.dev/icon"         = "audiobookshelf.png"
    "gethomepage.dev/group"        = "Media & Entertainment"
    "gethomepage.dev/pod-selector" = ""
    "gethomepage.dev/widget.type"  = "audiobookshelf"
    "gethomepage.dev/widget.url"   = "http://audiobookshelf.ebooks.svc.cluster.local"
    "gethomepage.dev/widget.key"   = local.audiobookshelf_homepage_credentials["audiobookshelf"]["token"]
  }
}

# Book-Search Deployment
resource "kubernetes_deployment" "book_search" {
  metadata {
    name      = "book-search"
    namespace = kubernetes_namespace.ebooks.metadata[0].name
    labels = {
      app  = "book-search"
      tier = local.tiers.edge
    }
  }
  spec {
    replicas = 1
    selector {
      match_labels = {
        app = "book-search"
      }
    }
    template {
      metadata {
        labels = {
          app = "book-search"
        }
      }
      spec {
        container {
          image = "viktorbarzin/book-search:latest"
          name  = "book-search"

          port {
            container_port = 8000
          }
          env {
            name  = "QBITTORRENT_URL"
            value = "http://qbittorrent.servarr.svc.cluster.local"
          }
          # Calibre-web shelf that Goodreads-sourced books are added to. The
          # shelf is public and owned by Anca's calibre-web user, which is what
          # lets the admin session book-search already holds write to it.
          env {
            name  = "GOODREADS_SHELF_ID"
            value = var.goodreads_shelf_id
          }
          env {
            name = "QBITTORRENT_PASS"
            value_from {
              secret_key_ref {
                name = "servarr-secrets"
                key  = "qbittorrent_password"
              }
            }
          }
          env {
            name  = "AUDIOBOOKSHELF_URL"
            value = "http://audiobookshelf.ebooks.svc.cluster.local"
          }
          env {
            name = "AUDIOBOOKSHELF_TOKEN"
            value_from {
              secret_key_ref {
                name = "servarr-secrets"
                key  = "audiobookshelf_api_token"
              }
            }
          }
          env {
            name = "MAM_EMAIL"
            value_from {
              secret_key_ref {
                name = "servarr-secrets"
                key  = "mam_email"
              }
            }
          }
          env {
            name = "MAM_PASSWORD"
            value_from {
              secret_key_ref {
                name = "servarr-secrets"
                key  = "mam_password"
              }
            }
          }
          env {
            name  = "CWA_INGEST_PATH"
            value = "/cwa-book-ingest"
          }
          env {
            name = "MAM_ID"
            value_from {
              secret_key_ref {
                name     = "servarr-secrets"
                key      = "mam_id"
                optional = true
              }
            }
          }
          env {
            name  = "MAM_ID_FILE"
            value = "/mam-farming/mam_id"
          }
          env {
            name = "API_KEY"
            value_from {
              secret_key_ref {
                name = "calibre-secrets"
                key  = "book_search_api_key"
              }
            }
          }
          env {
            name  = "SHORTCUT_ICLOUD_URL"
            value = ""
          }
          env {
            name  = "STACKS_DB_PATH"
            value = "/stacks-config/queue.db"
          }
          env {
            name  = "CALIBRE_WEB_USER"
            value = "admin"
          }
          env {
            name = "CALIBRE_WEB_PASS"
            value_from {
              secret_key_ref {
                name = "calibre-secrets"
                key  = "calibre_web_password"
              }
            }
          }
          env {
            name = "SMTP_HOST"
            # Use intra-cluster ClusterIP path — bypasses pfSense HAProxy +
            # PROXY v2 (the public path hairpins through HAProxy:587 →
            # NodePort → pod :5587 where Postfix's smtpd-proxy587 daemon
            # crashes ~50% of HAProxy healthchecks with
            # `smtpd_peer_hostaddr_to_sockaddr: ... Servname not supported`,
            # producing intermittent 6s TCP timeouts for clients that land
            # mid-respawn). The ClusterIP service points to pod port 587
            # (stock submission daemon, no PROXY) and is rock-solid (12/12
            # in <31ms vs 6/12 timeouts on the public path).
            # See docs/runbooks/mailserver-pfsense-haproxy.md.
            value = "mailserver.mailserver.svc.cluster.local"
          }
          env {
            name  = "SMTP_PORT"
            value = "587"
          }
          env {
            name  = "SMTP_USER"
            value = "calibre-web@viktorbarzin.me"
          }
          env {
            name  = "SMTP_FROM"
            value = "Calibre-Web <calibre-web@viktorbarzin.me>"
          }
          env {
            name = "SMTP_PASS"
            value_from {
              secret_key_ref {
                name = "calibre-secrets"
                key  = "smtp_password"
              }
            }
          }
          env {
            name = "SLACK_WEBHOOK_URL"
            value_from {
              secret_key_ref {
                name = "calibre-secrets"
                key  = "slack_webhook_url"
              }
            }
          }
          # VPN egress pilot — see var.book_search_proxy_url above for what this
          # is, why it is a measurement rather than a fix, and how to turn it
          # off. ALL_PROXY is the one that does the work: httpx runs with
          # trust_env=True and no client in the app passes proxies=/mounts=/
          # transport=, so ALL_PROXY becomes a single `all://` mount covering
          # http and https alike. HTTP_PROXY/HTTPS_PROXY carry the same value so
          # anything outside httpx (a library or subprocess added later) takes
          # the same route instead of quietly egressing from the home IP.
          env {
            name  = "ALL_PROXY"
            value = var.book_search_proxy_url
          }
          env {
            name  = "HTTP_PROXY"
            value = var.book_search_proxy_url
          }
          env {
            name  = "HTTPS_PROXY"
            value = var.book_search_proxy_url
          }
          # Bypass list. Inert while the proxy URL is "", so it stays put across
          # flips. myanonamouse.net is load-bearing: mam.py documents the MAM
          # session as ASN/IP-locked, and a UK exit changes both — worse, if
          # dynamicSeedbox.php then re-locks the session to the VPN address,
          # flipping the proxy back off breaks MAM a second time.
          # FQDN suffixes only: the match is against the full hostname, so a
          # bare short name (`calibre.ebooks`) would still take the tunnel — use
          # FQDNs in service URLs. No CIDRs either — httpx splits a NO_PROXY
          # entry on "/" and builds a malformed pattern, and the app makes no
          # raw-IP HTTP calls. Routing verified live in the pod, 2026-08-16:
          # in-cluster + MAM + localhost direct, libgen/annas/openlibrary via UK.
          env {
            name  = "NO_PROXY"
            value = ".svc.cluster.local,.cluster.local,localhost,127.0.0.1,myanonamouse.net,.viktorbarzin.me"
          }
          resources {
            requests = {
              cpu    = "10m"
              memory = "128Mi"
            }
            limits = {
              memory = "512Mi"
            }
          }
          liveness_probe {
            http_get {
              path = "/health"
              port = 8000
            }
            initial_delay_seconds = 10
            period_seconds        = 30
          }
          volume_mount {
            name       = "cwa-ingest"
            mount_path = "/cwa-book-ingest"
          }
          volume_mount {
            name       = "audiobooks"
            mount_path = "/audiobooks"
          }
          volume_mount {
            name       = "stacks-config"
            mount_path = "/stacks-config"
          }
          volume_mount {
            name       = "calibre-library"
            mount_path = "/calibre-library"
          }
          volume_mount {
            name       = "mam-farming"
            mount_path = "/mam-farming"
            read_only  = true
          }
        }
        volume {
          name = "cwa-ingest"
          persistent_volume_claim {
            claim_name = module.nfs_calibre_ingest_host.claim_name
          }
        }
        volume {
          name = "audiobooks"
          persistent_volume_claim {
            claim_name = module.nfs_audiobookshelf_audiobooks_host.claim_name
          }
        }
        volume {
          name = "calibre-library"
          persistent_volume_claim {
            claim_name = module.nfs_calibre_library_host.claim_name
          }
        }
        volume {
          name = "stacks-config"
          persistent_volume_claim {
            claim_name = module.nfs_calibre_stacks_config_host.claim_name
          }
        }
        volume {
          name = "mam-farming"
          persistent_volume_claim {
            claim_name = module.nfs_mam_farming_host.claim_name
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
    ]
  }
}

resource "kubernetes_service" "book_search" {
  metadata {
    name      = "book-search"
    namespace = kubernetes_namespace.ebooks.metadata[0].name
    labels = {
      app = "book-search"
    }
  }

  spec {
    selector = {
      app = "book-search"
    }
    port {
      name        = "http"
      port        = 80
      target_port = 8000
    }
  }
}

module "book_search_ingress" {
  source          = "../../modules/kubernetes/ingress_factory"
  dns_type        = "proxied"
  namespace       = kubernetes_namespace.ebooks.metadata[0].name
  name            = "book-search"
  tls_secret_name = var.tls_secret_name
  auth            = "required"
  extra_annotations = {
    "gethomepage.dev/enabled"      = "true"
    "gethomepage.dev/name"         = "Book Search"
    "gethomepage.dev/description"  = "Search & download books"
    "gethomepage.dev/icon"         = "audiobookshelf.png"
    "gethomepage.dev/group"        = "Media & Entertainment"
    "gethomepage.dev/pod-selector" = ""
  }
}

# API ingress - unprotected (API key auth handled by backend)
module "book_search_api_ingress" {
  source    = "../../modules/kubernetes/ingress_factory"
  namespace = kubernetes_namespace.ebooks.metadata[0].name
  name      = "book-search-api"
  # secondary/non-UI ingress: no homepage tile (dedupe sweep 2026-07-14)
  homepage_enabled = false
  host             = "book-search"
  service_name     = "book-search"
  tls_secret_name  = var.tls_secret_name
  # auth = "none": Book Search API endpoints — API key auth handled by backend; forward-auth would block downloads.
  auth         = "none"
  ingress_path = ["/api/download-url", "/api/download-status", "/api/send-to-kindle", "/shortcut"]
}

# ---------------------------------------------------------------------------- #
# Goodreads -> Calibre auto-ingest                                              #
#                                                                               #
# Design: pages.viktorbarzin.me/2026-08-16-goodreads-auto-ingest.html            #
#                                                                               #
# When Anca adds a book to her Goodreads to-read shelf it is matched, downloaded #
# and put on her calibre-web shelf, with nobody in the loop. Runs as its own     #
# small Deployment rather than inside the book-search pod so a slow feed or a    #
# stuck download cannot affect the interactive search UI.                        #
#                                                                               #
# Goodreads publishes no WebSub hub, so this polls — but the feed honours        #
# If-None-Match, so a check costs a few hundred bytes when nothing has changed   #
# and she gets her books within ~2 minutes of shelving them.                     #
# ---------------------------------------------------------------------------- #

# DB credentials from the Vault database engine (7-day rotation).
# Pre-req in dbaas: role + database `goodreads_sync`, Vault role
# `static-creds/pg-goodreads-sync`.
resource "kubernetes_manifest" "goodreads_db_external_secret" {
  field_manager {
    force_conflicts = true
  }
  manifest = {
    apiVersion = "external-secrets.io/v1"
    kind       = "ExternalSecret"
    metadata = {
      name      = "goodreads-sync-db-creds"
      namespace = kubernetes_namespace.ebooks.metadata[0].name
    }
    spec = {
      refreshInterval = "15m"
      secretStoreRef = {
        name = "vault-database"
        kind = "ClusterSecretStore"
      }
      target = {
        name = "goodreads-sync-db-creds"
        template = {
          metadata = {
            annotations = {
              "reloader.stakater.com/match" = "true"
            }
          }
          data = {
            GOODREADS_DATABASE_URL = "postgresql://goodreads_sync:{{ .password }}@postgresql.dbaas.svc.cluster.local:5432/goodreads_sync"
          }
        }
      }
      data = [{
        secretKey = "password"
        remoteRef = {
          key      = "database/static-creds/pg-goodreads-sync"
          property = "password"
        }
      }]
    }
  }
}

resource "kubernetes_deployment" "goodreads_sync" {
  metadata {
    name      = "goodreads-sync"
    namespace = kubernetes_namespace.ebooks.metadata[0].name
    labels = {
      app  = "goodreads-sync"
      tier = local.tiers.edge
    }
  }
  spec {
    replicas = 1
    selector {
      match_labels = {
        app = "goodreads-sync"
      }
    }
    # One writer only: the poller records one row per shelf item, and two
    # replicas would race to claim the same new book.
    strategy {
      type = "Recreate"
    }
    template {
      metadata {
        labels = {
          app = "goodreads-sync"
        }
      }
      spec {
        container {
          image   = "viktorbarzin/book-search:latest"
          name    = "goodreads-sync"
          command = ["python3", "-m", "backend.goodreads.runner"]

          env {
            name  = "GOODREADS_USER_ID"
            value = "33074940"
          }
          env {
            name  = "GOODREADS_SHELF"
            value = "to-read"
          }
          env {
            name  = "GOODREADS_POLL_SECONDS"
            value = "120"
          }
          env {
            name  = "GOODREADS_DOWNLOADS_ENABLED"
            value = var.goodreads_downloads_enabled
          }
          env {
            name  = "GOODREADS_SHELF_ID"
            value = var.goodreads_shelf_id
          }
          env {
            name  = "BOOK_SEARCH_URL"
            value = "http://book-search.ebooks.svc.cluster.local"
          }
          env {
            name = "API_KEY"
            value_from {
              secret_key_ref {
                name = "calibre-secrets"
                key  = "book_search_api_key"
              }
            }
          }
          env {
            name = "SLACK_WEBHOOK_URL"
            value_from {
              secret_key_ref {
                name = "calibre-secrets"
                key  = "slack_webhook_url"
              }
            }
          }
          env_from {
            secret_ref {
              name = "goodreads-sync-db-creds"
            }
          }
          # Follows book-search's egress pilot switch so both move together; the
          # measured result was that the UK exit changes nothing for these hosts,
          # so this is empty today.
          dynamic "env" {
            for_each = var.book_search_proxy_url == "" ? [] : [var.book_search_proxy_url]
            content {
              name  = "HTTPS_PROXY"
              value = env.value
            }
          }
          dynamic "env" {
            for_each = var.book_search_proxy_url == "" ? [] : [var.book_search_proxy_url]
            content {
              name  = "NO_PROXY"
              value = ".svc.cluster.local,.cluster.local,localhost,127.0.0.1,.viktorbarzin.me"
            }
          }

          resources {
            requests = {
              cpu    = "10m"
              memory = "64Mi"
            }
            limits = {
              memory = "256Mi"
            }
          }
        }
      }
    }
  }
}
