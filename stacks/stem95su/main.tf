# STEM educational platform for 95. СУ „Проф. Иван Шишманов" (Sofia).
# Public, open static site at stem95su.viktorbarzin.me. Self-contained HTML
# pages + media authored externally (Gemini exports), served by a stock nginx
# straight off the PVE host NFS — NOT baked into an image, so content can be
# updated out-of-band (Nextcloud "PVE NFS Pool" or rsync to /srv/nfs/stem-site)
# without a rebuild. Auto-backed-up offsite by the existing nfs-mirror job.

resource "kubernetes_namespace" "stem95su" {
  metadata {
    name = "stem95su"
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
  namespace       = kubernetes_namespace.stem95su.metadata[0].name
  tls_secret_name = var.tls_secret_name
}

# Content lives on the PVE host NFS. NOTE: the nfs_volume module creates only
# the K8s PV+PVC — the export subdir (/srv/nfs/stem-site) must already exist on
# 192.168.1.127 or the pod fails to mount (mount.nfs exit 32). It is created
# during deploy and re-created on demand if ever lost.
module "nfs_content" {
  source       = "../../modules/kubernetes/nfs_volume"
  name         = "stem95su-content"
  namespace    = kubernetes_namespace.stem95su.metadata[0].name
  nfs_server   = var.nfs_server
  nfs_path     = "/srv/nfs/stem-site"
  storage      = "1Gi"
  access_modes = ["ReadWriteMany"]
}

# Minimal nginx server block: serve the static dir, with the dashboard
# (stem_board.html) as the directory index so "/" loads the platform home.
# All other pages/assets are reached by their exact filenames (the dashboard
# links to them by name — those must not be renamed).
resource "kubernetes_config_map" "nginx_conf" {
  metadata {
    name      = "stem95su-nginx-conf"
    namespace = kubernetes_namespace.stem95su.metadata[0].name
  }
  data = {
    "default.conf" = <<-EOT
      server {
          listen       80;
          server_name  _;
          root   /usr/share/nginx/html;
          index  stem_board.html index.html;
      }
    EOT
  }
}

resource "kubernetes_deployment" "stem95su" {
  metadata {
    name      = "stem95su"
    namespace = kubernetes_namespace.stem95su.metadata[0].name
    labels = {
      run  = "stem95su"
      tier = local.tiers.aux
    }
  }
  spec {
    replicas = 1
    selector {
      match_labels = {
        run = "stem95su"
      }
    }
    template {
      metadata {
        labels = {
          run = "stem95su"
        }
      }
      spec {
        container {
          image = "nginx:1.28-alpine"
          name  = "nginx"
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
          }
          volume_mount {
            name       = "content"
            mount_path = "/usr/share/nginx/html"
            read_only  = true
          }
          volume_mount {
            name       = "nginx-conf"
            mount_path = "/etc/nginx/conf.d"
            read_only  = true
          }
          readiness_probe {
            http_get {
              path = "/"
              port = 80
            }
            initial_delay_seconds = 3
            period_seconds        = 10
          }
        }
        volume {
          name = "content"
          persistent_volume_claim {
            claim_name = module.nfs_content.claim_name
          }
        }
        volume {
          name = "nginx-conf"
          config_map {
            name = kubernetes_config_map.nginx_conf.metadata[0].name
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
}

resource "kubernetes_service" "stem95su" {
  metadata {
    name      = "stem95su"
    namespace = kubernetes_namespace.stem95su.metadata[0].name
    labels = {
      run = "stem95su"
    }
  }
  spec {
    selector = {
      run = "stem95su"
    }
    port {
      name        = "http"
      port        = "80"
      target_port = "80"
    }
  }
}

module "ingress" {
  source = "../../modules/kubernetes/ingress_factory"
  # auth = "none": public static educational site for 95. СУ, open to the internet by design — CrowdSec + ai-bot-block gate bots; no login.
  auth            = "none"
  namespace       = kubernetes_namespace.stem95su.metadata[0].name
  name            = "stem95su"
  service_name    = kubernetes_service.stem95su.metadata[0].name
  port            = "80"
  host            = "stem95su"
  dns_type        = "proxied"
  tls_secret_name = var.tls_secret_name
}
