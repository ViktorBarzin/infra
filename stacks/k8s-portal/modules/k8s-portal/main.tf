variable "tls_secret_name" {}
variable "tier" { type = string }
variable "k8s_ca_cert" {
  type    = string
  default = ""
}

resource "kubernetes_namespace" "k8s_portal" {
  metadata {
    name = "k8s-portal"
    labels = {
      tier = var.tier
    }
  }
}

module "tls_secret" {
  source          = "../../../../modules/kubernetes/setup_tls_secret"
  namespace       = kubernetes_namespace.k8s_portal.metadata[0].name
  tls_secret_name = var.tls_secret_name
}

resource "kubernetes_config_map" "k8s_portal_config" {
  metadata {
    name      = "k8s-portal-config"
    namespace = kubernetes_namespace.k8s_portal.metadata[0].name
  }

  data = {
    "ca.crt" = var.k8s_ca_cert
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
    strategy {
      type = "Recreate"
    }
    revision_history_limit = 3
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
            mount_path = "/config/ca.crt"
            sub_path   = "ca.crt"
            read_only  = true
          }
          volume_mount {
            name       = "user-roles"
            mount_path = "/config/users.json"
            sub_path   = "users.json"
            read_only  = true
          }
          resources {
            requests = {
              cpu    = "10m"
              memory = "128Mi"
            }
            limits = {
              memory = "128Mi"
            }
          }
        }

        volume {
          name = "config"
          config_map {
            name = kubernetes_config_map.k8s_portal_config.metadata[0].name
          }
        }
        volume {
          name = "user-roles"
          config_map {
            name = "k8s-user-roles"
          }
        }
        dns_config {
          option {
            name  = "ndots"
            value = "2"
          }
        }
      }
    }
  }
  lifecycle {
    ignore_changes = [
      spec[0].template[0].spec[0].dns_config,
      spec[0].template[0].spec[0].container[0].image, # CI updates image tag
    ]
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
  source          = "../../../../modules/kubernetes/ingress_factory"
  dns_type        = "non-proxied"
  namespace       = kubernetes_namespace.k8s_portal.metadata[0].name
  name            = "k8s-portal"
  tls_secret_name = var.tls_secret_name
  protected       = true # Require Authentik login
  extra_annotations = {
    "gethomepage.dev/enabled"      = "true"
    "gethomepage.dev/name"         = "K8s Portal"
    "gethomepage.dev/description"  = "Kubernetes portal"
    "gethomepage.dev/icon"         = "kubernetes.png"
    "gethomepage.dev/group"        = "Core Platform"
    "gethomepage.dev/pod-selector" = ""
  }
}

# Unprotected ingress for the setup script and agent endpoint (needs to be curl-able without auth)
module "ingress_setup_script" {
  source          = "../../../../modules/kubernetes/ingress_factory"
  namespace       = kubernetes_namespace.k8s_portal.metadata[0].name
  name            = "k8s-portal-setup"
  host            = "k8s-portal"
  service_name    = "k8s-portal"
  ingress_path    = ["/setup/script", "/agent"]
  tls_secret_name = var.tls_secret_name
  protected       = false
}
