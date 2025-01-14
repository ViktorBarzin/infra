variable "tls_secret_name" {}
variable "owntracks_credentials" {
  type = map(string)
  default = {
    "foo" = "bar" // example format for username and password
  }
}

resource "kubernetes_namespace" "owntracks" {
  metadata {
    name = "owntracks"
    labels = {
      "istio-injection" : "disabled"
    }
  }
}

module "tls_secret" {
  source          = "../setup_tls_secret"
  namespace       = "owntracks"
  tls_secret_name = var.tls_secret_name
}

locals {
  username = "owntracks"
  htpasswd = join("\n", [for name, pass in var.owntracks_credentials : "${name}:${bcrypt(pass, 10)}"])
}

resource "kubernetes_secret" "basic_auth" {
  metadata {
    name      = "basic-auth-secret"
    namespace = "owntracks"
  }

  data = {
    auth = local.htpasswd
  }

  type = "Opaque"
  lifecycle {
    ignore_changes = [data]
  }
}

resource "kubernetes_deployment" "owntracks" {
  metadata {
    name      = "owntracks"
    namespace = "owntracks"
    labels = {
      app = "owntracks"
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
        }
        volume {
          name = "data"
          nfs {
            path   = "/mnt/main/owntracks"
            server = "10.0.10.15"
          }
        }
      }
    }
  }
}


resource "kubernetes_service" "owntracks" {
  metadata {
    name      = "owntracks"
    namespace = "owntracks"
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
  source          = "../ingress_factory"
  namespace       = "owntracks"
  name            = "owntracks"
  tls_secret_name = var.tls_secret_name
  port            = 443
  extra_annotations = {
    "nginx.ingress.kubernetes.io/auth-type"   = "basic" # support only basic auth; can't use authentik
    "nginx.ingress.kubernetes.io/auth-secret" = kubernetes_secret.basic_auth.metadata[0].name
    "nginx.ingress.kubernetes.io/auth-realm"  = "Authentication Required"
  }
}
