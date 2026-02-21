variable "tls_secret_name" {}
variable "tier" { type = string }
variable "turn_secret" { type = string }
variable "public_ip" { type = string }

resource "kubernetes_namespace" "f1-stream" {
  metadata {
    name = "f1-stream"
    labels = {
      "istio-injection" : "disabled"
      tier = var.tier
    }
  }
}

resource "kubernetes_deployment" "f1-stream" {
  metadata {
    name      = "f1-stream"
    namespace = kubernetes_namespace.f1-stream.metadata[0].name
    labels = {
      app  = "f1-stream"
      tier = var.tier
    }
  }
  spec {
    replicas = 1
    selector {
      match_labels = {
        app = "f1-stream"
      }
    }
    template {
      metadata {
        labels = {
          app = "f1-stream"
        }
      }
      spec {
        container {
          image = "viktorbarzin/f1-stream:v1.2.8"
          name  = "f1-stream"
          resources {
            limits = {
              cpu    = "1"
              memory = "512Mi"
            }
            requests = {
              cpu    = "50m"
              memory = "128Mi"
            }
          }
          port {
            container_port = 8080
          }
          env {
            name  = "WEBAUTHN_RPID"
            value = "f1.viktorbarzin.me"
          }
          env {
            name  = "WEBAUTHN_ORIGIN"
            value = "https://f1.viktorbarzin.me"
          }
          env {
            name  = "WEBAUTHN_DISPLAY_NAME"
            value = "F1 Stream"
          }
          env {
            name  = "HEADLESS_EXTRACT_ENABLED"
            value = "true"
          }
          env {
            name  = "TURN_URL"
            value = "turn:${var.public_ip}:3478"
          }
          env {
            name  = "TURN_SHARED_SECRET"
            value = var.turn_secret
          }
          env {
            name  = "TURN_INTERNAL_URL"
            value = "turn:coturn.coturn.svc.cluster.local:3478"
          }
          volume_mount {
            name       = "data"
            mount_path = "/data"
          }
        }
        volume {
          name = "data"
          nfs {
            server = "10.0.10.15"
            path   = "/mnt/main/f1-stream"
          }
        }
      }
    }
  }
}


resource "kubernetes_service" "f1-stream" {
  metadata {
    name      = "f1"
    namespace = kubernetes_namespace.f1-stream.metadata[0].name
    labels = {
      "app" = "f1-stream"
    }
  }

  spec {
    selector = {
      app = "f1-stream"
    }
    port {
      port        = "80"
      target_port = "8080"
    }
  }
}

module "tls_secret" {
  source          = "../setup_tls_secret"
  namespace       = kubernetes_namespace.f1-stream.metadata[0].name
  tls_secret_name = var.tls_secret_name
}


module "ingress" {
  source          = "../ingress_factory"
  namespace       = kubernetes_namespace.f1-stream.metadata[0].name
  name            = "f1"
  tls_secret_name = var.tls_secret_name
  rybbit_site_id  = "7e69786f66d5"
}
