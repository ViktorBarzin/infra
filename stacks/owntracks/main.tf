variable "tls_secret_name" { type = string }
variable "owntracks_credentials" { type = map(string) }
variable "nfs_server" { type = string }


resource "kubernetes_namespace" "owntracks" {
  metadata {
    name = "owntracks"
    labels = {
      "istio-injection" : "disabled"
      tier = local.tiers.aux
    }
  }
}

module "tls_secret" {
  source          = "../../modules/kubernetes/setup_tls_secret"
  namespace       = kubernetes_namespace.owntracks.metadata[0].name
  tls_secret_name = var.tls_secret_name
}

locals {
  username = "owntracks"
  htpasswd = join("\n", [for name, pass in var.owntracks_credentials : "${name}:${bcrypt(pass, 10)}"])
}

resource "kubernetes_secret" "basic_auth" {
  metadata {
    name      = "basic-auth-secret"
    namespace = kubernetes_namespace.owntracks.metadata[0].name
  }

  data = {
    auth = local.htpasswd
  }

  type = "Opaque"
  lifecycle {
    ignore_changes = [data]
  }
}

module "nfs_data" {
  source     = "../../modules/kubernetes/nfs_volume"
  name       = "owntracks-data"
  namespace  = kubernetes_namespace.owntracks.metadata[0].name
  nfs_server = var.nfs_server
  nfs_path   = "/mnt/main/owntracks"
}

resource "kubernetes_deployment" "owntracks" {
  metadata {
    name      = "owntracks"
    namespace = kubernetes_namespace.owntracks.metadata[0].name
    labels = {
      app  = "owntracks"
      tier = local.tiers.aux
    }
    annotations = {
      "reloader.stakater.com/search" = "true"
    }
  }
  spec {
    replicas = 1
    strategy {
      type = "Recreate"
    }
    selector {
      match_labels = {
        app = "owntracks"
      }
    }
    template {
      metadata {
        labels = {
          app = "owntracks"
        }
        annotations = {
          "diun.enable"       = "true"
          "diun.include_tags" = "^\\d+(?:\\.\\d+)?(?:\\.\\d+)?$"
        }
      }
      spec {

        container {
          image = "owntracks/recorder:0.9.9"
          name  = "owntracks"
          port {
            name           = "https"
            container_port = 8083
          }
          env {
            name  = "OTR_PORT"
            value = "0"
          }

          volume_mount {
            name       = "data"
            mount_path = "/store"
          }
          volume_mount {
            name       = "data"
            mount_path = "/config"
          }
          resources {
            requests = {
              cpu    = "10m"
              memory = "16Mi"
            }
            limits = {
              cpu    = "100m"
              memory = "64Mi"
            }
          }
        }
        volume {
          name = "data"
          persistent_volume_claim {
            claim_name = module.nfs_data.claim_name
          }
        }
      }
    }
  }
}


resource "kubernetes_service" "owntracks" {
  metadata {
    name      = "owntracks"
    namespace = kubernetes_namespace.owntracks.metadata[0].name
    labels = {
      "app" = "owntracks"
    }
  }

  spec {
    selector = {
      app = "owntracks"
    }
    port {
      name        = "https"
      port        = 443
      target_port = 8083
      protocol    = "TCP"
    }
  }
}

module "ingress" {
  source          = "../../modules/kubernetes/ingress_factory"
  namespace       = kubernetes_namespace.owntracks.metadata[0].name
  name            = "owntracks"
  tls_secret_name = var.tls_secret_name
  port            = 443
  extra_annotations = {
    "traefik.ingress.kubernetes.io/router.middlewares" = "owntracks-basic-auth@kubernetescrd,traefik-rate-limit@kubernetescrd,traefik-csp-headers@kubernetescrd,traefik-crowdsec@kubernetescrd"
  }
}

resource "kubernetes_manifest" "basic_auth_middleware" {
  manifest = {
    apiVersion = "traefik.io/v1alpha1"
    kind       = "Middleware"
    metadata = {
      name      = "basic-auth"
      namespace = kubernetes_namespace.owntracks.metadata[0].name
    }
    spec = {
      basicAuth = {
        secret = kubernetes_secret.basic_auth.metadata[0].name
      }
    }
  }
}
