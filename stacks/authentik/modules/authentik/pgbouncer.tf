resource "kubernetes_config_map" "pgbouncer_config" {
  metadata {
    name      = "pgbouncer-config"
    namespace = "authentik"
  }

  data = {
    "pgbouncer.ini" = templatefile("${path.module}/pgbouncer.ini", { password = var.postgres_password })
  }
}

# --- 2️⃣ Secret for user credentials ---
resource "kubernetes_secret" "pgbouncer_auth" {
  metadata {
    name      = "pgbouncer-auth"
    namespace = "authentik"
  }

  data = {
    "userlist.txt" = templatefile("${path.module}/userlist.txt", { password = var.postgres_password })
  }

  type = "Opaque"
}

# --- 3️⃣ Deployment ---
resource "kubernetes_deployment" "pgbouncer" {
  metadata {
    name      = "pgbouncer"
    namespace = "authentik"
    labels = {
      app  = "pgbouncer"
      tier = var.tier
    }
  }

  spec {
    replicas = 3

    selector {
      match_labels = {
        app = "pgbouncer"
      }
    }

    template {
      metadata {
        labels = {
          app = "pgbouncer"
        }
      }

      spec {
        affinity {
          pod_anti_affinity {
            required_during_scheduling_ignored_during_execution {
              label_selector {
                match_expressions {
                  key      = "component"
                  operator = "In"
                  values   = ["server"]
                }
              }
              topology_key = "kubernetes.io/hostname"
            }
          }
        }
        container {
          name              = "pgbouncer"
          image             = "edoburu/pgbouncer:latest"
          image_pull_policy = "IfNotPresent"

          port {
            container_port = 6432
          }

          resources {
            requests = {
              cpu    = "50m"
              memory = "128Mi"
            }
            limits = {
              memory = "512Mi"
            }
          }

          readiness_probe {
            tcp_socket {
              port = 6432
            }
            initial_delay_seconds = 5
            period_seconds        = 10
            timeout_seconds       = 3
            failure_threshold     = 3
          }

          liveness_probe {
            tcp_socket {
              port = 6432
            }
            initial_delay_seconds = 30
            period_seconds        = 30
            timeout_seconds       = 5
            failure_threshold     = 3
          }

          volume_mount {
            name       = "config"
            mount_path = "/etc/pgbouncer/pgbouncer.ini"
            sub_path   = "pgbouncer.ini"
          }

          volume_mount {
            name       = "auth"
            mount_path = "/etc/pgbouncer/userlist.txt"
            sub_path   = "userlist.txt"
          }

          env {
            name  = "DATABASES_AUTHENTIK"
            value = "host=postgres port=5432 dbname=authentik user=authentik password=${var.postgres_password}"
          }
        }

        volume {
          name = "config"
          config_map {
            name = kubernetes_config_map.pgbouncer_config.metadata[0].name
          }
        }

        volume {
          name = "auth"
          secret {
            secret_name = kubernetes_secret.pgbouncer_auth.metadata[0].name
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
  depends_on = [kubernetes_secret.pgbouncer_auth]
  lifecycle {
    # KYVERNO_LIFECYCLE_V1: Kyverno admission webhook mutates dns_config with ndots=2
    ignore_changes = [spec[0].template[0].spec[0].dns_config]
  }
}

# --- 3b️⃣ PodDisruptionBudget ---
# Protects auth against simultaneous node drains. With 3 replicas and
# minAvailable=2, a single drain rolls cleanly; a simultaneous two-node
# outage is correctly blocked.
resource "kubernetes_pod_disruption_budget_v1" "pgbouncer" {
  metadata {
    name      = "pgbouncer"
    namespace = "authentik"
  }
  spec {
    min_available = 2
    selector {
      match_labels = {
        app = "pgbouncer"
      }
    }
  }
}

# --- 4️⃣ Service ---
resource "kubernetes_service" "pgbouncer" {
  metadata {
    name      = "pgbouncer"
    namespace = "authentik"
  }

  spec {
    selector = {
      app = "pgbouncer"
    }

    port {
      port        = 6432
      target_port = 6432
      protocol    = "TCP"
    }

    type = "ClusterIP"
  }
}
