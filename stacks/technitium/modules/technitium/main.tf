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
      tier = var.tier
    }
    # stale cache error when trying to resolve
    # labels = {
    #   "istio-injection" : "enabled"
    # }
  }
}

module "tls_secret" {
  source          = "../../../../modules/kubernetes/setup_tls_secret"
  namespace       = kubernetes_namespace.technitium.metadata[0].name
  tls_secret_name = var.tls_secret_name
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
          forward . 10.0.20.1 8.8.8.8 1.1.1.1
          cache {
            success 10000 300 6
            denial 10000 300 60
          }
          loop
          reload
          loadbalance
      }
      viktorbarzin.lan:53 {
        #log
        errors
        template ANY ANY viktorbarzin.lan {
          match ".*\..*\.viktorbarzin\.lan\.$"
          rcode NXDOMAIN
          fallthrough
        }
        forward . 10.96.0.53 # Technitium ClusterIP (technitium-dns-internal)
        cache {
          success 10000 300 6
          denial 10000 300 60
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
      "resize.topolvm.io/threshold"     = "80%"
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
              cpu    = "25m"
              memory = "512Mi"
            }
            limits = {
              memory = "512Mi"
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

module "ingress-doh" {
  source          = "../../../../modules/kubernetes/ingress_factory"
  namespace       = kubernetes_namespace.technitium.metadata[0].name
  name            = "technitium-doh"
  tls_secret_name = var.tls_secret_name
  host            = "dns"
  service_name    = "technitium-web"
}

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
# Translates 176.12.22.76 (public IP) → 10.0.20.200 (Traefik LB) in DNS responses
# for 192.168.1.x clients, fixing hairpin NAT on the TP-Link router.
# Also configures DNS Rebinding Protection to allow viktorbarzin.me to return private IPs
# (otherwise the translated 10.0.20.200 gets stripped as a rebinding attack).
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
                SPLIT_CONFIG='{"networks":{},"enableAddressTranslation":true,"domainGroupMap":{},"networkGroupMap":{"192.168.1.0/24":"sofia-lan"},"groups":[{"name":"sofia-lan","enabled":true,"translateReverseLookups":false,"externalToInternalTranslation":{"176.12.22.76":"10.0.20.200"}}]}'
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

