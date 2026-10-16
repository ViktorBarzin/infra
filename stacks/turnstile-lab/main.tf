# THROWAWAY LAB (2026-10-15): does Cloudflare Turnstile work as a bot wall in
# front of our sites, as a possible Anubis replacement? A tiny stock-python gate
# at turnstile-lab.viktorbarzin.me renders the widget, calls siteverify, logs
# the full result, and sets a signed cookie on success. It touches no existing
# site, ingress, middleware or Traefik plugin.
#
# Teardown: `homelab tf destroy turnstile-lab` (or scripts/tg destroy) from the
# main checkout, then delete stacks/turnstile-lab/ and commit. The destroy
# removes the namespace, the ingress and the Turnstile widget.

variable "tls_secret_name" {
  type      = string
  sensitive = true
}

locals {
  name = "turnstile-lab"
  host = "turnstile-lab.viktorbarzin.me"
}

data "cloudflare_accounts" "main" {}

# Managed mode: Cloudflare decides per visitor whether to show a checkbox.
# Free plan allows 20 widgets; forgejo-signup is the only other one we manage.
resource "cloudflare_turnstile_widget" "lab" {
  account_id = data.cloudflare_accounts.main.accounts[0].id
  name       = local.name
  domains    = [local.host]
  mode       = "managed"
}

resource "kubernetes_namespace" "lab" {
  metadata {
    name = local.name
    labels = {
      "istio-injection" : "disabled"
      tier = local.tiers.aux
    }
  }
  lifecycle {
    # KYVERNO_LIFECYCLE_V1: goldilocks-vpa-auto-mode ClusterPolicy stamps this label on every namespace
    ignore_changes = [metadata[0].labels["goldilocks.fairwinds.com/vpa-update-mode"]]
  }
}

module "tls_secret" {
  source          = "../../modules/kubernetes/setup_tls_secret"
  namespace       = kubernetes_namespace.lab.metadata[0].name
  tls_secret_name = var.tls_secret_name
}

resource "kubernetes_secret" "lab" {
  metadata {
    name      = "turnstile-lab"
    namespace = kubernetes_namespace.lab.metadata[0].name
  }
  data = {
    "turnstile-secret" = cloudflare_turnstile_widget.lab.secret
  }
}

resource "kubernetes_config_map" "gate" {
  metadata {
    name      = "turnstile-lab-gate"
    namespace = kubernetes_namespace.lab.metadata[0].name
  }
  data = {
    "gate.py" = file("${path.module}/files/gate.py")
  }
}

resource "kubernetes_deployment" "gate" {
  metadata {
    name      = local.name
    namespace = kubernetes_namespace.lab.metadata[0].name
    labels = {
      app  = local.name
      tier = local.tiers.aux
    }
  }
  spec {
    replicas = 1
    selector {
      match_labels = {
        app = local.name
      }
    }
    template {
      metadata {
        labels = {
          app = local.name
        }
        annotations = {
          # Roll the pod when the script changes.
          "turnstile-lab/gate-sha" = sha256(file("${path.module}/files/gate.py"))
        }
      }
      spec {
        container {
          name    = "gate"
          image   = "python:3.12-slim"
          command = ["python3", "-u", "/app/gate.py"]
          env {
            name  = "TURNSTILE_SITEKEY"
            value = cloudflare_turnstile_widget.lab.id
          }
          env {
            name = "TURNSTILE_SECRET"
            value_from {
              secret_key_ref {
                name = kubernetes_secret.lab.metadata[0].name
                key  = "turnstile-secret"
              }
            }
          }
          port {
            container_port = 8080
          }
          volume_mount {
            name       = "gate"
            mount_path = "/app"
            read_only  = true
          }
          readiness_probe {
            http_get {
              path = "/healthz"
              port = 8080
            }
            period_seconds = 10
          }
          resources {
            requests = {
              cpu    = "10m"
              memory = "48Mi"
            }
            limits = {
              memory = "96Mi"
            }
          }
        }
        volume {
          name = "gate"
          config_map {
            name = kubernetes_config_map.gate.metadata[0].name
          }
        }
      }
    }
  }
  lifecycle {
    ignore_changes = [
      spec[0].template[0].spec[0].dns_config, # KYVERNO_LIFECYCLE_V1
    ]
  }
}

resource "kubernetes_service" "gate" {
  metadata {
    name      = local.name
    namespace = kubernetes_namespace.lab.metadata[0].name
    labels = {
      app = local.name
    }
  }
  spec {
    selector = {
      app = local.name
    }
    port {
      name        = "http"
      port        = 80
      target_port = 8080
    }
  }
}

module "ingress" {
  source = "../../modules/kubernetes/ingress_factory"
  # The page under test IS the Turnstile gate, and the lab backend holds
  # nothing but its own verify log.
  # auth = "none": public by design, the Turnstile experiment itself
  auth            = "none"
  dns_type        = "proxied"
  namespace       = kubernetes_namespace.lab.metadata[0].name
  name            = local.name
  tls_secret_name = var.tls_secret_name
  # No gate: the lab serves its own Turnstile page.
  turnstile        = false
  anti_ai_scraping = false
  homepage_enabled = false
  external_monitor = false
}
