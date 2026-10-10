# Keel — automated Kubernetes Deployment image updates.
# Design: docs/plans/2026-05-16-auto-upgrade-apps-design.md
# Plan:   docs/plans/2026-05-16-auto-upgrade-apps-plan.md
#
# STATUS (2026-10-10): parked at replicaCount = 0. The software-currency
# cutover (docs/plans/2026-10-09-software-currency-design.md, Phase 3,
# batch B00) moves version ownership to Renovate. Keel is scaled to 0
# first because a running Keel writes back its cached copy of a workload
# and would revert the annotation and ignore_changes edits of the later
# batches. The Kyverno inject-keel-annotations policy that enrolled
# workloads was deleted in the same change. The stack itself is removed
# once every batch has landed.
#
# Operation while it ran: Keel polled each watched workload's registry
# hourly and rolled the workload when a new tag or digest matched its
# keel.sh/policy annotation.

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
  # 1.2.3 = app 0.22.4 (2026-10-08). 0.22.x resolves each workload's node
  # platforms before updating, and this chart version grants the
  # list/watch on core/v1 nodes it needs. Verify with
  # `kubectl auth can-i list nodes --as=system:serviceaccount:keel:keel`.
  version = "1.2.3"

  # Atomic mitigates partial-deploy state. Keel itself is exempt from
  # auto-update (Kyverno mutate excludes the keel namespace), so it only
  # rolls when this stack applies — making atomic safe here.
  atomic          = true
  cleanup_on_fail = true

  values = [yamlencode({
    # 2026-10-10: parked (0) for the Renovate cutover, see the header.
    # History: 2026-05-26 17:30: re-enabled after switching the Kyverno-injected
    # default from `force + match-tag=true` (proven unreliable — see
    # stacks/kyverno/modules/kyverno/keel-annotations.tf) to `patch` which
    # is semver-parser-bounded. Under `patch`:
    #   - Semver-tagged workloads get patch bumps only (1.2.3 → 1.2.4).
    #   - Float / SHA / non-semver tags are IGNORED — no tag rewriting.
    # The 2026-05-26 emergency-stop scope (replicaCount=0) is reverted now
    # that the default is safe. Workloads pinned out-of-band (uptime-kuma
    # via keel.sh/policy=never LABEL) stay opted-out via the Kyverno
    # exclude rule, not via Keel's own annotation.
    replicaCount = 0
    # Patched Keel: 0.22.4 + keel.sh/pollTagsAfterCurrent, which lets a
    # workload poll only the tags pushed after its running tag. Needed for
    # ghcr.io/immich-app/immich-machine-learning, whose 150k+ tag list gets
    # HTTP 429 from ghcr before a full walk finishes. Built by
    # github.com/ViktorBarzin/keel (branch homelab, homelab-image.yml).
    # Upstream: keel-hq/keel#942 (issue), keel-hq/keel#943 (PR). Once a
    # release contains the patch, remove this override and bump the chart.
    image = {
      repository = "ghcr.io/viktorbarzin/keel"
      tag        = "0.22.4-tagcursor.1@sha256:f602a4cc5c6f5d8e455db89ad586f096c21732eb2f6f54b0f93e9f3c13e39e98"
    }
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
    # Direct Slack notifications DISABLED (2026-07-02): at notificationLevel
    # info Keel posted every rollout event to #general, and a stuck update
    # (gotenberg blocked by require-trusted-registries) re-posted the same
    # failure EVERY HOURLY POLL for days. Failure visibility now comes from
    # the KeelUpdateFailing Loki-ruler alert (stacks/monitoring loki.tf),
    # which rides the alert-on-change routing: one Slack notification plus
    # the daily digest — never an hourly drip.
    slack = {
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
