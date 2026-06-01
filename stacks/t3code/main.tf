variable "tls_secret_name" {
  type      = string
  sensitive = true
}

resource "kubernetes_namespace" "t3code" {
  metadata {
    name = "t3code"
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

# TLS secret `tls-secret` (wildcard *.viktorbarzin.me) is auto-cloned into this
# namespace by Kyverno's `sync-tls-secret` ClusterPolicy — no local module or
# cert material needed; the renewal pipeline updates the source and Kyverno
# propagates within seconds.

# === Per-user dispatch =======================================================
# t3 is single-owner (no in-app multi-user), so each person runs their OWN
# `t3 serve` instance on the DevVM as their own OS user:
#   wizard (vbarzin)     -> 10.0.10.10:3773  (t3-serve.service,     ~/.t3)
#   emo    (emil.barzin) -> 10.0.10.10:3774  (t3-serve-emo.service, ~/.t3)
# This nginx routes a single hostname (t3.viktorbarzin.me) to the right
# instance by the Authentik identity, mirroring the terminal stack's
# /etc/ttyd-user-map model. Authentik forward-auth (auth="required" below)
# injects X-authentik-username; nginx maps it to the user's upstream. The
# header is trustworthy because forward-auth overwrites any client-supplied
# value, and unauthenticated requests never reach nginx (302'd at the edge).
# Unmapped identities get 403 (no shared fallback — same as the terminal).
locals {
  t3_dispatch_nginx_conf = <<-EOT
    events {}
    http {
      map $http_x_authentik_username $t3_upstream {
        vbarzin      10.0.10.10:3773;
        emil.barzin  10.0.10.10:3774;
        default      "";
      }
      map $http_upgrade $connection_upgrade {
        default upgrade;
        ''      close;
      }
      server {
        listen 80;
        # health endpoint for k8s probes (no identity needed)
        location = /healthz {
          access_log off;
          return 200 "ok\n";
        }
        location / {
          if ($t3_upstream = "") {
            return 403 "No t3 instance is provisioned for this Authentik user.\n";
          }
          proxy_pass http://$t3_upstream;
          proxy_http_version 1.1;
          proxy_set_header Upgrade $http_upgrade;
          proxy_set_header Connection $connection_upgrade;
          proxy_set_header Host $host;
          proxy_set_header X-Real-IP $remote_addr;
          proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
          proxy_set_header X-Forwarded-Proto $scheme;
          proxy_read_timeout 3600s;
          proxy_send_timeout 3600s;
        }
      }
    }
  EOT
}

resource "kubernetes_config_map_v1" "t3_dispatch" {
  metadata {
    name      = "t3-dispatch-nginx"
    namespace = kubernetes_namespace.t3code.metadata[0].name
  }
  data = {
    "nginx.conf" = local.t3_dispatch_nginx_conf
  }
}

resource "kubernetes_deployment_v1" "t3_dispatch" {
  metadata {
    name      = "t3-dispatch"
    namespace = kubernetes_namespace.t3code.metadata[0].name
    labels    = { app = "t3-dispatch" }
  }
  spec {
    replicas = 1
    selector {
      match_labels = { app = "t3-dispatch" }
    }
    template {
      metadata {
        labels = { app = "t3-dispatch" }
        annotations = {
          # roll the pod when the nginx config changes
          "checksum/config" = sha256(local.t3_dispatch_nginx_conf)
        }
      }
      spec {
        container {
          name  = "nginx"
          image = "docker.io/library/nginx:1.27-alpine"
          port {
            container_port = 80
          }
          volume_mount {
            name       = "conf"
            mount_path = "/etc/nginx/nginx.conf"
            sub_path   = "nginx.conf"
          }
          resources {
            requests = {
              cpu    = "10m"
              memory = "32Mi"
            }
            limits = {
              memory = "64Mi"
            }
          }
          liveness_probe {
            http_get {
              path = "/healthz"
              port = 80
            }
            initial_delay_seconds = 5
            period_seconds        = 30
          }
          readiness_probe {
            http_get {
              path = "/healthz"
              port = 80
            }
            initial_delay_seconds = 2
            period_seconds        = 10
          }
        }
        volume {
          name = "conf"
          config_map {
            name = kubernetes_config_map_v1.t3_dispatch.metadata[0].name
          }
        }
      }
    }
  }
  lifecycle {
    # KYVERNO_LIFECYCLE_V1: Kyverno injects dns_config on all pods
    ignore_changes = [spec[0].template[0].spec[0].dns_config]
  }
}

resource "kubernetes_service_v1" "t3_dispatch" {
  metadata {
    name      = "t3-dispatch"
    namespace = kubernetes_namespace.t3code.metadata[0].name
    labels    = { app = "t3-dispatch" }
  }
  spec {
    selector = { app = "t3-dispatch" }
    port {
      name        = "http"
      port        = 80
      target_port = 80
    }
  }
}

module "ingress" {
  source          = "../../modules/kubernetes/ingress_factory"
  dns_type        = "proxied"
  namespace       = kubernetes_namespace.t3code.metadata[0].name
  name            = "t3"
  service_name    = kubernetes_service_v1.t3_dispatch.metadata[0].name
  tls_secret_name = var.tls_secret_name
  # Authentik forward-auth gates t3.viktorbarzin.me and injects
  # X-authentik-username, which the t3-dispatch nginx (above) maps to each
  # user's own `t3 serve` instance on the DevVM — per-user isolation mirroring
  # the terminal stack. The same-origin self-served UI works behind forward-auth
  # (WS carries the Authentik cookie); t3's own pairing/bearer is the inner gate.
  # Cross-origin clients (native app / app.t3.codes) are intentionally NOT
  # supported here — deferred until the native app is published.
  auth = "required"
  extra_annotations = {
    "gethomepage.dev/enabled"      = "true"
    "gethomepage.dev/name"         = "T3 Code"
    "gethomepage.dev/description"  = "Coding-agent GUI (t3 serve on DevVM)"
    "gethomepage.dev/icon"         = "mdi-robot"
    "gethomepage.dev/group"        = "Infrastructure"
    "gethomepage.dev/pod-selector" = ""
  }
}
