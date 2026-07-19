variable "tls_secret_name" {}
variable "homepage_username" {}
variable "homepage_password" {}
variable "db_password" {}
variable "enroll_key" {}
variable "crowdsec_dash_api_key" {
  type      = string
  sensitive = true
}
variable "crowdsec_dash_machine_id" { type = string } # used for web dash
variable "crowdsec_dash_machine_password" {
  type      = string
  sensitive = true
}
variable "tier" { type = string }
variable "slack_webhook_url" { type = string }
variable "mysql_host" { type = string }
variable "postgresql_host" { type = string }
variable "kvsync_bouncer_key" {
  type        = string
  sensitive   = true
  description = "API key for the LAPI->Cloudflare-KV sync job (proxied-edge control plane). Seeded into LAPI via BOUNCER_KEY_kvsync; the rybbit-stack CronJob presents the same key to pull decisions."
}
variable "firewall_bouncer_key" {
  type        = string
  sensitive   = true
  description = "API key for the cs-firewall-bouncer DaemonSet (direct-host in-kernel enforcement). Seeded into LAPI via BOUNCER_KEY_firewall; the DaemonSet presents the same key to stream decisions."
}

module "tls_secret" {
  source          = "../../../../modules/kubernetes/setup_tls_secret"
  namespace       = kubernetes_namespace.crowdsec.metadata[0].name
  tls_secret_name = var.tls_secret_name
}

resource "kubernetes_namespace" "crowdsec" {
  metadata {
    name = "crowdsec"
    labels = {
      tier                               = var.tier
      "resource-governance/custom-quota" = "true"
      "keel.sh/enrolled"                 = "true"
    }
  }
  lifecycle {
    # KYVERNO_LIFECYCLE_V1: goldilocks-vpa-auto-mode ClusterPolicy stamps this label on every namespace
    ignore_changes = [metadata[0].labels["goldilocks.fairwinds.com/vpa-update-mode"]]
  }
}

resource "kubernetes_config_map" "crowdsec_custom_scenarios" {
  metadata {
    name      = "crowdsec-custom-scenarios"
    namespace = kubernetes_namespace.crowdsec.metadata[0].name
    labels = {
      "app.kubernetes.io/name" = "crowdsec"
    }
  }

  data = {
    "http-403-abuse.yaml" = <<-YAML
      type: leaky
      name: crowdsecurity/http-403-abuse
      description: "Detect IPs triggering too many HTTP 403s in NGINX ingress logs"
      filter: "evt.Meta.log_type == 'http_access-log' && evt.Parsed.status == '403'"
      groupby: "evt.Meta.source_ip"
      leakspeed: "2s"
      capacity: 10
      blackhole: 5m
      labels:
        service: http
        behavior: abusive_403
        remediation: true
    YAML
    "http-429-abuse.yaml" : <<-YAML
      type: leaky
      name: crowdsecurity/http-429-abuse
      description: "Detect IPs repeatedly triggering rate-limit (HTTP 429)"
      filter: "evt.Meta.log_type == 'http_access-log' && evt.Parsed.status == '429'"
      groupby: "evt.Meta.source_ip"
      leakspeed: "10s"
      capacity: 5
      blackhole: 1m
      labels:
        service: http
        behavior: rate_limit_abuse
        remediation: true
      YAML
  }
}

# Whitelist for trusted IPs that should never be blocked
resource "kubernetes_config_map" "crowdsec_whitelist" {
  metadata {
    name      = "crowdsec-whitelist"
    namespace = kubernetes_namespace.crowdsec.metadata[0].name
    labels = {
      "app.kubernetes.io/name" = "crowdsec"
    }
  }

  data = {
    "whitelist.yaml" = <<-YAML
      name: crowdsecurity/whitelist-trusted-ips
      description: "Whitelist for trusted IPs that should never be blocked"
      whitelist:
        reason: "Trusted IP - never block"
        ip:
          - "176.12.22.76"
        cidr:
          # Never ban internal/cluster/LAN/tailnet sources. Enforcement (edge
          # Worker + firewall-bouncer) drops on real source IP, so an internal
          # range slipping into a decision could blackhole legit traffic — this
          # makes that structurally impossible at the decision layer.
          - "10.0.0.0/8"        # k8s nodes/pods/services + VLAN 10/20
          - "172.16.0.0/12"     # RFC1918
          - "192.168.0.0/16"    # LAN (192.168.1.0/24) + Sofia
          - "100.64.0.0/10"     # Headscale tailnet (CGNAT)
      ---
      name: viktor/immich-asset-paths-whitelist
      description: "Don't penalise legit Immich timeline bursts (mobile scrub, web grid)"
      whitelist:
        reason: "Immich asset endpoints are auth-gated; mobile scrub legitimately bursts"
        expression:
          - >
            evt.Parsed.target_fqdn == "immich.viktorbarzin.me" &&
            (evt.Parsed.request startsWith "/api/assets/" ||
             evt.Parsed.request startsWith "/api/timeline/" ||
             evt.Parsed.request startsWith "/api/asset/" ||
             evt.Parsed.request startsWith "/api/search/" ||
             evt.Parsed.request startsWith "/api/memories" ||
             evt.Parsed.request startsWith "/api/albums" ||
             evt.Parsed.request startsWith "/api/activities")
      ---
      name: viktor/nextcloud-webdav-whitelist
      description: "Nextcloud WebDAV paths carry the account name 'admin' — not admin-panel probing"
      whitelist:
        reason: "Nextcloud-iOS/desktop PROPFIND 404s on /remote.php/dav/files/admin/... are legit sync misses; crowdsecurity/http-admin-interface-probing matches 'admin' in the path and banned the client's shared egress IP (Viktor's London Hyperoptic line, 2026-07-19). Scoped by traefik_router_name (traefik CLF access logs do NOT populate target_fqdn) plus the Nextcloud-exclusive /remote.php/ prefix. Nextcloud's own auth (401/403) still gates it."
        expression:
          - >
            evt.Parsed.traefik_router_name contains "nextcloud-viktorbarzin-me" &&
            evt.Parsed.request startsWith "/remote.php/"
    YAML
  }
}


# Syslog acquisition config for pfSense firewall log ingestion
resource "kubernetes_config_map" "crowdsec_syslog_acquisition" {
  metadata {
    name      = "crowdsec-syslog-acquisition"
    namespace = kubernetes_namespace.crowdsec.metadata[0].name
    labels = {
      "app.kubernetes.io/name" = "crowdsec"
    }
  }

  data = {
    "syslog.yaml" = <<-YAML
      source: syslog
      listen_addr: "0.0.0.0"
      listen_port: 514
      labels:
        type: pf
    YAML
  }
}

resource "helm_release" "crowdsec" {
  namespace        = kubernetes_namespace.crowdsec.metadata[0].name
  create_namespace = true
  name             = "crowdsec"
  atomic           = true
  version          = "0.21.0"

  repository = "https://crowdsecurity.github.io/helm-charts"
  chart      = "crowdsec"

  values        = [templatefile("${path.module}/values.yaml", { homepage_username = var.homepage_username, homepage_password = var.homepage_password, DB_PASSWORD = var.db_password, ENROLL_KEY = var.enroll_key, SLACK_WEBHOOK_URL = var.slack_webhook_url, mysql_host = var.mysql_host, postgresql_host = var.postgresql_host, KVSYNC_CROWDSEC_API_KEY = var.kvsync_bouncer_key, FIREWALL_CROWDSEC_API_KEY = var.firewall_bouncer_key })]
  timeout       = 1200
  wait          = true
  wait_for_jobs = true
}

# NodePort service for pfSense syslog → CrowdSec agent
# pfSense sends firewall logs to 10.0.20.202:30514 (any k8s node IP works)
resource "kubernetes_service" "crowdsec_syslog" {
  metadata {
    name      = "crowdsec-syslog"
    namespace = kubernetes_namespace.crowdsec.metadata[0].name
    labels = {
      app = "crowdsec-syslog"
    }
  }
  spec {
    type = "NodePort"
    selector = {
      "k8s-app" = "crowdsec"
      type      = "agent"
    }
    port {
      name        = "syslog-udp"
      port        = 514
      target_port = 514
      node_port   = 30514
      protocol    = "UDP"
    }
  }
}

# Deployment for my custom dashboard that helps me unblock myself when I blocklist myself
resource "kubernetes_deployment" "crowdsec-web" {
  metadata {
    name      = "crowdsec-web"
    namespace = kubernetes_namespace.crowdsec.metadata[0].name
    labels = {
      app                             = "crowdsec_web"
      "kubernetes.io/cluster-service" = "true"
      tier                            = var.tier
    }
  }
  spec {
    replicas = 1
    strategy {
      type = "RollingUpdate"
    }
    selector {
      match_labels = {
        app = "crowdsec_web"
      }
    }
    template {
      metadata {
        labels = {
          app                             = "crowdsec_web"
          "kubernetes.io/cluster-service" = "true"
        }
      }
      spec {
        priority_class_name = "tier-1-cluster"
        container {
          name  = "crowdsec-web"
          image = "viktorbarzin/crowdsec_web"
          env {
            name  = "CS_API_URL"
            value = "http://crowdsec-service.crowdsec.svc.cluster.local:8080/v1"
          }
          env {
            name  = "CS_API_KEY"
            value = var.crowdsec_dash_api_key
          }
          env {
            name  = "CS_MACHINE_ID"
            value = var.crowdsec_dash_machine_id
          }
          env {
            name  = "CS_MACHINE_PASSWORD"
            value = var.crowdsec_dash_machine_password
          }
          port {
            name           = "http"
            container_port = 8000
            protocol       = "TCP"
          }
          resources {
            requests = {
              cpu    = "15m"
              memory = "128Mi"
            }
            limits = {
              memory = "128Mi"
            }
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

resource "kubernetes_service" "crowdsec-web" {
  metadata {
    name      = "crowdsec-web"
    namespace = kubernetes_namespace.crowdsec.metadata[0].name
    labels = {
      "app" = "crowdsec_web"
    }
  }

  spec {
    selector = {
      app = "crowdsec_web"
    }
    port {
      port        = "80"
      target_port = "8000"
    }
  }
}
module "ingress" {
  source          = "../../../../modules/kubernetes/ingress_factory"
  dns_type        = "proxied"
  namespace       = kubernetes_namespace.crowdsec.metadata[0].name
  name            = "crowdsec-web"
  # Pin service_name explicitly (== name, so routing is unchanged) so
  # ingress_factory's real-ip auto-attach — startswith(var.service_name,
  # "anubis-") at ingress_factory/main.tf — doesn't hit the module's null
  # default and abort the whole crowdsec apply. Kept local to this stack; the
  # shared-module null-guard is a broader regression left to the in-flight
  # ingress_factory work (fixing it there forces a full-platform re-apply).
  service_name    = "crowdsec-web"
  auth            = "required"
  tls_secret_name = var.tls_secret_name
  extra_annotations = {
    "gethomepage.dev/icon" = "crowdsec.png"
  }
}

# CronJob to import public blocklists into CrowdSec
# https://github.com/wolffcatskyy/crowdsec-blocklist-import
# Uses kubectl exec to run in an existing CrowdSec agent pod that's already registered
resource "kubernetes_cron_job_v1" "crowdsec_blocklist_import" {
  metadata {
    name      = "crowdsec-blocklist-import"
    namespace = kubernetes_namespace.crowdsec.metadata[0].name
    labels = {
      app  = "crowdsec-blocklist-import"
      tier = var.tier
    }
  }

  spec {
    # Run daily at 4 AM
    schedule                      = "0 4 * * *"
    timezone                      = "Europe/London"
    concurrency_policy            = "Forbid"
    successful_jobs_history_limit = 3
    failed_jobs_history_limit     = 3

    job_template {
      metadata {
        labels = {
          app = "crowdsec-blocklist-import"
        }
      }

      spec {
        backoff_limit = 3
        template {
          metadata {
            labels = {
              app = "crowdsec-blocklist-import"
            }
          }

          spec {
            service_account_name = kubernetes_service_account.blocklist_import.metadata[0].name
            restart_policy       = "OnFailure"

            container {
              name  = "blocklist-import"
              image = "bitnami/kubectl:latest"

              command = ["/bin/bash", "-c"]
              args = [
                <<-EOF
                set -e

                echo "Finding CrowdSec agent pod..."
                AGENT_POD=$(kubectl get pods -n crowdsec -l k8s-app=crowdsec,type=agent -o jsonpath='{.items[0].metadata.name}')

                if [ -z "$AGENT_POD" ]; then
                  echo "ERROR: Could not find CrowdSec agent pod"
                  exit 1
                fi

                echo "Using agent pod: $AGENT_POD"

                # Download the import script
                echo "Downloading blocklist import script..."
                curl -fsSL -o /tmp/import.sh \
                  https://raw.githubusercontent.com/wolffcatskyy/crowdsec-blocklist-import/main/import.sh
                chmod +x /tmp/import.sh

                # Copy script to agent pod and execute
                echo "Copying script to agent pod and executing..."
                kubectl cp /tmp/import.sh crowdsec/$AGENT_POD:/tmp/import.sh

                kubectl exec -n crowdsec "$AGENT_POD" -- /bin/bash -c '
                  set -e

                  # Run with native mode since we are inside the CrowdSec container
                  export MODE=native
                  export DECISION_DURATION=168h
                  export FETCH_TIMEOUT=60
                  export LOG_LEVEL=INFO

                  /tmp/import.sh

                  # Cleanup
                  rm -f /tmp/import.sh
                '

                echo "Blocklist import completed successfully!"
                EOF
              ]
            }
          }
        }
      }
    }
  }
  lifecycle {
    # KYVERNO_LIFECYCLE_V1: Kyverno admission webhook mutates dns_config with ndots=2
    ignore_changes = [spec[0].job_template[0].spec[0].template[0].spec[0].dns_config]
  }
}

# Service account for the blocklist import job (needs kubectl exec permissions)
resource "kubernetes_service_account" "blocklist_import" {
  metadata {
    name      = "crowdsec-blocklist-import"
    namespace = kubernetes_namespace.crowdsec.metadata[0].name
  }
}

resource "kubernetes_role" "blocklist_import" {
  metadata {
    name      = "crowdsec-blocklist-import"
    namespace = kubernetes_namespace.crowdsec.metadata[0].name
  }

  rule {
    api_groups = [""]
    resources  = ["pods"]
    verbs      = ["get", "list"]
  }
  rule {
    api_groups = [""]
    resources  = ["pods/exec"]
    verbs      = ["create"]
  }
}

resource "kubernetes_role_binding" "blocklist_import" {
  metadata {
    name      = "crowdsec-blocklist-import"
    namespace = kubernetes_namespace.crowdsec.metadata[0].name
  }

  role_ref {
    api_group = "rbac.authorization.k8s.io"
    kind      = "Role"
    name      = kubernetes_role.blocklist_import.metadata[0].name
  }

  subject {
    kind      = "ServiceAccount"
    name      = kubernetes_service_account.blocklist_import.metadata[0].name
    namespace = kubernetes_namespace.crowdsec.metadata[0].name
  }
}

# Custom ResourceQuota for CrowdSec — needs more than default 1-cluster quota
# because it runs DaemonSet agents (1 per worker node) + 3 LAPI replicas + web UI
resource "kubernetes_resource_quota" "crowdsec" {
  metadata {
    name      = "crowdsec-quota"
    namespace = kubernetes_namespace.crowdsec.metadata[0].name
  }
  spec {
    hard = {
      "requests.cpu"    = "4"
      "requests.memory" = "8Gi"
      "limits.memory"   = "16Gi"
      pods              = "30"
    }
  }
}
