variable "tls_secret_name" {}
variable "tier" { type = string }

resource "kubernetes_namespace" "kms" {
  metadata {
    name = "kms"
    labels = {
      "istio-injection" : "disabled"
      tier = var.tier
    }
  }
}

module "tls_secret" {
  source          = "../setup_tls_secret"
  namespace       = kubernetes_namespace.kms.metadata[0].name
  tls_secret_name = var.tls_secret_name
}

resource "kubernetes_config_map" "kms-web-page" {
  metadata {
    name      = "kms-web-page-config"
    namespace = kubernetes_namespace.kms.metadata[0].name
  }
  data = {
    "index.html" = var.index_html
  }
}

resource "kubernetes_deployment" "kms-web-page" {
  metadata {
    name      = "kms-web-page"
    namespace = kubernetes_namespace.kms.metadata[0].name
    labels = {
      "app"                           = "kms-web-page"
      "kubernetes.io/cluster-service" = "true"
      tier                            = var.tier
    }
  }
  spec {
    replicas = 1
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
    name      = "kms"
    namespace = kubernetes_namespace.kms.metadata[0].name
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

module "ingress" {
  source          = "../ingress_factory"
  namespace       = kubernetes_namespace.kms.metadata[0].name
  name            = "kms"
  tls_secret_name = var.tls_secret_name
}

resource "kubernetes_deployment" "windows_kms" {
  metadata {
    name      = "kms"
    namespace = kubernetes_namespace.kms.metadata[0].name
    labels = {
      app  = "kms-service"
      tier = var.tier
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
    namespace = kubernetes_namespace.kms.metadata[0].name
    labels = {
      app = "kms-service"
    }
    annotations = {
      "metallb.universe.tf/allow-shared-ip" = "shared"
    }
  }

  spec {
    type                    = "LoadBalancer"
    external_traffic_policy = "Cluster"
    selector = {
      app = "kms-service"
    }
    port {
      port = "1688"
    }
  }
}
