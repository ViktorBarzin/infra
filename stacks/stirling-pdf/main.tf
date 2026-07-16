variable "tls_secret_name" {
  type      = string
  sensitive = true
}
variable "nfs_server" { type = string }


resource "kubernetes_namespace" "stirling-pdf" {
  metadata {
    name = "stirling-pdf"
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
  namespace       = kubernetes_namespace.stirling-pdf.metadata[0].name
  tls_secret_name = var.tls_secret_name
}

resource "kubernetes_persistent_volume_claim" "configs_proxmox" {
  wait_until_bound = false
  metadata {
    name      = "stirling-pdf-configs-proxmox"
    namespace = kubernetes_namespace.stirling-pdf.metadata[0].name
    annotations = {
      "resize.topolvm.io/threshold"     = "10%"
      "resize.topolvm.io/increase"      = "100%"
      "resize.topolvm.io/storage_limit" = "5Gi"
    }
  }
  spec {
    access_modes       = ["ReadWriteOnce"]
    storage_class_name = "proxmox-lvm"
    resources {
      requests = {
        storage = "1Gi"
      }
    }
  }
  lifecycle {
    # The autoresizer expands requests.storage up to storage_limit and
    # PVCs can't shrink. Without this, every TF apply tries to revert
    # to the spec value, K8s rejects the shrink, and the PVC ends up
    # in Terminating-but-in-use limbo.
    ignore_changes = [spec[0].resources[0].requests]
  }
}

resource "kubernetes_deployment" "stirling-pdf" {
  metadata {
    name      = "stirling-pdf"
    namespace = kubernetes_namespace.stirling-pdf.metadata[0].name
    labels = {
      app  = "stirling-pdf"
      tier = local.tiers.aux
      # Scale-to-zero enrollment (ADR-0022): parked when idle, woken by the
      # first request through the ingress (design doc 2026-07-12).
      "sablier.enable" = "true"
      "sablier.group"  = "stirling-pdf"
      # 5s settling delay after k8s readiness: covers Traefik endpoint-list
      # propagation so the first forwarded request never hits a 503 race.
      "sablier.ready-after" = "5s"
    }
    # v1→v2 upgrade (2026-07-16): auto-track latest SAFELY via the semver-ordered
    # `major` policy — NOT `force`. force ignores semver ordering and rolled
    # paperless-ngx 2.20.15→1.5.0 within minutes (2026-07-14, memory #9838); it
    # is house-banned on upstream multi-tag repos and stirlingtools/stirling-pdf
    # is exactly that. `major` auto-takes every HIGHER semver (incl. future
    # majors), is monotonic so it can never roll backward, and performs the
    # initial 0.33.1→2.x jump itself. These keys are intentionally OUT of
    # ignore_changes below so TF reconciles the live patch→major flip; Kyverno's
    # +(keel.sh/policy)=patch is add-if-absent, so this explicit value wins.
    annotations = {
      "keel.sh/policy"       = "major"
      "keel.sh/trigger"      = "poll"
      "keel.sh/pollSchedule" = "@every 1h"
    }
  }
  spec {
    replicas = 1
    strategy {
      type = "Recreate"
    }
    selector {
      match_labels = {
        app = "stirling-pdf"
      }
    }
    template {
      metadata {
        labels = {
          app = "stirling-pdf"
        }
      }
      spec {
        container {
          # Semver seed for Keel's `major` policy (recreate-correct only — Keel
          # owns the LIVE tag via ignore_changes and bumps 0.33.1→this→newer).
          # `latest` == v2 today; a semver tag (not `:latest`) is required so
          # the semver policy has an ordered base to compare on a fresh recreate.
          image = "stirlingtools/stirling-pdf:2.13.2"
          name  = "stirling-pdf"
          # v2's entrypoint DYNAMICALLY sizes the JVM from the container memory
          # LIMIT: at 1Gi it caps MaxMetaspaceSize=128m, too small for v2's class
          # graph → OutOfMemoryError: Metaspace → -XX:+ExitOnOutOfMemoryError
          # crashloop (verified live 2026-07-16). At 2Gi it sets MaxMeta=192m and
          # boots in ~28s.
          #
          # Auth (2026-07-16): Stirling's OWN login is ENABLED and wired to
          # Authentik via generic OIDC — one SSO login, users auto-provisioned.
          # loginMethod=all keeps local username/password as an admin-bootstrap +
          # fallback path alongside SSO. Ingress is auth="app" (Stirling is the
          # gate; forward-auth is NOT in front, so the OIDC callback isn't
          # intercepted). client_id/secret + issuer come from authentik.tf; the
          # "Stirling PDF Users" Authentik group binding gates who can complete
          # the flow. provider=authentik → callback /login/oauth2/code/authentik.
          env {
            name  = "SECURITY_ENABLELOGIN"
            value = "true"
          }
          env {
            name  = "SECURITY_LOGINMETHOD"
            value = "all" # oauth2 (SSO) + local username/password fallback
          }
          env {
            name  = "SECURITY_OAUTH2_ENABLED"
            value = "true"
          }
          env {
            name  = "SECURITY_OAUTH2_PROVIDER"
            value = "authentik"
          }
          env {
            name  = "SECURITY_OAUTH2_ISSUER"
            value = "https://authentik.viktorbarzin.me/application/o/stirling-pdf/"
          }
          env {
            name  = "SECURITY_OAUTH2_CLIENTID"
            value = authentik_provider_oauth2.stirling_pdf.client_id
          }
          env {
            name  = "SECURITY_OAUTH2_CLIENTSECRET"
            value = authentik_provider_oauth2.stirling_pdf.client_secret
          }
          env {
            name  = "SECURITY_OAUTH2_SCOPES"
            value = "openid, profile, email"
          }
          env {
            name  = "SECURITY_OAUTH2_USEASUSERNAME"
            value = "email"
          }
          env {
            name  = "SECURITY_OAUTH2_AUTOCREATEUSER"
            value = "true"
          }
          env {
            name  = "SECURITY_OAUTH2_BLOCKREGISTRATION"
            value = "false" # the Authentik group binding is the real access gate
          }
          resources {
            # Tier-4-aux Burstable (request < limit); CPU request only (no
            # cluster-wide CPU limits). 2Gi is the metaspace floor for v2, not
            # slack — do not drop below it. Watch with krr; bump if heavy
            # OCR/office-conversion pushes past it.
            requests = {
              cpu    = "250m"
              memory = "768Mi"
            }
            limits = {
              memory = "2Gi"
            }
          }

          port {
            container_port = 8080
          }
          # JVM cold-start on a Sablier wake is ~15-25s. Without probes the pod
          # reports Ready the instant the process starts, so Sablier forwards
          # the held request into a not-yet-serving JVM → 502. startup gates a
          # ~120s boot budget; readiness keeps the pod out of the Service until
          # it serves. Probe /api/v1/info/status — the auth-free health endpoint
          # (/ is login-gated on the standard image; status stays 200 regardless).
          startup_probe {
            http_get {
              path = "/api/v1/info/status"
              port = 8080
            }
            initial_delay_seconds = 5
            period_seconds        = 3
            failure_threshold     = 40
            timeout_seconds       = 3
          }
          readiness_probe {
            http_get {
              path = "/api/v1/info/status"
              port = 8080
            }
            period_seconds    = 10
            timeout_seconds   = 3
            failure_threshold = 3
          }
          volume_mount {
            name       = "configs"
            mount_path = "/configs"
          }
        }
        volume {
          name = "configs"
          persistent_volume_claim {
            claim_name = kubernetes_persistent_volume_claim.configs_proxmox.metadata[0].name
          }
        }
      }
    }
  }
  lifecycle {
    ignore_changes = [
      spec[0].template[0].spec[0].dns_config, # KYVERNO_LIFECYCLE_V1
      # keel.sh/policy|trigger|pollSchedule are NOT ignored here — TF owns them
      # so the explicit `major` policy above reconciles over Kyverno's
      # add-if-absent `patch` default and flips the live deployment (2026-07-16).
      metadata[0].annotations["keel.sh/match-tag"],
      spec[0].template[0].spec[0].container[0].image, # KEEL_IGNORE_IMAGE — Keel manages tag updates
      metadata[0].annotations["kubernetes.io/change-cause"],
      metadata[0].annotations["deployment.kubernetes.io/revision"],
      spec[0].template[0].metadata[0].annotations["keel.sh/update-time"], # KEEL_LIFECYCLE_V1
      spec[0].replicas,                                                   # SABLIER_MANAGED_REPLICAS — sablier scales 0<->1 (ADR-0022)
    ]
  }
}

resource "kubernetes_service" "stirling-pdf" {
  metadata {
    name      = "stirling-pdf"
    namespace = kubernetes_namespace.stirling-pdf.metadata[0].name
    labels = {
      "app" = "stirling-pdf"
    }
  }

  spec {
    selector = {
      app = "stirling-pdf"
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
  # Scale-to-zero (ADR-0022): held-request wake, 3h idle park.
  sablier = {
    group = "stirling-pdf"
  }
  # auth = "app": Stirling's own login (enableLogin=true) wired to Authentik via
  # OIDC (authentik.tf) is the gate; forward-auth must NOT be in front or it
  # would intercept the OIDC callback. Access is restricted by the "Stirling PDF
  # Users" Authentik group bound to the application. (Anti-AI on by default.)
  auth            = "app"
  dns_type        = "proxied"
  namespace       = kubernetes_namespace.stirling-pdf.metadata[0].name
  name            = "stirling-pdf"
  tls_secret_name = var.tls_secret_name
  extra_annotations = {
    "gethomepage.dev/enabled"      = "true"
    "gethomepage.dev/name"         = "Stirling PDF"
    "gethomepage.dev/description"  = "PDF toolkit"
    "gethomepage.dev/icon"         = "stirling-pdf.png"
    "gethomepage.dev/group"        = "Productivity"
    "gethomepage.dev/pod-selector" = ""
  }
}

# CI retrigger 2026-05-16T13:42:57+00:00 — bulk enrollment apply (pipeline #689 killed)
# CI retrigger v2 2026-05-16T13:46:35+00:00
