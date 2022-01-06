
variable "tls_secret_name" {}
variable "webhook_secret" {}
variable "fb_verify_token" {}
variable "fb_page_token" {}
variable "fb_app_secret" {}
variable "git_user" {}
variable "git_token" {}
variable "ssh_key" {}

resource "kubernetes_namespace" "webhook-handler" {
  metadata {
    name = "webhook-handler"
  }
}

module "tls_secret" {
  source          = "../setup_tls_secret"
  namespace       = "webhook-handler"
  tls_secret_name = var.tls_secret_name
}

resource "kubernetes_cluster_role" "deployment_updater" {
  metadata {
    name = "deployment-updater"
  }

  rule {
    verbs      = ["create", "update", "get", "patch", "list"]
    api_groups = ["extensions", "apps", ""]
    resources  = ["deployments", "namespaces", "pods", "services"]
  }
}

resource "kubernetes_cluster_role_binding" "update_deployment_binding" {
  metadata {
    name = "update-deployment-binding"
  }

  subject {
    kind      = "ServiceAccount"
    name      = "default"
    namespace = "webhook-handler"
  }

  role_ref {
    api_group = "rbac.authorization.k8s.io"
    kind      = "ClusterRole"
    name      = "deployment-updater"
  }
}


resource "kubernetes_secret" "ssh-key" {
  metadata {
    name      = "ssh-key"
    namespace = "webhook-handler"

    annotations = {
      "reloader.stakater.com/match" = "true"
    }
  }
  data = {
    "id_rsa" = var.ssh_key
  }
  type = "generic"
}
resource "kubernetes_deployment" "webhook_handler" {
  metadata {
    name      = "webhook-handler"
    namespace = "webhook-handler"
    labels = {
      app = "webhook-handler"
    }
    annotations = {
      "reloader.stakater.com/search" = "true"
    }
  }
  spec {
    replicas = 1
    selector {
      match_labels = {
        app = "webhook-handler"
      }
    }
    template {
      metadata {
        labels = {
          app = "webhook-handler"
        }
      }
      spec {
        container {
          # security_context {
          #   run_as_user = 1000
          # }
          # lifecycle {
          #   post_start {
          #     exec {
          #       # Must be kept in sycn with webhook_handler dockerfile
          #       command = ["echo", "\"$SSH_KEY\"", ">", "/opt/id_rsa", "&&", "chown", "appuser", "/opt/id_rsa", "&&", "chmod", "600", "/opt/id_rsa"]
          #     }
          #   }
          # }
          image = "viktorbarzin/webhook-handler:latest"
          name  = "webhook-handler"
          resources {
            limits = {
              cpu    = "0.5"
              memory = "512Mi"
            }
            requests = {
              cpu    = "250m"
              memory = "50Mi"
            }
          }
          port {
            container_port = 80
          }
          volume_mount {
            name       = "id-rsa"
            mount_path = "/opt/id_rsa"
            sub_path   = "id_rsa"
          }
          env {
            name  = "WEBHOOKSECRET"
            value = var.webhook_secret
          }
          env {
            name  = "FB_APP_SECRET"
            value = var.fb_app_secret
          }
          env {
            name  = "FB_VERIFY_TOKEN"
            value = var.fb_verify_token
          }
          env {
            name  = "FB_PAGE_TOKEN"
            value = var.fb_page_token
          }
          env {
            name  = "CONFIG"
            value = "./chatbot/config/viktorwebservices.yaml"
          }
          env {
            name  = "GIT_USER"
            value = var.git_user
          }
          env {
            name  = "GIT_TOKEN"
            value = var.git_token
          }
          env {
            name  = "SSH_KEY"
            value = "/opt/id_rsa"
          }
        }
        volume {
          name = "id-rsa"
          secret {
            secret_name = "ssh-key"
          }

        }
      }
    }
  }
}

resource "kubernetes_service" "webhook_handler" {
  metadata {
    name      = "webhook-handler"
    namespace = "webhook-handler"
    labels = {
      "app" = "webhook-handler"
    }
  }

  spec {
    selector = {
      app = "webhook-handler"
    }
    port {
      port        = "80"
      target_port = "3000"
    }
  }
}

resource "kubernetes_ingress_v1" "webhook_handler" {
  metadata {
    name      = "webhook-handler-ingress"
    namespace = "webhook-handler"
    annotations = {
      "kubernetes.io/ingress.class" = "nginx"
    }
  }

  spec {
    tls {
      hosts       = ["webhook.viktorbarzin.me"]
      secret_name = var.tls_secret_name
    }
    rule {
      host = "webhook.viktorbarzin.me"
      http {
        path {
          path = "/"
          backend {
            service {
              name = "webhook-handler"
              port {
                number = 80
              }
            }
          }
        }
      }
    }
  }
}
