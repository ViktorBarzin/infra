# DB as a service. Installs MySQL operator
variable "tls_secret_name" {}
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

resource "kubernetes_namespace" "dbaas" {
  metadata {
    name = "dbaas"
  }
}

module "tls_secret" {
  source          = "../setup_tls_secret"
  namespace       = kubernetes_namespace.dbaas.metadata[0].name
  tls_secret_name = var.tls_secret_name
}


resource "kubernetes_config_map" "mycnf" {
  metadata {
    name      = "mycnf"
    namespace = kubernetes_namespace.dbaas.metadata[0].name

    annotations = {
      "reloader.stakater.com/match" = "true"
    }
  }

  data = {
    "my.cnf" = <<-EOT
    # For advice on how to change settings please see
    # http://dev.mysql.com/doc/refman/8.2/en/server-configuration-defaults.html

    [mysqld]
    #
    # Remove leading # and set to the amount of RAM for the most important data
    # cache in MySQL. Start at 70% of total RAM for dedicated server, else 10%.
    # innodb_buffer_pool_size = 128M
    #
    # Remove leading # to turn on a very important data integrity option: logging
    # changes to the binary log between backups.
    # log_bin
    #
    # Remove leading # to set options mainly useful for reporting servers.
    # The server defaults are faster for transactions and fast SELECTs.
    # Adjust sizes as needed, experiment to find the optimal values.
    # join_buffer_size = 128M
    # sort_buffer_size = 2M
    # read_rnd_buffer_size = 2M

    # Remove leading # to revert to previous value for default_authentication_plugin,
    # this will increase compatibility with older clients. For background, see:
    # https://dev.mysql.com/doc/refman/8.2/en/server-system-variables.html#sysvar_default_authentication_plugin
    # default-authentication-plugin=mysql_native_password
    #skip-host-cache
    skip-name-resolve
    datadir=/var/lib/mysql
    socket=/var/run/mysqld/mysqld.sock
    secure-file-priv=/var/lib/mysql-files
    user=mysql
    #innodb_force_recovery = 6
    #log_error_verbosity = 6 

    pid-file=/var/run/mysqld/mysqld.pid
    [client]
    socket=/var/run/mysqld/mysqld.sock

    !includedir /etc/mysql/conf.d/
    EOT
  }
}
resource "kubernetes_service" "mysql" {
  metadata {
    name      = var.cluster_master_service
    namespace = kubernetes_namespace.dbaas.metadata[0].name
  }
  spec {
    selector = {
      app = "mysql"
    }
    port {
      port = 3306
    }
  }
}

resource "kubernetes_deployment" "mysql" {
  metadata {
    name      = "mysql"
    namespace = kubernetes_namespace.dbaas.metadata[0].name
    annotations = {
      "reloader.stakater.com/search" = "true"
    }
  }
  spec {
    replicas = 1
    selector {
      match_labels = {
        app = "mysql"
      }
    }
    strategy {
      type = "Recreate"
    }
    template {
      metadata {
        labels = {
          app = "mysql"
        }
        annotations = {
          "diun.enable"       = "false"
          "diun.include_tags" = "^\\d+(?:\\.\\d+)?(?:\\.\\d+)?$"
        }
      }
      spec {
        container {
          image = "mysql:9.2.0"
          name  = "mysql"
          env {
            name  = "MYSQL_ROOT_PASSWORD"
            value = var.dbaas_root_password
          }
          port {
            container_port = 3306
            name           = "mysql"
          }
          volume_mount {
            name       = "mysql-persistent-storage"
            mount_path = "/var/lib/mysql"
          }
          volume_mount {
            name       = "mycnf"
            mount_path = "/etc/my.cnf"
            sub_path   = "my.cnf"
          }
        }
        volume {
          name = "mysql-persistent-storage"
          nfs {
            path   = "/mnt/main/mysql"
            server = "10.0.10.15"
          }
        }

        volume {
          name = "mycnf"

          config_map {
            name = "mycnf"
          }

        }
      }
    }
  }
}

resource "kubernetes_cron_job_v1" "mysql-backup" {
  metadata {
    name      = "mysql-backup"
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
              name  = "mysql-backup"
              image = "mysql"
              # TODO: would be nice to rotate at some point... Current size is 11MB so not really needed atm
              command = ["/bin/bash", "-c", <<-EOT
                set -euxo pipefail
                export now=$(date +"%Y_%m_%d_%H_%M")
                mysqldump --all-databases -u root -p${var.dbaas_root_password} --host mysql.dbaas.svc.cluster.local > /backup/dump_$now.sql

                # Rotate - delete last log file
                cd /backup
                find . -name "dump_*.sql" -type f -mtime +14 -delete # 14 day retention of backups
                echo Done
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
              nfs {
                path   = "/mnt/main/mysql-backup"
                server = "10.0.10.15"
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
  source          = "../ingress_factory"
  namespace       = kubernetes_namespace.dbaas.metadata[0].name
  name            = "pma"
  tls_secret_name = var.tls_secret_name
  protected       = true
  extra_annotations = {
    "nginx.ingress.kubernetes.io/proxy-body-size" : "500m"
  }
  rybbit_site_id                   = "942c76b8bd4d"
  additional_configuration_snippet = <<-EOF
    more_set_headers "Content-Security-Policy: script-src 'self' 'unsafe-inline' 'unsafe-eval' 'wasm-unsafe-eval' https://rybbit.viktorbarzin.me";
  EOF
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

resource "kubernetes_deployment" "postgres" {
  metadata {
    name      = "postgresql"
    namespace = kubernetes_namespace.dbaas.metadata[0].name
    annotations = {
      "reloader.stakater.com/search" = "true"
    }
  }
  spec {
    selector {
      match_labels = {
        app = "postgresql"
      }
    }
    strategy {
      type = "Recreate"
    }
    template {
      metadata {
        labels = {
          app = "postgresql"
        }
        annotations = {
          "diun.enable"       = "false"
          "diun.include_tags" = "^\\d+(?:\\.\\d+)?-bullseye$"
        }
      }
      spec {
        container {
          # image = "postgis/postgis:16-master"
          image = "viktorbarzin/postgres:16-master" # mix of postgis + pgvector
          # image = "postgres:17.2-bullseye" # needs pg_upgrade to data dir
          name = "postgresql"
          env {
            name  = "POSTGRES_PASSWORD"
            value = var.postgresql_root_password
          }
          env {
            name  = "POSTGRES_USER"
            value = "root"
          }
          port {
            container_port = 5432
            protocol       = "TCP"
            name           = "postgresql"
          }
          volume_mount {
            name       = "postgresql-persistent-storage"
            mount_path = "/var/lib/postgresql/data"
          }
          # volume_mount {
          #   name       = "mycnf"
          #   mount_path = "/etc/my.cnf"
          #   sub_path   = "my.cnf"
          # }
        }
        volume {
          name = "postgresql-persistent-storage"
          nfs {
            path   = "/mnt/main/postgresql/data"
            server = "10.0.10.15"
          }
        }
        # volume {
        #   name = "mycnf"

        #   config_map {
        #     name = "mycnf"
        #   }
        # }
      }
    }
  }
}
resource "kubernetes_service" "postgresql" {
  metadata {
    name      = "postgresql"
    namespace = kubernetes_namespace.dbaas.metadata[0].name
  }
  spec {
    selector = {
      "app" = "postgresql"
    }
    port {
      name        = "postgresql"
      port        = 5432
      target_port = 5432
    }
  }
}

#### PGADMIN

resource "kubernetes_deployment" "pgadmin" {
  metadata {
    name      = "pgadmin"
    namespace = kubernetes_namespace.dbaas.metadata[0].name
    annotations = {
      "reloader.stakater.com/search" = "true"
    }
  }
  spec {
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

        }
        volume {
          name = "pgadmin"
          # config_map {
          #   name = "pgadmin-config"
          # }
          nfs {
            path   = "/mnt/main/postgresql/pgadmin"
            server = "10.0.10.15"
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
  source          = "../ingress_factory"
  namespace       = kubernetes_namespace.dbaas.metadata[0].name
  name            = "pgadmin"
  tls_secret_name = var.tls_secret_name
  protected       = true
  extra_annotations = {
    "nginx.ingress.kubernetes.io/proxy-body-size" : "50m"
  }
  rybbit_site_id = "7cef78e30485"
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
              image = "postgres:16.4-bullseye"
              command = ["/bin/bash", "-c", <<-EOT
                set -euxo pipefail
                export now=$(date +"%Y_%m_%d_%H_%M")
                PGPASSWORD=${var.postgresql_root_password} pg_dumpall  -h postgresql.dbaas -U root > /backup/dump_$now.sql

                # Rotate - delete last log file
                cd /backup
                find . -name "dump_*.sql" -type f -mtime +7 -delete # 7 day retention of backups
                echo Done
              EOT
              ]
              volume_mount {
                name       = "postgresql-backup"
                mount_path = "/backup"
              }
            }
            volume {
              name = "postgresql-backup"
              nfs {
                path   = "/mnt/main/postgresql-backup"
                server = "10.0.10.15"
              }
            }
          }
        }
      }
    }
  }
}
