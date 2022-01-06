# Create reverse proxy for external ip
# e.g internet -> k8s -> ip on lan, external to k8s

resource "kubernetes_service" "openwrt" {
  metadata {
    name      = "external-ip"
    namespace = "website"
    labels = {
      "run" = "external-ip"
    }
    annotations = {
      # "prometheus.io/scrape" = "true"
      # "prometheus.io/path"   = "/metrics"
      # "prometheus.io/port"   = "9113"
    }
  }

  spec {
    port {
      name        = "app"
      port        = "443"
      target_port = "5001"
      protocol    = "TCP"
    }
    cluster_ip       = "None"
    type             = "ClusterIP"
    session_affinity = "None"
  }
}

# kind: Endpoints
# apiVersion: v1
# metadata:
#   name: external-ip
#   namespace: default
# subsets:
#   - addresses:
#       - ip: 192.168.1.1
#     ports:
#       - name: app
#         port: 443
#         protocol: TCP

resource "kubernetes_ingress_v1" "openwrt" {
  metadata {
    name      = "openwrt-ingress"
    namespace = "website"
    annotations = {
      "nginx.ingress.kubernetes.io/backend-protocol" = "https"
    }
  }

  spec {
    tls {
      hosts       = ["home.viktorbarzin.me"]
      secret_name = var.tls_secret_name
    }
    rule {
      host = "home.viktorbarzin.me"
      http {
        path {
          path = "/"
          backend {
            service_name = "external-ip"
            service_port = "443"
          }
        }
      }
    }
  }
}
