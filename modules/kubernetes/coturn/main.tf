variable "tls_secret_name" {}
variable "tier" { type = string }
variable "turn_secret" { type = string }

locals {
  turn_realm = "viktorbarzin.me"
  turn_port  = 3478
  # Small relay range — 100 ports is plenty for a home lab (~50 concurrent streams)
  min_port = 49152
  max_port = 49252
}

resource "kubernetes_namespace" "coturn" {
  metadata {
    name = "coturn"
    labels = {
      tier = var.tier
    }
  }
}

module "tls_secret" {
  source          = "../setup_tls_secret"
  namespace       = kubernetes_namespace.coturn.metadata[0].name
  tls_secret_name = var.tls_secret_name
}

resource "kubernetes_config_map" "coturn_config" {
  metadata {
    name      = "coturn-config"
    namespace = kubernetes_namespace.coturn.metadata[0].name
  }

  data = {
    "turnserver.conf" = <<-EOF
      # TURN server configuration
      listening-port=${local.turn_port}
      fingerprint
      lt-cred-mech
      use-auth-secret
      static-auth-secret=${var.turn_secret}
      realm=${local.turn_realm}
      server-name=turn.${local.turn_realm}

      # Network — use 0.0.0.0, coturn auto-detects pod IP
      listening-ip=0.0.0.0

      # Media relay port range (narrow — 100 ports)
      min-port=${local.min_port}
      max-port=${local.max_port}

      # Logging
      verbose
      no-stdout-log
      syslog

      # Security
      no-multicast-peers
      no-cli
      no-tlsv1
      no-tlsv1_1

      # Performance
      total-quota=100
      stale-nonce=600
      max-bps=0
    EOF
  }
}

resource "kubernetes_deployment" "coturn" {
  metadata {
    name      = "coturn"
    namespace = kubernetes_namespace.coturn.metadata[0].name
    labels = {
      app  = "coturn"
      tier = var.tier
    }
  }

  spec {
    replicas = 1
    strategy {
      type = "RollingUpdate"
      rolling_update {
        max_unavailable = 0
        max_surge       = 1
      }
    }
    selector {
      match_labels = {
        app = "coturn"
      }
    }

    template {
      metadata {
        labels = {
          app = "coturn"
        }
      }

      spec {
        container {
          name  = "coturn"
          image = "coturn/coturn:latest"
          args  = ["-c", "/etc/turnserver/turnserver.conf"]

          # STUN/TURN signaling port
          port {
            name           = "turn-udp"
            container_port = local.turn_port
            protocol       = "UDP"
          }
          port {
            name           = "turn-tcp"
            container_port = local.turn_port
            protocol       = "TCP"
          }

          volume_mount {
            name       = "config"
            mount_path = "/etc/turnserver"
            read_only  = true
          }

          resources {
            requests = {
              cpu    = "100m"
              memory = "128Mi"
            }
            limits = {
              cpu    = "1"
              memory = "512Mi"
            }
          }
        }

        volume {
          name = "config"
          config_map {
            name = kubernetes_config_map.coturn_config.metadata[0].name
          }
        }
      }
    }
  }
}

# LoadBalancer service with MetalLB — exposes STUN/TURN signaling + relay ports
resource "kubernetes_service" "coturn" {
  metadata {
    name      = "coturn"
    namespace = kubernetes_namespace.coturn.metadata[0].name
    annotations = {
      "metallb.universe.tf/loadBalancerIPs"  = "10.0.20.200"
      "metallb.universe.tf/allow-shared-ip" = "shared"
    }
  }

  spec {
    type = "LoadBalancer"
    selector = {
      app = "coturn"
    }

    # STUN/TURN signaling
    port {
      name        = "turn-udp"
      port        = local.turn_port
      target_port = local.turn_port
      protocol    = "UDP"
    }
    port {
      name        = "turn-tcp"
      port        = local.turn_port
      target_port = local.turn_port
      protocol    = "TCP"
    }

    # Relay port range (49152-49252)
    dynamic "port" {
      for_each = range(local.min_port, local.max_port + 1)
      content {
        name        = "relay-${port.value}"
        port        = port.value
        target_port = port.value
        protocol    = "UDP"
      }
    }
  }
}
