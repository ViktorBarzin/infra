variable "tls_secret_name" {}

resource "kubernetes_namespace" "openid_help_page" {
  metadata {
    name = "openid-help-page"
  }
}

module "tls_secret" {
  source          = "../setup_tls_secret"
  namespace       = "openid-help-page"
  tls_secret_name = var.tls_secret_name
}

resource "kubernetes_deployment" "openid_help_page" {
  metadata {
    name      = "openid-help-page"
    namespace = "openid-help-page"
    labels = {
      app = "openid-help-page"
    }
  }
  spec {
    replicas = 3
    selector {
      match_labels = {
        app = "openid-help-page"
      }
    }
    template {
      metadata {
        labels = {
          app = "openid-help-page"
        }
      }
      spec {
        container {
          image = "viktorbarzin/openid-create-account-help-webpage:latest"
          name  = "openid-help-page"
          resources {
            limits = {
              cpu    = "0.5"
              memory = "512Mi"
            }
            requests = {
              cpu    = "250m"
              memory = "50Mi"
            }
          }
          port {
            container_port = 80
          }
        }
      }
    }
  }
}

resource "kubernetes_service" "openid_help_page" {
  metadata {
    name      = "openid-help-page"
    namespace = "openid-help-page"
  }

  spec {
    port {
      name        = "service-port"
      protocol    = "TCP"
      port        = 80
      target_port = "80"
    }

    selector = {
      app = "openid-help-page"
    }
    type             = "ClusterIP"
    session_affinity = "None"
  }
}

resource "kubernetes_ingress_v1" "openid_help_page" {
  metadata {
    name      = "openid-help-page"
    namespace = "openid-help-page"
    annotations = {
      "kubernetes.io/ingress.class" = "nginx"
    }
  }

  spec {
    tls {
      hosts       = ["kubectl.viktorbarzin.me"]
      secret_name = var.tls_secret_name
    }
    rule {
      host = "kubectl.viktorbarzin.me"
      http {
        path {
          path = "/"
          backend {
            service {
              name = "openid-help-page"
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
