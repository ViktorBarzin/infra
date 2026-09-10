variable "tls_secret_name" {}
variable "homepage_username" {}
variable "homepage_password" {}
variable "db_password" {}
variable "enroll_key" {}
variable "crowdsec_dash_api_key" {
  type      = string
  sensitive = true
}
variable "crowdsec_dash_machine_id" { type = string } # used for web dash
variable "crowdsec_dash_machine_password" {
  type      = string
  sensitive = true
}
variable "tier" { type = string }
variable "slack_webhook_url" { type = string }
variable "mysql_host" { type = string }
variable "postgresql_host" { type = string }
variable "firewall_bouncer_key" {
  type        = string
  sensitive   = true
  description = "API key for the cs-firewall-bouncer DaemonSet (direct-host in-kernel enforcement). Seeded into LAPI via BOUNCER_KEY_firewall; the DaemonSet presents the same key to stream decisions."
}
variable "traefik_bouncer_key" {
  type        = string
  sensitive   = true
  description = "API key for the in-process Traefik bouncer plugin (L7 enforcement on the websecure entrypoint, which is the only layer that sees the real client IP for Cloudflare-proxied hosts). Seeded into LAPI via BOUNCER_KEY_traefik; the crowdsec Middleware in stacks/traefik presents the same key to poll decisions."
}

module "tls_secret" {
  source          = "../../../../modules/kubernetes/setup_tls_secret"
  namespace       = kubernetes_namespace.crowdsec.metadata[0].name
  tls_secret_name = var.tls_secret_name
}

resource "kubernetes_namespace" "crowdsec" {
  metadata {
    name = "crowdsec"
    labels = {
      tier                               = var.tier
      "resource-governance/custom-quota" = "true"
      "keel.sh/enrolled"                 = "true"
    }
  }
  lifecycle {
    # KYVERNO_LIFECYCLE_V1: goldilocks-vpa-auto-mode ClusterPolicy stamps this label on every namespace
    ignore_changes = [metadata[0].labels["goldilocks.fairwinds.com/vpa-update-mode"]]
  }
}

resource "kubernetes_config_map" "crowdsec_custom_scenarios" {
  metadata {
    name      = "crowdsec-custom-scenarios"
    namespace = kubernetes_namespace.crowdsec.metadata[0].name
    labels = {
      "app.kubernetes.io/name" = "crowdsec"
    }
  }

  data = {
    "http-403-abuse.yaml" = <<-YAML
      type: leaky
      name: crowdsecurity/http-403-abuse
      description: "Detect IPs triggering too many HTTP 403s in NGINX ingress logs"
      filter: "evt.Meta.log_type == 'http_access-log' && evt.Parsed.status == '403'"
      groupby: "evt.Meta.source_ip"
      leakspeed: "2s"
      capacity: 10
      blackhole: 5m
      labels:
        service: http
        behavior: abusive_403
        remediation: true
    YAML
    # ---------------------------------------------------------------------
    # Two hub scenarios re-declared LOCALLY to fix their groupby. Upstream both
    # group by "evt.Meta.source_ip + '/' + evt.Parsed.target_fqdn", but NEITHER
    # traefik parser path ever creates evt.PARSED.target_fqdn — verified with
    # `cscli explain` on a real access-log line in both formats (CLF, and JSON
    # since 2026-09-01): the field is absent from evt.Parsed in both, while
    # traefik_router_name is populated
    # ("forgejo-forgejo-forgejo-viktorbarzin-me@kubernetes"). The JSON node of
    # crowdsecurity/traefik-logs does set target_fqdn, but as `meta:`, so it
    # lands in evt.META.target_fqdn — a different map from the one upstream's
    # groupby reads. The same finding is why the nextcloud-webdav whitelist
    # below is scoped by traefik_router_name.
    #
    # Grouping by router rather than by host is kept deliberately now that
    # evt.Meta.target_fqdn exists: a router is at least as specific as a host
    # (several routers can share one host), so switching would loosen the key
    # rather than tighten it, and it is not a change worth riding along with a
    # log-format change.
    #
    # So the key collapses to "<ip>/" and every host shares ONE bucket per IP.
    # That is more aggressive than upstream intends, not less: 10 distinct 404
    # paths spread across ten different hosts look identical to 10 probes against
    # one. Grouping by router restores the per-host partitioning upstream is
    # written for, which is a LOOSENING — it removes cross-host false positives
    # rather than adding detections.
    #
    # These are verbatim copies of the hub definitions with ONLY groupby changed,
    # so they need re-diffing against the hub when crowdsec's collections update.
    "http-probing.yaml" : <<-YAML
      # 404 scan
      type: leaky
      name: crowdsecurity/http-probing
      description: "Detect site scanning/probing from a single ip"
      filter: "evt.Meta.service == 'http' && evt.Meta.http_status in ['404', '403', '400'] && evt.Parsed.static_ressource == 'false'"
      groupby: "evt.Meta.source_ip + '/' + evt.Parsed.traefik_router_name"
      distinct: "evt.Meta.http_path"
      capacity: 10
      reprocess: true
      leakspeed: "10s"
      blackhole: 5m
      labels:
        remediation: true
        classification:
          - attack.T1595
        behavior: "http:scan"
        label: "HTTP Probing"
        spoofable: 0
        service: http
        confidence: 1
      YAML
    "http-crawl-non_statics.yaml" : <<-YAML
      type: leaky
      name: crowdsecurity/http-crawl-non_statics
      description: "Detect aggressive crawl on non static resources"
      filter: "evt.Meta.log_type in ['http_access-log', 'http_error-log'] && evt.Parsed.static_ressource == 'false' && evt.Parsed.verb in ['GET', 'HEAD']"
      distinct: "evt.Parsed.file_name"
      leakspeed: 0.5s
      capacity: 40
      cache_size: 5
      groupby: "evt.Meta.source_ip + '/' + evt.Parsed.traefik_router_name"
      blackhole: 1m
      labels:
        confidence: 1
        spoofable: 0
        classification:
          - attack.T1595
        behavior: "http:crawl"
        service: http
        label: "Aggressive Crawl"
        remediation: true
      YAML
    # viktor/forgejo-crawl-slow LIVED HERE and was retired 2026-09-10 on
    # Viktor's call. The scenario and the measurements behind its thresholds are
    # in the history of this file, one commit back.
    #
    # Why it went: measured on node3 during a live crawl, once the agents were
    # finally scraped, it held 12,521 leaky buckets and had overflowed 0 times,
    # against viktor/distributed-crawl-range's 1,373 buckets and 5,023
    # overflows. It grouped by IPv6 /64 and this crawler rotates ACROSS /64s, so
    # nearly every request minted a bucket that caught nobody. Each bucket
    # carries a queue of parsed events, so the agent climbed 566 -> 788 MiB in
    # two hours against the 1 GiB limit raised the day before. An OOM restarts
    # the pod and drops EVERY scenario's in-memory state, so a detector catching
    # nothing was endangering the one doing the work.
    #
    # What is given up: it was written for a SLOW crawler reading forgejo
    # patiently from a single address. It never caught one, and Anubis has
    # fronted forgejo since 2026-09-09, which challenges exactly that client.
    # A crawl that sends ONE request per source address, from hundreds of
    # addresses at once. Groups by the source's registered prefix
    # (evt.Meta.SourceRange, from crowdsecurity/geoip-enrich) and counts DISTINCT
    # ADDRESSES rather than requests, because the number of addresses is the only
    # part of the signature that separates this from ordinary traffic.
    #
    # WHY NEITHER EXISTING SCENARIO SEES IT. Measured on the live agent
    # 2026-09-09: crowdsecurity/http-crawl-non_statics instantiated 10,510
    # buckets, poured 1.3 events into each, and overflowed 0 times.
    # viktor/forgejo-crawl-slow groups by IPv6 /64 and fails the same way,
    # because this crawler rotates ACROSS /64s. Per-source bucketing cannot
    # work on one request per address, whatever the threshold.
    #
    # WHY DISTINCT ADDRESSES AND NOT REQUEST RATE. A per-range request-rate
    # bucket cannot separate the two populations: the crawl ran at ~150-210
    # req/min per range, while the largest confirmed legitimate single client
    # here bursts to 587 req/min (Viktor's phone syncing to immich). Distinct
    # addresses per range separates them by two orders of magnitude, and 587
    # requests from one phone pour exactly ONE token.
    #
    # MEASURED, three windows of traefik access logs (distinct source addresses
    # per netblock, private + CGNAT excluded):
    #
    #   window                          legitimate max   crawler /29s
    #   2026-09-08 12:00-12:05Z         2                27, 36, 50, 56, 58
    #   2026-09-08 19:00-19:05Z         3                42, 52, 55, 61, 61
    #   2026-09-09 08:05-08:06Z (1min)  3                328, 328, 338, 338
    #
    # Legitimate p99 is 2-3 addresses per netblock in every window, and the
    # median is 1. capacity 30 sits 10x above the measured legitimate ceiling
    # and fills in ~5s at the crawl's peak rate.
    #
    # leakspeed 30s drains 2 addresses/minute, so a range that presents a new
    # client every half minute forever never overflows; only a burst of 30
    # net-new addresses does.
    #
    # SIX rotating-proxy ranges were active in those windows
    # (2a10:4a00::/29, 2a10:7b00::/29, 2a12:da80::/29, 2a12:f540::/29,
    # 2a13:dcc0::/29, 2a13:f40::/29) while the static blocklist added the same
    # day covers two ASNs. That gap is what this scenario is for: it needs no
    # list, no ASN lookup and no advance knowledge of the operator.
    #
    # GROUPED BY SourceRange, NOT BY ASN, for three reasons:
    #   - The two databases disagree. MaxMind resolves the crawler's addresses
    #     to AS54852 / F4-NETWORKS where RIPE's route object says AS214483, so
    #     an AS-keyed rule's behaviour depends on which one you ask.
    #   - scope: AS is SILENTLY DISCARDED by our Traefik bouncer plugin, which
    #     handles only `ip` and `range` (crowdsec-bouncer-plugin/main.go:193-197).
    #     An AS-scoped decision would detect and then enforce nothing — the same
    #     shape as the captcha_remediation trap removed on 2026-09-02.
    #   - Detection and enforcement stay the same prefix, so the ban covers
    #     exactly what tripped it.
    #
    # EMPTY-SourceRange FALLBACK. GeoLite2-ASN.mmdb is baked into the image and
    # dated 11 May, so a prefix allocated since then resolves to nothing. Without
    # the fallback every unknown source would share one bucket keyed "" and emit
    # a decision with an empty scope; with it they fall back to /64 (IPv6) or /24
    # (IPv4). A crawler inside an unknown prefix then gets one bucket per /64
    # again, which is the pre-existing blind spot rather than a new one — the
    # durable fix is refreshing the mmdb.
    #
    # A false positive bans one registered prefix for 4h via
    # default_range_remediation, announces it in Slack, and lifts with
    # `homelab crowdsec unban <cidr>` — NOT `cscli decisions delete --ip`, which
    # does not match a range-scoped decision (docs/runbooks/crowdsec-manual-bans.md).
    "distributed-crawl-range.yaml" : <<-YAML
      type: leaky
      name: viktor/distributed-crawl-range
      description: "Detect a crawl spread across many addresses in one registered prefix"
      filter: "evt.Meta.log_type in ['http_access-log', 'http_error-log']"
      # Distinct ADDRESSES, not distinct pages: one request per address is the
      # whole signature, so counting requests would see nothing.
      distinct: "evt.Meta.source_ip"
      capacity: 30
      leakspeed: 30s
      # cache_size >= capacity, so an evicted address cannot pour a second time
      # and inflate the count (same reasoning as forgejo-crawl-slow above).
      cache_size: 60
      groupby: 'evt.Meta.SourceRange != "" ? evt.Meta.SourceRange : (IsIPV6(evt.Meta.source_ip) ? IpToRange(evt.Meta.source_ip, "/64") : IpToRange(evt.Meta.source_ip, "/24"))'
      scope:
        type: Range
        expression: 'evt.Meta.SourceRange != "" ? evt.Meta.SourceRange : (IsIPV6(evt.Meta.source_ip) ? IpToRange(evt.Meta.source_ip, "/64") : IpToRange(evt.Meta.source_ip, "/24"))'
      blackhole: 5m
      labels:
        confidence: 3
        spoofable: 0
        classification:
          - attack.T1595
        behavior: "http:crawl"
        service: http
        label: "Distributed crawl from one registered prefix"
        remediation: true
    YAML
    "http-429-abuse.yaml" : <<-YAML
      type: leaky
      name: crowdsecurity/http-429-abuse
      description: "Detect IPs repeatedly triggering rate-limit (HTTP 429)"
      filter: "evt.Meta.log_type == 'http_access-log' && evt.Parsed.status == '429'"
      groupby: "evt.Meta.source_ip"
      leakspeed: "10s"
      capacity: 5
      blackhole: 1m
      labels:
        service: http
        behavior: rate_limit_abuse
        remediation: true
      YAML
  }
}

# Whitelist for trusted IPs that should never be blocked
resource "kubernetes_config_map" "crowdsec_whitelist" {
  metadata {
    name      = "crowdsec-whitelist"
    namespace = kubernetes_namespace.crowdsec.metadata[0].name
    labels = {
      "app.kubernetes.io/name" = "crowdsec"
    }
  }

  data = {
    "whitelist.yaml" = <<-YAML
      name: crowdsecurity/whitelist-trusted-ips
      description: "Whitelist for trusted IPs that should never be blocked"
      whitelist:
        reason: "Trusted IP - never block"
        ip:
          - "176.12.22.76" # home / Sofia egress (origin)
          # London flat egress. Pinned 2026-09-02 alongside removing the
          # captcha divert, which turned four FP-prone HTTP scenarios into real
          # bans. This exact address was hand-banned for 363 days on 2026-08-16
          # when a Nextcloud client retry loop was mistaken for an external
          # attacker; it is dynamic in principle, so re-check it with
          # `homelab ha ssh --instance london -- curl -s ifconfig.me` if someone
          # in London reports being blocked.
          - "137.220.71.46"
        cidr:
          # Meta CORPORATE egress, Viktor's work VPN. Added 2026-09-07 after
          # finding he was blocked from his own sites twice over whenever it was
          # on: this /44 was inside the static Meta-ASN blocklist (removed from
          # it in the same commit), AND viktor/forgejo-crawl-slow had separately
          # banned 2620:10d:c092:400::4:2f8a, a single address inside it, which
          # was him browsing.
          #
          # This is NOT the crawler. The crawl runs from 2a03:2880::/32; corp
          # egress is a different prefix, so exempting it costs nothing against
          # the swarm. The occupants are employees on a managed network.
          #
          # NOTE the two halves are both needed and do different jobs: a
          # whitelist is PARSER-STAGE, so it stops scenarios from CREATING
          # decisions but does nothing about an already-imported one. Removing
          # the range from the static list is what lifts the existing block.
          - "2620:10d:c090::/44"
          # Never ban internal/cluster/LAN/tailnet sources. Enforcement (edge
          # Worker + firewall-bouncer) drops on real source IP, so an internal
          # range slipping into a decision could blackhole legit traffic — this
          # makes that structurally impossible at the decision layer.
          - "10.0.0.0/8"        # k8s nodes/pods/services + VLAN 10/20
          - "172.16.0.0/12"     # RFC1918
          - "192.168.0.0/16"    # LAN (192.168.1.0/24) + Sofia
          - "100.64.0.0/10"     # Headscale tailnet (CGNAT)
      ---
      name: viktor/immich-asset-paths-whitelist
      description: "Don't penalise legit Immich timeline bursts (mobile scrub, web grid)"
      # WAS INERT FROM THE DAY IT WAS WRITTEN UNTIL 2026-09-09. It read
      # evt.Parsed.target_fqdn, which no traefik parser path creates — the JSON
      # node writes evt.Meta.target_fqdn, a different map, and CLF writes
      # neither. `cscli explain` on an Immich 404 reported "unchanged" in both
      # log formats, so it never suppressed anything and Immich has had no
      # false-positive protection at all.
      #
      # Fixed here to evt.Parsed.traefik_router_name, the field
      # viktor/nextcloud-webdav-whitelist below already uses and which is
      # verified working at 4,397 suppressions. The router name is the FULL one
      # (immich-immich-immich-viktorbarzin-me@kubernetes, confirmed in the live
      # access log 2026-09-09) rather than a shorter substring, because
      # "immich-viktorbarzin-me" alone would also match the three
      # highlights-immich* routers, which are public share pages and are NOT
      # what this exemption is for.
      #
      # This does START suppressing detections, which is why it lands BEFORE the
      # new range-grouped scenario rather than after: tightening detection while
      # Immich's own exemption is dead is how the earlier self-blocking
      # happened.
      whitelist:
        reason: "Immich asset endpoints are auth-gated; mobile scrub legitimately bursts"
        expression:
          - >
            evt.Parsed.traefik_router_name contains "immich-immich-immich-viktorbarzin-me" &&
            (evt.Parsed.request startsWith "/api/assets/" ||
             evt.Parsed.request startsWith "/api/timeline/" ||
             evt.Parsed.request startsWith "/api/asset/" ||
             evt.Parsed.request startsWith "/api/search/" ||
             evt.Parsed.request startsWith "/api/memories" ||
             evt.Parsed.request startsWith "/api/albums" ||
             evt.Parsed.request startsWith "/api/activities")
      ---
      name: viktor/nextcloud-webdav-whitelist
      description: "Nextcloud WebDAV paths carry the account name 'admin' — not admin-panel probing"
      whitelist:
        reason: "Nextcloud-iOS/desktop PROPFIND 404s on /remote.php/dav/files/admin/... are legit sync misses; crowdsecurity/http-admin-interface-probing matches 'admin' in the path and banned the client's shared egress IP (Viktor's London Hyperoptic line, 2026-07-19). Scoped by traefik_router_name (no traefik parser path populates evt.Parsed.target_fqdn — the JSON node sets it as evt.Meta.target_fqdn instead, re-verified 2026-09-01) plus the Nextcloud-exclusive /remote.php/ prefix. Nextcloud's own auth (401/403) still gates it."
        expression:
          - >
            evt.Parsed.traefik_router_name contains "nextcloud-viktorbarzin-me" &&
            evt.Parsed.request startsWith "/remote.php/"
    YAML
  }
}


# Traefik access-log acquisition, OWNED HERE rather than generated by the chart.
#
# WHY: the chart renders every agent.acquisition entry with
#   force_inotify: true
#   poll_without_inotify: false
# and with inotify alone the agent stops reading after the log it opened is
# replaced. Measured 2026-09-03: the live container was writing traefik/3.log
# (928 KB, mtime 04:44) while the agent still held an open fd on traefik/2.log,
# last written 19:21 the previous evening. Lines read stayed frozen at 54,238
# across 80 fresh requests.
#
# Two things replace that file and both happen constantly here. A container
# restart moves the pod to the next N.log (traefik restarted five times on
# 2026-09-02 during the crawler incident), and kubelet rotates the file itself
# every 1.5-3 hours because traefik logs every request as JSON — four rotations
# of 3.log were on disk when this was found.
#
# CONSEQUENCE, and it is the real reason the Meta crawl was never banned: after
# each agent restart CrowdSec sees traefik for a couple of hours and is then
# blind until something restarts it again. Every http_* scenario is starved,
# not just the crawl one. The captcha divert removed earlier was a genuine bug
# on top of this, but it was the second one.
#
# poll_without_inotify makes the file source stat the path instead of trusting
# inotify, so it notices the inode change and reopens. The chart cannot express
# this per-entry, hence a hand-written acquisition file and the traefik entry
# removed from agent.acquisition in values.yaml.
#
# NOTE the same fault applies to the mailserver entries still generated by the
# chart; left alone deliberately to keep this change to the surface that was
# measured, and worth revisiting.
resource "kubernetes_config_map" "crowdsec_traefik_acquisition" {
  metadata {
    name      = "crowdsec-traefik-acquisition"
    namespace = kubernetes_namespace.crowdsec.metadata[0].name
    labels = {
      "app.kubernetes.io/name" = "crowdsec"
    }
  }

  data = {
    "traefik.yaml" = <<-YAML
      filenames:
        - /var/log/containers/traefik-*_traefik_traefik-*.log
      force_inotify: true
      poll_without_inotify: true
      labels:
        type: containerd
        program: traefik
    YAML
  }
}

# Syslog acquisition config for pfSense firewall log ingestion
resource "kubernetes_config_map" "crowdsec_syslog_acquisition" {
  metadata {
    name      = "crowdsec-syslog-acquisition"
    namespace = kubernetes_namespace.crowdsec.metadata[0].name
    labels = {
      "app.kubernetes.io/name" = "crowdsec"
    }
  }

  data = {
    "syslog.yaml" = <<-YAML
      source: syslog
      listen_addr: "0.0.0.0"
      listen_port: 514
      labels:
        type: pf
    YAML
  }
}

resource "helm_release" "crowdsec" {
  namespace        = kubernetes_namespace.crowdsec.metadata[0].name
  create_namespace = true
  name             = "crowdsec"
  atomic           = true
  version          = "0.21.0"

  repository = "https://crowdsecurity.github.io/helm-charts"
  chart      = "crowdsec"

  values        = [templatefile("${path.module}/values.yaml", { homepage_username = var.homepage_username, homepage_password = var.homepage_password, DB_PASSWORD = var.db_password, ENROLL_KEY = var.enroll_key, SLACK_WEBHOOK_URL = var.slack_webhook_url, mysql_host = var.mysql_host, postgresql_host = var.postgresql_host, FIREWALL_CROWDSEC_API_KEY = var.firewall_bouncer_key, TRAEFIK_CROWDSEC_API_KEY = var.traefik_bouncer_key })]
  timeout       = 1200
  wait          = true
  wait_for_jobs = true
}

# NodePort service for pfSense syslog → CrowdSec agent
# pfSense sends firewall logs to 10.0.20.202:30514 (any k8s node IP works)
resource "kubernetes_service" "crowdsec_syslog" {
  metadata {
    name      = "crowdsec-syslog"
    namespace = kubernetes_namespace.crowdsec.metadata[0].name
    labels = {
      app = "crowdsec-syslog"
    }
  }
  spec {
    type = "NodePort"
    selector = {
      "k8s-app" = "crowdsec"
      type      = "agent"
    }
    port {
      name        = "syslog-udp"
      port        = 514
      target_port = 514
      node_port   = 30514
      protocol    = "UDP"
    }
  }
}

# Deployment for my custom dashboard that helps me unblock myself when I blocklist myself
resource "kubernetes_deployment" "crowdsec-web" {
  metadata {
    name      = "crowdsec-web"
    namespace = kubernetes_namespace.crowdsec.metadata[0].name
    labels = {
      app                             = "crowdsec_web"
      "kubernetes.io/cluster-service" = "true"
      tier                            = var.tier
    }
  }
  spec {
    replicas = 1
    strategy {
      type = "RollingUpdate"
    }
    selector {
      match_labels = {
        app = "crowdsec_web"
      }
    }
    template {
      metadata {
        labels = {
          app                             = "crowdsec_web"
          "kubernetes.io/cluster-service" = "true"
        }
      }
      spec {
        priority_class_name = "tier-1-cluster"
        container {
          name  = "crowdsec-web"
          image = "viktorbarzin/crowdsec_web"
          env {
            name  = "CS_API_URL"
            value = "http://crowdsec-service.crowdsec.svc.cluster.local:8080/v1"
          }
          env {
            name  = "CS_API_KEY"
            value = var.crowdsec_dash_api_key
          }
          env {
            name  = "CS_MACHINE_ID"
            value = var.crowdsec_dash_machine_id
          }
          env {
            name  = "CS_MACHINE_PASSWORD"
            value = var.crowdsec_dash_machine_password
          }
          port {
            name           = "http"
            container_port = 8000
            protocol       = "TCP"
          }
          resources {
            requests = {
              cpu    = "15m"
              memory = "128Mi"
            }
            limits = {
              memory = "128Mi"
            }
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
    # KYVERNO_LIFECYCLE_V1: Kyverno admission webhook mutates dns_config with ndots=2
    ignore_changes = [
      spec[0].template[0].spec[0].dns_config,
      metadata[0].annotations["keel.sh/policy"],
      metadata[0].annotations["keel.sh/trigger"],
      metadata[0].annotations["keel.sh/pollSchedule"],                    # KYVERNO_LIFECYCLE_V2
      spec[0].template[0].metadata[0].annotations["keel.sh/update-time"], # KEEL_LIFECYCLE_V1
      spec[0].template[0].spec[0].container[0].image,                     # KEEL_IGNORE_IMAGE
    ]
  }
}

resource "kubernetes_service" "crowdsec-web" {
  metadata {
    name      = "crowdsec-web"
    namespace = kubernetes_namespace.crowdsec.metadata[0].name
    labels = {
      "app" = "crowdsec_web"
    }
  }

  spec {
    selector = {
      app = "crowdsec_web"
    }
    port {
      port        = "80"
      target_port = "8000"
    }
  }
}
module "ingress" {
  source    = "../../../../modules/kubernetes/ingress_factory"
  dns_type  = "proxied"
  namespace = kubernetes_namespace.crowdsec.metadata[0].name
  name      = "crowdsec-web"
  # Pin service_name explicitly (== name, so routing is unchanged) so
  # ingress_factory's real-ip auto-attach — startswith(var.service_name,
  # "anubis-") at ingress_factory/main.tf — doesn't hit the module's null
  # default and abort the whole crowdsec apply. Kept local to this stack; the
  # shared-module null-guard is a broader regression left to the in-flight
  # ingress_factory work (fixing it there forces a full-platform re-apply).
  service_name    = "crowdsec-web"
  auth            = "required"
  tls_secret_name = var.tls_secret_name
  extra_annotations = {
    "gethomepage.dev/description" = "CrowdSec decisions and alerts UI"
    "gethomepage.dev/icon"        = "crowdsec.png"
  }
}

# Static, reviewable blocklist: Meta's announced address space.
#
# On 2026-09-02 a Meta crawler swarm walked forgejo's git history — per-commit
# /commits, /src, /blame and /raw, the four most expensive pages the forge
# renders — from hundreds of addresses in AS32934, using spoofed desktop Chrome
# user-agents rather than declaring a bot. It OOMKilled all three traefik pods
# and forgejo itself, taking every ingress down intermittently.
#
# This lives in Terraform rather than as a `cscli decisions add` because ad-hoc
# decisions expire silently and nothing reminds anyone (the 363-day self-ban of
# 2026-08-16 is the counter-example in the other direction). The import step in
# the CronJob below re-applies it daily at 04:00 with a 168h duration, so the
# block renews itself and a deliberate `terraform apply` is what removes it.
#
# ACCEPTED COST, Viktor's decision: no Facebook, Instagram, WhatsApp or
# Messenger link previews for any viktorbarzin.me URL, because those fetches
# originate from this same address space. Outbound is unaffected — our own
# devices reaching Meta still work.
#
# Regenerate (772 announced prefixes collapse to 117 aggregates):
#   for as in AS32934 AS63293 AS54115; do
#     curl -s "https://stat.ripe.net/data/announced-prefixes/data.json?resource=$as" \
#       | jq -r '.data.prefixes[].prefix'
#   done | sort -u | python3 -c 'import sys,ipaddress as i; \
#       n=[i.ip_network(l.strip()) for l in sys.stdin if l.strip()]; \
#       print("\n".join(str(x) for x in list(i.collapse_addresses([a for a in n if a.version==4])) \
#                                      + list(i.collapse_addresses([a for a in n if a.version==6]))))'
resource "kubernetes_config_map" "crowdsec_static_blocklist" {
  metadata {
    name      = "crowdsec-static-blocklist"
    namespace = kubernetes_namespace.crowdsec.metadata[0].name
    labels = {
      "app.kubernetes.io/name" = "crowdsec"
    }
  }

  data = {
    # One CIDR per line — cscli decisions import --format values.
    "meta-asn.txt" = <<-LIST
      31.13.24.0/21
      31.13.64.0/18
      45.64.40.0/22
      57.141.0.0/24
      57.141.2.0/23
      57.141.4.0/23
      57.141.6.0/24
      57.141.8.0/24
      57.141.10.0/24
      57.141.12.0/23
      57.141.14.0/24
      57.141.16.0/22
      57.141.20.0/24
      57.141.22.0/24
      57.141.24.0/24
      57.144.0.0/14
      66.220.144.0/20
      69.63.176.0/20
      69.171.224.0/19
      74.119.76.0/22
      102.132.96.0/20
      102.132.112.0/24
      102.132.115.0/24
      102.132.116.0/23
      102.132.119.0/24
      102.132.120.0/23
      102.132.123.0/24
      102.132.125.0/24
      102.132.126.0/24
      102.221.188.0/22
      103.4.96.0/22
      129.134.0.0/17
      129.134.130.0/24
      129.134.132.0/24
      129.134.135.0/24
      129.134.136.0/22
      129.134.140.0/24
      129.134.143.0/24
      129.134.144.0/24
      129.134.148.0/23
      129.134.150.0/24
      129.134.154.0/23
      129.134.156.0/22
      129.134.160.0/22
      129.134.164.0/23
      129.134.168.0/21
      129.134.176.0/20
      129.134.194.0/23
      129.134.196.0/23
      157.240.0.0/17
      157.240.128.0/23
      157.240.131.0/24
      157.240.132.0/24
      157.240.134.0/24
      157.240.136.0/23
      157.240.139.0/24
      157.240.140.0/24
      157.240.156.0/22
      157.240.169.0/24
      157.240.170.0/24
      157.240.175.0/24
      157.240.177.0/24
      157.240.179.0/24
      157.240.181.0/24
      157.240.182.0/23
      157.240.184.0/21
      157.240.192.0/18
      163.70.128.0/17
      163.77.132.0/23
      163.77.136.0/23
      163.114.128.0/20
      173.252.64.0/18
      179.60.192.0/22
      185.60.216.0/22
      185.89.216.0/22
      199.201.64.0/22
      204.15.20.0/22
      2620:0:1c00::/40
      2a03:2880::/32
      2a03:2887:ff00::/48
      2a03:2887:ff02::/47
      2a03:2887:ff04::/46
      2a03:2887:ff09::/48
      2a03:2887:ff0a::/48
      2a03:2887:ff1b::/48
      2a03:2887:ff1e::/48
      2a03:2887:ff20::/48
      2a03:2887:ff22::/47
      2a03:2887:ff27::/48
      2a03:2887:ff28::/46
      2a03:2887:ff2e::/47
      2a03:2887:ff30::/48
      2a03:2887:ff33::/48
      2a03:2887:ff37::/48
      2a03:2887:ff38::/46
      2a03:2887:ff3e::/47
      2a03:2887:ff40::/46
      2a03:2887:ff44::/47
      2a03:2887:ff48::/46
      2a03:2887:ff4d::/48
      2a03:2887:ff4e::/47
      2a03:2887:ff50::/45
      2a03:2887:ff58::/47
      2a03:2887:ff5a::/48
      2a03:2887:ff5f::/48
      2a03:2887:ff60::/48
      2a03:2887:ff62::/47
      2a03:2887:ff64::/46
      2a03:2887:ff68::/46
      2a03:2887:ff6f::/48
      2a03:2887:ff70::/46
      2c0f:ef78:3::/48
      2c0f:ef78:5::/48
      2c0f:ef78:9::/48
      2c0f:ef78:c::/47
      2c0f:ef78:10::/47
    LIST

    # Static, reviewable blocklist: two IPv6 proxy-lease ASNs.
    #
    # On 2026-09-09 at 07:58Z a crawler walked forgejo's issue and pull-request
    # filter space — /viktor/infra/issues? and /pulls? with every combination of
    # labels, assignee, milestone, poster, project and state, which Forgejo
    # renders as a fresh DB query each time. 19,450 requests in 16 minutes
    # against a 48 req/min baseline.
    #
    # It was built to defeat per-IP detection: 1,993 distinct source addresses in
    # 2,000 sampled requests (one request per address), and eight spoofed desktop
    # Chrome/Edge user-agents rotated evenly. Every address traced to AS214483
    # (Rapidseedbox) or AS62610, both of which lease IPv6 space to rotating-proxy
    # operators. No rate-limit scenario can fire on a single request per address,
    # which is the same conclusion the 2026-09-02 Meta swarm reached and the
    # reason that block is also an ASN list rather than a scenario.
    #
    # Safe to block at ASN granularity: neither ASN served a single request to
    # any viktorbarzin.me host in the 7 days before the crawl (checked in Loki
    # across all eight /29s that appeared).
    #
    # ACCEPTED COST, Viktor's decision 2026-09-09: anyone reaching us from a
    # Rapidseedbox VPS or an AS62610 lease is refused on every host, not just
    # forgejo, because the firewall bouncer drops in-kernel. Outbound is
    # unaffected.
    #
    # Regenerate (754 announced prefixes collapse to 556 aggregates):
    #   for as in AS214483 AS62610; do
    #     curl -s "https://stat.ripe.net/data/announced-prefixes/data.json?resource=$as" \
    #       | jq -r '.data.prefixes[].prefix'
    #   done | sort -u | python3 -c 'import sys,ipaddress as i; \
    #       n=[i.ip_network(l.strip()) for l in sys.stdin if l.strip()]; \
    #       print("\n".join(str(x) for x in list(i.collapse_addresses([a for a in n if a.version==4])) \
    #                                      + list(i.collapse_addresses([a for a in n if a.version==6]))))'
    "proxy-asn.txt" = <<-LIST
      23.91.105.0/24
      23.136.164.0/24
      23.136.188.0/24
      23.137.204.0/24
      23.137.220.0/24
      23.137.228.0/24
      23.138.252.0/24
      23.139.108.0/24
      23.139.124.0/24
      23.139.148.0/24
      23.139.172.0/24
      23.139.188.0/24
      23.142.52.0/24
      23.142.188.0/24
      23.146.44.0/24
      23.147.36.0/24
      23.147.44.0/24
      23.148.244.0/24
      23.149.116.0/24
      23.149.140.0/24
      23.149.148.0/24
      23.149.156.0/24
      23.149.180.0/24
      23.149.204.0/24
      23.149.212.0/24
      23.149.244.0/24
      23.150.28.0/24
      23.150.36.0/24
      23.150.44.0/24
      23.150.52.0/24
      23.150.76.0/24
      23.150.100.0/24
      23.150.108.0/24
      23.150.116.0/24
      23.150.140.0/24
      23.150.148.0/24
      23.150.156.0/24
      23.150.188.0/24
      23.150.196.0/24
      23.150.212.0/24
      23.150.220.0/24
      23.150.236.0/24
      23.151.4.0/24
      23.151.12.0/24
      23.151.28.0/24
      23.152.52.0/24
      23.153.100.0/24
      23.153.124.0/24
      23.153.140.0/24
      23.169.0.0/24
      23.174.200.0/24
      23.185.16.0/24
      23.251.33.0/24
      23.251.36.0/22
      23.251.40.0/23
      23.251.43.0/24
      23.251.44.0/24
      23.251.47.0/24
      23.251.48.0/22
      23.251.52.0/24
      23.251.55.0/24
      23.251.56.0/22
      23.251.60.0/23
      23.251.62.0/24
      31.56.80.0/24
      31.56.217.0/24
      31.56.238.0/24
      31.57.213.0/24
      31.58.212.0/24
      38.67.19.0/24
      38.93.200.0/21
      38.179.80.0/21
      38.248.192.0/20
      38.248.208.0/21
      38.248.216.0/22
      38.248.220.0/23
      38.248.224.0/19
      43.224.150.0/24
      43.230.8.0/23
      43.252.210.0/24
      43.255.116.0/23
      45.12.185.0/24
      45.121.212.0/23
      45.121.214.0/24
      45.158.11.0/24
      46.202.101.0/24
      46.202.118.0/24
      46.202.124.0/24
      46.203.18.0/24
      46.203.31.0/24
      46.203.78.0/24
      46.203.155.0/24
      46.236.204.0/23
      46.236.206.0/24
      51.146.32.0/22
      51.194.251.0/24
      64.145.13.0/24
      64.204.8.0/24
      64.204.39.0/24
      64.204.133.0/24
      64.204.140.0/24
      64.204.162.0/24
      64.204.165.0/24
      64.204.172.0/24
      64.204.236.0/24
      64.205.176.0/22
      64.205.180.0/24
      64.205.182.0/24
      64.205.200.0/23
      64.205.203.0/24
      64.205.204.0/23
      64.205.206.0/24
      66.80.1.0/24
      66.92.5.0/24
      66.92.9.0/24
      66.92.10.0/24
      66.92.13.0/24
      66.92.17.0/24
      66.92.19.0/24
      66.93.8.0/24
      66.93.15.0/24
      66.93.29.0/24
      66.93.31.0/24
      66.93.33.0/24
      66.93.34.0/24
      66.93.40.0/24
      66.93.42.0/24
      66.93.44.0/24
      66.93.53.0/24
      66.93.57.0/24
      66.93.59.0/24
      66.93.74.0/24
      66.93.81.0/24
      66.93.128.0/24
      66.93.130.0/24
      66.93.132.0/24
      66.93.151.0/24
      66.93.154.0/24
      66.93.169.0/24
      66.93.173.0/24
      66.93.176.0/24
      66.93.179.0/24
      66.93.248.0/24
      66.253.10.0/23
      66.253.13.0/24
      66.253.14.0/24
      66.253.38.0/24
      66.253.45.0/24
      66.253.47.0/24
      68.166.215.0/24
      68.166.219.0/24
      68.166.228.0/24
      68.166.232.0/24
      68.166.240.0/24
      69.17.8.0/24
      69.33.216.0/24
      69.33.224.0/24
      69.165.69.0/24
      69.165.76.0/24
      74.2.221.0/24
      74.2.222.0/24
      82.21.112.0/24
      82.22.119.0/24
      82.22.166.0/24
      82.23.191.0/24
      82.24.70.0/24
      82.26.78.0/23
      82.29.64.0/24
      82.47.141.0/24
      82.47.143.0/24
      82.47.194.0/24
      82.109.151.0/24
      82.153.218.0/24
      83.147.41.0/24
      83.147.43.0/24
      83.147.44.0/22
      84.75.1.0/24
      84.75.179.0/24
      84.75.222.0/24
      87.83.47.0/24
      87.84.64.0/24
      89.116.10.0/24
      89.213.50.0/24
      89.213.224.0/24
      91.124.24.0/24
      91.124.94.0/23
      92.112.230.0/24
      95.134.63.0/24
      95.134.119.0/24
      95.134.240.0/20
      95.135.182.0/24
      95.135.192.0/24
      95.135.233.0/24
      95.155.172.0/23
      95.155.174.0/24
      98.96.221.0/24
      98.96.225.0/24
      98.96.232.0/23
      98.96.240.0/24
      98.96.248.0/23
      98.96.250.0/24
      98.98.23.0/24
      98.98.69.0/24
      98.98.74.0/24
      98.98.134.0/24
      101.47.94.0/24
      103.49.60.0/24
      103.49.62.0/23
      103.62.52.0/24
      103.62.54.0/24
      103.103.246.0/23
      103.215.127.0/24
      103.225.197.0/24
      103.225.198.0/24
      103.235.19.0/24
      103.237.101.0/24
      103.237.102.0/23
      103.239.103.0/24
      104.140.120.0/24
      104.166.83.0/24
      104.218.167.0/24
      104.254.194.0/24
      107.151.141.0/24
      107.151.153.0/24
      107.151.174.0/24
      107.151.192.0/23
      107.151.195.0/24
      107.151.196.0/22
      107.151.200.0/21
      107.151.208.0/22
      107.151.213.0/24
      107.151.214.0/23
      107.151.216.0/21
      107.151.234.0/24
      107.151.238.0/23
      107.151.240.0/22
      107.151.248.0/21
      109.65.235.0/24
      109.66.76.0/24
      109.66.78.0/24
      109.66.80.0/24
      109.66.94.0/24
      109.66.106.0/24
      109.66.131.0/24
      109.66.160.0/24
      109.66.164.0/24
      109.66.192.0/24
      118.26.60.0/22
      128.1.12.0/24
      128.1.24.0/24
      128.1.28.0/24
      128.1.120.0/23
      128.1.123.0/24
      128.1.147.0/24
      128.1.152.0/23
      128.1.162.0/24
      128.1.180.0/24
      128.1.195.0/24
      128.1.222.0/24
      128.1.237.0/24
      128.1.250.0/24
      128.14.24.0/24
      128.14.30.0/24
      128.14.37.0/24
      128.14.50.0/24
      128.14.61.0/24
      128.14.68.0/22
      128.14.79.0/24
      128.14.82.0/24
      128.14.127.0/24
      128.14.133.0/24
      128.14.134.0/23
      128.14.136.0/23
      128.14.142.0/24
      128.14.145.0/24
      128.14.146.0/23
      129.227.139.0/24
      134.202.225.0/24
      143.14.81.0/24
      143.14.140.0/24
      143.20.65.0/24
      143.20.72.0/24
      143.20.74.0/24
      143.20.102.0/24
      143.20.120.0/24
      143.20.200.0/24
      150.107.0.0/24
      150.107.3.0/24
      150.129.40.0/24
      150.129.42.0/24
      151.240.0.0/24
      151.240.5.0/24
      151.240.6.0/24
      151.240.133.0/24
      151.241.1.0/24
      151.241.148.0/24
      151.241.150.0/24
      151.241.157.0/24
      151.241.220.0/24
      151.242.1.0/24
      151.242.12.0/24
      151.242.14.0/24
      151.242.59.0/24
      151.242.77.0/24
      151.242.119.0/24
      151.242.157.0/24
      151.243.21.0/24
      151.243.47.0/24
      151.243.49.0/24
      151.243.51.0/24
      151.243.57.0/24
      151.243.60.0/23
      151.243.88.0/24
      151.243.114.0/24
      151.243.120.0/24
      151.244.105.0/24
      151.244.142.0/24
      151.244.178.0/24
      151.244.236.0/24
      151.245.29.0/24
      151.245.38.0/24
      151.245.48.0/24
      151.245.52.0/24
      151.245.60.0/23
      151.245.63.0/24
      151.245.65.0/24
      151.245.102.0/24
      151.245.109.0/24
      151.245.120.0/24
      151.245.138.0/24
      151.245.141.0/24
      151.245.148.0/24
      151.245.162.0/24
      151.245.170.0/24
      151.245.226.0/24
      151.245.241.0/24
      151.246.179.0/24
      151.246.180.0/24
      151.246.222.0/24
      151.246.248.0/24
      151.247.45.0/24
      151.247.108.0/24
      151.247.137.0/24
      154.16.41.0/24
      154.16.91.0/24
      154.16.96.0/24
      154.16.122.0/24
      154.16.159.0/24
      154.16.177.0/24
      154.16.184.0/24
      154.16.218.0/24
      154.16.220.0/24
      154.16.237.0/24
      154.84.167.0/24
      154.86.116.0/23
      154.208.113.0/24
      155.117.139.0/24
      155.229.87.0/24
      155.229.197.0/24
      156.59.73.0/24
      156.59.123.0/24
      156.59.146.0/24
      156.59.184.0/24
      156.59.223.0/24
      157.119.20.0/24
      162.128.64.0/23
      162.128.66.0/24
      162.128.68.0/22
      162.128.72.0/22
      162.128.76.0/23
      162.128.80.0/21
      162.128.89.0/24
      162.128.90.0/23
      162.128.92.0/22
      162.128.101.0/24
      162.128.113.0/24
      162.128.132.0/24
      162.128.146.0/24
      163.53.244.0/24
      163.53.247.0/24
      165.49.235.0/24
      167.148.40.0/24
      167.148.120.0/23
      167.148.169.0/24
      168.222.74.0/24
      168.222.117.0/24
      169.197.101.0/24
      172.81.127.0/24
      174.140.239.0/24
      174.140.251.0/24
      178.83.15.0/24
      178.83.106.0/24
      178.83.208.0/24
      178.92.228.0/24
      178.93.17.0/24
      178.93.58.0/24
      178.93.193.0/24
      178.93.236.0/24
      178.93.243.0/24
      178.94.195.0/24
      178.94.197.0/24
      178.94.201.0/24
      178.94.204.0/24
      178.94.207.0/24
      178.94.216.0/24
      178.94.228.0/24
      178.94.253.0/24
      178.95.8.0/24
      178.95.84.0/24
      178.95.87.0/24
      178.95.92.0/24
      178.95.97.0/24
      178.95.98.0/23
      178.95.113.0/24
      178.95.193.0/24
      178.95.219.0/24
      178.95.222.0/24
      178.95.226.0/24
      178.95.252.0/24
      178.95.254.0/24
      178.132.196.0/24
      179.61.152.0/24
      179.61.207.0/24
      181.214.220.0/24
      181.214.229.0/24
      181.215.198.0/24
      181.215.238.0/24
      188.220.95.0/24
      188.220.198.0/24
      188.220.249.0/24
      188.221.212.0/24
      188.221.216.0/24
      191.101.175.0/24
      191.101.189.0/24
      191.101.200.0/24
      192.6.35.0/24
      192.6.94.0/24
      193.8.113.0/24
      193.31.113.0/24
      194.231.139.0/24
      194.231.158.0/24
      194.231.208.0/24
      194.231.210.0/24
      198.44.164.0/22
      198.44.168.0/23
      198.44.171.0/24
      198.44.175.0/24
      198.44.188.0/22
      199.190.45.0/24
      204.27.77.0/24
      207.210.111.0/24
      209.101.52.0/24
      212.17.234.0/24
      212.134.16.0/24
      212.134.18.0/23
      212.134.22.0/24
      212.134.24.0/24
      212.134.58.0/23
      212.134.80.0/24
      212.134.83.0/24
      212.134.99.0/24
      212.134.104.0/24
      212.134.110.0/24
      212.134.120.0/24
      212.134.134.0/24
      212.134.136.0/24
      212.134.143.0/24
      212.134.160.0/24
      212.134.171.0/24
      212.134.175.0/24
      212.134.176.0/24
      212.134.181.0/24
      212.134.184.0/23
      212.134.202.0/24
      212.134.219.0/24
      212.134.233.0/24
      212.134.234.0/24
      212.134.237.0/24
      212.134.238.0/24
      212.134.244.0/24
      212.134.246.0/24
      212.134.251.0/24
      212.135.66.0/24
      212.135.98.0/24
      212.135.140.0/23
      212.135.150.0/24
      212.135.158.0/24
      212.135.168.0/24
      212.135.171.0/24
      212.135.204.0/24
      212.135.250.0/24
      216.27.173.0/24
      216.27.174.0/24
      216.115.187.0/24
      216.116.190.0/23
      216.133.144.0/24
      216.133.154.0/23
      216.133.157.0/24
      216.133.158.0/23
      216.231.51.0/24
      216.231.62.0/24
      217.147.168.0/24
      217.216.221.0/24
      217.216.222.0/23
      2400:3280::/32
      2401:a180::/32
      2401:bb80::/32
      2403:58c0::/32
      2602:f4e0::/40
      2602:f524::/40
      2602:f52b::/40
      2602:f54a::/40
      2602:ffe4:c68::/46
      2602:ffe4:c74::/46
      2602:ffe4:c80::/45
      2602:ffe4:c88::/46
      2602:ffe4:c90::/47
      2602:ffe4:c93::/48
      2602:ffe4:c94::/47
      2602:ffe4:c96::/48
      2602:ffe4:c98::/46
      2604:980:e016::/47
      2604:980:e01a::/47
      2604:980:e01c::/46
      2604:980:e020::/45
      2604:980:e028::/47
      2604:980:e02c::/46
      2604:980:e030::/47
      2604:980:e036::/47
      2604:980:e038::/46
      2604:980:e03c::/47
      2604:980:e044::/46
      2604:980:efc0::/42
      2a01:f2c0::/29
      2a09:3940::/29
      2a0b:21c1:600c::/46
      2a0b:21c1:6013::/48
      2a0b:21c1:6014::/46
      2a0b:21c1:6018::/47
      2a0b:21c1:601a::/48
      2a0b:21c1:601e::/47
      2a0b:21c1:6020::/47
      2a0b:21c1:6024::/46
      2a0b:21c1:6032::/47
      2a0c:a580::/29
      2a0e:1c00::/29
      2a10:4a00::/29
      2a10:7b00::/29
      2a11:c40::/29
      2a11:4500::/29
      2a11:7940::/29
      2a12:6180::/29
      2a12:da80::/29
      2a12:f540::/29
      2a13:f40::/29
      2a13:dcc0::/29
    LIST
  }
}

# CronJob to import public blocklists into CrowdSec
# https://github.com/wolffcatskyy/crowdsec-blocklist-import
# Uses kubectl exec to run in an existing CrowdSec agent pod that's already registered
resource "kubernetes_cron_job_v1" "crowdsec_blocklist_import" {
  metadata {
    name      = "crowdsec-blocklist-import"
    namespace = kubernetes_namespace.crowdsec.metadata[0].name
    labels = {
      app  = "crowdsec-blocklist-import"
      tier = var.tier
    }
  }

  spec {
    # Run daily at 4 AM
    schedule                      = "0 4 * * *"
    timezone                      = "Europe/London"
    concurrency_policy            = "Forbid"
    successful_jobs_history_limit = 3
    failed_jobs_history_limit     = 3

    job_template {
      metadata {
        labels = {
          app = "crowdsec-blocklist-import"
        }
      }

      spec {
        backoff_limit = 3
        template {
          metadata {
            labels = {
              app = "crowdsec-blocklist-import"
            }
          }

          spec {
            service_account_name = kubernetes_service_account.blocklist_import.metadata[0].name

            volume {
              name = "static-blocklist"
              config_map {
                name = kubernetes_config_map.crowdsec_static_blocklist.metadata[0].name
              }
            }
            restart_policy = "OnFailure"

            container {
              name  = "blocklist-import"
              image = "bitnami/kubectl:latest"

              command = ["/bin/bash", "-c"]

              volume_mount {
                name       = "static-blocklist"
                mount_path = "/static"
                read_only  = true
              }
              args = [
                <<-EOF
                set -e

                echo "Finding CrowdSec agent pod..."
                AGENT_POD=$(kubectl get pods -n crowdsec -l k8s-app=crowdsec,type=agent -o jsonpath='{.items[0].metadata.name}')

                if [ -z "$AGENT_POD" ]; then
                  echo "ERROR: Could not find CrowdSec agent pod"
                  exit 1
                fi

                echo "Using agent pod: $AGENT_POD"

                # ---- our own policy FIRST -------------------------------------
                # Re-applied every run so the 168h decisions never lapse. It runs
                # before the third-party feeds and outside the set +e below,
                # deliberately: on 2026-09-02 the public-list download died with
                # `curl: (35) TLS connect error: ... method not supported` (the
                # image is bitnami/kubectl:latest and moved under us), and with
                # `set -e` that aborted the whole job. Our reviewed blocklist must
                # not be hostage to somebody else's CDN or to an unpinned image.
                # NOT `kubectl cp`. A ConfigMap mount is a directory of
                # symlinks — /static/meta-asn.txt points at ..data/meta-asn.txt —
                # and `kubectl cp` tars the source without following symlinks, so
                # it delivered a dangling link and every run since 2026-09-02
                # died on `unable to open /tmp/meta-asn.txt: no such file or
                # directory`. Shell redirection follows the symlink, so pipe the
                # bytes through exec's stdin instead.
                # Each entry is "<file>|<reason>". Both lists get the identical
                # stage-verify-import treatment, so a second list can never be
                # added with weaker guards than the first.
                for ENTRY in \
                  "meta-asn.txt|static-blocklist/meta-asn (git-history crawler swarm 2026-09-02)" \
                  "proxy-asn.txt|static-blocklist/proxy-asn (rotating-proxy crawl 2026-09-09, AS214483+AS62610)"
                do
                  LIST_FILE="$${ENTRY%%|*}"
                  LIST_REASON="$${ENTRY#*|}"

                  echo "Importing static blocklist ($LIST_FILE)..."
                  EXPECTED=$(grep -cvE '^[[:space:]]*(#|$)' "/static/$LIST_FILE")
                  kubectl exec -i -n crowdsec "$AGENT_POD" -- \
                    sh -c "cat > /tmp/$LIST_FILE" < "/static/$LIST_FILE"

                  # Prove the file arrived before importing. The failure this
                  # guards against was silent for a day: the import errored, the
                  # job went red for what looked like the third-party feeds, and
                  # the 168h decisions quietly kept ticking down.
                  LANDED=$(kubectl exec -n crowdsec "$AGENT_POD" -- \
                    sh -c "grep -cvE '^[[:space:]]*(#|\$)' /tmp/$LIST_FILE 2>/dev/null || echo 0")
                  if [ "$LANDED" != "$EXPECTED" ]; then
                    echo "ERROR: static blocklist did not reach the agent:" \
                         "expected $EXPECTED CIDRs, found $LANDED in /tmp/$LIST_FILE"
                    kubectl exec -n crowdsec "$AGENT_POD" -- rm -f "/tmp/$LIST_FILE" || true
                    exit 1
                  fi
                  echo "Staged $LANDED CIDRs from $LIST_FILE on $AGENT_POD."

                  kubectl exec -n crowdsec "$AGENT_POD" -- cscli decisions import \
                    -i "/tmp/$LIST_FILE" --format values --scope range \
                    --duration 168h --reason "$LIST_REASON"
                  kubectl exec -n crowdsec "$AGENT_POD" -- rm -f "/tmp/$LIST_FILE"
                done

                # ---- third-party feeds, non-fatal -----------------------------
                # A failure here still exits non-zero at the end so the job goes
                # red and is visible, but only AFTER our own policy has landed.
                set +e
                (
                set -e

                # Download the import script
                echo "Downloading blocklist import script..."
                curl -fsSL -o /tmp/import.sh \
                  https://raw.githubusercontent.com/wolffcatskyy/crowdsec-blocklist-import/main/import.sh
                chmod +x /tmp/import.sh

                # Copy script to agent pod and execute
                echo "Copying script to agent pod and executing..."
                kubectl cp /tmp/import.sh crowdsec/$AGENT_POD:/tmp/import.sh

                kubectl exec -n crowdsec "$AGENT_POD" -- /bin/bash -c '
                  set -e

                  # Run with native mode since we are inside the CrowdSec container
                  export MODE=native
                  export DECISION_DURATION=168h
                  export FETCH_TIMEOUT=60
                  export LOG_LEVEL=INFO

                  /tmp/import.sh

                  # Cleanup
                  rm -f /tmp/import.sh
                '
                )
                EXT_RC=$?
                set -e

                if [ "$EXT_RC" -ne 0 ]; then
                  echo "WARNING: public blocklist import failed (exit $EXT_RC)."
                  echo "The static blocklist above WAS applied; only the third-party feeds were skipped."
                  exit "$EXT_RC"
                fi

                echo "Blocklist import completed successfully!"
                EOF
              ]
            }
          }
        }
      }
    }
  }
  lifecycle {
    # KYVERNO_LIFECYCLE_V1: Kyverno admission webhook mutates dns_config with ndots=2
    ignore_changes = [spec[0].job_template[0].spec[0].template[0].spec[0].dns_config]
  }
}

# Service account for the blocklist import job (needs kubectl exec permissions)
resource "kubernetes_service_account" "blocklist_import" {
  metadata {
    name      = "crowdsec-blocklist-import"
    namespace = kubernetes_namespace.crowdsec.metadata[0].name
  }
}

resource "kubernetes_role" "blocklist_import" {
  metadata {
    name      = "crowdsec-blocklist-import"
    namespace = kubernetes_namespace.crowdsec.metadata[0].name
  }

  rule {
    api_groups = [""]
    resources  = ["pods"]
    verbs      = ["get", "list"]
  }
  rule {
    api_groups = [""]
    resources  = ["pods/exec"]
    verbs      = ["create"]
  }
}

resource "kubernetes_role_binding" "blocklist_import" {
  metadata {
    name      = "crowdsec-blocklist-import"
    namespace = kubernetes_namespace.crowdsec.metadata[0].name
  }

  role_ref {
    api_group = "rbac.authorization.k8s.io"
    kind      = "Role"
    name      = kubernetes_role.blocklist_import.metadata[0].name
  }

  subject {
    kind      = "ServiceAccount"
    name      = kubernetes_service_account.blocklist_import.metadata[0].name
    namespace = kubernetes_namespace.crowdsec.metadata[0].name
  }
}

# Custom ResourceQuota for CrowdSec — needs more than default 1-cluster quota
# because it runs DaemonSet agents (1 per worker node) + 3 LAPI replicas + web UI
resource "kubernetes_resource_quota" "crowdsec" {
  metadata {
    name      = "crowdsec-quota"
    namespace = kubernetes_namespace.crowdsec.metadata[0].name
  }
  spec {
    hard = {
      "requests.cpu"    = "4"
      "requests.memory" = "8Gi"
      "limits.memory"   = "16Gi"
      pods              = "30"
    }
  }
}
