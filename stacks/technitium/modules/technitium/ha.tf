# =============================================================================
# Technitium DNS — High Availability (Primary-Secondary)
# =============================================================================
#
# Secondary DNS instance replicates zones from primary via AXFR.
# Both pods share the `dns-server=true` label so the DNS LoadBalancer
# in main.tf routes queries to whichever pod is healthy.

resource "kubernetes_persistent_volume_claim" "secondary_config_encrypted" {
  wait_until_bound = false
  metadata {
    name      = "technitium-secondary-config-encrypted"
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

# Primary-only service for zone transfers (AXFR) and API access
resource "kubernetes_service" "technitium_primary" {
  metadata {
    name      = "technitium-primary"
    namespace = kubernetes_namespace.technitium.metadata[0].name
    labels = {
      "app" = "technitium"
    }
  }

  spec {
    selector = {
      app = "technitium"
    }
    port {
      name     = "dns-tcp"
      port     = 53
      protocol = "TCP"
    }
    port {
      name     = "dns-udp"
      port     = 53
      protocol = "UDP"
    }
    port {
      name     = "api"
      port     = 5380
      protocol = "TCP"
    }
  }
}

# Secondary DNS deployment — zone-transfer replica
resource "kubernetes_deployment" "technitium_secondary" {
  metadata {
    name      = "technitium-secondary"
    namespace = kubernetes_namespace.technitium.metadata[0].name
    labels = {
      app  = "technitium-secondary"
      tier = var.tier
    }
  }
  spec {
    replicas = 1
    strategy {
      type = "Recreate"
    }
    selector {
      match_labels = {
        app = "technitium-secondary"
      }
    }
    template {
      metadata {
        labels = {
          app          = "technitium-secondary"
          "dns-server" = "true"
        }
      }
      spec {
        affinity {
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
          env {
            name  = "DNS_SERVER_ADMIN_PASSWORD"
            value = var.technitium_password
          }
          env {
            name  = "DNS_SERVER_ENABLE_BLOCKING"
            value = "true"
          }
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
        }
        volume {
          name = "nfs-config"
          persistent_volume_claim {
            claim_name = kubernetes_persistent_volume_claim.secondary_config_encrypted.metadata[0].name
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

# Secondary web service — internal only, used by setup Job
resource "kubernetes_service" "technitium_secondary_web" {
  metadata {
    name      = "technitium-secondary-web"
    namespace = kubernetes_namespace.technitium.metadata[0].name
    labels = {
      "app" = "technitium-secondary"
    }
  }

  spec {
    selector = {
      app = "technitium-secondary"
    }
    port {
      name     = "api"
      port     = 5380
      protocol = "TCP"
    }
  }
}

# Tertiary DNS deployment — another zone-transfer replica for ETP=Local coverage
resource "kubernetes_persistent_volume_claim" "tertiary_config_encrypted" {
  wait_until_bound = false
  metadata {
    name      = "technitium-tertiary-config-encrypted"
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

resource "kubernetes_deployment" "technitium_tertiary" {
  metadata {
    name      = "technitium-tertiary"
    namespace = kubernetes_namespace.technitium.metadata[0].name
    labels = {
      app  = "technitium-tertiary"
      tier = var.tier
    }
  }
  spec {
    replicas = 1
    strategy {
      type = "Recreate"
    }
    selector {
      match_labels = {
        app = "technitium-tertiary"
      }
    }
    template {
      metadata {
        labels = {
          app          = "technitium-tertiary"
          "dns-server" = "true"
        }
      }
      spec {
        affinity {
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
          env {
            name  = "DNS_SERVER_ADMIN_PASSWORD"
            value = var.technitium_password
          }
          env {
            name  = "DNS_SERVER_ENABLE_BLOCKING"
            value = "true"
          }
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
            name       = "config"
          }
        }
        volume {
          name = "config"
          persistent_volume_claim {
            claim_name = kubernetes_persistent_volume_claim.tertiary_config_encrypted.metadata[0].name
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

resource "kubernetes_service" "technitium_tertiary_web" {
  metadata {
    name      = "technitium-tertiary-web"
    namespace = kubernetes_namespace.technitium.metadata[0].name
    labels = {
      "app" = "technitium-tertiary"
    }
  }

  spec {
    selector = {
      app = "technitium-tertiary"
    }
    port {
      name     = "api"
      port     = 5380
      protocol = "TCP"
    }
  }
}

# PodDisruptionBudget — keep at least 2 DNS pods running during voluntary disruptions
resource "kubernetes_pod_disruption_budget_v1" "technitium_dns" {
  metadata {
    name      = "technitium-dns"
    namespace = kubernetes_namespace.technitium.metadata[0].name
  }
  spec {
    min_available = "2"
    selector {
      match_labels = {
        "dns-server" = "true"
      }
    }
  }
}

# Setup Job — configures secondary + tertiary zones via Technitium REST API
# Zone sync CronJob — replicates all primary zones to secondary/tertiary
# Runs every 30 minutes. Idempotent: skips zones that already exist on replicas.
resource "kubernetes_cron_job_v1" "technitium_zone_sync" {
  metadata {
    name      = "technitium-zone-sync"
    namespace = kubernetes_namespace.technitium.metadata[0].name
  }
  spec {
    schedule                      = "*/30 * * * *"
    successful_jobs_history_limit = 3
    failed_jobs_history_limit     = 3
    concurrency_policy            = "Forbid"
    job_template {
      metadata {}
      spec {
        backoff_limit = 2
        template {
          metadata {}
          spec {
            restart_policy = "OnFailure"
            container {
              name  = "zone-sync"
              image = "curlimages/curl:latest"
              command = ["/bin/sh", "-c", <<-SCRIPT
                set -e
                PRIMARY="http://technitium-primary.technitium.svc.cluster.local:5380"
                REPLICAS="http://technitium-secondary-web.technitium.svc.cluster.local:5380 http://technitium-tertiary-web.technitium.svc.cluster.local:5380"
                PUSHGW="http://prometheus-prometheus-pushgateway.monitoring:9091/metrics/job/technitium-zone-sync"

                # Track overall status — non-zero if any zone fails to create
                OVERALL_STATUS=0
                FAIL_COUNT=0
                SYNCED=0

                # Login to primary
                P_TOKEN=$(curl -sf "$PRIMARY/api/user/login?user=$TECH_USER&pass=$TECH_PASS" | sed -n 's/.*"token":"\([^"]*\)".*/\1/p')
                if [ -z "$P_TOKEN" ]; then echo "ERROR: Cannot login to primary"; OVERALL_STATUS=1; fi

                if [ "$OVERALL_STATUS" -eq 0 ]; then
                  # Get zones from primary (excluding default zones that don't need replication)
                  curl -sf "$PRIMARY/api/zones/list?token=$P_TOKEN" | tr ',' '\n' | sed -n 's/.*"name":"\([^"]*\)".*/\1/p' | \
                    grep -v -E '^(localhost|0\.in-addr\.arpa|127\.in-addr\.arpa|255\.in-addr\.arpa|1\.0\.0.*ip6\.arpa)$$' > /tmp/primary_zones.txt
                  PRIMARY_COUNT=$(wc -l < /tmp/primary_zones.txt)
                  echo "Primary has $PRIMARY_COUNT zones to replicate"

                  # Enable zone transfers on primary for all zones
                  while read -r zone; do
                    curl -sf "$PRIMARY/api/zones/options/set?token=$P_TOKEN&zone=$zone&zoneTransfer=Allow" > /dev/null || true
                  done < /tmp/primary_zones.txt

                  # Sync to each replica
                  for REPLICA in $REPLICAS; do
                    R_NAME=$(echo "$REPLICA" | sed 's|http://||; s|-web.*||')
                    R_TOKEN=$(curl -sf "$REPLICA/api/user/login?user=$TECH_USER&pass=$TECH_PASS" | sed -n 's/.*"token":"\([^"]*\)".*/\1/p')
                    if [ -z "$R_TOKEN" ]; then
                      echo "ERROR: Cannot login to $REPLICA"
                      OVERALL_STATUS=1
                      FAIL_COUNT=$((FAIL_COUNT + 1))
                      # Push replica zone_count=0 so divergence alert fires
                      printf 'technitium_zone_count{instance="%s"} 0\n' "$R_NAME" | \
                        curl -sf --data-binary @- "$PUSHGW/instance/$R_NAME" || true
                      continue
                    fi

                    # Get existing zones on this replica
                    curl -sf "$REPLICA/api/zones/list?token=$R_TOKEN" | tr ',' '\n' | sed -n 's/.*"name":"\([^"]*\)".*/\1/p' > /tmp/replica_zones.txt
                    REPLICA_COUNT=$(wc -l < /tmp/replica_zones.txt)

                    while read -r zone; do
                      if grep -qx "$zone" /tmp/replica_zones.txt; then
                        # Zone exists — just resync
                        curl -sf "$REPLICA/api/zones/resync?token=$R_TOKEN&zone=$zone" > /dev/null || true
                      else
                        # New zone — create as Secondary and validate response
                        echo "NEW: Creating $zone on $REPLICA"
                        RESP=$(curl -sf "$REPLICA/api/zones/create?token=$R_TOKEN&zone=$zone&type=Secondary&primaryNameServerAddresses=$PRIMARY_IP" || echo '{"status":"error"}')
                        if echo "$RESP" | grep -q '"status":"ok"'; then
                          SYNCED=$((SYNCED + 1))
                        else
                          echo "ERROR: Failed to create $zone on $REPLICA: $RESP"
                          OVERALL_STATUS=1
                          FAIL_COUNT=$((FAIL_COUNT + 1))
                        fi
                      fi
                    done < /tmp/primary_zones.txt

                    # Push per-replica zone count
                    printf 'technitium_zone_count{instance="%s"} %s\n' "$R_NAME" "$REPLICA_COUNT" | \
                      curl -sf --data-binary @- "$PUSHGW/instance/$R_NAME" || true
                  done

                  # Push primary zone count
                  printf 'technitium_zone_count{instance="primary"} %s\n' "$PRIMARY_COUNT" | \
                    curl -sf --data-binary @- "$PUSHGW/instance/primary" || true
                fi

                # Push overall status (0=ok, 1=fail) + last-run timestamp
                cat <<METRICS | curl -sf --data-binary @- "$PUSHGW" || true
                # HELP technitium_zone_sync_status Zone sync job status (0=ok, 1=fail)
                # TYPE technitium_zone_sync_status gauge
                technitium_zone_sync_status $OVERALL_STATUS
                # HELP technitium_zone_sync_failures Zones that failed to create this run
                # TYPE technitium_zone_sync_failures gauge
                technitium_zone_sync_failures $FAIL_COUNT
                # HELP technitium_zone_sync_last_run Timestamp of last zone-sync run
                # TYPE technitium_zone_sync_last_run gauge
                technitium_zone_sync_last_run $(date +%s)
                METRICS

                echo "Zone sync complete. $SYNCED new zone(s) created. $FAIL_COUNT failures. status=$OVERALL_STATUS"
                exit $OVERALL_STATUS
              SCRIPT
              ]
              env {
                name  = "TECH_USER"
                value = var.technitium_username
              }
              env {
                name  = "TECH_PASS"
                value = var.technitium_password
              }
              env {
                name  = "PRIMARY_IP"
                value = kubernetes_service.technitium_primary.spec[0].cluster_ip
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
  }
  lifecycle {
    # KYVERNO_LIFECYCLE_V1: Kyverno admission webhook mutates dns_config with ndots=2
    ignore_changes = [spec[0].job_template[0].spec[0].template[0].spec[0].dns_config]
  }
}
