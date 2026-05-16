# =============================================================================
# Keel Auto-Update Annotation Injector
# =============================================================================
# Design: infra/docs/plans/2026-05-16-auto-upgrade-apps-design.md
# Plan:   infra/docs/plans/2026-05-16-auto-upgrade-apps-plan.md
#
# Mutate policy that adds keel.sh/* annotations to Deployments,
# StatefulSets and DaemonSets in *opted-in* namespaces. Opt-in is via a
# label on the namespace:
#
#   labels = { "keel.sh/enrolled" = "true" }
#
# Phase rollout = label more namespaces. No edit to this file per phase.
#
# Workloads can individually opt out with the label keel.sh/policy=never
# (used by the rollback runbook). The keel namespace itself is always
# excluded (design decision #11 — supervisor must not auto-update).

resource "kubernetes_manifest" "policy_inject_keel_annotations" {
  manifest = {
    apiVersion = "kyverno.io/v1"
    kind       = "ClusterPolicy"
    metadata = {
      name = "inject-keel-annotations"
      annotations = {
        "policies.kyverno.io/title"       = "Inject Keel Auto-Update Annotations"
        "policies.kyverno.io/category"    = "Automation"
        "policies.kyverno.io/severity"    = "low"
        "policies.kyverno.io/description" = "Adds keel.sh/policy: force + trigger: poll annotations to workloads in namespaces labeled keel.sh/enrolled=true. Phase rollout per docs/plans/2026-05-16-auto-upgrade-apps-{design,plan}.md."
      }
    }
    spec = {
      background = true
      rules = [{
        name = "add-keel-annotations"
        match = {
          any = [{
            resources = {
              kinds = ["Deployment", "StatefulSet", "DaemonSet"]
              namespaceSelector = {
                matchLabels = {
                  "keel.sh/enrolled" = "true"
                }
              }
            }
          }]
        }
        exclude = {
          any = [
            {
              resources = {
                namespaces = ["keel"]
              }
            },
            {
              resources = {
                selector = {
                  matchLabels = {
                    "keel.sh/policy" = "never"
                  }
                }
              }
            },
          ]
        }
        mutate = {
          patchStrategicMerge = {
            metadata = {
              annotations = {
                # `+(...)` only adds if not present; per-workload overrides win.
                #
                # DEFAULT IS `never` — Keel ignores the workload.
                #
                # Rationale (post 2026-05-16 incident): Keel's `force` policy
                # is documented as "always update to the newest tag in the
                # registry," not "watch current tag for digest changes." On
                # services pinned to semver (e.g. calico/node:v3.26.1,
                # affine:0.26.6), force triggers a tag REWRITE — Keel switched
                # affine → :nightly-latest and calico → :master. Calico was
                # auto-healed by tigera-operator; affine had to be rolled back.
                #
                # Safe enablement now requires per-WORKLOAD opt-in:
                #   (a) ensure the Deployment's image is on a MUTABLE tag —
                #       `:latest` (force works), `:<major>` like `:16`/`:7`,
                #       or a vendor "stable" tag.
                #   (b) override THIS default by setting the Deployment's
                #       metadata.annotations["keel.sh/policy"] to `force`
                #       (digest tracking on the mutable tag) or `patch`/`minor`
                #       (semver bumps, requires `ignore_changes` on image).
                #
                # The namespace enrollment label + V2 lifecycle remain in
                # place so opt-in is a one-line annotation per Deployment,
                # without touching the namespace or refactoring lifecycle.
                "+(keel.sh/policy)"       = "never"
                "+(keel.sh/trigger)"      = "poll"
                "+(keel.sh/pollSchedule)" = "@every 1h"
              }
            }
          }
        }
      }]
    }
  }
  depends_on = [helm_release.kyverno]
}
