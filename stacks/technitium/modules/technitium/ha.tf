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
resource "kubernetes_job" "technitium_secondary_setup" {
  metadata {
    name      = "technitium-replica-setup"
    namespace = kubernetes_namespace.technitium.metadata[0].name
  }
  spec {
    backoff_limit = 5
    template {
      metadata {}
      spec {
        restart_policy = "OnFailure"
        container {
          name  = "setup"
          image = "curlimages/curl:latest"
          command = ["/bin/sh", "-c", <<-SCRIPT
            set -e
            PRIMARY="http://technitium-primary.technitium.svc.cluster.local:5380"
            REPLICAS="http://technitium-secondary-web.technitium.svc.cluster.local:5380 http://technitium-tertiary-web.technitium.svc.cluster.local:5380"

            # Wait for primary
            until curl -sf "$PRIMARY/api/user/login?user=$TECH_USER&pass=$TECH_PASS" -o /tmp/p.json; do echo "Waiting for primary..."; sleep 5; done
            P_TOKEN=$(cat /tmp/p.json | sed -n 's/.*"token":"\([^"]*\)".*/\1/p')

            # Get zones from primary
            curl -sf "$PRIMARY/api/zones/list?token=$P_TOKEN" | tr ',' '\n' | sed -n 's/.*"name":"\([^"]*\)".*/\1/p' > /tmp/zones.txt
            echo "Found zones:"; cat /tmp/zones.txt

            # Enable zone transfers on primary
            while read -r zone; do
              echo "Enabling zone transfer for: $zone"
              curl -sf "$PRIMARY/api/zones/options/set?token=$P_TOKEN&zone=$zone&zoneTransfer=Allow" || true
            done < /tmp/zones.txt

            # Configure each replica
            for REPLICA in $REPLICAS; do
              echo "=== Configuring replica: $REPLICA ==="
              until curl -sf "$REPLICA/api/user/login?user=$TECH_USER&pass=$TECH_PASS" -o /tmp/r.json; do echo "Waiting for $REPLICA..."; sleep 5; done
              R_TOKEN=$(cat /tmp/r.json | sed -n 's/.*"token":"\([^"]*\)".*/\1/p')

              while read -r zone; do
                echo "Creating secondary zone: $zone on $REPLICA"
                curl -sf "$REPLICA/api/zones/create?token=$R_TOKEN&zone=$zone&type=Secondary&primaryNameServerAddresses=$PRIMARY_IP" || true
              done < /tmp/zones.txt

              while read -r zone; do
                echo "Resyncing: $zone on $REPLICA"
                curl -sf "$REPLICA/api/zones/resync?token=$R_TOKEN&zone=$zone" || true
              done < /tmp/zones.txt
            done

            echo "Replica zone setup complete"
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

  depends_on = [
    kubernetes_deployment.technitium,
    kubernetes_deployment.technitium_secondary,
    kubernetes_deployment.technitium_tertiary,
    kubernetes_service.technitium_primary,
    kubernetes_service.technitium_secondary_web,
    kubernetes_service.technitium_tertiary_web,
  ]
}
