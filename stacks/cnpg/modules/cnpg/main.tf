variable "tier" { type = string }

# -----------------------------------------------------------------------------
# Namespace
# -----------------------------------------------------------------------------
resource "kubernetes_namespace" "cnpg_system" {
  metadata {
    name = "cnpg-system"
    labels = {
      tier = var.tier
    }
  }
  lifecycle {
    # KYVERNO_LIFECYCLE_V1: goldilocks-vpa-auto-mode ClusterPolicy stamps this label on every namespace
    ignore_changes = [metadata[0].labels["goldilocks.fairwinds.com/vpa-update-mode"]]
  }
}

# -----------------------------------------------------------------------------
# CloudNativePG Operator — manages PostgreSQL clusters via CRDs
# https://cloudnative-pg.io/
# -----------------------------------------------------------------------------
resource "helm_release" "cnpg" {
  namespace        = kubernetes_namespace.cnpg_system.metadata[0].name
  create_namespace = false
  name             = "cnpg"
  atomic           = true
  cleanup_on_fail  = true
  timeout          = 300

  repository = "https://cloudnative-pg.github.io/charts"
  chart      = "cloudnative-pg"
  # 0.27.1 (operator 1.28.1) -> 0.29.1 (operator 1.30.1), 2026-10-12. Direct
  # jump: upstream lists no required intermediate release, and the only 1.29
  # chart (0.28.3, operator 1.29.1) lacks the June CVE fixes. CRDs are chart
  # templates (crds.create), so helm upgrades them; 0.29 adds DatabaseRole.
  version = "0.29.1"

  values = [yamlencode({
    crds = {
      create = true
    }

    replicaCount = 1

    # Longer leader election, same reasoning as the control plane in
    # stacks/rbac/modules/rbac/leader-election-tuning.tf. With the defaults
    # (lease 15s, renew deadline 10s) the lease client's request timeout is
    # renew/2 = 5s, and a slow etcd write turns into
    #   Put .../leases/db9c8771.cnpg.io?timeout=5s: context deadline exceeded
    # then "leader election lost" and exit 1. Measured 2026-10-15: 67 restarts
    # in 2d13h on operator 1.30.1 (about 21 in the last 24h). These are the
    # only two knobs the 1.30 controller exposes (internal/cmd/manager/
    # controller/cmd.go); the retry period stays at controller-runtime's 2s,
    # which keeps 45 > 2 * 1.2. Cost: after an operator crash the replacement
    # can wait up to 60s for the lease. With one replica there is no failover
    # either way, and running Postgres instances do not depend on the operator
    # being up. Changing these args restarts only the operator pod.
    additionalArgs = [
      "--leader-lease-duration=60",
      "--leader-renew-deadline=45",
    ]

    resources = {
      requests = {
        cpu    = "100m"
        memory = "256Mi"
      }
      limits = {
        memory = "256Mi"
      }
    }

    # Tune webhook-cert renewal threshold. CNPG default is 7 days remaining,
    # which leaves no buffer when the cluster-health check (#22) flags
    # certs at <30d. Bump to 30 days so the operator rotates well before
    # external monitoring notices. Cert lifetime stays at chart default 90d.
    #
    # ENABLE_INSTANCE_MANAGER_INPLACE_UPDATES: on an operator upgrade, push the
    # new instance manager binary into each running Postgres pod (re-exec,
    # postmaster adopted) instead of the default rolling update. pg-cluster runs
    # primaryUpdateStrategy=unsupervised + primaryUpdateMethod=restart, so the
    # default path would delete and recreate every instance, the primary
    # included, with a write outage on the DB that holds Terraform state and
    # Woodpecker. This is operator config only; the Cluster spec is unchanged.
    config = {
      data = {
        EXPIRING_CHECK_THRESHOLD                = "30"
        ENABLE_INSTANCE_MANAGER_INPLACE_UPDATES = "true"
      }
    }
  })]
}

# NOTE: local-path-provisioner is already installed in the cluster
# (via cloud-init template) with StorageClass "local-path" (default).
# ReclaimPolicy is "Delete" — for CNPG clusters, set
# .spec.storage.pvcTemplate.storageClassName = "local-path" in the
# Cluster CR. CNPG handles PVC lifecycle independently.
