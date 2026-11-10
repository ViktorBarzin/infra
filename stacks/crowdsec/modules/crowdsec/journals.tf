# Server journals agent (network IDS plan phase 4; docs/runbooks/network-ids.md).
#
# One CrowdSec agent, a Deployment with a single replica, reads the sshd
# journals that the servers already ship to Loki: Proxmox, the devvm, rpi-sofia
# and the k8s nodes. Nothing is installed on any server. It runs apart from the
# DaemonSet agents because every agent with a Loki acquisition would tail the
# same streams and count each event once per node.
#
# The journal lines in Loki are bare messages, so each query rebuilds a syslog
# line ("<time> <host> sshd[1]: <message>") with line_format; the stock
# syslog-logs and sshd-logs parsers then work unchanged.
#
# simulation: true for every scenario until the phase 6 review, like the
# OPNsense agent: alerts and simulated decisions reach the LAPI, nothing is
# enforced. The machine "journals" is registered by the crowdsec-lapi-reconcile
# CronJob with the password from Vault secret/platform
# crowdsec_journals_agent_password.

locals {
  journals_line_format = "| line_format `{{ __timestamp__ | date \"Jan _2 15:04:05\" }} %s sshd[1]: {{ __line__ }}`"
  journals_sources = [
    { query = "{job=\"sshd-pve\"}", host = "pve" },
    { query = "{job=\"sshd-devvm\"}", host = "devvm" },
    { query = "{job=\"systemd-journal\", host=\"rpi-sofia\", unit=\"ssh.service\"}", host = "rpi-sofia" },
    { query = "{job=\"node-journal\", unit=\"ssh.service\"}", host = "{{ .node }}" },
  ]
  journals_acquisition = join("---\n", [for s in local.journals_sources : yamlencode({
    source         = "loki"
    url            = "http://loki.monitoring.svc.cluster.local:3100"
    mode           = "tail"
    query          = "${s.query} ${format(local.journals_line_format, s.host)}"
    wait_for_ready = "60s"
    labels         = { type = "syslog" }
  })])
}

resource "kubernetes_config_map" "crowdsec_journals" {
  metadata {
    name      = "crowdsec-journals"
    namespace = kubernetes_namespace.crowdsec.metadata[0].name
  }
  data = {
    "loki.yaml"       = local.journals_acquisition
    "simulation.yaml" = "simulation: true\nexclusions: []\n"
  }
}

resource "kubernetes_manifest" "crowdsec_journals_agent_secret" {
  field_manager {
    force_conflicts = true
  }
  manifest = {
    apiVersion = "external-secrets.io/v1"
    kind       = "ExternalSecret"
    metadata = {
      name      = "crowdsec-journals-agent"
      namespace = kubernetes_namespace.crowdsec.metadata[0].name
    }
    spec = {
      refreshInterval = "1h"
      secretStoreRef = {
        name = "vault-kv"
        kind = "ClusterSecretStore"
      }
      target = {
        name = "crowdsec-journals-agent"
      }
      data = [{
        secretKey = "password"
        remoteRef = {
          key      = "platform"
          property = "crowdsec_journals_agent_password"
        }
      }]
    }
  }
}

resource "kubernetes_deployment" "crowdsec_journals" {
  metadata {
    name      = "crowdsec-journals"
    namespace = kubernetes_namespace.crowdsec.metadata[0].name
    labels = {
      "app.kubernetes.io/name" = "crowdsec-journals"
      tier                     = var.tier
    }
  }
  spec {
    replicas = 1
    strategy {
      type = "Recreate"
    }
    selector {
      match_labels = {
        "app.kubernetes.io/name" = "crowdsec-journals"
      }
    }
    template {
      metadata {
        labels = {
          "app.kubernetes.io/name" = "crowdsec-journals"
          # Scraped by the crowdsec-agent job (regex crowdsec;agent-journals).
          "k8s-app" = "crowdsec"
          type      = "agent-journals"
          tier      = var.tier
        }
        annotations = {
          "checksum/config"    = sha256(local.journals_acquisition)
          "checksum/whitelist" = sha256(local.crowdsec_whitelist_yaml)
        }
      }
      spec {
        priority_class_name = "tier-1-cluster"
        container {
          name  = "crowdsec-agent"
          image = "crowdsecurity/crowdsec:v1.8.2"
          env {
            name  = "DISABLE_LOCAL_API"
            value = "true"
          }
          env {
            name  = "DISABLE_ONLINE_API"
            value = "true"
          }
          # The image refuses to start without a volume on /var/lib/crowdsec/data
          # unless this is set (the chart sets it for its agents too). The agent
          # keeps no database; the emptyDir holds the hub's data files.
          env {
            name  = "CROWDSEC_BYPASS_DB_VOLUME_CHECK"
            value = "true"
          }
          env {
            name  = "LOCAL_API_URL"
            value = "http://crowdsec-service.crowdsec.svc.cluster.local:8080"
          }
          env {
            name  = "AGENT_USERNAME"
            value = "journals"
          }
          env {
            name = "AGENT_PASSWORD"
            value_from {
              secret_key_ref {
                name = "crowdsec-journals-agent"
                key  = "password"
              }
            }
          }
          env {
            name  = "COLLECTIONS"
            value = "crowdsecurity/linux crowdsecurity/sshd"
          }
          port {
            name           = "metrics"
            container_port = 6060
            protocol       = "TCP"
          }
          volume_mount {
            name       = "config"
            mount_path = "/etc/crowdsec/acquis.d/loki.yaml"
            sub_path   = "loki.yaml"
            read_only  = true
          }
          volume_mount {
            name       = "config"
            mount_path = "/etc/crowdsec/simulation.yaml"
            sub_path   = "simulation.yaml"
            read_only  = true
          }
          volume_mount {
            name       = "data"
            mount_path = "/var/lib/crowdsec/data"
          }
          volume_mount {
            name       = "whitelist"
            mount_path = "/etc/crowdsec/parsers/s02-enrich/whitelist.yaml"
            sub_path   = "whitelist.yaml"
            read_only  = true
          }
          resources {
            requests = {
              cpu    = "25m"
              memory = "96Mi"
            }
            limits = {
              memory = "256Mi"
            }
          }
        }
        volume {
          name = "config"
          config_map {
            name = kubernetes_config_map.crowdsec_journals.metadata[0].name
          }
        }
        volume {
          name = "data"
          empty_dir {
            size_limit = "256Mi"
          }
        }
        volume {
          name = "whitelist"
          config_map {
            name = "crowdsec-whitelist"
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
  depends_on = [kubernetes_manifest.crowdsec_journals_agent_secret]
  lifecycle {
    # KYVERNO_LIFECYCLE_V1: Kyverno admission webhook mutates dns_config with ndots=2
    ignore_changes = [spec[0].template[0].spec[0].dns_config]
  }
}
