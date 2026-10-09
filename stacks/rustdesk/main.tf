# RustDesk server (hbbs rendezvous + hbbr relay) so Viktor, emo and Claude can
# take over Milka's Android phone when she calls for help. MeshCentral stays the
# dashboard, but its Android agent is view-only, so tapping goes through RustDesk.
# Design: docs/plans/2026-10-09-milka-remote-phone-help-design.md.
#
# Key-locked (-k _): only clients configured with this server's public key can
# register or relay through it. The keypair lives in Vault secret/rustdesk
# (id_ed25519 = base64 of the 64-byte libsodium secret key, id_ed25519_pub =
# base64 of the 32-byte public key); clients take the pub key as "Key".

variable "public_ip" { type = string }

locals {
  host = "rustdesk.viktorbarzin.me"
  # Dedicated MetalLB address with externalTrafficPolicy=Local, same reasoning
  # as coturn's .205: hbbs records each peer's public address for hole punching,
  # and the shared .200 (ETP=Cluster) would SNAT every client to a node IP.
  # Consumers that must track it:
  #   • pfSense alias `rustdesk_lb` (the RustDesk NAT rules)
  #   • stacks/technitium static_records.tf (internal rustdesk.viktorbarzin.me)
  lb_ip = "10.0.20.206"
  image = "rustdesk/rustdesk-server:1.1.16"
}

resource "kubernetes_namespace" "rustdesk" {
  metadata {
    name = "rustdesk"
    labels = {
      tier = local.tiers.edge
    }
  }
  lifecycle {
    # KYVERNO_LIFECYCLE_V1: goldilocks-vpa-auto-mode ClusterPolicy stamps this label on every namespace
    ignore_changes = [metadata[0].labels["goldilocks.fairwinds.com/vpa-update-mode"]]
  }
}

resource "kubernetes_manifest" "external_secret" {
  field_manager {
    force_conflicts = true
  }
  manifest = {
    apiVersion = "external-secrets.io/v1"
    kind       = "ExternalSecret"
    metadata = {
      name      = "rustdesk-keys"
      namespace = "rustdesk"
    }
    spec = {
      refreshInterval = "1h"
      secretStoreRef = {
        name = "vault-kv"
        kind = "ClusterSecretStore"
      }
      target = {
        name = "rustdesk-keys"
      }
      # secret/rustdesk holds only the keypair; the phone password lives in
      # secret/rustdesk-milka and stays out of the cluster.
      dataFrom = [{
        extract = {
          key = "rustdesk"
        }
      }]
    }
  }
  depends_on = [kubernetes_namespace.rustdesk]
}

resource "kubernetes_deployment" "rustdesk" {
  metadata {
    name      = "rustdesk"
    namespace = kubernetes_namespace.rustdesk.metadata[0].name
    labels = {
      app  = "rustdesk"
      tier = local.tiers.edge
    }
    annotations = {
      "reloader.stakater.com/auto" = "true"
    }
  }

  spec {
    replicas = 1
    # One pod owns the IDs; never run two side by side.
    strategy {
      type = "Recreate"
    }
    selector {
      match_labels = {
        app = "rustdesk"
      }
    }

    template {
      metadata {
        labels = {
          app = "rustdesk"
        }
      }

      spec {
        # hbbs and hbbr read id_ed25519{,.pub} from their working directory and
        # hbbs keeps its peer database (db_v2.sqlite3) there too. The database
        # is an emptyDir: clients re-register every few seconds, so a restart
        # loses nothing that matters.
        container {
          name        = "hbbs"
          image       = local.image
          command     = ["hbbs"]
          args        = ["-r", "${local.host}:21117", "-k", "_"]
          working_dir = "/data"

          port {
            name           = "nat-test"
            container_port = 21115
            protocol       = "TCP"
          }
          port {
            name           = "id-tcp"
            container_port = 21116
            protocol       = "TCP"
          }
          port {
            name           = "id-udp"
            container_port = 21116
            protocol       = "UDP"
          }

          volume_mount {
            name       = "data"
            mount_path = "/data"
          }
          volume_mount {
            name       = "keys"
            mount_path = "/data/id_ed25519"
            sub_path   = "id_ed25519"
            read_only  = true
          }
          volume_mount {
            name       = "keys"
            mount_path = "/data/id_ed25519.pub"
            sub_path   = "id_ed25519.pub"
            read_only  = true
          }

          resources {
            requests = {
              cpu    = "10m"
              memory = "32Mi"
            }
            limits = {
              memory = "128Mi"
            }
          }
        }

        container {
          name        = "hbbr"
          image       = local.image
          command     = ["hbbr"]
          args        = ["-k", "_"]
          working_dir = "/data"

          port {
            name           = "relay"
            container_port = 21117
            protocol       = "TCP"
          }

          volume_mount {
            name       = "keys"
            mount_path = "/data/id_ed25519"
            sub_path   = "id_ed25519"
            read_only  = true
          }
          volume_mount {
            name       = "keys"
            mount_path = "/data/id_ed25519.pub"
            sub_path   = "id_ed25519.pub"
            read_only  = true
          }

          resources {
            # A relayed phone screen is a few Mbps at most.
            requests = {
              cpu    = "10m"
              memory = "32Mi"
            }
            limits = {
              memory = "256Mi"
            }
          }
        }

        volume {
          name = "data"
          empty_dir {}
        }
        volume {
          name = "keys"
          secret {
            secret_name = "rustdesk-keys"
            items {
              key  = "id_ed25519"
              path = "id_ed25519"
            }
            items {
              key  = "id_ed25519_pub"
              path = "id_ed25519.pub"
            }
          }
        }
      }
    }
  }
  depends_on = [kubernetes_manifest.external_secret]
  lifecycle {
    ignore_changes = [
      spec[0].template[0].spec[0].dns_config, # KYVERNO_LIFECYCLE_V1
      metadata[0].annotations["kubernetes.io/change-cause"],
      metadata[0].annotations["deployment.kubernetes.io/revision"],
      spec[0].template[0].metadata[0].annotations["reloader.stakater.com/last-reloaded-from"], # RELOADER_LIFECYCLE_V1
    ]
  }
}

# Requires the matching pfSense NAT: WAN 21115-21117/tcp and 21116/udp to the
# `rustdesk_lb` alias, plus the same forwards on the TP-Link in front of pfSense.
resource "kubernetes_service" "rustdesk" {
  metadata {
    name      = "rustdesk"
    namespace = kubernetes_namespace.rustdesk.metadata[0].name
    annotations = {
      "metallb.io/loadBalancerIPs" = local.lb_ip
    }
  }

  lifecycle {
    # METALLB_LIFECYCLE_V1
    ignore_changes = [metadata[0].annotations["metallb.io/ip-allocated-from-pool"]]
  }
  spec {
    type                    = "LoadBalancer"
    external_traffic_policy = "Local"
    selector = {
      app = "rustdesk"
    }

    port {
      name        = "nat-test"
      port        = 21115
      target_port = 21115
      protocol    = "TCP"
    }
    port {
      name        = "id-tcp"
      port        = 21116
      target_port = 21116
      protocol    = "TCP"
    }
    port {
      name        = "id-udp"
      port        = 21116
      target_port = 21116
      protocol    = "UDP"
    }
    port {
      name        = "relay"
      port        = 21117
      target_port = 21117
      protocol    = "TCP"
    }
  }
}

# A-only, grey-cloud: Cloudflare's proxy carries HTTP only, and the IPv6 tunnel
# bridge on pfSense forwards no RustDesk ports, so no AAAA.
resource "cloudflare_record" "rustdesk" {
  name            = "rustdesk"
  content         = var.public_ip
  proxied         = false
  ttl             = 1
  type            = "A"
  zone_id         = "fd2c5dd4efe8fe38958944e74d0ced6d" # cloudflare_zone_id
  allow_overwrite = true
}
