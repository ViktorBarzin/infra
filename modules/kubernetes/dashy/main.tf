
variable "tls_secret_name" {}

module "tls_secret" {
  source          = "../setup_tls_secret"
  namespace       = "dashy"
  tls_secret_name = var.tls_secret_name
}

resource "kubernetes_namespace" "dashy" {
  metadata {
    name = "dashy"
  }
}

resource "kubernetes_config_map" "config" {
  metadata {
    name      = "config"
    namespace = "dashy"

    annotations = {
      "reloader.stakater.com/match" = "true"
    }
  }

  data = {
    "conf.yaml" = <<-EOT
---
pageInfo:
  title: Dashy
  description: Welcome to your new dashboard!
  navLinks:
    - title: GitHub
      path: https://github.com/Lissy93/dashy
    - title: Documentation
      path: https://dashy.to/docs
appConfig:
  theme: colorful
  layout: auto
  iconSize: large
  language: en
sections:
  - name: Getting Started
    icon: fas fa-rocket
    items:
      - &ref_0
        title: Dashy Live
        description: Development a project management links for Dashy
        icon: https://i.ibb.co/qWWpD0v/astro-dab-128.png
        url: https://live.dashy.to/
        target: newtab
        id: 0_1481_dashylive
      - &ref_1
        title: GitHub
        description: Source Code, Issues and Pull Requests
        url: https://github.com/lissy93/dashy
        icon: favicon
        id: 1_1481_github
      - &ref_2
        title: Docs
        description: Configuring & Usage Documentation
        provider: Dashy.to
        icon: far fa-book
        url: https://dashy.to/docs
        id: 2_1481_docs
      - &ref_3
        title: Showcase
        description: See how others are using Dashy
        url: https://github.com/Lissy93/dashy/blob/master/docs/showcase.md
        icon: far fa-grin-hearts
        id: 3_1481_showcase
      - &ref_4
        title: Config Guide
        description: See full list of configuration options
        url: https://github.com/Lissy93/dashy/blob/master/docs/configuring.md
        icon: fas fa-wrench
        id: 4_1481_configguide
      - &ref_5
        title: Support
        description: Get help with Dashy, raise a bug, or get in contact
        url: https://github.com/Lissy93/dashy/blob/master/.github/SUPPORT.md
        icon: far fa-hands-helping
        id: 5_1481_support
    filteredItems:
      - *ref_0
      - *ref_1
      - *ref_2
      - *ref_3
      - *ref_4
      - *ref_5

    EOT
  }
}

resource "kubernetes_deployment" "dashy" {
  metadata {
    name      = "dashy"
    namespace = "dashy"
    labels = {
      app = "dashy"
    }
    annotations = {
      "reloader.stakater.com/search" = "true"
    }
  }
  spec {
    replicas = 1
    selector {
      match_labels = {
        app = "dashy"
      }
    }
    template {
      metadata {
        labels = {
          app = "dashy"
        }
      }
      spec {
        container {
          image = "lissy93/dashy:latest"
          name  = "dashy"

          port {
            container_port = 80
          }
          #   volume_mount {
          #     name       = "config"
          #     mount_path = "/app/public/"
          #   }


        }
        volume {
          name = "config"
          config_map {
            name = "config"
          }
        }
      }
    }
  }
}

resource "kubernetes_service" "dashy" {
  metadata {
    name      = "dashy"
    namespace = "dashy"
    labels = {
      app = "dashy"
    }
  }

  spec {
    selector = {
      app = "dashy"
    }
    port {
      name = "http"
      port = "80"
    }
  }
}

resource "kubernetes_ingress_v1" "dashy" {
  metadata {
    name      = "dashy-ingress"
    namespace = "dashy"
    annotations = {
      "kubernetes.io/ingress.class" = "nginx"
      //"nginx.ingress.kubernetes.io/auth-tls-verify-client" = "on"
      //"nginx.ingress.kubernetes.io/auth-tls-secret"        = "default/ca-secret"
      #   "nginx.ingress.kubernetes.io/auth-url" : "https://$host/oauth2/auth"
      "nginx.ingress.kubernetes.io/auth-url" : "https://viktorbarzin.uk.auth0.com//oauth2/auth"
      #   "nginx.ingress.kubernetes.io/auth-signin" : "https://$host/oauth2/start?rd=$escaped_request_uri"
      "nginx.ingress.kubernetes.io/auth-signin" : "https://viktorbarzin.uk.auth0.com//oauth2/start?rd=$escaped_request_uri"
    }
  }

  spec {
    tls {
      hosts       = ["dashy.viktorbarzin.me"]
      secret_name = var.tls_secret_name
    }
    rule {
      host = "dashy.viktorbarzin.me"
      http {
        path {
          path = "/"
          backend {
            service {
              name = "dashy"
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
