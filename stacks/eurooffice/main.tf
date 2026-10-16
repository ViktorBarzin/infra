variable "tls_secret_name" {
  type      = string
  sensitive = true
}

# Euro-Office Document Server: the in-browser editor behind Nextcloud's
# "Open in Euro-Office" for docx/xlsx/pptx (Viktor, 2026-10-12). Euro-Office
# is the OnlyOffice fork Nextcloud ships as its default office suite since
# Hub 26 Spring; it replaced the onlyoffice stack decommissioned 2026-07-01.
#
# The standalone image runs its own Postgres, Redis and RabbitMQ inside the
# container, and nothing here is persisted. Documents live in Nextcloud: the
# editor fetches a file over the StorageUrl and posts the saved version back
# through the connector's callback, so a restart only drops sessions that are
# open at that moment.
#
# Nextcloud side (app config in the Nextcloud DB, set with occ, not managed
# here): the `eurooffice` connector app with
#   DocumentServerUrl         = https://eurooffice.viktorbarzin.me/
#   DocumentServerInternalUrl = http://eurooffice.eurooffice.svc.cluster.local/
#   StorageUrl                = https://nextcloud.viktorbarzin.me/
#   jwt_secret                = the jwt_secret key of the eurooffice-jwt Secret
#   jwt_header                = Authorization
# Check the link with `php occ eurooffice:documentserver --check` in the
# nextcloud pod.

resource "kubernetes_namespace" "eurooffice" {
  metadata {
    name = "eurooffice"
    labels = {
      "istio-injection" : "disabled"
      tier = local.tiers.edge
    }
  }
  lifecycle {
    # KYVERNO_LIFECYCLE_V1: goldilocks-vpa-auto-mode ClusterPolicy stamps this label on every namespace
    ignore_changes = [metadata[0].labels["goldilocks.fairwinds.com/vpa-update-mode"]]
  }
}

module "tls_secret" {
  source          = "../../modules/kubernetes/setup_tls_secret"
  namespace       = kubernetes_namespace.eurooffice.metadata[0].name
  tls_secret_name = var.tls_secret_name
}

# Shared secret between the Document Server and the Nextcloud connector. Every
# request in either direction carries a JWT signed with it, and it is the only
# gate on the public ingress below.
resource "random_password" "jwt_secret" {
  length  = 48
  special = false
}

resource "kubernetes_secret" "jwt" {
  metadata {
    name      = "eurooffice-jwt"
    namespace = kubernetes_namespace.eurooffice.metadata[0].name
  }
  data = {
    jwt_secret = random_password.jwt_secret.result
  }
}

resource "kubernetes_deployment" "eurooffice" {
  metadata {
    name      = "eurooffice"
    namespace = kubernetes_namespace.eurooffice.metadata[0].name
    labels = {
      app  = "eurooffice"
      tier = local.tiers.edge
    }
    annotations = {
      "reloader.stakater.com/auto" = "true"
    }
  }
  spec {
    replicas = 1
    strategy {
      type = "Recreate"
    }
    selector {
      match_labels = {
        app = "eurooffice"
      }
    }
    template {
      metadata {
        labels = {
          app = "eurooffice"
        }
      }
      spec {
        container {
          name  = "eurooffice"
          image = "ghcr.io/euro-office/documentserver:v9.3.5"
          # Docservice, converter, nginx and the bundled Postgres, Redis and
          # RabbitMQ share this one container. OnlyOffice with an external
          # database fitted in 1.5Gi; the limit leaves room for converting
          # large documents.
          resources {
            requests = {
              cpu    = "200m"
              memory = "1536Mi"
            }
            limits = {
              memory = "3Gi"
            }
          }
          port {
            name           = "http"
            container_port = 80
            protocol       = "TCP"
          }
          env {
            name = "JWT_SECRET"
            value_from {
              secret_key_ref {
                name = kubernetes_secret.jwt.metadata[0].name
                key  = "jwt_secret"
              }
            }
          }
          # The editor downloads documents from the StorageUrl,
          # nextcloud.viktorbarzin.me, which resolves to the internal Traefik
          # address inside the cluster. The server refuses private addresses
          # unless this is set.
          env {
            name  = "ALLOW_PRIVATE_IP_ADDRESS"
            value = "true"
          }
          # First boot initialises the bundled Postgres and RabbitMQ, which
          # takes a minute or two.
          startup_probe {
            http_get {
              path = "/healthcheck"
              port = 80
            }
            initial_delay_seconds = 20
            period_seconds        = 5
            failure_threshold     = 60
            timeout_seconds       = 3
          }
          readiness_probe {
            http_get {
              path = "/healthcheck"
              port = 80
            }
            period_seconds    = 10
            timeout_seconds   = 3
            failure_threshold = 3
          }
          liveness_probe {
            http_get {
              path = "/healthcheck"
              port = 80
            }
            period_seconds    = 30
            timeout_seconds   = 5
            failure_threshold = 5
          }
        }
      }
    }
  }
  lifecycle {
    ignore_changes = [
      spec[0].template[0].spec[0].dns_config, # KYVERNO_LIFECYCLE_V1
      metadata[0].annotations["kubernetes.io/change-cause"],
      metadata[0].annotations["deployment.kubernetes.io/revision"],
    ]
  }
  # A node without the 2.5 GB image takes about 7.5 min to pull it, and the
  # bundled Postgres can time out once on a cold first boot and restart. The
  # provider's default 10 min rollout wait ran out on the first apply.
  timeouts {
    create = "20m"
    update = "20m"
  }
}

resource "kubernetes_service" "eurooffice" {
  metadata {
    name      = "eurooffice"
    namespace = kubernetes_namespace.eurooffice.metadata[0].name
    labels = {
      app = "eurooffice"
    }
  }
  spec {
    selector = {
      app = "eurooffice"
    }
    port {
      name        = "http"
      port        = 80
      target_port = 80
    }
  }
}

module "ingress" {
  source = "../../modules/kubernetes/ingress_factory"
  # auth = "none": Nextcloud loads the editor in an iframe and every request
  # carries a JWT signed with the shared secret, which the Document Server
  # verifies. Authentik forward-auth would redirect the iframe load for a
  # browser without an Authentik cookie.
  auth            = "none"
  dns_type        = "proxied"
  namespace       = kubernetes_namespace.eurooffice.metadata[0].name
  name            = "eurooffice"
  # No Turnstile gate: its editor loads in an iframe inside Nextcloud (docs/plans/2026-10-16-turnstile-sitewide-design.md).
  turnstile = false
  tls_secret_name = var.tls_secret_name
  # Matches the Document Server's own 100 MB upload cap.
  max_body_size = "100m"
  extra_annotations = {
    "gethomepage.dev/enabled"      = "true"
    "gethomepage.dev/name"         = "Euro-Office"
    "gethomepage.dev/description"  = "Document editor for Nextcloud"
    "gethomepage.dev/icon"         = "onlyoffice.png"
    "gethomepage.dev/group"        = "Productivity"
    "gethomepage.dev/pod-selector" = ""
  }
}
