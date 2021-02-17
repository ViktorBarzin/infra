variable "tls_secret_name" {}

resource "kubernetes_namespace" "privatebin" {
  metadata {
    name = "privatebin"
  }
}

module "tls_secret" {
  source          = "../setup_tls_secret"
  namespace       = "privatebin"
  tls_secret_name = var.tls_secret_name
}

resource "kubernetes_deployment" "privatebin" {
  metadata {
    name      = "privatebin"
    namespace = "privatebin"
    labels = {
      app                             = "privatebin"
      "kubernetes.io/cluster-service" = "true"
    }
  }
  spec {
    replicas = 1
    strategy {
      type = "Recreate"
    }
    selector {
      match_labels = {
        app = "privatebin"
      }
    }
    template {
      metadata {
        labels = {
          app                             = "privatebin"
          "kubernetes.io/cluster-service" = "true"
        }
      }
      spec {
        container {
          image             = "privatebin/nginx-fpm-alpine"
          name              = "privatebin"
          image_pull_policy = "IfNotPresent"
          resources {
            limits = {
              cpu    = "1"
              memory = "1Gi"
            }
            requests = {
              cpu    = "1"
              memory = "1Gi"
            }
          }
          port {
            container_port = 8080
          }
          volume_mount {
            name       = "data"
            mount_path = "/srv/data"
            sub_path   = "data"
          }
        }

        volume {
          name = "data"
          iscsi {
            target_portal = "iscsi.viktorbarzin.lan:3260"
            fs_type       = "ext4"
            iqn           = "iqn.2020-12.lan.viktorbarzin:storage:privatebin"
            lun           = 0
            read_only     = false
          }
        }
      }
    }
  }
}

resource "kubernetes_service" "privatebin" {
  metadata {
    name      = "privatebin"
    namespace = "privatebin"
    labels = {
      "app" = "privatebin"
    }
  }

  spec {
    selector = {
      app = "privatebin"
    }
    port {
      port        = "80"
      target_port = "8080"
    }
  }
}

resource "kubernetes_ingress" "privatebin" {
  metadata {
    name      = "privatebin-ingress"
    namespace = "privatebin"
    annotations = {
      "kubernetes.io/ingress.class" = "nginx"
    }
  }

  spec {
    tls {
      hosts       = ["privatebin.viktorbarzin.me", "pb.viktorbarzin.me"]
      secret_name = var.tls_secret_name
    }
    rule {
      host = "privatebin.viktorbarzin.me"
      http {
        path {
          path = "/"
          backend {
            service_name = "privatebin"
            service_port = "80"
          }
        }
      }
    }
    rule {
      host = "pb.viktorbarzin.me"
      http {
        path {
          path = "/"
          backend {
            service_name = "privatebin"
            service_port = "80"
          }
        }
      }
    }
  }
}
