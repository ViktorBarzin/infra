# proxy — on-demand per-country NordVPN remote browser.
#
# A pure-stdlib Python broker (files/broker/broker.py, ConfigMap-mounted on a
# stock python image — the chrome-broker pattern, NO custom image/GHA) serves an
# Authentik-gated country picker and, per request, creates an ephemeral Pod
# (gluetun WireGuard tunnel + headful Chromium + noVNC sharing one netns so the
# browser egresses through the tunnel) plus a per-session Service + Ingress.
#
# Least-privilege: session pods run UNPRIVILEGED with NET_ADMIN+SYS_MODULE
# (kernelspace WireGuard needs no /dev/net/tun / privileged / device-plugin;
# proven 2026-07-24), so this namespace is NOT on the Kyverno security exclude
# list. It IS on ghcr_private_namespaces (stacks/kyverno) for the private
# chrome-service-browser pull.
#
# Design: docs/plans/2026-07-24-proxy-nordvpn-design.md

variable "tls_secret_name" {
  type      = string
  sensitive = true
}

locals {
  namespace = "proxy"
  host      = "proxy.viktorbarzin.me"
  labels    = { app = "proxy" }
}

resource "kubernetes_namespace" "proxy" {
  metadata {
    name = local.namespace
    labels = {
      tier = local.tiers.aux
      # We own the ResourceQuota below; stop Kyverno generating a tier quota.
      "resource-governance/custom-quota" = "true"
    }
  }
  lifecycle {
    # KYVERNO_LIFECYCLE_V1: goldilocks-vpa-auto-mode ClusterPolicy stamps this label.
    ignore_changes = [metadata[0].labels["goldilocks.fairwinds.com/vpa-update-mode"]]
  }
}

# TLS: the wildcard `tls-secret` is auto-cloned into every namespace by the
# Kyverno sync-tls-secret ClusterPolicy (synchronize=true), so we just
# reference var.tls_secret_name by name in the ingresses — no per-stack cert.

# NordVPN access token (for re-fetching the NordLynx key at each session spawn).
resource "kubernetes_manifest" "es_secrets" {
  manifest = {
    apiVersion = "external-secrets.io/v1"
    kind       = "ExternalSecret"
    metadata = {
      name      = "proxy-secrets"
      namespace = local.namespace
    }
    spec = {
      refreshInterval = "1h"
      secretStoreRef  = { name = "vault-kv", kind = "ClusterSecretStore" }
      target          = { name = "proxy-secrets" }
      dataFrom        = [{ extract = { key = "proxy" } }]
    }
  }
  depends_on = [kubernetes_namespace.proxy]
}

# --- Broker RBAC — namespaced CRUD on the objects it manages per session ------
resource "kubernetes_service_account" "broker" {
  metadata {
    name      = "proxy-broker"
    namespace = local.namespace
  }
}

resource "kubernetes_role" "broker" {
  metadata {
    name      = "proxy-broker"
    namespace = local.namespace
  }
  rule {
    api_groups = [""]
    # pods/services/secrets: gateway + browser pods and their per-object secrets.
    # configmaps: per-gateway WireGuard peers list (the broker maintains it; the
    # gateway sidecar reconciles wg0 from it). persistentvolumeclaims: per-user
    # encrypted browser profiles. "update" is needed for PUT-replace (_apply).
    resources = ["pods", "services", "secrets", "configmaps", "persistentvolumeclaims"]
    verbs     = ["get", "list", "watch", "create", "delete", "patch", "update"]
  }
  rule {
    api_groups = [""]
    resources  = ["pods/log"]
    verbs      = ["get"]
  }
  rule {
    api_groups = ["networking.k8s.io"]
    resources  = ["ingresses"]
    verbs      = ["get", "list", "watch", "create", "delete", "patch"]
  }
}

resource "kubernetes_role_binding" "broker" {
  metadata {
    name      = "proxy-broker"
    namespace = local.namespace
  }
  role_ref {
    api_group = "rbac.authorization.k8s.io"
    kind      = "Role"
    name      = kubernetes_role.broker.metadata[0].name
  }
  subject {
    kind      = "ServiceAccount"
    name      = kubernetes_service_account.broker.metadata[0].name
    namespace = local.namespace
  }
}

# --- Static stripPrefixRegex middleware: strips /s/<token> so noVNC assets +
# WebSocket land at the session container's root. ONE middleware serves all
# sessions (regex), so the broker never creates Middleware CRs.
resource "kubectl_manifest" "strip_session" {
  yaml_body = yamlencode({
    apiVersion = "traefik.io/v1alpha1"
    kind       = "Middleware"
    metadata   = { name = "strip-session", namespace = local.namespace }
    spec       = { stripPrefixRegex = { regex = ["^/s/[^/]+"] } }
  })
  depends_on = [kubernetes_namespace.proxy]
}

resource "kubernetes_config_map_v1" "broker_scripts" {
  metadata {
    name      = "proxy-broker-scripts"
    namespace = local.namespace
    labels    = local.labels
  }
  data = {
    "broker.py"  = file("${path.module}/files/broker/broker.py")
    "pool.py"    = file("${path.module}/files/broker/pool.py")
    "wgkeys.py"  = file("${path.module}/files/broker/wgkeys.py")
    "index.html" = file("${path.module}/files/broker/index.html")
  }
}

resource "kubernetes_deployment" "broker" {
  metadata {
    name      = "proxy-broker"
    namespace = local.namespace
    labels    = merge(local.labels, { app = "proxy-broker" })
    annotations = {
      "reloader.stakater.com/auto" = "true"
    }
  }
  spec {
    replicas = 1
    strategy {
      type = "RollingUpdate"
      rolling_update {
        max_surge       = 1
        max_unavailable = 0
      }
    }
    selector {
      match_labels = { app = "proxy-broker" }
    }
    template {
      metadata {
        labels = { app = "proxy-broker" }
        annotations = {
          "prometheus.io/scrape" = "true"
          "prometheus.io/port"   = "8080"
          "prometheus.io/path"   = "/metrics"
        }
      }
      spec {
        service_account_name = kubernetes_service_account.broker.metadata[0].name
        security_context {
          run_as_user  = 1000
          run_as_group = 1000
          fs_group     = 1000
          seccomp_profile { type = "RuntimeDefault" }
        }
        container {
          name              = "broker"
          image             = "python:3.12-slim"
          image_pull_policy = "IfNotPresent"
          command           = ["python3", "-u", "/broker/broker.py"]
          env {
            name  = "NAMESPACE"
            value = local.namespace
          }
          env {
            name  = "HOST"
            value = local.host
          }
          env {
            name  = "TLS_SECRET"
            value = var.tls_secret_name
          }
          # Reap a country gateway (freeing its NordVPN tunnel slot) after it has
          # carried no browsers for this long. Browsers themselves are persistent
          # (no deadline) — the profile PVC survives regardless.
          env {
            name  = "GW_IDLE_SECONDS"
            value = "600"
          }
          # Pin the KasmVNC browser image to the immutable commit-SHA tag, NOT
          # :latest — the ghcr pull-through cache serves a stale :latest, so a
          # freshly-built :latest doesn't reach new browser pods (house SHA-tag
          # convention). Bump this to the newest build's SHA after rebuilding
          # stacks/proxy/files/kasmvnc/**.
          env {
            name  = "KASMVNC_IMAGE"
            value = "ghcr.io/viktorbarzin/proxy-kasmvnc-browser:8d2a113c2b7bed5afde656df75f56a2094544c1c"
          }
          env {
            name  = "PORT"
            value = "8080"
          }
          env {
            name = "NORDVPN_TOKEN"
            value_from {
              secret_key_ref {
                name = "proxy-secrets"
                key  = "nordvpn_token"
              }
            }
          }
          port {
            name           = "http"
            container_port = 8080
            protocol       = "TCP"
          }
          liveness_probe {
            http_get {
              path = "/healthz"
              port = 8080
            }
            initial_delay_seconds = 15
            period_seconds        = 30
          }
          readiness_probe {
            http_get {
              path = "/healthz"
              port = 8080
            }
            initial_delay_seconds = 5
            period_seconds        = 10
          }
          volume_mount {
            name       = "broker"
            mount_path = "/broker"
            read_only  = true
          }
          resources {
            requests = { cpu = "20m", memory = "64Mi" }
            limits   = { memory = "192Mi" }
          }
        }
        volume {
          name = "broker"
          config_map {
            name         = kubernetes_config_map_v1.broker_scripts.metadata[0].name
            default_mode = "0555"
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
  depends_on = [kubernetes_manifest.es_secrets]
}

resource "kubernetes_service" "broker" {
  metadata {
    name      = "proxy-broker"
    namespace = local.namespace
    labels    = merge(local.labels, { app = "proxy-broker" })
  }
  spec {
    selector = { app = "proxy-broker" }
    port {
      name        = "http"
      port        = 8080
      target_port = 8080
      protocol    = "TCP"
    }
  }
}

# UI + API ingress — Authentik-gated (the broker has no auth of its own). The
# per-session noVNC ingresses the broker creates (/s/<token>, auth=none, higher
# router priority) are separate and route around this "/" router.
module "ingress" {
  source          = "../../modules/kubernetes/ingress_factory"
  dns_type        = "proxied"
  namespace       = kubernetes_namespace.proxy.metadata[0].name
  name            = "proxy"
  host            = "proxy"
  service_name    = kubernetes_service.broker.metadata[0].name
  port            = 8080
  tls_secret_name = var.tls_secret_name
  # Authentik forward-auth gates the UI + API: the broker keys each user's own
  # persistent browser + encrypted profile on the X-authentik-username identity
  # header, so login is required (re-gated 2026-07-25 for the per-user scale-up,
  # infra#81 — greenfield, no users to disrupt). The per-session noVNC ingresses
  # the broker creates (/s/<token>) stay auth=none — an Authentik forward-auth
  # breaks the noVNC WebSocket — gated instead by the unguessable per-user token.
  auth = "required"
  extra_annotations = {
    "gethomepage.dev/enabled"     = "true"
    "gethomepage.dev/name"        = "Proxy"
    "gethomepage.dev/description" = "Remote browser via NordVPN, any country"
    "gethomepage.dev/icon"        = "chromium.png"
    "gethomepage.dev/group"       = "Infrastructure"
  }
}

# Namespace quota: broker + up to ~6 country gateways (each ~130Mi req across
# gluetun+wgserver) + up to ~10 user browsers (each ~1.7Gi req / ~3.5Gi lim
# across gluetun+chrome+novnc). count/pods is the runaway-create backstop; the
# broker self-limits countries to MAX_COUNTRIES-RESERVED (pool.py), browsers are
# one-per-user; requests.memory bounds a full house.
resource "kubernetes_resource_quota" "proxy" {
  metadata {
    name      = "proxy"
    namespace = local.namespace
  }
  spec {
    hard = {
      "requests.cpu"    = "4"
      "requests.memory" = "20Gi"
      "limits.memory"   = "40Gi"
      "count/pods"      = "28"
    }
  }
}

# Gateway pods request the net.ipv4.ip_forward unsafe sysctl, which the kubelet
# only allows on the general workers node2-5 (allowedUnsafeSysctls, infra#81 —
# NOT master/GPU-node1). A pod requesting it elsewhere is rejected SysctlForbidden,
# so we label those nodes and nodeSelector gateways onto them. kubernetes_labels
# manages only this one label (coexists with node's other labels).
resource "kubernetes_labels" "gateway_nodes" {
  for_each    = toset(["k8s-node2", "k8s-node3", "k8s-node4", "k8s-node5"])
  api_version = "v1"
  kind        = "Node"
  metadata {
    name = each.value
  }
  labels = {
    "proxy.viktorbarzin.me/gateway" = "true"
  }
}
