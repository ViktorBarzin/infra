variable "tls_secret_name" {}

module "tls_secret" {
  source          = "../setup_tls_secret"
  namespace       = "nvidia"
  tls_secret_name = var.tls_secret_name
}

resource "kubernetes_namespace" "nvidia" {
  metadata {
    name = "nvidia"
    labels = {
      "istio-injection" : "disabled"
    }
  }
}

# Apply to operator with:
# kubectl patch clusterpolicies.nvidia.com/cluster-policy -n gpu-operator --type merge -p '{"spec": {"devicePlugin": {"config": {"name": "time-slicing-config", "default": "any"}}}}'

resource "kubernetes_config_map" "time_slicing_config" {
  metadata {
    name      = "time-slicing-config"
    namespace = "nvidia"
  }

  data = {
    any = <<-EOF
      flags:
        migStrategy: none
      sharing:
        timeSlicing:
          renameByDefault: false
          failRequestsGreaterThanOne: false
          resources:
            - name: nvidia.com/gpu
              replicas: 10
    EOF
  }
}

resource "helm_release" "nvidia-gpu-operator" {
  namespace = "nvidia"
  name      = "nvidia-gpu-operator"

  repository = "https://helm.ngc.nvidia.com/nvidia"
  chart      = "gpu-operator"
  atomic     = true
  #   version    = "0.9.3"
  timeout = 6000

  values = [templatefile("${path.module}/values.yaml", {})]
}

resource "kubernetes_deployment" "nvidia-exporter" {
  metadata {
    name      = "nvidia-exporter"
    namespace = "nvidia"
    labels = {
      app = "nvidia-exporter"
    }
  }
  spec {
    replicas = 1
    selector {
      match_labels = {
        app = "nvidia-exporter"
      }
    }
    template {
      metadata {
        labels = {
          app = "nvidia-exporter"
        }
      }
      spec {
        node_selector = {
          "gpu" : "true"
        }
        container {
          image = "nvidia/dcgm-exporter:latest"
          name  = "nvidia-exporter"
          port {
            container_port = 9400
          }
          port {
            container_port = 9400
          }
          security_context {
            privileged = true
            capabilities {
              add = ["SYS_ADMIN"]
            }
          }
          resources {
            limits = {
              "nvidia.com/gpu" = "1"
            }
          }
        }
      }
    }
  }
}

resource "kubernetes_service" "nvidia-exporter" {
  metadata {
    name      = "nvidia-exporter"
    namespace = "nvidia"
    labels = {
      "app" = "nvidia-exporter"
    }
  }

  spec {
    selector = {
      app = "nvidia-exporter"
    }
    port {
      name        = "http"
      port        = 80
      target_port = 9400
    }
  }
}


module "ingress" {
  source                  = "../ingress_factory"
  namespace               = "nvidia"
  name                    = "nvidia-exporter"
  root_domain             = "viktorbarzin.lan"
  tls_secret_name         = var.tls_secret_name
  allow_local_access_only = true
  ssl_redirect            = false
}

# resource "kubernetes_ingress_v1" "nvidia-exporter" {
#   metadata {
#     name      = "nvidia-exporter"
#     namespace = "nvidia"
#     annotations = {
#       "kubernetes.io/ingress.class" = "nginx"
#       "nginx.ingress.kubernetes.io/whitelist-source-range" : "192.168.1.0/24, 10.0.0.0/8"
#       "nginx.ingress.kubernetes.io/ssl-redirect" : "false" # used only in LAN

#     }
#   }
#   spec {
#     tls {
#       hosts       = ["nvidia-exporter.viktorbarzin.lan"]
#       secret_name = var.tls_secret_name
#     }
#     rule {
#       host = "nvidia-exporter.viktorbarzin.lan"
#       http {
#         path {
#           backend {
#             service {
#               name = "nvidia-exporter"
#               port {
#                 number = 80
#               }
#             }
#           }
#         }
#       }
#     }
#   }
# }
