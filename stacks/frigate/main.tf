variable "tls_secret_name" {
  type      = string
  sensitive = true
}
variable "nfs_server" { type = string }


resource "kubernetes_namespace" "frigate" {
  metadata {
    name = "frigate"
    labels = {
      tier = local.tiers.gpu
    }
    # labels = {
    #   "istio-injection" : "enabled"
    # }
  }
}

module "tls_secret" {
  source          = "../../modules/kubernetes/setup_tls_secret"
  namespace       = kubernetes_namespace.frigate.metadata[0].name
  tls_secret_name = var.tls_secret_name
}

resource "kubernetes_persistent_volume_claim" "config_encrypted" {
  wait_until_bound = false
  metadata {
    name      = "frigate-config-encrypted"
    namespace = kubernetes_namespace.frigate.metadata[0].name
    annotations = {
      "resize.topolvm.io/threshold"     = "80%"
      "resize.topolvm.io/increase"      = "100%"
      "resize.topolvm.io/storage_limit" = "5Gi"
    }
  }
  spec {
    access_modes       = ["ReadWriteOnce"]
    storage_class_name = "proxmox-lvm-encrypted"
    resources {
      requests = {
        storage = "1Gi"
      }
    }
  }
}

module "nfs_media_host" {
  source     = "../../modules/kubernetes/nfs_volume"
  name       = "frigate-media-host"
  namespace  = kubernetes_namespace.frigate.metadata[0].name
  nfs_server = "192.168.1.127"
  nfs_path   = "/srv/nfs/frigate/media"
}

resource "kubernetes_deployment" "frigate" {
  metadata {
    name      = "frigate"
    namespace = kubernetes_namespace.frigate.metadata[0].name
    labels = {
      app  = "frigate"
      tier = local.tiers.gpu
    }
    annotations = {
      "reloader.stakater.com/search" = "true"
    }
  }
  spec {
    replicas = 1 # Temporarily disabled due to high power consumption
    strategy {
      type = "Recreate"
    }
    selector {
      match_labels = {
        app = "frigate"
      }
    }
    template {
      metadata {
        labels = {
          app = "frigate"
        }
      }
      spec {
        node_selector = {
          "gpu" : true
        }
        toleration {
          key      = "nvidia.com/gpu"
          operator = "Equal"
          value    = "true"
          effect   = "NoSchedule"
        }
        container {
          # image = "ghcr.io/blakeblackshear/frigate:stable"
          # image = "ghcr.io/blakeblackshear/frigate:stable-tensorrt"
          image = "ghcr.io/blakeblackshear/frigate:0.17.0-beta1-tensorrt"
          name  = "frigate"

          resources {
            requests = {
              cpu    = "1500m"
              memory = "5Gi"
            }
            limits = {
              memory           = "10Gi"
              "nvidia.com/gpu" = "1"
            }
          }
          env {
            name  = "FRIGATE_RTSP_PASSWORD"
            value = "password"
          }
          port {
            container_port = 5000
          }
          port {
            container_port = 8554
          }
          port {
            container_port = 8555
            protocol       = "TCP"
          }
          port {
            container_port = 8555
            protocol       = "UDP"
          }
          volume_mount {
            name       = "config"
            mount_path = "/config"
          }
          volume_mount {
            name       = "dri"
            mount_path = "/dev/dri"
          }
          volume_mount {
            name       = "dshm"
            mount_path = "/dev/shm"
          }
          volume_mount {
            name       = "media"
            mount_path = "/media/frigate"
          }
          volume_mount {
            name       = "cache-tmpfs"
            mount_path = "/tmp/cache"
          }
          # Restart pod if GPU becomes unavailable, Frigate hangs, or
          # detector falls back to CPU (inference time spikes from ~20ms to 200ms+)
          liveness_probe {
            exec {
              command = ["sh", "-c", <<-EOT
                nvidia-smi > /dev/null 2>&1 || exit 1
                STATS=$(curl -sf --max-time 5 http://localhost:5000/api/stats) || exit 1
                echo "$STATS" | python3 -c "
import sys, json
stats = json.load(sys.stdin)
for name, det in stats.get('detectors', {}).items():
    speed = det.get('inference_speed', 0)
    if speed > 100:
        print(f'UNHEALTHY: detector {name} inference {speed}ms > 100ms threshold')
        sys.exit(1)
"
              EOT
              ]
            }
            initial_delay_seconds = 120
            period_seconds        = 60
            timeout_seconds       = 10
            failure_threshold     = 3
          }
          # TensorRT model loading can take several minutes
          startup_probe {
            http_get {
              path = "/api/version"
              port = 5000
            }
            period_seconds    = 10
            failure_threshold = 30 # up to 5 minutes for startup
          }
          security_context {
            privileged = true
          }
        }

        volume {
          name = "config"
          persistent_volume_claim {
            claim_name = kubernetes_persistent_volume_claim.config_encrypted.metadata[0].name
          }
        }
        volume {
          name = "dshm"
          empty_dir {
            medium     = "Memory"
            size_limit = "1Gi"
          }
        }
        volume {
          name = "media"
          persistent_volume_claim {
            claim_name = module.nfs_media_host.claim_name
          }
        }
        volume {
          name = "cache-tmpfs"
          empty_dir {
            medium     = "Memory"
            size_limit = "512Mi"
          }
        }
        volume {
          name = "dri"
          host_path {
            path = "/dev/dri"
            type = "Directory"
          }
        }
      }
    }
  }
}

resource "kubernetes_service" "frigate" {
  metadata {
    name      = "frigate"
    namespace = kubernetes_namespace.frigate.metadata[0].name
    labels = {
      "app" = "frigate"
    }
  }

  spec {
    selector = {
      app = "frigate"
    }
    port {
      name        = "http"
      target_port = 5000
      port        = 80
      protocol    = "TCP"
    }
  }
}

resource "kubernetes_service" "frigate-rtsp" {
  metadata {
    name      = "frigate-rtsp"
    namespace = kubernetes_namespace.frigate.metadata[0].name
    labels = {
      "app" = "frigate"
    }
  }

  spec {
    type = "NodePort" # Should always live on node1 where the gpu is
    selector = {
      app = "frigate"
    }
    port {
      name        = "rtsp-tcp"
      target_port = 8554
      port        = 8554
      protocol    = "TCP"
      node_port   = 30554
    }
    port {
      name        = "rtsp-udp"
      target_port = 8554
      port        = 8554
      protocol    = "UDP"
      node_port   = 30554
    }
  }
}

module "ingress" {
  source          = "../../modules/kubernetes/ingress_factory"
  namespace       = kubernetes_namespace.frigate.metadata[0].name
  name            = "frigate"
  tls_secret_name = var.tls_secret_name
  protected       = true
  rybbit_site_id  = "0d4044069ff5"
  extra_annotations = {
    "gethomepage.dev/enabled"      = "true"
    "gethomepage.dev/name"         = "Frigate"
    "gethomepage.dev/description"  = "NVR & object detection"
    "gethomepage.dev/icon"         = "frigate.png"
    "gethomepage.dev/group"        = "Media & Entertainment"
    "gethomepage.dev/pod-selector" = ""
    "gethomepage.dev/widget.type"  = "frigate"
    "gethomepage.dev/widget.url"   = "http://frigate.frigate.svc.cluster.local"
  }
}

module "ingress-internal" {
  source                  = "../../modules/kubernetes/ingress_factory"
  namespace               = kubernetes_namespace.frigate.metadata[0].name
  name                    = "frigate-lan"
  host                    = "frigate-lan"
  root_domain             = "viktorbarzin.lan"
  service_name            = "frigate"
  tls_secret_name         = var.tls_secret_name
  allow_local_access_only = true
  ssl_redirect            = false
  extra_annotations = {
    "gethomepage.dev/enabled" = "false"
  }
}
