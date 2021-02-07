
variable "tls_secret_name" {}
variable "tls_crt" {}
variable "tls_key" {}
variable "webhook_secret" {}

resource "kubernetes_namespace" "webhook-handler" {
  metadata {
    name = "webhook-handler"
  }
}

module "tls_secret" {
  source          = "../setup_tls_secret"
  namespace       = "webhook-handler"
  tls_secret_name = var.tls_secret_name
  tls_crt         = var.tls_crt
  tls_key         = var.tls_key
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

resource "kubernetes_deployment" "webhook_handler" {
  metadata {
    name      = "webhook-handler"
    namespace = "webhook-handler"
    labels = {
      app = "webhook-handler"
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
          env {
            name  = "WEBHOOKSECRET"
            value = var.webhook_secret
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

resource "kubernetes_ingress" "webhook_handler" {
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
            service_name = "webhook-handler"
            service_port = "80"
          }
        }
      }
    }
  }
}
