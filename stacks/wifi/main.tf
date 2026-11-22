variable "image_tag" {
  type        = string
  default     = "latest" # used only when the Deployment is created; CI sets the running tag
  description = "Image tag used when the Deployment is (re)created. The running tag is set by the Woodpecker deploy (kubectl set image)."
}
variable "postgresql_host" { type = string }
variable "tls_secret_name" {
  type      = string
  sensitive = true
}
variable "cloudflare_zone_id" { type = string }

# wifi: the London Wi-Fi role manager (Forgejo viktor/wifi,
# docs/plans/2026-11-22-london-network-roles-design.md). Every London device is
# a guest until it has a role. People sign in here to give the device they are
# on their role, Viktor moves any device, and the London Flint long-polls
# /api/router/roles for the list (scripts/london-flint/london-roles).
#
# Vault KV secret/wifi holds better_auth_secret, oidc_client_id,
# oidc_client_secret and router_token (the Flint's bearer token, also written to
# the router by provision.sh), seeded by hand on 2026-11-22.
locals {
  # Dedicated MetalLB IP with externalTrafficPolicy Local, so the proxy sees
  # each London device's own address (nothing NATs London traffic to 10/8).
  # Every London role may reach this IP, and only this IP is the sign-in page:
  # the shared Traefik IP stays closed to guests, whose 192.168.8.0/24 source
  # would pass Traefik's local-only allowlist.
  lb_ip = "10.0.20.215"
  host  = "wifi.viktorbarzin.me"
}

module "app" {
  source = "../../modules/kubernetes/tanstack_app"

  name         = "wifi"
  display_name = "London Wi-Fi"
  tier         = local.tiers.aux

  image     = "ghcr.io/viktorbarzin/wifi"
  image_tag = var.image_tag

  postgresql_host = var.postgresql_host
  tls_secret_name = var.tls_secret_name

  app_secret_env = { ROUTER_TOKEN = "router_token" }

  # The groups are the roles: admins = london-admin (all of Sofia), users =
  # london-storage (the 192.168.1.13 share). The app maps them itself.
  users_group  = "london-storage"
  admins_group = "london-admin"
  # Admins are not members by default, so Viktor is seeded into both.
  initial_user_pks  = [data.authentik_user.viktor.id, data.authentik_user.anca.id]
  admin_user_pks    = [data.authentik_user.viktor.id]
  reader_managed_by = "infra/stacks/wifi/authentik.tf"

  # The proxy below runs in this namespace and forwards to the app.
  ingress_from_namespaces = ["traefik", "wifi"]

  # The Traefik ingress stays for use from Sofia; the public name points at
  # the proxy's own IP (cloudflare_dns_record.wifi), which shadows the wildcard.
  ingress = {
    dns_type             = "none"
    homepage_description = "London Wi-Fi device roles"
    homepage_icon        = "mdi-wifi-lock"
    homepage_group       = "Infrastructure"
  }
}

# --- Sign-in proxy on its own IP ---
# nginx terminates TLS with the wildcard certificate and passes the client's
# own address in X-Real-IP, which the app maps to a MAC from the Flint's lease
# table. It holds the router's 50 s long poll, so the read timeout is 70 s.
resource "kubernetes_config_map" "proxy" {
  metadata {
    name      = "wifi-proxy"
    namespace = module.app.namespace
  }
  data = {
    "default.conf" = <<-EOT
      server {
        listen 8443 ssl;
        http2 on;
        server_name ${local.host};
        ssl_certificate     /tls/tls.crt;
        ssl_certificate_key /tls/tls.key;
        client_max_body_size 1m;
        location / {
          proxy_pass http://wifi.wifi.svc.cluster.local:3000;
          proxy_http_version 1.1;
          proxy_set_header Host $host;
          proxy_set_header X-Real-IP $remote_addr;
          proxy_set_header X-Forwarded-For $remote_addr;
          proxy_set_header X-Forwarded-Proto https;
          proxy_read_timeout 70s;
          proxy_buffering off;
        }
      }
    EOT
  }
}

resource "kubernetes_deployment" "proxy" {
  metadata {
    name      = "wifi-proxy"
    namespace = module.app.namespace
    labels    = { app = "wifi-proxy" }
    annotations = {
      "reloader.stakater.com/auto" = "true"
    }
  }
  spec {
    replicas = 1
    selector {
      match_labels = { app = "wifi-proxy" }
    }
    template {
      metadata {
        labels = { app = "wifi-proxy" }
      }
      spec {
        container {
          name  = "nginx"
          image = "nginx:1.31.9"
          port {
            name           = "https"
            container_port = 8443
          }
          resources {
            requests = { cpu = "5m", memory = "16Mi" }
            limits   = { memory = "64Mi" }
          }
          readiness_probe {
            tcp_socket {
              port = 8443
            }
            period_seconds = 10
          }
          volume_mount {
            name       = "conf"
            mount_path = "/etc/nginx/conf.d"
            read_only  = true
          }
          volume_mount {
            name       = "tls"
            mount_path = "/tls"
            read_only  = true
          }
        }
        volume {
          name = "conf"
          config_map {
            name = kubernetes_config_map.proxy.metadata[0].name
          }
        }
        volume {
          name = "tls"
          secret {
            secret_name = var.tls_secret_name
          }
        }
      }
    }
  }
  lifecycle {
    ignore_changes = [spec[0].template[0].spec[0].dns_config] # KYVERNO_LIFECYCLE_V1
  }
}

resource "kubernetes_service" "proxy" {
  metadata {
    name      = "wifi-proxy"
    namespace = module.app.namespace
    annotations = {
      "metallb.io/loadBalancerIPs" = local.lb_ip
    }
  }
  spec {
    type                    = "LoadBalancer"
    external_traffic_policy = "Local"
    selector                = { app = "wifi-proxy" }
    port {
      name        = "https"
      port        = 443
      target_port = 8443
    }
  }
  lifecycle {
    ignore_changes = [metadata[0].annotations["metallb.io/ip-allocated-from-pool"]]
  }
}

# Public A record with the private address: it resolves everywhere and routes
# only from the home sites, like ingress_factory's "internal" type.
resource "cloudflare_dns_record" "wifi" {
  name    = "wifi"
  content = local.lb_ip
  proxied = false
  ttl     = 1
  type    = "A"
  zone_id = var.cloudflare_zone_id
}
