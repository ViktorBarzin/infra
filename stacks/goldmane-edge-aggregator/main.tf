# =============================================================================
# goldmane-edge-aggregator — durable who-talks-to-whom audit trail (ADR-0014 / #58)
# =============================================================================
# A small Go service that streams Calico Goldmane's gRPC Flows API (mTLS) and
# upserts the unique service-to-service edge set into Postgres, plus a daily
# Slack digest CronJob of first-seen edges. Code lives in the standalone
# `goldmane-edge-aggregator` repo; the authoritative deploy spec is its
# DEPLOY.md. This stack is the infra side of that spec.
#
# Goldmane runs as `Service goldmane:7443` (gRPC/mTLS) in calico-system, enabled
# via the operator CR in stacks/calico/main.tf. The durable Loki path is NOT
# the operator CRs — this service IS the durable trail.
#
# Structure mirrors stacks/claude-memory (the canonical Tier-1 pattern): a
# per-service namespace, a CNPG Postgres DB + role + Vault 7-day rotation +
# ExternalSecret -> DATABASE_URL, the Reloader annotation, and the
# Terragrunt-generated backend.tf/providers.tf/tiers.tf layout. The novel bit is
# minting an mTLS client cert from the Tigera CA (hashicorp/tls; see versions.tf).
#
# IMAGE: ghcr.io/viktorbarzin/goldmane-edge-aggregator is PRIVATE. Onboarding
# MUST add the "goldmane-edge-aggregator" namespace to the ghcr-credentials
# Kyverno allowlist (stacks/kyverno/modules/kyverno/ghcr-credentials.tf,
# local.ghcr_private_namespaces) so the Kyverno-synced `ghcr-credentials` secret
# is cloned into this namespace — otherwise the pulls 401. The imagePullSecrets
# reference below assumes that entry exists.
# =============================================================================

variable "postgresql_host" { type = string }

# Plan-time root creds for the idempotent DB-init Job (mirrors claude-memory).
data "vault_kv_secret_v2" "secrets" {
  mount = "secret"
  name  = "goldmane-edge-aggregator"
}

# -----------------------------------------------------------------------------
# 1. Namespace
# -----------------------------------------------------------------------------
resource "kubernetes_namespace" "goldmane_edge_aggregator" {
  metadata {
    name = "goldmane-edge-aggregator"
    labels = {
      name = "goldmane-edge-aggregator"
      # Tier 4-aux: a small off-path consumer service, like claude-memory.
      tier               = local.tiers.aux
      "keel.sh/enrolled" = "true"
    }
  }
  lifecycle {
    # KYVERNO_LIFECYCLE_V1: goldilocks-vpa-auto-mode ClusterPolicy stamps this label on every namespace
    ignore_changes = [metadata[0].labels["goldilocks.fairwinds.com/vpa-update-mode"]]
  }
}

# -----------------------------------------------------------------------------
# 2. Goldmane mTLS client certificate (minted from the Tigera CA)
# -----------------------------------------------------------------------------
# The aggregator dials goldmane:7443 over mutual TLS. We mint a client cert
# signed by the Tigera CA (the same CA that issues Goldmane's serving cert), so
# Goldmane trusts the client and the client trusts Goldmane's server cert via
# the published CA bundle.
#
# The Tigera CA private key lives in the `tigera-ca-private` Secret in
# tigera-operator (Opaque; verified keys: tls.crt + tls.key). The stack's apply
# identity needs RBAC get on that secret — see the Role/RoleBinding below.
data "kubernetes_secret" "tigera_ca" {
  metadata {
    name      = "tigera-ca-private"
    namespace = "tigera-operator"
  }
}

# The CA bundle that verifies Goldmane's serving cert. It lives ONLY in
# calico-system (verified: ConfigMap `tigera-ca-bundle`, 2 keys present —
# `ca-bundle.crt` AND `tigera-ca-bundle.crt`, both the trusted bundle). We read
# it and recreate it as a ConfigMap in this namespace so the pod can mount it
# (a ConfigMap cannot be cross-namespace-mounted).
data "kubernetes_config_map" "tigera_ca_bundle" {
  metadata {
    name      = "tigera-ca-bundle"
    namespace = "calico-system"
  }
}

resource "kubernetes_config_map" "tigera_ca_bundle" {
  metadata {
    name      = "tigera-ca-bundle"
    namespace = kubernetes_namespace.goldmane_edge_aggregator.metadata[0].name
  }
  # Copy the upstream bundle verbatim. We mount the `tigera-ca-bundle.crt` key
  # at /etc/tigera-ca/tigera-ca-bundle.crt so the service's default
  # CA_CERT_PATH (/etc/tigera-ca/tigera-ca-bundle.crt) resolves with no override.
  data = data.kubernetes_config_map.tigera_ca_bundle.data
}

# Client private key.
resource "tls_private_key" "goldmane_client" {
  algorithm = "RSA"
  rsa_bits  = 2048
}

# CSR for the client cert. CN identifies the client; the service-DNS SAN mirrors
# how Felix/whisker-backend present a client identity to Goldmane.
resource "tls_cert_request" "goldmane_client" {
  private_key_pem = tls_private_key.goldmane_client.private_key_pem
  subject {
    common_name  = "goldmane-edge-aggregator"
    organization = "goldmane-edge-aggregator"
  }
  dns_names = [
    "goldmane-edge-aggregator",
    "goldmane-edge-aggregator.goldmane-edge-aggregator.svc.cluster.local",
  ]
}

# Sign the CSR with the Tigera CA. 10-year validity (87600h): re-apply rotates
# it well before expiry; a long horizon avoids surprise mTLS outages from an
# unattended stack. The Tigera CA itself outlives this (operator-managed).
resource "tls_locally_signed_cert" "goldmane_client" {
  cert_request_pem   = tls_cert_request.goldmane_client.cert_request_pem
  ca_private_key_pem = data.kubernetes_secret.tigera_ca.data["tls.key"]
  ca_cert_pem        = data.kubernetes_secret.tigera_ca.data["tls.crt"]

  validity_period_hours = 87600 # 10y
  early_renewal_hours   = 720   # re-sign on apply when <30d remain

  allowed_uses = [
    "client_auth",
    "digital_signature",
    "key_encipherment",
  ]
}

# The minted client cert + key, mounted at TLS_CERT_PATH / TLS_KEY_PATH defaults
# (/etc/goldmane-client-tls/tls.crt and .../tls.key).
resource "kubernetes_secret" "goldmane_client_tls" {
  metadata {
    name      = "goldmane-client-tls"
    namespace = kubernetes_namespace.goldmane_edge_aggregator.metadata[0].name
  }
  type = "Opaque"
  data = {
    "tls.crt" = tls_locally_signed_cert.goldmane_client.cert_pem
    "tls.key" = tls_private_key.goldmane_client.private_key_pem
  }
}

# Narrow RBAC so this stack's apply identity (and ESO/Reloader are unaffected)
# can `get` the Tigera CA private key in tigera-operator. The data source above
# reads it at apply time; this Role/RoleBinding documents + grants that access
# rather than relying on cluster-admin. The subject is the same SA the other
# Tier-1 stacks apply as (claude-agent/terraform-state for headless, the human
# OIDC identity interactively) — both are cluster-admin today, so this is
# belt-and-braces / least-privilege intent for when apply identities tighten.
resource "kubernetes_role" "read_tigera_ca" {
  metadata {
    name      = "goldmane-edge-aggregator-read-tigera-ca"
    namespace = "tigera-operator"
  }
  rule {
    api_groups     = [""]
    resources      = ["secrets"]
    resource_names = ["tigera-ca-private"]
    verbs          = ["get"]
  }
}

resource "kubernetes_role_binding" "read_tigera_ca" {
  metadata {
    name      = "goldmane-edge-aggregator-read-tigera-ca"
    namespace = "tigera-operator"
  }
  role_ref {
    api_group = "rbac.authorization.k8s.io"
    kind      = "Role"
    name      = kubernetes_role.read_tigera_ca.metadata[0].name
  }
  # The headless apply identity (claude-agent-service runs Tier-1 applies as the
  # `terraform-state` Vault K8s role in the claude-agent namespace).
  subject {
    kind      = "ServiceAccount"
    name      = "default"
    namespace = "claude-agent"
  }
}

# -----------------------------------------------------------------------------
# 3. Postgres: DB + role `goldmane_edges`, Vault 7-day rotation, DATABASE_URL
# -----------------------------------------------------------------------------
# Idempotent create of the role + DB using the CNPG root creds from Vault
# (dbaas_root_password), exactly mirroring claude-memory's db_init Job. The
# service creates the `edge` table itself at startup (migrations/0001_edge.sql),
# so no migration Job is needed.
resource "kubernetes_job" "db_init" {
  metadata {
    name      = "goldmane-edges-db-init"
    namespace = kubernetes_namespace.goldmane_edge_aggregator.metadata[0].name
  }
  spec {
    template {
      metadata {}
      spec {
        container {
          name  = "db-init"
          image = "postgres:16-alpine"
          command = [
            "sh", "-c",
            <<-EOT
              set -e
              # -d postgres: psql defaults the database name to the username;
              # the root user has no root-named database, so be explicit.
              PGPASSWORD='${data.vault_kv_secret_v2.secrets.data["dbaas_root_password"]}' psql -h ${var.postgresql_host} -U root -d postgres -tc "SELECT 1 FROM pg_roles WHERE rolname='goldmane_edges'" | grep -q 1 || \
                PGPASSWORD='${data.vault_kv_secret_v2.secrets.data["dbaas_root_password"]}' psql -h ${var.postgresql_host} -U root -d postgres -c "CREATE ROLE goldmane_edges WITH LOGIN PASSWORD '${data.vault_kv_secret_v2.secrets.data["db_password"]}'"
              PGPASSWORD='${data.vault_kv_secret_v2.secrets.data["dbaas_root_password"]}' psql -h ${var.postgresql_host} -U root -d postgres -tc "SELECT 1 FROM pg_database WHERE datname='goldmane_edges'" | grep -q 1 || \
                PGPASSWORD='${data.vault_kv_secret_v2.secrets.data["dbaas_root_password"]}' psql -h ${var.postgresql_host} -U root -d postgres -c "CREATE DATABASE goldmane_edges OWNER goldmane_edges"
              PGPASSWORD='${data.vault_kv_secret_v2.secrets.data["dbaas_root_password"]}' psql -h ${var.postgresql_host} -U root -d postgres -c "GRANT ALL PRIVILEGES ON DATABASE goldmane_edges TO goldmane_edges"
              echo "Database init complete"
            EOT
          ]
        }
        restart_policy = "Never"
      }
    }
    backoff_limit = 3
  }
  wait_for_completion = true
  timeouts {
    create = "2m"
  }
}

# ExternalSecret projecting the Vault-rotated (7-day) credential into a K8s
# Secret as DATABASE_URL. The Vault DB static role `pg-goldmane-edges` and its
# place in the CNPG connection allowlist are added in stacks/vault/main.tf
# (see this stack's terragrunt.hcl note). remoteRef key: static-creds/pg-goldmane-edges.
resource "kubernetes_manifest" "db_external_secret" {
  manifest = {
    apiVersion = "external-secrets.io/v1"
    kind       = "ExternalSecret"
    metadata = {
      name      = "goldmane-edges-db-creds"
      namespace = kubernetes_namespace.goldmane_edge_aggregator.metadata[0].name
    }
    spec = {
      refreshInterval = "15m"
      secretStoreRef = {
        name = "vault-database"
        kind = "ClusterSecretStore"
      }
      target = {
        name = "goldmane-edges-db-creds"
        template = {
          data = {
            DATABASE_URL = "postgresql://goldmane_edges:{{ .password }}@${var.postgresql_host}:5432/goldmane_edges"
          }
        }
      }
      data = [{
        secretKey = "password"
        remoteRef = {
          key      = "static-creds/pg-goldmane-edges"
          property = "password"
        }
      }]
    }
  }
  depends_on = [kubernetes_namespace.goldmane_edge_aggregator]
}

# -----------------------------------------------------------------------------
# 4. Slack webhook (reuse the alert-digest incoming webhook)
# -----------------------------------------------------------------------------
# The monitoring alert-digest CronJob posts with the Slack incoming webhook at
# Vault secret/monitoring -> key `alertmanager_slack_api_url`
# (stacks/monitoring/modules/monitoring/alert_digest.tf). Project that same URL
# into this namespace as SLACK_WEBHOOK_URL via an ExternalSecret (no new
# webhook). The digest CronJob defaults to #security.
resource "kubernetes_manifest" "slack_external_secret" {
  manifest = {
    apiVersion = "external-secrets.io/v1"
    kind       = "ExternalSecret"
    metadata = {
      name      = "goldmane-edges-slack"
      namespace = kubernetes_namespace.goldmane_edge_aggregator.metadata[0].name
    }
    spec = {
      refreshInterval = "1h"
      secretStoreRef = {
        name = "vault-kv"
        kind = "ClusterSecretStore"
      }
      target = {
        name = "goldmane-edges-slack"
      }
      data = [{
        secretKey = "SLACK_WEBHOOK_URL"
        remoteRef = {
          key      = "monitoring"
          property = "alertmanager_slack_api_url"
        }
      }]
    }
  }
  depends_on = [kubernetes_namespace.goldmane_edge_aggregator]
}

# -----------------------------------------------------------------------------
# 5. aggregate — Deployment (long-running gRPC stream -> Postgres upserts)
# -----------------------------------------------------------------------------
resource "kubernetes_deployment" "aggregate" {
  depends_on = [
    kubernetes_job.db_init,
    kubernetes_manifest.db_external_secret,
  ]
  metadata {
    name      = "goldmane-edge-aggregator"
    namespace = kubernetes_namespace.goldmane_edge_aggregator.metadata[0].name
    labels = {
      app  = "goldmane-edge-aggregator"
      tier = local.tiers.aux
    }
    annotations = {
      # Credential is env-injected and read only at startup; the 7-day rotation
      # must bounce the pod or it keeps the stale password and silently fails
      # DB auth (infra CLAUDE.md Reloader rule).
      "secret.reloader.stakater.com/reload" = "goldmane-edges-db-creds"
    }
  }
  spec {
    # 1 replica: the edge set is a global upsert keyed on (src_ns, dst_ns,
    # action); a second replica only doubles writes for no benefit (Goldmane
    # streams per-flow). Stateless (no PVC) so RollingUpdate is fine.
    replicas = 1
    selector {
      match_labels = {
        app = "goldmane-edge-aggregator"
      }
    }
    template {
      metadata {
        labels = {
          app = "goldmane-edge-aggregator"
        }
      }
      spec {
        # PRIVATE ghcr image — cloned into this namespace by the Kyverno
        # sync-ghcr-credentials allowlist policy (add this ns to that list).
        image_pull_secrets {
          name = "ghcr-credentials"
        }
        container {
          name = "aggregate"
          # CI (GHA -> ghcr) overwrites this to :<sha8> via `kubectl set image`;
          # the image tag is in ignore_changes below so the SHA sticks across
          # `terragrunt apply` (fleet image-pin convention). Placeholder :latest
          # until the deploy pipeline runs.
          image = "ghcr.io/viktorbarzin/goldmane-edge-aggregator:latest"
          args  = ["aggregate"]

          # Goldmane mTLS. GOLDMANE_HOST default host sans port =>
          # ServerName "goldmane.calico-system.svc.cluster.local", which is a SAN
          # on the live Goldmane serving cert (verified 2026-06-24:
          # DNS:goldmane{,.calico-system{,.svc{,.cluster.local}}}). So no
          # GOLDMANE_SERVER_NAME override and no GOLDMANE_TLS_INSECURE needed.
          env {
            name  = "GOLDMANE_HOST"
            value = "goldmane.calico-system.svc.cluster.local:7443"
          }
          # TLS_CERT_PATH / TLS_KEY_PATH / CA_CERT_PATH are left at their image
          # defaults (/etc/goldmane-client-tls/tls.{crt,key} and
          # /etc/tigera-ca/tigera-ca-bundle.crt) — the mounts below match them.

          env {
            name = "DATABASE_URL"
            value_from {
              secret_key_ref {
                name = "goldmane-edges-db-creds"
                key  = "DATABASE_URL"
              }
            }
          }

          volume_mount {
            name       = "goldmane-client-tls"
            mount_path = "/etc/goldmane-client-tls"
            read_only  = true
          }
          volume_mount {
            name       = "tigera-ca"
            mount_path = "/etc/tigera-ca"
            read_only  = true
          }

          resources {
            # Idles low: a single gRPC stream + periodic upserts. requests=limits
            # per the repo memory rule; no CPU limit (CFS throttling). Right-size
            # later with krr.
            requests = {
              cpu    = "10m"
              memory = "64Mi"
            }
            limits = {
              memory = "64Mi"
            }
          }
        }

        volume {
          name = "goldmane-client-tls"
          secret {
            secret_name = kubernetes_secret.goldmane_client_tls.metadata[0].name
          }
        }
        volume {
          name = "tigera-ca"
          config_map {
            name = kubernetes_config_map.tigera_ca_bundle.metadata[0].name
          }
        }
      }
    }
  }
  lifecycle {
    ignore_changes = [
      # CI pipeline owns the image tag (kubectl set image from GHA/Woodpecker).
      spec[0].template[0].spec[0].container[0].image,
      spec[0].template[0].spec[0].dns_config, # KYVERNO_LIFECYCLE_V1: Kyverno admission webhook mutates dns_config with ndots=2
      metadata[0].annotations["keel.sh/policy"],
      metadata[0].annotations["keel.sh/trigger"],
      metadata[0].annotations["keel.sh/pollSchedule"], # KYVERNO_LIFECYCLE_V2
      metadata[0].annotations["keel.sh/match-tag"],
      metadata[0].annotations["kubernetes.io/change-cause"],
      metadata[0].annotations["deployment.kubernetes.io/revision"],
      spec[0].template[0].metadata[0].annotations["keel.sh/update-time"], # KEEL_LIFECYCLE_V1
    ]
  }
}

# -----------------------------------------------------------------------------
# 6. digest — daily CronJob (first-seen edges -> Slack)
# -----------------------------------------------------------------------------
resource "kubernetes_cron_job_v1" "digest" {
  depends_on = [
    kubernetes_job.db_init,
    kubernetes_manifest.db_external_secret,
    kubernetes_manifest.slack_external_secret,
  ]
  metadata {
    name      = "goldmane-edges-digest"
    namespace = kubernetes_namespace.goldmane_edge_aggregator.metadata[0].name
    labels = {
      app  = "goldmane-edge-aggregator"
      tier = local.tiers.aux
    }
  }
  spec {
    # Daily 08:00 Europe/London — aligns with the alert-digest cadence.
    schedule                      = "0 8 * * *"
    timezone                      = "Europe/London"
    concurrency_policy            = "Forbid"
    successful_jobs_history_limit = 3
    failed_jobs_history_limit     = 3
    starting_deadline_seconds     = 600

    job_template {
      metadata {
        labels = {
          app = "goldmane-edge-aggregator"
        }
        annotations = {
          # 7-day DB rotation: bounce the Job pod's stale env (Reloader rule).
          "secret.reloader.stakater.com/reload" = "goldmane-edges-db-creds"
        }
      }
      spec {
        backoff_limit              = 2
        active_deadline_seconds    = 300
        ttl_seconds_after_finished = 86400

        template {
          metadata {
            labels = {
              app = "goldmane-edge-aggregator"
            }
          }
          spec {
            restart_policy = "OnFailure"
            image_pull_secrets {
              name = "ghcr-credentials"
            }
            container {
              name = "digest"
              # CronJobs track :latest + imagePullPolicy: Always (fleet
              # convention) so the daily run picks up the current image.
              image             = "ghcr.io/viktorbarzin/goldmane-edge-aggregator:latest"
              image_pull_policy = "Always"
              args              = ["digest"]

              env {
                name = "DATABASE_URL"
                value_from {
                  secret_key_ref {
                    name = "goldmane-edges-db-creds"
                    key  = "DATABASE_URL"
                  }
                }
              }
              env {
                name = "SLACK_WEBHOOK_URL"
                value_from {
                  secret_key_ref {
                    name = "goldmane-edges-slack"
                    key  = "SLACK_WEBHOOK_URL"
                  }
                }
              }
              env {
                name  = "SLACK_CHANNEL"
                value = "#security"
              }

              resources {
                requests = {
                  cpu    = "10m"
                  memory = "64Mi"
                }
                limits = {
                  memory = "64Mi"
                }
              }
            }
          }
        }
      }
    }
  }
  lifecycle {
    # KYVERNO_LIFECYCLE_V1 (CronJob path): Kyverno mutates dns_config with ndots=2.
    ignore_changes = [spec[0].job_template[0].spec[0].template[0].spec[0].dns_config]
  }
}

# -----------------------------------------------------------------------------
# 7. Egress (default-deny consideration)
# -----------------------------------------------------------------------------
# Goldmane's own NetworkPolicy already allows INGRESS on 7443 from anywhere, so
# nothing is needed on the Goldmane side. No egress policy is declared here:
# this namespace is default-allow egress today. IF/WHEN it is brought under the
# wave-1 default-deny egress enforcement (per-namespace allowlists), add
# (Global)NetworkPolicy egress rules permitting:
#   - goldmane.calico-system.svc.cluster.local:7443 (the flow stream)
#   - pg-cluster-rw.dbaas.svc.cluster.local:5432    (Postgres)
#   - hooks.slack.com:443                            (digest -> Slack, internet)
#   - kube-dns / CoreDNS :53                         (DNS, every namespace)
