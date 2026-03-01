variable "tier" { type = string }
variable "crowdsec_api_key" { type = string }
variable "redis_host" { type = string }
variable "tls_secret_name" {}

resource "kubernetes_namespace" "traefik" {
  metadata {
    name = "traefik"
    labels = {
      "app.kubernetes.io/name"     = "traefik"
      "app.kubernetes.io/instance" = "traefik"
      tier                         = var.tier
    }
  }
}

resource "helm_release" "traefik" {
  namespace        = kubernetes_namespace.traefik.metadata[0].name
  create_namespace = false
  name             = "traefik"
  repository       = "https://traefik.github.io/charts"
  chart            = "traefik"
  atomic           = true
  timeout          = 600

  values = [yamlencode({
    deployment = {
      replicas = 3
      podAnnotations = {
        "diun.enable"       = "true"
        "diun.include_tags" = "^v\\d+(?:\\.\\d+)?(?:\\.\\d+)?.*$"
      }
      initContainers = [{
        name  = "download-plugins"
        image = "alpine:3"
        command = ["sh", "-c", join("", [
          "set -e; ",
          "STORAGE=/plugins-storage; ",
          "mkdir -p \"$STORAGE/archives/github.com/maxlerebourg/crowdsec-bouncer-traefik-plugin\"; ",
          "mkdir -p \"$STORAGE/archives/github.com/packruler/rewrite-body\"; ",
          "wget -q -T 30 -O \"$STORAGE/archives/github.com/maxlerebourg/crowdsec-bouncer-traefik-plugin/v1.4.2.zip\" ",
          "\"https://github.com/maxlerebourg/crowdsec-bouncer-traefik-plugin/archive/refs/tags/v1.4.2.zip\"; ",
          "wget -q -T 30 -O \"$STORAGE/archives/github.com/packruler/rewrite-body/v1.2.0.zip\" ",
          "\"https://github.com/packruler/rewrite-body/archive/refs/tags/v1.2.0.zip\"; ",
          "printf '{\"github.com/maxlerebourg/crowdsec-bouncer-traefik-plugin\":\"v1.4.2\",\"github.com/packruler/rewrite-body\":\"v1.2.0\"}' ",
          "> \"$STORAGE/archives/state.json\"; ",
          "echo \"Plugins pre-downloaded successfully\"",
        ])]
        volumeMounts = [{
          name      = "plugins"
          mountPath = "/plugins-storage"
        }]
      }]
    }

    updateStrategy = {
      type = "RollingUpdate"
      rollingUpdate = {
        maxUnavailable = 1
        maxSurge       = 2
      }
    }

    ingressClass = {
      enabled        = true
      isDefaultClass = true
    }

    providers = {
      kubernetesIngress = {
        enabled                   = true
        allowExternalNameServices = true
        publishedService          = { enabled = true }
      }
      kubernetesCRD = {
        enabled                   = true
        allowExternalNameServices = true
        allowCrossNamespace       = true
      }
    }

    # Enable dashboard API (accessible on port 8080 internally)
    api = {
      insecure = false
    }

    # Entrypoints
    ports = {
      web = {
        port        = 8000
        exposedPort = 80
        protocol    = "TCP"
        http = {
          redirections = {
            entryPoint = {
              to     = "websecure"
              scheme = "https"
            }
          }
        }
      }
      websecure = {
        port        = 8443
        exposedPort = 443
        protocol    = "TCP"
        http = {
          tls = {
            enabled = true
          }
        }
        http3 = {
          enabled        = true
          advertisedPort = 443
        }
      }
      whisper-tcp = {
        port        = 10300
        exposedPort = 10300
        protocol    = "TCP"
        expose      = { default = true }
      }
      piper-tcp = {
        port        = 10200
        exposedPort = 10200
        protocol    = "TCP"
        expose      = { default = true }
      }
      ollama-tcp = {
        port        = 11434
        exposedPort = 11434
        protocol    = "TCP"
        expose      = { default = true }
      }
    }

    service = {
      type = "LoadBalancer"
      annotations = {
        "metallb.universe.tf/loadBalancerIPs" = "10.0.20.202"
      }
      spec = {
        externalTrafficPolicy = "Local"
      }
    }

    # Plugins
    experimental = {
      plugins = {
        crowdsec-bouncer = {
          moduleName = "github.com/maxlerebourg/crowdsec-bouncer-traefik-plugin"
          version    = "v1.4.2"
        }
        rewrite-body = {
          moduleName = "github.com/packruler/rewrite-body"
          version    = "v1.2.0"
        }
      }
    }

    # Prometheus metrics
    metrics = {
      prometheus = {
        entryPoint           = "metrics"
        addEntryPointsLabels = true
        addServicesLabels    = true
        addRoutersLabels     = true
      }
    }

    # Access logs
    logs = {
      access = {
        enabled = true
      }
    }

    additionalArguments = [
      "--global.checknewversion=false",
      "--global.sendanonymoususage=false",
      # Skip TLS verification for self-signed backend certs (proxmox, idrac, etc.)
      "--serversTransport.insecureSkipVerify=true",
      # Increase timeouts for services like Immich
      "--serversTransport.forwardingTimeouts.dialTimeout=60s",
      "--serversTransport.forwardingTimeouts.responseHeaderTimeout=0s",
      "--serversTransport.forwardingTimeouts.idleConnTimeout=90s",
      # Use forwarded headers from trusted proxies
      "--entryPoints.websecure.forwardedHeaders.insecure=false",
      "--entryPoints.web.forwardedHeaders.insecure=false",
      "--entryPoints.websecure.forwardedHeaders.trustedIPs=173.245.48.0/20,103.21.244.0/22,103.22.200.0/22,103.31.4.0/22,141.101.64.0/18,108.162.192.0/18,190.93.240.0/20,188.114.96.0/20,197.234.240.0/22,198.41.128.0/17,162.158.0.0/15,104.16.0.0/13,104.24.0.0/14,172.64.0.0/13,131.0.72.0/22,10.0.0.0/8,192.168.0.0/16",
      "--entryPoints.web.forwardedHeaders.trustedIPs=173.245.48.0/20,103.21.244.0/22,103.22.200.0/22,103.31.4.0/22,141.101.64.0/18,108.162.192.0/18,190.93.240.0/20,188.114.96.0/20,197.234.240.0/22,198.41.128.0/17,162.158.0.0/15,104.16.0.0/13,104.24.0.0/14,172.64.0.0/13,131.0.72.0/22,10.0.0.0/8,192.168.0.0/16",
    ]

    resources = {
      requests = {
        cpu    = "100m"
        memory = "128Mi"
      }
    }

    nodeSelector = {
      "kubernetes.io/os" = "linux"
    }

    tolerations = []
  })]
}

# Dashboard resources
module "tls_secret" {
  source          = "../../../../modules/kubernetes/setup_tls_secret"
  namespace       = kubernetes_namespace.traefik.metadata[0].name
  tls_secret_name = var.tls_secret_name
}

resource "kubernetes_service" "traefik_dashboard" {
  metadata {
    name      = "traefik-dashboard"
    namespace = kubernetes_namespace.traefik.metadata[0].name
    labels = {
      "app" = "traefik-dashboard"
    }
  }

  spec {
    selector = {
      "app.kubernetes.io/name" = "traefik"
    }
    port {
      name        = "http"
      port        = 8080
      target_port = 8080
      protocol    = "TCP"
    }
  }
}

module "ingress" {
  source          = "../../../../modules/kubernetes/ingress_factory"
  namespace       = kubernetes_namespace.traefik.metadata[0].name
  name            = "traefik"
  service_name    = "traefik-dashboard"
  host            = "traefik"
  port            = 8080
  tls_secret_name = var.tls_secret_name
  protected       = true
}
