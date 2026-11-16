# Shadow CrowdSec for the home address (Cloud B38, Viktor's decision V8;
# docs/agents/security.md, "Open risk"; docs/runbooks/cloud.md, "CrowdSec
# shadow for the home address").
#
# Cloud's Project pods leave through the home WAN, so their requests to a
# homelab host through Cloudflare reach Traefik with the household's address,
# which the live CrowdSec whitelists. Before Viktor decides which scenarios
# may ban that address, this instance counts which scenarios it would trigger,
# for 3 days from 2026-11-16 (decision on or after 2026-11-19).
#
# It BANS NOTHING, by construction:
#   - its own LAPI on 127.0.0.1 with SQLite in an emptyDir; no Service, no
#     bouncer key, so no bouncer can ever read it;
#   - its only profile makes no decision (`decisions` absent), so the
#     database holds alerts and no decision at all;
#   - DISABLE_ONLINE_API: no Central API, no signals, no blocklist pulls, no
#     console enrollment (no ENROLL_KEY).
# The live LAPI, its allowlist and its whitelist are unchanged.
#
# Input: the Traefik access lines from Loki whose ClientHost is the home
# address (var.public_ip), and nothing else, so its buckets stay small.
# Scenarios: the live agents' 3 HTTP collections (traefik,
# base-http-scenarios, http-cve; the others parse logs it never reads) and
# geoip parser, the same custom scenario files (every key of
# crowdsec-custom-scenarios) and the same parser whitelists minus the home
# address line. AppSec alerts come from the
# AppSec pods, not from log scenarios, so this instance does not see them.
#
# Counts per scenario: Prometheus scrapes cs_bucket_overflowed_total through
# the pod annotations (job kubernetes-pods), which survives a restart; the
# alerts themselves (cscli alerts list) live in the emptyDir, which survives
# a container restart and is lost when the pod is replaced.
#
# Remove it: delete this file and the public_ip lines in stacks/crowdsec
# main.tf, then apply stacks/crowdsec.

variable "public_ip" {
  type        = string
  description = "The home WAN IPv4 (config.tfvars public_ip): the only source the shadow instance reads."
}

locals {
  shadow_name = "crowdsec-shadow"
  # The live parser whitelists without the home address line.
  shadow_whitelist_yaml = replace(
    local.crowdsec_whitelist_yaml,
    "/(?m)^[ \\t]*- \"${replace(var.public_ip, ".", "\\.")}\".*\\n/",
    "",
  )
  shadow_acquisition = yamlencode({
    source         = "loki"
    url            = "http://loki.monitoring.svc.cluster.local:3100"
    mode           = "tail"
    query          = "{namespace=\"traefik\", container=\"traefik\"} |= `\"ClientHost\":\"${var.public_ip}\"`"
    wait_for_ready = "60s"
    labels         = { type = "traefik" }
  })
  # One profile for every alert, with no decisions: the alert is stored and
  # nothing else happens (the docs' LAPI whitelist pattern).
  shadow_profiles     = <<-YAML
    name: shadow_record_only
    filters:
      - Alert.GetScenario() != ""
    on_success: break
  YAML
  shadow_config_local = <<-YAML
    api:
      server:
        listen_uri: 127.0.0.1:8080
  YAML
}

resource "kubernetes_config_map" "crowdsec_shadow" {
  metadata {
    name      = local.shadow_name
    namespace = kubernetes_namespace.crowdsec.metadata[0].name
    labels = {
      "app.kubernetes.io/name" = local.shadow_name
    }
  }
  data = {
    "loki.yaml"         = local.shadow_acquisition
    "profiles.yaml"     = local.shadow_profiles
    "config.yaml.local" = local.shadow_config_local
    "whitelist.yaml"    = local.shadow_whitelist_yaml
    "simulation.yaml"   = "simulation: false\nexclusions: []\n"
  }
  lifecycle {
    precondition {
      condition     = strcontains(local.crowdsec_whitelist_yaml, "\"${var.public_ip}\"") && !strcontains(local.shadow_whitelist_yaml, var.public_ip)
      error_message = "The shadow whitelist must be the live one without the home address (var.public_ip), and the live one must still list it."
    }
    precondition {
      condition     = !strcontains(local.shadow_profiles, "decisions")
      error_message = "The shadow profile must make no decision."
    }
  }
}

resource "kubernetes_deployment" "crowdsec_shadow" {
  metadata {
    name      = local.shadow_name
    namespace = kubernetes_namespace.crowdsec.metadata[0].name
    labels = {
      "app.kubernetes.io/name" = local.shadow_name
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
        "app.kubernetes.io/name" = local.shadow_name
      }
    }
    template {
      metadata {
        # No k8s-app=crowdsec label: the crowdsec and crowdsec-agent scrape
        # jobs and their alerts stay about the live instance only.
        labels = {
          "app.kubernetes.io/name" = local.shadow_name
          tier                     = var.tier
        }
        annotations = {
          "checksum/config"      = sha256(jsonencode(kubernetes_config_map.crowdsec_shadow.data))
          "checksum/scenarios"   = sha256(jsonencode(kubernetes_config_map.crowdsec_custom_scenarios.data))
          "prometheus.io/scrape" = "true"
          "prometheus.io/port"   = "6060"
          "prometheus.io/path"   = "/metrics"
        }
      }
      spec {
        # Not cluster-critical: it bans nothing and only counts.
        priority_class_name = "tier-4-aux"
        container {
          name  = "crowdsec"
          image = "crowdsecurity/crowdsec:v1.8.2"
          env {
            name  = "DISABLE_ONLINE_API"
            value = "true"
          }
          env {
            name  = "LOCAL_API_URL"
            value = "http://127.0.0.1:8080"
          }
          # SQLite in the emptyDir; the image checks for a volume there.
          env {
            name  = "CROWDSEC_BYPASS_DB_VOLUME_CHECK"
            value = "true"
          }
          # The live agents' collections and extra parser (values.yaml).
          env {
            name  = "COLLECTIONS"
            value = "crowdsecurity/traefik crowdsecurity/base-http-scenarios crowdsecurity/http-cve"
          }
          env {
            name  = "PARSERS"
            value = "crowdsecurity/geoip-enrich"
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
            mount_path = "/etc/crowdsec/profiles.yaml"
            sub_path   = "profiles.yaml"
            read_only  = true
          }
          volume_mount {
            name       = "config"
            mount_path = "/etc/crowdsec/config.yaml.local"
            sub_path   = "config.yaml.local"
            read_only  = true
          }
          volume_mount {
            name       = "config"
            mount_path = "/etc/crowdsec/simulation.yaml"
            sub_path   = "simulation.yaml"
            read_only  = true
          }
          volume_mount {
            name       = "config"
            mount_path = "/etc/crowdsec/parsers/s02-enrich/whitelist.yaml"
            sub_path   = "whitelist.yaml"
            read_only  = true
          }
          # The same custom scenarios and overrides as the live agents.
          dynamic "volume_mount" {
            for_each = toset(keys(kubernetes_config_map.crowdsec_custom_scenarios.data))
            content {
              name       = "scenarios"
              mount_path = "/etc/crowdsec/scenarios/${volume_mount.value}"
              sub_path   = volume_mount.value
              read_only  = true
            }
          }
          volume_mount {
            name       = "data"
            mount_path = "/var/lib/crowdsec/data"
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
            name = kubernetes_config_map.crowdsec_shadow.metadata[0].name
          }
        }
        volume {
          name = "scenarios"
          config_map {
            name = kubernetes_config_map.crowdsec_custom_scenarios.metadata[0].name
          }
        }
        volume {
          name = "data"
          empty_dir {
            size_limit = "256Mi"
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
