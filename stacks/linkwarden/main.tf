variable "tls_secret_name" {
  type = string
  sensitive = true
}
variable "linkwarden_postgresql_password" {
  type = string
  sensitive = true
}
variable "linkwarden_authentik_client_id" { type = string }
variable "linkwarden_authentik_client_secret" {
  type = string
  sensitive = true
}
variable "postgresql_host" { type = string }


resource "kubernetes_namespace" "linkwarden" {
  metadata {
    name = "linkwarden"
    labels = {
      tier = local.tiers.aux
    }
  }
}

module "tls_secret" {
  source          = "../../modules/kubernetes/setup_tls_secret"
  namespace       = kubernetes_namespace.linkwarden.metadata[0].name
  tls_secret_name = var.tls_secret_name
}

resource "random_string" "secret" {
  length           = 32
  special          = true
  override_special = "/@£$"
}

resource "kubernetes_deployment" "linkwarden" {
  metadata {
    name      = "linkwarden"
    namespace = kubernetes_namespace.linkwarden.metadata[0].name
    labels = {
      app  = "linkwarden"
      tier = local.tiers.aux
    }
    annotations = {
      "reloader.stakater.com/search" = "true"
    }
  }
  spec {
    replicas = 1
    selector {
      match_labels = {
        app = "linkwarden"
      }
    }
    template {
      metadata {
        labels = {
          app = "linkwarden"
        }
        annotations = {
          "diun.enable"       = "false"
          "diun.include_tags" = "latest"
        }
      }
      spec {
        container {
          image = "ghcr.io/linkwarden/linkwarden:latest"
          name  = "linkwarden"

          port {
            container_port = 3000
          }
          env {
            name  = "DATABASE_URL"
            value = "postgresql://linkwarden:${var.linkwarden_postgresql_password}@${var.postgresql_host}:5432/linkwarden"
          }
          env {
            name  = "NEXT_PUBLIC_AUTHENTIK_ENABLED"
            value = "true"
          }
          env {
            name  = "NEXTAUTH_SECRET"
            value = random_string.secret.result
          }
          env {
            name  = "NEXTAUTH_URL"
            value = "https://linkwarden.viktorbarzin.me/api/v1/auth"
          }
          env {
            name  = "AUTHENTIK_ISSUER"
            value = "https://authentik.viktorbarzin.me/application/o/linkwarden"
          }
          env {
            name  = "AUTHENTIK_CLIENT_ID"
            value = var.linkwarden_authentik_client_id
          }
          env {
            name  = "AUTHENTIK_CLIENT_SECRET"
            value = var.linkwarden_authentik_client_secret
          }
          resources {
            requests = {
              cpu    = "25m"
              memory = "256Mi"
            }
            limits = {
              cpu    = "500m"
              memory = "1536Mi"
            }
          }
        }
      }
    }
  }
}
resource "kubernetes_service" "linkwarden" {
  metadata {
    name      = "linkwarden"
    namespace = kubernetes_namespace.linkwarden.metadata[0].name
    labels = {
      app = "linkwarden"
    }
  }

  spec {
    selector = {
      app = "linkwarden"
    }
    port {
      name        = "linkwarden"
      port        = 80
      target_port = 3000
    }
  }
}

module "ingress" {
  source          = "../../modules/kubernetes/ingress_factory"
  namespace       = kubernetes_namespace.linkwarden.metadata[0].name
  name            = "linkwarden"
  tls_secret_name = var.tls_secret_name
}
