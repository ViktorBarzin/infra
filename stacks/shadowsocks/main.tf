variable "method" {
  default = "chacha20-ietf-poly1305"
}

resource "kubernetes_namespace" "shadowsocks" {
  metadata {
    name = "shadowsocks"
    labels = {
      tier = local.tiers.edge
    }
    # TLS termination seems iffy - I get pfsense MiTM-ing
    # labels = {
    #   "istio-injection" : "enabled"
    # }
  }
  lifecycle {
    # KYVERNO_LIFECYCLE_V1: goldilocks-vpa-auto-mode ClusterPolicy stamps this label on every namespace
    ignore_changes = [metadata[0].labels["goldilocks.fairwinds.com/vpa-update-mode"]]
  }
}

resource "kubernetes_manifest" "external_secret" {
  manifest = {
    apiVersion = "external-secrets.io/v1beta1"
    kind       = "ExternalSecret"
    metadata = {
      name      = "shadowsocks-secrets"
      namespace = "shadowsocks"
    }
    spec = {
      refreshInterval = "15m"
      secretStoreRef = {
        name = "vault-kv"
        kind = "ClusterSecretStore"
      }
      target = {
        name = "shadowsocks-secrets"
      }
      dataFrom = [{
        extract = {
          key = "shadowsocks"
        }
      }]
    }
  }
  depends_on = [kubernetes_namespace.shadowsocks]
}

resource "kubernetes_deployment" "shadowsocks" {
  metadata {
    name      = "shadowsocks"
    namespace = kubernetes_namespace.shadowsocks.metadata[0].name
    labels = {
      "app" = "shadowsocks"
      tier  = local.tiers.edge
    }
    annotations = {
      "reloader.stakater.com/auto" = "true"
    }
  }
  spec {
    replicas = "1"
    selector {
      match_labels = {
        "app" = "shadowsocks"
      }
    }
    template {
      metadata {
        labels = {
          "app" = "shadowsocks"
        }
        annotations = {
          "diun.enable"       = "true"
          "diun.include_tags" = "^v\\d+\\.\\d+\\.\\d+$"
        }
      }
      spec {
        container {
          name              = "shadowsocks"
          image             = "shadowsocks/shadowsocks-libev:v3.3.5"
          image_pull_policy = "IfNotPresent"
          env {
            name  = "METHOD"
            value = var.method
          }
          env {
            name = "PASSWORD"
            value_from {
              secret_key_ref {
                name = "shadowsocks-secrets"
                key  = "password"
              }
            }
          }
          port {
            container_port = 8388
            protocol       = "TCP"
          }
          port {
            container_port = 8388
            protocol       = "UDP"
          }
          resources {
            requests = {
              cpu    = "10m"
              memory = "64Mi"
            }
            limits = {
              memory = "64Mi"
            }
          }
        }
      }
    }
  }
}

resource "kubernetes_service" "mailserver" { # rename me
  metadata {
    name      = "shadowsocks"
    namespace = kubernetes_namespace.shadowsocks.metadata[0].name

    labels = {
      app = "shadowsocks"
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
      app = "shadowsocks"
    }

    port {
      name        = "shadowsocks-tcp"
      protocol    = "TCP"
      port        = 8388
      target_port = "8388"
    }

    port {
      name        = "shadowsocks-udp"
      protocol    = "UDP"
      port        = 8388
      target_port = "8388"
    }
  }
}
