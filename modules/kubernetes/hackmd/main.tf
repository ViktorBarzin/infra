variable "tls_secret_name" {}
variable "hackmd_db_password" {}

resource "kubernetes_namespace" "hackmd" {
  metadata {
    name = "hackmd"
    labels = {
      "istio-injection" : "disabled"
    }
  }
}

module "tls_secret" {
  source          = "../setup_tls_secret"
  namespace       = kubernetes_namespace.hackmd.metadata[0].name
  tls_secret_name = var.tls_secret_name
}

resource "kubernetes_deployment" "hackmd" {
  metadata {
    name      = "hackmd"
    namespace = kubernetes_namespace.hackmd.metadata[0].name
    labels = {
      app                             = "hackmd"
      "kubernetes.io/cluster-service" = "true"
    }
  }
  spec {
    replicas = 1
    strategy {
      type = "RollingUpdate" # DB is external so we can roll
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
            # value = format("%s%s%s", "postgres://codimd:", var.hackmd_db_password, "@localhost/codimd")
            value = format("%s%s%s", "mysql://codimd:", var.hackmd_db_password, "@mysql.dbaas/codimd")
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
        }
        security_context {
          fs_group = "1500"
        }
        volume {
          name = "data"
          nfs {
            path   = "/mnt/main/hackmd"
            server = "10.0.10.15"
          }
          #   iscsi {
          #     target_portal = "iscsi.viktorbarzin.lan:3260"
          #     fs_type       = "ext4"
          #     iqn           = "iqn.2020-12.lan.viktorbarzin:storage:hackmd"
          #     lun           = 0
          #     read_only     = false
          #   }
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
  source          = "../ingress_factory"
  namespace       = kubernetes_namespace.hackmd.metadata[0].name
  name            = "hackmd"
  tls_secret_name = var.tls_secret_name
  extra_annotations = {
    "nginx.ingress.kubernetes.io/proxy-body-size" : "20000m"
  }
}
