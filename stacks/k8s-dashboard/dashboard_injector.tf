# Dashboard token-injector: auto-inject each user's ServiceAccount token so they
# never see the dashboard's "paste token" prompt.
#
# Flow: ingress (auth=required → Authentik forward-auth injects X-authentik-username
# = the user's email) → THIS nginx → maps username → that user's SA token → sets
# `Authorization: Bearer <token>` → kong-proxy → dashboard auto-authenticates with
# the token → per-namespace RBAC applies.
#
# Why this and not OIDC SSO: the apiserver rejects all Authentik OIDC tokens (see
# docs/plans/2026-06-04-k8s-dashboard-sso-design.md §12); SA tokens DO work. Mirrors
# the proven t3-dispatch pattern (X-authentik-username → per-user backend).
#
# SECURITY: the username→token map lives in a SECRET (not a ConfigMap) — the
# namespace-owner cluster-read-only role covers configmaps but NOT secrets, so a
# namespace-owner cannot read other users' tokens. Forward-auth overwrites
# X-authentik-* (anti-spoofing), so a client can't forge another user's identity.

locals {
  k8s_users_injector = jsondecode(data.vault_kv_secret_v2.cf_platform.data["k8s_users"])

  # namespace-owner email -> their per-namespace dashboard SA token Secret
  # (created by stacks/rbac/modules/rbac/dashboard-sa.tf). One namespace per
  # owner today; uses the first namespace if several.
  dashboard_owners = {
    for name, u in local.k8s_users_injector :
    u.email => {
      namespace = u.namespaces[0]
      secret    = "dashboard-${name}-token"
    }
    if u.role == "namespace-owner" && length(try(u.namespaces, [])) > 0
  }

  # Admins (real Authentik usernames = email) → cluster-admin dashboard SA token.
  # Hardcoded: admin k8s_users emails (e.g. viktor@viktorbarzin.me) do NOT match
  # the actual Authentik login identity, so they're listed explicitly here.
  dashboard_admin_emails = ["vbarzin@gmail.com"]
}

# Long-lived token for the cluster-admin `kubernetes-dashboard` SA (for admins).
resource "kubernetes_secret" "dashboard_admin_token" {
  metadata {
    name      = "kubernetes-dashboard-admin-token"
    namespace = kubernetes_namespace.k8s-dashboard.metadata[0].name
    annotations = {
      "kubernetes.io/service-account.name" = kubernetes_service_account.kubernetes-dashboard.metadata[0].name
    }
  }
  type                           = "kubernetes.io/service-account-token"
  wait_for_service_account_token = true
}

# Read each namespace-owner's SA token (created by the rbac stack).
data "kubernetes_secret" "owner_token" {
  for_each = nonsensitive(local.dashboard_owners)
  metadata {
    name      = each.value.secret
    namespace = each.value.namespace
  }
}

locals {
  injector_map_lines = concat(
    [for email, info in local.dashboard_owners : "    \"${email}\" \"${data.kubernetes_secret.owner_token[email].data["token"]}\";"],
    [for email in local.dashboard_admin_emails : "    \"${email}\" \"${kubernetes_secret.dashboard_admin_token.data["token"]}\";"],
  )

  injector_nginx_conf = <<-NGINX
    map $http_upgrade $connection_upgrade { default upgrade; "" close; }

    map $http_x_authentik_username $dash_sa_token {
        default "";
    ${join("\n", local.injector_map_lines)}
    }

    map $dash_sa_token $dash_auth_hdr {
        ""      "";
        default "Bearer $dash_sa_token";
    }

    server {
        listen 8080;
        client_max_body_size 50m;

        location / {
            proxy_pass https://kubernetes-dashboard-kong-proxy.kubernetes-dashboard.svc.cluster.local:443;
            proxy_ssl_server_name on;
            proxy_ssl_verify off;

            # Inject the authenticated user's SA token; strip any client-supplied one.
            proxy_set_header Authorization $dash_auth_hdr;

            proxy_set_header Host $host;
            proxy_set_header X-Forwarded-Proto $scheme;
            proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;

            proxy_http_version 1.1;
            proxy_set_header Upgrade $http_upgrade;
            proxy_set_header Connection $connection_upgrade;
            proxy_read_timeout 3600s;
            proxy_buffer_size 16k;
            proxy_buffers 8 16k;
        }
    }
  NGINX
}

resource "kubernetes_secret" "dashboard_injector_conf" {
  metadata {
    name      = "dashboard-token-injector-conf"
    namespace = kubernetes_namespace.k8s-dashboard.metadata[0].name
  }
  data = {
    "default.conf" = local.injector_nginx_conf
  }
}

resource "kubernetes_deployment" "dashboard_injector" {
  metadata {
    name      = "dashboard-token-injector"
    namespace = kubernetes_namespace.k8s-dashboard.metadata[0].name
    labels    = { app = "dashboard-token-injector" }
  }
  spec {
    replicas = 2
    selector { match_labels = { app = "dashboard-token-injector" } }
    template {
      metadata {
        labels = { app = "dashboard-token-injector" }
        # Roll the pods when the token map changes (hash is non-secret).
        annotations = { "conf/sha" = nonsensitive(sha256(local.injector_nginx_conf)) }
      }
      spec {
        container {
          name  = "nginx"
          image = "nginxinc/nginx-unprivileged:1.27-alpine"
          port { container_port = 8080 }
          volume_mount {
            name       = "conf"
            mount_path = "/etc/nginx/conf.d"
            read_only  = true
          }
          resources {
            requests = { cpu = "10m", memory = "32Mi" }
            limits   = { memory = "96Mi" }
          }
          readiness_probe {
            tcp_socket { port = 8080 }
            initial_delay_seconds = 3
            period_seconds        = 10
          }
        }
        volume {
          name = "conf"
          secret {
            secret_name = kubernetes_secret.dashboard_injector_conf.metadata[0].name
          }
        }
        dns_config {
          option {
            name  = "ndots"
            value = "2"
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

resource "kubernetes_service" "dashboard_injector" {
  metadata {
    name      = "dashboard-token-injector"
    namespace = kubernetes_namespace.k8s-dashboard.metadata[0].name
  }
  spec {
    selector = { app = "dashboard-token-injector" }
    port {
      port        = 80
      target_port = 8080
    }
  }
}
