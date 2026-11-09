# Event pipeline (ADR-0041): Vector receives Segment-spec Product events,
# checks them against the telemetry standard, and fans them out to Rybbit,
# the events_raw store and (for rejects) Loki. Config and unit tests live in
# files/vector.yaml.

locals {
  # Instrumented apps: name -> production host. The host is the hostname
  # Rybbit records for server and Android events, which carry no page URL.
  # Each needs a key in Vault secret/rybbit `write_keys` (JSON, app -> key).
  analytics_apps = {
    tv = "tv.viktorbarzin.me"
  }

  write_keys = jsondecode(data.vault_kv_secret_v2.secrets.data["write_keys"])

  write_keys_csv = join("\n", concat(
    ["write_key,app,hostname,site_id"],
    [for app, host in local.analytics_apps :
    "${local.write_keys[app]},${app},${host},${data.vault_kv_secret_v2.secrets.data["site_id_apps"]}"],
  ))
}

resource "kubernetes_config_map" "event_pipeline" {
  metadata {
    name      = "event-pipeline"
    namespace = kubernetes_namespace.rybbit.metadata[0].name
  }
  data = {
    "vector.yaml" = file("${path.module}/files/vector.yaml")
  }
}

resource "kubernetes_secret" "event_pipeline_keys" {
  metadata {
    name      = "event-pipeline-keys"
    namespace = kubernetes_namespace.rybbit.metadata[0].name
  }
  data = {
    "keys.csv" = "${local.write_keys_csv}\n"
  }
}

resource "kubernetes_deployment" "event_pipeline" {
  metadata {
    name      = "event-pipeline"
    namespace = kubernetes_namespace.rybbit.metadata[0].name
    labels = {
      app  = "event-pipeline"
      tier = local.tiers.aux
    }
    annotations = {
      "reloader.stakater.com/auto" = "true"
    }
  }
  spec {
    replicas = 1
    selector {
      match_labels = {
        app = "event-pipeline"
      }
    }
    template {
      metadata {
        labels = {
          app = "event-pipeline"
        }
        annotations = {
          "prometheus.io/scrape"           = "true"
          "prometheus.io/port"             = "9598"
          "prometheus.io/path"             = "/metrics"
          "dependency.kyverno.io/wait-for" = "rybbit.rybbit:80,clickhouse.rybbit:8123"
        }
      }
      spec {
        container {
          name  = "vector"
          image = "timberio/vector:0.61.0-debian"
          args  = ["--config", "/etc/vector/vector.yaml"]
          env {
            name = "RYBBIT_INGEST_KEY"
            value_from {
              secret_key_ref {
                name = "rybbit-secrets"
                key  = "ingest_api_key"
              }
            }
          }
          env {
            name = "CLICKHOUSE_PASSWORD"
            value_from {
              secret_key_ref {
                name = "rybbit-secrets"
                key  = "clickhouse_password"
              }
            }
          }
          port {
            name           = "http"
            container_port = 8080
          }
          port {
            name           = "metrics"
            container_port = 9598
          }
          readiness_probe {
            tcp_socket {
              port = 8080
            }
            period_seconds = 10
          }
          liveness_probe {
            tcp_socket {
              port = 8080
            }
            initial_delay_seconds = 15
            period_seconds        = 30
            failure_threshold     = 5
          }
          volume_mount {
            name       = "config"
            mount_path = "/etc/vector/vector.yaml"
            sub_path   = "vector.yaml"
          }
          volume_mount {
            name       = "keys"
            mount_path = "/etc/vector/keys"
          }
          volume_mount {
            name       = "data"
            mount_path = "/var/lib/vector"
          }
          resources {
            requests = {
              cpu    = "25m"
              memory = "128Mi"
            }
            limits = {
              memory = "512Mi"
            }
          }
        }
        volume {
          name = "config"
          config_map {
            name = kubernetes_config_map.event_pipeline.metadata[0].name
          }
        }
        volume {
          name = "keys"
          secret {
            secret_name = kubernetes_secret.event_pipeline_keys.metadata[0].name
          }
        }
        # Disk buffers for the Rybbit and ClickHouse sinks. They survive a
        # container restart, not a reschedule; events_raw is the record.
        volume {
          name = "data"
          empty_dir {
            size_limit = "1Gi"
          }
        }
      }
    }
  }
  lifecycle {
    ignore_changes = [
      spec[0].template[0].spec[0].dns_config, # KYVERNO_LIFECYCLE_V1
      metadata[0].annotations["kubernetes.io/change-cause"],
      metadata[0].annotations["deployment.kubernetes.io/revision"],
      spec[0].template[0].metadata[0].annotations["reloader.stakater.com/last-reloaded-from"], # RELOADER_LIFECYCLE_V1
    ]
  }
}

resource "kubernetes_service" "event_pipeline" {
  metadata {
    name      = "event-pipeline"
    namespace = kubernetes_namespace.rybbit.metadata[0].name
    labels = {
      app = "event-pipeline"
    }
  }
  spec {
    selector = {
      app = "event-pipeline"
    }
    port {
      name        = "http"
      port        = 80
      target_port = 8080
    }
  }
}
