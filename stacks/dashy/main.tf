variable "tls_secret_name" {
  type      = string
  sensitive = true
}


module "tls_secret" {
  source          = "../../modules/kubernetes/setup_tls_secret"
  namespace       = kubernetes_namespace.dashy.metadata[0].name
  tls_secret_name = var.tls_secret_name
}

resource "kubernetes_namespace" "dashy" {
  metadata {
    name = "dashy"
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

resource "kubernetes_config_map" "config" {
  metadata {
    name      = "config"
    namespace = kubernetes_namespace.dashy.metadata[0].name

    annotations = {
      "reloader.stakater.com/match" = "true"
    }
  }

  data = {
    "conf.yml" = file("${path.module}/conf.yml")
  }
}

resource "kubernetes_deployment" "dashy" {
  metadata {
    name      = "dashy"
    namespace = kubernetes_namespace.dashy.metadata[0].name
    labels = {
      app  = "dashy"
      tier = local.tiers.aux
    }
    annotations = {
      "reloader.stakater.com/search" = "true"
    }
  }
  spec {
    # Disabled: reduce cluster memory pressure (2026-03-14 OOM incident)
    replicas = 0
    selector {
      match_labels = {
        app = "dashy"
      }
    }
    template {
      metadata {
        annotations = {
          # "diun.enable" = "true"
        }
        labels = {
          app = "dashy"
        }
      }
      spec {
        container {
          image = "lissy93/dashy:latest"
          name  = "dashy"

          resources {
            requests = {
              cpu    = "250m"
              memory = "1Gi"
            }
            limits = {
              memory = "1Gi"
            }
          }
          port {
            container_port = 8080
          }
          volume_mount {
            name       = "config"
            mount_path = "/app/user-data/"
          }
        }
        volume {
          name = "config"
          config_map {
            name = "config"
          }
        }
      }
    }
  }
  lifecycle {
    # KYVERNO_LIFECYCLE_V1: Kyverno admission webhook mutates dns_config with ndots=2
    ignore_changes = [spec[0].template[0].spec[0].dns_config]
  }
}

resource "kubernetes_service" "dashy" {
  metadata {
    name      = "dashy"
    namespace = kubernetes_namespace.dashy.metadata[0].name
    labels = {
      app = "dashy"
    }
  }

  spec {
    selector = {
      app = "dashy"
    }
    port {
      name        = "http"
      port        = 80
      target_port = 8080
    }
  }
}

module "ingress" {
  source          = "../../modules/kubernetes/ingress_factory"
  dns_type        = "proxied"
  namespace       = kubernetes_namespace.dashy.metadata[0].name
  name            = "dashy"
  tls_secret_name = var.tls_secret_name
  protected       = true # hidden as we use homepage now
}
