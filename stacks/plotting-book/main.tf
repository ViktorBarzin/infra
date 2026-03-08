variable "tls_secret_name" {
  type = string
  sensitive = true
}
variable "plotting_book_session_secret" {
  type      = string
  sensitive = true
}
variable "plotting_book_google_client_id" {
  type      = string
  sensitive = true
}
variable "plotting_book_google_client_secret" {
  type      = string
  sensitive = true
}


resource "kubernetes_namespace" "plotting-book" {
  metadata {
    name = "plotting-book"
    labels = {
      "istio-injection" : "disabled"
      tier = local.tiers.aux
    }
  }
}

module "tls_secret" {
  source          = "../../modules/kubernetes/setup_tls_secret"
  namespace       = kubernetes_namespace.plotting-book.metadata[0].name
  tls_secret_name = var.tls_secret_name
}

resource "kubernetes_persistent_volume_claim" "plotting-book-data" {
  metadata {
    name      = "plotting-book-data"
    namespace = kubernetes_namespace.plotting-book.metadata[0].name
  }
  spec {
    access_modes       = ["ReadWriteOnce"]
    storage_class_name = "iscsi-truenas"
    resources {
      requests = {
        storage = "1Gi"
      }
    }
  }
}

resource "kubernetes_deployment" "plotting-book" {
  metadata {
    name      = "plotting-book"
    namespace = kubernetes_namespace.plotting-book.metadata[0].name
    labels = {
      app  = "plotting-book"
      tier = local.tiers.aux
    }
  }
  lifecycle {
    ignore_changes = [
      spec[0].template[0].spec[0].container[0].image,
    ]
  }
  spec {
    replicas = 1
    selector {
      match_labels = {
        app = "plotting-book"
      }
    }
    template {
      metadata {
        labels = {
          app = "plotting-book"
        }
      }
      spec {
        volume {
          name = "data"
          persistent_volume_claim {
            claim_name = kubernetes_persistent_volume_claim.plotting-book-data.metadata[0].name
          }
        }
        container {
          image = "ancamilea/book-plotter:latest"
          # image = "viktorbarzin/book-plotter:7"
          name              = "plotting-book"
          image_pull_policy = "Always"
          env {
            name  = "SESSION_SECRET"
            value = var.plotting_book_session_secret
          }
          env {
            name  = "GOOGLE_CLIENT_ID"
            value = var.plotting_book_google_client_id
          }
          env {
            name  = "GOOGLE_CLIENT_SECRET"
            value = var.plotting_book_google_client_secret
          }
          env {
            name  = "GOOGLE_CALLBACK_URL"
            value = "https://plotting-book.viktorbarzin.me/api/auth/google/callback"
          }
          env {
            name  = "DB_PATH"
            value = "/data/database.sqlite"
          }
          volume_mount {
            name       = "data"
            mount_path = "/data"
          }
          port {
            container_port = 3001
          }
          resources {
            requests = {
              memory = "32Mi"
              cpu    = "10m"
            }
            limits = {
              memory = "256Mi"
              cpu    = "100m"
            }
          }
        }
      }
    }
  }
}

resource "kubernetes_service" "plotting-book" {
  metadata {
    name      = "plotting-book"
    namespace = kubernetes_namespace.plotting-book.metadata[0].name
    labels = {
      "app" = "plotting-book"
    }
  }

  spec {
    selector = {
      app = "plotting-book"
    }
    port {
      name        = "http"
      port        = 80
      target_port = 3001
    }
  }
}

module "ingress" {
  source          = "../../modules/kubernetes/ingress_factory"
  namespace       = kubernetes_namespace.plotting-book.metadata[0].name
  name            = "plotting-book"
  tls_secret_name = var.tls_secret_name

  custom_content_security_policy = "default-src 'self' blob: data:; img-src 'self' data: blob:; style-src 'self' 'unsafe-inline'; script-src 'self' 'unsafe-inline' 'unsafe-eval' blob:; worker-src 'self' blob:; connect-src 'self' blob: https://accounts.google.com; form-action 'self' https://accounts.google.com; frame-ancestors 'self' *.viktorbarzin.me viktorbarzin.me"
  extra_annotations = {
    "gethomepage.dev/enabled"      = "true"
    "gethomepage.dev/name"         = "Plotting Book"
    "gethomepage.dev/description"  = "Interactive fiction"
    "gethomepage.dev/icon"         = "mdi-book-open-variant"
    "gethomepage.dev/group"        = "Other"
    "gethomepage.dev/pod-selector" = ""
  }
}

# Sealed Secrets — encrypted secrets safe to commit to git
resource "kubernetes_manifest" "sealed_secrets" {
  for_each = fileset(path.module, "sealed-*.yaml")
  manifest = yamldecode(file("${path.module}/${each.value}"))
}
