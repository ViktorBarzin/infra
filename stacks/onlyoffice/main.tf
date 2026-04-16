variable "tls_secret_name" {
  type      = string
  sensitive = true
}
variable "nfs_server" { type = string }
variable "redis_host" { type = string }
variable "mysql_host" { type = string }

resource "kubernetes_namespace" "onlyoffice" {
  metadata {
    name = "onlyoffice"
    labels = {
      "istio-injection" : "disabled"
      tier                                    = local.tiers.edge
      "resource-governance/custom-limitrange" = "true"
      "resource-governance/custom-quota"      = "true"
    }
  }
}

resource "kubernetes_manifest" "external_secret" {
  manifest = {
    apiVersion = "external-secrets.io/v1beta1"
    kind       = "ExternalSecret"
    metadata = {
      name      = "onlyoffice-secrets"
      namespace = "onlyoffice"
    }
    spec = {
      refreshInterval = "15m"
      secretStoreRef = {
        name = "vault-kv"
        kind = "ClusterSecretStore"
      }
      target = {
        name = "onlyoffice-secrets"
      }
      dataFrom = [{
        extract = {
          key = "onlyoffice"
        }
      }]
    }
  }
  depends_on = [kubernetes_namespace.onlyoffice]
}

resource "kubernetes_limit_range" "onlyoffice" {
  metadata {
    name      = "onlyoffice-limits"
    namespace = kubernetes_namespace.onlyoffice.metadata[0].name
  }
  spec {
    limit {
      type = "Container"
      default = {
        memory = "256Mi"
      }
      default_request = {
        cpu    = "25m"
        memory = "64Mi"
      }
      max = {
        memory = "8Gi"
      }
    }
  }
}

resource "kubernetes_resource_quota" "onlyoffice" {
  metadata {
    name      = "onlyoffice-quota"
    namespace = kubernetes_namespace.onlyoffice.metadata[0].name
  }
  spec {
    hard = {
      "requests.cpu"    = "4"
      "requests.memory" = "4Gi"
      "limits.memory"   = "16Gi"
      pods              = "10"
    }
  }
}

module "tls_secret" {
  source          = "../../modules/kubernetes/setup_tls_secret"
  namespace       = kubernetes_namespace.onlyoffice.metadata[0].name
  tls_secret_name = var.tls_secret_name
}

resource "kubernetes_persistent_volume_claim" "data_proxmox" {
  wait_until_bound = false
  metadata {
    name      = "onlyoffice-data-proxmox"
    namespace = kubernetes_namespace.onlyoffice.metadata[0].name
    annotations = {
      "resize.topolvm.io/threshold"     = "80%"
      "resize.topolvm.io/increase"      = "100%"
      "resize.topolvm.io/storage_limit" = "5Gi"
    }
  }
  spec {
    access_modes       = ["ReadWriteOnce"]
    storage_class_name = "proxmox-lvm"
    resources {
      requests = {
        storage = "1Gi"
      }
    }
  }
}

resource "kubernetes_deployment" "onlyoffice-document-server" {
  metadata {
    name      = "onlyoffice-document-server"
    namespace = kubernetes_namespace.onlyoffice.metadata[0].name
    labels = {
      app  = "onlyoffice-document-server"
      tier = local.tiers.edge
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
        app = "onlyoffice-document-server"
      }
    }
    template {
      metadata {
        labels = {
          app = "onlyoffice-document-server"
        }
        annotations = {
          "dependency.kyverno.io/wait-for" = "mysql.dbaas:3306,redis.redis:6379"
        }
      }
      spec {
        container {
          name  = "onlyoffice-document-server"
          image = "onlyoffice/documentserver:9.3.1"
          resources {
            requests = {
              cpu    = "100m"
              memory = "1536Mi"
            }
            limits = {
              memory = "1536Mi"
            }
          }
          port {
            name           = "http"
            container_port = 80
            protocol       = "TCP"
          }
          env {
            name  = "DB_TYPE"
            value = "mariadb"
          }
          env {
            name  = "DB_HOST"
            value = var.mysql_host
          }
          env {
            name  = "DB_PORT"
            value = 3306
          }
          env {
            name  = "DB_NAME"
            value = "onlyoffice"
          }
          env {
            name  = "DB_USER"
            value = "onlyoffice"
          }
          env {
            name = "DB_PWD"
            value_from {
              secret_key_ref {
                name = "onlyoffice-secrets"
                key  = "db_password"
              }
            }
          }
          env {
            name  = "REDIS_SERVER_HOST"
            value = var.redis_host
          }
          env {
            name  = "REDIS_SERVER_PORT"
            value = 6379
          }
          env {
            name = "JWT_SECRET"
            value_from {
              secret_key_ref {
                name = "onlyoffice-secrets"
                key  = "jwt_token"
              }
            }
          }

          volume_mount {
            name       = "data"
            mount_path = "/var/www/onlyoffice/Data"
          }
        }
        volume {
          name = "data"
          persistent_volume_claim {
            claim_name = kubernetes_persistent_volume_claim.data_proxmox.metadata[0].name
          }
        }
      }
    }
  }
}

resource "kubernetes_service" "onlyoffice" {
  metadata {
    name      = "onlyoffice-document-server"
    namespace = kubernetes_namespace.onlyoffice.metadata[0].name
    labels = {
      "app" = "onlyoffice-document-server"
    }
  }

  spec {
    selector = {
      app = "onlyoffice-document-server"
    }
    port {
      port = "80"
    }
  }
}
module "ingress" {
  source          = "../../modules/kubernetes/ingress_factory"
  dns_type        = "proxied"
  namespace       = kubernetes_namespace.onlyoffice.metadata[0].name
  name            = "onlyoffice"
  service_name    = "onlyoffice-document-server"
  tls_secret_name = var.tls_secret_name
  extra_annotations = {
    "gethomepage.dev/enabled"      = "true"
    "gethomepage.dev/name"         = "OnlyOffice"
    "gethomepage.dev/description"  = "Document editor"
    "gethomepage.dev/icon"         = "onlyoffice.png"
    "gethomepage.dev/group"        = "Other"
    "gethomepage.dev/pod-selector" = ""
  }
}
