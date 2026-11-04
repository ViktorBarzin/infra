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
variable "dawarich_metrics_username" {
  type        = string
  sensitive   = true
  description = "Basic-auth user for Dawarich's Sidekiq /metrics exporter (Vault secret/dawarich)."
}
variable "dawarich_metrics_password" {
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
variable "kube_config_path" {
  type      = string
  sensitive = true
}
variable "tier" { type = string }
variable "mysql_host" { type = string }
# One declaration, two consumers. Both features that arrived on this stack in
# September 2026 need the CNPG primary, and declaring it twice is a Terraform
# error that stops the whole stack initialising, so neither may add its own.
variable "postgresql_host" {
  type        = string
  description = "CNPG primary. The stray-workload reconciler (stray_workload.tf) reads Tier-1 Terraform state from the terraform_state database here; the Goldmane edge-trail Grafana datasource (goldmane_edges_datasource.tf) reads the goldmane_edges database."
}
variable "dbaas_postgresql_root_password" {
  type        = string
  sensitive   = true
  description = "CNPG superuser, used only by the stray-workload-detect-db-init Job to create its read-only reader role."
}
variable "registry_user" {
  type      = string
  sensitive = true
}
variable "registry_password" {
  type      = string
  sensitive = true
}
variable "forgejo_pull_token" {
  type        = string
  sensitive   = true
  description = "PAT for the cluster-puller user, used by the Forgejo registry integrity probe."
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
              name = "monitor-prometheus"
              # job-runtime (images/job-runtime) has the tools baked in, so the pod does not install them on every run.
              image             = "ghcr.io/viktorbarzin/job-runtime:latest"
              image_pull_policy = "Always"
              command           = ["/bin/sh", "-c", "curl --connect-timeout 2 prometheus-server.monitoring.svc.cluster.local || curl https://webhook.viktorbarzin.me/fb/message-viktor -d 'Prometheus is down!'"]
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
# Phase 4 of forgejo-registry-consolidation 2026-05-07: registry-private
# decommissioned. The integrity probe below caught the orphan-index failure
# mode in `registry:2.8.3` (post-mortem 2026-04-19). With that engine
# retired, the probe is replaced by `forgejo_integrity_probe` below.
#
# Resource definitions stripped wholesale — terragrunt apply destroys the
# in-cluster CronJob + Secret on the next run.
# See: docs/post-mortems/2026-04-19-registry-orphan-index.md
# -----------------------------------------------------------------------------

# -----------------------------------------------------------------------------
# Forgejo registry integrity probe — same algorithm as registry-integrity-probe
# above, but targets the Forgejo OCI registry instead of registry-private. Runs
# in parallel with the existing probe during the dual-push bake; once Phase 4
# decommissions registry-private, the registry-integrity-probe CronJob is
# deleted and only this one remains.
#
# Auth: HTTP Basic with cluster-puller PAT (read:package scope is enough to
# walk catalog + manifests). Reaches Forgejo via the in-cluster service so we
# don't hairpin out through Traefik for every probe run.
# -----------------------------------------------------------------------------
resource "kubernetes_secret" "forgejo_probe_credentials" {
  metadata {
    name      = "forgejo-probe-credentials"
    namespace = kubernetes_namespace.monitoring.metadata[0].name
  }
  type = "Opaque"
  data = {
    REG_USER = "cluster-puller"
    REG_PASS = var.forgejo_pull_token
  }
}

resource "kubernetes_cron_job_v1" "forgejo_integrity_probe" {
  metadata {
    name      = "forgejo-integrity-probe"
    namespace = kubernetes_namespace.monitoring.metadata[0].name
  }
  spec {
    concurrency_policy            = "Forbid"
    failed_jobs_history_limit     = 3
    successful_jobs_history_limit = 3
    schedule                      = "*/30 * * * *"
    job_template {
      metadata {}
      spec {
        backoff_limit              = 1
        ttl_seconds_after_finished = 600
        template {
          metadata {}
          spec {
            container {
              name = "forgejo-integrity-probe"
              # job-runtime (images/job-runtime) has the tools baked in, so the pod does not install them on every run.
              image             = "ghcr.io/viktorbarzin/job-runtime:latest"
              image_pull_policy = "Always"
              env {
                name = "REG_USER"
                value_from {
                  secret_key_ref {
                    name = kubernetes_secret.forgejo_probe_credentials.metadata[0].name
                    key  = "REG_USER"
                  }
                }
              }
              env {
                name = "REG_PASS"
                value_from {
                  secret_key_ref {
                    name = kubernetes_secret.forgejo_probe_credentials.metadata[0].name
                    key  = "REG_PASS"
                  }
                }
              }
              env {
                name  = "REGISTRY_HOST"
                value = "forgejo.forgejo.svc.cluster.local"
              }
              env {
                name  = "REGISTRY_SCHEME"
                value = "http"
              }
              env {
                name  = "REGISTRY_INSTANCE"
                value = "forgejo.viktorbarzin.me"
              }
              env {
                name  = "PUSHGATEWAY"
                value = "http://prometheus-prometheus-pushgateway.monitoring:9091/metrics/job/forgejo-integrity-probe"
              }
              env {
                name  = "TAGS_PER_REPO"
                value = "5"
              }
              command = ["/bin/sh", "-c", <<-EOT
                set -eu

                REG="$REGISTRY_HOST"
                SCHEME="$${REGISTRY_SCHEME:-https}"
                INSTANCE="$REGISTRY_INSTANCE"
                AUTH="$REG_USER:$REG_PASS"
                ACCEPT='application/vnd.oci.image.index.v1+json,application/vnd.oci.image.manifest.v1+json,application/vnd.docker.distribution.manifest.list.v2+json,application/vnd.docker.distribution.manifest.v2+json'

                push() {
                  curl -sf --max-time 10 --data-binary @- "$PUSHGATEWAY" >/dev/null 2>&1 || true
                }

                CATALOG=$(curl -sk -u "$AUTH" --max-time 30 "$SCHEME://$REG/v2/_catalog?n=1000" || echo "")
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

                  TAGS_JSON=$(curl -sk -u "$AUTH" --max-time 15 "$SCHEME://$REG/v2/$repo/tags/list" || echo "")
                  echo "$TAGS_JSON" | jq -r '.tags[]?' 2>/dev/null | tail -n "$TAGS_PER_REPO" > /tmp/tags.txt || true

                  while IFS= read -r tag; do
                    [ -z "$tag" ] && continue
                    TAGS_N=$((TAGS_N + 1))

                    HTTP=$(curl -sk -u "$AUTH" -o /tmp/m.json -w '%%{http_code}' \
                      -H "Accept: $ACCEPT" --max-time 15 \
                      "$SCHEME://$REG/v2/$repo/manifests/$tag")
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
                          "$SCHEME://$REG/v2/$repo/manifests/$d")
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

# The hetrix-redirect Middleware + IngressRoute for status.viktorbarzin.me
# were retired 2026-07-08 (ADR-0020): the name is now a grey-cloud A record
# to mx2 (gatus status page), so no traffic for it reaches Traefik anymore.

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
# Headroom: cluster grew from 5 → 7 workers (k8s-node5/6 added 2026-05-26); per-pod
# DaemonSets (alloy 562Mi, node-exporter 100Mi, loki-canary 128Mi, sysctl-inotify 4Mi)
# now consume ~+2Gi vs. pre-expansion. 20Gi gives ~3-4Gi safe headroom.
resource "kubernetes_resource_quota" "monitoring" {
  metadata {
    name      = "monitoring-quota"
    namespace = kubernetes_namespace.monitoring.metadata[0].name
  }
  spec {
    hard = {
      "requests.cpu"    = "16"
      "requests.memory" = "20Gi"
      "limits.memory"   = "64Gi"
      pods              = "100"
    }
  }
}
