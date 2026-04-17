# DB as a service. Installs MySQL operator
variable "tls_secret_name" {}
variable "tier" { type = string }
variable "dbaas_root_password" {}
variable "cluster_master_service" {
  default = "mysql"
}
variable "postgresql_root_password" {}
variable "pgadmin_password" {}
variable "prod" {
  default = false
  type    = bool
}
variable "nfs_server" { type = string }
variable "kube_config_path" {
  type      = string
  sensitive = true
}

# MySQL static application users (not rotated by Vault DB engine; baked into
# each app's config). Codified here so future MySQL rebuilds cannot silently
# drop them.
variable "mysql_forgejo_password" {
  type      = string
  sensitive = true
}
variable "mysql_roundcubemail_password" {
  type      = string
  sensitive = true
}

resource "kubernetes_namespace" "dbaas" {
  metadata {
    name = "dbaas"
    labels = {
      tier                               = var.tier
      "resource-governance/custom-quota" = "true"
    }
  }
}

# Override Kyverno tier-1-cluster LimitRange (max 4Gi) to allow MySQL 6Gi limit
resource "kubernetes_limit_range" "dbaas" {
  metadata {
    name      = "tier-defaults"
    namespace = kubernetes_namespace.dbaas.metadata[0].name
  }
  spec {
    limit {
      type = "Container"
      default = {
        memory = "256Mi"
      }
      default_request = {
        cpu    = "50m"
        memory = "256Mi"
      }
      max = {
        memory = "8Gi"
      }
    }
  }
}

resource "kubernetes_resource_quota" "dbaas" {
  metadata {
    name      = "dbaas-quota"
    namespace = kubernetes_namespace.dbaas.metadata[0].name
  }
  spec {
    hard = {
      "requests.cpu"    = "8"
      "requests.memory" = "40Gi"
      "limits.memory"   = "40Gi"
      pods              = "30"
    }
  }
}

module "tls_secret" {
  source          = "../../../../modules/kubernetes/setup_tls_secret"
  namespace       = kubernetes_namespace.dbaas.metadata[0].name
  tls_secret_name = var.tls_secret_name
}


#### MYSQL — InnoDB Cluster via MySQL Operator
#
# 3 MySQL servers with Group Replication + 1 MySQL Router for auto-failover.
# Operator installed in mysql-operator namespace (toleration for control-plane).
# Init containers are slow (~20 min each) due to mysqlsh plugin loading.

resource "kubernetes_namespace" "mysql_operator" {
  metadata {
    name = "mysql-operator"
    labels = {
      tier = "1-cluster"
    }
  }
}

resource "helm_release" "mysql_operator" {
  namespace        = kubernetes_namespace.mysql_operator.metadata[0].name
  create_namespace = false
  name             = "mysql-operator"
  timeout          = 300

  repository = "https://mysql.github.io/mysql-operator/"
  chart      = "mysql-operator"
  version    = "2.2.7"

  # NOTE: The mysql-operator chart (2.2.7) does NOT expose a resources values key.
  # The resources block below is ignored by the chart. Without explicit resources
  # on the deployment, the LimitRange default (256Mi) applies silently.
  # Fix: kubectl patch deployment mysql-operator -n mysql-operator --type=json \
  #   -p='[{"op":"replace","path":"/spec/template/spec/containers/0/resources","value":{"requests":{"cpu":"100m","memory":"256Mi"},"limits":{"memory":"512Mi"}}}]'
  values = [yamlencode({
    resources = {
      requests = {
        cpu    = "100m"
        memory = "256Mi"
      }
      limits = {
        memory = "512Mi"
      }
    }
  })]
}

# The mysql-sidecar ClusterRole created by the Helm chart is missing
# namespace and CRD list/watch permissions needed by the kopf framework
# in the sidecar container. Without these, the sidecar enters degraded
# mode and never completes InnoDB cluster join operations.
resource "kubernetes_cluster_role" "mysql_sidecar_extra" {
  metadata {
    name = "mysql-sidecar-extra"
  }
  rule {
    api_groups = [""]
    resources  = ["namespaces"]
    verbs      = ["list", "watch"]
  }
  rule {
    api_groups = ["apiextensions.k8s.io"]
    resources  = ["customresourcedefinitions"]
    verbs      = ["list", "watch"]
  }
}

resource "kubernetes_cluster_role_binding" "mysql_sidecar_extra" {
  metadata {
    name = "mysql-sidecar-extra"
  }
  role_ref {
    api_group = "rbac.authorization.k8s.io"
    kind      = "ClusterRole"
    name      = kubernetes_cluster_role.mysql_sidecar_extra.metadata[0].name
  }
  subject {
    kind      = "ServiceAccount"
    name      = "mysql-cluster-sa"
    namespace = kubernetes_namespace.dbaas.metadata[0].name
  }
}

# ConfigMap for MySQL extra config — mounted as subPath over 99-extra.cnf
# This is the only reliable way to persist innodb_doublewrite=OFF because:
# - spec.mycnf only applies on initial cluster creation
# - The operator's initconf container overwrites 99-extra.cnf on every pod start
# - SET PERSIST doesn't support innodb_doublewrite (static variable)
resource "kubernetes_config_map" "mysql_extra_cnf" {
  metadata {
    name      = "mysql-extra-cnf"
    namespace = kubernetes_namespace.dbaas.metadata[0].name
  }
  data = {
    "99-extra.cnf" = <<-EOT
      [mysqld]
      innodb_doublewrite=OFF
    EOT
  }
}

resource "helm_release" "mysql_cluster" {
  namespace        = kubernetes_namespace.dbaas.metadata[0].name
  create_namespace = false
  name             = "mysql-cluster"
  timeout          = 900

  repository = "https://mysql.github.io/mysql-operator/"
  chart      = "mysql-innodbcluster"
  version    = "2.2.7"

  values = [yamlencode({
    serverInstances = 1
    routerInstances = 1
    serverVersion   = "8.4.4"

    credentials = {
      root = {
        user     = "root"
        password = var.dbaas_root_password
        host     = "%"
      }
    }

    tls = {
      useSelfSigned = true
    }

    datadirVolumeClaimTemplate = {
      storageClassName = "proxmox-lvm-encrypted"
      metadata = {
        annotations = {
          "resize.topolvm.io/threshold"     = "80%"
          "resize.topolvm.io/increase"      = "20%"
          "resize.topolvm.io/storage_limit" = "100Gi"
        }
      }
      resources = {
        requests = {
          storage = "30Gi"
        }
      }
    }

    serverConfig = {
      mycnf = <<-EOT
        [mysqld]
        skip-name-resolve
        mysql-native-password=ON
        # Auto-recovery after crashes: rejoin group without manual intervention
        group_replication_autorejoin_tries=2016
        group_replication_exit_state_action=OFFLINE_MODE
        group_replication_member_expel_timeout=30
        group_replication_unreachable_majority_timeout=60
        group_replication_start_on_boot=ON
        # Cap XCom cache to prevent unbounded growth (default 1GB causes OOM)
        group_replication_message_cache_size=134217728
        # Reduce log buffer (16MB sufficient for this workload, was 64MB)
        innodb_log_buffer_size=16777216
        # Limit connections (peak usage ~40, no need for 151)
        max_connections=80
        # --- Disk write reduction (HDD/LVM thin) ---
        # Flush redo log once per second, not per commit. Up to 1s data loss on MySQL crash,
        # but group replication provides redundancy across 3 nodes.
        innodb_flush_log_at_trx_commit=0
        # OS decides when to flush binlog (not per commit)
        sync_binlog=0
        # HDD-tuned I/O capacity (default 200/2000 is for SSD)
        innodb_io_capacity=100
        innodb_io_capacity_max=200
        # 1GB redo log capacity — larger log means less frequent checkpoint flushes
        innodb_redo_log_capacity=1073741824
        # 1GB buffer pool
        innodb_buffer_pool_size=1073741824
        # Disable doublewrite — halves write amplification. Safe with group replication
        # (crashed node can re-clone from healthy replica rather than relying on local recovery)
        innodb_doublewrite=OFF
        # Flush neighbors on HDD (coalesce adjacent dirty pages into single I/O)
        innodb_flush_neighbors=1
        # Reduce page cleaner aggressiveness
        innodb_lru_scan_depth=256
        innodb_page_cleaners=1
        # Reduce adaptive flushing — let dirty pages accumulate longer before background flush
        innodb_adaptive_flushing_lwm=10
        innodb_max_dirty_pages_pct=90
        innodb_max_dirty_pages_pct_lwm=10
      EOT
    }

    # Top-level resources apply to SIDECAR container
    # VPA shows sidecar needs only 248Mi target / 334Mi upper bound
    # Setting to 350Mi (was 2Gi/4Gi - 17× over-provisioned)
    resources = {
      requests = {
        cpu    = "250m"
        memory = "350Mi"
      }
      limits = {
        memory = "350Mi"
      }
    }

    podSpec = {
      affinity = {
        nodeAffinity = {
          requiredDuringSchedulingIgnoredDuringExecution = {
            nodeSelectorTerms = [{
              matchExpressions = [{
                key      = "kubernetes.io/hostname"
                operator = "NotIn"
                values   = ["k8s-node1"]
              }]
            }]
          }
        }
        podAntiAffinity = {
          preferredDuringSchedulingIgnoredDuringExecution = [{
            weight = 100
            podAffinityTerm = {
              labelSelector = {
                matchLabels = {
                  "component" = "mysqld"
                }
              }
              topologyKey = "kubernetes.io/hostname"
            }
          }]
        }
      }
      # Container-specific resources for MYSQL container
      # VPA shows 2.98Gi target / 5.26Gi upper bound
      # Current usage ~1.8Gi peak. Reducing limit from 4Gi to 3Gi
      containers = [
        {
          name = "mysql"
          resources = {
            requests = {
              memory = "2Gi"
              cpu    = "250m"
            }
            limits = {
              memory = "3Gi"
            }
          }
        },
        {
          # MySQL operator sidecar (kopf Python control loop)
          # VPA upper bound: 334Mi. Was 6Gi limit — 17× over-provisioned.
          name = "sidecar"
          resources = {
            requests = {
              memory = "350Mi"
              cpu    = "50m"
            }
            limits = {
              memory = "512Mi"
            }
          }
        }
      ]
      initContainers = [
        {
          name = "fixdatadir"
          resources = {
            requests = { memory = "64Mi", cpu = "25m" }
            limits   = { memory = "64Mi" }
          }
        },
        {
          name = "initconf"
          resources = {
            requests = { memory = "256Mi", cpu = "50m" }
            limits   = { memory = "256Mi" }
          }
        },
        {
          name = "initmysql"
          resources = {
            requests = { memory = "512Mi", cpu = "250m" }
            limits   = { memory = "512Mi" }
          }
        }
      ]
    }

    # MySQL Router - explicitly set resources (chart does not expose router.resources)
    # VPA shows 100Mi upper bound, setting to 128Mi
    # Note: This requires manual kubectl patch after helm release:
    #   kubectl patch deployment mysql-cluster-router -n dbaas --type=json -p='[
    #     {"op": "replace", "path": "/spec/template/spec/containers/0/resources",
    #      "value": {"requests": {"cpu": "25m", "memory": "128Mi"}, "limits": {"memory": "128Mi"}}}]'
    # TODO: migrate to mysql-operator fork or wait for upstream router.resources support

  })]

  depends_on = [helm_release.mysql_operator]
}

#### MYSQL — Standalone (migration target)
#
# Standalone MySQL without Group Replication. Eliminates ~95 GB/day of GR
# write overhead (binlog, relay log, XCom cache) for databases totaling ~35 MB.
# Binary logging disabled entirely (skip-log-bin) since no replication needed.
# Uses official mysql:8.4 image (Bitnami images deprecated by Broadcom Aug 2025).

resource "kubernetes_config_map" "mysql_standalone_cnf" {
  metadata {
    name      = "mysql-standalone-cnf"
    namespace = kubernetes_namespace.dbaas.metadata[0].name
  }
  data = {
    "standalone.cnf" = <<-EOT
      [mysqld]
      skip-name-resolve
      mysql-native-password=ON
      skip-log-bin
      max_connections=80
      innodb_log_buffer_size=16777216
      innodb_flush_log_at_trx_commit=2
      innodb_io_capacity=100
      innodb_io_capacity_max=200
      innodb_redo_log_capacity=1073741824
      innodb_buffer_pool_size=1073741824
      innodb_flush_neighbors=1
      innodb_lru_scan_depth=256
      innodb_page_cleaners=1
      innodb_adaptive_flushing_lwm=10
      innodb_max_dirty_pages_pct=90
      innodb_max_dirty_pages_pct_lwm=10
    EOT
  }
}

resource "kubernetes_stateful_set_v1" "mysql_standalone" {
  metadata {
    name      = "mysql-standalone"
    namespace = kubernetes_namespace.dbaas.metadata[0].name
    labels = {
      "app.kubernetes.io/name"      = "mysql"
      "app.kubernetes.io/instance"  = "mysql-standalone"
      "app.kubernetes.io/component" = "primary"
    }
  }
  spec {
    service_name = "mysql-standalone"
    replicas     = 1

    selector {
      match_labels = {
        "app.kubernetes.io/instance"  = "mysql-standalone"
        "app.kubernetes.io/component" = "primary"
      }
    }

    template {
      metadata {
        labels = {
          "app.kubernetes.io/name"      = "mysql"
          "app.kubernetes.io/instance"  = "mysql-standalone"
          "app.kubernetes.io/component" = "primary"
        }
      }
      spec {
        affinity {
          node_affinity {
            required_during_scheduling_ignored_during_execution {
              node_selector_term {
                match_expressions {
                  key      = "kubernetes.io/hostname"
                  operator = "NotIn"
                  values   = ["k8s-node1"]
                }
              }
            }
          }
        }

        container {
          name  = "mysql"
          image = "mysql:8.4"

          port {
            container_port = 3306
            name           = "mysql"
          }

          env {
            name = "MYSQL_ROOT_PASSWORD"
            value_from {
              secret_key_ref {
                name = kubernetes_secret.cluster-password.metadata[0].name
                key  = "ROOT_PASSWORD"
              }
            }
          }

          resources {
            requests = {
              cpu    = "250m"
              memory = "1536Mi"
            }
            limits = {
              memory = "2Gi"
            }
          }

          volume_mount {
            name       = "data"
            mount_path = "/var/lib/mysql"
          }

          volume_mount {
            name       = "config"
            mount_path = "/etc/mysql/conf.d"
            read_only  = true
          }

          liveness_probe {
            exec {
              command = ["mysqladmin", "ping", "-h", "localhost"]
            }
            initial_delay_seconds = 30
            period_seconds        = 10
            timeout_seconds       = 5
            failure_threshold     = 3
          }

          readiness_probe {
            exec {
              command = ["mysqladmin", "ping", "-h", "localhost"]
            }
            initial_delay_seconds = 10
            period_seconds        = 10
            timeout_seconds       = 5
            failure_threshold     = 3
          }
        }

        volume {
          name = "config"
          config_map {
            name = kubernetes_config_map.mysql_standalone_cnf.metadata[0].name
          }
        }
      }
    }

    volume_claim_template {
      metadata {
        name = "data"
        annotations = {
          "resize.topolvm.io/threshold"     = "80%"
          "resize.topolvm.io/increase"      = "100%"
          "resize.topolvm.io/storage_limit" = "50Gi"
        }
      }
      spec {
        access_modes       = ["ReadWriteOnce"]
        storage_class_name = "proxmox-lvm-encrypted"
        resources {
          requests = {
            storage = "5Gi"
          }
        }
      }
    }
  }

  lifecycle {
    ignore_changes = [spec[0].template[0].spec[0].dns_config]
  }
}

# Compatibility service: mysql.dbaas.svc.cluster.local:3306
# Points at standalone MySQL (migrated from InnoDB Cluster 2026-04-16)
resource "kubernetes_service" "mysql" {
  metadata {
    name      = var.cluster_master_service
    namespace = kubernetes_namespace.dbaas.metadata[0].name
  }
  spec {
    selector = {
      "app.kubernetes.io/instance"  = "mysql-standalone"
      "app.kubernetes.io/component" = "primary"
    }
    port {
      port        = 3306
      target_port = 3306
    }
  }

  depends_on = [kubernetes_stateful_set_v1.mysql_standalone]
}

# MySQL static application users — not rotated by Vault DB engine.
# Each app stores its password in its own config (forgejo app.ini, roundcube
# ROUNDCUBEMAIL_DB_PASSWORD env). During the 2026-04-16 InnoDB Cluster →
# standalone migration these users were accidentally dropped and recreated with
# mismatched passwords; this block codifies them so a future rebuild cannot
# silently break the apps.
#
# Pattern matches `null_resource.pg_terraform_state_db` below (local-exec into
# the DB pod). We CREATE IF NOT EXISTS + ALTER USER on every apply so a
# password rotation in Vault is re-synced on the next `scripts/tg apply`. The
# `password_hash` trigger re-runs the provisioner when the Vault password
# changes; the namespace/user triggers re-run if identifiers change.
locals {
  mysql_static_users = {
    forgejo = {
      database = "forgejo"
      password = var.mysql_forgejo_password
    }
    roundcubemail = {
      database = "roundcubemail"
      password = var.mysql_roundcubemail_password
    }
  }
}

resource "null_resource" "mysql_static_user" {
  for_each = local.mysql_static_users

  depends_on = [kubernetes_stateful_set_v1.mysql_standalone]

  triggers = {
    username      = each.key
    database      = each.value.database
    password_hash = sha256(each.value.password)
  }

  provisioner "local-exec" {
    command = <<EOT
kubectl --kubeconfig ${var.kube_config_path} exec -i -n dbaas mysql-standalone-0 -c mysql -- sh -c 'exec mysql -uroot -p"$MYSQL_ROOT_PASSWORD"' <<'SQL'
CREATE DATABASE IF NOT EXISTS `${each.value.database}`;
CREATE USER IF NOT EXISTS '${each.key}'@'%' IDENTIFIED WITH caching_sha2_password BY '${each.value.password}';
ALTER USER '${each.key}'@'%' IDENTIFIED WITH caching_sha2_password BY '${each.value.password}';
GRANT ALL PRIVILEGES ON `${each.value.database}`.* TO '${each.key}'@'%';
FLUSH PRIVILEGES;
SQL
EOT
  }
}

module "nfs_mysql_backup_host" {
  source     = "../../../../modules/kubernetes/nfs_volume"
  name       = "dbaas-mysql-backup-host"
  namespace  = kubernetes_namespace.dbaas.metadata[0].name
  nfs_server = "192.168.1.127"
  nfs_path   = "/srv/nfs/mysql-backup"
}

resource "kubernetes_persistent_volume_claim" "pgadmin_encrypted" {
  wait_until_bound = false
  metadata {
    name      = "dbaas-pgadmin-encrypted"
    namespace = kubernetes_namespace.dbaas.metadata[0].name
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
        storage = "1Gi"
      }
    }
  }
}

module "nfs_postgresql_backup_host" {
  source     = "../../../../modules/kubernetes/nfs_volume"
  name       = "dbaas-postgresql-backup-host"
  namespace  = kubernetes_namespace.dbaas.metadata[0].name
  nfs_server = "192.168.1.127"
  nfs_path   = "/srv/nfs/postgresql-backup"
}

resource "kubernetes_cron_job_v1" "mysql-backup" {
  metadata {
    name      = "mysql-backup"
    namespace = kubernetes_namespace.dbaas.metadata[0].name
  }
  spec {
    concurrency_policy        = "Replace"
    failed_jobs_history_limit = 5
    schedule                  = "30 0 * * *"
    # schedule                      = "* * * * *"
    starting_deadline_seconds     = 10
    successful_jobs_history_limit = 10
    job_template {
      metadata {}
      spec {
        backoff_limit              = 3
        ttl_seconds_after_finished = 10
        template {
          metadata {}
          spec {
            container {
              name  = "mysql-backup"
              image = "docker.io/library/mysql:8.0"
              env {
                name = "MYSQL_PWD"
                value_from {
                  secret_key_ref {
                    name = "cluster-secret"
                    key  = "ROOT_PASSWORD"
                  }
                }
              }
              command = ["/bin/bash", "-c", <<-EOT
                set -euxo pipefail
                _t0=$(date +%s)
                _rb0=$(awk '/^read_bytes/{print $2}' /proc/$$/io 2>/dev/null || echo 0)
                _wb0=$(awk '/^write_bytes/{print $2}' /proc/$$/io 2>/dev/null || echo 0)

                export now=$(date +"%Y_%m_%d_%H_%M")
                mysqldump --all-databases -u root --host mysql.dbaas.svc.cluster.local | gzip -9 > /backup/dump_$now.sql.gz

                # Rotate — 14 day retention
                cd /backup
                find . -name "dump_*.sql.gz" -type f -mtime +14 -delete
                find . -name "dump_*.sql" -type f -mtime +14 -delete  # clean up old uncompressed

                _dur=$(($(date +%s) - _t0))
                _rb1=$(awk '/^read_bytes/{print $2}' /proc/$$/io 2>/dev/null || echo 0)
                _wb1=$(awk '/^write_bytes/{print $2}' /proc/$$/io 2>/dev/null || echo 0)
                echo "=== Backup IO Stats ==="
                echo "duration: $${_dur}s"
                echo "read:    $(( (_rb1 - _rb0) / 1048576 )) MiB"
                echo "written: $(( (_wb1 - _wb0) / 1048576 )) MiB"
                echo "output:  $(ls -lh /backup/dump_$now.sql.gz | awk '{print $5}')"

                _out_bytes=$(stat -c%s /backup/dump_$now.sql.gz)
                curl -sf --data-binary @- "http://prometheus-prometheus-pushgateway.monitoring:9091/metrics/job/mysql-backup" <<PGEOF || true
                backup_duration_seconds $${_dur}
                backup_read_bytes $(( _rb1 - _rb0 ))
                backup_written_bytes $(( _wb1 - _wb0 ))
                backup_output_bytes $${_out_bytes}
                backup_last_success_timestamp $(date +%s)
                PGEOF
              EOT
              ]
              # To restore (from outside of the cluster):
              # run kubectl port-forward to pod e.g.:
              # > kb port-forward mysql-647cfd4969-46rmw --address 0.0.0.0 3307:3306
              # run mysql import (and specify non-localhost address to avoid using unix socket): (password is in tfvars)
              # > mysql -u root -p --host 10.0.10.10 --port 3307 < /mnt/nfs/2024_01_06_13_54.sql
              volume_mount {
                name       = "mysql-backup"
                mount_path = "/backup"
              }
            }
            volume {
              name = "mysql-backup"
              persistent_volume_claim {
                claim_name = module.nfs_mysql_backup_host.claim_name
              }
            }
          }
        }
      }
    }
  }
}

# Per-database MySQL backups (enables single-database restore without affecting others)
resource "kubernetes_cron_job_v1" "mysql-backup-per-db" {
  metadata {
    name      = "mysql-backup-per-db"
    namespace = kubernetes_namespace.dbaas.metadata[0].name
  }
  spec {
    concurrency_policy            = "Replace"
    failed_jobs_history_limit     = 3
    schedule                      = "45 0 * * *"
    starting_deadline_seconds     = 10
    successful_jobs_history_limit = 3
    job_template {
      metadata {}
      spec {
        backoff_limit              = 3
        ttl_seconds_after_finished = 10
        template {
          metadata {}
          spec {
            container {
              name  = "mysql-backup-per-db"
              image = "docker.io/library/mysql:8.0"
              env {
                name = "MYSQL_PWD"
                value_from {
                  secret_key_ref {
                    name = "cluster-secret"
                    key  = "ROOT_PASSWORD"
                  }
                }
              }
              command = ["/bin/bash", "-c", <<-EOT
                set -euo pipefail
                _t0=$(date +%s)
                now=$(date +"%Y_%m_%d_%H_%M")
                MYSQL_HOST=mysql.dbaas.svc.cluster.local
                failed=0
                total=0
                ok=0

                # Discover all user databases
                dbs=$(mysql -u root --host $MYSQL_HOST -N -e \
                  "SELECT schema_name FROM information_schema.schemata WHERE schema_name NOT IN ('mysql','information_schema','performance_schema','sys','mysql_innodb_cluster_metadata');")

                for db in $dbs; do
                  total=$((total + 1))
                  mkdir -p /backup/per-db/$db
                  echo "=== Backing up $db ==="
                  if mysqldump -u root --host $MYSQL_HOST --single-transaction --set-gtid-purged=OFF "$db" | gzip -9 > "/backup/per-db/$db/dump_$now.sql.gz"; then
                    _size=$(stat -c%s "/backup/per-db/$db/dump_$now.sql.gz")
                    echo "  OK — $(( _size / 1024 )) KiB"
                    ok=$((ok + 1))
                  else
                    echo "  FAILED"
                    rm -f "/backup/per-db/$db/dump_$now.sql.gz"
                    failed=$((failed + 1))
                  fi
                done

                # Rotate — 14 day retention per database
                find /backup/per-db -name "dump_*.sql.gz" -type f -mtime +14 -delete

                _dur=$(($(date +%s) - _t0))
                echo "=== Per-DB Backup Summary ==="
                echo "databases: $total (ok: $ok, failed: $failed)"
                echo "duration: $${_dur}s"

                curl -sf --data-binary @- "http://prometheus-prometheus-pushgateway.monitoring:9091/metrics/job/mysql-backup-per-db" <<PGEOF || true
                backup_duration_seconds $${_dur}
                backup_databases_total $total
                backup_databases_ok $ok
                backup_databases_failed $failed
                backup_last_success_timestamp $(date +%s)
                PGEOF
              EOT
              ]
              volume_mount {
                name       = "mysql-backup"
                mount_path = "/backup"
              }
            }
            volume {
              name = "mysql-backup"
              persistent_volume_claim {
                claim_name = module.nfs_mysql_backup_host.claim_name
              }
            }
          }
        }
      }
    }
  }
}

# resource "kubernetes_persistent_volume" "mysql" {
#   metadata {
#     name = "mysql-pv"
#   }
#   spec {
#     capacity = {
#       "storage" = "10Gi"
#     }
#     access_modes = ["ReadWriteOnce"]
#     persistent_volume_source {
#       iscsi {
#         target_portal = "iscsi.viktorbarzin.lan:3260"
#         iqn           = "iqn.2020-12.lan.viktorbarzin:storage:dbaas:mysql"
#         lun           = 0
#         fs_type       = "ext4"
#       }
#     }
#   }
# }


# resource "helm_release" "mysql" {
#  namespace = kubernetes_namespace.dbaas.metadata[0].name
#   create_namespace = false
#   name             = "mysql"

#   repository = "https://presslabs.github.io/charts"
#   chart      = "mysql-operator"
#   # version    = "v0.5.0-rc.3"

#   values = [templatefile("${path.module}/mysql_chart_values.yaml", { secretName = var.tls_secret_name })]
#   atomic = true

#   depends_on = [kubernetes_namespace.dbaas]
# }

# # resource "helm_release" "mysql" {
# #  namespace = kubernetes_namespace.dbaas.metadata[0].name
# #   create_namespace = false
# #   name             = "mysql-operator"

# #   repository = "https://mysql.github.io/mysql-operator/"
# #   chart      = "mysql-operator"
# #   atomic     = true
# #   depends_on = [kubernetes_namespace.dbaas]
# # }

# # resource "helm_release" "innodb-cluster" {
# #  namespace = kubernetes_namespace.dbaas.metadata[0].name
# #   create_namespace = false
# #   name             = var.cluster_master_service

# #   repository = "https://mysql.github.io/mysql-operator/"
# #   chart      = "mysql-innodbcluster"
# #   atomic     = true
# #   depends_on = [kubernetes_namespace.dbaas]
# #   values     = [templatefile("${path.module}/chart_values.tpl", { root_password = var.dbaas_root_password })]
# # }

# resource "kubernetes_persistent_volume" "mysql-operator" {
#   metadata {
#     name = "mysql-operator-pv"
#   }
#   spec {
#     capacity = {
#       "storage" = "1Gi"
#     }
#     access_modes = ["ReadWriteOnce"]
#     persistent_volume_source {
#       iscsi {
#         target_portal = "iscsi.viktorbarzin.lan:3260"
#         iqn           = "iqn.2020-12.lan.viktorbarzin:storage:dbaas:operator"
#         lun           = 0
#         fs_type       = "ext4"
#       }
#     }
#   }
# }

resource "kubernetes_secret" "cluster-password" {
  metadata {
    name      = "cluster-secret"
    namespace = kubernetes_namespace.dbaas.metadata[0].name
    annotations = {
      "reloader.stakater.com/match" = "true"
    }
  }
  type = "Opaque"
  data = {
    "ROOT_PASSWORD" = var.dbaas_root_password
  }
}

# resource "kubernetes_ingress_v1" "dbaas" {
#   metadata {
#     name      = "orchestrator-ingress"
#    namespace = kubernetes_namespace.dbaas.metadata[0].name
#     annotations = {
#       "kubernetes.io/ingress.class"                        = "nginx"
#       "nginx.ingress.kubernetes.io/auth-tls-verify-client" = "on"
#       "nginx.ingress.kubernetes.io/auth-tls-secret"        = "default/ca-secret"
#     }
#   }

#   spec {
#     tls {
#       hosts       = ["db.viktorbarzin.me"]
#       secret_name = var.tls_secret_name
#     }
#     rule {
#       host = "db.viktorbarzin.me"
#       http {
#         path {
#           path = "/"
#           backend {
#             service {
#               name = "mysql-mysql-operator"
#               port {
#                 number = 80
#               }
#             }
#           }
#         }
#       }
#     }
#   }
# }


# PHPMyAdmin instance
resource "kubernetes_deployment" "phpmyadmin" {
  metadata {
    name      = "phpmyadmin"
    namespace = kubernetes_namespace.dbaas.metadata[0].name
    labels = {
      "app" = "phpmyadmin"
      tier  = var.tier

    }
    annotations = {
      "reloader.stakater.com/search" = "true"
    }
  }
  spec {
    replicas = "1"
    selector {
      match_labels = {
        "app" = "phpmyadmin"
      }
    }
    template {
      metadata {
        labels = {
          "app" = "phpmyadmin"
        }
      }
      spec {
        container {
          name  = "phpmyadmin"
          image = "phpmyadmin/phpmyadmin:5.2.3"
          port {
            container_port = 80
          }
          env {
            name  = "PMA_HOST"
            value = var.cluster_master_service
          }
          env {
            name  = "PMA_PORT"
            value = "3306"
          }
          env {
            name = "MYSQL_ROOT_PASSWORD"
            value_from {
              secret_key_ref {
                name = "cluster-secret"
                key  = "ROOT_PASSWORD"
              }
            }
          }
          env {
            name  = "UPLOAD_LIMIT"
            value = "300M"
          }
          resources {
            requests = {
              cpu    = "15m"
              memory = "100Mi"
            }
            limits = {
              memory = "100Mi"
            }
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

resource "kubernetes_service" "phpmyadmin" {
  metadata {
    name      = "pma"
    namespace = kubernetes_namespace.dbaas.metadata[0].name
  }
  spec {
    selector = {
      "app" = "phpmyadmin"
    }
    port {
      name = "web"
      port = 80
    }
  }
}
module "ingress" {
  source            = "../../../../modules/kubernetes/ingress_factory"
  dns_type          = "proxied"
  namespace         = kubernetes_namespace.dbaas.metadata[0].name
  name              = "pma"
  tls_secret_name   = var.tls_secret_name
  protected         = true
  extra_annotations = {}
}


# resource "kubectl_manifest" "mysql-cluster" {
#   yaml_body  = <<-YAML
#     apiVersion: mysql.presslabs.org/v1alpha1
#     kind: MysqlCluster
#     metadata:
#       name: mysql-cluster
#      namespace = kubernetes_namespace.dbaas.metadata[0].name
#     spec:
#       mysqlVersion: "5.7"
#       replicas: 1
#       secretName: cluster-secret
#       mysqlConf:
#         # read_only: 0                          # mysql forms a single transaction for each sql statement, autocommit for each statement
#         # automatic_sp_privileges: "ON"         # automatically grants the EXECUTE and ALTER ROUTINE privileges to the creator of a stored routine
#         # auto_generate_certs: "ON"             # Auto Generation of Certificate
#         # auto_increment_increment: 1           # Auto Incrementing value from +1
#         # auto_increment_offset: 1              # Auto Increment Offset
#         # binlog-format: "STATEMENT"            # contains various options such ROW(SLOW,SAFE) STATEMENT(FAST,UNSAFE), MIXED(combination of both)
#         # wait_timeout: 31536000                # 28800 number of seconds the server waits for activity on a non-interactive connection before closing it, You might encounter MySQL server has gone away error, you then tweak this value acccordingly
#         # interactive_timeout: 28800            # The number of seconds the server waits for activity on an interactive connection before closing it.
#         # max_allowed_packet: "512M"            # Maximum size of MYSQL Network protocol packet that the server can create or read 4MB, 8MB, 16MB, 32MB
#         # max-binlog-size: 1073741824           # binary logs contains the events that describe database changes, this parameter describe size for the bin_log file.
#         # log_output: "TABLE"                   # Format in which the logout will be dumped
#         # master-info-repository: "TABLE"       # Format in which the master info will be dumped
#         # relay_log_info_repository: "TABLE"    # Format in which the relay info will be dumped
#       volumeSpec:
#         persistentVolumeClaim:
#           accessModes:
#           - ReadWriteOnce
#           resources:
#             requests:
#               storage: 10Gi
#   YAML
#   depends_on = [helm_release.mysql]
#   # manifest = {
#   #   apiVersion = "mysql.presslabs.org/v1alpha1"
#   #   kind       = "MysqlCluster"
#   #   metadata = {
#   #     name      = "mysql-cluster"
#   #    namespace = kubernetes_namespace.dbaas.metadata[0].name
#   #   }
#   #   spec = {
#   #     mysqlVersion = "5.7"
#   #     replicas     = 1
#   #     secretName   = "cluster-secret"
#   #     mysqlConf = {
#   #       read_only = 0
#   #     }
#   #     volumeSpec = {
#   #       persistentVolumeClaim = {
#   #         resources = {
#   #           requests = {
#   #             storage = "10Gi"
#   #           }
#   #         }
#   #       }
#   #     }
#   #   }
#   # }
# }


# For some unknwown reason not all CRDs are installed. Add them manually
# resource "kubectl_manifest" "mysql-user" {
#   yaml_body = <<-EOF
#     apiVersion: apiextensions.k8s.io/v1
#     kind: CustomResourceDefinition
#     metadata:
#       annotations:
#         controller-gen.kubebuilder.io/version: v0.5.0
#         helm.sh/hook: crd-install
#       name: mysqlusers.mysql.presslabs.org
#       labels:
#         app: mysql-operator
#     spec:
#       group: mysql.presslabs.org
#       names:
#         kind: MysqlUser
#         listKind: MysqlUserList
#         plural: mysqlusers
#         singular: mysqluser
#       scope:namespace = kubernetes_namespace.dbaas.metadata[0].name
#       versions:
#         - additionalPrinterColumns:
#             - description: The user status
#               jsonPath: .status.conditions[?(@.type == 'Ready')].status
#               name: Ready
#               type: string
#             - jsonPath: .spec.clusterRef.name
#               name: Cluster
#               type: string
#             - jsonPath: .spec.user
#               name: UserName
#               type: string
#             - jsonPath: .metadata.creationTimestamp
#               name: Age
#               type: date
#           name: v1alpha1
#           schema:
#             openAPIV3Schema:
#               description: MysqlUser is the Schema for the MySQL User API
#               properties:
#                 apiVersion:
#                   description: 'APIVersion defines the versioned schema of this representation of an object. Servers should convert recognized schemas to the latest internal value, and may reject unrecognized values. More info: https://git.k8s.io/community/contributors/devel/sig-architecture/api-conventions.md#resources'
#                   type: string
#                 kind:
#                   description: 'Kind is a string value representing the REST resource this object represents. Servers may infer this from the endpoint the client submits requests to. Cannot be updated. In CamelCase. More info: https://git.k8s.io/community/contributors/devel/sig-architecture/api-conventions.md#types-kinds'
#                   type: string
#                 metadata:
#                   type: object
#                 spec:
#                   description: MysqlUserSpec defines the desired state of MysqlUserSpec
#                   properties:
#                     allowedHosts:
#                       description: AllowedHosts is the allowed host to connect from.
#                       items:
#                         type: string
#                       type: array
#                     clusterRef:
#                       description: ClusterRef represents a reference to the MySQL cluster. This field should be immutable.
#                       properties:
#                         name:
#                           description: 'Name of the referent. More info: https://kubernetes.io/docs/concepts/overview/working-with-objects/names/#names TODO: Add other useful fields. apiVersion, kind, uid?'
#                           type: string
#                        namespace = kubernetes_namespace.dbaas.metadata[0].name
#                           description:namespace = kubernetes_namespace.dbaas.metadata[0].name
#                           type: string
#                       type: object
#                     password:
#                       description: Password is the password for the user.
#                       properties:
#                         key:
#                           description: The key of the secret to select from.  Must be a valid secret key.
#                           type: string
#                         name:
#                           description: 'Name of the referent. More info: https://kubernetes.io/docs/concepts/overview/working-with-objects/names/#names TODO: Add other useful fields. apiVersion, kind, uid?'
#                           type: string
#                         optional:
#                           description: Specify whether the Secret or its key must be defined
#                           type: boolean
#                       required:
#                         - key
#                       type: object
#                     permissions:
#                       description: Permissions is the list of roles that user has in the specified database.
#                       items:
#                         description: MysqlPermission defines a MySQL schema permission
#                         properties:
#                           permissions:
#                             description: Permissions represents the permissions granted on the schema/tables
#                             items:
#                               type: string
#                             type: array
#                           schema:
#                             description: Schema represents the schema to which the permission applies
#                             type: string
#                           tables:
#                             description: Tables represents the tables inside the schema to which the permission applies
#                             items:
#                               type: string
#                             type: array
#                         required:
#                           - permissions
#                           - schema
#                           - tables
#                         type: object
#                       type: array
#                     resourceLimits:
#                       additionalProperties:
#                         anyOf:
#                           - type: integer
#                           - type: string
#                         pattern: ^(\+|-)?(([0-9]+(\.[0-9]*)?)|(\.[0-9]+))(([KMGTPE]i)|[numkMGTPE]|([eE](\+|-)?(([0-9]+(\.[0-9]*)?)|(\.[0-9]+))))?$
#                         x-kubernetes-int-or-string: true
#                       description: 'ResourceLimits allow settings limit per mysql user as defined here: https://dev.mysql.com/doc/refman/5.7/en/user-resources.html'
#                       type: object
#                     user:
#                       description: User is the name of the user that will be created with will access the specified database. This field should be immutable.
#                       type: string
#                   required:
#                     - allowedHosts
#                     - clusterRef
#                     - password
#                     - user
#                   type: object
#                 status:
#                   description: MysqlUserStatus defines the observed state of MysqlUser
#                   properties:
#                     allowedHosts:
#                       description: AllowedHosts contains the list of hosts that the user is allowed to connect from.
#                       items:
#                         type: string
#                       type: array
#                     conditions:
#                       description: Conditions represents the MysqlUser resource conditions list.
#                       items:
#                         description: MySQLUserCondition defines the condition struct for a MysqlUser resource
#                         properties:
#                           lastTransitionTime:
#                             description: Last time the condition transitioned from one status to another.
#                             format: date-time
#                             type: string
#                           lastUpdateTime:
#                             description: The last time this condition was updated.
#                             format: date-time
#                             type: string
#                           message:
#                             description: A human readable message indicating details about the transition.
#                             type: string
#                           reason:
#                             description: The reason for the condition's last transition.
#                             type: string
#                           status:
#                             description: Status of the condition, one of True, False, Unknown.
#                             type: string
#                           type:
#                             description: Type of MysqlUser condition.
#                             type: string
#                         required:
#                           - lastTransitionTime
#                           - message
#                           - reason
#                           - status
#                           - type
#                         type: object
#                       type: array
#                   type: object
#               type: object
#           served: true
#           storage: true
#           subresources:
#             status: {}
#   EOF
# }

#### POSTGRESQL — CloudNativePG Cluster
#
# Migrated from single NFS-backed pod to CNPG on local-path storage.
# CNPG Cluster is managed via kubectl apply (not kubernetes_manifest)
# because the CNPG webhook mutates the spec on apply, causing
# Terraform provider "inconsistent result" errors.
#
# Rollback: apply old deployment yaml, revert service selector to app=postgresql.

# Ensure the CNPG cluster manifest exists (idempotent kubectl apply)
resource "null_resource" "pg_cluster" {
  triggers = {
    instances     = "2"
    image         = "ghcr.io/cloudnative-pg/postgis:16"
    storage_size  = "20Gi"
    storage_class = "proxmox-lvm-encrypted"
    memory_limit  = "2Gi"
    pg_params     = "v2-shared512-walcomp-workmem16"
  }

  provisioner "local-exec" {
    command = <<-EOT
      kubectl --kubeconfig ${var.kube_config_path} apply -f - <<'EOF'
      apiVersion: postgresql.cnpg.io/v1
      kind: Cluster
      metadata:
        name: pg-cluster
        namespace: dbaas
      spec:
        instances: 2
        imageName: ghcr.io/cloudnative-pg/postgis:16
        postgresql:
          parameters:
            search_path: '"$user", public'
            shared_buffers: "512MB"
            effective_cache_size: "1536MB"
            work_mem: "16MB"
            wal_compression: "on"
            random_page_cost: "4"
            checkpoint_completion_target: "0.9"
          enableAlterSystem: true
        enableSuperuserAccess: true
        inheritedMetadata:
          annotations:
            resize.topolvm.io/threshold: "80%"
            resize.topolvm.io/increase: "20%"
            resize.topolvm.io/storage_limit: "100Gi"
        storage:
          size: 20Gi
          storageClass: proxmox-lvm-encrypted
        resources:
          requests:
            cpu: "50m"
            memory: "2Gi"
          limits:
            memory: "2Gi"
      EOF
    EOT
  }
}

# Service that maintains the original postgresql.dbaas endpoint,
# now pointing at the CNPG primary pod instead of the old deployment.
resource "kubernetes_service" "postgresql" {
  metadata {
    name      = "postgresql"
    namespace = kubernetes_namespace.dbaas.metadata[0].name
  }
  spec {
    selector = {
      "cnpg.io/cluster"      = "pg-cluster"
      "cnpg.io/instanceRole" = "primary"
    }
    port {
      name        = "postgresql"
      port        = 5432
      target_port = 5432
    }
  }
}

# LoadBalancer service for PG primary — accessible from DevVM (10.0.20.200:5432).
# Shares MetalLB IP with other non-conflicting services (Traefik, Dolt, etc.).
resource "kubernetes_service" "postgresql_lb" {
  metadata {
    name      = "postgresql-lb"
    namespace = kubernetes_namespace.dbaas.metadata[0].name
    annotations = {
      "metallb.universe.tf/loadBalancerIPs" = "10.0.20.200"
      "metallb.io/allow-shared-ip"          = "shared"
    }
  }
  spec {
    type = "LoadBalancer"
    selector = {
      "cnpg.io/cluster"      = "pg-cluster"
      "cnpg.io/instanceRole" = "primary"
    }
    port {
      name        = "postgresql"
      port        = 5432
      target_port = 5432
    }
  }
}

# Create terraform_state database for remote TF state backend (pg backend).
# User password is managed by Vault Database Secrets Engine (static role rotation).
resource "null_resource" "pg_terraform_state_db" {
  depends_on = [null_resource.pg_cluster]

  triggers = {
    db_name  = "terraform_state"
    username = "terraform_state"
  }

  provisioner "local-exec" {
    command = <<-EOT
      kubectl --kubeconfig ${var.kube_config_path} exec -n dbaas pg-cluster-1 -c postgres -- \
        bash -c '
          psql -U postgres -tc "SELECT 1 FROM pg_catalog.pg_roles WHERE rolname = '"'"'terraform_state'"'"'" | grep -q 1 || \
            psql -U postgres -c "CREATE ROLE terraform_state WITH LOGIN PASSWORD '"'"'changeme-vault-will-rotate'"'"'"
          psql -U postgres -tc "SELECT 1 FROM pg_catalog.pg_database WHERE datname = '"'"'terraform_state'"'"'" | grep -q 1 || \
            psql -U postgres -c "CREATE DATABASE terraform_state OWNER terraform_state"
          psql -U postgres -c "GRANT ALL PRIVILEGES ON DATABASE terraform_state TO terraform_state"
        '
    EOT
  }
}

# Old PostgreSQL deployment — kept commented for rollback reference
# resource "kubernetes_deployment" "postgres" {
#   metadata {
#     name      = "postgresql"
#     namespace = kubernetes_namespace.dbaas.metadata[0].name
#     labels    = { tier = var.tier }
#   }
#   spec {
#     replicas = 0  # scaled to 0 during CNPG migration
#     selector { match_labels = { app = "postgresql" } }
#     strategy { type = "Recreate" }
#     template {
#       metadata { labels = { app = "postgresql" } }
#       spec {
#         container {
#           image = "viktorbarzin/postgres:16-master"
#           name  = "postgresql"
#           env { name = "POSTGRES_PASSWORD"; value = var.postgresql_root_password }
#           env { name = "POSTGRES_USER"; value = "root" }
#           port { container_port = 5432; protocol = "TCP"; name = "postgresql" }
#           volume_mount { name = "postgresql-persistent-storage"; mount_path = "/var/lib/postgresql/data" }
#         }
#         volume {
#           name = "postgresql-persistent-storage"
#           nfs { path = "/mnt/main/postgresql/data"; server = var.nfs_server }
#         }
#       }
#     }
#   }
# }

#### PGADMIN

resource "kubernetes_deployment" "pgadmin" {
  metadata {
    name      = "pgadmin"
    namespace = kubernetes_namespace.dbaas.metadata[0].name
    annotations = {
      "reloader.stakater.com/search" = "true"
    }
    labels = {
      tier = var.tier
    }
  }
  spec {
    strategy {
      type = "Recreate"
    }
    selector {
      match_labels = {
        app = "pgadmin"
      }
    }
    template {
      metadata {
        labels = {
          app = "pgadmin"
        }
      }
      spec {
        container {
          image = "dpage/pgadmin4"
          name  = "pgadmin"
          env {
            name  = "PGADMIN_DEFAULT_EMAIL"
            value = "me@viktorbarzin.me"
          }
          env {
            name = "PGADMIN_DEFAULT_PASSWORD"
            # Changed at startup
            value = var.pgadmin_password
          }
          port {
            container_port = 80
            name           = "web"
          }
          volume_mount {
            name       = "pgadmin"
            mount_path = "/var/lib/pgadmin/"
          }

          resources {
            requests = {
              cpu    = "25m"
              memory = "450Mi"
            }
            limits = {
              memory = "450Mi"
            }
          }

        }
        volume {
          name = "pgadmin"
          # config_map {
          #   name = "pgadmin-config"
          # }
          persistent_volume_claim {
            claim_name = kubernetes_persistent_volume_claim.pgadmin_encrypted.metadata[0].name
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
resource "kubernetes_service" "pgadmin" {
  metadata {
    name      = "pgadmin"
    namespace = kubernetes_namespace.dbaas.metadata[0].name
  }
  spec {
    selector = {
      "app" = "pgadmin"
    }
    port {
      name = "pgadmin"
      port = 80
    }
  }
}
module "ingress-pgadmin" {
  source          = "../../../../modules/kubernetes/ingress_factory"
  dns_type        = "proxied"
  namespace       = kubernetes_namespace.dbaas.metadata[0].name
  name            = "pgadmin"
  tls_secret_name = var.tls_secret_name
  protected       = true
}


resource "kubernetes_cron_job_v1" "postgresql-backup" {
  metadata {
    name      = "postgresql-backup"
    namespace = kubernetes_namespace.dbaas.metadata[0].name
  }
  spec {
    concurrency_policy        = "Replace"
    failed_jobs_history_limit = 5
    schedule                  = "0 0 * * *"
    # schedule                      = "* * * * *"
    starting_deadline_seconds     = 10
    successful_jobs_history_limit = 10
    job_template {
      metadata {}
      spec {
        backoff_limit              = 3
        ttl_seconds_after_finished = 10
        template {
          metadata {}
          spec {
            container {
              name  = "postgresql-backup"
              image = "docker.io/library/postgres:16.4-bullseye"
              env {
                name = "PGPASSWORD"
                value_from {
                  secret_key_ref {
                    name = "pg-cluster-superuser"
                    key  = "password"
                  }
                }
              }
              command = ["/bin/bash", "-c", <<-EOT
                set -euxo pipefail
                apt-get update -qq && apt-get install -yqq curl >/dev/null 2>&1 || true
                _t0=$(date +%s)
                _rb0=$(awk '/^read_bytes/{print $2}' /proc/$$/io 2>/dev/null || echo 0)
                _wb0=$(awk '/^write_bytes/{print $2}' /proc/$$/io 2>/dev/null || echo 0)

                export now=$(date +"%Y_%m_%d_%H_%M")
                PGPASSWORD=$PGPASSWORD pg_dumpall -h pg-cluster-rw.dbaas -U postgres | gzip -9 > /backup/dump_$now.sql.gz

                # Rotate — 14 day retention
                cd /backup
                find . -name "dump_*.sql.gz" -type f -mtime +14 -delete
                find . -name "dump_*.sql" -type f -mtime +14 -delete  # clean up old uncompressed

                _dur=$(($(date +%s) - _t0))
                _rb1=$(awk '/^read_bytes/{print $2}' /proc/$$/io 2>/dev/null || echo 0)
                _wb1=$(awk '/^write_bytes/{print $2}' /proc/$$/io 2>/dev/null || echo 0)
                echo "=== Backup IO Stats ==="
                echo "duration: $${_dur}s"
                echo "read:    $(( (_rb1 - _rb0) / 1048576 )) MiB"
                echo "written: $(( (_wb1 - _wb0) / 1048576 )) MiB"
                echo "output:  $(ls -lh /backup/dump_$now.sql.gz | awk '{print $5}')"

                _out_bytes=$(stat -c%s /backup/dump_$now.sql.gz)
                curl -sf --data-binary @- "http://prometheus-prometheus-pushgateway.monitoring:9091/metrics/job/postgresql-backup" <<PGEOF || true
                backup_duration_seconds $${_dur}
                backup_read_bytes $(( _rb1 - _rb0 ))
                backup_written_bytes $(( _wb1 - _wb0 ))
                backup_output_bytes $${_out_bytes}
                backup_last_success_timestamp $(date +%s)
                PGEOF
              EOT
              ]
              volume_mount {
                name       = "postgresql-backup"
                mount_path = "/backup"
              }
            }
            volume {
              name = "postgresql-backup"
              persistent_volume_claim {
                claim_name = module.nfs_postgresql_backup_host.claim_name
              }
            }
          }
        }
      }
    }
  }
}

# Per-database PostgreSQL backups (enables single-database restore without affecting others)
resource "kubernetes_cron_job_v1" "postgresql-backup-per-db" {
  metadata {
    name      = "postgresql-backup-per-db"
    namespace = kubernetes_namespace.dbaas.metadata[0].name
  }
  spec {
    concurrency_policy            = "Replace"
    failed_jobs_history_limit     = 3
    schedule                      = "15 0 * * *"
    starting_deadline_seconds     = 10
    successful_jobs_history_limit = 3
    job_template {
      metadata {}
      spec {
        backoff_limit              = 3
        ttl_seconds_after_finished = 10
        template {
          metadata {}
          spec {
            container {
              name  = "postgresql-backup-per-db"
              image = "docker.io/library/postgres:16.4-bullseye"
              env {
                name = "PGPASSWORD"
                value_from {
                  secret_key_ref {
                    name = "pg-cluster-superuser"
                    key  = "password"
                  }
                }
              }
              command = ["/bin/bash", "-c", <<-EOT
                set -euo pipefail
                apt-get update -qq && apt-get install -yqq curl >/dev/null 2>&1 || true

                _t0=$(date +%s)
                now=$(date +"%Y_%m_%d_%H_%M")
                PGHOST=pg-cluster-rw.dbaas
                PGUSER=postgres
                failed=0
                total=0
                ok=0

                # Discover all user databases
                dbs=$(PGPASSWORD=$PGPASSWORD psql -h $PGHOST -U $PGUSER -t -A -c \
                  "SELECT datname FROM pg_database WHERE datistemplate = false AND datname != 'postgres' ORDER BY datname;")

                for db in $dbs; do
                  total=$((total + 1))
                  mkdir -p /backup/per-db/$db
                  echo "=== Backing up $db ==="
                  if PGPASSWORD=$PGPASSWORD pg_dump -Fc -h $PGHOST -U $PGUSER "$db" > "/backup/per-db/$db/dump_$now.dump"; then
                    _size=$(stat -c%s "/backup/per-db/$db/dump_$now.dump")
                    echo "  OK — $(( _size / 1024 )) KiB"
                    ok=$((ok + 1))
                  else
                    echo "  FAILED"
                    rm -f "/backup/per-db/$db/dump_$now.dump"
                    failed=$((failed + 1))
                  fi
                done

                # Rotate — 14 day retention per database
                find /backup/per-db -name "dump_*.dump" -type f -mtime +14 -delete

                _dur=$(($(date +%s) - _t0))
                echo "=== Per-DB Backup Summary ==="
                echo "databases: $total (ok: $ok, failed: $failed)"
                echo "duration: $${_dur}s"

                curl -sf --data-binary @- "http://prometheus-prometheus-pushgateway.monitoring:9091/metrics/job/postgresql-backup-per-db" <<PGEOF || true
                backup_duration_seconds $${_dur}
                backup_databases_total $total
                backup_databases_ok $ok
                backup_databases_failed $failed
                backup_last_success_timestamp $(date +%s)
                PGEOF
              EOT
              ]
              volume_mount {
                name       = "postgresql-backup"
                mount_path = "/backup"
              }
              resources {
                requests = {
                  memory = "256Mi"
                  cpu    = "50m"
                }
                limits = {
                  memory = "512Mi"
                }
              }
            }
            volume {
              name = "postgresql-backup"
              persistent_volume_claim {
                claim_name = module.nfs_postgresql_backup_host.claim_name
              }
            }
          }
        }
      }
    }
  }
}
