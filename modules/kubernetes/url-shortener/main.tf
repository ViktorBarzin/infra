variable "tls_secret_name" {}
variable "geolite_license_key" {}
variable "api_key" {}
variable "domain" {
  default = "url.viktorbarzin.me"
}

resource "kubernetes_namespace" "shlink" {
  metadata {
    name = "url"
  }
}

module "tls_secret" {
  source          = "../setup_tls_secret"
  namespace       = "url"
  tls_secret_name = var.tls_secret_name
}

resource "kubernetes_deployment" "shlink" {
  metadata {
    name      = "shlink"
    namespace = "url"
    labels = {
      run = "shlink"
    }
  }
  spec {
    replicas = 1
    selector {
      match_labels = {
        run = "shlink"
      }
    }
    template {
      metadata {
        labels = {
          run = "shlink"
        }
      }
      spec {
        container {
          image = "shlinkio/shlink:stable"
          name  = "shlink"
          env {
            name  = "SHORT_DOMAIN_HOST"
            value = var.domain
          }
          env {
            name  = "SHORT_DOMAIN_SCHEMA"
            value = "https"
          }
          env {
            name  = "GEOLITE_LICENSE_KEY"
            value = var.geolite_license_key
          }
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
            container_port = 8080
          }
        }
      }
    }
  }
}

resource "kubernetes_service" "shlink" {
  metadata {
    name      = "shlink"
    namespace = "url"
    labels = {
      "run" = "shlink"
    }
  }

  spec {
    selector = {
      run = "shlink"
    }
    port {
      name        = "http"
      port        = "80"
      target_port = "8080"
    }
  }
}

resource "kubernetes_ingress" "shlink" {
  metadata {
    name      = "shlink-ingress"
    namespace = "url"
    annotations = {
      "kubernetes.io/ingress.class" = "nginx"
    }
  }

  spec {
    tls {
      hosts       = ["url.viktorbarzin.me"]
      secret_name = var.tls_secret_name
    }
    rule {
      host = "url.viktorbarzin.me"
      http {
        path {
          path = "/"
          backend {
            service_name = "shlink"
            service_port = "80"
          }
        }
      }
    }
  }
}

# Shlink web client

resource "kubernetes_config_map" "shlink-web" {
  metadata {
    name      = "shlink-web-servers"
    namespace = "url"

    annotations = {
      "reloader.stakater.com/match" = "true"
    }
  }

  data = {
    "servers.json" = jsonencode([{
      name   = "Main"
      url    = "https://url.viktorbarzin.me"
      apiKey = var.api_key
    }])
  }
}

resource "kubernetes_deployment" "shlink-web" {
  metadata {
    name      = "shlink-web"
    namespace = "url"
    labels = {
      run = "shlink-web"
    }
    annotations = {
      "reloader.stakater.com/search" = "true"
    }
  }
  spec {
    replicas = 1
    selector {
      match_labels = {
        run = "shlink-web"
      }
    }
    template {
      metadata {
        labels = {
          run = "shlink-web"
        }
      }
      spec {
        container {
          image = "shlinkio/shlink-web-client"
          name  = "shlink-web"
          volume_mount {
            mount_path = "/usr/share/nginx/html/servers.json"
            sub_path   = "servers.json"
            name       = "config"
          }
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
            container_port = 8080
          }
        }
        volume {
          name = "config"
          config_map {
            name = "shlink-web-servers"
          }
        }
      }
    }
  }
}

resource "kubernetes_service" "shlink-web" {
  metadata {
    name      = "shlink-web"
    namespace = "url"
    labels = {
      "run" = "shlink-web"
    }
  }

  spec {
    selector = {
      run = "shlink-web"
    }
    port {
      name        = "http"
      port        = "80"
      target_port = "80"
    }
  }
}

resource "kubernetes_ingress" "shlink-web" {
  metadata {
    name      = "shlink-web-ingress"
    namespace = "url"
    annotations = {
      "kubernetes.io/ingress.class"                        = "nginx"
      "nginx.ingress.kubernetes.io/auth-tls-verify-client" = "on"
      "nginx.ingress.kubernetes.io/auth-tls-secret"        = "default/ca-secret"
    }
  }

  spec {
    tls {
      hosts       = ["shlink.viktorbarzin.me"]
      secret_name = var.tls_secret_name
    }
    rule {
      host = "shlink.viktorbarzin.me"
      http {
        path {
          path = "/"
          backend {
            service_name = "shlink-web"
            service_port = "80"
          }
        }
      }
    }
  }
}
