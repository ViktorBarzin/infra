# DB as a service. Installs MySQL operator
variable "tls_secret_name" {}

resource "kubernetes_namespace" "dbaas" {
  metadata {
    name = "dbaas"
  }
}

module "tls_secret" {
  source          = "../setup_tls_secret"
  namespace       = "dbaas"
  tls_secret_name = var.tls_secret_name
}

resource "helm_release" "mysql" {
  namespace        = "dbaas"
  create_namespace = false
  name             = "mysql"

  repository = "https://presslabs.github.io/charts"
  chart      = "mysql-operator"

  values = [templatefile("${path.module}/mysql_chart_values.yaml", { secretName = var.tls_secret_name })]

}

resource "kubernetes_persistent_volume" "mysql-operator" {
  metadata {
    name = "mysql-operator-pv"
  }
  spec {
    capacity = {
      "storage" = "1Gi"
    }
    access_modes = ["ReadWriteOnce"]
    persistent_volume_source {
      iscsi {
        target_portal = "iscsi.viktorbarzin.lan:3260"
        iqn           = "iqn.2020-12.lan.viktorbarzin:storage:dbaas:operator"
        lun           = 0
        fs_type       = "ext4"
      }
    }
  }
}

resource "kubernetes_persistent_volume" "mysql" {
  metadata {
    name = "mysql-pv"
  }
  spec {
    capacity = {
      "storage" = "10Gi"
    }
    access_modes = ["ReadWriteOnce"]
    persistent_volume_source {
      iscsi {
        target_portal = "iscsi.viktorbarzin.lan:3260"
        iqn           = "iqn.2020-12.lan.viktorbarzin:storage:dbaas:mysql"
        lun           = 0
        fs_type       = "ext4"
      }
    }
  }
}

resource "kubernetes_secret" "cluster-password" {
  metadata {
    name      = "cluster-secret"
    namespace = "dbaas"
  }
  type = "Opaque"
  data = {
    "ROOT_PASSWORD" = "kek"
  }
}
# resource "kubernetes_manifest" "mysql-cluster" {
#   manifest = {
#     apiVersion = "mysql.presslabs.org/v1alpha1"
#     kind       = "MysqlCluster"
#     metadata = {
#       name      = "mysql-cluster"
#       namespace = "dbaas"
#     }
#     spec = {
#       mysqlVersion = "5.7"
#       replicas     = 1
#       secretName   = "cluster-secret"
#       mysqlConf = {
#         read_only = 0
#       }
#       volumeSpec = {
#         persistentVolumeClaim = {
#           resources = {
#             requests = {
#               storage = "10Gi"
#             }
#           }
#         }
#       }
#     }
#   }
# }

# resource "kubectl_manifest" "mysql-cluster" {
#   yaml_body = <<-YAML
#     apiVersion: mysql.presslabs.org/v1alpha1
#     kind: MysqlCluster
#     metadata:
#     name: MyCluster
#     spec:
#     mysqlVersion: "5.7"
#     replicas: 1
#     secretName: MyCluster-Secret
#     mysqlConf:
#         read_only: 0                          # mysql forms a single transaction for each sql statement, autocommit for each statement
#         automatic_sp_privileges: "ON"         # automatically grants the EXECUTE and ALTER ROUTINE privileges to the creator of a stored routine
#         auto_generate_certs: "ON"             # Auto Generation of Certificate
#         auto_increment_increment: 1           # Auto Incrementing value from +1
#         auto_increment_offset: 1              # Auto Increment Offset
#         binlog-format: "STATEMENT"            # contains various options such ROW(SLOW,SAFE) STATEMENT(FAST,UNSAFE), MIXED(combination of both)
#         wait_timeout: 31536000                # 28800 number of seconds the server waits for activity on a non-interactive connection before closing it, You might encounter MySQL server has gone away error, you then tweak this value acccordingly
#         interactive_timeout: 28800            # The number of seconds the server waits for activity on an interactive connection before closing it.
#         max_allowed_packet: "512M"            # Maximum size of MYSQL Network protocol packet that the server can create or read 4MB, 8MB, 16MB, 32MB
#         max-binlog-size: 1073741824           # binary logs contains the events that describe database changes, this parameter describe size for the bin_log file.
#         log_output: "TABLE"                   # Format in which the logout will be dumped
#         master-info-repository: "TABLE"       # Format in which the master info will be dumped
#         relay_log_info_repository: "TABLE"    # Format in which the relay info will be dumped
#     volumeSpec:
#         persistentVolumeClaim:
#         accessModes:
#         - ReadWriteMany
#         resources:
#             requests:
#             storage: 10Gi
#     YAML
# }