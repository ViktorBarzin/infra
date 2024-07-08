variable "tls_secret_name" {}
resource "kubernetes_namespace" "cyberchef" {
  metadata {
    name = "cyberchef"
  }
}

module "tls_secret" {
  source          = "../setup_tls_secret"
  namespace       = "cyberchef"
  tls_secret_name = var.tls_secret_name
}

resource "kubernetes_deployment" "cyberchef" {
  metadata {
    name      = "cyberchef"
    namespace = "cyberchef"
    labels = {
      app = "cyberchef"
    }
    annotations = {
      "reloader.stakater.com/search" = "true"
    }
  }
  spec {
    replicas = 1
    strategy {
      type = "RollingUpdate"
    }
    selector {
      match_labels = {
        app = "cyberchef"
      }
    }
    template {
      metadata {
        labels = {
          app = "cyberchef"
        }
      }
      spec {
        container {
          image = "mpepping/cyberchef"
          name  = "cyberchef"

          port {
            container_port = 8000
          }
        }
      }
    }
  }
}

resource "kubernetes_service" "cyberchef" {
  metadata {
    name      = "cyberchef"
    namespace = "cyberchef"
    labels = {
      "app" = "cyberchef"
    }
  }

  spec {
    selector = {
      app = "cyberchef"
    }
    port {
      name        = "http"
      target_port = 8000
      port        = 80
    }
  }
}

resource "kubernetes_ingress_v1" "cyberchef" {
  metadata {
    name      = "cyberchef"
    namespace = "cyberchef"
    annotations = {
      "kubernetes.io/ingress.class" = "nginx"
    }
  }

  spec {
    tls {
      hosts       = ["cc.viktorbarzin.me"]
      secret_name = var.tls_secret_name
    }
    rule {
      host = "cc.viktorbarzin.me"
      http {
        path {
          path = "/"
          backend {
            service {
              name = "cyberchef"
              port {
                number = 80
              }
            }
          }
        }
      }
    }
  }
}

