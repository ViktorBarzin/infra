variable "tls_secret_name" {
  type      = string
  sensitive = true
}


resource "kubernetes_namespace" "kms" {
  metadata {
    name = "kms"
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
  namespace       = kubernetes_namespace.kms.metadata[0].name
  tls_secret_name = var.tls_secret_name
}

resource "kubernetes_deployment" "kms-web-page" {
  metadata {
    name      = "kms-web-page"
    namespace = kubernetes_namespace.kms.metadata[0].name
    labels = {
      "app"                           = "kms-web-page"
      "kubernetes.io/cluster-service" = "true"
      tier                            = local.tiers.aux
    }
  }
  spec {
    replicas = 1
    selector {
      match_labels = {
        "app" = "kms-web-page"
      }
    }
    template {
      metadata {
        labels = {
          "app"                           = "kms-web-page"
          "kubernetes.io/cluster-service" = "true"
        }
      }
      spec {
        image_pull_secrets {
          name = "registry-credentials"
        }
        container {
          image             = "ghcr.io/viktorbarzin/kms-website:${var.image_tag}"
          name              = "kms-web-page"
          image_pull_policy = "IfNotPresent"
          resources {
            limits = {
              memory = "64Mi"
            }
            requests = {
              cpu    = "10m"
              memory = "64Mi"
            }
          }
          port {
            container_port = 80
            protocol       = "TCP"
          }
        }
      }
    }
  }
  lifecycle {
    ignore_changes = [
      # KYVERNO_LIFECYCLE_V1: Kyverno admission webhook mutates dns_config with ndots=2
      spec[0].template[0].spec[0].dns_config,
      # CI (Woodpecker) manages the live image tag via `kubectl set image`
      spec[0].template[0].spec[0].container[0].image,
    ]
  }
}

resource "kubernetes_service" "kms-web-page" {
  metadata {
    name      = "kms"
    namespace = kubernetes_namespace.kms.metadata[0].name
    labels = {
      "app" = "kms-web-page"
    }
  }

  spec {
    selector = {
      "app" = "kms-web-page"
    }
    port {
      port     = "80"
      protocol = "TCP"
    }
  }
}

module "anubis" {
  source           = "../../modules/kubernetes/anubis_instance"
  name             = "kms"
  namespace        = kubernetes_namespace.kms.metadata[0].name
  target_url       = "http://${kubernetes_service.kms-web-page.metadata[0].name}.${kubernetes_namespace.kms.metadata[0].name}.svc.cluster.local"
  shared_store_url = "redis://redis-master.redis.svc.cluster.local:6379/8"
}

module "ingress" {
  source       = "../../modules/kubernetes/ingress_factory"
  auth         = "none" # Anubis-fronted; PoW challenge gates bots, no Authentik
  dns_type     = "non-proxied"
  namespace    = kubernetes_namespace.kms.metadata[0].name
  name         = "kms"
  service_name = module.anubis.service_name
  port         = module.anubis.service_port
  # Anubis binds its JWT to X-Real-Ip; the header must not reach it (flaps per
  # request across cloudflared pods for CF-tunneled traffic) — see ingress_factory.
  strip_x_real_ip   = true
  extra_middlewares = ["traefik-x402@kubernetescrd"]
  tls_secret_name   = var.tls_secret_name
  anti_ai_scraping  = false
  extra_annotations = {
    "gethomepage.dev/enabled"      = "true"
    "gethomepage.dev/name"         = "KMS"
    "gethomepage.dev/description"  = "License activation server"
    "gethomepage.dev/icon"         = "microsoft.png"
    "gethomepage.dev/group"        = "Other"
    "gethomepage.dev/pod-selector" = ""
  }
}

# Carve-out for /scripts/* and /keys.json — the PowerShell activators
# (kms-bootstrap.ps1, setup-kms.ps1) that visitors fetch with `iwr ... | iex`,
# plus /keys.json (the published GVLK list the scripts fetch to auto-select a
# key). Anubis cannot gate these paths: PowerShell/curl are non-JS clients and
# can't solve the PoW challenge, so they'd receive the challenge HTML and the
# script (or ConvertFrom-Json) would choke on it. Points at the bare
# kms-web-page nginx service, bypassing the Anubis proxy. Traefik prioritises
# the longer /scripts and /keys.json prefixes over the main "/" router.
module "ingress_scripts" {
  source = "../../modules/kubernetes/ingress_factory"
  # auth = "none": public read-only static scripts + key list (iwr|iex). No login, no PoW.
  auth             = "none"
  namespace        = kubernetes_namespace.kms.metadata[0].name
  name             = "kms-scripts"
  service_name     = kubernetes_service.kms-web-page.metadata[0].name
  port             = "80"
  ingress_path     = ["/scripts", "/keys.json"]
  full_host        = "kms.viktorbarzin.me" # MUST match the main ingress host; without this the factory derives kms-scripts.viktorbarzin.me and the carve-out never matches.
  dns_type         = "none"                # DNS already owned by the main kms ingress.
  tls_secret_name  = var.tls_secret_name
  anti_ai_scraping = false # Static scripts + key list; nothing for scrapers to mine.
}

# Anonymous diagnostics collector for the PowerShell activation scripts. The
# activators POST a tiny JSON blob (action/outcome/error) to /diag so script
# failures are captured. The collector prints each event to stdout, which Loki
# scrapes — making them searchable in Grafana. Loki only: no Slack, no
# Prometheus. Like /scripts, /diag must bypass Anubis: PowerShell/curl can't
# solve the PoW challenge, so the carve-out below points at the bare collector.
resource "kubernetes_config_map" "kms_diag_collector" {
  metadata {
    name      = "kms-diag-collector"
    namespace = kubernetes_namespace.kms.metadata[0].name
  }
  data = {
    "diag-collector.py" = file("${path.module}/files/diag-collector.py")
  }
}

resource "kubernetes_deployment" "kms_diag" {
  metadata {
    name      = "kms-diag"
    namespace = kubernetes_namespace.kms.metadata[0].name
    labels = {
      app  = "kms-diag"
      tier = local.tiers.aux
    }
  }
  spec {
    replicas = 1
    selector {
      match_labels = {
        app = "kms-diag"
      }
    }
    template {
      metadata {
        labels = {
          app = "kms-diag"
        }
        annotations = {
          # Reload pods when the collector script changes
          "checksum/collector" = sha1(file("${path.module}/files/diag-collector.py"))
        }
      }
      spec {
        volume {
          name = "diag-collector-script"
          config_map {
            name = kubernetes_config_map.kms_diag_collector.metadata[0].name
          }
        }
        container {
          image   = "python:3.12-alpine"
          name    = "diag-collector"
          command = ["python3", "/app/diag-collector.py"]
          resources {
            limits = {
              memory = "64Mi"
            }
            requests = {
              cpu    = "5m"
              memory = "48Mi"
            }
          }
          port {
            container_port = 9102
          }
          volume_mount {
            name       = "diag-collector-script"
            mount_path = "/app"
            read_only  = true
          }
        }
      }
    }
  }
  lifecycle {
    ignore_changes = [spec[0].template[0].spec[0].dns_config] # KYVERNO_LIFECYCLE_V1
  }
}

resource "kubernetes_service" "kms_diag" {
  metadata {
    name      = "kms-diag"
    namespace = kubernetes_namespace.kms.metadata[0].name
    labels = {
      app = "kms-diag"
    }
  }

  spec {
    selector = {
      app = "kms-diag"
    }
    port {
      port     = "9102"
      protocol = "TCP"
    }
  }
}

# Carve-out for /diag — the anonymous telemetry endpoint. Same rationale as
# /scripts: PowerShell/curl POSTs can't solve Anubis' PoW challenge, so this
# points at the bare kms-diag collector service. full_host MUST match the main
# ingress host; without it the factory derives kms-diag.viktorbarzin.me and the
# carve-out never matches (this exact bug hit the /scripts carve-out).
module "ingress_diag" {
  source = "../../modules/kubernetes/ingress_factory"
  # auth = "none": public telemetry collector, no login/PoW
  auth             = "none"
  namespace        = kubernetes_namespace.kms.metadata[0].name
  name             = "kms-diag"
  service_name     = kubernetes_service.kms_diag.metadata[0].name
  port             = "9102"
  ingress_path     = ["/diag"]
  full_host        = "kms.viktorbarzin.me"
  dns_type         = "none"
  tls_secret_name  = var.tls_secret_name
  anti_ai_scraping = false
}

# Dedicated KMS endpoint hostname. kms.viktorbarzin.me is the *website* (Traefik
# 10.0.20.203 internally / :443 externally) and cannot also serve raw KMS on
# :1688, so clients pointed at kms.viktorbarzin.me:1688 from the LAN hit Traefik
# (no 1688 listener) and fail with "KMS server cannot be reached". vlmcs.* is
# A-only (NO AAAA — the IPv6 tunnel doesn't forward 1688) and resolves to the
# vlmcsd MetalLB IP both ways:
#   external: vlmcs.viktorbarzin.me -> 176.12.22.76 -> pfSense WAN NAT :1688 -> 10.0.20.202
#   internal: vlmcs.viktorbarzin.me -> 10.0.20.202 (Technitium split-horizon, set via API)
resource "cloudflare_record" "vlmcs" {
  name            = "vlmcs"
  content         = "176.12.22.76" # public_ip (mirrors config.tfvars / ingress_factory default)
  proxied         = false          # raw TCP 1688 — Cloudflare proxy is HTTP-only
  ttl             = 1
  type            = "A"
  zone_id         = "fd2c5dd4efe8fe38958944e74d0ced6d" # cloudflare_zone_id
  allow_overwrite = true
}

resource "kubernetes_config_map" "kms_slack_notifier" {
  metadata {
    name      = "kms-slack-notifier"
    namespace = kubernetes_namespace.kms.metadata[0].name
  }
  data = {
    "notifier.py" = file("${path.module}/files/slack-notifier.py")
  }
}

resource "kubernetes_manifest" "kms_slack_external_secret" {
  field_manager {
    force_conflicts = true
  }
  manifest = {
    apiVersion = "external-secrets.io/v1"
    kind       = "ExternalSecret"
    metadata = {
      name      = "kms-slack-webhook"
      namespace = kubernetes_namespace.kms.metadata[0].name
    }
    spec = {
      refreshInterval = "1h"
      secretStoreRef = {
        name = "vault-kv"
        kind = "ClusterSecretStore"
      }
      target = {
        name           = "kms-slack-webhook"
        creationPolicy = "Owner"
      }
      data = [{
        secretKey = "url"
        remoteRef = {
          key      = "kms"
          property = "slack_webhook_url"
        }
      }]
    }
  }
  depends_on = [kubernetes_namespace.kms]
}

resource "kubernetes_deployment" "windows_kms" {
  metadata {
    name      = "kms"
    namespace = kubernetes_namespace.kms.metadata[0].name
    labels = {
      app  = "kms-service"
      tier = local.tiers.aux
    }
  }
  spec {
    replicas = 1
    selector {
      match_labels = {
        app = "kms-service"
      }
    }
    template {
      metadata {
        labels = {
          app = "kms-service"
        }
        annotations = {
          # Reload pods when the notifier script changes
          "checksum/notifier" = sha1(file("${path.module}/files/slack-notifier.py"))
          # Prometheus scrape — kubernetes-pods job picks up via pod IP
          "prometheus.io/scrape" = "true"
          "prometheus.io/port"   = "9101"
          "prometheus.io/path"   = "/metrics"
        }
      }
      spec {
        volume {
          name = "vlmcsd-log"
          empty_dir {}
        }
        volume {
          name = "slack-notifier-script"
          config_map {
            name = kubernetes_config_map.kms_slack_notifier.metadata[0].name
          }
        }
        container {
          image   = "kebe/vlmcsd:latest"
          name    = "windows-kms"
          command = ["/usr/bin/vlmcsd"]
          args    = ["-D", "-v", "-l", "/var/log/vlmcsd/vlmcsd.log"]
          resources {
            limits = {
              memory = "64Mi"
            }
            requests = {
              cpu    = "10m"
              memory = "64Mi"
            }
          }
          port {
            container_port = 1688
          }
          # Gate Pod Ready on the listener actually being up. Required for
          # ETP=Local: MetalLB only advertises 10.0.20.202 from a node where
          # the backing pod is Ready, so without this the pod is "Ready"
          # before vlmcsd has bound 1688 and ARP can briefly point at a node
          # that drops connections during pod start.
          readiness_probe {
            tcp_socket { port = 1688 }
            initial_delay_seconds = 1
            period_seconds        = 5
            failure_threshold     = 3
          }
          liveness_probe {
            tcp_socket { port = 1688 }
            initial_delay_seconds = 5
            period_seconds        = 30
            failure_threshold     = 3
          }
          volume_mount {
            name       = "vlmcsd-log"
            mount_path = "/var/log/vlmcsd"
          }
        }
        container {
          image   = "python:3.12-alpine"
          name    = "slack-notifier"
          command = ["python3", "-u", "/scripts/notifier.py"]
          env {
            name  = "VLMCSD_LOG"
            value = "/var/log/vlmcsd/vlmcsd.log"
          }
          env {
            name  = "SLACK_CHANNEL"
            value = "#alerts"
          }
          env {
            name  = "DEDUP_WINDOW_SECONDS"
            value = "3600"
          }
          env {
            name = "SLACK_WEBHOOK_URL"
            value_from {
              secret_key_ref {
                name = "kms-slack-webhook"
                key  = "url"
              }
            }
          }
          port {
            container_port = 9101
            name           = "metrics"
          }
          resources {
            limits = {
              memory = "64Mi"
            }
            requests = {
              cpu    = "5m"
              memory = "48Mi"
            }
          }
          volume_mount {
            name       = "vlmcsd-log"
            mount_path = "/var/log/vlmcsd"
            read_only  = true
          }
          volume_mount {
            name       = "slack-notifier-script"
            mount_path = "/scripts"
            read_only  = true
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
      spec[0].template[0].spec[0].container[1].image,
      metadata[0].annotations["kubernetes.io/change-cause"],
      metadata[0].annotations["deployment.kubernetes.io/revision"],
      spec[0].template[0].metadata[0].annotations["keel.sh/update-time"], # KEEL_LIFECYCLE_V1
    ]
  }
  depends_on = [kubernetes_manifest.kms_slack_external_secret]
}

resource "kubernetes_service" "windows_kms" {
  metadata {
    name      = "windows-kms"
    namespace = kubernetes_namespace.kms.metadata[0].name
    labels = {
      app = "kms-service"
    }
    annotations = {
      # Dedicated MetalLB IP (not shared) so ETP=Local can preserve real
      # client IPs in the vlmcsd log. Sharing 10.0.20.200 isn't an option:
      # all 10 services there are ETP=Cluster and MetalLB requires a single
      # ETP per shared IP.
      "metallb.io/loadBalancerIPs" = "10.0.20.202"
    }
  }

  spec {
    type                    = "LoadBalancer"
    external_traffic_policy = "Local"
    selector = {
      app = "kms-service"
    }
    port {
      port = "1688"
    }
  }
}

# CI retrigger 2026-05-16T13:42:57+00:00 — bulk enrollment apply (pipeline #689 killed)
# CI retrigger v2 2026-05-16T13:46:35+00:00

# CI retrigger v3 2026-05-16T14:06:39Z

# CI retrigger v4 2026-05-16T14:13:59Z

# CI retrigger v5 2026-05-16T23:10:38Z

# CI retrigger v6 2026-05-16T23:18:58Z
