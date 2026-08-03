# Tailscale subnet-router connectivity probe — every 6 hours.
#
# WHY: the pfSense subnet router sat `Logged out` from ~2026-07-18 to 2026-08-03
# and nothing noticed, because nothing was watching. Headscale's own metrics
# cannot answer the question that matters ("can a client actually reach the
# LAN?") — a node can be online with routes approved while the data path is
# broken. So this probe joins the tailnet as a real client each run and pulls
# HTTP through the subnet routes.
#
# WHY NOT just query the Headscale API: an in-cluster pod can reach 192.168.1.x
# and 10.0.20.x DIRECTLY over ordinary cluster routing, so "can I reach the LAN"
# is NOT a tailnet test from here. Traffic is therefore forced through
# tailscaled's own outbound HTTP proxy (userspace netstack), which can only
# egress via the tunnel, and the probe refuses to report success unless it first
# confirms it holds a tailnet address.
#
# Identity: a reusable + EPHEMERAL pre-auth key tagged tag:probe. Ephemeral means
# Headscale reaps the node when it disconnects, so runs do not accumulate nodes.
# tag:probe's ACL grant is deliberately just two HTTP endpoints (ha-sofia:8123
# and traefik-lb:80 in acl.hujson), so a leaked probe key buys almost nothing —
# that is why a long-lived key is acceptable here.
#
# Design: docs/plans/2026-08-03-pfsense-tailscale-subnet-router-design.md

resource "kubernetes_manifest" "probe_preauthkey_secret" {
  field_manager {
    force_conflicts = true
  }
  manifest = {
    apiVersion = "external-secrets.io/v1"
    kind       = "ExternalSecret"
    metadata = {
      name      = "headscale-probe-preauthkey"
      namespace = "headscale"
    }
    spec = {
      refreshInterval = "1h"
      secretStoreRef = {
        name = "vault-kv"
        kind = "ClusterSecretStore"
      }
      target = { name = "headscale-probe-preauthkey" }
      data = [
        {
          secretKey = "TS_AUTHKEY"
          remoteRef = { key = "platform", property = "headscale_probe_preauthkey" }
        },
      ]
    }
  }
}

resource "kubernetes_cron_job_v1" "subnet_router_probe" {
  metadata {
    name      = "tailscale-subnet-router-probe"
    namespace = "headscale"
    labels    = { app = "tailscale-subnet-router-probe", tier = local.tiers.core }
  }
  spec {
    # Every 6 hours, per Viktor's ask. Deliberately not more often: each run
    # registers and reaps an ephemeral tailnet node.
    schedule                      = "7 */6 * * *"
    concurrency_policy            = "Forbid"
    successful_jobs_history_limit = 2
    failed_jobs_history_limit     = 3
    starting_deadline_seconds     = 600

    job_template {
      metadata {
        labels = { app = "tailscale-subnet-router-probe" }
      }
      spec {
        backoff_limit           = 1
        active_deadline_seconds = 420
        template {
          metadata {
            labels = { app = "tailscale-subnet-router-probe" }
          }
          spec {
            restart_policy = "Never"

            volume {
              name = "shared"
              empty_dir {}
            }

            # The probe writes metrics; the main container ships them. Ordering
            # via init_container is deterministic (the immich-search-probe
            # pattern) — two plain containers would race the file.
            init_container {
              name  = "probe"
              image = "ghcr.io/tailscale/tailscale:v1.86.2"
              command = ["/bin/sh", "-c"]
              args = [<<-EOT
                set -u
                # Userspace netstack: no NET_ADMIN, no /dev/net/tun, no host
                # network — and, critically, no route leakage. Everything sent
                # through the proxy below can ONLY leave via the tunnel.
                # 127.0.0.1 not "localhost": busybox wget resolves localhost to
                # ::1 first, and the proxy listens on IPv4 only -> instant
                # "Connection refused" that looks exactly like a broken tunnel.
                tailscaled --tun=userspace-networking \
                  --outbound-http-proxy-listen=127.0.0.1:1055 \
                  --state=mem: >/tmp/tailscaled.log 2>&1 &
                sleep 5

                tailscale up --login-server=https://headscale.viktorbarzin.me \
                  --authkey="$TS_AUTHKEY" \
                  --hostname=tailnet-probe \
                  --accept-routes >/tmp/up.log 2>&1

                ENROLLED=0
                TS_IP="$(tailscale ip -4 2>/dev/null || true)"
                case "$TS_IP" in 100.*) ENROLLED=1 ;; esac

                ROUTER_UP=0
                SOFIA=0
                K8S=0

                if [ "$ENROLLED" = "1" ]; then
                  # Liveness of the subnet router itself over the tunnel.
                  if tailscale ping --c 4 --timeout=5s 100.64.0.9 2>/dev/null | grep -q '^pong'; then
                    ROUTER_UP=1
                  fi

                  export http_proxy=http://127.0.0.1:1055
                  # ANY HTTP response proves the round trip: request reached the
                  # LAN host through the subnet route and the reply came back.
                  # Status code is irrelevant — traefik answers a bare-IP request
                  # with 502 (no matching router), which is still proof of path,
                  # so grep for the status line instead of trusting wget's exit.
                  if wget -S -q -O /dev/null --timeout=20 http://192.168.1.8:8123/ 2>&1 | grep -q 'HTTP/1'; then
                    SOFIA=1
                  fi
                  if wget -S -q -O /dev/null --timeout=20 http://10.0.20.203:80/ 2>&1 | grep -q 'HTTP/1'; then
                    K8S=1
                  fi
                  tailscale logout >/dev/null 2>&1 || true
                else
                  echo "NOT ENROLLED — reporting failure rather than a false green"
                  cat /tmp/up.log 2>/dev/null | tail -5
                fi

                SUCCESS=0
                if [ "$ENROLLED" = "1" ] && [ "$SOFIA" = "1" ] && [ "$K8S" = "1" ]; then
                  SUCCESS=1
                fi

                {
                  echo "# HELP tailscale_subnet_router_probe_enrolled 1 if the probe joined the tailnet (a 0 makes all other series meaningless)."
                  echo "# TYPE tailscale_subnet_router_probe_enrolled gauge"
                  echo "tailscale_subnet_router_probe_enrolled $ENROLLED"
                  echo "# HELP tailscale_subnet_router_up 1 if the pfSense subnet router answered a tailnet ping."
                  echo "# TYPE tailscale_subnet_router_up gauge"
                  echo "tailscale_subnet_router_up $ROUTER_UP"
                  echo "# HELP tailscale_subnet_route_reachable 1 if an HTTP round trip through that advertised subnet route succeeded."
                  echo "# TYPE tailscale_subnet_route_reachable gauge"
                  echo "tailscale_subnet_route_reachable{route=\"192.168.1.0/24\",target=\"ha-sofia:8123\"} $SOFIA"
                  echo "tailscale_subnet_route_reachable{route=\"10.0.20.0/24\",target=\"traefik-lb:80\"} $K8S"
                  echo "# HELP tailscale_subnet_router_probe_success 1 only if enrolled AND both routes carried traffic."
                  echo "# TYPE tailscale_subnet_router_probe_success gauge"
                  echo "tailscale_subnet_router_probe_success $SUCCESS"
                  echo "# HELP tailscale_subnet_router_probe_last_run_timestamp Unix time of the last completed probe."
                  echo "# TYPE tailscale_subnet_router_probe_last_run_timestamp gauge"
                  echo "tailscale_subnet_router_probe_last_run_timestamp $(date +%s)"
                } > /shared/metrics.prom

                echo "enrolled=$ENROLLED ip=$TS_IP router_up=$ROUTER_UP sofia=$SOFIA k8s=$K8S success=$SUCCESS"
                # Exit 0 regardless: the metric carries the verdict, and a failed
                # Job would also fire PodCrashLooping-class noise for what is
                # already an alerted condition.
                exit 0
              EOT
              ]
              env {
                name = "TS_AUTHKEY"
                value_from {
                  secret_key_ref {
                    name = "headscale-probe-preauthkey"
                    key  = "TS_AUTHKEY"
                  }
                }
              }
              volume_mount {
                name       = "shared"
                mount_path = "/shared"
              }
              resources {
                requests = { cpu = "20m", memory = "64Mi" }
                limits   = { memory = "128Mi" }
              }
            }

            container {
              name  = "push"
              image = "docker.io/curlimages/curl:8.11.1"
              command = [
                "curl", "-sf", "-m", "20", "--data-binary", "@/shared/metrics.prom",
                "http://prometheus-prometheus-pushgateway.monitoring:9091/metrics/job/tailscale-subnet-router-probe",
              ]
              volume_mount {
                name       = "shared"
                mount_path = "/shared"
              }
              resources {
                requests = { cpu = "10m", memory = "16Mi" }
                limits   = { memory = "32Mi" }
              }
            }
          }
        }
      }
    }
  }

  lifecycle {
    # KYVERNO_LIFECYCLE_V1: Kyverno injects spec.dnsConfig on pod templates
    ignore_changes = [spec[0].job_template[0].spec[0].template[0].spec[0].dns_config]
  }

  depends_on = [kubernetes_manifest.probe_preauthkey_secret]
}
