# FORGEJO TURNSTILE CANARY (48 h A/B test, started 2026-10-15).
#
# Question: does Cloudflare Turnstile stop the commit-page crawler (real
# Chrome 155, ~17,800 new residential IPs a day, ~3 s per IP) that already
# solves Anubis? Half of the untrusted IPs (HMAC of X-Real-Ip, IPv6 by /64)
# get a Turnstile page in front of Anubis; the other half get Anubis exactly
# as before. The readout compares how often the crawler gets through in each
# arm. Design and decision rule: docs/agents/ingress.md, "Turnstile canary".
#
# Request path on forgejo.viktorbarzin.me (middlewares listed in
# stacks/forgejo extra_middlewares, after real-ip):
#   strip   deletes any client-sent X-Turnstile-Pass, so only the gate sets it
#   auth    forwardAuth -> nginx shim -> gate /auth
#   Anubis  ALLOWs when X-Turnstile-Pass: 1 (rule allow-turnstile-pass)
#
# Fails open: the shim turns a gate timeout or 5xx into a plain 200, and the
# visitor gets Anubis as before. The shim itself is the one hard dependency
# (forwardAuth to a dead address is a 500), hence two replicas and a PDB.
#
# ROLLBACK ORDER MATTERS. Remove the two middlewares and the Anubis rule from
# stacks/forgejo and apply that FIRST; only then destroy this stack. Traefik
# drops a router whose middleware does not exist, so destroying this stack
# first would take forgejo's whole web UI down.

variable "tls_secret_name" {
  type      = string
  sensitive = true
}

locals {
  name   = "turnstile-gate"
  host   = "forgejo.viktorbarzin.me"
  action = "forgejo-gate"
  # Not a secret: it only decides which arm an IP lands in, and the crawler
  # cannot choose its residential IPs. Picked so the UK VPN egress IPs seen on
  # 2026-10-15 (185.28.252.79, 91.196.221.4) land in the Turnstile arm, which
  # lets the rollout be checked from an untrusted address we control.
  arm_salt = "forgejo-canary-2026-10-15-3"
  # Mirrors var.trusted_local_cidrs in modules/kubernetes/anubis_instance.
  trusted_cidrs = ["10.0.0.0/8", "172.16.0.0/12", "192.168.0.0/16", "100.64.0.0/10", "fc00::/7", "fe80::/10"]
  gate_labels   = { app = local.name }
  shim_labels   = { app = "${local.name}-shim" }
}

data "cloudflare_accounts" "main" {}

# Managed mode: Cloudflare decides per visitor whether a checkbox is needed.
resource "cloudflare_turnstile_widget" "forgejo_gate" {
  account_id = data.cloudflare_accounts.main.accounts[0].id
  name       = "forgejo-gate"
  domains    = [local.host]
  mode       = "managed"
}

resource "random_password" "cookie_key" {
  length  = 48
  special = false
}

resource "kubernetes_namespace" "gate" {
  metadata {
    name = local.name
    labels = {
      "istio-injection" : "disabled"
      # edge, not aux: every forgejo request passes through the shim.
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
  namespace       = kubernetes_namespace.gate.metadata[0].name
  tls_secret_name = var.tls_secret_name
}

resource "kubernetes_secret" "gate" {
  metadata {
    name      = local.name
    namespace = kubernetes_namespace.gate.metadata[0].name
  }
  data = {
    "turnstile-secret" = cloudflare_turnstile_widget.forgejo_gate.secret
    "cookie-key"       = random_password.cookie_key.result
  }
}

resource "kubernetes_config_map" "gate" {
  metadata {
    name      = local.name
    namespace = kubernetes_namespace.gate.metadata[0].name
  }
  data = {
    "gate.py" = file("${path.module}/files/gate.py")
  }
}

resource "kubernetes_deployment" "gate" {
  metadata {
    name      = local.name
    namespace = kubernetes_namespace.gate.metadata[0].name
    labels    = local.gate_labels
  }
  spec {
    replicas = 2
    selector {
      match_labels = local.gate_labels
    }
    template {
      metadata {
        labels = local.gate_labels
        annotations = {
          # Roll the pods when the script changes.
          "turnstile-gate/gate-sha" = sha256(file("${path.module}/files/gate.py"))
        }
      }
      spec {
        topology_spread_constraint {
          max_skew           = 1
          topology_key       = "kubernetes.io/hostname"
          when_unsatisfiable = "ScheduleAnyway"
          label_selector {
            match_labels = local.gate_labels
          }
        }
        container {
          name    = "gate"
          image   = "python:3.12-slim"
          command = ["python3", "-u", "/app/gate.py"]
          env {
            name  = "TURNSTILE_SITEKEY"
            value = cloudflare_turnstile_widget.forgejo_gate.id
          }
          env {
            name = "TURNSTILE_SECRET"
            value_from {
              secret_key_ref {
                name = kubernetes_secret.gate.metadata[0].name
                key  = "turnstile-secret"
              }
            }
          }
          env {
            name = "COOKIE_KEY"
            value_from {
              secret_key_ref {
                name = kubernetes_secret.gate.metadata[0].name
                key  = "cookie-key"
              }
            }
          }
          env {
            name  = "ARM_SALT"
            value = local.arm_salt
          }
          env {
            name  = "GATE_HOST"
            value = local.host
          }
          env {
            name  = "TURNSTILE_ACTION"
            value = local.action
          }
          env {
            name  = "TRUSTED_CIDRS"
            value = join(",", local.trusted_cidrs)
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
              cpu    = "25m"
              memory = "48Mi"
            }
            limits = {
              memory = "128Mi"
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
    namespace = kubernetes_namespace.gate.metadata[0].name
    labels    = local.gate_labels
  }
  spec {
    selector = local.gate_labels
    port {
      name        = "http"
      port        = 80
      target_port = 8080
    }
  }
}

resource "kubernetes_pod_disruption_budget_v1" "gate" {
  metadata {
    name      = local.name
    namespace = kubernetes_namespace.gate.metadata[0].name
  }
  spec {
    min_available = 1
    selector {
      match_labels = local.gate_labels
    }
  }
}

# The fail-open shim, same idea as bot_block_proxy_config in
# stacks/traefik/modules/traefik/main.tf: the gate's own 403 passes through,
# anything the gate cannot answer becomes a plain 200 (Anubis as before).
# Writes never reach the gate at all; Anubis already allows every non-GET.
resource "kubernetes_config_map" "shim" {
  metadata {
    name      = "${local.name}-shim"
    namespace = kubernetes_namespace.gate.metadata[0].name
  }
  data = {
    "default.conf" = <<-EOT
      upstream gate {
          server ${kubernetes_service.gate.metadata[0].name}.${kubernetes_namespace.gate.metadata[0].name}.svc.cluster.local:80;
          keepalive 16;
      }
      server {
          listen 8080;
          # Same reason as bot-block-proxy: browsers carry large cookie piles
          # for *.viktorbarzin.me, and forwardAuth passes them all through.
          client_header_buffer_size 8k;
          large_client_header_buffers 8 256k;
          access_log off;

          location = /auth {
              if ($http_x_forwarded_method !~ ^(GET|HEAD)$) {
                  return 200;
              }
              proxy_pass http://gate/auth;
              proxy_http_version 1.1;
              proxy_set_header Connection "";
              proxy_pass_request_body off;
              proxy_set_header Content-Length "";
              proxy_connect_timeout 1s;
              proxy_send_timeout 3s;
              proxy_read_timeout 3s;
              proxy_intercept_errors on;
              error_page 500 502 503 504 = @open;
          }
          location @open {
              return 200;
          }
          location = /healthz {
              return 200 "ok";
          }
      }
    EOT
  }
}

resource "kubernetes_deployment" "shim" {
  metadata {
    name      = "${local.name}-shim"
    namespace = kubernetes_namespace.gate.metadata[0].name
    labels    = local.shim_labels
  }
  spec {
    replicas = 2
    selector {
      match_labels = local.shim_labels
    }
    template {
      metadata {
        labels = local.shim_labels
        annotations = {
          # nginx does not reload a ConfigMap-mounted config on its own.
          "turnstile-gate/shim-sha" = sha256(kubernetes_config_map.shim.data["default.conf"])
        }
      }
      spec {
        topology_spread_constraint {
          max_skew           = 1
          topology_key       = "kubernetes.io/hostname"
          when_unsatisfiable = "ScheduleAnyway"
          label_selector {
            match_labels = local.shim_labels
          }
        }
        container {
          name  = "nginx"
          image = "nginx:1.31.7"
          port {
            container_port = 8080
          }
          volume_mount {
            name       = "conf"
            mount_path = "/etc/nginx/conf.d"
            read_only  = true
          }
          readiness_probe {
            http_get {
              path = "/healthz"
              port = 8080
            }
            period_seconds = 5
          }
          liveness_probe {
            http_get {
              path = "/healthz"
              port = 8080
            }
            period_seconds = 10
          }
          resources {
            requests = {
              cpu    = "10m"
              memory = "16Mi"
            }
            limits = {
              memory = "64Mi"
            }
          }
        }
        volume {
          name = "conf"
          config_map {
            name = kubernetes_config_map.shim.metadata[0].name
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

resource "kubernetes_service" "shim" {
  metadata {
    name      = "${local.name}-shim"
    namespace = kubernetes_namespace.gate.metadata[0].name
    labels    = local.shim_labels
  }
  spec {
    selector = local.shim_labels
    port {
      name        = "http"
      port        = 8080
      target_port = 8080
    }
  }
}

resource "kubernetes_pod_disruption_budget_v1" "shim" {
  metadata {
    name      = "${local.name}-shim"
    namespace = kubernetes_namespace.gate.metadata[0].name
  }
  spec {
    min_available = 1
    selector {
      match_labels = local.shim_labels
    }
  }
}

# Referenced from stacks/forgejo as turnstile-gate-strip@kubernetescrd.
# An empty value makes Traefik delete the header.
resource "kubernetes_manifest" "strip" {
  manifest = {
    apiVersion = "traefik.io/v1alpha1"
    kind       = "Middleware"
    metadata = {
      name      = "strip"
      namespace = kubernetes_namespace.gate.metadata[0].name
    }
    spec = {
      headers = {
        customRequestHeaders = {
          "X-Turnstile-Pass" = ""
        }
      }
    }
  }
}

# Referenced from stacks/forgejo as turnstile-gate-auth@kubernetescrd.
resource "kubernetes_manifest" "auth" {
  manifest = {
    apiVersion = "traefik.io/v1alpha1"
    kind       = "Middleware"
    metadata = {
      name      = "auth"
      namespace = kubernetes_namespace.gate.metadata[0].name
    }
    spec = {
      forwardAuth = {
        address = "http://${kubernetes_service.shim.metadata[0].name}.${kubernetes_namespace.gate.metadata[0].name}.svc.cluster.local:8080/auth"
        # The challenge page is ~3 KB; 1 MiB matches authentik-forward-auth.
        maxResponseBodySize = 1048576
        authResponseHeaders = ["X-Turnstile-Pass"]
      }
    }
  }
}

# /_gate/verify and /_gate/fallback, called by the challenge page on the same
# host. Forgejo user and org names must start with a letter or digit, so no
# Forgejo route can begin with /_gate/. Traefik prefers the longer path, so
# this beats forgejo's "/" ingress. dns_type = "none": the forgejo ingress
# owns the record.
module "ingress" {
  source = "../../modules/kubernetes/ingress_factory"
  # auth = "none": the Turnstile verify endpoint has to be reachable before any login, that is its job
  auth              = "none"
  dns_type          = "none"
  namespace         = kubernetes_namespace.gate.metadata[0].name
  name              = "forgejo-gate"
  full_host         = local.host
  ingress_path      = ["/_gate/"]
  service_name      = kubernetes_service.gate.metadata[0].name
  port              = 80
  tls_secret_name   = var.tls_secret_name
  extra_middlewares = ["traefik-real-ip@kubernetescrd"]
  homepage_enabled  = false
  external_monitor  = false
}
