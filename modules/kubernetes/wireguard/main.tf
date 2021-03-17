variable "tls_secret_name" {}
variable "wg_0_conf" {}
variable "firewall_sh" {}
variable "wg_0_key" {}

module "tls_secret" {
  source          = "../setup_tls_secret"
  namespace       = "wireguard"
  tls_secret_name = var.tls_secret_name
}

resource "kubernetes_namespace" "wireguard" {
  metadata {
    name = "wireguard"
  }
}
resource "kubernetes_config_map" "wg_0_conf" {
  metadata {
    name      = "wg0-conf"
    namespace = "wireguard"

    labels = {
      app = "wireguard"
    }
    annotations = {
      "reloader.stakater.com/match" = "true"
    }
  }

  data = {
    "setup-firewall.sh" = var.firewall_sh
    "wg0.conf"          = format("%s%s", var.wg_0_conf, file("${path.module}/extra/clients.conf"))
  }
}

resource "kubernetes_secret" "wg_0_key" {
  metadata {
    name      = "wg0-key"
    namespace = "wireguard"

    annotations = {
      "reloader.stakater.com/match" = "true"
    }
  }
  data = {
    "wg0.key" = var.wg_0_key
  }
  type = "generic"
}


resource "kubernetes_deployment" "wireguard" {
  metadata {
    name      = "wireguard"
    namespace = "wireguard"
    labels = {
      app = "wireguard"
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
        app = "wireguard"
      }
    }
    template {
      metadata {
        labels = {
          app = "wireguard"
        }
        annotations = {
          "prometheus.io/scrape" = "true"
        }
      }
      spec {
        container {
          image             = "sclevine/wg:latest"
          name              = "wireguard"
          image_pull_policy = "IfNotPresent"
          lifecycle {
            post_start {
              exec {
                command = ["wg-quick", "up", "wg0"]
              }
            }
            pre_stop {
              exec {
                command = ["wg-quick", "down", "wg0"]
              }
            }
          }
          command = ["tail", "-f", "/dev/null"]
          port {
            container_port = 51820
            protocol       = "UDP"
          }
          volume_mount {
            name       = "wg0-key"
            mount_path = "/etc/wireguard/wg0.key"
            sub_path   = "wg0.key"
          }
          volume_mount {
            name       = "wg0-conf"
            mount_path = "/etc/wireguard/wg0.conf"
            sub_path   = "wg0.conf"
          }
          volume_mount {
            name       = "wg0-conf"
            mount_path = "/etc/wireguard/setup-firewall.sh"
            sub_path   = "setup-firewall.sh"
          }
          security_context {
            capabilities {
              add = ["NET_ADMIN", "SYS_MODULE"]
            }
          }
        }

        container {
          name              = "prometheus-exporter"
          image             = "mindflavor/prometheus-wireguard-exporter"
          image_pull_policy = "IfNotPresent"
          command           = ["prometheus_wireguard_exporter", "-a", "-v", "-n", "/etc/wireguard/wg0.conf"]
          volume_mount {
            name       = "wg0-conf"
            mount_path = "/etc/wireguard/wg0.conf"
            sub_path   = "wg0.conf"
          }
          security_context {
            capabilities {
              add = ["NET_ADMIN"]
            }
          }
          port {
            container_port = 9586
            protocol       = "TCP"
          }
        }
        volume {
          name = "wg0-key"
          secret {
            secret_name = "wg0-key"
          }
        }
        volume {
          name = "wg0-conf"
          config_map {
            name = "wg0-conf"
          }
        }
      }
    }
  }
}

resource "kubernetes_service" "wireguard" {
  metadata {
    name      = "wireguard"
    namespace = "wireguard"
    annotations = {
      "metallb.universe.tf/allow-shared-ip" = "shared"
    }
    labels = {
      "app" = "wireguard"
    }
  }

  spec {
    type                    = "LoadBalancer"
    external_traffic_policy = "Cluster"
    selector = {
      app = "wireguard"
    }
    port {
      port     = "51820"
      protocol = "UDP"
    }
  }
}


resource "kubernetes_service" "wireguard_exporter" {
  metadata {
    name      = "wireguard-exporter"
    namespace = "wireguard"
    labels = {
      "app" = "wireguard-exporter"
    }
  }

  spec {
    selector = {
      app = "wireguard"
    }
    port {
      port        = "9102"
      target_port = "9586"
    }
  }
}
resource "kubernetes_service" "webui" {
  metadata {
    name      = "webui"
    namespace = "wireguard"

    labels = {
      app = "webui"
    }
  }
  spec {
    type = "ClusterIP"
    port {
      name        = "http"
      protocol    = "TCP"
      port        = 80
      target_port = "8080"
    }
    selector = {
      app = "webui"
    }
  }
}


resource "kubernetes_ingress" "webui" {
  metadata {
    name      = "webui-ingress"
    namespace = "wireguard"
    annotations = {
      "kubernetes.io/ingress.class" = "nginx"
    }
  }

  spec {
    tls {
      hosts       = ["wg.viktorbarzin.me"]
      secret_name = var.tls_secret_name
    }
    rule {
      host = "wg.viktorbarzin.me"
      http {
        path {
          path = "/"
          backend {
            service_name = "webui"
            service_port = "80"
          }
        }
      }
    }
  }
}
