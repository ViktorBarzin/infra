variable "tls_secret_name" {
  type      = string
  sensitive = true
}
variable "nfs_server" { type = string }


resource "kubernetes_namespace" "matrix" {
  metadata {
    name = "matrix"
    labels = {
      "istio-injection" : "disabled"
      tier = local.tiers.aux
    }
  }
}

# DB credentials from Vault database engine (rotated every 24h)
resource "kubernetes_manifest" "db_external_secret" {
  manifest = {
    apiVersion = "external-secrets.io/v1beta1"
    kind       = "ExternalSecret"
    metadata = {
      name      = "matrix-db-creds"
      namespace = "matrix"
    }
    spec = {
      refreshInterval = "15m"
      secretStoreRef = {
        name = "vault-database"
        kind = "ClusterSecretStore"
      }
      target = {
        name = "matrix-db-creds"
        template = {
          data = {
            DB_PASSWORD = "{{ .password }}"
          }
        }
      }
      data = [{
        secretKey = "password"
        remoteRef = {
          key      = "static-creds/pg-matrix"
          property = "password"
        }
      }]
    }
  }
  depends_on = [kubernetes_namespace.matrix]
}

module "tls_secret" {
  source          = "../../modules/kubernetes/setup_tls_secret"
  namespace       = kubernetes_namespace.matrix.metadata[0].name
  tls_secret_name = var.tls_secret_name
}

resource "kubernetes_persistent_volume_claim" "data_encrypted" {
  wait_until_bound = false
  metadata {
    name      = "matrix-data-encrypted"
    namespace = kubernetes_namespace.matrix.metadata[0].name
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

resource "kubernetes_deployment" "matrix" {
  metadata {
    name      = "matrix"
    namespace = kubernetes_namespace.matrix.metadata[0].name
    labels = {
      app  = "matrix"
      tier = local.tiers.aux
    }
  }
  spec {
    replicas = 1
    strategy {
      type = "Recreate"
    }
    selector {
      match_labels = {
        app = "matrix"
      }
    }
    template {
      metadata {
        labels = {
          app = "matrix"
        }
        annotations = {
          "diun.enable"                    = "true"
          "diun.include_tags"              = "^v\\d+\\.\\d+\\.\\d+$"
          "dependency.kyverno.io/wait-for" = "pg-cluster-rw.dbaas:5432"
        }
      }
      spec {
        init_container {
          name    = "install-psycopg2"
          image   = "matrixdotorg/synapse:v1.125.0"
          command = ["/bin/sh", "-c", "pip install --target=/extra-packages psycopg2-binary 2>/dev/null"]
          volume_mount {
            name       = "extra-packages"
            mount_path = "/extra-packages"
          }
        }
        init_container {
          name  = "inject-db-password"
          image = "busybox:1.37"
          command = ["/bin/sh", "-c", <<-EOF
            # Update database config in homeserver.yaml with current Vault-managed password
            sed -i "s|host: .*dbaas.*|host: pg-cluster-rw.dbaas.svc.cluster.local|" /data/homeserver.yaml
            sed -i "s|user: .*|user: matrix|" /data/homeserver.yaml
            sed -i "s|password: .*|password: $DB_PASSWORD|" /data/homeserver.yaml
            echo "DB password injected"
          EOF
          ]
          env {
            name = "DB_PASSWORD"
            value_from {
              secret_key_ref {
                name = "matrix-db-creds"
                key  = "DB_PASSWORD"
              }
            }
          }
          volume_mount {
            name       = "data"
            mount_path = "/data"
          }
        }
        container {
          image = "matrixdotorg/synapse:v1.125.0"
          name  = "matrix"
          port {
            container_port = 8008
          }
          env {
            name  = "SYNAPSE_SERVER_NAME"
            value = "matrix.viktorbarzin.me"
          }
          env {
            name  = "SYNAPSE_REPORT_STATS"
            value = "yes"
          }
          env {
            name  = "PYTHONPATH"
            value = "/extra-packages"
          }
          volume_mount {
            name       = "data"
            mount_path = "/data"
          }
          volume_mount {
            name       = "extra-packages"
            mount_path = "/extra-packages"
          }
          resources {
            requests = {
              cpu    = "25m"
              memory = "256Mi"
            }
            limits = {
              memory = "512Mi"
            }
          }
        }
        volume {
          name = "data"
          persistent_volume_claim {
            claim_name = kubernetes_persistent_volume_claim.data_encrypted.metadata[0].name
          }
        }
        volume {
          name = "extra-packages"
          empty_dir {}
        }
      }
    }
  }
}

resource "kubernetes_service" "matrix" {
  metadata {
    name      = "matrix"
    namespace = kubernetes_namespace.matrix.metadata[0].name
    labels = {
      "app" = "matrix"
    }
  }

  spec {
    selector = {
      app = "matrix"
    }
    port {
      name        = "http"
      port        = "80"
      target_port = "8008"
    }
  }
}

module "ingress" {
  source          = "../../modules/kubernetes/ingress_factory"
  namespace       = kubernetes_namespace.matrix.metadata[0].name
  name            = "matrix"
  tls_secret_name = var.tls_secret_name
  extra_annotations = {
    "gethomepage.dev/enabled"      = "true"
    "gethomepage.dev/name"         = "Matrix"
    "gethomepage.dev/description"  = "Secure messaging"
    "gethomepage.dev/icon"         = "matrix.png"
    "gethomepage.dev/group"        = "Other"
    "gethomepage.dev/pod-selector" = ""
  }
}
