variable "tls_secret_name" {}
variable "tier" { type = string }
variable "homepage_token" {}
variable "mysql_host" { type = string }
variable "postgresql_host" { type = string }
variable "technitium_username" { type = string }
variable "technitium_password" {
  type      = string
  sensitive = true
}

resource "kubernetes_namespace" "technitium" {
  metadata {
    name = "technitium"
    labels = {
      tier               = var.tier
      "keel.sh/enrolled" = "true"
    }
    # stale cache error when trying to resolve
    # labels = {
    #   "istio-injection" : "enabled"
    # }
  }
  lifecycle {
    # KYVERNO_LIFECYCLE_V1: goldilocks-vpa-auto-mode ClusterPolicy stamps this label on every namespace
    ignore_changes = [metadata[0].labels["goldilocks.fairwinds.com/vpa-update-mode"]]
  }
}

module "tls_secret" {
  source          = "../../../../modules/kubernetes/setup_tls_secret"
  namespace       = kubernetes_namespace.technitium.metadata[0].name
  tls_secret_name = var.tls_secret_name
}

# Traefik Service ClusterIP for the CoreDNS viktorbarzin.me block below.
# Pods cannot use the Traefik LB IP (.203, externalTrafficPolicy=Local — only
# nodes with a local Traefik endpoint answer), so in-cluster answers must
# target the ClusterIP. Read from the live Service so a recreate can never
# leave a stale literal (same pattern as the woodpecker-server hostAlias fix).
data "kubernetes_service" "traefik" {
  metadata {
    name      = "traefik"
    namespace = "traefik"
  }
}

# CoreDNS Corefile - manages cluster DNS resolution
# The viktorbarzin.lan block forwards to Technitium via ClusterIP (stable, LB-independent).
# A template regex in the viktorbarzin.lan block short-circuits junk queries
# caused by ndots:5 search domain expansion (e.g. www.cloudflare.com.viktorbarzin.lan,
# redis.redis.svc.cluster.local.viktorbarzin.lan) by returning NXDOMAIN for any
# query with 2+ labels before .viktorbarzin.lan. Legitimate single-label queries
# (e.g. idrac.viktorbarzin.lan) fall through to Technitium.
resource "kubernetes_config_map" "coredns" {
  metadata {
    name      = "coredns"
    namespace = "kube-system"
  }

  data = {
    Corefile = <<-EOF
      .:53 {
        #log
          errors
          health {
              lameduck 5s
          }
          ready
          kubernetes cluster.local in-addr.arpa ip6.arpa {
              pods insecure
              fallthrough in-addr.arpa ip6.arpa
              ttl 30
          }
          prometheus :9153
          forward . 10.0.20.1 8.8.8.8 1.1.1.1 {
              policy sequential
              health_check 5s
              max_fails 2
          }
          cache {
            success 10000 300 6
            denial 10000 300 60
            serve_stale 86400s
          }
          loop
          reload
          loadbalance
      }
      # Dedicated zone for *.viktorbarzin.me as seen by PODS. Pods are
      # ordinary internal clients: same split-horizon answers as every
      # node/VM/laptop (ingress hosts CNAME -> apex -> live Traefik LB;
      # mail -> 10.0.20.1; vlmcs -> 10.0.20.202). Forwards to the SAME
      # Technitium ClusterIP the viktorbarzin.lan block below uses.
      # Verified 2026-06-10 on k8s 1.34: pods DO reach the ETP=Local LB IP
      # (kube-proxy short-circuits in-cluster traffic to LB IPs via the
      # cluster path) — re-verify after major k8s upgrades; the canary is
      # the uptime-kuma [External] monitor fleet going red.
      # forgejo stays pinned to Traefik's ClusterIP (hosts plugin) so CI
      # pushes survive a Technitium outage; the kubernetes plugin isn't in
      # this block so a Service-name rewrite cannot resolve here.
      # History: until 2026-06-10 (evening) this block forwarded to public
      # 8.8.8.8/1.1.1.1, which sent pods to the WAN IP and the broken
      # TP-Link NAT loopback — 27 non-proxied [External] monitors dark
      # (beads code-yh33 — in-cluster *.viktorbarzin.me hairpin).
      viktorbarzin.me:53 {
        errors
        hosts {
          ${data.kubernetes_service.traefik.spec.0.cluster_ip} forgejo.viktorbarzin.me
          fallthrough
        }
        forward . 10.96.0.53 {
            policy sequential
            health_check 5s
            max_fails 2
        }
        cache {
          success 10000 300 6
          denial 10000 300 60
          serve_stale 86400s
        }
        reload
      }
      viktorbarzin.lan:53 {
        #log
        errors
        template ANY ANY viktorbarzin.lan {
          match ".*\..*\.viktorbarzin\.lan\.$"
          rcode NXDOMAIN
          fallthrough
        }
        forward . 10.96.0.53 {
          health_check 5s
          max_fails 2
        }
        cache {
          success 10000 300 6
          denial 10000 300 60
          serve_stale 86400s
        }
      }
    EOF
  }
}

resource "kubernetes_persistent_volume_claim" "primary_config_encrypted" {
  wait_until_bound = false
  metadata {
    name      = "technitium-primary-config-encrypted"
    namespace = kubernetes_namespace.technitium.metadata[0].name
    annotations = {
      "resize.topolvm.io/threshold"     = "10%"
      "resize.topolvm.io/increase"      = "100%"
      "resize.topolvm.io/storage_limit" = "5Gi"
    }
  }
  spec {
    access_modes       = ["ReadWriteOnce"]
    storage_class_name = "proxmox-lvm-encrypted"
    resources {
      requests = {
        storage = "2Gi"
      }
    }
  }
  lifecycle {
    # Autoresizer expands; PVCs can't shrink. Without this, TF apply
    # plans destroy+recreate which leaves the PVC in Terminating while
    # the technitium primary pod still uses it. See incident on
    # 2026-05-10 (both prometheus-data-proxmox + this PVC).
    ignore_changes = [spec[0].resources[0].requests]
  }
}

resource "kubernetes_deployment" "technitium" {
  # resource "kubernetes_daemonset" "technitium" {
  metadata {
    name      = "technitium"
    namespace = kubernetes_namespace.technitium.metadata[0].name
    labels = {
      app  = "technitium"
      tier = var.tier
    }
  }
  spec {
    strategy {
      type = "Recreate"
    }
    # replicas = 1
    selector {
      match_labels = {
        app = "technitium"
      }
    }
    template {
      metadata {
        annotations = {
          "diun.enable"       = "true"
          "diun.include_tags" = "^\\d+\\.\\d+\\.\\d+$"
        }
        labels = {
          app          = "technitium"
          "dns-server" = "true"
        }
      }
      spec {
        affinity {
          # Spread DNS pods across nodes for HA
          pod_anti_affinity {
            required_during_scheduling_ignored_during_execution {
              label_selector {
                match_expressions {
                  key      = "dns-server"
                  operator = "In"
                  values   = ["true"]
                }
              }
              topology_key = "kubernetes.io/hostname"
            }
          }
        }
        container {
          image = "technitium/dns-server:14.3.0"
          name  = "technitium"
          resources {
            requests = {
              cpu    = "100m"
              memory = "1Gi"
            }
            limits = {
              memory = "1Gi"
            }
          }
          port {
            container_port = 5380
          }
          port {
            container_port = 53
          }
          port {
            container_port = 80
          }
          liveness_probe {
            tcp_socket {
              port = 53
            }
            initial_delay_seconds = 10
            period_seconds        = 10
          }
          readiness_probe {
            tcp_socket {
              port = 53
            }
            initial_delay_seconds = 5
            period_seconds        = 5
          }
          volume_mount {
            mount_path = "/etc/dns"
            name       = "nfs-config"
          }
          volume_mount {
            mount_path = "/etc/tls/"
            name       = "tls-cert"
          }
        }
        volume {
          name = "nfs-config"
          persistent_volume_claim {
            claim_name = kubernetes_persistent_volume_claim.primary_config_encrypted.metadata[0].name
          }
        }
        volume {
          name = "tls-cert"
          secret {
            secret_name = var.tls_secret_name
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

resource "kubernetes_service" "technitium-web" {
  metadata {
    name      = "technitium-web"
    namespace = kubernetes_namespace.technitium.metadata[0].name
    labels = {
      "app" = "technitium"
    }
    # annotations = {
    #   "metallb.universe.tf/allow-shared-ip" : "shared"
    # }
  }

  spec {
    # type                    = "LoadBalancer"
    # external_traffic_policy = "Cluster"
    selector = {
      app = "technitium"
    }
    port {
      name     = "technitium-dns"
      port     = "5380"
      protocol = "TCP"
    }
    port {
      name     = "technitium-doh"
      port     = "80"
      protocol = "TCP"
    }
  }
}

resource "kubernetes_service" "technitium-dns" {
  metadata {
    name      = "technitium-dns"
    namespace = kubernetes_namespace.technitium.metadata[0].name
    labels = {
      "app" = "technitium"
    }
    annotations = {
      "metallb.io/loadBalancerIPs" = "10.0.20.201"
    }
  }

  spec {
    type = "LoadBalancer"
    port {
      name     = "dns-udp"
      port     = 53
      protocol = "UDP"
    }
    port {
      name     = "dns-tcp"
      port     = 53
      protocol = "TCP"
    }
    external_traffic_policy = "Local"
    selector = {
      "dns-server" = "true"
    }
  }
}

# Fixed ClusterIP for CoreDNS forwarding — bypasses MetalLB entirely.
# IP 10.96.0.53 is pinned so it survives Service recreation.
resource "kubernetes_service" "technitium_dns_internal" {
  metadata {
    name      = "technitium-dns-internal"
    namespace = kubernetes_namespace.technitium.metadata[0].name
    labels = {
      app = "technitium"
    }
  }
  spec {
    type       = "ClusterIP"
    cluster_ip = "10.96.0.53"
    selector = {
      "dns-server" = "true"
    }
    port {
      name     = "dns-udp"
      port     = 53
      protocol = "UDP"
    }
    port {
      name     = "dns-tcp"
      port     = 53
      protocol = "TCP"
    }
  }
}

module "ingress" {
  source          = "../../../../modules/kubernetes/ingress_factory"
  auth            = "required"
  dns_type        = "proxied"
  namespace       = kubernetes_namespace.technitium.metadata[0].name
  name            = "technitium"
  tls_secret_name = var.tls_secret_name
  port            = 5380
  service_name    = "technitium-web"
  extra_annotations = {
    "gethomepage.dev/enabled"     = "true"
    "gethomepage.dev/description" = "Internal DNS Server and Recursive Resolver"
    "gethomepage.dev/group"       = "Infrastructure"
    "gethomepage.dev/icon" : "technitium.png"
    "gethomepage.dev/name"        = "Technitium"
    "gethomepage.dev/widget.type" = "technitium"
    "gethomepage.dev/widget.url"  = "http://technitium-web.technitium.svc.cluster.local:5380"
    "gethomepage.dev/widget.key"  = var.homepage_token

    "gethomepage.dev/widget.range"  = "LastWeek"
    "gethomepage.dev/widget.fields" = "[\"totalQueries\", \"totalCached\", \"totalBlocked\", \"totalRecursive\"]"
    "gethomepage.dev/pod-selector"  = ""
  }
}

# DoH ingress removed — dns.viktorbarzin.me was externally unreachable and unused.
# DNS is served on UDP/TCP port 53 via the LoadBalancer service (10.0.20.201).
# module "ingress-doh" {
#   source          = "../../../../modules/kubernetes/ingress_factory"
#   namespace       = kubernetes_namespace.technitium.metadata[0].name
#   name            = "technitium-doh"
#   tls_secret_name = var.tls_secret_name
#   host            = "dns"
#   service_name    = "technitium-web"
# }

# ExternalSecret for Technitium MySQL password (Vault auto-rotation)
resource "kubernetes_manifest" "external_secret" {
  manifest = {
    apiVersion = "external-secrets.io/v1beta1"
    kind       = "ExternalSecret"
    metadata = {
      name      = "technitium-db-creds"
      namespace = kubernetes_namespace.technitium.metadata[0].name
    }
    spec = {
      refreshInterval = "15m"
      secretStoreRef = {
        name = "vault-database"
        kind = "ClusterSecretStore"
      }
      target = {
        name = "technitium-db-creds"
      }
      data = [{
        secretKey = "db_password"
        remoteRef = {
          key      = "static-creds/mysql-technitium"
          property = "password"
        }
      }]
    }
  }
  depends_on = [kubernetes_namespace.technitium]
}

data "kubernetes_secret" "technitium_db_creds" {
  metadata {
    name      = "technitium-db-creds"
    namespace = kubernetes_namespace.technitium.metadata[0].name
  }
  depends_on = [kubernetes_manifest.external_secret]
}

# Grafana datasource for Technitium DNS query logs in PostgreSQL
resource "kubernetes_config_map" "grafana_technitium_datasource" {
  metadata {
    name      = "grafana-technitium-datasource"
    namespace = "monitoring"
    labels = {
      grafana_datasource = "1"
    }
  }
  data = {
    "technitium-datasource.yaml" = yamlencode({
      apiVersion = 1
      datasources = [{
        name     = "Technitium PostgreSQL"
        type     = "postgres"
        access   = "proxy"
        url      = "${var.postgresql_host}:5432"
        database = "technitium"
        user     = "technitium"
        uid      = "technitium-pg"
        jsonData = {
          sslmode         = "disable"
          postgresVersion = 1600
          timescaledb     = false
        }
        secureJsonData = {
          password = data.kubernetes_secret.technitium_db_creds.data["db_password"]
        }
      }]
    })
  }
}

# Grafana dashboard for Technitium DNS query logs
resource "kubernetes_config_map" "grafana_technitium_dashboard" {
  metadata {
    name      = "grafana-technitium-dashboard"
    namespace = "monitoring"
    labels = {
      grafana_dashboard = "1"
    }
    annotations = {
      grafana_folder = "Networking"
    }
  }
  data = {
    "technitium-dns.json" = file("${path.module}/dashboards/technitium-dns.json")
  }
}

# CronJob to sync Vault-rotated MySQL password into Technitium's app config
resource "kubernetes_cron_job_v1" "technitium_password_sync" {
  metadata {
    name      = "technitium-password-sync"
    namespace = kubernetes_namespace.technitium.metadata[0].name
  }
  spec {
    schedule                      = "0 */6 * * *"
    successful_jobs_history_limit = 1
    failed_jobs_history_limit     = 3
    job_template {
      metadata {}
      spec {
        template {
          metadata {}
          spec {
            container {
              name  = "sync"
              image = "curlimages/curl:latest"
              resources {
                requests = {
                  cpu    = "10m"
                  memory = "32Mi"
                }
                limits = {
                  memory = "32Mi"
                }
              }
              env {
                name = "DB_PASSWORD"
                value_from {
                  secret_key_ref {
                    name = "technitium-db-creds"
                    key  = "db_password"
                  }
                }
              }
              env {
                name  = "TECH_USER"
                value = var.technitium_username
              }
              env {
                name  = "TECH_PASS"
                value = var.technitium_password
              }
              command = ["/bin/sh", "-c", <<-EOT
                set -e
                TOKEN=$$(curl -sf "http://technitium-web:5380/api/user/login?user=$$TECH_USER&pass=$$TECH_PASS" | grep -o '"token":"[^"]*"' | cut -d'"' -f4)
                if [ -z "$$TOKEN" ]; then echo "Login failed"; exit 1; fi

                # Uninstall MySQL + SQLite query log plugins if present.
                # These must be REMOVED, not just disabled — Technitium re-enables
                # disabled plugins on pod restart, causing 46+ GB/day of writes.
                # Only PostgreSQL query logging should remain.
                APPS=$$(curl -sf "http://technitium-web:5380/api/apps/list?token=$$TOKEN")
                if echo "$$APPS" | grep -q 'Query Logs (MySQL)'; then
                  curl -sf -X POST "http://technitium-web:5380/api/apps/uninstall?token=$$TOKEN&name=Query%20Logs%20(MySQL)"
                  echo "MySQL query log plugin UNINSTALLED"
                else
                  echo "MySQL query log plugin already absent"
                fi
                if echo "$$APPS" | grep -q 'Query Logs (Sqlite)'; then
                  curl -sf -X POST "http://technitium-web:5380/api/apps/uninstall?token=$$TOKEN&name=Query%20Logs%20(Sqlite)"
                  echo "SQLite query log plugin UNINSTALLED"
                else
                  echo "SQLite query log plugin already absent"
                fi

                # Ensure PG plugin is loaded
                if ! echo "$$APPS" | grep -q 'Query Logs (Postgres)'; then
                  echo "WARNING: PG plugin not loaded — reinstall manually via Technitium UI"
                fi

                # Configure PG query logging (updates password from Vault rotation)
                PG_CONFIG="{\"enableLogging\":true,\"maxQueueSize\":1000000,\"maxLogDays\":90,\"maxLogRecords\":0,\"databaseName\":\"technitium\",\"connectionString\":\"Host=${var.postgresql_host}; Port=5432; Username=technitium; Password=$$DB_PASSWORD;\"}"
                curl -sf -X POST "http://technitium-web:5380/api/apps/config/set?token=$$TOKEN" --data-urlencode "name=Query Logs (Postgres)" --data-urlencode "config=$$PG_CONFIG"
                echo "PG logging configured on primary"

                # Uninstall MySQL/SQLite on secondary and tertiary instances too
                for INST in http://technitium-secondary-web:5380 http://technitium-tertiary-web:5380; do
                  echo "Configuring $$INST"
                  R_TOKEN=$$(curl -sf "$$INST/api/user/login?user=$$TECH_USER&pass=$$TECH_PASS" | grep -o '"token":"[^"]*"' | cut -d'"' -f4)
                  if [ -z "$$R_TOKEN" ]; then echo "Login failed for $$INST, skipping"; continue; fi
                  R_APPS=$$(curl -sf "$$INST/api/apps/list?token=$$R_TOKEN")
                  echo "$$R_APPS" | grep -q 'Query Logs (MySQL)' && curl -sf -X POST "$$INST/api/apps/uninstall?token=$$R_TOKEN&name=Query%20Logs%20(MySQL)" && echo "MySQL uninstalled on $$INST"
                  echo "$$R_APPS" | grep -q 'Query Logs (Sqlite)' && curl -sf -X POST "$$INST/api/apps/uninstall?token=$$R_TOKEN&name=Query%20Logs%20(Sqlite)" && echo "SQLite uninstalled on $$INST"
                done
                echo "Password sync complete"
              EOT
              ]
            }
            restart_policy = "OnFailure"
          }
        }
      }
    }
  }
}

# CronJob to configure Split Horizon AddressTranslation on all Technitium instances.
# Translates 176.12.22.76 (public IP) → 10.0.20.203 (Traefik LB) in DNS responses
# for 192.168.1.x clients, fixing hairpin NAT on the TP-Link router.
# Also configures DNS Rebinding Protection to allow viktorbarzin.me to return private IPs
# (otherwise the translated 10.0.20.203 gets stripped as a rebinding attack).
resource "kubernetes_cron_job_v1" "technitium_split_horizon_sync" {
  metadata {
    name      = "technitium-split-horizon-sync"
    namespace = kubernetes_namespace.technitium.metadata[0].name
  }
  spec {
    schedule                      = "15 */6 * * *"
    successful_jobs_history_limit = 1
    failed_jobs_history_limit     = 3
    job_template {
      metadata {}
      spec {
        template {
          metadata {}
          spec {
            container {
              name  = "sync"
              image = "curlimages/curl:latest"
              resources {
                requests = {
                  cpu    = "10m"
                  memory = "32Mi"
                }
                limits = {
                  memory = "32Mi"
                }
              }
              env {
                name  = "TECH_USER"
                value = var.technitium_username
              }
              env {
                name  = "TECH_PASS"
                value = var.technitium_password
              }
              command = ["/bin/sh", "-c", <<-EOT
                set -e
                SPLIT_CONFIG='{"networks":{},"enableAddressTranslation":true,"domainGroupMap":{},"networkGroupMap":{"192.168.1.0/24":"sofia-lan"},"groups":[{"name":"sofia-lan","enabled":true,"translateReverseLookups":false,"externalToInternalTranslation":{"176.12.22.76":"10.0.20.203"}}]}'
                REBINDING_CONFIG='{"enableProtection":true,"bypassNetworks":[],"privateNetworks":["10.0.0.0/8","127.0.0.0/8","172.16.0.0/12","192.168.0.0/16","169.254.0.0/16","fc00::/7","fe80::/10"],"privateDomains":["home.arpa","viktorbarzin.me"]}'
                SPLIT_URL="https://download.technitium.com/dns/apps/SplitHorizonApp-v10.zip"
                REBINDING_URL="https://download.technitium.com/dns/apps/DnsRebindingProtectionApp-v4.zip"
                INSTANCES="http://technitium-web:5380 http://technitium-secondary-web:5380 http://technitium-tertiary-web:5380"

                for INST in $$INSTANCES; do
                  echo "=== Configuring $$INST ==="
                  TOKEN=$$(curl -sf "$$INST/api/user/login?user=$$TECH_USER&pass=$$TECH_PASS" | grep -o '"token":"[^"]*"' | cut -d'"' -f4)
                  if [ -z "$$TOKEN" ]; then echo "Login failed for $$INST, skipping"; continue; fi

                  curl -sf -X POST "$$INST/api/apps/downloadAndInstall?token=$$TOKEN&name=Split%20Horizon&url=$$SPLIT_URL" || true
                  curl -sf -X POST "$$INST/api/apps/downloadAndInstall?token=$$TOKEN&name=DNS%20Rebinding%20Protection&url=$$REBINDING_URL" || true

                  curl -sf -X POST "$$INST/api/apps/config/set?token=$$TOKEN" --data-urlencode "name=Split Horizon" --data-urlencode "config=$$SPLIT_CONFIG"
                  curl -sf -X POST "$$INST/api/apps/config/set?token=$$TOKEN" --data-urlencode "name=DNS Rebinding Protection" --data-urlencode "config=$$REBINDING_CONFIG"

                  echo "Done with $$INST"
                done
                echo "Split Horizon sync complete"
              EOT
              ]
            }
            restart_policy = "OnFailure"
          }
        }
      }
    }
  }
}

# CronJob to apply DNS performance optimizations:
# 1. Set minimum cache TTL to 60s (avoids frequent re-queries for short-TTL domains like headscale's 18s)
# 2. Create emrsn.org stub zone → NXDOMAIN (avoids forwarding 27K+ daily corporate domain queries to Cloudflare)
resource "kubernetes_cron_job_v1" "technitium_dns_optimization" {
  metadata {
    name      = "technitium-dns-optimization"
    namespace = kubernetes_namespace.technitium.metadata[0].name
  }
  spec {
    schedule                      = "30 */6 * * *"
    successful_jobs_history_limit = 1
    failed_jobs_history_limit     = 3
    job_template {
      metadata {}
      spec {
        template {
          metadata {}
          spec {
            container {
              name  = "sync"
              image = "curlimages/curl:latest"
              resources {
                requests = {
                  cpu    = "10m"
                  memory = "32Mi"
                }
                limits = {
                  memory = "32Mi"
                }
              }
              env {
                name  = "TECH_USER"
                value = var.technitium_username
              }
              env {
                name  = "TECH_PASS"
                value = var.technitium_password
              }
              command = ["/bin/sh", "-c", <<-EOT
                set -e
                TOKEN=$$(curl -sf "http://technitium-web:5380/api/user/login?user=$$TECH_USER&pass=$$TECH_PASS" | grep -o '"token":"[^"]*"' | cut -d'"' -f4)
                if [ -z "$$TOKEN" ]; then echo "Login failed"; exit 1; fi

                # 1. Ensure minimum cache TTL is 60s (reduces re-queries for short-TTL domains)
                curl -sf -X POST "http://technitium-web:5380/api/settings/set?token=$$TOKEN&cacheMinimumRecordTtl=60"
                echo "Cache minimum TTL set to 60s"

                # 2. Stub zone for emrsn.org corporate domains
                # Returns NXDOMAIN immediately instead of forwarding to Cloudflare upstream
                curl -sf "http://technitium-web:5380/api/zones/create?token=$$TOKEN&domain=emrsn.org&type=Primary" || true
                curl -sf "http://technitium-web:5380/api/zones/options/set?token=$$TOKEN&zone=emrsn.org&zoneTransfer=Allow" || true
                echo "emrsn.org stub zone configured"

                echo "DNS optimization sync complete"
              EOT
              ]
            }
            restart_policy = "OnFailure"
          }
        }
      }
    }
  }
}

# viktorbarzin.me apex DNS drift probe
# Resolves `viktorbarzin.me A` against the Technitium LoadBalancer IP every
# 5 min and pushes a Pushgateway gauge. Backstop for the entire
# split-horizon zone: every internal `*.viktorbarzin.me` CNAME chains through
# this apex, so if it drifts (ISP rollover, accidental edit), this is the
# canary. Alerts: ViktorBarzinApexDrift, ApexProbeStale, ApexProbeNeverRun
# in stacks/monitoring/.
resource "kubernetes_cron_job_v1" "viktorbarzin_apex_probe" {
  metadata {
    name      = "viktorbarzin-apex-probe"
    namespace = kubernetes_namespace.technitium.metadata[0].name
  }
  spec {
    concurrency_policy            = "Replace"
    schedule                      = "*/5 * * * *"
    successful_jobs_history_limit = 1
    failed_jobs_history_limit     = 3
    job_template {
      metadata {}
      spec {
        backoff_limit              = 1
        ttl_seconds_after_finished = 300
        template {
          metadata {}
          spec {
            container {
              name  = "probe"
              image = "docker.io/library/python:3.12-alpine"
              resources {
                requests = {
                  cpu    = "10m"
                  memory = "48Mi"
                }
                limits = {
                  memory = "96Mi"
                }
              }
              command = ["/bin/sh", "-c", <<-EOT
                pip install --quiet --disable-pip-version-check dnspython requests && python3 -c '
import dns.resolver, requests, time, sys

EXPECTED = {"10.0.20.203"}
NAMESERVER = "10.0.20.201"  # Technitium LB IP
NAME = "viktorbarzin.me"
PUSHGATEWAY = "http://prometheus-prometheus-pushgateway.monitoring:9091/metrics/job/viktorbarzin-apex-probe"

resolver = dns.resolver.Resolver(configure=False)
resolver.nameservers = [NAMESERVER]
resolver.timeout = 5
resolver.lifetime = 8

correct = 0
observed = "unknown"
try:
    answer = resolver.resolve(NAME, "A")
    ips = sorted(str(r) for r in answer)
    observed = ",".join(ips)
    correct = 1 if set(ips) <= EXPECTED and ips else 0
    print(f"apex {NAME} -> {observed} (expected one of {EXPECTED}); correct={correct}")
except Exception as e:
    observed = f"error:{type(e).__name__}"
    print(f"resolve error: {e}", file=sys.stderr)

metric_lines = [
    "# HELP viktorbarzin_apex_correct 1 if viktorbarzin.me apex resolves to expected IP, 0 otherwise",
    "# TYPE viktorbarzin_apex_correct gauge",
    f"viktorbarzin_apex_correct {correct}",
]
if correct:
    metric_lines += [
        "# HELP viktorbarzin_apex_last_correct_timestamp Unix time of last correct resolution",
        "# TYPE viktorbarzin_apex_last_correct_timestamp gauge",
        f"viktorbarzin_apex_last_correct_timestamp {int(time.time())}",
    ]
metrics = "\n".join(metric_lines) + "\n"
try:
    r = requests.post(PUSHGATEWAY, data=metrics, timeout=10)
    print(f"pushgateway: {r.status_code}")
except Exception as e:
    print(f"pushgateway error: {e}", file=sys.stderr)
sys.exit(0 if correct else 1)
'
              EOT
              ]
            }
            dns_config {
              option {
                name  = "ndots"
                value = "2"
              }
            }
            restart_policy = "OnFailure"
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


# ServiceAccount + RBAC for the ingress-dns-sync CronJob to list ingresses cluster-wide.
resource "kubernetes_service_account" "ingress_dns_sync" {
  metadata {
    name      = "ingress-dns-sync"
    namespace = kubernetes_namespace.technitium.metadata[0].name
  }
}

resource "kubernetes_cluster_role" "ingress_dns_sync" {
  metadata {
    name = "ingress-dns-sync"
  }
  rule {
    api_groups = ["networking.k8s.io"]
    resources  = ["ingresses"]
    verbs      = ["list"]
  }
  # Read the Traefik LoadBalancer Service so the sync can pin the
  # ingress.viktorbarzin.lan anchor to the live Traefik LB IP (see CronJob).
  rule {
    api_groups = [""]
    resources  = ["services"]
    verbs      = ["get", "list"]
  }
}

resource "kubernetes_cluster_role_binding" "ingress_dns_sync" {
  metadata {
    name = "ingress-dns-sync"
  }
  role_ref {
    api_group = "rbac.authorization.k8s.io"
    kind      = "ClusterRole"
    name      = kubernetes_cluster_role.ingress_dns_sync.metadata[0].name
  }
  subject {
    kind      = "ServiceAccount"
    name      = kubernetes_service_account.ingress_dns_sync.metadata[0].name
    namespace = kubernetes_namespace.technitium.metadata[0].name
  }
}

# CronJob to sync K8s Ingress hosts -> Technitium CNAME records.
# Discovers all *.viktorbarzin.me ingress hosts, ensures each has a CNAME
# pointing to viktorbarzin.me in Technitium's authoritative zone.
# Prevents the desync where Cloudflare has the record but internal DNS doesn't.
resource "kubernetes_cron_job_v1" "technitium_ingress_dns_sync" {
  metadata {
    name      = "technitium-ingress-dns-sync"
    namespace = kubernetes_namespace.technitium.metadata[0].name
  }
  spec {
    schedule                      = "0 * * * *"
    successful_jobs_history_limit = 1
    failed_jobs_history_limit     = 3
    job_template {
      metadata {}
      spec {
        template {
          metadata {}
          spec {
            service_account_name = kubernetes_service_account.ingress_dns_sync.metadata[0].name
            container {
              name  = "sync"
              image = "bitnami/kubectl:latest"
              resources {
                requests = {
                  cpu    = "10m"
                  memory = "32Mi"
                }
                limits = {
                  memory = "64Mi"
                }
              }
              env {
                name  = "TECH_USER"
                value = var.technitium_username
              }
              env {
                name  = "TECH_PASS"
                value = var.technitium_password
              }
              command = ["/bin/sh", "-c", <<-EOT
                set -e
                ZONE="viktorbarzin.me"
                TECH_API="http://technitium-web:5380"

                TOKEN=$$(curl -sf "$$TECH_API/api/user/login?user=$$TECH_USER&pass=$$TECH_PASS" | grep -o '"token":"[^"]*"' | cut -d'"' -f4)
                if [ -z "$$TOKEN" ]; then echo "Login failed"; exit 1; fi

                EXISTING=$$(curl -sf "$$TECH_API/api/zones/records/get?token=$$TOKEN&zone=$$ZONE&domain=$$ZONE&listZone=true" | grep -o '"name":"[^"]*\.viktorbarzin\.me"' | sed 's/"name":"//;s/"//' | sort -u)

                HOSTS=$$(kubectl get ingress -A -o jsonpath='{range .items[*]}{range .spec.rules[*]}{.host}{"\n"}{end}{end}' | grep "\.$$ZONE$$" | grep -v "^$$ZONE$$" | sort -u)

                CREATED=0
                for HOST in $$HOSTS; do
                  if echo "$$EXISTING" | grep -qx "$$HOST"; then
                    continue
                  fi
                  RESULT=$$(curl -sf "$$TECH_API/api/zones/records/add?token=$$TOKEN&zone=$$ZONE&domain=$$HOST&type=CNAME&cname=$$ZONE&ttl=86400" 2>&1) || true
                  if echo "$$RESULT" | grep -q '"status":"ok"'; then
                    echo "Created CNAME: $$HOST -> $$ZONE"
                    CREATED=$$((CREATED + 1))
                  elif echo "$$RESULT" | grep -q 'already exists'; then
                    echo "Already exists: $$HOST"
                  else
                    echo "Failed: $$HOST -- $$RESULT"
                  fi
                done
                echo "Sync complete. Created $$CREATED new records."

                # Pin the .lan ingress anchor A record to the LIVE Traefik LB IP.
                # *.viktorbarzin.lan ingress hosts CNAME to ingress.viktorbarzin.lan,
                # so a Traefik LB IP move that misses the .lan zone silently breaks
                # every internal exporter + HA-sourced sensor (regression 2026-05-30:
                # .200 -> .203 migration updated .me but not .lan). This keeps the
                # anchor self-correcting on future IP moves.
                TRAEFIK_IP=$$(kubectl get svc traefik -n traefik -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null)
                if [ -n "$$TRAEFIK_IP" ]; then
                  LAN_CUR=$$(curl -sf "$$TECH_API/api/zones/records/get?token=$$TOKEN&zone=viktorbarzin.lan&domain=ingress.viktorbarzin.lan&listZone=false" | grep -o '"ipAddress":"[^"]*"' | head -1 | cut -d'"' -f4)
                  if [ -z "$$LAN_CUR" ]; then
                    curl -sf "$$TECH_API/api/zones/records/add?token=$$TOKEN&zone=viktorbarzin.lan&domain=ingress.viktorbarzin.lan&type=A&ipAddress=$$TRAEFIK_IP&ttl=300" >/dev/null && echo "Added ingress.viktorbarzin.lan A -> $$TRAEFIK_IP"
                  elif [ "$$LAN_CUR" != "$$TRAEFIK_IP" ]; then
                    curl -sf "$$TECH_API/api/zones/records/update?token=$$TOKEN&zone=viktorbarzin.lan&domain=ingress.viktorbarzin.lan&type=A&ipAddress=$$LAN_CUR&newIpAddress=$$TRAEFIK_IP&ttl=300" >/dev/null && echo "Updated ingress.viktorbarzin.lan A: $$LAN_CUR -> $$TRAEFIK_IP"
                  else
                    echo "ingress.viktorbarzin.lan A already $$TRAEFIK_IP"
                  fi
                else
                  echo "WARN: could not resolve Traefik LB IP; skipping .lan anchor sync"
                fi
              EOT
              ]
            }
            restart_policy = "OnFailure"
          }
        }
      }
    }
  }
  lifecycle {
    ignore_changes = [spec[0].job_template[0].spec[0].template[0].spec[0].dns_config] # KYVERNO_LIFECYCLE_V1
  }
}
