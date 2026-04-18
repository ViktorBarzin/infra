variable "tls_secret_name" {}
variable "tier" { type = string }
variable "xray_reality_clients" { type = list(map(string)) }
variable "xray_reality_private_key" {
  type      = string
  sensitive = true
}
variable "xray_reality_short_ids" { type = list(string) }

# Github repo - https://github.com/teddysun/across/blob/master/docker/xray/README.md
# Clients:
# iOS - OneXRay - https://github.com/OneXray/OneXray
# MacOS - V2BOX


module "tls_secret" {
  source          = "../../../../modules/kubernetes/setup_tls_secret"
  namespace       = kubernetes_namespace.xray.metadata[0].name
  tls_secret_name = var.tls_secret_name
}

resource "kubernetes_namespace" "xray" {
  metadata {
    name = "xray"
    labels = {
      tier = var.tier
    }
  }
  lifecycle {
    # KYVERNO_LIFECYCLE_V1: goldilocks-vpa-auto-mode ClusterPolicy stamps this label on every namespace
    ignore_changes = [metadata[0].labels["goldilocks.fairwinds.com/vpa-update-mode"]]
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
          resources {
            requests = {
              cpu    = "10m"
              memory = "64Mi"
            }
            limits = {
              memory = "64Mi"
            }
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
        dns_config {
          option {
            name  = "ndots"
            value = "2"
          }
        }
      }
    }
  }
  lifecycle {
    # KYVERNO_LIFECYCLE_V1: Kyverno admission webhook mutates dns_config with ndots=2
    ignore_changes = [spec[0].template[0].spec[0].dns_config]
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
    annotations = {
      "metallb.io/loadBalancerIPs" = "10.0.20.200"
      "metallb.io/allow-shared-ip" = "shared"
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

module "ingress_ws" {
  source          = "../../../../modules/kubernetes/ingress_factory"
  dns_type        = "proxied"
  namespace       = kubernetes_namespace.xray.metadata[0].name
  name            = "xray-ws"
  service_name    = "xray"
  host            = "xray-ws"
  port            = 8443
  tls_secret_name = var.tls_secret_name
}

module "ingress_grpc" {
  source          = "../../../../modules/kubernetes/ingress_factory"
  dns_type        = "proxied"
  namespace       = kubernetes_namespace.xray.metadata[0].name
  name            = "xray-grpc"
  service_name    = "xray"
  host            = "xray-grpc"
  port            = 9443
  tls_secret_name = var.tls_secret_name
  ingress_path    = ["/grpc-vpn"]
  extra_annotations = {
    "traefik.ingress.kubernetes.io/service.serversscheme" = "h2c"
  }
}

module "ingress_vless" {
  source          = "../../../../modules/kubernetes/ingress_factory"
  dns_type        = "proxied"
  namespace       = kubernetes_namespace.xray.metadata[0].name
  name            = "xray-vless"
  service_name    = "xray"
  host            = "xray-vless"
  port            = 6443
  tls_secret_name = var.tls_secret_name
}
