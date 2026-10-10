# Verify Jobs: the namespace, identity and credentials the per-stack verify
# scripts run with.
#
# Software-currency design, "Verification contract"
# (docs/plans/2026-10-09-software-currency-design.md). An upgrade counts as
# landed only when the component's checks pass. scripts/verify/run starts a Job
# here that runs scripts/verify/lib.sh (the floor: rollout, ingress, alerts)
# and stacks/<stack>/verify.sh (the component's own checks).
# How to run and extend: docs/runbooks/verify-jobs.md.
#
# What the Job identity may do:
#   - read everything in the cluster except Secrets (verify-read below)
#   - in this namespace: create and delete probe pods and PVCs, and server-side
#     dry runs of a privileged pod, an ExternalSecret and a CNPG Cluster (the
#     admission-webhook checks; a dry run persists nothing)
#   - in the database namespaces: start a Job from the backup CronJob, the
#     "backup job runs on the new version" check
# It has no exec into other namespaces' pods: database probes log in over the
# network with the credentials below.

variable "nfs_server" { type = string }

locals {
  # Namespaces whose backup CronJob the database checks start once.
  backup_namespaces = ["dbaas", "immich", "redis", "rybbit", "beads-server"]
}

resource "kubernetes_namespace" "verify" {
  metadata {
    name = "verify"
    labels = {
      # Aux tier: tier-4-aux priority and the aux quota (20 pods, 2 CPU /
      # 3Gi requests). A verify Job is one pod plus short probe pods.
      tier = local.tiers.aux
    }
  }
  lifecycle {
    # KYVERNO_LIFECYCLE_V1: goldilocks-vpa-auto-mode ClusterPolicy stamps this label on every namespace
    ignore_changes = [metadata[0].labels["goldilocks.fairwinds.com/vpa-update-mode"]]
  }
}

resource "kubernetes_service_account" "verify_runner" {
  metadata {
    name      = "verify-runner"
    namespace = kubernetes_namespace.verify.metadata[0].name
  }
}

# Read access to every API group the checks look at. Core resources are
# listed one by one so Secrets stay out; the other groups are read in full
# (generators.external-secrets.io, which can mint credentials, is left out).
resource "kubernetes_cluster_role" "verify_read" {
  metadata {
    name = "verify-read"
  }
  rule {
    api_groups = [""]
    resources = [
      "pods", "pods/log", "pods/status", "services", "endpoints", "nodes", "nodes/status",
      "namespaces", "configmaps", "persistentvolumeclaims", "persistentvolumes", "events",
      "serviceaccounts", "replicationcontrollers", "resourcequotas", "limitranges",
    ]
    verbs = ["get", "list", "watch"]
  }
  rule {
    api_groups = [
      "admissionregistration.k8s.io", "apiextensions.k8s.io", "apiregistration.k8s.io",
      "apps", "autoscaling", "batch", "coordination.k8s.io", "discovery.k8s.io",
      "events.k8s.io", "networking.k8s.io", "node.k8s.io", "policy", "rbac.authorization.k8s.io",
      "scheduling.k8s.io", "storage.k8s.io", "snapshot.storage.k8s.io", "metrics.k8s.io",
      "aquasecurity.github.io", "bitnami.com", "configuration.konghq.com", "crd.projectcalico.org",
      "external-secrets.io", "gateway.networking.k8s.io", "hub.traefik.io", "kyverno.io",
      "metallb.io", "monitoring.grafana.com", "nfd.k8s-sigs.io", "nvidia.com", "operator.tigera.io",
      "policies.kyverno.io", "policy.networking.k8s.io", "postgresql.cnpg.io", "projectcalico.org",
      "reports.kyverno.io", "traefik.io", "wgpolicyk8s.io",
    ]
    resources = ["*"]
    verbs     = ["get", "list", "watch"]
  }
  rule {
    non_resource_urls = ["/healthz", "/livez", "/readyz", "/version"]
    verbs             = ["get"]
  }
}

resource "kubernetes_cluster_role_binding" "verify_read" {
  metadata {
    name = "verify-read"
  }
  role_ref {
    api_group = "rbac.authorization.k8s.io"
    kind      = "ClusterRole"
    name      = kubernetes_cluster_role.verify_read.metadata[0].name
  }
  subject {
    kind      = "ServiceAccount"
    name      = kubernetes_service_account.verify_runner.metadata[0].name
    namespace = kubernetes_namespace.verify.metadata[0].name
  }
}

# Writes inside the verify namespace only.
resource "kubernetes_role" "verify_runner" {
  metadata {
    name      = "verify-runner"
    namespace = kubernetes_namespace.verify.metadata[0].name
  }
  # Probe pods (database clients, nvidia-smi, storage smoke tests) and the
  # Kyverno admission dry runs.
  rule {
    api_groups = [""]
    resources  = ["pods"]
    verbs      = ["create", "delete", "get", "list", "watch"]
  }
  # Storage smoke tests: create, expand and delete a PVC on each CSI driver.
  rule {
    api_groups = [""]
    resources  = ["persistentvolumeclaims"]
    verbs      = ["create", "delete", "get", "list", "watch", "patch"]
  }
  # Admission-webhook dry runs (ESO and CNPG webhooks refuse invalid objects).
  rule {
    api_groups = ["external-secrets.io"]
    resources  = ["externalsecrets"]
    verbs      = ["create"]
  }
  rule {
    api_groups = ["postgresql.cnpg.io"]
    resources  = ["clusters"]
    verbs      = ["create"]
  }
}

resource "kubernetes_role_binding" "verify_runner" {
  metadata {
    name      = "verify-runner"
    namespace = kubernetes_namespace.verify.metadata[0].name
  }
  role_ref {
    api_group = "rbac.authorization.k8s.io"
    kind      = "Role"
    name      = kubernetes_role.verify_runner.metadata[0].name
  }
  subject {
    kind      = "ServiceAccount"
    name      = kubernetes_service_account.verify_runner.metadata[0].name
    namespace = kubernetes_namespace.verify.metadata[0].name
  }
}

# Start (and clean up) a one-off Job from a backup CronJob.
resource "kubernetes_role" "verify_backup" {
  for_each = toset(local.backup_namespaces)
  metadata {
    name      = "verify-backup-run"
    namespace = each.value
  }
  rule {
    api_groups = ["batch"]
    resources  = ["jobs"]
    verbs      = ["create", "delete", "get", "list", "watch"]
  }
}

resource "kubernetes_role_binding" "verify_backup" {
  for_each = toset(local.backup_namespaces)
  metadata {
    name      = "verify-backup-run"
    namespace = each.value
  }
  role_ref {
    api_group = "rbac.authorization.k8s.io"
    kind      = "Role"
    name      = kubernetes_role.verify_backup[each.value].metadata[0].name
  }
  subject {
    kind      = "ServiceAccount"
    name      = kubernetes_service_account.verify_runner.metadata[0].name
    namespace = kubernetes_namespace.verify.metadata[0].name
  }
}

# Storage classes for the CSI smoke tests. Same parameters as proxmox-lvm and
# nfs-pve, but reclaimPolicy Delete, so the test volume (LV on the PVE host,
# directory on the NFS share) is removed when the test PVC is deleted. The
# production classes are Retain.
resource "kubernetes_storage_class" "verify_proxmox_lvm" {
  metadata {
    name = "verify-proxmox-lvm"
  }
  storage_provisioner    = "csi.proxmox.sinextra.dev"
  reclaim_policy         = "Delete"
  volume_binding_mode    = "WaitForFirstConsumer"
  allow_volume_expansion = true
  parameters = {
    storage                     = "local-lvm"
    cache                       = "none"
    "csi.storage.k8s.io/fstype" = "ext4"
  }
}

resource "kubernetes_storage_class" "verify_nfs" {
  metadata {
    name = "verify-nfs"
  }
  storage_provisioner = "nfs.csi.k8s.io"
  reclaim_policy      = "Delete"
  volume_binding_mode = "Immediate"
  mount_options       = ["nfsvers=4", "soft", "timeo=30", "retrans=3", "actimeo=5"]
  parameters = {
    server = var.nfs_server
    share  = "/srv/nfs"
    # Test volumes land in their own directory and are deleted with the PVC.
    subDir = "verify-smoke/$${pvc.metadata.name}"
  }
}

# Database credentials, from Vault through ESO.
#   verify-db-creds: Vault database-engine static roles for the verify_probe
#   users on pg-cluster and MySQL (created in stacks/dbaas, roles in
#   stacks/vault). verify_probe owns only its own scratch database, can read
#   replication status (pg_monitor) and connect to the databases whose
#   extensions it checks.
#   verify-app-creds: the Immich Postgres and rybbit ClickHouse passwords from
#   Vault KV (single-tenant servers; the probes write only to a scratch
#   schema/database and drop it).
# refreshInterval is short because the static roles rotate weekly and a Job
# started just after a rotation would otherwise read the old password.
resource "kubernetes_manifest" "verify_db_creds" {
  field_manager {
    force_conflicts = true
  }
  manifest = {
    apiVersion = "external-secrets.io/v1"
    kind       = "ExternalSecret"
    metadata = {
      name      = "verify-db-creds"
      namespace = kubernetes_namespace.verify.metadata[0].name
    }
    spec = {
      refreshInterval = "2m"
      secretStoreRef = {
        name = "vault-database"
        kind = "ClusterSecretStore"
      }
      target = {
        name = "verify-db-creds"
      }
      data = [
        {
          secretKey = "PG_VERIFY_PASSWORD"
          remoteRef = {
            key      = "static-creds/pg-verify-probe"
            property = "password"
          }
        },
        {
          secretKey = "MYSQL_VERIFY_PASSWORD"
          remoteRef = {
            key      = "static-creds/mysql-verify-probe"
            property = "password"
          }
        },
      ]
    }
  }
}

resource "kubernetes_manifest" "verify_app_creds" {
  field_manager {
    force_conflicts = true
  }
  manifest = {
    apiVersion = "external-secrets.io/v1"
    kind       = "ExternalSecret"
    metadata = {
      name      = "verify-app-creds"
      namespace = kubernetes_namespace.verify.metadata[0].name
    }
    spec = {
      refreshInterval = "15m"
      secretStoreRef = {
        name = "vault-kv"
        kind = "ClusterSecretStore"
      }
      target = {
        name = "verify-app-creds"
      }
      data = [
        {
          secretKey = "IMMICH_DB_PASSWORD"
          remoteRef = {
            key      = "immich"
            property = "db_password"
          }
        },
        {
          secretKey = "CLICKHOUSE_PASSWORD"
          remoteRef = {
            key      = "rybbit"
            property = "clickhouse_password"
          }
        },
      ]
    }
  }
}
