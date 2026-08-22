resource "kubernetes_namespace" "crowdsec" {
  metadata {
    name = "reloader"
    labels = {
      tier               = local.tiers.aux
      "keel.sh/enrolled" = "true"
    }
  }
  lifecycle {
    # KYVERNO_LIFECYCLE_V1: goldilocks-vpa-auto-mode ClusterPolicy stamps this label on every namespace
    ignore_changes = [metadata[0].labels["goldilocks.fairwinds.com/vpa-update-mode"]]
  }
}
resource "helm_release" "reloader" {
  namespace        = kubernetes_namespace.crowdsec.metadata[0].name
  create_namespace = false
  name             = "reloader"
  atomic           = true

  repository = "https://stakater.github.io/stakater-charts"
  chart      = "reloader"

  # Reload via a pod-template ANNOTATION instead of an injected env var.
  #
  # The chart default ("default") makes Reloader inject an env var named
  # STAKATER_<RESOURCE>_SECRET, holding a hash of the watched Secret, into the
  # container's env list. Terraform does not model that env var, so it planned to
  # remove it — and because a Kubernetes env list is ORDERED, the plan then
  # rendered as a cascade of apparent renames while every later variable shifted
  # position, e.g. on stacks/health:
  #     ~ name = "STAKATER_HEALTH_DB_SECRETS_SECRET" -> "DATABASE_URL"
  #     ~ name = "DATABASE_URL" -> "SECRET_KEY"
  # It reads like a wholesale rewrite but is one injected element. Measured
  # 2026-08-14: 33 deployments across 23 namespaces, making this the second
  # largest contributor to the 118-stack DriftStacksMany run after the lost TLS
  # cert.
  #
  # `annotations` keeps the behaviour that matters — a rotated Secret still
  # triggers a rolling restart, which the 7-day Vault DB-credential rotation
  # depends on (apps that read their password only at startup would otherwise
  # keep the stale one). It moves the marker to the pod template annotation
  # `reloader.stakater.com/last-reloaded-from`, which Terraform does not manage.
  #
  # ignore_changes was rejected as the alternative: Terraform cannot ignore a
  # single element of a list, so suppressing this would mean ignoring the whole
  # `env` block and giving up Terraform management of environment variables.
  #
  # ONE-TIME COST: removing the env vars is a pod-spec change, so all 33
  # deployments roll once when this applies. Revert = drop this `values` block.
  values = [yamlencode({
    reloader = {
      reloadStrategy = "annotations"
    }
  })]
}
