# C2 blocklist mirror (network IDS plan, decision 4; docs/runbooks/network-ids.md).
#
# When one of our hosts reaches an abuse.ch botnet C2, the OPNsense agent's
# scenario viktor/abusech-c2-destination raises an alert on the C2 address, and
# the LAPI profile c2_destination_block (values.yaml) turns it into a decision
# of type c2-block. Only this mirror serves that type: Traefik's plugin, the
# node nftables bouncer, the OPNsense bouncer and ipv6-ban-widen.sh all act on
# type ban only, so a C2 that shares a cloud address never gets banned inbound
# for the whole cluster. OPNsense pulls the list into the URL-table alias
# crowdsec_c2 and blocks it outbound on VLAN 10 and VLAN 20.
#
# crowdsecurity/cs-blocklist-mirror is CrowdSec's own bouncer for serving
# decisions as a plain list; the stream API it uses leaves out simulated
# decisions, so the list stays empty while the OPNsense agent is simulated.

variable "c2mirror_bouncer_key" {
  type        = string
  sensitive   = true
  description = "API key for the C2 blocklist mirror. Seeded into LAPI via BOUNCER_KEY_c2mirror (values.yaml); Vault secret/platform crowdsec_c2mirror_bouncer_key."
}

locals {
  c2_mirror_yaml = yamlencode({
    config_version = "v1.0"
    crowdsec_config = {
      lapi_key                     = var.c2mirror_bouncer_key
      lapi_url                     = "http://crowdsec-service.crowdsec.svc.cluster.local:8080/"
      update_frequency             = "10s"
      include_scenarios_containing = ["viktor/abusech-c2-destination"]
      exclude_scenarios_containing = []
      only_include_decisions_from  = ["crowdsec"]
      insecure_skip_verify         = false
      supported_decisions_types    = ["c2-block"]
    }
    blocklists = [{
      format   = "plain_text"
      endpoint = "/security/blocklist"
      authentication = {
        # The Service keeps the client address (externalTrafficPolicy Local),
        # so the mirror itself also checks it is OPNsense asking.
        type        = "ip_based"
        trusted_ips = ["10.0.20.1/32", "10.0.10.1/32", "127.0.0.1/32"]
      }
    }]
    listen_uri         = "0.0.0.0:41412"
    tls                = { cert_file = "", key_file = "" }
    metrics            = { enabled = true, endpoint = "/metrics" }
    log_media          = "stdout"
    log_level          = "info"
    enable_access_logs = true
  })
}

resource "kubernetes_secret" "c2_mirror_config" {
  metadata {
    name      = "crowdsec-c2-mirror-config"
    namespace = kubernetes_namespace.crowdsec.metadata[0].name
    labels = {
      "app.kubernetes.io/name" = "crowdsec-c2-mirror"
      tier                     = var.tier
    }
    annotations = {
      "reloader.stakater.com/match" = "true"
    }
  }
  data = {
    "crowdsec-blocklist-mirror.yaml" = local.c2_mirror_yaml
  }
  type = "Opaque"
}

resource "kubernetes_deployment" "c2_mirror" {
  metadata {
    name      = "crowdsec-c2-mirror"
    namespace = kubernetes_namespace.crowdsec.metadata[0].name
    labels = {
      "app.kubernetes.io/name" = "crowdsec-c2-mirror"
      tier                     = var.tier
    }
  }
  spec {
    replicas = 1
    selector {
      match_labels = {
        "app.kubernetes.io/name" = "crowdsec-c2-mirror"
      }
    }
    template {
      metadata {
        labels = {
          "app.kubernetes.io/name" = "crowdsec-c2-mirror"
          tier                     = var.tier
        }
        annotations = {
          "secret.reloader.stakater.com/reload" = kubernetes_secret.c2_mirror_config.metadata[0].name
        }
      }
      spec {
        priority_class_name = "tier-1-cluster"
        container {
          name  = "mirror"
          image = "crowdsecurity/blocklist-mirror:v0.0.6"
          port {
            name           = "http"
            container_port = 41412
            protocol       = "TCP"
          }
          volume_mount {
            name       = "config"
            mount_path = "/etc/crowdsec/bouncers"
            read_only  = true
          }
          readiness_probe {
            tcp_socket {
              port = 41412
            }
            period_seconds = 10
          }
          resources {
            requests = {
              cpu    = "10m"
              memory = "32Mi"
            }
            limits = {
              memory = "64Mi"
            }
          }
        }
        volume {
          name = "config"
          secret {
            secret_name = kubernetes_secret.c2_mirror_config.metadata[0].name
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
    ignore_changes = [
      spec[0].template[0].spec[0].dns_config,
      spec[0].template[0].metadata[0].annotations["reloader.stakater.com/last-reloaded-from"], # RELOADER_LIFECYCLE_V1
    ]
  }
}

resource "kubernetes_service" "c2_mirror" {
  metadata {
    name      = "crowdsec-c2-mirror"
    namespace = kubernetes_namespace.crowdsec.metadata[0].name
    labels = {
      "app.kubernetes.io/name" = "crowdsec-c2-mirror"
    }
    annotations = {
      "metallb.io/loadBalancerIPs" = "10.0.20.212"
    }
  }
  spec {
    type                        = "LoadBalancer"
    external_traffic_policy     = "Local"
    load_balancer_source_ranges = ["10.0.20.1/32", "10.0.10.1/32"]
    selector = {
      "app.kubernetes.io/name" = "crowdsec-c2-mirror"
    }
    port {
      name        = "http"
      port        = 41412
      target_port = 41412
      protocol    = "TCP"
    }
  }
  lifecycle {
    ignore_changes = [metadata[0].annotations["metallb.io/ip-allocated-from-pool"]]
  }
}
