# Keel — automated Kubernetes Deployment image updates.
# Design: docs/plans/2026-05-16-auto-upgrade-apps-design.md
# Plan:   docs/plans/2026-05-16-auto-upgrade-apps-plan.md
#
# Operation: Keel polls each watched workload's registry hourly (default
# schedule below; overridable per-workload via keel.sh/pollSchedule).
# Detection of a new digest under the watched tag triggers a Deployment
# update (pod template hash bump → rolling restart). Workloads opt in by
# carrying keel.sh/policy + keel.sh/trigger annotations — those are
# injected cluster-wide by the inject-keel-annotations ClusterPolicy
# (stacks/kyverno/modules/kyverno/keel-annotations.tf) on namespaces
# labeled keel.sh/enrolled=true.

resource "kubernetes_namespace" "keel" {
  metadata {
    name = "keel"
    labels = {
      tier = local.tiers.cluster
    }
  }
  lifecycle {
    # KYVERNO_LIFECYCLE_V1
    ignore_changes = [metadata[0].labels["goldilocks.fairwinds.com/vpa-update-mode"]]
  }
}

resource "helm_release" "keel" {
  name       = "keel"
  namespace  = kubernetes_namespace.keel.metadata[0].name
  repository = "https://charts.keel.sh"
  chart      = "keel"
  version    = "1.0.6"

  # Atomic mitigates partial-deploy state. Keel itself is exempt from
  # auto-update (Kyverno mutate excludes the keel namespace), so it only
  # rolls when this stack applies — making atomic safe here.
  atomic = true

  values = [yamlencode({
    polling = {
      enabled = true
      # Default poll cadence for workloads that don't override per-Deployment
      # via keel.sh/pollSchedule. Decision #8 in the design doc.
      defaultSchedule = "@every 1h"
    }
    helmProvider = {
      enabled = false # We use annotations, not Helm hooks
    }
    notificationLevel = "info"
    persistence = {
      enabled = false
    }
    # Keel uses each watched Deployment's own imagePullSecrets to query
    # its registry. Forgejo creds (`registry-credentials`) are auto-synced
    # to every namespace by Kyverno already, so Keel pods don't need a
    # separate pull-secret for their own image (ghcr.io is public).
    rbac = {
      enabled = true
    }
    resources = {
      requests = { cpu = "50m", memory = "64Mi" }
      limits   = { memory = "256Mi" }
    }
  })]
}
