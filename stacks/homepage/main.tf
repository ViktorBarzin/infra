variable "tls_secret_name" {
  type      = string
  sensitive = true
}


module "tls_secret" {
  source          = "../../modules/kubernetes/setup_tls_secret"
  namespace       = kubernetes_namespace.homepage.metadata[0].name
  tls_secret_name = var.tls_secret_name
}

resource "kubernetes_namespace" "homepage" {
  metadata {
    name = "homepage"
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

resource "helm_release" "homepage" {
  namespace        = kubernetes_namespace.homepage.metadata[0].name
  create_namespace = false
  name             = "homepage"
  atomic           = true

  repository = "http://jameswynn.github.io/helm-charts"
  chart      = "homepage"

  values = [file("${path.module}/values.yaml")]
}

# --- Caching proxy: nginx in front of Homepage for stale-while-revalidate on /api/ ---

resource "kubernetes_config_map" "cache_proxy" {
  metadata {
    name      = "homepage-cache-config"
    namespace = kubernetes_namespace.homepage.metadata[0].name
  }
  data = {
    "default.conf" = <<-EOT
      proxy_cache_path /tmp/cache levels=1:2 keys_zone=hp:10m max_size=500m inactive=24h;

      server {
        listen 80;
        resolver kube-dns.kube-system.svc.cluster.local valid=5s;
        set $upstream http://homepage.homepage.svc.cluster.local:3000;

        location /api/ {
          proxy_pass $upstream;
          proxy_cache hp;
          proxy_cache_valid 200 24h;
          proxy_cache_use_stale updating error timeout;
          proxy_cache_background_update on;
          proxy_cache_lock on;
          proxy_cache_key "$request_uri";
          proxy_set_header Host $host;
          proxy_next_upstream error timeout http_500 http_502 http_503;
          proxy_next_upstream_tries 3;
          add_header X-Cache-Status $upstream_cache_status;
        }

        location / {
          proxy_pass $upstream;
          proxy_set_header Host $host;
          proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
          proxy_set_header X-Forwarded-Proto $scheme;
          proxy_buffering off;
        }
      }
    EOT
  }
}

resource "kubernetes_deployment" "cache_proxy" {
  metadata {
    name      = "homepage-cache"
    namespace = kubernetes_namespace.homepage.metadata[0].name
  }
  spec {
    replicas = 1
    selector {
      match_labels = { app = "homepage-cache" }
    }
    template {
      metadata {
        labels = { app = "homepage-cache" }
      }
      spec {
        container {
          name  = "nginx"
          image = "nginx:alpine"
          port {
            container_port = 80
          }
          resources {
            requests = { cpu = "10m", memory = "64Mi" }
            limits   = { memory = "64Mi" }
          }
          volume_mount {
            name       = "config"
            mount_path = "/etc/nginx/conf.d"
          }
        }
        volume {
          name = "config"
          config_map {
            name = kubernetes_config_map.cache_proxy.metadata[0].name
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

resource "kubernetes_service" "cache_proxy" {
  metadata {
    name      = "homepage-cache"
    namespace = kubernetes_namespace.homepage.metadata[0].name
  }
  spec {
    selector = { app = "homepage-cache" }
    port {
      port        = 80
      target_port = 80
    }
  }
}

module "ingress" {
  source          = "../../modules/kubernetes/ingress_factory"
  namespace       = kubernetes_namespace.homepage.metadata[0].name
  name            = "homepage"
  host            = "home"
  dns_type        = "proxied"
  service_name    = kubernetes_service.cache_proxy.metadata[0].name
  tls_secret_name = var.tls_secret_name
  extra_annotations = {
    "gethomepage.dev/enabled"     = "true"
    "gethomepage.dev/name"        = "Homepage"
    "gethomepage.dev/description" = "Service dashboard"
    "gethomepage.dev/group"       = "Core Platform"
    "gethomepage.dev/icon"        = "homepage.png"
  }
}
