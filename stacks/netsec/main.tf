# netsec: the shipper for what the network IDS records
# (docs/plans/2026-11-10-network-ids.md, docs/architecture/network-security-monitoring.md).
#
#   OPNsense syslog-ng --TCP 10.0.20.211:5140--> Vector --HTTP--> ClickHouse netsec.*
#   goflow2 sidecar ----vector 6000 (in-cluster)-^                 (stacks/claude-sessions)
#
# Its own Vector, same image and config pattern as rybbit's event-pipeline
# (stacks/rybbit/event_pipeline.tf), kept separate so a netsec fault cannot
# stop app analytics. Config and unit tests: files/vector.yaml.

locals {
  namespace = "netsec"
  # Free address in the MetalLB pool 10.0.20.200-220
  # (docs/architecture/networking.md, LoadBalancer table).
  lb_ip = "10.0.20.211"
  # OPNsense's own addresses on VLAN 20 and VLAN 10. ETP Local keeps them as
  # the source, so the LB source ranges and the NetworkPolicy both see them.
  opnsense_sources = ["10.0.20.1/32", "10.0.10.1/32"]
}

resource "kubernetes_namespace" "netsec" {
  metadata {
    name = local.namespace
    labels = {
      tier = local.tiers.aux
    }
  }
  lifecycle {
    # KYVERNO_LIFECYCLE_V1: goldilocks-vpa-auto-mode ClusterPolicy stamps this label on every namespace
    ignore_changes = [metadata[0].labels["goldilocks.fairwinds.com/vpa-update-mode"]]
  }
}

# netsec_writer's password, from the same Vault path the ClickHouse server
# reads it from (secret/claude-sessions).
resource "kubernetes_manifest" "external_secret" {
  field_manager {
    force_conflicts = true
  }
  manifest = {
    apiVersion = "external-secrets.io/v1"
    kind       = "ExternalSecret"
    metadata = {
      name      = "netsec-secrets"
      namespace = local.namespace
    }
    spec = {
      refreshInterval = "1h"
      secretStoreRef = {
        name = "vault-kv"
        kind = "ClusterSecretStore"
      }
      target = {
        name = "netsec-secrets"
      }
      data = [{
        secretKey = "netsec_writer_password"
        remoteRef = {
          key      = "claude-sessions"
          property = "netsec_writer_password"
        }
      }]
    }
  }
  depends_on = [kubernetes_namespace.netsec]
}

resource "kubernetes_config_map" "vector" {
  metadata {
    name      = "netsec-vector"
    namespace = kubernetes_namespace.netsec.metadata[0].name
  }
  data = {
    "vector.yaml" = file("${path.module}/files/vector.yaml")
  }
}

resource "kubernetes_deployment" "vector" {
  metadata {
    name      = "netsec-vector"
    namespace = kubernetes_namespace.netsec.metadata[0].name
    labels = {
      app  = "netsec-vector"
      tier = local.tiers.aux
    }
    annotations = {
      "reloader.stakater.com/auto" = "true"
    }
  }
  spec {
    replicas = 1
    selector {
      match_labels = {
        app = "netsec-vector"
      }
    }
    template {
      metadata {
        labels = {
          app = "netsec-vector"
        }
        annotations = {
          "prometheus.io/scrape"           = "true"
          "prometheus.io/port"             = "9598"
          "prometheus.io/path"             = "/metrics"
          "dependency.kyverno.io/wait-for" = "clickhouse.claude-sessions:8123"
        }
      }
      spec {
        container {
          name  = "vector"
          image = "docker.io/timberio/vector:0.61.0-debian"
          args  = ["--config", "/etc/vector/vector.yaml"]
          port {
            name           = "opnsense"
            container_port = 5140
          }
          port {
            name           = "shippers"
            container_port = 6000
          }
          port {
            name           = "metrics"
            container_port = 9598
          }
          readiness_probe {
            tcp_socket {
              port = 6000
            }
            period_seconds = 10
          }
          liveness_probe {
            tcp_socket {
              port = 6000
            }
            initial_delay_seconds = 15
            period_seconds        = 30
            failure_threshold     = 5
          }
          volume_mount {
            name       = "config"
            mount_path = "/etc/vector/vector.yaml"
            sub_path   = "vector.yaml"
          }
          volume_mount {
            name       = "data"
            mount_path = "/var/lib/vector"
          }
          volume_mount {
            name       = "secrets"
            mount_path = "/etc/vector/secrets"
            read_only  = true
          }
          # Memory buffers hold at most 70,000 events (~70 MB of rows).
          resources {
            requests = {
              cpu    = "50m"
              memory = "128Mi"
            }
            limits = {
              memory = "512Mi"
            }
          }
        }
        volume {
          name = "config"
          config_map {
            name = kubernetes_config_map.vector.metadata[0].name
          }
        }
        volume {
          name = "secrets"
          secret {
            secret_name = "netsec-secrets"
          }
        }
        # Vector's data_dir (checkpoints only); sink buffers are in memory.
        volume {
          name = "data"
          empty_dir {
            size_limit = "256Mi"
          }
        }
      }
    }
  }
  lifecycle {
    ignore_changes = [
      spec[0].template[0].spec[0].dns_config, # KYVERNO_LIFECYCLE_V1
      metadata[0].annotations["kubernetes.io/change-cause"],
      metadata[0].annotations["deployment.kubernetes.io/revision"],
      spec[0].template[0].metadata[0].annotations["reloader.stakater.com/last-reloaded-from"], # RELOADER_LIFECYCLE_V1
    ]
  }
  depends_on = [kubernetes_manifest.external_secret]
}

# In-cluster shippers (the goflow2 sidecar) send here.
resource "kubernetes_service" "vector" {
  metadata {
    name      = "netsec-vector"
    namespace = kubernetes_namespace.netsec.metadata[0].name
    labels = {
      app = "netsec-vector"
    }
  }
  spec {
    selector = {
      app = "netsec-vector"
    }
    port {
      name        = "shippers"
      port        = 6000
      target_port = 6000
    }
  }
}

# OPNsense sends raw EVE JSON lines here (phase 2). Dedicated IP with
# externalTrafficPolicy Local so the source stays OPNsense's own address.
resource "kubernetes_service" "opnsense" {
  metadata {
    name      = "netsec-opnsense"
    namespace = kubernetes_namespace.netsec.metadata[0].name
    labels = {
      app = "netsec-vector"
    }
    annotations = {
      "metallb.io/loadBalancerIPs" = local.lb_ip
    }
  }
  spec {
    type                        = "LoadBalancer"
    external_traffic_policy     = "Local"
    load_balancer_source_ranges = local.opnsense_sources
    selector = {
      app = "netsec-vector"
    }
    port {
      name        = "eve"
      port        = 5140
      target_port = 5140
      protocol    = "TCP"
    }
  }
  lifecycle {
    # METALLB_LIFECYCLE_V1
    ignore_changes = [metadata[0].annotations["metallb.io/ip-allocated-from-pool"]]
  }
}

# Only OPNsense, the goflow2 sidecar and Prometheus reach the pod.
resource "kubernetes_network_policy" "vector" {
  metadata {
    name      = "netsec-vector"
    namespace = kubernetes_namespace.netsec.metadata[0].name
  }
  spec {
    pod_selector {
      match_labels = {
        app = "netsec-vector"
      }
    }
    policy_types = ["Ingress"]
    ingress {
      dynamic "from" {
        for_each = local.opnsense_sources
        content {
          ip_block {
            cidr = from.value
          }
        }
      }
      ports {
        port     = "5140"
        protocol = "TCP"
      }
    }
    ingress {
      from {
        namespace_selector {
          match_labels = {
            "kubernetes.io/metadata.name" = "monitoring"
          }
        }
        pod_selector {
          match_labels = {
            app = "goflow2"
          }
        }
      }
      ports {
        port     = "6000"
        protocol = "TCP"
      }
    }
    ingress {
      from {
        namespace_selector {
          match_labels = {
            "kubernetes.io/metadata.name" = "monitoring"
          }
        }
      }
      ports {
        port     = "9598"
        protocol = "TCP"
      }
    }
  }
}
