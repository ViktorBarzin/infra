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
      app = "pgbouncer"
    }
  }

  spec {
    replicas = 1

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
        container {
          name              = "pgbouncer"
          image             = "edoburu/pgbouncer:latest"
          image_pull_policy = "IfNotPresent"

          port {
            container_port = 6432
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
      }
    }
  }
  depends_on = [kubernetes_secret.pgbouncer_auth]
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
