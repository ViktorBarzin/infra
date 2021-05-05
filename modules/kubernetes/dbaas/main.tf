# DB as a service. Installs MySQL operator
variable "tls_secret_name" {}
variable "dbaas_root_password" {}
variable "cluster_master_service" {
  default = "mysql-cluster-mysql-master"
}
variable "prod" {
  default = false
  type    = bool
}

provider "kubectl" {
  # config_path = var.prod ? "" : "~/.kube/config"
  host               = "kubernetes:6443"
  client_certificate = var.prod ? "/run/secrets/kubernetes.io/serviceaccount/ca.crt" : ""
  token              = var.prod ? "/run/secrets/kubernetes.io/serviceaccount/token" : ""
  insecure           = true
}
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
  atomic = true

  depends_on = [kubernetes_namespace.dbaas]
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
    annotations = {
      "reloader.stakater.com/match" = "true"
    }
  }
  type = "Opaque"
  data = {
    "ROOT_PASSWORD" = var.dbaas_root_password
  }
}

resource "kubernetes_ingress" "dbaas" {
  metadata {
    name      = "orchestrator-ingress"
    namespace = "dbaas"
    annotations = {
      "kubernetes.io/ingress.class"                        = "nginx"
      "nginx.ingress.kubernetes.io/auth-tls-verify-client" = "on"
      "nginx.ingress.kubernetes.io/auth-tls-secret"        = "default/ca-secret"
    }
  }

  spec {
    tls {
      hosts       = ["db.viktorbarzin.me"]
      secret_name = var.tls_secret_name
    }
    rule {
      host = "db.viktorbarzin.me"
      http {
        path {
          path = "/"
          backend {
            service_name = "mysql-mysql-operator"
            service_port = "80"
          }
        }
      }
    }
  }
}


# PHPMyAdmin instance
resource "kubernetes_deployment" "phpmyadmin" {
  metadata {
    name      = "phpmyadmin"
    namespace = "dbaas"
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
          image = "phpmyadmin/phpmyadmin"
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
        }
      }
    }
  }
}

resource "kubernetes_service" "phpmyadmin" {
  metadata {
    name      = "phpmyadmin"
    namespace = "dbaas"
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

resource "kubernetes_ingress" "phpmyadmin" {
  metadata {
    name      = "phpmyadmin-ingress"
    namespace = "dbaas"

    annotations = {
      "kubernetes.io/ingress.class"                        = "nginx"
      "nginx.ingress.kubernetes.io/auth-tls-verify-client" = "on"
      "nginx.ingress.kubernetes.io/auth-tls-secret"        = "default/ca-secret"
    }
  }
  spec {
    tls {
      hosts       = ["pma.viktorbarzin.me"]
      secret_name = var.tls_secret_name
    }
    rule {
      host = "pma.viktorbarzin.me"
      http {
        path {
          path = "/"
          backend {
            service_name = "phpmyadmin"
            service_port = "80"
          }
        }
      }
    }
  }

}


resource "kubectl_manifest" "mysql-cluster" {
  yaml_body  = <<-YAML
    apiVersion: mysql.presslabs.org/v1alpha1
    kind: MysqlCluster
    metadata:
      name: mysql-cluster
      namespace: dbaas
    spec:
      mysqlVersion: "5.7"
      replicas: 1
      secretName: cluster-secret
      mysqlConf:
        # read_only: 0                          # mysql forms a single transaction for each sql statement, autocommit for each statement
        # automatic_sp_privileges: "ON"         # automatically grants the EXECUTE and ALTER ROUTINE privileges to the creator of a stored routine
        # auto_generate_certs: "ON"             # Auto Generation of Certificate
        # auto_increment_increment: 1           # Auto Incrementing value from +1
        # auto_increment_offset: 1              # Auto Increment Offset
        # binlog-format: "STATEMENT"            # contains various options such ROW(SLOW,SAFE) STATEMENT(FAST,UNSAFE), MIXED(combination of both)
        # wait_timeout: 31536000                # 28800 number of seconds the server waits for activity on a non-interactive connection before closing it, You might encounter MySQL server has gone away error, you then tweak this value acccordingly
        # interactive_timeout: 28800            # The number of seconds the server waits for activity on an interactive connection before closing it.
        # max_allowed_packet: "512M"            # Maximum size of MYSQL Network protocol packet that the server can create or read 4MB, 8MB, 16MB, 32MB
        # max-binlog-size: 1073741824           # binary logs contains the events that describe database changes, this parameter describe size for the bin_log file.
        # log_output: "TABLE"                   # Format in which the logout will be dumped
        # master-info-repository: "TABLE"       # Format in which the master info will be dumped
        # relay_log_info_repository: "TABLE"    # Format in which the relay info will be dumped
      volumeSpec:
        persistentVolumeClaim:
          accessModes:
          - ReadWriteOnce
          resources:
            requests:
              storage: 10Gi
  YAML
  depends_on = [helm_release.mysql]
  # manifest = {
  #   apiVersion = "mysql.presslabs.org/v1alpha1"
  #   kind       = "MysqlCluster"
  #   metadata = {
  #     name      = "mysql-cluster"
  #     namespace = "dbaas"
  #   }
  #   spec = {
  #     mysqlVersion = "5.7"
  #     replicas     = 1
  #     secretName   = "cluster-secret"
  #     mysqlConf = {
  #       read_only = 0
  #     }
  #     volumeSpec = {
  #       persistentVolumeClaim = {
  #         resources = {
  #           requests = {
  #             storage = "10Gi"
  #           }
  #         }
  #       }
  #     }
  #   }
  # }
}


# For some unknwown reason not all CRDs are installed. Add them manually
resource "kubectl_manifest" "mysql-user" {
  yaml_body = <<-EOF
    apiVersion: apiextensions.k8s.io/v1
    kind: CustomResourceDefinition
    metadata:
      annotations:
        controller-gen.kubebuilder.io/version: v0.5.0
        helm.sh/hook: crd-install
      name: mysqlusers.mysql.presslabs.org
      labels:
        app: mysql-operator
    spec:
      group: mysql.presslabs.org
      names:
        kind: MysqlUser
        listKind: MysqlUserList
        plural: mysqlusers
        singular: mysqluser
      scope: Namespaced
      versions:
        - additionalPrinterColumns:
            - description: The user status
              jsonPath: .status.conditions[?(@.type == 'Ready')].status
              name: Ready
              type: string
            - jsonPath: .spec.clusterRef.name
              name: Cluster
              type: string
            - jsonPath: .spec.user
              name: UserName
              type: string
            - jsonPath: .metadata.creationTimestamp
              name: Age
              type: date
          name: v1alpha1
          schema:
            openAPIV3Schema:
              description: MysqlUser is the Schema for the MySQL User API
              properties:
                apiVersion:
                  description: 'APIVersion defines the versioned schema of this representation of an object. Servers should convert recognized schemas to the latest internal value, and may reject unrecognized values. More info: https://git.k8s.io/community/contributors/devel/sig-architecture/api-conventions.md#resources'
                  type: string
                kind:
                  description: 'Kind is a string value representing the REST resource this object represents. Servers may infer this from the endpoint the client submits requests to. Cannot be updated. In CamelCase. More info: https://git.k8s.io/community/contributors/devel/sig-architecture/api-conventions.md#types-kinds'
                  type: string
                metadata:
                  type: object
                spec:
                  description: MysqlUserSpec defines the desired state of MysqlUserSpec
                  properties:
                    allowedHosts:
                      description: AllowedHosts is the allowed host to connect from.
                      items:
                        type: string
                      type: array
                    clusterRef:
                      description: ClusterRef represents a reference to the MySQL cluster. This field should be immutable.
                      properties:
                        name:
                          description: 'Name of the referent. More info: https://kubernetes.io/docs/concepts/overview/working-with-objects/names/#names TODO: Add other useful fields. apiVersion, kind, uid?'
                          type: string
                        namespace:
                          description: Namespace the MySQL cluster namespace
                          type: string
                      type: object
                    password:
                      description: Password is the password for the user.
                      properties:
                        key:
                          description: The key of the secret to select from.  Must be a valid secret key.
                          type: string
                        name:
                          description: 'Name of the referent. More info: https://kubernetes.io/docs/concepts/overview/working-with-objects/names/#names TODO: Add other useful fields. apiVersion, kind, uid?'
                          type: string
                        optional:
                          description: Specify whether the Secret or its key must be defined
                          type: boolean
                      required:
                        - key
                      type: object
                    permissions:
                      description: Permissions is the list of roles that user has in the specified database.
                      items:
                        description: MysqlPermission defines a MySQL schema permission
                        properties:
                          permissions:
                            description: Permissions represents the permissions granted on the schema/tables
                            items:
                              type: string
                            type: array
                          schema:
                            description: Schema represents the schema to which the permission applies
                            type: string
                          tables:
                            description: Tables represents the tables inside the schema to which the permission applies
                            items:
                              type: string
                            type: array
                        required:
                          - permissions
                          - schema
                          - tables
                        type: object
                      type: array
                    resourceLimits:
                      additionalProperties:
                        anyOf:
                          - type: integer
                          - type: string
                        pattern: ^(\+|-)?(([0-9]+(\.[0-9]*)?)|(\.[0-9]+))(([KMGTPE]i)|[numkMGTPE]|([eE](\+|-)?(([0-9]+(\.[0-9]*)?)|(\.[0-9]+))))?$
                        x-kubernetes-int-or-string: true
                      description: 'ResourceLimits allow settings limit per mysql user as defined here: https://dev.mysql.com/doc/refman/5.7/en/user-resources.html'
                      type: object
                    user:
                      description: User is the name of the user that will be created with will access the specified database. This field should be immutable.
                      type: string
                  required:
                    - allowedHosts
                    - clusterRef
                    - password
                    - user
                  type: object
                status:
                  description: MysqlUserStatus defines the observed state of MysqlUser
                  properties:
                    allowedHosts:
                      description: AllowedHosts contains the list of hosts that the user is allowed to connect from.
                      items:
                        type: string
                      type: array
                    conditions:
                      description: Conditions represents the MysqlUser resource conditions list.
                      items:
                        description: MySQLUserCondition defines the condition struct for a MysqlUser resource
                        properties:
                          lastTransitionTime:
                            description: Last time the condition transitioned from one status to another.
                            format: date-time
                            type: string
                          lastUpdateTime:
                            description: The last time this condition was updated.
                            format: date-time
                            type: string
                          message:
                            description: A human readable message indicating details about the transition.
                            type: string
                          reason:
                            description: The reason for the condition's last transition.
                            type: string
                          status:
                            description: Status of the condition, one of True, False, Unknown.
                            type: string
                          type:
                            description: Type of MysqlUser condition.
                            type: string
                        required:
                          - lastTransitionTime
                          - message
                          - reason
                          - status
                          - type
                        type: object
                      type: array
                  type: object
              type: object
          served: true
          storage: true
          subresources:
            status: {}
  EOF
}
