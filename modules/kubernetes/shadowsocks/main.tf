variable "password" {}
variable "tier" { type = string }
variable "method" {
  default = "chacha20-ietf-poly1305"
}

resource "kubernetes_namespace" "shadowsocks" {
  metadata {
    name = "shadowsocks"
    # TLS termination seems iffy - I get pfsense MiTM-ing
    # labels = {
    #   "istio-injection" : "enabled"
    # }
  }
}

resource "kubernetes_deployment" "shadowsocks" {
  metadata {
    name      = "shadowsocks"
    namespace = kubernetes_namespace.shadowsocks.metadata[0].name
    labels = {
      "app" = "shadowsocks"
      tier  = var.tier
    }
    annotations = {
      "reloader.stakater.com/search" = "true"
    }
  }
  spec {
    replicas = "1"
    selector {
      match_labels = {
        "app" = "shadowsocks"
      }
    }
    template {
      metadata {
        labels = {
          "app" = "shadowsocks"
        }
      }
      spec {
        container {
          name              = "shadowsocks"
          image             = "shadowsocks/shadowsocks-libev"
          image_pull_policy = "IfNotPresent"
          env {
            name  = "METHOD"
            value = var.method
          }
          env {
            name  = "PASSWORD"
            value = var.password
          }
          port {
            container_port = 8388
            protocol       = "TCP"
          }
          port {
            container_port = 8388
            protocol       = "UDP"
          }
        }
      }
    }
  }
}

resource "kubernetes_service" "mailserver" { # rename me
  metadata {
    name      = "shadowsocks"
    namespace = kubernetes_namespace.shadowsocks.metadata[0].name

    labels = {
      app = "shadowsocks"
    }
    annotations = {
      "metallb.universe.tf/allow-shared-ip" = "shared"
    }
  }

  spec {
    type                    = "LoadBalancer"
    external_traffic_policy = "Cluster"
    selector = {
      app = "shadowsocks"
    }

    port {
      name        = "shadowsocks-tcp"
      protocol    = "TCP"
      port        = 8388
      target_port = "8388"
    }

    port {
      name        = "shadowsocks-udp"
      protocol    = "UDP"
      port        = 8388
      target_port = "8388"
    }
  }
}
