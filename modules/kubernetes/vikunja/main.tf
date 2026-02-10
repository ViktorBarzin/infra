variable "tls_secret_name" {}

resource "kubernetes_namespace" "vikunja" {
  metadata {
    name = "vikunja"
  }
}

module "tls_secret" {
  source          = "../setup_tls_secret"
  namespace       = kubernetes_namespace.vikunja.metadata[0].name
  tls_secret_name = var.tls_secret_name
}

resource "kubernetes_deployment" "vikunja" {
  metadata {
    name      = "vikunja"
    namespace = kubernetes_namespace.vikunja.metadata[0].name
    labels = {
      app = "vikunja"
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
        app = "vikunja"
      }
    }
    template {
      metadata {
        labels = {
          app = "vikunja"
        }
      }
      spec {
        container {
          image = "vikunja/api"
          name  = "api"
          # General settings
          env {
            name  = "VIKUNJA_SERVICE_TIMEZONE"
            value = "Europe/London"
          }
          env {
            name  = "VIKUNJA_SERVICE_ENABLEREGISTRATION"
            value = "true"
          }
          env {
            name  = "VIKUNJA_LOG_LEVEL"
            value = "DEBUG"
          }
          # Frontend Settings
          env {
            name  = "VIKUNJA_SERVICE_JWTSECRET"
            value = "vikunja"
          }
          env {
            name  = "VIKUNJA_SERVICE_FRONTENDURL"
            value = "https://todo.viktorbarzin.me/"
          }
          # DB Settings
          env {
            name  = "VIKUNJA_DATABASE_HOST"
            value = "mysql.dbaas.svc.cluster.local"
          }
          env {
            name  = "VIKUNJA_DATABASE_PASSWORD"
            value = "" # ADD ME
          }
          env {
            name  = "VIKUNJA_DATABASE_TYPE"
            value = "mysql"
          }
          env {
            name  = "VIKUNJA_DATABASE_USER"
            value = "vikunja"
          }
          env {
            name  = "VIKUNJA_DATABASE_DATABASE"
            value = "vikunja"
          }
          env {
            name  = "VIKUNJA_LOG_DATABASE"
            value = "true"
          }
          env {
            name  = "VIKUNJA_LOG_DATABASELEVEL"
            value = "DEBUG"
          }
          # Mailser settings
          env {
            name  = "VIKUNJA_MAILER_ENABLED"
            value = "true"
          }
          env {
            name  = "VIKUNJA_MAILER_HOST"
            value = "mailserver.mailserver.svc.cluster.local"
          }
          env {
            name  = "VIKUNJA_MAILER_USERNAME"
            value = "me@viktorbarzin.me"
          }
          env {
            name  = "VIKUNJA_MAILER_PASSWORD"
            value = "" # TODO: add me
          }
          env {
            name  = "VIKUNJA_MAILER_FROMEMAIL"
            value = "todo@viktorbarzin.me"
          }
          # TODOIST settings
          env {
            name  = "VIKUNJA_MIGRATION_TODOIST_ENABLE"
            value = "true"
          }
          env {
            name  = "VIKUNJA_MIGRATION_TODOIST_CLIENTID"
            value = "" # TODO: add me
          }
          env {
            name  = "VIKUNJA_MIGRATION_TODOIST_CLIENTSECRET"
            value = "" # TODO: add me
          }
          env {
            name  = "VIKUNJA_MIGRATION_TODOIST_REDIRECTURL"
            value = "https://todo.viktorbarzin.me/migrate/todoist"
          }
          port {
            name           = "api"
            container_port = 3456
          }
        }

        container {
          image = "vikunja/frontend"
          name  = "frontend"
          port {
            name           = "http"
            container_port = 80
          }
        }
      }
    }
  }
}

resource "kubernetes_service" "vikunja" {
  metadata {
    name      = "vikunja"
    namespace = kubernetes_namespace.vikunja.metadata[0].name
    labels = {
      "app" = "vikunja"
    }
  }

  spec {
    selector = {
      app = "vikunja"
    }
    port {
      name        = "http"
      target_port = 80
      port        = 80
      protocol    = "TCP"
    }
  }
}

resource "kubernetes_service" "api" {
  metadata {
    name      = "api"
    namespace = kubernetes_namespace.vikunja.metadata[0].name
    labels = {
      "app" = "vikunja"
    }
  }

  spec {
    selector = {
      app = "vikunja"
    }
    port {
      name        = "api"
      target_port = 3456
      port        = 3456
      protocol    = "TCP"
    }
  }
}

module "ingress" {
  source          = "../ingress_factory"
  namespace       = kubernetes_namespace.vikunja.metadata[0].name
  name            = "vikunja"
  host            = "todo"
  tls_secret_name = var.tls_secret_name
}

module "ingress-api" {
  source          = "../ingress_factory"
  namespace       = kubernetes_namespace.vikunja.metadata[0].name
  name            = "vikunja-api"
  host            = "todo"
  service_name    = "api"
  port            = 3456
  ingress_path    = ["/api/"]
  tls_secret_name = var.tls_secret_name
}

