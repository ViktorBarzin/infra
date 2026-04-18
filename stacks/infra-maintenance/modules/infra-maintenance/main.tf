# Module to run some infra-specific things like updating the public ip
variable "git_user" {}
variable "git_token" {}
variable "technitium_username" {}
variable "technitium_password" {}
variable "nfs_server" { type = string }


# DISABLED WHILST USING CLOUDFLARE NS
# resource "kubernetes_cron_job_v1" "update-public-ip" {
#   metadata {
#     name      = "update-public-ip"
#     namespace = "default"
#   }
#   spec {
#     schedule                      = "*/5 * * * *"
#     successful_jobs_history_limit = 1
#     failed_jobs_history_limit     = 1
#     concurrency_policy            = "Forbid"
#     job_template {
#       metadata {
#         name = "update-public-ip"
#       }
#       spec {
#         template {
#           metadata {
#             name = "update-public-ip"
#           }
#           spec {
#             priority_class_name = "system-cluster-critical"
#             container {
#               name    = "update-public-ip"
#               image   = "viktorbarzin/infra"
#               command = ["./infra_cli"]
#               args    = ["-use-case", "update-public-ip"]

#               env {
#                 name  = "GIT_USER"
#                 value = var.git_user
#               }
#               env {
#                 name  = "GIT_TOKEN"
#                 value = var.git_token
#               }
#               env {
#                 name  = "TECHNITIUM_USERNAME"
#                 value = var.technitium_username
#               }
#               env {
#                 name  = "TECHNITIUM_PASSWORD"
#                 value = var.technitium_password
#               }
#             }
#             restart_policy = "Never"
#             # service_account_name = "descheduler-sa"
#             # volume {
#             #   name = "policy-volume"
#             #   config_map {
#             #     name = "policy-configmap"
#             #   }
#             # }
#           }
#         }
#       }
#     }
#   }
# }

module "nfs_etcd_backup_host" {
  source     = "../../../../modules/kubernetes/nfs_volume"
  name       = "infra-etcd-backup-host"
  namespace  = "default"
  nfs_server = "192.168.1.127"
  nfs_path   = "/srv/nfs/etcd-backup"
}

# # backup etcd
resource "kubernetes_cron_job_v1" "backup-etcd" {
  metadata {
    name      = "backup-etcd"
    namespace = "default"
  }
  spec {
    schedule                      = "0 1 * * 0"
    successful_jobs_history_limit = 1
    failed_jobs_history_limit     = 1
    concurrency_policy            = "Forbid"
    job_template {
      metadata {
        name = "backup-etcd"
      }
      spec {
        template {
          metadata {
            name = "backup-etcd"
          }
          spec {
            node_name           = "k8s-master"
            priority_class_name = "system-cluster-critical"
            host_network        = true
            dns_policy          = "ClusterFirstWithHostNet"
            init_container {
              name    = "backup-etcd"
              image   = "registry.k8s.io/etcd:3.5.21-0"
              command = ["etcdctl", "snapshot", "save", "/backup/etcd-snapshot-latest.db"]
              resources {
                requests = {
                  memory = "256Mi"
                  cpu    = "50m"
                }
                limits = {
                  memory = "512Mi"
                }
              }
              env {
                name  = "ETCDCTL_API"
                value = "3"
              }
              env {
                name  = "ETCDCTL_ENDPOINTS"
                value = "https://127.0.0.1:2379"
              }
              env {
                name  = "ETCDCTL_CACERT"
                value = "/etc/kubernetes/pki/etcd/ca.crt"
              }
              env {
                name  = "ETCDCTL_CERT"
                value = "/etc/kubernetes/pki/etcd/healthcheck-client.crt"
              }
              env {
                name  = "ETCDCTL_KEY"
                value = "/etc/kubernetes/pki/etcd/healthcheck-client.key"
              }
              volume_mount {
                mount_path = "/backup"
                name       = "backup"
              }
              volume_mount {
                mount_path = "/etc/kubernetes/pki/etcd"
                name       = "etcd-certs"
                read_only  = true
              }
            }
            container {
              name    = "backup-manage"
              image   = "busybox:1.37"
              command = ["/bin/sh", "-c"]
              args = [<<-EOT
                set -eu
                # Rename snapshot with timestamp
                TIMESTAMP=$(date +%Y%m%d-%H%M%S)
                mv /backup/etcd-snapshot-latest.db /backup/etcd-snapshot-$TIMESTAMP.db
                _out_bytes=$(stat -c%s /backup/etcd-snapshot-$TIMESTAMP.db 2>/dev/null || echo 0)
                echo "Backup done: etcd-snapshot-$TIMESTAMP.db ($${_out_bytes} bytes)"

                # Rotate — 30 day retention
                find /backup -type f -mtime +30 -name '*.db' -exec rm -- '{}' \;

                # Push metrics to Pushgateway
                wget -qO- --post-data "backup_output_bytes $${_out_bytes}
                backup_last_success_timestamp $(date +%s)
                " "http://prometheus-prometheus-pushgateway.monitoring:9091/metrics/job/backup-etcd" || true
              EOT
              ]
              volume_mount {
                mount_path = "/backup"
                name       = "backup"
              }
            }

            volume {
              name = "backup"
              persistent_volume_claim {
                claim_name = module.nfs_etcd_backup_host.claim_name
              }
            }
            volume {
              name = "etcd-certs"
              host_path {
                path = "/etc/kubernetes/pki/etcd"
                type = "DirectoryOrCreate"
              }
            }
            restart_policy = "Never"
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

# Weekly etcd defragmentation — prevents fragmentation buildup that causes slow requests
resource "kubernetes_cron_job_v1" "defrag-etcd" {
  metadata {
    name      = "defrag-etcd"
    namespace = "default"
  }
  spec {
    schedule                      = "0 3 * * 0"
    successful_jobs_history_limit = 1
    failed_jobs_history_limit     = 1
    concurrency_policy            = "Forbid"
    job_template {
      metadata {
        name = "defrag-etcd"
      }
      spec {
        template {
          metadata {
            name = "defrag-etcd"
          }
          spec {
            node_name           = "k8s-master"
            priority_class_name = "system-cluster-critical"
            host_network        = true
            container {
              name    = "defrag-etcd"
              image   = "registry.k8s.io/etcd:3.5.21-0"
              command = ["etcdctl"]
              args    = ["--endpoints=https://127.0.0.1:2379", "--cacert=/etc/kubernetes/pki/etcd/ca.crt", "--cert=/etc/kubernetes/pki/etcd/healthcheck-client.crt", "--key=/etc/kubernetes/pki/etcd/healthcheck-client.key", "--command-timeout=60s", "defrag"]
              env {
                name  = "ETCDCTL_API"
                value = "3"
              }
              volume_mount {
                mount_path = "/etc/kubernetes/pki/etcd"
                name       = "etcd-certs"
                read_only  = true
              }
            }
            volume {
              name = "etcd-certs"
              host_path {
                path = "/etc/kubernetes/pki/etcd"
                type = "DirectoryOrCreate"
              }
            }
            restart_policy = "Never"
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

# Clean up evicted/failed pods cluster-wide daily
resource "kubernetes_cron_job_v1" "cleanup-failed-pods" {
  metadata {
    name      = "cleanup-failed-pods"
    namespace = "default"
  }
  spec {
    schedule                      = "0 2 * * *"
    successful_jobs_history_limit = 1
    failed_jobs_history_limit     = 1
    concurrency_policy            = "Forbid"
    job_template {
      metadata {
        name = "cleanup-failed-pods"
      }
      spec {
        template {
          metadata {
            name = "cleanup-failed-pods"
          }
          spec {
            service_account_name = kubernetes_service_account.cleanup_sa.metadata[0].name
            container {
              name    = "cleanup"
              image   = "bitnami/kubectl:latest"
              command = ["/bin/sh", "-c", "kubectl delete pods -A --field-selector=status.phase=Failed --ignore-not-found"]
            }
            restart_policy = "Never"
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

resource "kubernetes_service_account" "cleanup_sa" {
  metadata {
    name      = "failed-pod-cleanup"
    namespace = "default"
  }
}

resource "kubernetes_cluster_role" "cleanup_role" {
  metadata {
    name = "failed-pod-cleanup"
  }
  rule {
    api_groups = [""]
    resources  = ["pods"]
    verbs      = ["list", "delete"]
  }
}

resource "kubernetes_cluster_role_binding" "cleanup_binding" {
  metadata {
    name = "failed-pod-cleanup"
  }
  role_ref {
    api_group = "rbac.authorization.k8s.io"
    kind      = "ClusterRole"
    name      = kubernetes_cluster_role.cleanup_role.metadata[0].name
  }
  subject {
    kind      = "ServiceAccount"
    name      = kubernetes_service_account.cleanup_sa.metadata[0].name
    namespace = "default"
  }
}
