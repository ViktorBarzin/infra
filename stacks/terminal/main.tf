variable "tls_secret_name" {
  type      = string
  sensitive = true
}

resource "kubernetes_namespace" "terminal" {
  metadata {
    name = "terminal"
    labels = {
      "istio-injection" : "disabled"
      tier               = local.tiers.aux
      "keel.sh/enrolled" = "true"
    }
  }
  lifecycle {
    # KYVERNO_LIFECYCLE_V1: goldilocks-vpa-auto-mode ClusterPolicy stamps this label on every namespace
    ignore_changes = [metadata[0].labels["goldilocks.fairwinds.com/vpa-update-mode"]]
  }
}

module "tls_secret" {
  source          = "../../modules/kubernetes/setup_tls_secret"
  namespace       = kubernetes_namespace.terminal.metadata[0].name
  tls_secret_name = var.tls_secret_name
}

# Service + Endpoints to reverse-proxy to ttyd at 10.0.10.10:7681
resource "kubernetes_service" "terminal" {
  metadata {
    name      = "terminal"
    namespace = kubernetes_namespace.terminal.metadata[0].name
    labels = {
      app = "terminal"
    }
  }

  spec {
    port {
      name        = "http"
      port        = 80
      target_port = 7681
    }
  }
}

resource "kubernetes_endpoints" "terminal" {
  metadata {
    name      = "terminal"
    namespace = kubernetes_namespace.terminal.metadata[0].name
  }

  subset {
    address {
      ip = "10.0.10.10"
    }
    port {
      name = "http"
      port = 7681
    }
  }
}

module "ingress" {
  source          = "../../modules/kubernetes/ingress_factory"
  dns_type        = "proxied"
  namespace       = kubernetes_namespace.terminal.metadata[0].name
  name            = "terminal"
  tls_secret_name = var.tls_secret_name
  auth            = "required"
  extra_annotations = {
    "gethomepage.dev/enabled"      = "true"
    "gethomepage.dev/name"         = "Terminal"
    "gethomepage.dev/description"  = "Web terminal (ttyd)"
    "gethomepage.dev/icon"         = "mdi-console"
    "gethomepage.dev/group"        = "Infrastructure"
    "gethomepage.dev/pod-selector" = ""
  }
}

# Read-only terminal session at terminal-ro.viktorbarzin.me
resource "kubernetes_service" "terminal_ro" {
  metadata {
    name      = "terminal-ro"
    namespace = kubernetes_namespace.terminal.metadata[0].name
    labels = {
      app = "terminal-ro"
    }
  }

  spec {
    port {
      name        = "http"
      port        = 80
      target_port = 7682
    }
  }
}

resource "kubernetes_endpoints" "terminal_ro" {
  metadata {
    name      = "terminal-ro"
    namespace = kubernetes_namespace.terminal.metadata[0].name
  }

  subset {
    address {
      ip = "10.0.10.10"
    }
    port {
      name = "http"
      port = 7682
    }
  }
}

# Clipboard image upload service (same-origin path routing)
resource "kubernetes_service" "clipboard_upload" {
  metadata {
    name      = "clipboard-upload"
    namespace = kubernetes_namespace.terminal.metadata[0].name
    labels = {
      app = "clipboard-upload"
    }
  }

  spec {
    port {
      name        = "http"
      port        = 80
      target_port = 7683
    }
  }
}

resource "kubernetes_endpoints" "clipboard_upload" {
  metadata {
    name      = "clipboard-upload"
    namespace = kubernetes_namespace.terminal.metadata[0].name
  }

  subset {
    address {
      ip = "10.0.10.10"
    }
    port {
      name = "http"
      port = 7683
    }
  }
}

# IngressRoute for /clipboard/* on terminal.viktorbarzin.me → clipboard-upload service
resource "kubernetes_manifest" "clipboard_ingressroute" {
  manifest = {
    apiVersion = "traefik.io/v1alpha1"
    kind       = "IngressRoute"
    metadata = {
      name      = "clipboard-upload"
      namespace = kubernetes_namespace.terminal.metadata[0].name
    }
    spec = {
      entryPoints = ["websecure"]
      routes = [{
        match = "Host(`terminal.viktorbarzin.me`) && PathPrefix(`/clipboard/`)"
        kind  = "Rule"
        middlewares = [
          {
            name      = "authentik-forward-auth"
            namespace = "traefik"
          },
          {
            name      = "clipboard-strip-prefix"
            namespace = kubernetes_namespace.terminal.metadata[0].name
          }
        ]
        services = [{
          name = "clipboard-upload"
          port = 80
        }]
      }]
      tls = {
        secretName = var.tls_secret_name
      }
    }
  }
}

resource "kubernetes_manifest" "clipboard_strip_prefix" {
  manifest = {
    apiVersion = "traefik.io/v1alpha1"
    kind       = "Middleware"
    metadata = {
      name      = "clipboard-strip-prefix"
      namespace = kubernetes_namespace.terminal.metadata[0].name
    }
    spec = {
      stripPrefix = {
        prefixes = ["/clipboard"]
      }
    }
  }
}

module "ingress_ro" {
  source          = "../../modules/kubernetes/ingress_factory"
  dns_type        = "proxied"
  namespace       = kubernetes_namespace.terminal.metadata[0].name
  name            = "terminal-ro"
  tls_secret_name = var.tls_secret_name
  auth            = "required"
  extra_annotations = {
    "gethomepage.dev/enabled"      = "true"
    "gethomepage.dev/name"         = "Terminal (Read-Only)"
    "gethomepage.dev/description"  = "Read-only web terminal (ttyd)"
    "gethomepage.dev/icon"         = "mdi-console"
    "gethomepage.dev/group"        = "Infrastructure"
    "gethomepage.dev/pod-selector" = ""
  }
}

# === Multi-session lobby on terminal.viktorbarzin.me ===
#
# Application code (frontend, tmux-api, clipboard-upload, DevVM
# systemd units / scripts / config) lives in a separate Forgejo repo:
#   https://forgejo.viktorbarzin.me/viktor/terminal-lobby
#
# That repo's ./scripts/deploy.sh ships everything to wizard@10.0.10.10
# and restarts ttyd / ttyd-ro / tmux-api / clipboard-upload. Deploy is
# MANUAL via that script — there is no CI pipeline (the lobby's
# .woodpecker.yml was removed under ADR-0002, issue #31; it builds no
# image, so it is not part of the GHA->ghcr fleet). This stack only owns
# the Kubernetes side: Services, Endpoints pointing at
# 10.0.10.10:{7681,7682,7683,7684}, the IngressRoutes, and the Traefik
# middlewares that gate everything behind Authentik forward-auth.
#
# Service map (DevVM):
#   ttyd               :7681  →  serves lobby + xterm WS
#   ttyd-ro            :7682  →  read-only mirror at terminal-ro.viktorbarzin.me
#   clipboard-upload   :7683  →  POST /upload, returns saved path
#   tmux-api           :7684  →  GET /sessions, DELETE /sessions/<n>,
#                                POST /sessions/<n>/rename, GET /whoami

# Service+Endpoints → tmux-api on the DevVM (port 7684).
resource "kubernetes_service" "tmux_api" {
  metadata {
    name      = "tmux-api"
    namespace = kubernetes_namespace.terminal.metadata[0].name
    labels = {
      app = "tmux-api"
    }
  }

  spec {
    port {
      name        = "http"
      port        = 80
      target_port = 7684
    }
  }
}

resource "kubernetes_endpoints" "tmux_api" {
  metadata {
    name      = "tmux-api"
    namespace = kubernetes_namespace.terminal.metadata[0].name
  }

  subset {
    address {
      ip = "10.0.10.10"
    }
    port {
      name = "http"
      port = 7684
    }
  }
}

# IngressRoute: /api/sessions/* on terminal.viktorbarzin.me → tmux-api
# service. Path-prefix specificity beats the catch-all `module.ingress`
# (terminal.viktorbarzin.me → ttyd) above, so the lobby HTML reaches
# tmux-api directly while everything else flows to ttyd.
resource "kubernetes_manifest" "tmux_api_ingressroute" {
  manifest = {
    apiVersion = "traefik.io/v1alpha1"
    kind       = "IngressRoute"
    metadata = {
      name      = "tmux-api"
      namespace = kubernetes_namespace.terminal.metadata[0].name
    }
    spec = {
      entryPoints = ["websecure"]
      routes = [{
        match = "Host(`terminal.viktorbarzin.me`) && PathPrefix(`/api/sessions/`)"
        kind  = "Rule"
        middlewares = [
          {
            name      = "authentik-forward-auth"
            namespace = "traefik"
          },
          {
            name      = "tmux-api-strip-prefix"
            namespace = kubernetes_namespace.terminal.metadata[0].name
          }
        ]
        services = [{
          name = "tmux-api"
          port = 80
        }]
      }]
      tls = {
        secretName = var.tls_secret_name
      }
    }
  }
}

resource "kubernetes_manifest" "tmux_api_strip_prefix" {
  manifest = {
    apiVersion = "traefik.io/v1alpha1"
    kind       = "Middleware"
    metadata = {
      name      = "tmux-api-strip-prefix"
      namespace = kubernetes_namespace.terminal.metadata[0].name
    }
    spec = {
      stripPrefix = {
        prefixes = ["/api/sessions"]
      }
    }
  }
}

# =============================================================================
# Webterminal probe (added 2026-05-17 after a Traefik replica came up with a
# partial routing table — only the IngressRoute CRDs registered; the
# kubernetes_ingress for terminal.viktorbarzin.me was missing, so ~70% of
# /token requests routed to that replica returned 404 with router="-". The
# lobby's WebSocket retry loop kept the user stuck on "Failed to connect.
# Retrying..." because Cloudflare → that replica → 404 broke /token and the
# /ws upgrade intermittently.
#
# The probe exercises the full external path (Cloudflare → Traefik → ttyd
# Service) every 5 minutes and pushes 4 gauges to Pushgateway:
#   webterminal_probe_token_status        — HTTP status of GET /token (want 302)
#   webterminal_probe_ws_status           — HTTP status of WS upgrade /ws (want 302)
#   webterminal_probe_ttyd_status         — In-cluster ttyd /token (want 200)
#   webterminal_probe_last_success_timestamp — Unix ts of last fully-OK run
#
# Alerts live in monitoring/prometheus_chart_values.tpl group "Webterminal".
# =============================================================================

resource "kubernetes_cron_job_v1" "webterminal_probe" {
  metadata {
    name      = "webterminal-probe"
    namespace = kubernetes_namespace.terminal.metadata[0].name
  }
  spec {
    concurrency_policy            = "Forbid"
    failed_jobs_history_limit     = 3
    successful_jobs_history_limit = 1
    schedule                      = "*/5 * * * *"
    job_template {
      metadata {}
      spec {
        backoff_limit              = 1
        ttl_seconds_after_finished = 600
        template {
          metadata {
            labels = {
              app = "webterminal-probe"
            }
          }
          spec {
            restart_policy = "OnFailure"
            container {
              name              = "probe"
              image             = "docker.io/library/alpine:3.20"
              image_pull_policy = "IfNotPresent"
              resources {
                requests = {
                  cpu    = "10m"
                  memory = "32Mi"
                }
                limits = {
                  memory = "96Mi"
                }
              }
              env {
                name  = "TARGET_HOST"
                value = "terminal.viktorbarzin.me"
              }
              env {
                name  = "PUSHGATEWAY"
                value = "http://prometheus-prometheus-pushgateway.monitoring:9091/metrics/job/webterminal-probe"
              }
              command = ["/bin/sh", "-c", <<-EOT
                set -u
                apk add --no-cache curl python3 >/dev/null 2>&1

                # Probe 1 — HTTP GET /token (Cloudflare → Traefik → ttyd).
                # Without an Authentik cookie the response MUST be 302
                # (forward-auth redirect). 404 means a Traefik router is
                # missing on the replica that received the request.
                TOKEN_STATUS=$(curl -sk -o /dev/null -w "%%{http_code}" \
                    --max-time 10 \
                    "https://$${TARGET_HOST}/token?arg=probe" || echo 0)

                # Probe 2 — WebSocket upgrade to /ws. Same expectation: 302.
                # 404 here is what produced "Failed to connect" in the lobby
                # iframe. Use Python for a true Upgrade request — curl's
                # synthetic upgrade headers don't always trigger the WS path
                # through every Cloudflare POP.
                WS_STATUS=$(python3 - <<'PYEOF' 2>/dev/null || echo 0
                import ssl, socket, base64, os
                try:
                    ctx = ssl.create_default_context()
                    ctx.check_hostname = False
                    ctx.verify_mode = ssl.CERT_NONE
                    ctx.set_alpn_protocols(["http/1.1"])
                    sock = socket.create_connection((os.environ["TARGET_HOST"], 443), timeout=10)
                    ssock = ctx.wrap_socket(sock, server_hostname=os.environ["TARGET_HOST"])
                    key = base64.b64encode(os.urandom(16)).decode()
                    req = (
                        "GET /ws?arg=probe HTTP/1.1\r\n"
                        f"Host: {os.environ['TARGET_HOST']}\r\n"
                        "Upgrade: websocket\r\n"
                        "Connection: Upgrade\r\n"
                        f"Sec-WebSocket-Key: {key}\r\n"
                        "Sec-WebSocket-Version: 13\r\n"
                        "Sec-WebSocket-Protocol: tty\r\n"
                        f"Origin: https://{os.environ['TARGET_HOST']}\r\n"
                        "\r\n"
                    )
                    ssock.sendall(req.encode())
                    ssock.settimeout(5)
                    data = ssock.recv(2048)
                    ssock.close()
                    first = data.split(b"\r\n")[0].decode("ascii", "ignore")
                    parts = first.split()
                    print(parts[1] if len(parts) >= 2 and parts[1].isdigit() else 0)
                except Exception:
                    print(0)
                PYEOF
                )

                # Probe 3 — ttyd Service ClusterIP. Bypasses Cloudflare /
                # Traefik / Authentik so we can tell whether the failure mode
                # is "ttyd down" vs "edge proxy misrouting".
                TTYD_STATUS=$(curl -s -o /dev/null -w "%%{http_code}" \
                    --max-time 5 -H "X-authentik-username: probe" \
                    "http://terminal.terminal.svc.cluster.local/token" || echo 0)

                OK=0
                if [ "$$TOKEN_STATUS" = "302" ] && [ "$$WS_STATUS" = "302" ] && [ "$$TTYD_STATUS" = "200" ]; then
                  OK=1
                fi
                NOW=$(date +%s)

                cat <<METRICS | curl -sf --max-time 10 --data-binary @- "$$PUSHGATEWAY" >/dev/null 2>&1 || true
                # HELP webterminal_probe_token_status HTTP status from GET /token via Cloudflare.
                # TYPE webterminal_probe_token_status gauge
                webterminal_probe_token_status $${TOKEN_STATUS:-0}
                # HELP webterminal_probe_ws_status HTTP status from WebSocket upgrade /ws via Cloudflare.
                # TYPE webterminal_probe_ws_status gauge
                webterminal_probe_ws_status $${WS_STATUS:-0}
                # HELP webterminal_probe_ttyd_status HTTP status from in-cluster ttyd /token.
                # TYPE webterminal_probe_ttyd_status gauge
                webterminal_probe_ttyd_status $${TTYD_STATUS:-0}
                # HELP webterminal_probe_last_success_timestamp Unix ts of last fully-OK probe.
                # TYPE webterminal_probe_last_success_timestamp gauge
                webterminal_probe_last_success_timestamp $$([ "$$OK" = "1" ] && echo "$$NOW" || echo 0)
                METRICS

                echo "probe: token=$${TOKEN_STATUS} ws=$${WS_STATUS} ttyd=$${TTYD_STATUS} ok=$${OK}"
              EOT
              ]
            }
          }
        }
      }
    }
  }
}

# CI retrigger 2026-05-16T13:42:57+00:00 — bulk enrollment apply (pipeline #689 killed)
# CI retrigger v2 2026-05-16T13:46:35+00:00
