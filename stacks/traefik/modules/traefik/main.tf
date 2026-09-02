variable "tier" { type = string }
variable "redis_host" { type = string }
variable "tls_secret_name" {}
variable "auth_fallback_htpasswd" {
  type        = string
  description = "htpasswd-format string for emergency basicAuth fallback when Authentik is down"
  sensitive   = true
}
variable "crowdsec_bouncer_key" {
  type        = string
  sensitive   = true
  description = "LAPI bouncer API key for the in-process crowdsec-bouncer plugin. Registered at LAPI startup by stacks/crowdsec via BOUNCER_KEY_traefik; both sides read Vault secret/platform -> traefik_bouncer_key."
}
variable "x402_wallet_address" {
  type        = string
  default     = ""
  description = "EVM wallet (Base mainnet, 0x…) that receives USDC from x402 payments. Empty = DRY_RUN, gateway always returns 200 to forwardAuth so traffic is unaffected."
}
variable "x402_notify_webhook_url" {
  type        = string
  default     = ""
  description = "Slack-compatible incoming-webhook URL the gateway POSTs to on every successful payment. Empty = no notifications."
  sensitive   = true
}

resource "kubernetes_namespace" "traefik" {
  metadata {
    name = "traefik"
    labels = {
      "app.kubernetes.io/name"     = "traefik"
      "app.kubernetes.io/instance" = "traefik"
      tier                         = var.tier
      "keel.sh/enrolled"           = "true"
    }
  }
  lifecycle {
    # KYVERNO_LIFECYCLE_V1: goldilocks-vpa-auto-mode ClusterPolicy stamps this label on every namespace
    ignore_changes = [metadata[0].labels["goldilocks.fairwinds.com/vpa-update-mode"]]
  }
}

resource "helm_release" "traefik" {
  namespace        = kubernetes_namespace.traefik.metadata[0].name
  create_namespace = false
  name             = "traefik"
  repository       = "https://traefik.github.io/charts"
  chart            = "traefik"
  # Pin to the deployed chart version. Was unpinned, so a refreshed helm repo
  # index silently tries to upgrade to the latest chart on the next apply —
  # chart 41.0.0 rejects this values block's `logs` key ("Additional property
  # logs is not allowed"). Bump deliberately (with values migration), never
  # implicitly. Deployed since 2026-05-30 (release rev 57).
  version = "40.2.0"
  atomic  = true
  timeout = 600

  values = [yamlencode({
    deployment = {
      replicas                      = 3
      terminationGracePeriodSeconds = 60
      lifecycle = {
        preStop = {
          exec = {
            command = ["/bin/sh", "-c", "sleep 15"]
          }
        }
      }
      podAnnotations = {
        "diun.enable"       = "true"
        "diun.include_tags" = "^v\\d+(?:\\.\\d+)?(?:\\.\\d+)?.*$"
      }
      # QUIC socket telemetry. Traefik terminates HTTP/3 on ONE shared UDP
      # socket per pod, and when that socket's receive buffer overflows the
      # kernel drops packets, quic-go loses ACKs, and large downloads truncate
      # while still reporting HTTP 200 — the 2026-08-29 grey-photo incident
      # (see playbooks/k8s-node-tuning.yml for the buffer fix itself).
      #
      # WHY A SIDECAR AND NOT THE EXISTING node-exporter DAEMONSET: the counter
      # that moves is Udp RcvbufErrors in the POD's network namespace. The
      # DaemonSet runs hostNetwork=true, so it reads the HOST namespace, which
      # sat at 0 for the entire incident while the Traefik pod's own counter was
      # at 449. It is structurally blind to this and no amount of scraping it
      # would help. Containers in a pod share a network namespace, so a sidecar
      # reading its own /proc/net/snmp sees exactly the right counters.
      #
      # DO NOT REMOVE as "duplicate node-exporter" — it is not duplicate, it is
      # a different namespace. Alert: TraefikQUICSocketDropping.
      additionalContainers = [{
        name  = "quic-socket-metrics"
        image = "quay.io/prometheus/node-exporter:v1.7.0"
        args = [
          # netstat is the only collector we want; the defaults would export
          # filesystem/cpu/etc for a namespace where they are meaningless.
          # Its default field allowlist already includes Udp_(InDatagrams|
          # OutDatagrams|NoPorts|RcvbufErrors|SndbufErrors), so no override.
          "--collector.disable-defaults",
          "--collector.netstat",
          "--web.listen-address=:9101",
        ]
        ports = [{
          name          = "quicmetrics"
          containerPort = 9101
        }]
        securityContext = {
          runAsNonRoot             = true
          runAsUser                = 65534
          allowPrivilegeEscalation = false
          readOnlyRootFilesystem   = true
          capabilities             = { drop = ["ALL"] }
        }
        # No CPU limit: the strip-cpu-limits Kyverno policy removes them anyway.
        resources = {
          requests = { cpu = "5m", memory = "16Mi" }
          limits   = { memory = "64Mi" }
        }
      }]
      initContainers = [{
        name  = "download-plugins"
        image = "alpine:3"
        command = ["sh", "-c", join("", [
          "set -e; ",
          "STORAGE=/plugins-storage; ",
          "mkdir -p \"$STORAGE/archives/github.com/Aetherinox/traefik-api-token-middleware\"; ",
          "wget -q -T 30 -O \"$STORAGE/archives/github.com/Aetherinox/traefik-api-token-middleware/v0.1.4.zip\" ",
          "\"https://github.com/Aetherinox/traefik-api-token-middleware/archive/refs/tags/v0.1.4.zip\"; ",
          "printf '{\"github.com/Aetherinox/traefik-api-token-middleware\":\"v0.1.4\"}' ",
          "> \"$STORAGE/archives/state.json\"; ",
          "echo \"Plugins pre-downloaded successfully\"",
        ])]
        volumeMounts = [{
          name      = "plugins"
          mountPath = "/plugins-storage"
        }]
      }]
    }

    updateStrategy = {
      type = "RollingUpdate"
      rollingUpdate = {
        maxUnavailable = 0
        maxSurge       = 1
      }
    }

    ingressClass = {
      enabled        = true
      isDefaultClass = true
    }

    providers = {
      kubernetesIngress = {
        enabled                   = true
        allowExternalNameServices = true
        publishedService          = { enabled = true }
      }
      kubernetesCRD = {
        enabled                   = true
        allowExternalNameServices = true
        allowCrossNamespace       = true
      }
    }

    # Enable dashboard API (accessible on port 8080 internally)
    api = {
      insecure = false
    }

    # Entrypoints
    ports = {
      web = {
        port        = 8000
        exposedPort = 80
        protocol    = "TCP"
        http = {
          redirections = {
            entryPoint = {
              to     = "websecure"
              scheme = "https"
            }
          }
        }
        proxyProtocol = {
          trustedIPs = ["10.0.20.1"]
        }
      }
      websecure = {
        port        = 8443
        exposedPort = 443
        protocol    = "TCP"
        http = {
          tls = {
            enabled = true
          }
          # Entrypoint middlewares are PREPENDED to every router on websecure, so
          # this covers all ~195 Ingresses, the 10 IngressRoutes and the catchall
          # — including the hand-rolled ingresses that never go through
          # ingress_factory. That reach is the point: doing it per-ingress via the
          # factory would fan a modules/ change out over 33 platform + ~95 app
          # stacks applied serially, and lock-contended stacks are SKIPPED rather
          # than failed, which would leave some ingresses on the old chain.
          #
          # crowdsec comes first so a banned client is rejected before any
          # compression work. It only gates HTTP on this entrypoint: the
          # api/dashboard/ping routers live on the `traefik` entrypoint (:8080),
          # the two IngressRouteTCPs have their own entrypoints, and there is no
          # ACME/HTTP-01 path through Traefik at all (no certResolver anywhere —
          # certs come from the renew-tls Woodpecker cron).
          #
          # ORDERING: never leave a router referencing a Middleware that does not
          # exist. The `crowdsec` Middleware (middleware.tf) is created before
          # this reference is added, and `entryPoints` is STATIC config — changing
          # it is a helm upgrade plus a 3-replica roll, not an annotation edit, so
          # a rollback here costs minutes rather than seconds.
          middlewares = [
            "traefik-crowdsec@kubernetescrd",
            "traefik-compress@kubernetescrd",
          ]
        }
        # DO NOT set enabled = false to "turn off QUIC". It takes the whole
        # site down, and the reason is not obvious from this file.
        #
        # websecure/TCP:443 and websecure-http3/UDP:443 share a port NUMBER, and
        # Kubernetes uses `port` as the strategic-merge key for
        # Service.spec.ports. Two entries on 443 collide on that key, so a patch
        # that removes the UDP entry removes the TCP one with it. Measured
        # 2026-08-31: helm rendered websecure/TCP:443 correctly in the very
        # revision that took every ingress down (`helm get manifest --revision
        # 72` lists it), the live Service lost it anyway, and websecure's
        # nodePort moved 31049 -> 30703, showing the entry was deleted and
        # recreated rather than patched. Traefik stayed healthy on :8443 the
        # whole time with nothing mapping 443 to it.
        #
        # The same collision means helm cannot heal the drift afterwards: with
        # the port identical in the old and new manifests there is no diff to
        # patch, so the missing entry was restored by hand with an additive JSON
        # patch (`kubectl patch --type=json`), which bypasses merge keys.
        #
        # To disable HTTP/3 for real, do it at the Cloudflare edge for proxied
        # hosts (stacks/cloudflared), and for origin-direct hosts strip the
        # alt-svc response header with a middleware rather than touching this
        # entrypoint. Verify any change here by rendering the Service first:
        #   helm template traefik traefik/traefik --version 40.2.0 -f <values>
        # and confirm websecure/TCP:443 is still in the output.
        http3 = {
          enabled        = true
          advertisedPort = 443
        }
        # Accept PROXY-v2 ONLY from the pfSense HAProxy IPv6 bridge (10.0.20.1)
        # so IPv6 clients (forwarded [2001:470:6e:43d::2] -> here) get their real
        # IP for CrowdSec. Real IPv4 clients arrive with their own source IP
        # (ETP=Local, not 10.0.20.1) and are unaffected.
        proxyProtocol = {
          trustedIPs = ["10.0.20.1"]
        }
      }
      whisper-tcp = {
        port        = 10300
        exposedPort = 10300
        protocol    = "TCP"
        expose      = { default = true }
      }
      piper-tcp = {
        port        = 10200
        exposedPort = 10200
        protocol    = "TCP"
        expose      = { default = true }
      }
    }

    service = {
      type = "LoadBalancer"
      annotations = {
        # Dedicated IP + ETP=Local so direct-app clients keep their real source
        # IP (CrowdSec) and QUIC handshakes pin to one pod. Proxied apps are
        # unaffected — cloudflared targets the in-cluster Traefik Service
        # (traefik.traefik.svc), not this LB IP, so the LB IP can move freely.
        "metallb.io/loadBalancerIPs" = "10.0.20.203"
      }
      spec = {
        externalTrafficPolicy = "Local"
      }
    }

    # Plugins
    experimental = {
      plugins = {
        # Static-token bearer/header auth middleware. Used by services that
        # need gateway-level API-key/bearer enforcement without app-layer auth
        # (e.g. paperless-mcp, which has no native auth). Plugin key
        # `api-token-middleware` is the name to use as the inner key in
        # `Middleware.spec.plugin.<key>` on consuming Middleware CRDs.
        api-token-middleware = {
          moduleName = "github.com/Aetherinox/traefik-api-token-middleware"
          version    = "v0.1.4"
        }
      }
      # Scale-to-zero wake middleware (ADR-0022). Vendored as a LOCAL plugin —
      # source pinned in-repo at ./sablier-plugin/ (upstream tag v1.3.0,
      # sablierapp/sablier-traefik-plugin; ~13KB, zero deps) — so Traefik
      # startup never depends on plugins.traefik.io (traefik#13005 class) and
      # a chart bump can never silently change the plugin. Upgrading the
      # plugin = deliberately re-vendoring these files + re-verifying against
      # the running Traefik version. The chart builds the ConfigMap and mounts
      # it at /plugins-local (inlinePlugin). Consumed by per-ingress
      # Middleware CRs emitted by ingress_factory's `sablier` variable
      # (plugin key `sablier` in Middleware.spec.plugin.sablier).
      # NOTE: one BROKEN plugin disables ALL plugins at startup (Traefik logs
      # "Plugins are disabled because an error has occurred.") including
      # api-token-middleware above — after any change here verify plugin load
      # in the logs AND that paperless-mcp still gates.
      # `go build` + `go test` do NOT catch that class: a plugin can compile and
      # pass its tests while Yaegi rejects it at import. BEFORE applying a change
      # to any plugin below, run `scripts/yaegi-plugin-gate` (it loads the
      # vendored files under the same yaegi version this Traefik embeds — see its
      # README for the invocations and for the variadic-struct-field panic that
      # motivated it).
      localPlugins = {
        sablier = {
          moduleName = "github.com/sablierapp/sablier-traefik-plugin"
          mountPath  = "/plugins-local/src/github.com/sablierapp/sablier-traefik-plugin"
          type       = "inlinePlugin"
          source = {
            "go.mod"       = file("${path.module}/sablier-plugin/go.mod")
            ".traefik.yml" = file("${path.module}/sablier-plugin/.traefik.yml")
            "config.go"    = file("${path.module}/sablier-plugin/config.go")
            "main.go"      = file("${path.module}/sablier-plugin/main.go")
            "version.go"   = file("${path.module}/sablier-plugin/version.go")
          }
        }
        # Rewrites X-Real-Ip to the true client for Cloudflare-tunneled
        # traffic (Cf-Connecting-Ip / first public XFF entry / else leave the
        # existing X-Real-Ip untouched). Vendored as a LOCAL plugin, same
        # rationale as sablier above. NOT YET ATTACHED to any route/Middleware
        # — this only registers it with Traefik; a later task wires it in.
        realip = {
          moduleName = "github.com/viktorbarzin/real-ip-plugin"
          mountPath  = "/plugins-local/src/github.com/viktorbarzin/real-ip-plugin"
          type       = "inlinePlugin"
          source = {
            "go.mod"       = file("${path.module}/real-ip-plugin/go.mod")
            ".traefik.yml" = file("${path.module}/real-ip-plugin/.traefik.yml")
            "main.go"      = file("${path.module}/real-ip-plugin/main.go")
          }
        }
        # CrowdSec ban enforcement, in-process. Vendored as a LOCAL plugin, same
        # rationale as sablier and realip above.
        #
        # This is where CrowdSec bans are enforced for public web traffic.
        # `cloudflare_proxied_names = []` means every HTTP host rides the
        # zone-wide wildcard and is proxied, so proxied traffic arrives from the
        # in-cluster cloudflared pod and the nftables bouncer sees 10.10.x.x
        # rather than the client. Enforcement previously lived at the Cloudflare
        # edge for that reason, until the Lists API turned out to hold a hard 72h
        # floor between successful writes (the edge list disagreed with LAPI for
        # 107 of 216 observed hours). In-process, a decision lands within one
        # poll interval, and the plugin can trust the real TCP peer the way
        # realip does — a ForwardAuth backend cannot, since its peer is always a
        # Traefik pod and Traefik's forwardedheaders does not manage
        # Cf-Connecting-Ip.
        #
        # Consumed by the `crowdsec` Middleware CR in middleware.tf (plugin key
        # `crowdsec` in Middleware.spec.plugin.crowdsec), attached to the
        # websecure entrypoint so it covers every router on it.
        crowdsec = {
          moduleName = "github.com/viktorbarzin/crowdsec-bouncer-plugin"
          mountPath  = "/plugins-local/src/github.com/viktorbarzin/crowdsec-bouncer-plugin"
          type       = "inlinePlugin"
          source = {
            "go.mod"       = file("${path.module}/crowdsec-bouncer-plugin/go.mod")
            ".traefik.yml" = file("${path.module}/crowdsec-bouncer-plugin/.traefik.yml")
            "main.go"      = file("${path.module}/crowdsec-bouncer-plugin/main.go")
          }
        }
      }
    }

    # Prometheus metrics
    metrics = {
      prometheus = {
        entryPoint           = "metrics"
        addEntryPointsLabels = true
        addServicesLabels    = true
        addRoutersLabels     = true
        buckets              = "0.01,0.05,0.1,0.2,0.5,1.0,2.0,5.0,10.0,30.0"
      }
    }

    # Access logs, JSON since 2026-09-01. Headers default to DROP; the four
    # named below are kept.
    #
    # WHY JSON AND NOT CLF: CLF has fixed positions for Referer and User-Agent
    # and nowhere to put anything else, so the authenticated principal — which
    # forward-auth already puts on the request and every backend already sees —
    # could not be logged at all. It is now a field. That is the recording half
    # of docs/plans/2026-09-01-service-identity-and-request-attribution-design.md
    # (step 5b); without it "which user made this request" is unanswerable for
    # the ~90 forward-auth routers.
    #
    # X-Authentik-Username is stamped by the Authentik forward-auth middleware
    # and cannot be set by a client (middleware.tf strips and replaces every
    # X-authentik-* header). Verified against traefik:v3.7.1 on 2026-09-01: a
    # header injected by forward-auth DOES reach the access log, because the
    # accesslog handler holds the same http.Header map the middleware mutates.
    #
    # X-Auth-Fallback is logged here but will be EMPTY until the header is added
    # to authResponseHeaders in middleware.tf (design step 1). The nginx auth
    # fallback stamps it when the Authentik outpost 5xxs, but forward-auth only
    # copies headers on that list, so today it never reaches the request. The
    # field is declared now so the format does not have to change again.
    #
    # MEASURED COST (2026-09-01, 8,876 real access-log lines over five 10-minute
    # windows): 402 bytes/line CLF -> 1,266 bytes/line JSON, a 3.15x raw growth.
    # gzip'd, which is how Loki stores it, the growth is only 1.58x — JSON's
    # repeated key names compress from 7.9x to 15.8x. At the measured 23.0 MB/h
    # of access log that is 0.55 GB/day -> 1.7 GB/day raw, and roughly
    # 70 MB/day -> 110 MB/day on disk.
    #
    # HEADER NAME CASING DOES NOT MATTER HERE, output casing is always
    # canonical: the fields.headers.names lookup is case-insensitive, and the
    # emitted keys are request_X-Authentik-Username / request_X-Auth-Fallback
    # whatever case is written below (verified 2026-09-01).
    #
    # CONSUMERS — anything parsing these lines was ported in the same commit:
    #   - CrowdSec: no change needed. crowdsecurity/traefik-logs already has a
    #     JSON node alongside its CLF grok, verified with `cscli explain` on the
    #     live agent: parser green, all five http-* scenarios still fire, and
    #     evt.Parsed.status stringifies so the local http-403/429-abuse
    #     overrides ('403' string compare) keep matching.
    #     ONE BEHAVIOUR DIFFERENCE between the two parser paths, measured and
    #     currently harmless: the CLF grok takes the first token of ClientHost
    #     as the client IP, while the JSON node takes Split(ClientHost,',')[-1],
    #     the RIGHTMOST entry. ClientHost is the whole X-Forwarded-For header
    #     when one is present, so a multi-entry XFF would make the two disagree
    #     about which address gets banned. Zero of 11,953 real access-log lines
    #     sampled on 2026-09-01 carried a comma there — Cloudflare and the
    #     pfSense HAProxy path both send a single entry — so source_ip is the
    #     real client either way (spot-checked: `cscli explain` on a JSON line
    #     resolved evt.Meta.source_ip correctly). If a multi-entry XFF ever
    #     appears, the JSON path picks the nearest proxy rather than the client:
    #     safer against spoofing, wrong for attribution. Watch for it if an
    #     upstream proxy is ever chained in front of Cloudflare.
    #   - Immich share-link recording rules + share-link-geo CronJob
    #     (stacks/monitoring) and the download-truncation CronJob
    #     (stacks/immich): re-anchored from CLF byte positions to the JSON key
    #     names.
    # The old CLF quote-escaping trade-off is GONE: the CrowdSec grok that
    # %%{NOTDQUOTE} could not span is no longer on the JSON path, so a
    # quote-bearing User-Agent no longer makes a line unparsed.
    #
    # Anything consuming these lines still must NOT trust UA/Referer content.
    # JSON makes that easier, not harder — a header value cannot contain a bare
    # `"`, so an extraction anchored to a `"FieldName":"` prefix cannot be
    # reached from a header value. See the guards in stacks/monitoring/loki.tf.
    logs = {
      access = {
        enabled = true
        format  = "json"
        fields = {
          headers = {
            names = {
              "User-Agent"           = "keep"
              "Referer"              = "keep"
              "X-Authentik-Username" = "keep"
              "X-Auth-Fallback"      = "keep"
            }
          }
        }
      }
    }

    additionalArguments = [
      "--global.checknewversion=false",
      "--global.sendanonymoususage=false",
      # Skip TLS verification for self-signed backend certs (proxmox, idrac, etc.)
      "--serversTransport.insecureSkipVerify=true",
      # Increase timeouts for services like Immich
      "--serversTransport.forwardingTimeouts.dialTimeout=60s",
      "--serversTransport.forwardingTimeouts.responseHeaderTimeout=30s",
      "--serversTransport.forwardingTimeouts.idleConnTimeout=90s",
      # Increase backend connection pool (default maxIdleConnsPerHost=2 is too low)
      "--serversTransport.maxIdleConnsPerHost=100",
      # Entrypoint transport timeouts. NOTE: Traefik respondingTimeouts are HARD caps on
      # total request/response duration (unlike nginx proxy_*_timeout, which reset per read).
      # A finite writeTimeout therefore caps total *download* time regardless of progress —
      # a prior writeTimeout=60s silently truncated large downloads at 60s (HTTP/2 reset).
      #   writeTimeout=0  -> unlimited download size/duration (Traefik's own default; Immich's
      #                      reverse-proxy guidance assumes it — it never sets writeTimeout).
      #   readTimeout=3600s -> one upload may take up to 1h. NOT 0: an unbounded request read
      #                      is the slow-loris vector (hence Traefik's 60s default). Immich has
      #                      no resumable upload, so the window must exceed real upload times.
      "--entryPoints.websecure.transport.respondingTimeouts.readTimeout=3600s",
      "--entryPoints.websecure.transport.respondingTimeouts.writeTimeout=0s",
      "--entryPoints.websecure.transport.respondingTimeouts.idleTimeout=600s",
      # Use forwarded headers from trusted proxies
      "--entryPoints.websecure.forwardedHeaders.insecure=false",
      "--entryPoints.web.forwardedHeaders.insecure=false",
      "--entryPoints.websecure.forwardedHeaders.trustedIPs=173.245.48.0/20,103.21.244.0/22,103.22.200.0/22,103.31.4.0/22,141.101.64.0/18,108.162.192.0/18,190.93.240.0/20,188.114.96.0/20,197.234.240.0/22,198.41.128.0/17,162.158.0.0/15,104.16.0.0/13,104.24.0.0/14,172.64.0.0/13,131.0.72.0/22,10.0.0.0/8,192.168.0.0/16",
      "--entryPoints.web.forwardedHeaders.trustedIPs=173.245.48.0/20,103.21.244.0/22,103.22.200.0/22,103.31.4.0/22,141.101.64.0/18,108.162.192.0/18,190.93.240.0/20,188.114.96.0/20,197.234.240.0/22,198.41.128.0/17,162.158.0.0/15,104.16.0.0/13,104.24.0.0/14,172.64.0.0/13,131.0.72.0/22,10.0.0.0/8,192.168.0.0/16",
    ]

    resources = {
      requests = {
        cpu    = "100m"
        memory = "768Mi"
      }
      limits = {
        # Raised 768Mi -> 1536Mi during a live incident on 2026-09-02: all three
        # pods were OOMKilled repeatedly (exit 137) and ALL ingress flapped.
        # Trigger was a crawler swarm on forgejo's expensive commit/src/blame
        # pages — hundreds of distinct IPv6 clients with real browser
        # user-agents, ~5s per request, most ending 499. forgejo alone was 3.8
        # of 8.2 cluster req/s and it OOMKilled forgejo too. Traefik sat at
        # 681Mi of 768Mi between restarts, i.e. permanently at the ceiling.
        #
        # The request deliberately stays at 768Mi (so this is now Burstable, not
        # Guaranteed): node2/node3 have only ~2.2-2.7GiB of free memory REQUESTS,
        # and raising the request on three replicas would cost +2.3GiB of
        # reservation and eat the N-1 headroom that ClusterCannotTolerateNonGpuNodeLoss
        # watches. Actual node usage is ~40%, so the headroom to absorb a spike
        # is real even though the reservation is not.
        memory = "1536Mi"
      }
    }

    nodeSelector = {
      "kubernetes.io/os" = "linux"
    }

    tolerations = []

    topologySpreadConstraints = [{
      maxSkew           = 1
      topologyKey       = "kubernetes.io/hostname"
      whenUnsatisfiable = "DoNotSchedule"
      labelSelector = {
        matchLabels = {
          "app.kubernetes.io/name" = "traefik"
        }
      }
    }]

    podDisruptionBudget = {
      enabled      = true
      minAvailable = 2
    }
  })]
}

# Dashboard resources
module "tls_secret" {
  source          = "../../../../modules/kubernetes/setup_tls_secret"
  namespace       = kubernetes_namespace.traefik.metadata[0].name
  tls_secret_name = var.tls_secret_name
}

resource "kubernetes_service" "traefik_dashboard" {
  metadata {
    name      = "traefik-dashboard"
    namespace = kubernetes_namespace.traefik.metadata[0].name
    labels = {
      "app" = "traefik-dashboard"
    }
  }

  spec {
    selector = {
      "app.kubernetes.io/name" = "traefik"
    }
    port {
      name        = "http"
      port        = 8080
      target_port = 8080
      protocol    = "TCP"
    }
  }
}

module "ingress" {
  source          = "../../../../modules/kubernetes/ingress_factory"
  dns_type        = "non-proxied"
  namespace       = kubernetes_namespace.traefik.metadata[0].name
  name            = "traefik"
  service_name    = "traefik-dashboard"
  host            = "traefik"
  port            = 8080
  tls_secret_name = var.tls_secret_name
  auth            = "required"
  extra_annotations = {
    "gethomepage.dev/enabled"      = "true"
    "gethomepage.dev/name"         = "Traefik"
    "gethomepage.dev/description"  = "Reverse proxy & ingress"
    "gethomepage.dev/icon"         = "traefik.png"
    "gethomepage.dev/group"        = "Core Platform"
    "gethomepage.dev/pod-selector" = ""
  }
}

# Bot-block resilience proxy: nginx reverse proxy in front of Poison Fountain
# Forward-auth target for the ai-bot-block middleware. The poison-fountain bot
# trap is intentionally scaled to 0 (stacks/poison-fountain), so /auth is a
# clean no-op returning 200 (allow-all) rather than proxying to an absent
# upstream. Reloader (annotation on the Deployment below) rolls the pods when
# this ConfigMap changes — openresty does not reload on its own.
resource "kubernetes_config_map" "bot_block_proxy_config" {
  metadata {
    name      = "bot-block-proxy-config"
    namespace = kubernetes_namespace.traefik.metadata[0].name
  }

  data = {
    "default.conf" = <<-EOT
      server {
          listen 8080;

          # Browsers accumulate one authentik_proxy_<random> cookie per Authentik
          # Proxy Provider on the parent domain. With 30+ services under
          # viktorbarzin.me the combined Cookie header exceeds nginx's default
          # 4 x 8k large_client_header_buffers and the ai-bot-block forward-auth
          # rejects it with 400 (and error-pages then shows "Too big request
          # header" 431). NOTE the *binding* limit for browsers is Traefik's
          # HTTP/2 header cap (~64KB, Go maxHeaderListSize, not configurable) —
          # bigger piles are rejected upstream of here regardless. This 256k
          # only keeps bot-block from being a *tighter* bottleneck (and covers
          # HTTP/1.1 clients). poison-fountain (the bot check) ignores cookies.
          # Real fix for >64KB piles = reduce authentik_proxy_* accumulation.
          client_header_buffer_size 8k;
          large_client_header_buffers 8 256k;

          location /auth {
              access_by_lua_block {
                  ngx.req.clear_header("If-Match")
                  ngx.req.clear_header("If-None-Match")
                  ngx.req.clear_header("If-Modified-Since")
                  ngx.req.clear_header("If-Unmodified-Since")
              }
              # poison-fountain (the bot trap) is intentionally scaled to 0
              # (stacks/poison-fountain, replicas=0). With no upstream to
              # consult we short-circuit to allow-all here -- the SAME effective
              # behaviour as the prior proxy_pass + error_page-5xx-to-200
              # fail-open (poison-fountain down => 200 allowed), minus the
              # per-request connect attempt that logged ~51k errors/hr once pod
              # logs shipped to Loki (2026-06-05) and cost up to 100ms/req. To
              # re-enable the trap: restore the upstream + proxy_pass (git
              # history) and scale poison-fountain up.
              return 200 "allowed";
          }
          location /healthz {
              access_log off;
              return 200 "ok";
          }
      }
    EOT
  }
}

resource "kubernetes_deployment" "bot_block_proxy" {
  metadata {
    name      = "bot-block-proxy"
    namespace = kubernetes_namespace.traefik.metadata[0].name
    labels = {
      app = "bot-block-proxy"
    }
    annotations = {
      # openresty does not hot-reload its ConfigMap-mounted default.conf, so a
      # config change needs a pod roll. Reloader watches the named ConfigMap and
      # rolls this Deployment on change (the missing piece that let stale config
      # run for days before 2026-06-05).
      "configmap.reloader.stakater.com/reload" = "bot-block-proxy-config"
    }
  }

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
      match_labels = {
        app = "bot-block-proxy"
      }
    }
    template {
      metadata {
        labels = {
          app = "bot-block-proxy"
        }
      }
      spec {
        topology_spread_constraint {
          max_skew           = 1
          topology_key       = "kubernetes.io/hostname"
          when_unsatisfiable = "DoNotSchedule"
          label_selector {
            match_labels = {
              app = "bot-block-proxy"
            }
          }
        }
        container {
          name  = "nginx"
          image = "openresty/openresty:alpine"

          port {
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
              cpu    = "5m"
              memory = "64Mi"
            }
            limits = {
              memory = "64Mi"
            }
          }
        }

        volume {
          name = "config"
          config_map {
            name = kubernetes_config_map.bot_block_proxy_config.metadata[0].name
          }
        }
      }
    }
  }
  lifecycle {
    # KYVERNO_LIFECYCLE_V1: Kyverno admission webhook mutates dns_config with ndots=2
    ignore_changes = [
      spec[0].template[0].spec[0].dns_config,
      # KEEL_LIFECYCLE_V1: keel.sh annotations + tier label are stamped on the
      # live object (keel enrollment / resource-governance) — don't strip them.
      metadata[0].annotations["keel.sh/policy"],
      metadata[0].annotations["keel.sh/trigger"],
      metadata[0].annotations["keel.sh/pollSchedule"],
      metadata[0].annotations["keel.sh/match-tag"],
      metadata[0].labels["tier"],
      spec[0].template[0].metadata[0].annotations["keel.sh/update-time"], # KEEL_LIFECYCLE_V1
      spec[0].template[0].spec[0].container[0].image,                     # KEEL_IGNORE_IMAGE
    ]
  }
}

resource "kubernetes_service" "bot_block_proxy" {
  metadata {
    name      = "bot-block-proxy"
    namespace = kubernetes_namespace.traefik.metadata[0].name
    labels = {
      app = "bot-block-proxy"
    }
  }

  spec {
    selector = {
      app = "bot-block-proxy"
    }
    port {
      name        = "http"
      port        = 8080
      target_port = 8080
    }
  }
}

# x402 payment gateway — shared forwardAuth target for every ingress that
# wants to issue HTTP 402 to declared AI-bot UAs / accept X-PAYMENT for paid
# access. One deployment serves all hosts; each consumer ingress just adds
# `traefik-x402@kubernetescrd` to its middleware chain.
#
# DRY_RUN until `var.x402_wallet_address` is set. While dry-run, every
# auth call returns 200 (allow) so traffic is unaffected.
resource "kubernetes_deployment" "x402_gateway" {
  metadata {
    name      = "x402-gateway"
    namespace = kubernetes_namespace.traefik.metadata[0].name
    labels    = { app = "x402-gateway" }
  }

  spec {
    replicas = 2 # Stateless; HA across two pods is cheap.
    selector {
      match_labels = { app = "x402-gateway" }
    }
    strategy {
      type = "RollingUpdate"
      rolling_update {
        max_surge       = 1
        max_unavailable = 0
      }
    }
    template {
      metadata {
        labels = { app = "x402-gateway" }
      }
      spec {
        image_pull_secrets {
          name = "registry-credentials"
        }
        topology_spread_constraint {
          max_skew           = 1
          topology_key       = "kubernetes.io/hostname"
          when_unsatisfiable = "ScheduleAnyway"
          label_selector {
            match_labels = { app = "x402-gateway" }
          }
        }
        container {
          name  = "x402-gateway"
          image = "ghcr.io/viktorbarzin/x402-gateway:latest"
          port {
            name           = "http"
            container_port = 8923
          }
          port {
            name           = "metrics"
            container_port = 9090
          }
          env {
            name  = "MODE"
            value = "forwardauth"
          }
          env {
            name  = "BIND"
            value = ":8923"
          }
          env {
            name  = "METRICS_BIND"
            value = ":9090"
          }
          env {
            name  = "WALLET_ADDRESS"
            value = var.x402_wallet_address
          }
          env {
            name  = "PRICE_LABEL"
            value = "$0.01"
          }
          env {
            name  = "PRICE_USDC_MICROS"
            value = "10000"
          }
          env {
            name  = "NETWORK"
            value = "base"
          }
          env {
            name  = "FACILITATOR_URL"
            value = "https://x402.org/facilitator"
          }
          # Slack incoming-webhook for real-time payment notifications.
          # Reuses the existing Alertmanager channel — payment events appear
          # alongside infra alerts. Reads from secret/viktor.alertmanager_slack_api_url.
          env {
            name  = "NOTIFY_WEBHOOK_URL"
            value = var.x402_notify_webhook_url
          }
          # Local sources are never asked to pay. Our own browsing and our own
          # automation present exactly the UAs BOT_UA_REGEX charges for
          # (python-requests, scrapy, HeadlessChrome, ClaudeBot), so without
          # this the local-browsing bypass would end at Anubis and every local
          # script would get a 402 instead of the app. The gateway matches this
          # against X-Real-Ip, which the real-ip plugin stamps with the
          # unspoofable TCP peer earlier in the chain — a client cannot forge it.
          #
          # MIRRORS the canonical list in
          # modules/kubernetes/anubis_instance/main.tf (var.trusted_local_cidrs).
          # Two copies on purpose: CI fans a modules/ edit out to that module's
          # consuming app stacks, and a stacks/traefik edit re-applies this
          # platform stack — so each copy is applied where it is edited. A single
          # shared definition would leave one side unapplied. CHANGE BOTH.
          #
          # Private + CGNAT only; our public egress IP (176.12.22.76) is
          # deliberately absent, so the skip is unreachable from the internet.
          env {
            name  = "TRUSTED_CIDRS"
            value = "10.0.0.0/8,172.16.0.0/12,192.168.0.0/16,100.64.0.0/10,fc00::/7,fe80::/10"
          }
          resources {
            requests = {
              cpu    = "10m"
              memory = "64Mi"
            }
            limits = {
              memory = "128Mi"
            }
          }
          liveness_probe {
            http_get {
              path = "/healthz"
              port = "metrics"
            }
            initial_delay_seconds = 5
            period_seconds        = 30
          }
          readiness_probe {
            http_get {
              path = "/healthz"
              port = "metrics"
            }
            initial_delay_seconds = 1
            period_seconds        = 5
          }
          security_context {
            run_as_non_root            = true
            run_as_user                = 65532
            run_as_group               = 65532
            allow_privilege_escalation = false
            read_only_root_filesystem  = true
            capabilities {
              drop = ["ALL"]
            }
          }
        }
      }
    }
  }

  lifecycle {
    # KYVERNO_LIFECYCLE_V1: Kyverno admission webhook mutates dns_config with ndots=2
    ignore_changes = [
      spec[0].template[0].spec[0].dns_config,
      # KEEL_IGNORE_IMAGE: the GHA->ghcr build (ADR-0002 infra#28) set-images
      # the running :sha8 tag; don't let terragrunt revert it to :latest.
      spec[0].template[0].spec[0].container[0].image,
      # KEEL_LIFECYCLE_V1: keel.sh annotations + tier label are stamped on the
      # live object (keel enrollment / resource-governance) — don't strip them.
      metadata[0].annotations["keel.sh/policy"],
      metadata[0].annotations["keel.sh/trigger"],
      metadata[0].annotations["keel.sh/pollSchedule"],
      metadata[0].annotations["keel.sh/match-tag"],
      metadata[0].labels["tier"],
      spec[0].template[0].metadata[0].annotations["keel.sh/update-time"], # KEEL_LIFECYCLE_V1
    ]
  }
}

resource "kubernetes_service" "x402_gateway" {
  metadata {
    name      = "x402-gateway"
    namespace = kubernetes_namespace.traefik.metadata[0].name
    labels    = { app = "x402-gateway" }
    annotations = {
      "prometheus.io/scrape" = "true"
      "prometheus.io/path"   = "/metrics"
      "prometheus.io/port"   = "9090"
    }
  }

  spec {
    selector = { app = "x402-gateway" }
    port {
      name        = "http"
      port        = 8080
      target_port = 8923
    }
    port {
      name        = "metrics"
      port        = 9090
      target_port = 9090
    }
  }
}

resource "kubernetes_pod_disruption_budget_v1" "x402_gateway" {
  metadata {
    name      = "x402-gateway"
    namespace = kubernetes_namespace.traefik.metadata[0].name
  }
  spec {
    min_available = "1"
    selector {
      match_labels = { app = "x402-gateway" }
    }
  }
}

# Resilience proxy for Authentik ForwardAuth
# Falls back to basicAuth when Authentik is unreachable
resource "kubernetes_secret" "auth_proxy_htpasswd" {
  metadata {
    name      = "auth-proxy-htpasswd"
    namespace = kubernetes_namespace.traefik.metadata[0].name
  }

  data = {
    "htpasswd" = var.auth_fallback_htpasswd
  }
}

resource "kubernetes_config_map" "auth_proxy_config" {
  metadata {
    name      = "auth-proxy-config"
    namespace = kubernetes_namespace.traefik.metadata[0].name
  }

  data = {
    "default.conf" = <<-EOT
      upstream authentik {
          # Forward-auth MUST be answered by the SAME outpost that answers the
          # OAuth callback, and the callback is the standalone Deployment:
          # authentik.viktorbarzin.me/outpost.goauthentik.io is routed to
          # ak-outpost-authentik-embedded-outpost by BOTH the authentik-outpost
          # Ingress (ours) and the ak-outpost-... Ingress (the outpost
          # controller's, which we do not own and cannot durably repoint).
          #
          # Do NOT point this at goauthentik-server (the inline outpost inside
          # the server pods). The two implementations issue the SAME cookie
          # name on the SAME domain in mutually unreadable formats:
          #
          #   inline (Rust)      authentik_proxy_34f8da53=<b64 hmac>=<uuid>
          #   standalone (Go)    authentik_proxy_34f8da53=<base32 session id>
          #
          # Split across the two, a logged-in user loops forever: forward-auth
          # (inline) cannot read the cookie the callback (standalone) just set,
          # so it 302s to login, the callback re-issues a Go cookie, and round
          # it goes. Nothing reaches the backend -- OriginStatus 0 on every
          # request, XHR included, which is what took terminal.viktorbarzin.me
          # and every other auth="required" host down on 2026-09-02 10:52.
          # An anonymous probe cannot see this: 302-to-login is the CORRECT
          # answer for a request with no session, so the whole estate looked
          # healthy while every signed-in request was in a loop.
          #
          # STILL OPEN: nginx OSS resolves this name ONCE at startup and caches
          # the IP for the life of the process, while the outpost controller
          # RECREATES this Service on upgrades with a fresh ClusterIP. nginx
          # then dials a dead address, the 3s connect timeout trips, and
          # error_page hands every forward-auth host to @fallback_auth =
          # Emergency Access basic-auth (the 2026-08-19 outage). The fix is a
          # target the controller never recreates -- a Terraform-owned Service
          # selecting the same pods -- NOT a different outpost.
          server ak-outpost-authentik-embedded-outpost.authentik.svc.cluster.local:9000;
          # Reuse connections to the outpost. Without this every forward-auth
          # subrequest (= every request to every auth="required" ingress) opens
          # a fresh TCP connection. Requires HTTP/1.1 + cleared Connection
          # header on the proxy_pass locations below.
          keepalive 32;
      }
      server {
          listen 9000;

          # Browsers accumulate one authentik_proxy_<random> cookie per Authentik
          # Proxy Provider on the parent domain. With 30+ services under
          # viktorbarzin.me the combined Cookie header exceeds nginx's default
          # 4 x 8k large_client_header_buffers and trips "Too big request header"
          # (431). Bump to 8 x 64k so the auth check accepts the pile.
          client_header_buffer_size 8k;
          large_client_header_buffers 8 64k;

          location /outpost.goauthentik.io/auth/traefik {
              proxy_pass http://authentik;
              proxy_http_version 1.1;
              proxy_set_header Connection "";
              proxy_connect_timeout 3s;
              proxy_read_timeout 5s;
              proxy_send_timeout 5s;
              proxy_intercept_errors on;
              error_page 502 503 504 = @fallback_auth;
              proxy_set_header Host $host;
              proxy_set_header X-Real-IP $remote_addr;
              proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
              proxy_set_header X-Forwarded-Proto $scheme;
              proxy_set_header X-Original-URL $scheme://$http_host$request_uri;
          }

          location @fallback_auth {
              auth_basic "Emergency Access";
              auth_basic_user_file /etc/nginx/htpasswd;
              # Set ALL X-authentik-* headers to prevent client-supplied header spoofing.
              # Without this, a client could inject fake X-authentik-groups and backends
              # that trust these headers would grant elevated access.
              add_header X-authentik-username $remote_user always;
              add_header X-authentik-uid "" always;
              add_header X-authentik-email "" always;
              add_header X-authentik-name "" always;
              add_header X-authentik-groups "" always;
              add_header X-Auth-Fallback "true" always;
              root /usr/share/nginx/fallback;
              try_files /ok =403;
          }

          location /outpost.goauthentik.io/ {
              proxy_pass http://authentik;
              proxy_http_version 1.1;
              proxy_set_header Connection "";
              proxy_connect_timeout 3s;
              proxy_read_timeout 10s;
              proxy_set_header Host $host;
              proxy_set_header X-Real-IP $remote_addr;
              proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
              proxy_set_header X-Forwarded-Proto $scheme;
          }

          location /healthz {
              access_log off;
              return 200 "ok";
          }
      }
    EOT
  }
}

resource "kubernetes_config_map" "auth_proxy_fallback" {
  metadata {
    name      = "auth-proxy-fallback"
    namespace = kubernetes_namespace.traefik.metadata[0].name
  }

  data = {
    "ok" = "authenticated"
  }
}

resource "kubernetes_deployment" "auth_proxy" {
  metadata {
    name      = "auth-proxy"
    namespace = kubernetes_namespace.traefik.metadata[0].name
    labels = {
      app = "auth-proxy"
    }
  }

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
      match_labels = {
        app = "auth-proxy"
      }
    }
    template {
      metadata {
        labels = {
          app = "auth-proxy"
        }
        annotations = {
          # nginx only reads its config at startup — roll the pods whenever
          # the ConfigMap content changes.
          "checksum/auth-proxy-config" = sha1(kubernetes_config_map.auth_proxy_config.data["default.conf"])
          # The emergency-fallback htpasswd is a subPath secret mount, which
          # does NOT auto-update on change — roll the pods when it rotates so a
          # regenerated emergency password actually takes effect.
          "checksum/auth-proxy-htpasswd" = sha1(var.auth_fallback_htpasswd)
        }
      }
      spec {
        topology_spread_constraint {
          max_skew           = 1
          topology_key       = "kubernetes.io/hostname"
          when_unsatisfiable = "DoNotSchedule"
          label_selector {
            match_labels = {
              app = "auth-proxy"
            }
          }
        }
        container {
          name  = "nginx"
          image = "nginx:1-alpine"

          port {
            container_port = 9000
          }

          volume_mount {
            name       = "config"
            mount_path = "/etc/nginx/conf.d"
            read_only  = true
          }
          volume_mount {
            name       = "htpasswd"
            mount_path = "/etc/nginx/htpasswd"
            sub_path   = "htpasswd"
            read_only  = true
          }
          volume_mount {
            name       = "fallback"
            mount_path = "/usr/share/nginx/fallback"
            read_only  = true
          }

          liveness_probe {
            http_get {
              path = "/healthz"
              port = 9000
            }
            initial_delay_seconds = 3
            period_seconds        = 10
          }
          readiness_probe {
            http_get {
              path = "/healthz"
              port = 9000
            }
            initial_delay_seconds = 2
            period_seconds        = 5
          }

          resources {
            requests = {
              cpu    = "5m"
              memory = "64Mi"
            }
            limits = {
              memory = "64Mi"
            }
          }
        }

        volume {
          name = "config"
          config_map {
            name = kubernetes_config_map.auth_proxy_config.metadata[0].name
          }
        }
        volume {
          name = "htpasswd"
          secret {
            secret_name = kubernetes_secret.auth_proxy_htpasswd.metadata[0].name
          }
        }
        volume {
          name = "fallback"
          config_map {
            name = kubernetes_config_map.auth_proxy_fallback.metadata[0].name
          }
        }
      }
    }
  }
  lifecycle {
    # KYVERNO_LIFECYCLE_V1: Kyverno admission webhook mutates dns_config with ndots=2
    ignore_changes = [
      spec[0].template[0].spec[0].dns_config,
      # KEEL_LIFECYCLE_V1: keel.sh annotations + tier label are stamped on the
      # live object (keel enrollment / resource-governance) — don't strip them.
      metadata[0].annotations["keel.sh/policy"],
      metadata[0].annotations["keel.sh/trigger"],
      metadata[0].annotations["keel.sh/pollSchedule"],
      metadata[0].annotations["keel.sh/match-tag"],
      metadata[0].labels["tier"],
      spec[0].template[0].metadata[0].annotations["keel.sh/update-time"], # KEEL_LIFECYCLE_V1
      spec[0].template[0].spec[0].container[0].image,                     # KEEL_IGNORE_IMAGE
    ]
  }
}

resource "kubernetes_service" "auth_proxy" {
  metadata {
    name      = "auth-proxy"
    namespace = kubernetes_namespace.traefik.metadata[0].name
    labels = {
      app = "auth-proxy"
    }
  }

  spec {
    selector = {
      app = "auth-proxy"
    }
    port {
      name        = "http"
      port        = 9000
      target_port = 9000
    }
  }
}

# Scrape target for the quic-socket-metrics sidecar (see deployment.additionalContainers).
#
# The kubernetes-pods Prometheus job explicitly DROPS the traefik namespace, so
# pod annotations would be ignored here. Service annotations are the working
# path in this namespace — the x402-gateway Service above is scraped the same
# way, via the kubernetes-service-endpoints job.
#
# TRAP: that job also applies a metric-NAME allowlist. `node_netstat_Udp_.*` was
# added to it in prometheus_chart_values.tpl for this; without that entry the
# target scrapes green and every series is silently dropped.
resource "kubernetes_service" "traefik_quic_socket_metrics" {
  metadata {
    name      = "traefik-quic-socket-metrics"
    namespace = kubernetes_namespace.traefik.metadata[0].name
    labels    = { app = "traefik-quic-socket-metrics" }
    annotations = {
      "prometheus.io/scrape" = "true"
      "prometheus.io/path"   = "/metrics"
      "prometheus.io/port"   = "9101"
    }
  }

  spec {
    # Selects the Traefik pods themselves; each replica becomes its own
    # endpoint, so a single node's overflowing socket is still visible.
    selector = {
      "app.kubernetes.io/name"     = "traefik"
      "app.kubernetes.io/instance" = "traefik-traefik"
    }
    port {
      name        = "quicmetrics"
      port        = 9101
      target_port = 9101
    }
  }
}
