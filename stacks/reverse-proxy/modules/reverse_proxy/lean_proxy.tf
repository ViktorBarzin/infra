# lean-proxy: an allowlist hop between Traefik and small-buffer devices.
#
# The TP-Link Archer AX6000 behind gw.viktorbarzin.me answers
# "413 Request Entity Too Large" when a request carries more than 32 header
# fields, and separately when its header block reaches 4,096 bytes (measured
# on the LAN 2026-09-22: 32 fields pass and 33 fail even at 560 bytes; 4,095
# bytes pass and 4,096 fail). Its buffers cannot be raised.
#
# Trimming headers was the February fix (eef9d258, now the keep-fallback
# strip middleware) and it still works: it deletes the five X-authentik-*
# lines, 309 bytes for Viktor. But it removed a fixed number of lines, and the
# path kept adding lines back. A signed-in Chrome XHR POST that comes in
# through Cloudflare reaches the router with 32 fields today: 18 from the
# browser, 6 from Cloudflare and cloudflared, 2 from the outage-failover Worker
# route (on gw since 3505dbfd, 2026-07-08) and 6 from Traefik. One field more
# and it is refused, which is what Viktor's browser hit on every Cloudflare-path
# POST on 2026-08-31 and 2026-09-22. The byte limit is under separate pressure
# from cookies scoped to .viktorbarzin.me: that POST is about 2,064 bytes with
# a typical jar and 2,772 with the largest one seen, against 4,095.
#
# So this hop does not trim, it allowlists. nginx sends the device the fixed
# header list in factory/main.tf (local.lean_headers) plus Host, Connection,
# the body framing headers and only the device's own cookies out of Cookie.
# Growth anywhere upstream (domain cookies, Cloudflare, the Worker, Traefik,
# a new Chrome header) no longer reaches the device. Measured before landing
# (2026-09-22) with that POST plus one extra field: 33 fields and 2,080 bytes
# straight to the router get its 413; through this config the router receives
# 12 fields and 629 bytes and answers 200. With a 4,449-byte cookie jar it is
# still 12 fields and 628 bytes, and with every allowlisted header present
# 25 fields and 1,062 bytes.
#
# Forward-auth and the strip still run in Traefik before this hop, so nothing
# about authentication changes. A host opts in with header_allowlist on its
# factory call (factory/main.tf); that points its Ingress at a per-host
# "<name>-lean" Service in front of these pods. Deleting header_allowlist is
# the rollback: the device Service is never removed, and Terraform repoints
# the Ingress before it deletes the lean Service and, when no host is left,
# this Deployment.
#
# Safety net for the allowlist: each pod logs one [warn] line the first time it
# drops a request header or cookie it does not know, and when the device sets
# a cookie missing from the list. nginx writes the level in lower case, so
# query with |= "lean-proxy" |= "[warn]", not "WARN".

locals {
  # Every factory host that can opt in; a host that has not returns null.
  lean_servers = compact([
    module.tp-link-gateway.lean_proxy_server,
    module.idrac.lean_proxy_server,
  ])

  # http-level settings, then the default server, then one block per host.
  # Headers are parsed before nginx chooses a server block, so the buffer
  # sizes and underscores_in_headers only take effect at this level.
  lean_proxy_conf = join("\n", concat([<<-EOT
    # kube-dns ClusterIP: resolves backends given by name (idrac.viktorbarzin.lan)
    # at request time.
    resolver 10.96.0.10 valid=30s ipv6=off;
    error_log /dev/stderr warn;
    # Same sizes as auth-proxy, whose forward-auth check every request here has
    # already passed with the browser's full header set, so this hop is never
    # the tighter limit.
    client_header_buffer_size 8k;
    large_client_header_buffers 8 64k;
    underscores_in_headers on;
    lua_shared_dict lean_seen 1m;
    map $http_upgrade $connection_upgrade {
        default upgrade;
        ''      close;
    }
    log_format lean escape=json '{"time":"$time_iso8601","host":"$host","method":"$request_method","status":$status,"upstream_status":"$upstream_status","request_time":$request_time,"request_length":$request_length}';

    server {
        listen 8080 default_server;
        access_log off;
        location = /healthz { return 200 'ok'; }
        location / { return 421; }
    }
    EOT
  ], local.lean_servers))

  lean_proxy_labels = {
    app = "lean-proxy"
  }
}

resource "kubernetes_config_map" "lean_proxy" {
  count = length(local.lean_servers) > 0 ? 1 : 0
  metadata {
    name      = "lean-proxy-config"
    namespace = kubernetes_namespace.reverse-proxy.metadata[0].name
  }

  data = {
    "default.conf" = local.lean_proxy_conf
  }
}

resource "kubernetes_deployment" "lean_proxy" {
  count = length(local.lean_servers) > 0 ? 1 : 0
  metadata {
    name      = "lean-proxy"
    namespace = kubernetes_namespace.reverse-proxy.metadata[0].name
    labels    = local.lean_proxy_labels
  }

  # Terraform waits here until the new pods are Ready. The factory Ingresses
  # take their Service selector from this resource, so an Ingress switches to
  # lean-proxy only after a rollout that worked, and a failed rollout leaves
  # every host on its current route.
  wait_for_rollout = true

  spec {
    replicas = 2
    strategy {
      type = "RollingUpdate"
      rolling_update {
        max_unavailable = 0
        max_surge       = 1
      }
    }
    selector {
      match_labels = local.lean_proxy_labels
    }
    template {
      metadata {
        labels = local.lean_proxy_labels
        annotations = {
          # openresty reads default.conf once at start. A config change rolls
          # the pods through this hash, inside the apply, so the wait above
          # covers it too. (Reloader would roll them after the apply instead.)
          "checksum/config" = sha256(local.lean_proxy_conf)
        }
      }
      spec {
        topology_spread_constraint {
          max_skew           = 1
          topology_key       = "kubernetes.io/hostname"
          when_unsatisfiable = "DoNotSchedule"
          label_selector {
            match_labels = local.lean_proxy_labels
          }
        }
        container {
          name  = "nginx"
          image = "openresty/openresty:alpine"

          port {
            name           = "http"
            container_port = 8080
          }

          volume_mount {
            name       = "config"
            mount_path = "/etc/nginx/conf.d"
            read_only  = true
          }

          liveness_probe {
            http_get {
              path = "/healthz"
              port = 8080
            }
            initial_delay_seconds = 3
            period_seconds        = 10
          }
          readiness_probe {
            http_get {
              path = "/healthz"
              port = 8080
            }
            initial_delay_seconds = 2
            period_seconds        = 5
          }

          resources {
            requests = {
              cpu    = "10m"
              memory = "32Mi"
            }
            limits = {
              memory = "128Mi"
            }
          }
        }

        volume {
          name = "config"
          config_map {
            name = kubernetes_config_map.lean_proxy[0].metadata[0].name
          }
        }
      }
    }
  }
  lifecycle {
    ignore_changes = [
      spec[0].template[0].spec[0].dns_config, # KYVERNO_LIFECYCLE_V1
      # KEEL_LIFECYCLE_V1: the namespace is keel-enrolled, so Kyverno stamps
      # keel.sh annotations on the live object; don't strip them.
      metadata[0].annotations["keel.sh/policy"],
      metadata[0].annotations["keel.sh/trigger"],
      metadata[0].annotations["keel.sh/pollSchedule"],
      metadata[0].annotations["keel.sh/match-tag"],
      spec[0].template[0].metadata[0].annotations["keel.sh/update-time"], # KEEL_LIFECYCLE_V1
      spec[0].template[0].spec[0].container[0].image,                     # KEEL_IGNORE_IMAGE
    ]
  }
}
