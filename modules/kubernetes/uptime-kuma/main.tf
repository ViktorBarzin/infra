variable "tls_secret_name" {}

module "tls_secret" {
  source          = "../setup_tls_secret"
  namespace       = "uptime-kuma"
  tls_secret_name = var.tls_secret_name
}

resource "kubernetes_namespace" "uptime-kuma" {
  metadata {
    name = "uptime-kuma"
    # labels = {
    #   "istio-injection" : "enabled"
    # }
  }
}

resource "kubernetes_deployment" "uptime-kuma" {
  metadata {
    name      = "uptime-kuma"
    namespace = "uptime-kuma"
    labels = {
      app = "uptime-kuma"
    }
    annotations = {
      "reloader.stakater.com/search" = "true"
    }
  }
  spec {
    replicas = 1
    strategy {
      type = "Recreate"
    }
    selector {
      match_labels = {
        app = "uptime-kuma"
      }
    }
    template {
      metadata {
        annotations = {
          "diun.enable"       = "true"
          "diun.include_tags" = "latest"
        }
        labels = {
          app = "uptime-kuma"
        }
      }
      spec {
        container {
          image = "louislam/uptime-kuma:latest"
          name  = "uptime-kuma"

          port {
            container_port = 3001
          }
          volume_mount {
            name       = "data"
            mount_path = "/app/data"
          }
        }
        volume {
          name = "data"
          nfs {
            server = "10.0.10.15"
            path   = "/mnt/main/uptime-kuma"
          }
        }
      }
    }
  }
}
resource "kubernetes_service" "uptime-kuma" {
  metadata {
    name      = "uptime-kuma"
    namespace = "uptime-kuma"
    labels = {
      "app" = "uptime-kuma"
    }
  }

  spec {
    selector = {
      app = "uptime-kuma"
    }
    port {
      port        = "80"
      target_port = "3001"
    }
  }
}
module "ingress" {
  source          = "../ingress_factory"
  namespace       = "uptime-kuma"
  name            = "uptime"
  tls_secret_name = var.tls_secret_name
  service_name    = "uptime-kuma"
  extra_annotations = {
    "nginx.org/websocket-services" = "uptime-kuma"
    "gethomepage.dev/enabled"      = "true"
    "gethomepage.dev/description"  = "Uptime monitor"
    # gethomepage.dev/group: Media
    "gethomepage.dev/icon" : "uptime-kuma.png"
    "gethomepage.dev/name"         = "Uptime Kuma"
    "gethomepage.dev/widget.type"  = "uptimekuma"
    "gethomepage.dev/widget.url"   = "https://uptime.viktorbarzin.me"
    "gethomepage.dev/widget.slug"  = "cluster-internal"
    "gethomepage.dev/pod-selector" = ""
  }
}
