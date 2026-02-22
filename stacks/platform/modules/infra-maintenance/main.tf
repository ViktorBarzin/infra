# Module to run some infra-specific things like updating the public ip
variable "git_user" {}
variable "git_token" {}
variable "technitium_username" {}
variable "technitium_password" {}


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

# # backup etcd
resource "kubernetes_cron_job_v1" "backup-etcd" {
  metadata {
    name      = "backup-etcd"
    namespace = "default"
  }
  spec {
    schedule                      = "0 0 * * *"
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
            container {
              name    = "backup-etcd"
              image   = "k8s.gcr.io/etcd-amd64:3.3.15"
              command = ["/bin/sh"]
              args    = ["-c", "etcdctl --endpoints=https://127.0.0.1:2379 --cacert=/etc/kubernetes/pki/etcd/ca.crt --cert=/etc/kubernetes/pki/etcd/healthcheck-client.crt --key=/etc/kubernetes/pki/etcd/healthcheck-client.key snapshot save /backup/etcd-snapshot-$(date +%Y_%m_%d_%H:%M:%S_%Z).db"]
              env {
                name  = "ETCDCTL_API"
                value = "3"
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
              name    = "backup-purge"
              image   = "busybox:1.31.1"
              command = ["/bin/sh"]
              args    = ["-c", "find /backup -type f -mtime +30 -name '*.db' -exec rm -- '{}' \\;"]

              volume_mount {
                mount_path = "/backup"
                name       = "backup"
              }
            }

            volume {
              name = "backup"
              nfs {
                path   = "/mnt/main/etcd-backup"
                server = "10.0.10.15"
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
