# db-rotation-watcher: pushes each Tuesday static-role rotation to its
# consumers within seconds.
#
# Vault rotates every database static role in a Tuesday slot (table in
# main.tf, "Static role rotation slots"). The old Postgres password dies at
# once, and External Secrets would otherwise notice only on its 15-minute poll,
# so an app opening a new connection in between failed to log in: linkwarden
# was down 14:31-14:46 on 2026-10-30, and a 30-day Loki measurement found 11 of
# 31 roles with auth failures after rotation, up to 232 minutes for technitium.
#
# Vault stays in charge of rotation. This CronJob runs through the rotation
# hour, reads role metadata every 5s, and on a change force-syncs every
# ExternalSecret that references the role, waits for it to refresh, runs any
# CronJobs named in its rotation.viktorbarzin.me/after-sync-cronjobs annotation
# and pushes the lag to the Pushgateway. Script and tests:
# files/db_rotation_watcher.py. Runbook: docs/runbooks/db-credential-rotation.md.
#
# It is an optimisation with a fallback: if it fails, the 15-minute ESO poll
# still applies, as before it existed. The alerts DbRotationSyncLagHigh,
# DbRotationWatcherSilent and DbAuthFailuresAfterRotation (stacks/monitoring)
# report a Tuesday that went wrong.

resource "vault_policy" "db_rotation_watcher" {
  name   = "db-rotation-watcher"
  policy = <<-EOT
    # Role metadata only: username, schedule, last_vault_rotation. Passwords
    # live under database/static-creds/*, which this policy does not grant.
    path "database/static-roles" {
      capabilities = ["list"]
    }
    path "database/static-roles/*" {
      capabilities = ["read", "list"]
    }
  EOT
}

resource "vault_kubernetes_auth_backend_role" "db_rotation_watcher" {
  backend                          = vault_auth_backend.kubernetes.path
  role_name                        = "db-rotation-watcher"
  bound_service_account_names      = [kubernetes_service_account.db_rotation_watcher.metadata[0].name]
  bound_service_account_namespaces = [kubernetes_namespace.vault.metadata[0].name]
  token_policies                   = [vault_policy.db_rotation_watcher.name]
  # One run is ~65 minutes; the script logs in again on a 403.
  token_ttl     = 7200
  token_max_ttl = 7200
}

resource "kubernetes_service_account" "db_rotation_watcher" {
  metadata {
    name      = "db-rotation-watcher"
    namespace = kubernetes_namespace.vault.metadata[0].name
  }
}

# Cluster-wide, because the consumers live in ~30 namespaces. Running a
# follow-up CronJob needs a Role in that app's namespace, granted by the app's
# own stack (stacks/technitium is the first).
resource "kubernetes_cluster_role" "db_rotation_watcher" {
  metadata { name = "db-rotation-watcher" }
  rule {
    api_groups = ["external-secrets.io"]
    resources  = ["externalsecrets"]
    verbs      = ["get", "list", "patch"]
  }
}

resource "kubernetes_cluster_role_binding" "db_rotation_watcher" {
  metadata { name = "db-rotation-watcher" }
  role_ref {
    api_group = "rbac.authorization.k8s.io"
    kind      = "ClusterRole"
    name      = kubernetes_cluster_role.db_rotation_watcher.metadata[0].name
  }
  subject {
    kind      = "ServiceAccount"
    name      = kubernetes_service_account.db_rotation_watcher.metadata[0].name
    namespace = kubernetes_namespace.vault.metadata[0].name
  }
}

resource "kubernetes_config_map" "db_rotation_watcher" {
  metadata {
    name      = "db-rotation-watcher"
    namespace = kubernetes_namespace.vault.metadata[0].name
  }
  data = {
    "db_rotation_watcher.py" = file("${path.module}/files/db_rotation_watcher.py")
  }
}

resource "kubernetes_cron_job_v1" "db_rotation_watcher" {
  metadata {
    name      = "db-rotation-watcher"
    namespace = kubernetes_namespace.vault.metadata[0].name
  }
  spec {
    # Two minutes before the first slot (10:00) so the baseline read is taken
    # before anything rotates; runs until 11:02, past the last slot (10:45).
    schedule                      = "58 9 * * TUE"
    timezone                      = "Etc/UTC"
    concurrency_policy            = "Forbid"
    starting_deadline_seconds     = 120
    successful_jobs_history_limit = 3
    failed_jobs_history_limit     = 3
    job_template {
      metadata {}
      spec {
        # Hard stop at 11:05. The script exits by itself at RUN_SECONDS.
        active_deadline_seconds    = 4020
        backoff_limit              = 2
        ttl_seconds_after_finished = 604800
        template {
          metadata {
            labels = { app = "db-rotation-watcher" }
          }
          spec {
            service_account_name = kubernetes_service_account.db_rotation_watcher.metadata[0].name
            # A restarted container picks up rotations from the last 5 minutes
            # and finishes them, so OnFailure loses nothing.
            restart_policy = "OnFailure"
            container {
              name    = "watcher"
              image   = "docker.io/library/python:3.15-slim"
              command = ["python3", "-I", "/scripts/db_rotation_watcher.py"]
              env {
                name  = "RUN_SECONDS"
                value = "3840"
              }
              env {
                name  = "POLL_SECONDS"
                value = "5"
              }
              env {
                name  = "VAULT_ADDR"
                value = "http://vault-active.vault.svc.cluster.local:8200"
              }
              env {
                name  = "VAULT_ROLE"
                value = vault_kubernetes_auth_backend_role.db_rotation_watcher.role_name
              }
              env {
                name  = "PUSHGATEWAY_URL"
                value = "http://prometheus-prometheus-pushgateway.monitoring.svc.cluster.local:9091"
              }
              security_context {
                run_as_non_root            = true
                run_as_user                = 65534
                allow_privilege_escalation = false
                read_only_root_filesystem  = true
              }
              volume_mount {
                name       = "script"
                mount_path = "/scripts"
                read_only  = true
              }
              resources {
                requests = {
                  cpu    = "10m"
                  memory = "32Mi"
                }
                limits = {
                  memory = "96Mi"
                }
              }
            }
            volume {
              name = "script"
              config_map {
                name = kubernetes_config_map.db_rotation_watcher.metadata[0].name
              }
            }
          }
        }
      }
    }
  }
  lifecycle {
    ignore_changes = [spec[0].job_template[0].spec[0].template[0].spec[0].dns_config] # KYVERNO_LIFECYCLE_V1
  }
}
