variable "tls_secret_name" {
  type      = string
  sensitive = true
}
variable "nfs_server" { type = string }
variable "redis_host" { type = string }
variable "mysql_host" { type = string }

data "vault_kv_secret_v2" "secrets" {
  mount = "secret"
  name  = "paperless-ngx"
}

locals {
  homepage_credentials = jsondecode(data.vault_kv_secret_v2.secrets.data["homepage_credentials"])
}


resource "kubernetes_namespace" "paperless-ngx" {
  metadata {
    name = "paperless-ngx"
    labels = {
      tier               = local.tiers.edge
      "keel.sh/enrolled" = "true"
    }
    # labels = {
    #   "istio-injection" : "enabled"
    # }
  }
  lifecycle {
    # KYVERNO_LIFECYCLE_V1: goldilocks-vpa-auto-mode ClusterPolicy stamps this label on every namespace
    ignore_changes = [metadata[0].labels["goldilocks.fairwinds.com/vpa-update-mode"]]
  }
}

resource "kubernetes_manifest" "external_secret" {
  field_manager {
    force_conflicts = true
  }
  manifest = {
    apiVersion = "external-secrets.io/v1"
    kind       = "ExternalSecret"
    metadata = {
      name      = "paperless-ngx-secrets"
      namespace = "paperless-ngx"
    }
    spec = {
      refreshInterval = "15m"
      secretStoreRef = {
        name = "vault-kv"
        kind = "ClusterSecretStore"
      }
      target = {
        name = "paperless-ngx-secrets"
      }
      dataFrom = [{
        extract = {
          key = "paperless-ngx"
        }
      }]
    }
  }
  depends_on = [kubernetes_namespace.paperless-ngx]
}
module "tls_secret" {
  source          = "../../modules/kubernetes/setup_tls_secret"
  namespace       = kubernetes_namespace.paperless-ngx.metadata[0].name
  tls_secret_name = var.tls_secret_name
}


resource "kubernetes_persistent_volume_claim" "data_encrypted" {
  wait_until_bound = false
  metadata {
    name      = "paperless-ngx-data-encrypted"
    namespace = kubernetes_namespace.paperless-ngx.metadata[0].name
    annotations = {
      "resize.topolvm.io/threshold"     = "10%"
      "resize.topolvm.io/increase"      = "100%"
      "resize.topolvm.io/storage_limit" = "80Gi"
    }
  }
  spec {
    access_modes       = ["ReadWriteOnce"]
    storage_class_name = "proxmox-lvm-encrypted"
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


resource "kubernetes_deployment" "paperless-ngx" {
  metadata {
    name      = "paperless-ngx"
    namespace = kubernetes_namespace.paperless-ngx.metadata[0].name
    labels = {
      app  = "paperless-ngx"
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
        app = "paperless-ngx"
      }
    }
    template {
      metadata {
        labels = {
          app = "paperless-ngx"
        }
        annotations = {
          "diun.enable"                    = "true"
          "diun.include_tags"              = "^\\d+(?:\\.\\d+)?(?:\\.\\d+)?$"
          "dependency.kyverno.io/wait-for" = "mysql.dbaas:3306,redis-master.redis:6379"
        }
      }
      spec {
        container {
          image = "ghcr.io/paperless-ngx/paperless-ngx:2.20.14"
          name  = "paperless-ngx"
          env {
            name = "PAPERLESS_REDIS"
            // If redis gets stuck, try deleting the locks files in log dir
            value = "redis://${var.redis_host}"
          }
          env {
            name  = "PAPERLESS_REDIS_PREFIX"
            value = "paperless-ngx"
          }
          env {
            name  = "PAPERLESS_DBENGINE"
            value = "mariadb"
          }
          env {
            name  = "PAPERLESS_DBHOST"
            value = var.mysql_host
          }
          env {
            name  = "PAPERLESS_DBNAME"
            value = "paperless-ngx"
          }
          env {
            name  = "PAPERLESS_DBUSER"
            value = "paperless-ngx"
          }
          env {
            name = "PAPERLESS_DBPASS"
            value_from {
              secret_key_ref {
                name = "paperless-ngx-secrets"
                key  = "db_password"
              }
            }
          }
          env {
            name  = "PAPERLESS_CSRF_TRUSTED_ORIGINS"
            value = "https://paperless-ngx.viktorbarzin.me,https://pdf.viktorbarzin.me"
          }
          env {
            name  = "PAPERLESS_DEBUG"
            value = "false"
          }
          env {
            name  = "PAPERLESS_MEDIA_ROOT"
            value = "../data"
          }
          env {
            name  = "PAPERLESS_OCR_USER_ARGS"
            value = "{\"invalidate_digital_signatures\": true}"
          }
          # OCR language(s) used per document. bul+eng covers the Bulgarian
          # (Cyrillic) + English document set being imported (e.g. emo's
          # archive). Multiple langs => tesseract tries all; "+" not " ".
          env {
            name  = "PAPERLESS_OCR_LANGUAGE"
            value = "bul+eng"
          }
          # Language data packages installed at container start (space-
          # separated). The image ships eng (+deu/fra/ita/spa); bul must be
          # apt-installed here so OCR_LANGUAGE=bul+eng resolves.
          env {
            name  = "PAPERLESS_OCR_LANGUAGES"
            value = "bul eng"
          }
          # Office/email documents (.doc/.docx/.xls/.xlsx/.ppt/.pptx/.odt/.eml/
          # .msg) are converted via Apache Tika (text+metadata) + Gotenberg
          # (-> PDF) so paperless can archive/OCR/index them. Needed for emo's
          # work-PC document set (~4.9k Office files). Endpoints = the tika /
          # gotenberg deployments defined below in this stack.
          env {
            name  = "PAPERLESS_TIKA_ENABLED"
            value = "1"
          }
          env {
            name  = "PAPERLESS_TIKA_ENDPOINT"
            value = "http://tika.paperless-ngx.svc.cluster.local:9998"
          }
          env {
            name  = "PAPERLESS_TIKA_GOTENBERG_ENDPOINT"
            value = "http://gotenberg.paperless-ngx.svc.cluster.local:3000"
          }
          # Processing concurrency, tuned for the bulk Emo import (~13.7k docs).
          # 2 workers = 2 docs in parallel (≈2x throughput); kept modest because
          # archive writes land on the shared sdc HDD that etcd also uses (IO
          # storm risk, code-oflt). 2 threads/worker speeds per-doc OCR using the
          # node's spare CPU. Watch etcd apply latency; dial workers back to 1 if
          # it degrades. Revert both to defaults once the import is done.
          env {
            name  = "PAPERLESS_TASK_WORKERS"
            value = "4"
          }
          env {
            name  = "PAPERLESS_THREADS_PER_WORKER"
            value = "1"
          }
          # Skip the redundant OCR'd archive PDF for inputs that already carry a
          # text layer (born-digital PDFs + office->PDF via Gotenberg). Big
          # speed/IO saver for emo's work-doc set; scanned docs still OCR+archive.
          env {
            name  = "PAPERLESS_OCR_SKIP_ARCHIVE_FILE"
            value = "with_text"
          }
          volume_mount {
            name       = "data"
            mount_path = "/usr/src/paperless/data"
          }

          resources {
            requests = {
              cpu    = "50m"
              memory = "2Gi"
            }
            limits = {
              memory = "8Gi"
            }
          }

          port {
            container_port = 8000
          }
        }
        volume {
          name = "data"
          persistent_volume_claim {
            claim_name = kubernetes_persistent_volume_claim.data_encrypted.metadata[0].name
          }
        }
      }
    }
  }
  lifecycle {
    ignore_changes = [
      spec[0].template[0].spec[0].dns_config, # KYVERNO_LIFECYCLE_V1
      metadata[0].annotations["keel.sh/policy"],
      metadata[0].annotations["keel.sh/trigger"],
      metadata[0].annotations["keel.sh/pollSchedule"], # KYVERNO_LIFECYCLE_V2
      metadata[0].annotations["keel.sh/match-tag"],
      spec[0].template[0].spec[0].container[0].image, # KEEL_IGNORE_IMAGE — Keel manages tag updates
      metadata[0].annotations["kubernetes.io/change-cause"],
      metadata[0].annotations["deployment.kubernetes.io/revision"],
      spec[0].template[0].metadata[0].annotations["keel.sh/update-time"], # KEEL_LIFECYCLE_V1
    ]
  }
}

resource "kubernetes_service" "paperless-ngx" {
  metadata {
    name      = "paperless-ngx"
    namespace = kubernetes_namespace.paperless-ngx.metadata[0].name
    labels = {
      "app" = "paperless-ngx"
    }
  }

  spec {
    selector = {
      app = "paperless-ngx"
    }
    port {
      name        = "http"
      target_port = 8000
      port        = 80
      protocol    = "TCP"
    }
  }
}

# --- Tika + Gotenberg: Office/email -> text/PDF conversion for paperless ---
# Apache Tika extracts text+metadata; Gotenberg renders Office formats to PDF.
# Paperless routes Office/email docs through these (PAPERLESS_TIKA_* above).
# Stateless (no PVC), pinned images. 3 replicas during the bulk import: a
# single LibreOffice instance 503s under concurrent paperless workers; the
# Service load-balances office conversions across the replicas.
resource "kubernetes_deployment" "gotenberg" {
  metadata {
    name      = "gotenberg"
    namespace = kubernetes_namespace.paperless-ngx.metadata[0].name
    labels = {
      app  = "gotenberg"
      tier = local.tiers.edge
    }
  }
  spec {
    replicas = 3
    selector {
      match_labels = {
        app = "gotenberg"
      }
    }
    template {
      metadata {
        labels = {
          app = "gotenberg"
        }
      }
      spec {
        container {
          image = "docker.io/gotenberg/gotenberg:8.25"
          name  = "gotenberg"
          # docker-compose `command:` == k8s `args` (overrides CMD, keeps the
          # image's tini ENTRYPOINT). Paperless's recommended hardening flags.
          args = [
            "gotenberg",
            "--chromium-disable-javascript=true",
            "--chromium-allow-list=file:///tmp/.*",
          ]
          port {
            container_port = 3000
          }
          resources {
            requests = {
              cpu    = "50m"
              memory = "256Mi"
            }
            limits = {
              memory = "1536Mi"
            }
          }
          readiness_probe {
            http_get {
              path = "/health"
              port = 3000
            }
            initial_delay_seconds = 5
            period_seconds        = 15
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
}

resource "kubernetes_service" "gotenberg" {
  metadata {
    name      = "gotenberg"
    namespace = kubernetes_namespace.paperless-ngx.metadata[0].name
    labels = {
      app = "gotenberg"
    }
  }
  spec {
    selector = {
      app = "gotenberg"
    }
    port {
      name        = "http"
      port        = 3000
      target_port = 3000
      protocol    = "TCP"
    }
  }
}

resource "kubernetes_deployment" "tika" {
  metadata {
    name      = "tika"
    namespace = kubernetes_namespace.paperless-ngx.metadata[0].name
    labels = {
      app  = "tika"
      tier = local.tiers.edge
    }
  }
  spec {
    replicas = 2
    selector {
      match_labels = {
        app = "tika"
      }
    }
    template {
      metadata {
        labels = {
          app = "tika"
        }
      }
      spec {
        container {
          image = "docker.io/apache/tika:3.3.1.0"
          name  = "tika"
          port {
            container_port = 9998
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
          readiness_probe {
            http_get {
              path = "/tika"
              port = 9998
            }
            initial_delay_seconds = 10
            period_seconds        = 15
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
}

resource "kubernetes_service" "tika" {
  metadata {
    name      = "tika"
    namespace = kubernetes_namespace.paperless-ngx.metadata[0].name
    labels = {
      app = "tika"
    }
  }
  spec {
    selector = {
      app = "tika"
    }
    port {
      name        = "http"
      port        = 9998
      target_port = 9998
      protocol    = "TCP"
    }
  }
}

module "ingress" {
  source = "../../modules/kubernetes/ingress_factory"
  # Paperless has a mobile app (`Paperless`) that uses /api/* with token
  # auth. The app can't follow Authentik 302s. Paperless's own login
  # gates the web UI.
  # auth = "app": Paperless mobile app uses /api/* with token auth; Paperless enforces app-layer login for web UI; backend manages authentication.
  auth            = "app"
  namespace       = kubernetes_namespace.paperless-ngx.metadata[0].name
  name            = "paperless-ngx"
  service_name    = "paperless-ngx"
  host            = "pdf"
  dns_type        = "proxied"
  tls_secret_name = var.tls_secret_name
  port            = 80
  extra_annotations = {
    "gethomepage.dev/enabled"     = "true"
    "gethomepage.dev/description" = "Document library"
    "gethomepage.dev/group"       = "Productivity"
    "gethomepage.dev/icon" : "paperless-ngx.png"
    "gethomepage.dev/name"        = "Paperless-ngx"
    "gethomepage.dev/widget.type" = "paperlessngx"
    "gethomepage.dev/widget.url"  = "http://paperless-ngx.paperless-ngx.svc.cluster.local"
    # "gethomepage.dev/widget.token"    = var.homepage_token
    "gethomepage.dev/widget.username" = local.homepage_credentials["paperless-ngx"]["username"]
    "gethomepage.dev/widget.password" = local.homepage_credentials["paperless-ngx"]["password"]
    "gethomepage.dev/widget.fields"   = "[\"total\"]"
    "gethomepage.dev/pod-selector"    = ""
    # gethomepage.dev/weight: 10 # optional
    # gethomepage.dev/instance: "public" # optional
  }
}

# CI retrigger 2026-05-16T13:42:57+00:00 — bulk enrollment apply (pipeline #689 killed)
# CI retrigger v2 2026-05-16T13:46:35+00:00
