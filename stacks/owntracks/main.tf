variable "tls_secret_name" {
  type      = string
  sensitive = true
}
variable "nfs_server" { type = string }

resource "kubernetes_manifest" "external_secret" {
  manifest = {
    apiVersion = "external-secrets.io/v1"
    kind       = "ExternalSecret"
    metadata = {
      name      = "owntracks-secrets"
      namespace = "owntracks"
    }
    spec = {
      refreshInterval = "15m"
      secretStoreRef = {
        name = "vault-kv"
        kind = "ClusterSecretStore"
      }
      target = {
        name = "owntracks-secrets"
      }
      dataFrom = [{
        extract = {
          key = "owntracks"
        }
      }]
    }
  }
  depends_on = [kubernetes_namespace.owntracks]
}

data "kubernetes_secret" "eso_secrets" {
  metadata {
    name      = "owntracks-secrets"
    namespace = kubernetes_namespace.owntracks.metadata[0].name
  }
  depends_on = [kubernetes_manifest.external_secret]
}

locals {
  credentials = jsondecode(data.kubernetes_secret.eso_secrets.data["credentials"])
}


resource "kubernetes_namespace" "owntracks" {
  metadata {
    name = "owntracks"
    labels = {
      "istio-injection" : "disabled"
      tier               = local.tiers.aux
      "keel.sh/enrolled" = "true"
    }
  }
  lifecycle {
    # KYVERNO_LIFECYCLE_V1: goldilocks-vpa-auto-mode ClusterPolicy stamps this label on every namespace
    ignore_changes = [metadata[0].labels["goldilocks.fairwinds.com/vpa-update-mode"]]
  }
}

module "tls_secret" {
  source          = "../../modules/kubernetes/setup_tls_secret"
  namespace       = kubernetes_namespace.owntracks.metadata[0].name
  tls_secret_name = var.tls_secret_name
}

locals {
  username = "owntracks"
  htpasswd = join("\n", [for name, pass in local.credentials : "${name}:${bcrypt(pass, 10)}"])
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
    # DRIFT_WORKAROUND: htpasswd bcrypt hashes are non-deterministic per apply; would cause perpetual diff. Reviewed 2026-04-18.
    ignore_changes = [data]
  }
}

resource "kubernetes_config_map" "dawarich_hook" {
  metadata {
    name      = "dawarich-hook"
    namespace = kubernetes_namespace.owntracks.metadata[0].name
  }
  data = {
    "dawarich-hook.lua" = file("${path.module}/dawarich-hook.lua")
  }
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
          image = "owntracks/recorder:1.0.1"
          name  = "owntracks"
          port {
            name           = "http"
            container_port = 8083
          }
          # ot-recorder 1.0.1 has no OTR_HTTPHOOK; forwarding to Dawarich is
          # done via a Lua hook script loaded with --lua-script. The script
          # reads DAWARICH_API_KEY from env and fires curl fire-and-forget.
          args = ["--lua-script", "/hook/dawarich-hook.lua", "owntracks/#"]
          env {
            name  = "OTR_PORT"
            value = "0"
          }
          env {
            name = "DAWARICH_API_KEY"
            value_from {
              secret_key_ref {
                name = "owntracks-secrets"
                key  = "dawarich_api_key"
              }
            }
          }

          volume_mount {
            name       = "data"
            mount_path = "/store"
          }
          volume_mount {
            name       = "data"
            mount_path = "/config"
          }
          volume_mount {
            name       = "hook"
            mount_path = "/hook"
            read_only  = true
          }
          resources {
            requests = {
              cpu    = "10m"
              memory = "64Mi"
            }
            limits = {
              memory = "64Mi"
            }
          }
        }
        volume {
          name = "data"
          persistent_volume_claim {
            claim_name = "owntracks-data-encrypted"
          }
        }
        volume {
          name = "hook"
          config_map {
            name = kubernetes_config_map.dawarich_hook.metadata[0].name
          }
        }
      }
    }
  }
  lifecycle {
    ignore_changes = [
      spec[0].template[0].spec[0].dns_config, # KYVERNO_LIFECYCLE_V1
      metadata[0].annotations["keel.sh/policy"],
      metadata[0].annotations["keel.sh/trigger"],
      metadata[0].annotations["keel.sh/pollSchedule"], # KYVERNO_LIFECYCLE_V2
      metadata[0].annotations["keel.sh/match-tag"],
      spec[0].template[0].spec[0].container[0].image, # KEEL_IGNORE_IMAGE — Keel manages tag updates
      metadata[0].annotations["kubernetes.io/change-cause"],
      metadata[0].annotations["deployment.kubernetes.io/revision"],
      spec[0].template[0].metadata[0].annotations["keel.sh/update-time"], # KEEL_LIFECYCLE_V1
    ]
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
      # Recorder listens plain HTTP on 8083 (OTR_PORT=0 disables HTTPS).
      # Port name/number drive Traefik's backend-scheme inference — must be
      # http/80 so it doesn't try TLS against a plain socket (previous 500s).
      name        = "http"
      port        = 80
      target_port = 8083
      protocol    = "TCP"
    }
  }
}

module "ingress" {
  source = "../../modules/kubernetes/ingress_factory"
  # OwnTracks mobile clients post location data over HTTP basic-auth (see the
  # `owntracks-basic-auth` middleware below). They can't follow forward-auth
  # 302s, so Authentik is bypassed; the `extra_annotations` block below
  # overrides the factory's middleware list anyway.
  # auth = "none": OwnTracks mobile clients POST location via HTTP Basic auth; Authentik 302s incompatible with non-browser clients.
  auth            = "none"
  dns_type        = "proxied"
  namespace       = kubernetes_namespace.owntracks.metadata[0].name
  name            = "owntracks"
  tls_secret_name = var.tls_secret_name
  port            = 80
  extra_annotations = {
    "traefik.ingress.kubernetes.io/router.middlewares" = "owntracks-basic-auth@kubernetescrd,traefik-rate-limit@kubernetescrd,traefik-csp-headers@kubernetescrd"
    "gethomepage.dev/enabled"                          = "true"
    "gethomepage.dev/name"                             = "OwnTracks"
    "gethomepage.dev/description"                      = "Location tracking"
    "gethomepage.dev/icon"                             = "owntracks.png"
    "gethomepage.dev/group"                            = "Smart Home"
    "gethomepage.dev/pod-selector"                     = ""
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

# CI retrigger 2026-05-16T13:42:57+00:00 — bulk enrollment apply (pipeline #689 killed)
# CI retrigger v2 2026-05-16T13:46:35+00:00
