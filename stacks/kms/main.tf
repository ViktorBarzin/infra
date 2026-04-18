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

resource "kubernetes_config_map" "kms-web-page" {
  metadata {
    name      = "kms-web-page-config"
    namespace = kubernetes_namespace.kms.metadata[0].name
  }
  data = {
    "index.html" = var.index_html
  }
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
        container {
          image             = "nginx"
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
          volume_mount {
            name       = "config"
            mount_path = "/usr/share/nginx/html/"
          }
        }

        volume {
          name = "config"
          config_map {
            name = "kms-web-page-config"
            items {
              key  = "index.html"
              path = "index.html"
            }
          }
        }
      }
    }
  }
  depends_on = [kubernetes_config_map.kms-web-page]
  lifecycle {
    # KYVERNO_LIFECYCLE_V1: Kyverno admission webhook mutates dns_config with ndots=2
    ignore_changes = [spec[0].template[0].spec[0].dns_config]
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

module "ingress" {
  source          = "../../modules/kubernetes/ingress_factory"
  dns_type        = "proxied"
  namespace       = kubernetes_namespace.kms.metadata[0].name
  name            = "kms"
  tls_secret_name = var.tls_secret_name
  extra_annotations = {
    "gethomepage.dev/enabled"      = "true"
    "gethomepage.dev/name"         = "KMS"
    "gethomepage.dev/description"  = "License activation server"
    "gethomepage.dev/icon"         = "microsoft.png"
    "gethomepage.dev/group"        = "Other"
    "gethomepage.dev/pod-selector" = ""
  }
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
      }
      spec {
        container {
          image = "kebe/vlmcsd:latest"
          name  = "windows-kms"
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
        }
      }
    }
  }
  lifecycle {
    # KYVERNO_LIFECYCLE_V1: Kyverno admission webhook mutates dns_config with ndots=2
    ignore_changes = [spec[0].template[0].spec[0].dns_config]
  }
}

resource "kubernetes_service" "windows_kms" {
  metadata {
    name      = "windows-kms"
    namespace = kubernetes_namespace.kms.metadata[0].name
    labels = {
      app = "kms-service"
    }
    annotations = {
      "metallb.io/loadBalancerIPs" = "10.0.20.200"
      "metallb.io/allow-shared-ip" = "shared"
    }
  }

  spec {
    type                    = "LoadBalancer"
    external_traffic_policy = "Cluster"
    selector = {
      app = "kms-service"
    }
    port {
      port = "1688"
    }
  }
}
