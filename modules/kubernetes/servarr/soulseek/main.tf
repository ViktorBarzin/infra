variable "tls_secret_name" {}
variable "tier" { type = string }


resource "kubernetes_deployment" "soulseek" {
  metadata {
    name      = "soulseek"
    namespace = "servarr"
    labels = {
      app  = "soulseek"
      tier = var.tier
    }
    annotations = {
      "reloader.stakater.com/search" = "true"
    }
  }
  spec {
    replicas = 1
    selector {
      match_labels = {
        app = "soulseek"
      }
    }
    template {
      metadata {
        labels = {
          app = "soulseek"
        }
      }
      spec {
        container {
          image = "realies/soulseek"
          name  = "soulseek"

          port {
            name           = "soulseek"
            container_port = 6080
          }
          env {
            name  = "PUID"
            value = 1000
          }
          env {
            name  = "PGID"
            value = 1000
          }
          volume_mount {
            name       = "config"
            mount_path = "/data/.SoulseekQt"
            sub_path   = "soulseek/config"
          }
          volume_mount {
            name       = "downloads"
            mount_path = "/data/Soulseek Downloads"
            sub_path   = "soulseek/downloads"
          }
        }
        volume {
          name = "config"
          nfs {
            path   = "/mnt/main/servarr/lidarr"
            server = "10.0.10.15"
          }
        }
        volume {
          name = "downloads"
          nfs {
            path   = "/mnt/main/servarr/lidarr"
            server = "10.0.10.15"
          }
        }
      }
    }
  }
}

resource "kubernetes_service" "soulseek" {
  metadata {
    name      = "soulseek"
    namespace = "servarr"
    labels = {
      app = "soulseek"
    }
  }

  spec {
    selector = {
      app = "soulseek"
    }
    port {
      name        = "http"
      port        = 80
      target_port = 6080
    }
  }
}


module "ingress" {
  source          = "../../ingress_factory"
  namespace       = "servarr"
  name            = "soulseek"
  tls_secret_name = var.tls_secret_name
  protected       = true
}
