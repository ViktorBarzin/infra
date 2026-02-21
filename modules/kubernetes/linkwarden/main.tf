variable "tls_secret_name" {}
variable "tier" { type = string }
variable "postgresql_password" {}
variable "authentik_client_id" {}
variable "authentik_client_secret" {}

resource "kubernetes_namespace" "linkwarden" {
  metadata {
    name = "linkwarden"
    labels = {
      tier = var.tier
    }
  }
}

module "tls_secret" {
  source          = "../setup_tls_secret"
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
      tier = var.tier
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
            value = "postgresql://linkwarden:${var.postgresql_password}@postgresql.dbaas.svc.cluster.local:5432/linkwarden"
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
            value = var.authentik_client_id
          }
          env {
            name  = "AUTHENTIK_CLIENT_SECRET"
            value = var.authentik_client_secret
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
  source          = "../ingress_factory"
  namespace       = kubernetes_namespace.linkwarden.metadata[0].name
  name            = "linkwarden"
  tls_secret_name = var.tls_secret_name
}
