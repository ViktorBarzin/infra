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

module "tls_secret" {
  source          = "../../modules/kubernetes/setup_tls_secret"
  namespace       = kubernetes_namespace.matrix.metadata[0].name
  tls_secret_name = var.tls_secret_name
}

module "nfs_data" {
  source     = "../../modules/kubernetes/nfs_volume"
  name       = "matrix-data"
  namespace  = kubernetes_namespace.matrix.metadata[0].name
  nfs_server = var.nfs_server
  nfs_path   = "/mnt/main/matrix"
}

resource "kubernetes_persistent_volume_claim" "data_proxmox" {
  wait_until_bound = false
  metadata {
    name      = "matrix-data-proxmox"
    namespace = kubernetes_namespace.matrix.metadata[0].name
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
          "dependency.kyverno.io/wait-for" = "postgresql.dbaas:5432"
        }
      }
      spec {
        init_container {
          name    = "install-psycopg2"
          image   = "matrixdotorg/synapse:latest"
          command = ["/bin/sh", "-c", "pip install --target=/extra-packages psycopg2-binary 2>/dev/null"]
          volume_mount {
            name       = "extra-packages"
            mount_path = "/extra-packages"
          }
        }
        container {
          image = "matrixdotorg/synapse:latest"
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
        }
        volume {
          name = "data"
          persistent_volume_claim {
            claim_name = kubernetes_persistent_volume_claim.data_proxmox.metadata[0].name
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
