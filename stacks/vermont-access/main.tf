############################################################################
# vermont-access: two-year archive of the Vermont complex access-control
# events (infra#176, decided by Viktor 2026-11-11).
#
# The six entrance panels (10.77.1.111-116) and the back-door terminal (.117)
# keep their event log in a ring buffer with no storage: about two weeks on
# the busiest panel. Every Monday at 00:00 Sofia time this CronJob reads each
# device over ISAPI and appends the new events to the vermont_access database
# on pg-cluster, where events older than two years are deleted.
#
# Script and design notes: files/acs_archive.py (tests: files/test_acs_archive.py).
# Network path: pods SNAT to the node address; OPNsense and rpi-sofia admit the
# k8s nodes to 10.77.1.111-117 on TCP 80 only, and the ClusterNetworkPolicies
# below keep every other namespace, and every other address and port, out.
# Runbook: docs/runbooks/cameras-nvr-intercom.md, "Архив на влизанията".
############################################################################

variable "postgresql_host" { type = string }

locals {
  namespace = "vermont-access"
  # 10.77.1.x is 192.168.1.x in the complex (ADR-0035, NETMAP on rpi-sofia).
  complex_alias_cidr = "10.77.1.0/24"
  devices            = [111, 112, 113, 114, 115, 116, 117]
}

resource "kubernetes_namespace" "vermont_access" {
  metadata {
    name = local.namespace
    labels = {
      "istio-injection" : "disabled"
      tier = local.tiers.aux
    }
  }
  lifecycle {
    # KYVERNO_LIFECYCLE_V1: goldilocks-vpa-auto-mode ClusterPolicy stamps this label on every namespace
    ignore_changes = [metadata[0].labels["goldilocks.fairwinds.com/vpa-update-mode"]]
  }
}

# The panels' admin account (the same one the devvm uses), from emo's Vault tree.
resource "kubernetes_manifest" "panel_credentials" {
  field_manager {
    force_conflicts = true
  }
  manifest = {
    apiVersion = "external-secrets.io/v1"
    kind       = "ExternalSecret"
    metadata = {
      name      = "vermont-panels"
      namespace = local.namespace
    }
    spec = {
      refreshInterval = "1h"
      secretStoreRef = {
        name = "vault-kv"
        kind = "ClusterSecretStore"
      }
      target = {
        name = "vermont-panels"
      }
      data = [{
        secretKey = "PANEL_PASSWORD"
        remoteRef = {
          key      = "emo/vermont-panels"
          property = "password"
        }
      }]
    }
  }
  depends_on = [kubernetes_namespace.vermont_access]
}

# Vault static role pg-vermont-access (stacks/vault app_db_roles.tf) owns the
# password; emo reads it through the projects-emo policy.
resource "kubernetes_manifest" "db_credentials" {
  field_manager {
    force_conflicts = true
  }
  manifest = {
    apiVersion = "external-secrets.io/v1"
    kind       = "ExternalSecret"
    metadata = {
      name      = "vermont-access-db-creds"
      namespace = local.namespace
    }
    spec = {
      refreshInterval = "15m"
      secretStoreRef = {
        name = "vault-database"
        kind = "ClusterSecretStore"
      }
      target = {
        name = "vermont-access-db-creds"
        template = {
          data = {
            PGHOST     = var.postgresql_host
            PGPORT     = "5432"
            PGDATABASE = "vermont_access"
            PGUSER     = "vermont_access"
            PGPASSWORD = "{{ .password }}"
          }
        }
      }
      data = [{
        secretKey = "password"
        remoteRef = {
          key      = "static-creds/pg-vermont-access"
          property = "password"
        }
      }]
    }
  }
  depends_on = [kubernetes_namespace.vermont_access]
}

resource "kubernetes_config_map" "script" {
  metadata {
    name      = "acs-archive-script"
    namespace = kubernetes_namespace.vermont_access.metadata[0].name
  }
  data = {
    "acs_archive.py" = file("${path.module}/files/acs_archive.py")
  }
}

resource "kubernetes_cron_job_v1" "acs_archive" {
  metadata {
    name      = "acs-archive"
    namespace = kubernetes_namespace.vermont_access.metadata[0].name
  }
  spec {
    # Monday 00:00 in Sofia, as Emil asked. The busiest panel (.116, about 640
    # events a day) holds about two weeks, so one missed run loses nothing.
    schedule                      = "0 0 * * 1"
    timezone                      = "Europe/Sofia"
    successful_jobs_history_limit = 1
    failed_jobs_history_limit     = 3
    concurrency_policy            = "Forbid"
    starting_deadline_seconds     = 3600
    job_template {
      metadata {}
      spec {
        backoff_limit = 0
        # A normal run is about a minute (about 800 requests in sequence,
        # tested from the devvm 2026-11-11).
        active_deadline_seconds    = 1800
        ttl_seconds_after_finished = 604800
        template {
          metadata {
            labels = {
              app = "acs-archive"
            }
            annotations = {
              "checksum/script" = sha1(file("${path.module}/files/acs_archive.py"))
            }
          }
          spec {
            restart_policy = "Never"
            container {
              name = "archive"
              # python3, requests and psql come baked into job-runtime.
              image             = "ghcr.io/viktorbarzin/job-runtime:latest"
              image_pull_policy = "Always"
              command           = ["python3", "/app/acs_archive.py", "run"]
              env_from {
                secret_ref {
                  name = "vermont-access-db-creds"
                }
              }
              env_from {
                secret_ref {
                  name = "vermont-panels"
                }
              }
              env {
                name  = "DEVICES"
                value = join(",", local.devices)
              }
              env {
                name  = "RETENTION"
                value = "2 years"
              }
              env {
                name  = "PUSHGATEWAY_URL"
                value = "http://prometheus-prometheus-pushgateway.monitoring:9091/metrics/job/vermont-acs-archive"
              }
              volume_mount {
                name       = "script"
                mount_path = "/app"
                read_only  = true
              }
              resources {
                requests = {
                  cpu    = "10m"
                  memory = "128Mi"
                }
                limits = {
                  memory = "256Mi"
                }
              }
            }
            volume {
              name = "script"
              config_map {
                name = kubernetes_config_map.script.metadata[0].name
              }
            }
          }
        }
      }
    }
  }
  depends_on = [kubernetes_manifest.panel_credentials, kubernetes_manifest.db_credentials]
  lifecycle {
    # KYVERNO_LIFECYCLE_V1: Kyverno admission webhook mutates dns_config with ndots=2
    ignore_changes = [spec[0].job_template[0].spec[0].template[0].spec[0].dns_config]
  }
}

# Every pod SNATs to its node's address, and OPNsense and rpi-sofia can only
# see node addresses, so the pod-level boundary is here. Tier Admin is
# evaluated before namespace NetworkPolicies; v1alpha2 because Calico 3.33
# does not enforce v1alpha1 AdminNetworkPolicy (infra#123). Same shape as the
# retired stacks/ivms complex-alias-ivms-only policy.
resource "kubernetes_manifest" "complex_alias_others_denied" {
  manifest = {
    apiVersion = "policy.networking.k8s.io/v1alpha2"
    kind       = "ClusterNetworkPolicy"
    metadata = {
      name = "complex-alias-vermont-access-only"
    }
    spec = {
      tier     = "Admin"
      priority = 20
      subject = {
        namespaces = {
          matchExpressions = [{
            key      = "kubernetes.io/metadata.name"
            operator = "NotIn"
            values   = [kubernetes_namespace.vermont_access.metadata[0].name]
          }]
        }
      }
      egress = [{
        name   = "deny-complex-alias"
        action = "Deny"
        to     = [{ networks = [local.complex_alias_cidr] }]
      }]
    }
  }
}

# vermont-access itself: the seven devices on TCP 80, nothing else in the
# complex (the NVR and the cameras stay out).
resource "kubernetes_manifest" "complex_alias_devices_only" {
  manifest = {
    apiVersion = "policy.networking.k8s.io/v1alpha2"
    kind       = "ClusterNetworkPolicy"
    metadata = {
      name = "vermont-access-devices-only"
    }
    spec = {
      tier     = "Admin"
      priority = 21
      subject = {
        namespaces = {
          matchLabels = {
            "kubernetes.io/metadata.name" = kubernetes_namespace.vermont_access.metadata[0].name
          }
        }
      }
      egress = [
        {
          name      = "accept-acs-devices-http"
          action    = "Accept"
          to        = [{ networks = [for d in local.devices : "10.77.1.${d}/32"] }]
          protocols = [{ tcp = { destinationPort = { number = 80 } } }]
        },
        {
          name   = "deny-rest-of-complex"
          action = "Deny"
          to     = [{ networks = [local.complex_alias_cidr] }]
        },
      ]
    }
  }
}
