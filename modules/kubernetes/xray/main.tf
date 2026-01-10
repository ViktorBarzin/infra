variable "tls_secret_name" {}
variable "tier" { type = string }
variable "xray_reality_clients" { type = list(map(string)) }
variable "xray_reality_private_key" { type = string }
variable "xray_reality_short_ids" { type = list(string) }

# Github repo - https://github.com/teddysun/across/blob/master/docker/xray/README.md
# Clients:
# iOS - OneXRay - https://github.com/OneXray/OneXray
# MacOS - V2BOX


module "tls_secret" {
  source          = "../setup_tls_secret"
  namespace       = kubernetes_namespace.xray.metadata[0].name
  tls_secret_name = var.tls_secret_name
}

resource "kubernetes_namespace" "xray" {
  metadata {
    name = "xray"
  }
}

resource "kubernetes_config_map" "xray_config" {
  metadata {
    name      = "xray-config"
    namespace = kubernetes_namespace.xray.metadata[0].name

    labels = {
      app = "xray"
    }
    annotations = {
      "reloader.stakater.com/match" = "true"
    }
  }

  data = {
    "config.json" = templatefile("${path.module}/xray_config.json.tpl", {
      clients             = jsonencode(var.xray_reality_clients)
      reality_private_key = var.xray_reality_private_key
      reality_short_ids   = jsonencode(var.xray_reality_short_ids)
    })
  }
}

resource "kubernetes_deployment" "xray" {
  metadata {
    name      = "xray"
    namespace = kubernetes_namespace.xray.metadata[0].name
    labels = {
      app  = "xray"
      tier = var.tier
    }
    annotations = {
      "reloader.stakater.com/search" = "true"
    }
  }
  spec {
    replicas = 1
    strategy {
      rolling_update {
        max_surge       = "2"
        max_unavailable = "0"
      }
    }
    selector {
      match_labels = {
        app = "xray"
      }
    }
    template {
      metadata {
        labels = {
          app = "xray"
        }
      }
      spec {
        container {
          image             = "teddysun/xray"
          name              = "xray"
          image_pull_policy = "IfNotPresent"
          port {
            container_port = 6443 // vless
            protocol       = "TCP"
          }
          port {
            container_port = 7443 // reality
            protocol       = "TCP"
          }
          port {
            container_port = 8443 // websocket
            protocol       = "TCP"
          }
          port {
            container_port = 9443 // gRPC
            protocol       = "TCP"
          }
          volume_mount {
            name       = "tls"
            mount_path = "/etc/xray/tls.crt"
            sub_path   = "tls.crt"
          }
          volume_mount {
            name       = "tls"
            mount_path = "/etc/xray/tls.key"
            sub_path   = "tls.key"
          }
          volume_mount {
            name       = "config"
            mount_path = "/etc/xray/config.json"
            sub_path   = "config.json"
          }
        }

        volume {
          name = "tls"
          secret {
            secret_name = var.tls_secret_name
          }
        }
        volume {
          name = "config"
          config_map {
            name = "xray-config"
          }
        }
      }
    }
  }
}

resource "kubernetes_service" "xray" {
  metadata {
    name      = "xray"
    namespace = kubernetes_namespace.xray.metadata[0].name
    labels = {
      "app" = "xray"
    }
  }

  spec {
    selector = {
      app = "xray"
    }
    port {
      name     = "vless"
      port     = 6443
      protocol = "TCP"
    }
    port {
      name     = "websocket"
      port     = 8443
      protocol = "TCP"
    }
    port {
      name     = "grpc"
      port     = 9443
      protocol = "TCP"
    }
  }
}

resource "kubernetes_service" "xray-reality" {
  metadata {
    name      = "xray-reality"
    namespace = kubernetes_namespace.xray.metadata[0].name
    labels = {
      "app" = "xray"
    }
  }

  spec {
    type = "LoadBalancer"
    selector = {
      app = "xray"
    }
    port {
      name     = "reality"
      port     = 7443
      protocol = "TCP"
    }
  }
}

resource "kubernetes_ingress_v1" "ingress" {
  metadata {
    namespace = kubernetes_namespace.xray.metadata[0].name
    name      = "xray"
    annotations = {
      "kubernetes.io/ingress.class"                  = "nginx"
      "nginx.ingress.kubernetes.io/backend-protocol" = "HTTP"
      "nginx.org/websocket-services" : "xray"
      "nginx.ingress.kubernetes.io/enable-access-log" = "false"
    }
  }

  spec {
    tls {
      hosts       = ["xray-ws.viktorbarzin.me"]
      secret_name = var.tls_secret_name
    }
    rule {
      host = "xray-ws.viktorbarzin.me"
      http {
        path {
          backend {
            service {
              name = "xray"
              port {
                number = 8443

              }
            }
          }
        }
      }
    }
  }
}

resource "kubernetes_ingress_v1" "ingress-grpc" {
  metadata {
    namespace = kubernetes_namespace.xray.metadata[0].name
    name      = "xray-grpc"
    annotations = {
      "kubernetes.io/ingress.class"                    = "nginx"
      "nginx.ingress.kubernetes.io/enable-access-log"  = "false"
      "nginx.ingress.kubernetes.io/backend-protocol"   = "GRPC"
      "nginx.ingress.kubernetes.io/proxy-read-timeout" = "3600"
      "nginx.ingress.kubernetes.io/proxy-send-timeout" = "3600"
    }
  }

  spec {
    tls {
      hosts       = ["xray-grpc.viktorbarzin.me"]
      secret_name = var.tls_secret_name
    }
    rule {
      host = "xray-grpc.viktorbarzin.me"
      http {
        path {
          path      = "/grpc-vpn"
          path_type = "Prefix"
          backend {
            service {
              name = "xray"
              port {
                number = 9443
              }
            }
          }
        }
      }
    }
  }
}

resource "kubernetes_ingress_v1" "ingress-vless" {
  metadata {
    namespace = kubernetes_namespace.xray.metadata[0].name
    name      = "xray-vless"
    annotations = {
      "kubernetes.io/ingress.class" = "nginx"
    }
  }

  spec {
    tls {
      hosts       = ["xray-vless.viktorbarzin.me"]
      secret_name = var.tls_secret_name
    }
    rule {
      host = "xray-vless.viktorbarzin.me"
      http {
        path {
          backend {
            service {
              name = "xray"
              port {
                number = 6443

              }
            }
          }
        }
      }
    }
  }
}
