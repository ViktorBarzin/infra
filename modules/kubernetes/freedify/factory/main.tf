variable "tls_secret_name" {}
variable "name" {}
variable "tag" {
  default = "latest"
}
variable "tier" { type = string }
variable "protected" {
  type    = bool
  default = false
}
variable "listenbrainz_token" {
  type    = string
  default = null
}
variable "genius_token" {
  type    = string
  default = null
}
variable "dab_visitor_id" {
  type    = string
  default = null
}
variable "dab_session" {
  type    = string
  default = null
}
variable "gemini_api_key" {
  type    = string
  default = null
}
variable "cpu_limit" {
  type    = string
  default = "500m"
}
variable "memory_limit" {
  type    = string
  default = "512Mi"
}
variable "cpu_request" {
  type    = string
  default = "100m"
}
variable "memory_request" {
  type    = string
  default = "256Mi"
}


resource "kubernetes_deployment" "freedify" {
  metadata {
    name      = "music-${var.name}"
    namespace = "freedify"
    labels = {
      app  = "music-${var.name}"
      tier = var.tier
    }
  }
  spec {
    replicas = 1
    strategy {
      type = "RollingUpdate"
    }
    selector {
      match_labels = {
        app = "music-${var.name}"
      }
    }
    template {
      metadata {
        annotations = {
          "diun.enable"       = "true"
          "diun.include_tags" = "^${var.tag}$"
        }
        labels = {
          app = "music-${var.name}"
        }
      }
      spec {
        container {
          image = "viktorbarzin/freedify:${var.tag}"
          name  = "freedify"

          port {
            container_port = 8000
          }
          env {
            name  = "LISTENBRAINZ_TOKEN"
            value = var.listenbrainz_token
          }
          env {
            name  = "GENIUS_ACCESS_TOKEN"
            value = var.genius_token
          }
          env {
            name  = "DAB_SESSION"
            value = var.dab_session
          }
          env {
            name  = "DAB_VISITOR_ID"
            value = var.dab_visitor_id
          }
          env {
            name  = "GEMINI_API_KEY"
            value = var.gemini_api_key
          }
          resources {
            limits = {
              cpu    = var.cpu_limit
              memory = var.memory_limit
            }
            requests = {
              cpu    = var.cpu_request
              memory = var.memory_request
            }
          }
        }
      }
    }
  }
}

resource "kubernetes_service" "freedify" {
  metadata {
    name      = "music-${var.name}"
    namespace = "freedify"
    labels = {
      app = "music-${var.name}"
    }
  }

  spec {
    selector = {
      app = "music-${var.name}"
    }
    port {
      name        = "http"
      port        = 80
      target_port = 8000
    }
  }
}

module "ingress" {
  source          = "../../ingress_factory"
  namespace       = "freedify"
  name            = "music-${var.name}"
  tls_secret_name = var.tls_secret_name
  protected       = var.protected
}
