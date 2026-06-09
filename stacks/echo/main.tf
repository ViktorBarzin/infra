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
      "keel.sh/enrolled" = "true"
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
    ignore_changes = [
      spec[0].template[0].spec[0].dns_config, # KYVERNO_LIFECYCLE_V1
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
  source = "../../modules/kubernetes/ingress_factory"
  # echo is a header-reflecting diagnostic — public so it's reachable for
  # forward-auth smoke-testing. Anyone visiting echo.viktorbarzin.me sees
  # exactly which X-authentik-* headers Traefik forwarded to backends.
  auth            = "public"
  dns_type        = "proxied"
  namespace       = kubernetes_namespace.echo.metadata[0].name
  name            = "echo"
  tls_secret_name = var.tls_secret_name
}
