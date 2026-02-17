variable "tls_secret_name" {}
variable "tier" { type = string }

resource "kubernetes_namespace" "k8s_portal" {
  metadata {
    name = "k8s-portal"
    labels = {
      tier = var.tier
    }
  }
}

module "tls_secret" {
  source          = "../setup_tls_secret"
  namespace       = kubernetes_namespace.k8s_portal.metadata[0].name
  tls_secret_name = var.tls_secret_name
}

resource "kubernetes_config_map" "k8s_portal_config" {
  metadata {
    name      = "k8s-portal-config"
    namespace = kubernetes_namespace.k8s_portal.metadata[0].name
  }

  data = {
    # CA cert extracted from kubeconfig — will be populated with cluster CA cert
    "ca.crt" = ""
  }
}

resource "kubernetes_deployment" "k8s_portal" {
  metadata {
    name      = "k8s-portal"
    namespace = kubernetes_namespace.k8s_portal.metadata[0].name
    labels = {
      app  = "k8s-portal"
      tier = var.tier
    }
  }

  spec {
    replicas = 1
    selector {
      match_labels = {
        app = "k8s-portal"
      }
    }

    template {
      metadata {
        labels = {
          app = "k8s-portal"
        }
      }

      spec {
        container {
          name  = "portal"
          image = "viktorbarzin/k8s-portal:latest"
          port {
            container_port = 3000
          }

          volume_mount {
            name       = "config"
            mount_path = "/config"
            read_only  = true
          }
        }

        volume {
          name = "config"
          config_map {
            name = kubernetes_config_map.k8s_portal_config.metadata[0].name
          }
        }
      }
    }
  }
}

resource "kubernetes_service" "k8s_portal" {
  metadata {
    name      = "k8s-portal"
    namespace = kubernetes_namespace.k8s_portal.metadata[0].name
  }

  spec {
    selector = {
      app = "k8s-portal"
    }
    port {
      port        = 80
      target_port = 3000
    }
  }
}

module "ingress" {
  source          = "../ingress_factory"
  namespace       = kubernetes_namespace.k8s_portal.metadata[0].name
  name            = "k8s-portal"
  tls_secret_name = var.tls_secret_name
  protected       = true # Require Authentik login
}

# Unprotected ingress for the setup script (needs to be curl-able without auth)
module "ingress_setup_script" {
  source          = "../ingress_factory"
  namespace       = kubernetes_namespace.k8s_portal.metadata[0].name
  name            = "k8s-portal-setup"
  host            = "k8s-portal"
  service_name    = "k8s-portal"
  ingress_path    = ["/setup/script"]
  tls_secret_name = var.tls_secret_name
  protected       = false
}
