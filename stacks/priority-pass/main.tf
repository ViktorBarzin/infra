variable "tls_secret_name" {
  type      = string
  sensitive = true
}

resource "kubernetes_namespace" "priority-pass" {
  metadata {
    name = "priority-pass"
    labels = {
      "istio-injection" = "disabled"
      tier              = local.tiers.aux
    }
  }
}

module "tls_secret" {
  source          = "../../modules/kubernetes/setup_tls_secret"
  namespace       = "priority-pass"
  tls_secret_name = var.tls_secret_name
}

resource "kubernetes_deployment" "priority-pass" {
  metadata {
    name      = "priority-pass"
    namespace = "priority-pass"
    labels = {
      run  = "priority-pass"
      tier = local.tiers.aux
    }
  }
  spec {
    replicas = 1
    selector {
      match_labels = {
        run = "priority-pass"
      }
    }
    template {
      metadata {
        labels = {
          run = "priority-pass"
        }
      }
      spec {
        image_pull_secrets {
          name = "registry-credentials"
        }
        container {
          name  = "frontend"
          image = "registry.viktorbarzin.me/priority-pass-frontend:v5"
          port {
            container_port = 3000
          }
          env {
            name  = "BACKEND_URL"
            value = "http://127.0.0.1:8000"
          }
          env {
            name  = "ORIGIN"
            value = "https://priority-pass.viktorbarzin.me"
          }
          resources {
            limits = {
              memory = "128Mi"
            }
            requests = {
              cpu    = "10m"
              memory = "128Mi"
            }
          }
        }
        container {
          name  = "backend"
          image = "registry.viktorbarzin.me/priority-pass-backend:v8"
          port {
            container_port = 8000
          }
          resources {
            limits = {
              memory = "512Mi"
            }
            requests = {
              cpu    = "10m"
              memory = "512Mi"
            }
          }
        }
      }
    }
  }
  lifecycle {
    ignore_changes = [spec[0].template[0].spec[0].dns_config]
  }
}

resource "kubernetes_service" "priority-pass" {
  metadata {
    name      = "priority-pass"
    namespace = "priority-pass"
    labels = {
      run = "priority-pass"
    }
  }
  spec {
    selector = {
      run = "priority-pass"
    }
    port {
      name        = "http"
      port        = 80
      target_port = 3000
    }
  }
}

module "ingress" {
  source          = "../../modules/kubernetes/ingress_factory"
  dns_type        = "proxied"
  namespace       = "priority-pass"
  name            = "priority-pass"
  tls_secret_name = var.tls_secret_name
  protected       = true
  max_body_size   = "10m"
}
