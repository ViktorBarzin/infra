variable "tls_secret_name" {
  type      = string
  sensitive = true
}


resource "kubernetes_namespace" "kms" {
  metadata {
    name = "kms"
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
          image             = "forgejo.viktorbarzin.me/viktor/kms-website:${var.image_tag}"
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
  source            = "../../modules/kubernetes/ingress_factory"
  auth              = "none" # Anubis-fronted; PoW challenge gates bots, no Authentik
  dns_type          = "non-proxied"
  namespace         = kubernetes_namespace.kms.metadata[0].name
  name              = "kms"
  service_name      = module.anubis.service_name
  port              = module.anubis.service_port
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
  manifest = {
    apiVersion = "external-secrets.io/v1beta1"
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
    # KYVERNO_LIFECYCLE_V1: Kyverno admission webhook mutates dns_config with ndots=2
    ignore_changes = [spec[0].template[0].spec[0].dns_config]
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
