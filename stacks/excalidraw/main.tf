variable "tls_secret_name" { type = string }

locals {
  tiers = {
    core    = "0-core"
    cluster = "1-cluster"
    gpu     = "2-gpu"
    edge    = "3-edge"
    aux     = "4-aux"
  }
}

resource "kubernetes_namespace" "excalidraw" {
  metadata {
    name = "excalidraw"
    labels = {
      "istio-injection" : "disabled"
      tier = local.tiers.aux
    }
  }
}


module "tls_secret" {
  source          = "../../modules/kubernetes/setup_tls_secret"
  namespace       = kubernetes_namespace.excalidraw.metadata[0].name
  tls_secret_name = var.tls_secret_name
}

resource "kubernetes_deployment" "excalidraw" {
  metadata {
    name      = "excalidraw"
    namespace = kubernetes_namespace.excalidraw.metadata[0].name
    labels = {
      app  = "excalidraw"
      tier = local.tiers.aux
    }
  }
  spec {
    replicas = 1
    selector {
      match_labels = {
        app = "excalidraw"
      }
    }
    template {
      metadata {
        labels = {
          app = "excalidraw"
        }
        annotations = {
          "diun.enable"       = "true"
          "diun.include_tags" = "^latest$"
        }
      }
      spec {
        container {
          image             = "viktorbarzin/excalidraw-library:v4"
          image_pull_policy = "IfNotPresent"
          name              = "excalidraw"
          port {
            container_port = 8080
          }
          env {
            name  = "DATA_DIR"
            value = "/data"
          }
          env {
            name  = "PORT"
            value = "8080"
          }
          volume_mount {
            name       = "data"
            mount_path = "/data"
          }
        }
        volume {
          name = "data"
          nfs {
            server = "10.0.10.15"
            path   = "/mnt/main/excalidraw"
          }
        }
      }
    }
  }
}

resource "kubernetes_service" "draw" {
  metadata {
    name      = "draw"
    namespace = kubernetes_namespace.excalidraw.metadata[0].name
    labels = {
      app = "excalidraw"
    }
  }

  spec {
    selector = {
      app = "excalidraw"
    }
    port {
      name        = "http"
      port        = 80
      target_port = 8080
    }
  }
}

module "ingress" {
  source          = "../../modules/kubernetes/ingress_factory"
  namespace       = kubernetes_namespace.excalidraw.metadata[0].name
  name            = "draw"
  tls_secret_name = var.tls_secret_name
  protected       = true
}
