variable "tls_secret_name" {
  type      = string
  sensitive = true
}


resource "kubernetes_namespace" "echo" {
  metadata {
    name = "echo"
    labels = {
      "istio-injection" : "disabled"
      tier = local.tiers.edge
    }
  }
  lifecycle {
    # KYVERNO_LIFECYCLE_V1: goldilocks-vpa-auto-mode ClusterPolicy stamps this label on every namespace
    ignore_changes = [metadata[0].labels["goldilocks.fairwinds.com/vpa-update-mode"]]
  }
}

module "tls_secret" {
  source          = "../../modules/kubernetes/setup_tls_secret"
  namespace       = kubernetes_namespace.echo.metadata[0].name
  tls_secret_name = var.tls_secret_name
}

resource "kubernetes_deployment" "echo" {
  metadata {
    name      = "echo"
    namespace = kubernetes_namespace.echo.metadata[0].name
    labels = {
      app  = "echo"
      tier = local.tiers.edge
    }
  }
  spec {
    replicas = 1
    selector {
      match_labels = {
        app = "echo"
      }
    }
    template {
      metadata {
        labels = {
          app = "echo"
        }
        annotations = {
          "diun.enable"       = "true"
          "diun.include_tags" = "^\\d+$"
        }
      }
      spec {
        container {
          image = "mendhak/http-https-echo:36"
          name  = "echo"
          port {
            container_port = 8080
          }
          port {
            container_port = 8443
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
      }
    }
  }
  lifecycle {
    # KYVERNO_LIFECYCLE_V1: Kyverno admission webhook mutates dns_config with ndots=2
    ignore_changes = [spec[0].template[0].spec[0].dns_config]
  }
}

resource "kubernetes_service" "echo" {
  metadata {
    name      = "echo"
    namespace = kubernetes_namespace.echo.metadata[0].name
    labels = {
      "app" = "echo"
    }
  }

  spec {
    selector = {
      app = "echo"
    }
    port {
      name        = "http"
      port        = "80"
      target_port = "8080"
    }
  }
}

module "ingress" {
  source          = "../../modules/kubernetes/ingress_factory"
  dns_type        = "proxied"
  namespace       = kubernetes_namespace.echo.metadata[0].name
  name            = "echo"
  tls_secret_name = var.tls_secret_name
}
