variable "tls_secret_name" {
  type      = string
  sensitive = true
}
variable "public_ip" { type = string }

resource "kubernetes_manifest" "external_secret" {
  manifest = {
    apiVersion = "external-secrets.io/v1beta1"
    kind       = "ExternalSecret"
    metadata = {
      name      = "coturn-secrets"
      namespace = "coturn"
    }
    spec = {
      refreshInterval = "15m"
      secretStoreRef = {
        name = "vault-kv"
        kind = "ClusterSecretStore"
      }
      target = {
        name = "coturn-secrets"
      }
      dataFrom = [{
        extract = {
          key = "coturn"
        }
      }]
    }
  }
  depends_on = [kubernetes_namespace.coturn]
}

data "kubernetes_secret" "eso_secrets" {
  metadata {
    name      = "coturn-secrets"
    namespace = kubernetes_namespace.coturn.metadata[0].name
  }
  depends_on = [kubernetes_manifest.external_secret]
}

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
      tier = local.tiers.edge
    }
  }
  lifecycle {
    # KYVERNO_LIFECYCLE_V1: goldilocks-vpa-auto-mode ClusterPolicy stamps this label on every namespace
    ignore_changes = [metadata[0].labels["goldilocks.fairwinds.com/vpa-update-mode"]]
  }
}

module "tls_secret" {
  source          = "../../modules/kubernetes/setup_tls_secret"
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
      static-auth-secret=${data.kubernetes_secret.eso_secrets.data["turn_secret"]}
      realm=${local.turn_realm}
      server-name=turn.${local.turn_realm}

      # Network — use 0.0.0.0, coturn auto-detects pod IP
      listening-ip=0.0.0.0
      external-ip=${var.public_ip}

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
      tier = local.tiers.edge
    }
    annotations = {
      "reloader.stakater.com/auto" = "true"
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
        annotations = {
          "diun.enable"       = "true"
          "diun.include_tags" = "^\\d+\\.\\d+\\.\\d+-r\\d+$"
        }
      }

      spec {
        container {
          name  = "coturn"
          image = "coturn/coturn:4.10.0-r1"
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
              cpu    = "10m"
              memory = "64Mi"
            }
            limits = {
              memory = "64Mi"
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
  lifecycle {
    # KYVERNO_LIFECYCLE_V1: Kyverno admission webhook mutates dns_config with ndots=2
    ignore_changes = [spec[0].template[0].spec[0].dns_config]
  }
}

# LoadBalancer service with MetalLB — exposes STUN/TURN signaling + relay ports
resource "kubernetes_service" "coturn" {
  metadata {
    name      = "coturn"
    namespace = kubernetes_namespace.coturn.metadata[0].name
    annotations = {
      "metallb.io/loadBalancerIPs" = "10.0.20.200"
      "metallb.io/allow-shared-ip" = "shared"
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
