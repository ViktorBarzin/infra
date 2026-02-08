variable "tier" { type = string }
variable "crowdsec_api_key" { type = string }
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
      insecure = true
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
      dns-udp = {
        port        = 5353
        exposedPort = 53
        protocol    = "UDP"
        expose      = { default = true }
      }
      whisper-tcp = {
        port        = 10300
        exposedPort = 10300
        protocol    = "TCP"
        expose      = { default = true }
      }
    }

    service = {
      type = "LoadBalancer"
      annotations = {
        # Temporary IP during migration; will move to nginx's 10.0.20.202 once nginx is removed
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
        rewritebody = {
          moduleName = "github.com/traefik/plugin-rewritebody"
          version    = "v0.3.1"
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
      "--api.insecure=true",
      "--global.checknewversion=false",
      "--global.sendanonymoususage=false",
      # Skip TLS verification for self-signed backend certs (proxmox, idrac, etc.)
      "--serversTransport.insecureSkipVerify=true",
      # Increase timeouts for services like Immich
      "--serversTransport.forwardingTimeouts.dialTimeout=60s",
      "--serversTransport.forwardingTimeouts.responseHeaderTimeout=0s",
      "--serversTransport.forwardingTimeouts.idleConnTimeout=90s",
      # Use forwarded headers from trusted proxies
      "--entryPoints.websecure.forwardedHeaders.insecure=true",
      "--entryPoints.web.forwardedHeaders.insecure=true",
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

# DNS UDP passthrough to Technitium
resource "kubernetes_manifest" "dns_udp_ingressroute" {
  manifest = {
    apiVersion = "traefik.io/v1alpha1"
    kind       = "IngressRouteUDP"
    metadata = {
      name      = "dns-udp"
      namespace = kubernetes_namespace.traefik.metadata[0].name
    }
    spec = {
      entryPoints = ["dns-udp"]
      routes = [{
        services = [{
          name      = "technitium-dns"
          namespace = "technitium"
          port      = 53
        }]
      }]
    }
  }

  depends_on = [helm_release.traefik]
}

# Dashboard resources
module "tls_secret" {
  source          = "../setup_tls_secret"
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
  source          = "../ingress_factory"
  namespace       = kubernetes_namespace.traefik.metadata[0].name
  name            = "traefik"
  service_name    = "traefik-dashboard"
  host            = "traefik"
  port            = 8080
  tls_secret_name = var.tls_secret_name
  protected       = true
}
