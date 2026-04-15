variable "tls_secret_name" {
  type = string
}
variable "nfs_server" { type = string }
variable "mysql_host" { type = string }

resource "kubernetes_namespace" "hackmd" {
  metadata {
    name = "hackmd"
    labels = {
      "istio-injection" : "disabled"
      tier = local.tiers.edge
    }
  }
}

module "tls_secret" {
  source          = "../../modules/kubernetes/setup_tls_secret"
  namespace       = kubernetes_namespace.hackmd.metadata[0].name
  tls_secret_name = var.tls_secret_name
}

resource "kubernetes_persistent_volume_claim" "data_encrypted" {
  wait_until_bound = false
  metadata {
    name      = "hackmd-data-encrypted"
    namespace = kubernetes_namespace.hackmd.metadata[0].name
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

resource "kubernetes_deployment" "hackmd" {
  metadata {
    name      = "hackmd"
    namespace = kubernetes_namespace.hackmd.metadata[0].name
    labels = {
      app                             = "hackmd"
      "kubernetes.io/cluster-service" = "true"
      tier                            = local.tiers.edge
    }
    annotations = {
      "reloader.stakater.com/auto" = "true"
    }
  }
  spec {
    replicas = 1
    strategy {
      type = "Recreate"
    }
    selector {
      match_labels = {
        app = "hackmd"
      }
    }
    template {
      metadata {
        labels = {
          app                             = "hackmd"
          "kubernetes.io/cluster-service" = "true"
        }
        annotations = {
          "dependency.kyverno.io/wait-for" = "mysql.dbaas:3306"
        }
      }
      spec {
        # container {
        #   image             = "postgres:11.6-alpine"
        #   name              = "postgres"
        #   image_pull_policy = "IfNotPresent"
        #   env {
        #     name  = "POSTGRES_USER"
        #     value = "codimd"
        #   }
        #   env {
        #     name  = "POSTGRES_PASSWORD"
        #     value = var.hackmd_db_password
        #   }
        #   env {
        #     name  = "POSTGRES_DB"
        #     value = "codimd"
        #   }
        #   resources {
        #     limits = {
        #       cpu    = "1"
        #       memory = "1Gi"
        #     }
        #     requests = {
        #       cpu    = "1"
        #       memory = "1Gi"
        #     }
        #   }
        #   port {
        #     container_port = 80
        #   }
        # volume_mount {
        #   name       = "data"
        #   mount_path = "/var/lib/postgresql/data"
        #   sub_path   = "postgres"
        # }
        # }

        container {
          name  = "codimd"
          image = "hackmdio/hackmd"
          env {
            name = "CMD_DB_URL"
            value_from {
              secret_key_ref {
                name = "hackmd-secrets"
                key  = "CMD_DB_URL"
              }
            }
          }
          env {
            name  = "CMD_USECDN"
            value = "false"
          }
          volume_mount {
            name       = "data"
            mount_path = "/home/hackmd/app/public/uploads"
            sub_path   = "hackmd"
          }
          port {
            name           = "http"
            container_port = 3000
            protocol       = "TCP"
          }
          resources {
            requests = {
              cpu    = "15m"
              memory = "256Mi"
            }
            limits = {
              memory = "256Mi"
            }
          }
        }
        security_context {
          fs_group = "1500"
        }
        volume {
          name = "data"
          persistent_volume_claim {
            claim_name = kubernetes_persistent_volume_claim.data_encrypted.metadata[0].name
          }
        }
      }
    }
  }
}

resource "kubernetes_service" "hackmd" {
  metadata {
    name      = "hackmd"
    namespace = kubernetes_namespace.hackmd.metadata[0].name
    labels = {
      "app" = "hackmd"
    }
  }

  spec {
    selector = {
      app = "hackmd"
    }
    port {
      port        = "80"
      target_port = "3000"
    }
  }
}
module "ingress" {
  source          = "../../modules/kubernetes/ingress_factory"
  namespace       = kubernetes_namespace.hackmd.metadata[0].name
  name            = "hackmd"
  tls_secret_name = var.tls_secret_name
  extra_annotations = {
    "gethomepage.dev/enabled"      = "true"
    "gethomepage.dev/name"         = "HackMD"
    "gethomepage.dev/description"  = "Collaborative markdown"
    "gethomepage.dev/icon"         = "hedgedoc.png"
    "gethomepage.dev/group"        = "Development & CI"
    "gethomepage.dev/pod-selector" = ""
  }
}

resource "kubernetes_manifest" "external_secret" {
  manifest = {
    apiVersion = "external-secrets.io/v1beta1"
    kind       = "ExternalSecret"
    metadata = {
      name      = "hackmd-secrets"
      namespace = "hackmd"
    }
    spec = {
      refreshInterval = "15m"
      secretStoreRef = {
        name = "vault-database"
        kind = "ClusterSecretStore"
      }
      target = {
        name = "hackmd-secrets"
        template = {
          data = {
            CMD_DB_URL = "mysql://codimd:{{ .db_password }}@mysql.dbaas.svc.cluster.local/codimd"
          }
        }
      }
      data = [{
        secretKey = "db_password"
        remoteRef = {
          key      = "static-creds/mysql-codimd"
          property = "password"
        }
      }]
    }
  }
  depends_on = [kubernetes_namespace.hackmd]
}
