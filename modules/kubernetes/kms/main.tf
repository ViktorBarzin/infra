variable "tls_secret_name" {}

resource "kubernetes_namespace" "kms" {
  metadata {
    name = "kms"
  }
}

module "tls_secret" {
  source          = "../setup_tls_secret"
  namespace       = "kms"
  tls_secret_name = var.tls_secret_name
}

resource "kubernetes_config_map" "kms-web-page" {
  metadata {
    name      = "kms-web-page-config"
    namespace = "kms"
  }
  data = {
    "index.html" = var.index_html
  }
}

resource "kubernetes_deployment" "kms-web-page" {
  metadata {
    name      = "kms-web-page"
    namespace = "kms"
    labels = {
      "app"                           = "kms-web-page"
      "kubernetes.io/cluster-service" = "true"
    }
  }
  spec {
    replicas = 3
    selector {
      match_labels = {
        "app" = "kms-web-page"
      }
    }
    template {
      metadata {
        labels = {
          "app"                           = "kms-web-page"
          "kubernetes.io/cluster-service" = "true"
        }
      }
      spec {
        container {
          image             = "nginx"
          name              = "kms-web-page"
          image_pull_policy = "IfNotPresent"
          resources {
            limits = {
              cpu    = "0.5"
              memory = "512Mi"
            }
            requests = {
              cpu    = "0.5"
              memory = "512Mi"
            }
          }
          port {
            container_port = 80
            protocol       = "TCP"
          }
          volume_mount {
            name       = "config"
            mount_path = "/usr/share/nginx/html/"
          }
        }

        volume {
          name = "config"
          config_map {
            name = "kms-web-page-config"
            items {
              key  = "index.html"
              path = "index.html"
            }
          }
        }
      }
    }
  }
  depends_on = [kubernetes_config_map.kms-web-page]
}

resource "kubernetes_service" "kms-web-page" {
  metadata {
    name      = "kms-web-page"
    namespace = "kms"
    labels = {
      "app" = "kms-web-page"
    }
  }

  spec {
    selector = {
      "app" = "kms-web-page"
    }
    port {
      port     = "80"
      protocol = "TCP"
    }
  }
}

resource "kubernetes_ingress" "kms-web-page" {
  metadata {
    name      = "kms-web-page"
    namespace = "kms"
    annotations = {
      "kubernetes.io/ingress.class" = "nginx"
    }
  }

  spec {
    tls {
      hosts       = ["kms.viktorbarzin.me"]
      secret_name = var.tls_secret_name
    }
    rule {
      host = "kms.viktorbarzin.me"
      http {
        path {
          path = "/"
          backend {
            service_name = "kms-web-page"
            service_port = "80"
          }
        }
      }
    }
  }
}

resource "kubernetes_deployment" "windows_kms" {
  metadata {
    name      = "kms"
    namespace = "kms"
    labels = {
      app = "kms-service"
    }
  }
  spec {
    replicas = 1
    selector {
      match_labels = {
        app = "kms-service"
      }
    }
    template {
      metadata {
        labels = {
          app = "kms-service"
        }
      }
      spec {
        container {
          image = "kebe/vlmcsd:latest"
          name  = "windows-kms"
          resources {
            limits = {
              cpu    = "1"
              memory = "512Mi"
            }
            requests = {
              cpu    = "1"
              memory = "50Mi"
            }
          }
          port {
            container_port = 1688
          }
        }
      }
    }
  }
}

resource "kubernetes_service" "windows_kms" {
  metadata {
    name      = "windows-kms"
    namespace = "kms"
    labels = {
      "app" = "windows-kms"
    }
    annotations = {
      "metallb.universe.tf/allow-shared-ip" = "shared"
    }
  }

  spec {
    type                    = "LoadBalancer"
    external_traffic_policy = "Cluster"
    selector = {
      "app" = "windows-kms"
    }
    port {
      port = "1688"
    }
  }
}
