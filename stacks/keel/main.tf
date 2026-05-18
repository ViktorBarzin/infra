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

# Slack bot token for posting upgrade notifications. Existing token in
# Vault — same one used elsewhere — see secret/viktor -> slack_bot_token.
data "vault_kv_secret_v2" "viktor" {
  mount = "secret"
  name  = "viktor"
}

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
  # Latest stable per `helm search repo keel/keel -l` 2026-05-16
  # (app version 0.21.1). 1.0.6 doesn't exist — verify before bumping.
  version    = "1.2.0"

  # Atomic mitigates partial-deploy state. Keel itself is exempt from
  # auto-update (Kyverno mutate excludes the keel namespace), so it only
  # rolls when this stack applies — making atomic safe here.
  atomic = true

  values = [yamlencode({
    # Prometheus pod-annotation scrape — picks up Keel-specific metrics
    # (pending_approvals, poll_trigger_tracked_images, registries_scanned_total{image,registry})
    # on container port 9300 /metrics. The cluster's `kubernetes-pods`
    # Prometheus job keys on these annotations. Used by
    # infra/scripts/upgrade_state.sh (the /upgrade-state skill).
    podAnnotations = {
      "prometheus.io/scrape" = "true"
      "prometheus.io/port"   = "9300"
      "prometheus.io/path"   = "/metrics"
    }
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
    # Slack notifications: post every rollout to the configured channel.
    # Bot token from Vault (secret/viktor -> slack_bot_token). The Keel
    # chart sets SLACK_BOT_TOKEN, SLACK_CHANNELS, etc. on the deployment
    # from these values.
    slack = {
      enabled  = true
      botToken = data.vault_kv_secret_v2.viktor.data["slack_bot_token"]
      channel  = "general"
      # No approval flow — opt-out-pure means everything auto-rolls.
      # If we ever introduce gated rollouts, set approvalsChannel here.
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
