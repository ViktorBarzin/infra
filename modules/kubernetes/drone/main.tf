variable "tls_secret_name" {}
variable "tls_crt" {}
variable "tls_key" {}
variable "github_client_id" {}
variable "github_client_secret" {}
variable "rpc_secret" {}
variable "server_host" {}
variable "server_proto" {}
variable "rpc_host" {
  default = "drone.drone.svc.cluster.local"
}
variable "allowed_users" {
  # comma separated list
  default = "viktorbarzin"
}

resource "kubernetes_namespace" "drone" {
  metadata {
    name = "drone"
  }
}

module "tls_secret" {
  source          = "../setup_tls_secret"
  namespace       = "drone"
  tls_secret_name = var.tls_secret_name
  tls_crt         = var.tls_crt
  tls_key         = var.tls_key
}

resource "kubernetes_config_map" "git_crypt_key" {
  metadata {
    name      = "git-crypt-key"
    namespace = "drone"
  }

  data = {
    "key" = filebase64("${path.root}/.git/git-crypt/keys/default")
  }
}

resource "kubernetes_deployment" "drone_server" {
  metadata {
    name      = "drone-server"
    namespace = "drone"
    labels = {
      app = "drone"
    }
  }
  spec {
    strategy {
      type = "Recreate"
    }
    replicas = 1
    selector {
      match_labels = {
        app = "drone"
      }
    }
    template {
      metadata {
        labels = {
          app = "drone"
        }
      }
      spec {
        container {
          image = "drone/drone:1"
          name  = "drone-server"
          resources {
            limits = {
              cpu    = "1"
              memory = "1Gi"
            }
            requests = {
              cpu    = "500m"
              memory = "1Gi"
            }
          }
          port {
            container_port = 80
          }
          volume_mount {
            name       = "data"
            mount_path = "/data"
          }

          env {
            name  = "DRONE_GITHUB_CLIENT_ID"
            value = var.github_client_id
          }
          env {
            name  = "DRONE_GITHUB_CLIENT_SECRET"
            value = var.github_client_secret
          }
          env {
            name  = "DRONE_RPC_SECRET"
            value = var.rpc_secret
          }
          env {
            name  = "DRONE_SERVER_HOST"
            value = var.server_host
          }
          env {
            name  = "DRONE_SERVER_PROTO"
            value = var.server_proto
          }
          env {
            name  = "DRONE_USER_FILTER"
            value = var.allowed_users
          }

        }
        volume {
          name = "data"
          iscsi {
            target_portal = "iscsi.viktorbarzin.lan:3260"
            fs_type       = "ext4"
            iqn           = "iqn.2020-12.lan.viktorbarzin:storage:drone"
            lun           = 0
            read_only     = false
          }
        }
      }
    }
  }
}

resource "kubernetes_service" "drone" {
  metadata {
    name      = "drone"
    namespace = "drone"
    labels = {
      app = "drone"
    }
  }

  spec {
    selector = {
      app = "drone"
    }
    port {
      name = "http"
      port = "80"
    }
  }
}

resource "kubernetes_ingress" "drone" {
  metadata {
    name      = "drone-ingress"
    namespace = "drone"
    annotations = {
      "kubernetes.io/ingress.class" = "nginx"
      //"nginx.ingress.kubernetes.io/auth-tls-verify-client" = "on"
      //"nginx.ingress.kubernetes.io/auth-tls-secret"        = "default/ca-secret"
    }
  }

  spec {
    tls {
      hosts       = ["drone.viktorbarzin.me"]
      secret_name = var.tls_secret_name
    }
    rule {
      host = "drone.viktorbarzin.me"
      http {
        path {
          path = "/"
          backend {
            service_name = "drone"
            service_port = "80"
          }
        }
      }
    }
  }
}

# Setup drone runner
resource "kubernetes_cluster_role" "drone" {
  metadata {
    name = "drone"
  }
  rule {
    api_groups = [""]
    resources  = ["configmaps"]
    verbs      = ["get", "list", "update", "patch"]
  }
  rule {
    api_groups = [""]
    resources  = ["secrets"]
    verbs      = ["get", "list", "create", "delete"]
  }
  rule {
    api_groups = [""]
    resources  = ["pods", "pods/log"]
    verbs      = ["get", "create", "delete", "list", "watch", "update"]
  }
  rule {
    api_groups = ["apps"]
    resources  = ["deployments"]
    verbs      = ["get", "create", "delete", "list", "watch", "update", "patch"]
  }
}

resource "kubernetes_cluster_role_binding" "drone" {
  metadata {
    name = "drone"
  }
  subject {
    kind      = "ServiceAccount"
    name      = "default"
    namespace = "drone"
  }
  role_ref {
    kind = "ClusterRole"
    # name      = "drone"
    name      = "cluster-admin"
    api_group = "rbac.authorization.k8s.io"
  }
}

resource "kubernetes_deployment" "drone_runner" {
  metadata {
    name      = "drone-runner"
    namespace = "drone"
    labels = {
      app = "drone-runner"
    }
  }
  spec {
    strategy {
      type = "Recreate"
    }
    replicas = 1
    selector {
      match_labels = {
        app = "drone-runner"
      }
    }
    template {
      metadata {
        labels = {
          app = "drone-runner"
        }
      }
      spec {
        container {
          image = "drone/drone-runner-kube:latest"
          name  = "drone-runner"
          resources {
            limits = {
              cpu    = "1"
              memory = "1Gi"
            }
            requests = {
              cpu    = "500m"
              memory = "1Gi"
            }
          }
          env {
            name  = "DRONE_RPC_HOST"
            value = var.rpc_host
          }
          env {
            name  = "DRONE_RPC_PROTO"
            value = "http"
          }
          env {
            name  = "DRONE_RPC_SECRET"
            value = var.rpc_secret
          }
          env {
            name  = "DRONE_NAMESPACE_DEFAULT"
            value = "drone"
          }
          env {
            name  = "SECRET_KEY"
            value = var.rpc_secret
          }
          env {
            name  = "DRONE_SECRET_PLUGIN_ENDPOINT"
            value = "http://drone-runner-secret.drone.svc.cluster.local:3000"
          }
          env {
            name  = "DRONE_SECRET_PLUGIN_TOKEN"
            value = var.rpc_secret
          }
          env {
            name  = "DRONE_DEBUG"
            value = "true"
          }
        }
      }
    }
  }
}
resource "kubernetes_deployment" "drone_runner_secret" {
  metadata {
    name      = "drone-runner-secret"
    namespace = "drone"
    labels = {
      app = "drone-runner-secret"
    }
  }
  spec {
    strategy {
      type = "Recreate"
    }
    replicas = 1
    selector {
      match_labels = {
        app = "drone-runner-secret"
      }
    }
    template {
      metadata {
        labels = {
          app = "drone-runner-secret"
        }
      }
      spec {
        container {
          name  = "secret"
          image = "drone/kubernetes-secrets:latest"
          port {
            container_port = 3000
          }
          env {
            name  = "SECRET_KEY"
            value = var.rpc_secret
          }
          env {
            name  = "DEBUG"
            value = "true"
          }
          env {
            name  = "KUBERNETES_NAMESPACE"
            value = "drone"
          }
          // Custom variable to start terraform as prod
          env {
            name  = "TF_VAR_prod"
            value = true
          }
        }
      }
    }
  }
}


resource "kubernetes_service" "drone_runner_secret" {
  metadata {
    name      = "drone-runner-secret"
    namespace = "drone"
    labels = {
      app = "drone-runner-secret"
    }
  }

  spec {
    selector = {
      app = "drone-runner-secret"
    }
    port {
      name = "http"
      port = "3000"
    }
  }
}

# SQL to delete last N builds (n = 1000)
# PRAGMA foreign_keys = ON;

# WITH n_build_ids_per_repo as (
#   SELECT build_id
#   FROM (
#     SELECT
#       build_id,
#       build_repo_id,
#       DENSE_RANK() OVER (PARTITION BY build_repo_id ORDER BY build_id DESC) AS rank
#     FROM builds
#   ) AS t
#   WHERE t.rank <= 1000
# )
# DELETE FROM
#   builds 
# WHERE 
#   builds.build_id NOT IN (SELECT build_id FROM n_build_ids_per_repo);
