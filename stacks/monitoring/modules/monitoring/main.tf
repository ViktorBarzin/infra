variable "tls_secret_name" {}
variable "alertmanager_account_password" {}
variable "idrac_host" {
  default = "192.168.1.4"
}
variable "idrac_username" {
  default = "root"
}
variable "idrac_password" {
  default   = "calvin"
  sensitive = true
}
variable "alertmanager_slack_api_url" {}
variable "tiny_tuya_service_secret" {
  type      = string
  sensitive = true
}
variable "haos_api_token" {
  type      = string
  sensitive = true
}
variable "pve_password" {
  type      = string
  sensitive = true
}
variable "grafana_admin_password" {
  type      = string
  sensitive = true
}
variable "tier" { type = string }
variable "mysql_host" { type = string }
variable "registry_user" {
  type      = string
  sensitive = true
}
variable "registry_password" {
  type      = string
  sensitive = true
}

resource "kubernetes_namespace" "monitoring" {
  metadata {
    name = "monitoring"
    labels = {
      "istio-injection" : "disabled"
      tier                               = var.tier
      "resource-governance/custom-quota" = "true"
    }
  }
  lifecycle {
    # KYVERNO_LIFECYCLE_V1: goldilocks-vpa-auto-mode ClusterPolicy stamps this label on every namespace
    ignore_changes = [metadata[0].labels["goldilocks.fairwinds.com/vpa-update-mode"]]
  }
}

module "tls_secret" {
  source          = "../../../../modules/kubernetes/setup_tls_secret"
  namespace       = kubernetes_namespace.monitoring.metadata[0].name
  tls_secret_name = var.tls_secret_name
}
# Terraform get angry with the 30k values file :/ use ansible until solved
# resource "helm_release" "ups_prometheus_snmp_exporter" {
#  namespace = kubernetes_namespace.monitoring.metadata[0].name
#   create_namespace = true
#   name             = "ups_prometheus_exporter"

#   repository = "https://prometheus-community.github.io/helm-charts"
#   chart      = "prometheus-snmp-exporter"

#   values = [file("${path.module}/ups_snmp_values.yaml")]
# }



resource "kubernetes_cron_job_v1" "monitor_prom" {
  metadata {
    name = "monitor-prometheus"
  }
  spec {
    concurrency_policy        = "Replace"
    failed_jobs_history_limit = 5
    schedule                  = "*/30 * * * *"
    job_template {
      metadata {

      }
      spec {
        template {
          metadata {

          }
          spec {
            container {
              name    = "monitor-prometheus"
              image   = "alpine"
              command = ["/bin/sh", "-c", "apk add --update curl && curl --connect-timeout 2 prometheus-server.monitoring.svc.cluster.local || curl https://webhook.viktorbarzin.me/fb/message-viktor -d 'Prometheus is down!'"]
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

# -----------------------------------------------------------------------------
# DNS Anomaly Monitor — query Technitium stats API, detect anomalies, push to Pushgateway
# Runs every 15 min. Checks for query spikes, high error rates, and suspicious patterns.
# -----------------------------------------------------------------------------
resource "kubernetes_cron_job_v1" "dns_anomaly_monitor" {
  metadata {
    name      = "dns-anomaly-monitor"
    namespace = kubernetes_namespace.monitoring.metadata[0].name
  }
  spec {
    concurrency_policy            = "Replace"
    failed_jobs_history_limit     = 3
    successful_jobs_history_limit = 3
    schedule                      = "*/15 * * * *"
    job_template {
      metadata {}
      spec {
        backoff_limit              = 2
        ttl_seconds_after_finished = 300
        template {
          metadata {}
          spec {
            container {
              name  = "dns-anomaly-monitor"
              image = "docker.io/library/alpine"
              command = ["/bin/sh", "-c", <<-EOT
                set -euo pipefail
                apk add --no-cache curl jq

                TECHNITIUM_URL="http://technitium-web.technitium.svc.cluster.local:5380"

                # Get main stats
                STATS=$(curl -sf "$TECHNITIUM_URL/api/stats/get?token=&type=LastHour" 2>&1) || {
                  echo "ERROR: Failed to query Technitium stats API"
                  exit 1
                }

                # Parse key metrics
                TOTAL_QUERIES=$(echo "$STATS" | jq -r '.response.stats.totalQueries // 0')
                SERVER_FAILURE=$(echo "$STATS" | jq -r '.response.stats.serverFailure // 0')
                NX_DOMAIN=$(echo "$STATS" | jq -r '.response.stats.nxDomain // 0')
                BLOCKED=$(echo "$STATS" | jq -r '.response.stats.blocked // 0')
                NO_ERROR=$(echo "$STATS" | jq -r '.response.stats.noError // 0')

                echo "DNS Stats (last hour): total=$TOTAL_QUERIES noError=$NO_ERROR nxDomain=$NX_DOMAIN serverFailure=$SERVER_FAILURE blocked=$BLOCKED"

                # Get top clients for anomaly context
                TOP_CLIENTS=$(curl -sf "$TECHNITIUM_URL/api/stats/getTopClients?token=&type=LastHour&limit=10" 2>&1) || true

                # Get top domains for DGA/tunneling detection
                TOP_DOMAINS=$(curl -sf "$TECHNITIUM_URL/api/stats/getTopDomains?token=&type=LastHour&limit=20" 2>&1) || true

                # Check for high-entropy domains (potential DGA)
                DGA_SUSPECT=0
                if [ -n "$TOP_DOMAINS" ]; then
                  # Simple heuristic: domains with many consonant clusters or very long labels
                  DGA_SUSPECT=$(echo "$TOP_DOMAINS" | jq -r '[.response.topDomains[]?.name // empty | select(length > 30 or test("[bcdfghjklmnpqrstvwxyz]{5,}"))] | length')
                fi

                # Push metrics to Pushgateway
                cat <<METRICS | curl -sf --data-binary @- "http://prometheus-prometheus-pushgateway.monitoring:9091/metrics/job/dns-anomaly-monitor"
                # HELP dns_anomaly_total_queries Total DNS queries in last hour
                # TYPE dns_anomaly_total_queries gauge
                dns_anomaly_total_queries $TOTAL_QUERIES
                # HELP dns_anomaly_server_failure DNS server failures in last hour
                # TYPE dns_anomaly_server_failure gauge
                dns_anomaly_server_failure $SERVER_FAILURE
                # HELP dns_anomaly_nx_domain NX domain responses in last hour
                # TYPE dns_anomaly_nx_domain gauge
                dns_anomaly_nx_domain $NX_DOMAIN
                # HELP dns_anomaly_blocked Blocked queries in last hour
                # TYPE dns_anomaly_blocked gauge
                dns_anomaly_blocked $BLOCKED
                # HELP dns_anomaly_dga_suspects Domains with DGA-like characteristics
                # TYPE dns_anomaly_dga_suspects gauge
                dns_anomaly_dga_suspects $DGA_SUSPECT
                # HELP dns_anomaly_check_timestamp Last successful check timestamp
                # TYPE dns_anomaly_check_timestamp gauge
                dns_anomaly_check_timestamp $(date +%s)
              METRICS

                # Calculate average for spike detection (store as a simple rolling metric)
                # The Prometheus alert rule compares current vs stored average
                AVG_FILE="/tmp/dns_avg"
                if [ -f "$AVG_FILE" ]; then
                  PREV_AVG=$(cat "$AVG_FILE")
                  NEW_AVG=$(( (PREV_AVG + TOTAL_QUERIES) / 2 ))
                else
                  NEW_AVG=$TOTAL_QUERIES
                fi

                cat <<METRICS | curl -sf --data-binary @- "http://prometheus-prometheus-pushgateway.monitoring:9091/metrics/job/dns-anomaly-monitor"
                # HELP dns_anomaly_avg_queries Rolling average DNS queries
                # TYPE dns_anomaly_avg_queries gauge
                dns_anomaly_avg_queries $NEW_AVG
              METRICS

                echo "DNS anomaly check complete (DGA suspects: $DGA_SUSPECT)"
              EOT
              ]
              resources {
                requests = {
                  memory = "32Mi"
                  cpu    = "10m"
                }
                limits = {
                  memory = "64Mi"
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
    }
  }
  lifecycle {
    # KYVERNO_LIFECYCLE_V1: Kyverno admission webhook mutates dns_config with ndots=2
    ignore_changes = [spec[0].job_template[0].spec[0].template[0].spec[0].dns_config]
  }
}

# -----------------------------------------------------------------------------
# Registry manifest-integrity probe — HEADs every tag in the private R/W
# registry's catalog, walks multi-platform image indexes, and reports blob
# availability. Catches the orphan-index failure mode seen 2026-04-13 and
# 2026-04-19 before downstream pipelines hit it.
# See: docs/post-mortems/2026-04-19-registry-orphan-index.md
# -----------------------------------------------------------------------------
resource "kubernetes_secret" "registry_probe_credentials" {
  metadata {
    name      = "registry-probe-credentials"
    namespace = kubernetes_namespace.monitoring.metadata[0].name
  }
  type = "Opaque"
  data = {
    REG_USER = var.registry_user
    REG_PASS = var.registry_password
  }
}

resource "kubernetes_cron_job_v1" "registry_integrity_probe" {
  metadata {
    name      = "registry-integrity-probe"
    namespace = kubernetes_namespace.monitoring.metadata[0].name
  }
  spec {
    concurrency_policy            = "Forbid"
    failed_jobs_history_limit     = 3
    successful_jobs_history_limit = 3
    schedule                      = "*/15 * * * *"
    job_template {
      metadata {}
      spec {
        backoff_limit              = 1
        ttl_seconds_after_finished = 600
        template {
          metadata {}
          spec {
            container {
              name  = "registry-integrity-probe"
              image = "docker.io/library/alpine:3.20"
              env {
                name = "REG_USER"
                value_from {
                  secret_key_ref {
                    name = kubernetes_secret.registry_probe_credentials.metadata[0].name
                    key  = "REG_USER"
                  }
                }
              }
              env {
                name = "REG_PASS"
                value_from {
                  secret_key_ref {
                    name = kubernetes_secret.registry_probe_credentials.metadata[0].name
                    key  = "REG_PASS"
                  }
                }
              }
              env {
                name  = "REGISTRY_HOST"
                value = "10.0.20.10:5050"
              }
              env {
                name  = "REGISTRY_INSTANCE"
                value = "registry.viktorbarzin.me:5050"
              }
              env {
                name  = "PUSHGATEWAY"
                value = "http://prometheus-prometheus-pushgateway.monitoring:9091/metrics/job/registry-integrity-probe"
              }
              env {
                name  = "TAGS_PER_REPO"
                value = "5"
              }
              command = ["/bin/sh", "-c", <<-EOT
                set -eu
                apk add --no-cache curl jq >/dev/null

                REG="$REGISTRY_HOST"
                INSTANCE="$REGISTRY_INSTANCE"
                AUTH="$REG_USER:$REG_PASS"
                ACCEPT='application/vnd.oci.image.index.v1+json,application/vnd.oci.image.manifest.v1+json,application/vnd.docker.distribution.manifest.list.v2+json,application/vnd.docker.distribution.manifest.v2+json'

                push() {
                  # Prometheus pushgateway — body ends with blank line. Ignore push errors.
                  curl -sf --max-time 10 --data-binary @- "$PUSHGATEWAY" >/dev/null 2>&1 || true
                }

                CATALOG=$(curl -sk -u "$AUTH" --max-time 30 "https://$REG/v2/_catalog?n=1000" || echo "")
                REPOS=$(echo "$CATALOG" | jq -r '.repositories[]?' 2>/dev/null || echo "")

                if [ -z "$REPOS" ]; then
                  echo "ERROR: empty catalog or auth failure — cannot probe"
                  NOW=$(date +%s)
                  push <<METRICS
                # TYPE registry_manifest_integrity_catalog_accessible gauge
                registry_manifest_integrity_catalog_accessible{instance="$INSTANCE"} 0
                # TYPE registry_manifest_integrity_last_run_timestamp gauge
                registry_manifest_integrity_last_run_timestamp{instance="$INSTANCE"} $NOW
                METRICS
                  exit 1
                fi

                FAIL=0
                REPOS_N=0
                TAGS_N=0
                INDEXES_N=0

                printf '%s\n' $REPOS > /tmp/repos.txt
                while IFS= read -r repo; do
                  [ -z "$repo" ] && continue
                  REPOS_N=$((REPOS_N + 1))

                  TAGS_JSON=$(curl -sk -u "$AUTH" --max-time 15 "https://$REG/v2/$repo/tags/list" || echo "")
                  echo "$TAGS_JSON" | jq -r '.tags[]?' 2>/dev/null | tail -n "$TAGS_PER_REPO" > /tmp/tags.txt || true

                  while IFS= read -r tag; do
                    [ -z "$tag" ] && continue
                    TAGS_N=$((TAGS_N + 1))

                    HTTP=$(curl -sk -u "$AUTH" -o /tmp/m.json -w '%%{http_code}' \
                      -H "Accept: $ACCEPT" --max-time 15 \
                      "https://$REG/v2/$repo/manifests/$tag")
                    if [ "$HTTP" != "200" ]; then
                      echo "FAIL: $repo:$tag manifest HTTP $HTTP"
                      FAIL=$((FAIL + 1))
                      continue
                    fi

                    MT=$(jq -r '.mediaType // empty' /tmp/m.json 2>/dev/null || echo "")
                    if echo "$MT" | grep -Eq 'manifest\.list|image\.index'; then
                      INDEXES_N=$((INDEXES_N + 1))
                      jq -r '.manifests[].digest' /tmp/m.json > /tmp/children.txt 2>/dev/null || true
                      while IFS= read -r d; do
                        [ -z "$d" ] && continue
                        CH=$(curl -sk -u "$AUTH" -o /dev/null -w '%%{http_code}' \
                          -H "Accept: $ACCEPT" --max-time 10 -I \
                          "https://$REG/v2/$repo/manifests/$d")
                        if [ "$CH" != "200" ]; then
                          echo "FAIL: $repo:$tag index child $d HTTP $CH"
                          FAIL=$((FAIL + 1))
                        fi
                      done < /tmp/children.txt
                    fi
                  done < /tmp/tags.txt
                done < /tmp/repos.txt

                NOW=$(date +%s)
                push <<METRICS
                # TYPE registry_manifest_integrity_failures gauge
                registry_manifest_integrity_failures{instance="$INSTANCE"} $FAIL
                # TYPE registry_manifest_integrity_catalog_accessible gauge
                registry_manifest_integrity_catalog_accessible{instance="$INSTANCE"} 1
                # TYPE registry_manifest_integrity_repos_checked gauge
                registry_manifest_integrity_repos_checked{instance="$INSTANCE"} $REPOS_N
                # TYPE registry_manifest_integrity_tags_checked gauge
                registry_manifest_integrity_tags_checked{instance="$INSTANCE"} $TAGS_N
                # TYPE registry_manifest_integrity_indexes_checked gauge
                registry_manifest_integrity_indexes_checked{instance="$INSTANCE"} $INDEXES_N
                # TYPE registry_manifest_integrity_last_run_timestamp gauge
                registry_manifest_integrity_last_run_timestamp{instance="$INSTANCE"} $NOW
                METRICS

                echo "Probe complete: $FAIL failures across $REPOS_N repos / $TAGS_N tags / $INDEXES_N indexes"
                if [ "$FAIL" -gt 0 ]; then exit 1; fi
              EOT
              ]
              resources {
                requests = {
                  cpu    = "10m"
                  memory = "48Mi"
                }
                limits = {
                  memory = "96Mi"
                }
              }
            }
            restart_policy = "OnFailure"
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

# Expose Pushgateway via NodePort so the PVE host can push LVM snapshot metrics
resource "kubernetes_service" "pushgateway_nodeport" {
  metadata {
    name      = "pushgateway-nodeport"
    namespace = kubernetes_namespace.monitoring.metadata[0].name
  }
  spec {
    type = "NodePort"
    selector = {
      "app.kubernetes.io/name"     = "prometheus-pushgateway"
      "app.kubernetes.io/instance" = "prometheus"
    }
    port {
      port        = 9091
      target_port = 9091
      node_port   = 30091
      protocol    = "TCP"
    }
  }
}

resource "kubernetes_manifest" "status_redirect_middleware" {
  manifest = {
    apiVersion = "traefik.io/v1alpha1"
    kind       = "Middleware"
    metadata = {
      name      = "status-redirect"
      namespace = kubernetes_namespace.monitoring.metadata[0].name
    }
    spec = {
      redirectRegex = {
        regex       = ".*"
        replacement = "https://hetrixtools.com/r/38981b548b5d38b052aca8d01285a3f3/"
        permanent   = true
      }
    }
  }
}

resource "kubernetes_manifest" "status_ingress_route" {
  manifest = {
    apiVersion = "traefik.io/v1alpha1"
    kind       = "IngressRoute"
    metadata = {
      name      = "hetrix-redirect-ingress"
      namespace = kubernetes_namespace.monitoring.metadata[0].name
    }
    spec = {
      entryPoints = ["websecure"]
      routes = [{
        match = "Host(`status.viktorbarzin.me`)"
        kind  = "Rule"
        middlewares = [{
          name      = "status-redirect"
          namespace = kubernetes_namespace.monitoring.metadata[0].name
        }]
        services = [{
          kind = "TraefikService"
          name = "noop@internal"
        }]
      }]
      tls = {
        secretName = var.tls_secret_name
      }
    }
  }
}

resource "kubernetes_manifest" "yotovski_redirect_middleware" {
  manifest = {
    apiVersion = "traefik.io/v1alpha1"
    kind       = "Middleware"
    metadata = {
      name      = "yotovski-redirect"
      namespace = kubernetes_namespace.monitoring.metadata[0].name
    }
    spec = {
      redirectRegex = {
        regex       = ".*"
        replacement = "https://hetrixtools.com/r/2ba9d7a5e017794db0fd91f0115a8b3b/"
        permanent   = true
      }
    }
  }
}

resource "kubernetes_manifest" "yotovski_ingress_route" {
  manifest = {
    apiVersion = "traefik.io/v1alpha1"
    kind       = "IngressRoute"
    metadata = {
      name      = "hetrix-yotovski-redirect-ingress"
      namespace = kubernetes_namespace.monitoring.metadata[0].name
    }
    spec = {
      entryPoints = ["websecure"]
      routes = [{
        match = "Host(`yotovski-status.viktorbarzin.me`)"
        kind  = "Rule"
        middlewares = [{
          name      = "yotovski-redirect"
          namespace = kubernetes_namespace.monitoring.metadata[0].name
        }]
        services = [{
          kind = "TraefikService"
          name = "noop@internal"
        }]
      }]
      tls = {
        secretName = var.tls_secret_name
      }
    }
  }
}

# Custom ResourceQuota for monitoring — larger than the default 1-cluster tier quota
# because monitoring runs 29+ pods (Prometheus, Grafana, Loki, Alloy, exporters, etc.)
resource "kubernetes_resource_quota" "monitoring" {
  metadata {
    name      = "monitoring-quota"
    namespace = kubernetes_namespace.monitoring.metadata[0].name
  }
  spec {
    hard = {
      "requests.cpu"    = "16"
      "requests.memory" = "16Gi"
      "limits.memory"   = "64Gi"
      pods              = "100"
    }
  }
}
