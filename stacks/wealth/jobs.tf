# wealth's three background job processes (src/server/jobs/README.md in the
# wealth repo). Each runs the app's own image with another entrypoint, and
# each is one replica with no HTTP port: pg-boss jobs in the app database
# (schema pgboss) are their only input.
#
# - wealth-worker: every connector queue, market.fx and market.quotes (ECB
#   and Yahoo), ledger.revalue, col.refresh (Numbeo and Expatistan) and the
#   pg-boss cron that turns schedules into jobs.
# - wealth-fire and wealth-sweep: FIRE jobs and Sweep jobs, in processes of
#   their own (a FIRE job after a Sweep in one process took 2 to 4 times as
#   long; src/engine/jobs.ts).
#
# Each holds JOB_POOL_MAX=2 Postgres connections (pg-boss polls, no LISTEN):
# with the web pod's 5 and the migrate step's 1, the app holds 12 at most.
# The Woodpecker deploy in the wealth repo sets the image on all three after
# the web pod, whose init container has applied the migrations.
#
# Fidelity: the worker builds the Fidelity connector only when
# FIDELITY_CDP_URL is set, and then schedules each Fidelity connector on the
# 3rd and 17th at 07:40 UK (wealth src/connectors/brokers/fidelity). PlanViewer
# is behind Akamai, which refuses a headless Chrome, so the connector drives
# the cluster's headful Chrome (chrome-service) over CDP, as broker-sync's
# Fidelity CronJob does.
#
# Schwab: the worker builds the Schwab connector only when SCHWAB_CDP_URL is
# set, and then schedules each Schwab connector on the 20th at 07:50 UK
# (wealth src/connectors/brokers/schwab-web). Schwab keeps "trust this
# device" in chrome-service's persistent profile, so the connector opens a
# tab in the browser's default context and closes only that tab. A switch
# of its own, so either broker can be turned off alone.
#
# chrome-service's NetworkPolicy admits port 9222 from this namespace by
# name, for pods labelled app=wealth-worker only (docs/architecture/
# chrome-service.md, "Network controls").
locals {
  jobs_namespace = module.app.namespace
  jobs = {
    worker = {
      args = ["entrypoints/worker.js"]
      # Connector runs, the ledger revalue and the page parsers. A 21,828-row
      # revalue measured 1.6 s on the devvm.
      requests = { cpu = "50m", memory = "192Mi" }
      limits   = { memory = "768Mi" }
    }
    fire = {
      args = ["entrypoints/engine-worker.js", "fire"]
      # One Monte Carlo job at a time, each in a fresh Bun Worker.
      requests = { cpu = "100m", memory = "256Mi" }
      limits   = { memory = "1536Mi" }
    }
    sweep = {
      args     = ["entrypoints/engine-worker.js", "sweep"]
      requests = { cpu = "100m", memory = "256Mi" }
      limits   = { memory = "1536Mi" }
    }
  }
}

resource "kubernetes_deployment" "jobs" {
  for_each = local.jobs

  # CI owns rollouts, as for the web Deployment.
  wait_for_rollout = false

  metadata {
    name      = "wealth-${each.key}"
    namespace = local.jobs_namespace
    labels = {
      app       = "wealth-${each.key}"
      component = "jobs"
      tier      = local.tiers.aux
    }
    annotations = {
      # Not wealth-db-creds: the password file is re-read on every new
      # connection, so the weekly rotation needs no restart.
      "secret.reloader.stakater.com/reload" = each.key == "worker" ? "wealth-secrets,wealth-payslip-ingest" : ""
    }
  }

  spec {
    replicas = 1
    # Never two of one process: a second main process would run the cron
    # twice, and pg-boss's stately queues expect one worker per queue.
    strategy {
      type = "Recreate"
    }
    selector {
      match_labels = { app = "wealth-${each.key}" }
    }
    template {
      metadata {
        labels = {
          app       = "wealth-${each.key}"
          component = "jobs"
        }
      }
      spec {
        security_context {
          run_as_non_root = true
          run_as_user     = 10001
          run_as_group    = 10001
          fs_group        = 10001
        }

        image_pull_secrets {
          name = "ghcr-credentials"
        }

        # A job in flight gets 30 s to finish before pg-boss stops it; the
        # next scheduled run picks up the rest.
        termination_grace_period_seconds = 45

        container {
          name  = "jobs"
          image = "ghcr.io/viktorbarzin/wealth:${var.image_tag}"
          args  = each.value.args

          port {
            name           = "metrics"
            container_port = 9090
          }

          env {
            name  = "DATABASE_URL"
            value = module.app.database_url
          }
          env {
            name  = "DATABASE_PASSWORD_FILE"
            value = "/secrets/db/password"
          }
          env {
            name  = "JOB_POOL_MAX"
            value = "2"
          }
          env {
            name  = "METRICS_PORT"
            value = "9090"
          }

          # The main process only: the connector secrets key, and
          # payslip-ingest's read token for the payslip connector
          # (payslip-ingest.tf). The engine processes read neither.
          dynamic "env_from" {
            for_each = each.key == "worker" ? ["wealth-secrets", "wealth-payslip-ingest"] : []
            content {
              secret_ref {
                name = env_from.value
              }
            }
          }
          dynamic "env" {
            for_each = each.key == "worker" ? {
              PAYSLIP_INGEST_URL = "http://payslip-ingest.payslip-ingest.svc.cluster.local:8080"
              PAPERLESS_URL      = "http://paperless-ngx.paperless-ngx.svc.cluster.local"
              FIDELITY_CDP_URL   = "http://chrome-service.chrome-service.svc.cluster.local:9222"
              SCHWAB_CDP_URL     = "http://chrome-service.chrome-service.svc.cluster.local:9222"
            } : {}
            content {
              name  = env.key
              value = env.value
            }
          }

          volume_mount {
            name       = "db-password"
            mount_path = "/secrets/db"
            read_only  = true
          }

          resources {
            requests = each.value.requests
            limits   = each.value.limits
          }
        }

        # The module's wealth-db-creds, as a directory (no subPath), so the
        # kubelet refreshes the file when ESO writes a rotated password.
        volume {
          name = "db-password"
          secret {
            secret_name  = "wealth-db-creds"
            default_mode = "0440"
            items {
              key  = "DB_PASSWORD"
              path = "password"
            }
          }
        }
      }
    }
  }

  lifecycle {
    ignore_changes = [
      spec[0].template[0].spec[0].dns_config,                                                  # KYVERNO_LIFECYCLE_V1
      spec[0].template[0].spec[0].container[0].image,                                          # CI_SETS_IMAGE: first-party image, deployed by its own CI
      spec[0].template[0].metadata[0].annotations["reloader.stakater.com/last-reloaded-from"], # RELOADER_LIFECYCLE_V1
      metadata[0].annotations["kubernetes.io/change-cause"],
      metadata[0].annotations["deployment.kubernetes.io/revision"],
      metadata[0].labels["tier"], # stamped by Kyverno sync-tier-label-from-namespace
    ]
  }

  depends_on = [module.app, kubernetes_manifest.payslip_ingest_token]
}

# One Service per process, for Prometheus: the kubernetes-service-endpoints
# job scrapes it and labels the series service="wealth-<process>", which the
# Wealth alert group reads (stacks/monitoring). The main worker's Service
# also gets an Uptime Kuma check of its metrics port (internal-monitor-sync).
resource "kubernetes_service" "jobs" {
  for_each = local.jobs

  metadata {
    name      = "wealth-${each.key}"
    namespace = local.jobs_namespace
    labels    = { app = "wealth-${each.key}", component = "jobs" }
    annotations = merge(
      {
        "prometheus.io/scrape" = "true"
        "prometheus.io/path"   = "/metrics"
        "prometheus.io/port"   = "9090"
      },
      each.key == "worker" ? {
        "uptime.viktorbarzin.me/internal-monitor"      = "true"
        "uptime.viktorbarzin.me/internal-monitor-name" = "wealth worker"
        "uptime.viktorbarzin.me/internal-monitor-path" = "/metrics"
      } : {},
    )
  }

  spec {
    type     = "ClusterIP"
    selector = { app = "wealth-${each.key}" }
    port {
      name        = "metrics"
      port        = 9090
      target_port = 9090
    }
  }
}

# /metrics only from Prometheus and Uptime Kuma; the job pods take no other
# traffic.
resource "kubernetes_network_policy_v1" "jobs" {
  metadata {
    name      = "wealth-jobs-ingress"
    namespace = local.jobs_namespace
  }
  spec {
    pod_selector {
      match_labels = { component = "jobs" }
    }
    policy_types = ["Ingress"]
    ingress {
      dynamic "from" {
        for_each = ["monitoring", "uptime-kuma"]
        content {
          namespace_selector {
            match_labels = {
              "kubernetes.io/metadata.name" = from.value
            }
          }
        }
      }
      ports {
        port     = "9090"
        protocol = "TCP"
      }
    }
  }
}
