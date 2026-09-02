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
      # KNOWN INERT, pre-dates the 2026-09-01 JSON switch and unaffected by it:
      # this expression reads evt.Parsed.target_fqdn, which no traefik parser
      # path creates — the JSON node writes evt.Meta.target_fqdn, a different
      # map, and CLF writes neither. Verified with `cscli explain` on an Immich
      # 404 in both formats on 2026-09-01: this whitelist reported "unchanged"
      # both times, so it has never suppressed anything. Fixing it means
      # evt.Meta.target_fqdn (or evt.Parsed.traefik_router_name, as the
      # nextcloud whitelist below does), which would START suppressing
      # detections — a security-posture change, deliberately not bundled with a
      # log-format change.
      whitelist:
        reason: "Immich asset endpoints are auth-gated; mobile scrub legitimately bursts"
        expression:
          - >
            evt.Parsed.target_fqdn == "immich.viktorbarzin.me" &&
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
      2620:10d:c090::/44
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

                # Our own static blocklist, re-applied every run so the 168h
                # decisions never lapse. Kept separate from the public lists
                # above because it is a deliberate, reviewed policy decision
                # rather than a third-party feed — see the ConfigMap comment.
                echo "Importing static blocklist (Meta ASN)..."
                kubectl cp /static/meta-asn.txt crowdsec/$AGENT_POD:/tmp/meta-asn.txt
                kubectl exec -n crowdsec "$AGENT_POD" -- cscli decisions import \
                  -i /tmp/meta-asn.txt --format values --scope range \
                  --duration 168h \
                  --reason "static-blocklist/meta-asn (git-history crawler swarm 2026-09-02)"
                kubectl exec -n crowdsec "$AGENT_POD" -- rm -f /tmp/meta-asn.txt

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
