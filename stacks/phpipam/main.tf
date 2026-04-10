variable "tls_secret_name" {
  type      = string
  sensitive = true
}
variable "mysql_host" { type = string }

resource "kubernetes_namespace" "phpipam" {
  metadata {
    name = "phpipam"
    labels = {
      tier = local.tiers.aux
    }
  }
}

resource "kubernetes_manifest" "external_secret" {
  manifest = {
    apiVersion = "external-secrets.io/v1beta1"
    kind       = "ExternalSecret"
    metadata = {
      name      = "phpipam-secrets"
      namespace = "phpipam"
    }
    spec = {
      refreshInterval = "15m"
      secretStoreRef = {
        name = "vault-database"
        kind = "ClusterSecretStore"
      }
      target = {
        name = "phpipam-secrets"
      }
      data = [{
        secretKey = "db_password"
        remoteRef = {
          key      = "static-creds/mysql-phpipam"
          property = "password"
        }
      }]
    }
  }
  depends_on = [kubernetes_namespace.phpipam]
}

module "tls_secret" {
  source          = "../../modules/kubernetes/setup_tls_secret"
  namespace       = kubernetes_namespace.phpipam.metadata[0].name
  tls_secret_name = var.tls_secret_name
}

resource "kubernetes_deployment" "phpipam_web" {
  metadata {
    name      = "phpipam-web"
    namespace = kubernetes_namespace.phpipam.metadata[0].name
    labels = {
      app  = "phpipam"
      tier = local.tiers.aux
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
        app = "phpipam"
      }
    }
    template {
      metadata {
        labels = {
          app = "phpipam"
        }
        annotations = {
          "diun.enable"                    = "true"
          "dependency.kyverno.io/wait-for" = "mysql.dbaas:3306"
        }
      }
      spec {
        container {
          image = "phpipam/phpipam-www:v1.7.0"
          name  = "phpipam-web"
          port {
            container_port = 80
          }
          env {
            name  = "TZ"
            value = "Europe/Sofia"
          }
          env {
            name  = "IPAM_DATABASE_HOST"
            value = var.mysql_host
          }
          env {
            name  = "IPAM_DATABASE_USER"
            value = "phpipam"
          }
          env {
            name = "IPAM_DATABASE_PASS"
            value_from {
              secret_key_ref {
                name = "phpipam-secrets"
                key  = "db_password"
              }
            }
          }
          env {
            name  = "IPAM_DATABASE_NAME"
            value = "phpipam"
          }
          env {
            name  = "IPAM_TRUST_X_FORWARDED"
            value = "true"
          }
          resources {
            requests = {
              cpu    = "10m"
              memory = "64Mi"
            }
            limits = {
              memory = "256Mi"
            }
          }
        }
      }
    }
  }
  lifecycle {
    ignore_changes = [spec[0].template[0].spec[0].dns_config]
  }
}

resource "kubernetes_deployment" "phpipam_cron" {
  metadata {
    name      = "phpipam-cron"
    namespace = kubernetes_namespace.phpipam.metadata[0].name
    labels = {
      app       = "phpipam-cron"
      component = "scanner"
      tier      = local.tiers.aux
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
        app = "phpipam-cron"
      }
    }
    template {
      metadata {
        labels = {
          app       = "phpipam-cron"
          component = "scanner"
        }
        annotations = {
          "dependency.kyverno.io/wait-for" = "mysql.dbaas:3306"
        }
      }
      spec {
        container {
          image = "phpipam/phpipam-cron:v1.7.0"
          name  = "phpipam-cron"
          env {
            name  = "TZ"
            value = "Europe/Sofia"
          }
          env {
            name  = "IPAM_DATABASE_HOST"
            value = var.mysql_host
          }
          env {
            name  = "IPAM_DATABASE_USER"
            value = "phpipam"
          }
          env {
            name = "IPAM_DATABASE_PASS"
            value_from {
              secret_key_ref {
                name = "phpipam-secrets"
                key  = "db_password"
              }
            }
          }
          env {
            name  = "IPAM_DATABASE_NAME"
            value = "phpipam"
          }
          env {
            name  = "SCAN_INTERVAL"
            value = "15m"
          }
          resources {
            requests = {
              cpu    = "10m"
              memory = "64Mi"
            }
            limits = {
              memory = "512Mi"
            }
          }
          security_context {
            capabilities {
              add = ["NET_RAW"]
            }
          }
        }
      }
    }
  }
  lifecycle {
    ignore_changes = [spec[0].template[0].spec[0].dns_config]
  }
}

resource "kubernetes_service" "phpipam" {
  metadata {
    name      = "phpipam"
    namespace = kubernetes_namespace.phpipam.metadata[0].name
    labels = {
      app = "phpipam"
    }
  }
  spec {
    selector = {
      app = "phpipam"
    }
    port {
      name        = "http"
      port        = 80
      target_port = 80
    }
  }
}

module "ingress" {
  source          = "../../modules/kubernetes/ingress_factory"
  namespace       = kubernetes_namespace.phpipam.metadata[0].name
  name            = "phpipam"
  tls_secret_name = var.tls_secret_name
  protected       = true
  extra_annotations = {
    "gethomepage.dev/enabled"      = "true"
    "gethomepage.dev/name"         = "phpIPAM"
    "gethomepage.dev/description"  = "IP Address Management"
    "gethomepage.dev/icon"         = "phpipam.png"
    "gethomepage.dev/group"        = "Infrastructure"
    "gethomepage.dev/pod-selector" = ""
  }
}
