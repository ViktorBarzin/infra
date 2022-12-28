variable "tls_secret_name" {}

resource "kubernetes_namespace" "echo" {
  metadata {
    name = "echo"
  }
}

module "tls_secret" {
  source          = "../setup_tls_secret"
  namespace       = "echo"
  tls_secret_name = var.tls_secret_name
}

resource "kubernetes_deployment" "echo" {
  metadata {
    name      = "echo"
    namespace = "echo"
    labels = {
      run = "echo"
    }
  }
  spec {
    replicas = 1
    selector {
      match_labels = {
        run = "echo"
      }
    }
    template {
      metadata {
        labels = {
          run = "echo"
        }
      }
      spec {
        container {
          image = "mendhak/http-https-echo"
          name  = "echo"
          port {
            container_port = 80
          }
          port {
            container_port = 443
          }
        }
      }
    }
  }
}

resource "kubernetes_service" "echo" {
  metadata {
    name      = "echo"
    namespace = "echo"
    labels = {
      "run" = "echo"
    }
  }

  spec {
    selector = {
      run = "echo"
    }
    port {
      name        = "http"
      port        = "80"
      target_port = "80"
    }
  }
}

resource "kubernetes_ingress_v1" "echo" {
  metadata {
    name      = "echo"
    namespace = "echo"

    annotations = {
      "kubernetes.io/ingress.class" = "nginx"
    }
  }

  spec {
    tls {
      hosts       = ["echo.viktorbarzin.me"]
      secret_name = var.tls_secret_name
    }
    rule {
      host = "echo.viktorbarzin.me"
      http {
        path {
          path = "/"
          backend {
            service {
              name = "echo"
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
