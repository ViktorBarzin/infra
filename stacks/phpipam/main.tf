variable "tls_secret_name" {
  type      = string
  sensitive = true
}
variable "mysql_host" { type = string }

data "vault_kv_secret_v2" "secrets" {
  mount = "secret"
  name  = "platform"
}

locals {
  technitium_password = data.vault_kv_secret_v2.secrets.data["technitium_password"]
}

resource "kubernetes_namespace" "phpipam" {
  metadata {
    name = "phpipam"
    labels = {
      tier = local.tiers.aux
    }
  }
}

resource "kubernetes_manifest" "external_secret" {
  manifest = {
    apiVersion = "external-secrets.io/v1beta1"
    kind       = "ExternalSecret"
    metadata = {
      name      = "phpipam-secrets"
      namespace = "phpipam"
    }
    spec = {
      refreshInterval = "15m"
      secretStoreRef = {
        name = "vault-database"
        kind = "ClusterSecretStore"
      }
      target = {
        name = "phpipam-secrets"
      }
      data = [{
        secretKey = "db_password"
        remoteRef = {
          key      = "static-creds/mysql-phpipam"
          property = "password"
        }
      }]
    }
  }
  depends_on = [kubernetes_namespace.phpipam]
}

resource "kubernetes_manifest" "external_secret_admin" {
  manifest = {
    apiVersion = "external-secrets.io/v1beta1"
    kind       = "ExternalSecret"
    metadata = {
      name      = "phpipam-admin-password"
      namespace = "phpipam"
    }
    spec = {
      refreshInterval = "1h"
      secretStoreRef = {
        name = "vault-kv"
        kind = "ClusterSecretStore"
      }
      target = {
        name = "phpipam-admin-password"
      }
      data = [{
        secretKey = "password"
        remoteRef = {
          key      = "viktor"
          property = "phpipam_admin_password"
        }
      }]
    }
  }
  depends_on = [kubernetes_namespace.phpipam]
}

module "tls_secret" {
  source          = "../../modules/kubernetes/setup_tls_secret"
  namespace       = kubernetes_namespace.phpipam.metadata[0].name
  tls_secret_name = var.tls_secret_name
}

resource "kubernetes_deployment" "phpipam_web" {
  metadata {
    name      = "phpipam-web"
    namespace = kubernetes_namespace.phpipam.metadata[0].name
    labels = {
      app  = "phpipam"
      tier = local.tiers.aux
    }
    annotations = {
      "reloader.stakater.com/auto" = "true"
    }
  }
  spec {
    replicas = 1
    strategy {
      type = "Recreate"
    }
    selector {
      match_labels = {
        app = "phpipam"
      }
    }
    template {
      metadata {
        labels = {
          app = "phpipam"
        }
        annotations = {
          "diun.enable"                    = "true"
          "dependency.kyverno.io/wait-for" = "mysql.dbaas:3306"
        }
      }
      spec {
        container {
          image = "phpipam/phpipam-www:v1.7.0"
          name  = "phpipam-web"
          port {
            container_port = 80
          }
          env {
            name  = "TZ"
            value = "Europe/Sofia"
          }
          env {
            name  = "IPAM_DATABASE_HOST"
            value = var.mysql_host
          }
          env {
            name  = "IPAM_DATABASE_USER"
            value = "phpipam"
          }
          env {
            name = "IPAM_DATABASE_PASS"
            value_from {
              secret_key_ref {
                name = "phpipam-secrets"
                key  = "db_password"
              }
            }
          }
          env {
            name  = "IPAM_DATABASE_NAME"
            value = "phpipam"
          }
          env {
            name  = "IPAM_TRUST_X_FORWARDED"
            value = "true"
          }
          resources {
            requests = {
              cpu    = "10m"
              memory = "64Mi"
            }
            limits = {
              memory = "256Mi"
            }
          }
        }
      }
    }
  }
  lifecycle {
    ignore_changes = [spec[0].template[0].spec[0].dns_config]
  }
}

resource "kubernetes_deployment" "phpipam_cron" {
  metadata {
    name      = "phpipam-cron"
    namespace = kubernetes_namespace.phpipam.metadata[0].name
    labels = {
      app       = "phpipam-cron"
      component = "scanner"
      tier      = local.tiers.aux
    }
    annotations = {
      "reloader.stakater.com/auto" = "true"
    }
  }
  spec {
    replicas = 1
    strategy {
      type = "Recreate"
    }
    selector {
      match_labels = {
        app = "phpipam-cron"
      }
    }
    template {
      metadata {
        labels = {
          app       = "phpipam-cron"
          component = "scanner"
        }
        annotations = {
          "dependency.kyverno.io/wait-for" = "mysql.dbaas:3306"
        }
      }
      spec {
        container {
          image = "phpipam/phpipam-cron:v1.7.0"
          name  = "phpipam-cron"
          env {
            name  = "TZ"
            value = "Europe/Sofia"
          }
          env {
            name  = "IPAM_DATABASE_HOST"
            value = var.mysql_host
          }
          env {
            name  = "IPAM_DATABASE_USER"
            value = "phpipam"
          }
          env {
            name = "IPAM_DATABASE_PASS"
            value_from {
              secret_key_ref {
                name = "phpipam-secrets"
                key  = "db_password"
              }
            }
          }
          env {
            name  = "IPAM_DATABASE_NAME"
            value = "phpipam"
          }
          env {
            name  = "SCAN_INTERVAL"
            value = "15m"
          }
          resources {
            requests = {
              cpu    = "10m"
              memory = "64Mi"
            }
            limits = {
              memory = "512Mi"
            }
          }
          security_context {
            capabilities {
              add = ["NET_RAW"]
            }
          }
        }
      }
    }
  }
  lifecycle {
    ignore_changes = [spec[0].template[0].spec[0].dns_config]
  }
}

resource "kubernetes_service" "phpipam" {
  metadata {
    name      = "phpipam"
    namespace = kubernetes_namespace.phpipam.metadata[0].name
    labels = {
      app = "phpipam"
    }
  }
  spec {
    selector = {
      app = "phpipam"
    }
    port {
      name        = "http"
      port        = 80
      target_port = 80
    }
  }
}

module "ingress" {
  source          = "../../modules/kubernetes/ingress_factory"
  namespace       = kubernetes_namespace.phpipam.metadata[0].name
  name            = "phpipam"
  tls_secret_name = var.tls_secret_name
  protected       = true
  extra_annotations = {
    "gethomepage.dev/enabled"      = "true"
    "gethomepage.dev/name"         = "phpIPAM"
    "gethomepage.dev/description"  = "IP Address Management"
    "gethomepage.dev/icon"         = "phpipam.png"
    "gethomepage.dev/group"        = "Infrastructure"
    "gethomepage.dev/pod-selector" = ""
  }
}

# CronJob: Bidirectional sync between phpIPAM and Technitium DNS
# 1. Push: named phpIPAM hosts → Technitium A + PTR records
# 2. Pull: Technitium reverse DNS → phpIPAM hostnames for unnamed entries
resource "kubernetes_cron_job_v1" "phpipam_dns_sync" {
  metadata {
    name      = "phpipam-dns-sync"
    namespace = kubernetes_namespace.phpipam.metadata[0].name
  }
  spec {
    schedule                      = "*/15 * * * *"
    successful_jobs_history_limit = 1
    failed_jobs_history_limit     = 3
    concurrency_policy            = "Forbid"
    job_template {
      metadata {}
      spec {
        backoff_limit = 1
        template {
          metadata {}
          spec {
            restart_policy = "Never"
            container {
              name  = "sync"
              image = "mysql:8.0"
              command = ["/bin/bash", "-c", <<-EOT
                set -e
                TECH_URL="http://technitium-web.technitium.svc.cluster.local:5380"

                # Login to Technitium
                TECH_TOKEN=$$(curl -sf "$$TECH_URL/api/user/login?user=admin&pass=$$TECH_PASS" | sed 's/.*"token":"\([^"]*\)".*/\1/')
                if [ -z "$$TECH_TOKEN" ]; then echo "Technitium login failed"; exit 1; fi
                echo "Technitium auth OK"

                # Query phpIPAM MySQL directly for hosts with hostnames
                HOSTS=$$(mysql -h $$DB_HOST -u $$DB_USER -p$$DB_PASS $$DB_NAME -N -B -e \
                  "SELECT INET_NTOA(ip_addr), hostname FROM ipaddresses WHERE hostname != '' AND hostname IS NOT NULL AND subnetId >= 7")

                SYNCED=0
                echo "$$HOSTS" | while IFS=$$'\t' read -r IP HOSTNAME; do
                  [ -z "$$IP" ] || [ -z "$$HOSTNAME" ] && continue
                  SHORT=$$(echo "$$HOSTNAME" | cut -d. -f1)
                  FQDN="$$SHORT.viktorbarzin.lan"

                  # A record
                  curl -sf -o /dev/null -X POST "$$TECH_URL/api/zones/records/add?token=$$TECH_TOKEN" \
                    -d "domain=$$FQDN&zone=viktorbarzin.lan&type=A&ipAddress=$$IP&overwrite=true&ttl=300"

                  # PTR record
                  O1=$$(echo $$IP | cut -d. -f1); O2=$$(echo $$IP | cut -d. -f2)
                  O3=$$(echo $$IP | cut -d. -f3); O4=$$(echo $$IP | cut -d. -f4)
                  curl -sf -o /dev/null -X POST "$$TECH_URL/api/zones/records/add?token=$$TECH_TOKEN" \
                    -d "domain=$$O4.$$O3.$$O2.$$O1.in-addr.arpa&zone=$$O3.$$O2.$$O1.in-addr.arpa&type=PTR&ptrName=$$FQDN&overwrite=true&ttl=300" 2>/dev/null || true

                  SYNCED=$$((SYNCED + 1))
                  echo "  $$IP -> $$FQDN"
                done
                echo "Push sync complete"

                # Reverse sync: pull hostnames from DNS into phpIPAM for unnamed entries
                echo ""
                echo "=== Reverse sync: DNS -> phpIPAM ==="
                UNNAMED=$$(mysql -h $$DB_HOST -u $$DB_USER -p$$DB_PASS $$DB_NAME -N -B -e \
                  "SELECT id, INET_NTOA(ip_addr) FROM ipaddresses WHERE (hostname IS NULL OR hostname = '') AND subnetId >= 7")

                echo "$$UNNAMED" | while IFS=$$'\t' read -r ID IP; do
                  [ -z "$$ID" ] || [ -z "$$IP" ] && continue
                  # Query Technitium for PTR record
                  O1=$$(echo $$IP | cut -d. -f1); O2=$$(echo $$IP | cut -d. -f2)
                  O3=$$(echo $$IP | cut -d. -f3); O4=$$(echo $$IP | cut -d. -f4)
                  PTR_NAME="$$O4.$$O3.$$O2.$$O1.in-addr.arpa"
                  REV_ZONE="$$O3.$$O2.$$O1.in-addr.arpa"
                  RESULT=$$(curl -sf "$$TECH_URL/api/zones/records/get?token=$$TECH_TOKEN&domain=$$PTR_NAME&zone=$$REV_ZONE&type=PTR" 2>/dev/null)
                  HOSTNAME=$$(echo "$$RESULT" | sed -n 's/.*"ptrName":"\([^"]*\)".*/\1/p' | head -1)
                  [ -z "$$HOSTNAME" ] && continue

                  # Extract short name
                  SHORT=$$(echo "$$HOSTNAME" | cut -d. -f1)
                  [ -z "$$SHORT" ] && continue

                  # Update phpIPAM
                  mysql -h $$DB_HOST -u $$DB_USER -p$$DB_PASS $$DB_NAME -e \
                    "UPDATE ipaddresses SET hostname='$$SHORT' WHERE id=$$ID AND (hostname IS NULL OR hostname = '')"
                  echo "  $$IP -> $$SHORT (from DNS)"
                done
                echo "Bidirectional sync complete"
              EOT
              ]
              env {
                name  = "TECH_PASS"
                value = local.technitium_password
              }
              env {
                name  = "DB_HOST"
                value = var.mysql_host
              }
              env {
                name  = "DB_USER"
                value = "phpipam"
              }
              env {
                name = "DB_PASS"
                value_from {
                  secret_key_ref {
                    name = "phpipam-secrets"
                    key  = "db_password"
                  }
                }
              }
              env {
                name  = "DB_NAME"
                value = "phpipam"
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
          }
        }
      }
    }
  }
}
